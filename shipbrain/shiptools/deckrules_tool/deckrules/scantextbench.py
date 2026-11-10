"""Text benchmark for the scan reader (owner 2026-10-24): vector pdf regions are rendered as 400 dpi 1-bit scans, read by the offline OCR path and compared WORD BY WORD
with the true vector text (position + string).  Failures are listed by class (numeric / alpha / mixed, size, direction) with the wrong readings, so that rules can be added.
python -m deckrules.scantextbench PDF [PDF...] --pages 1 --crops 2 --out report.md"""
import argparse
import collections
import os
import re
import numpy as np
import cv2
import pymupdf
from . import scanvec as sv
from . import scanbench as sb

NORM = lambda x: re.sub(r'[^A-Z0-9.+\-X/]', '', x.upper())


def pick_text_crops(pg, n):
    R = pg.mediabox
    gx, gy = int(R.width // 150) + 1, int(R.height // 150) + 1
    hist = np.zeros((gy, gx))
    for w in pg.get_text('words'):
        hist[min(int(w[1] // 150), gy - 1), min(int(w[0] // 150), gx - 1)] += 1
    best, out = [], []
    for iy in range(gy):
        for ix in range(gx):
            x0, y0 = ix * 150.0, iy * 150.0
            if x0 + sb.CW > R.width or y0 + sb.CH > R.height:
                continue
            best.append((hist[iy:iy + int(sb.CH // 150), ix:ix + int(sb.CW // 150)].sum(), x0, y0))
    for sc, x0, y0 in sorted(best, reverse=True):
        if sc <= 0:
            break
        if all(abs(x0 - a) >= sb.CW or abs(y0 - b) >= sb.CH for a, b in out):
            out.append((x0, y0))
        if len(out) >= n:
            break
    return out


def classify_word(w, size, vertical):
    n = NORM(w)
    kind = 'numeric' if re.fullmatch(r'[0-9.]+', n) else ('alpha' if re.fullmatch(r'[A-Z.]+', n) else 'mixed')
    return kind, ('size<5pt' if size < 5 else 'size5-8pt' if size < 8 else 'size>=8pt'), ('vertical' if vertical else 'horizontal')


def read_crop(pg, crop, ocr_fn, dpi=400.0):
    """-> list of (gt_word, class, found_exact, found_position, ocr_text_there)"""
    cr = pymupdf.Rect(crop[0], crop[1], crop[0] + sb.CW, crop[1] + sb.CH)
    g = sv.render_scan_like(pg, cr, dpi)
    k = {90: -1, 180: 2, 270: 1}.get(pg.rotation, 0)
    gd = np.ascontiguousarray(np.rot90(g, k)) if k else g
    lines = ocr_fn(gd)                                                  # list of (text, (x0,y0,x1,y1) px of gd)
    crd = cr * pg.rotation_matrix
    s = dpi / 72.0
    out = []
    d = pg.get_text('dict', clip=cr)
    for b in d['blocks']:
        for ln in b.get('lines', []):
            dx, dy = ln['dir']
            for sp in ln['spans']:
                words = sp['text'].split()
                if not words:
                    continue
                r = pymupdf.Rect(sp['bbox']) * pg.rotation_matrix
                # per-word box: split the span box proportionally to characters (horizontal in text direction)
                tot = len(sp['text']); pos = 0
                for w in words:
                    i = sp['text'].index(w, pos); pos = i + len(w)
                    f0, f1 = i / tot, (i + len(w)) / tot
                    ox, oy = ln['dir']
                    bx0, by0, bx1, by1 = sp['bbox']
                    if abs(dx) >= abs(dy):
                        wb = pymupdf.Rect(bx0 + (bx1 - bx0) * f0, by0, bx0 + (bx1 - bx0) * f1, by1) if dx > 0 else pymupdf.Rect(bx1 - (bx1 - bx0) * f1, by0, bx1 - (bx1 - bx0) * f0, by1)
                    else:
                        wb = pymupdf.Rect(bx0, by0 + (by1 - by0) * f0, bx1, by0 + (by1 - by0) * f1) if dy > 0 else pymupdf.Rect(bx0, by1 - (by1 - by0) * f1, bx1, by1 - (by1 - by0) * f0)
                    wd = wb * pg.rotation_matrix
                    cx, cy = ((wd.x0 + wd.x1) / 2 - crd.x0) * s, ((wd.y0 + wd.y1) / 2 - crd.y0) * s
                    n = NORM(w)
                    if not n:
                        continue
                    # displayed direction of the word: horizontal if the displayed box is wider than tall
                    vertical = (wd.y1 - wd.y0) > 1.5 * (wd.x1 - wd.x0) and len(n) > 1
                    near = [t for t, (x0, y0, x1, y1) in lines if x0 - 6 <= cx <= x1 + 6 and y0 - 6 <= cy <= y1 + 6]
                    exact = any(n in NORM(t) for t in near)
                    out.append((w, classify_word(w, sp['size'], vertical), exact, bool(near), ' | '.join(near)[:60]))
    return out


def main(argv=None):
    from .ocr import OCR
    from .read_drawing import OCR_SCALE
    ap = argparse.ArgumentParser()
    ap.add_argument('pdfs', nargs='+'); ap.add_argument('--pages', default='1'); ap.add_argument('--crops', type=int, default=2); ap.add_argument('--out', default='scantextbench.md')
    ap.add_argument('--scale', type=float, default=OCR_SCALE)
    ap.add_argument('--residual', action='store_true')
    ap.add_argument('--reread', action='store_true')
    ap.add_argument('--numcheck', action='store_true')
    ap.add_argument('--ext', default='', help='up | down: digit extension, vertical text reads bottom->top (up) or top->bottom')
    a = ap.parse_args(argv)
    eng = OCR('auto')

    import hashlib, pickle
    from .ocr import Line

    def ocr_fn(gd):
        key = hashlib.md5(gd.tobytes()).hexdigest() + f'_{a.scale}_{int(a.residual)}{int(a.reread)}{a.ext}'
        cf = f'/tmp/work/ocrcache_{key}.pkl'
        if os.path.exists(cf):
            lines = [Line(tx, bx, 0.9, vv) for tx, bx, vv in pickle.load(open(cf, 'rb'))]
        else:
            gs = cv2.resize(gd, None, fx=a.scale, fy=a.scale, interpolation=cv2.INTER_AREA)
            lines = eng.read_tiled(gs, tile=1000)
            for ln in lines:
                ln.box = ln.box / a.scale
            if a.reread:
                lines = eng.reread_short(gd, lines)
            if a.ext:
                lines = eng.extend_digits(gd, lines, vertical_up=(a.ext == 'up'))
            if a.residual:
                rl = eng.read_residual(gd, [tuple(l.box[:, 0].min() for _ in [0]) + (l.box[:, 1].min(), l.box[:, 0].max(), l.box[:, 1].max(), l.text) for l in lines])
                if a.ext:
                    rl = eng.extend_digits(gd, rl, vertical_up=(a.ext == 'up'))
                lines = list(lines) + list(rl)
            pickle.dump([(l.text, l.box, l.vertical) for l in lines], open(cf, 'wb'))
        if a.numcheck:
            from . import numcheck
            fx = numcheck.check(lines)
            print('   numcheck fixes:', fx)
        return [(ln.text.strip(), (ln.box[:, 0].min(), ln.box[:, 1].min(), ln.box[:, 0].max(), ln.box[:, 1].max())) for ln in lines]
    return run(a.pdfs, [int(x) for x in a.pages.split(',')], a.crops, ocr_fn, a.out)


def run(pdfs, pages, ncrops, ocr_fn, out, quiet=False):
    allr = []
    for pdf in pdfs:
        doc = pymupdf.open(pdf)
        for pn in pages:
            if pn > len(doc):
                continue
            pg = doc[pn - 1]
            for c in pick_text_crops(pg, ncrops):
                r = read_crop(pg, c, ocr_fn)
                allr += [(os.path.basename(pdf)[:24],) + x for x in r]
                if not quiet:
                    e = sum(1 for x in r if x[2])
                    print(os.path.basename(pdf)[:24], pn, c, len(r), 'exact %.3f' % (e / max(len(r), 1)), flush=True)
    tot = len(allr); ex = sum(1 for x in allr if x[3]); pos = sum(1 for x in allr if x[4])
    L = [f'# Text benchmark (vector text vs OCR of the same region rendered as a 400 dpi scan)\n', f'words {tot}: **exact {ex / max(tot, 1):.3f}**, position found {pos / max(tot, 1):.3f}\n', '## By class\n\n| class | words | exact |\n|---|---|---|']
    byc = collections.defaultdict(lambda: [0, 0])
    for x in allr:
        for c in x[2]:
            byc[c][0] += 1; byc[c][1] += 1 if x[3] else 0
    for c, v in sorted(byc.items()):
        L.append(f'| {c} | {v[0]} | {v[1] / v[0]:.3f} |')
    byp = collections.defaultdict(lambda: [0, 0])
    for x in allr:
        byp[x[0]][0] += 1; byp[x[0]][1] += 1 if x[3] else 0
    L.append('\n## By drawing\n\n| drawing | words | exact |\n|---|---|---|')
    for c, v in sorted(byp.items()):
        L.append(f'| {c} | {v[0]} | {v[1] / v[0]:.3f} |')
    bad = [x for x in allr if not x[3]]
    L.append('\n## Wrong / missed words (true word -> what OCR has at that place)\n')
    cnt = collections.Counter((x[1], x[5]) for x in bad)
    for (w, o), n in cnt.most_common(80):
        L.append(f'- `{w}` -> `{o}`' + (f'  x{n}' if n > 1 else ''))
    open(out, 'w').write('\n'.join(L))
    return allr


if __name__ == '__main__':
    main()
