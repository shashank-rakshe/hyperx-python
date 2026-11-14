"""Offline drawing reader (owner 2026-10-24): STEP 1 raw vector data + STEP 2 scale calibration, written as documents.
  python -m deckrules.read_drawing DRAWING.pdf --out OUT
Only pymupdf; deterministic; no OCR / network / AI.  Facts printed on the drawing are read as they are.  A rule that DECIDES something (which view a note belongs to)
lives in ONE function (assign_note) and is printed in the document as 'proposed, unconfirmed'; the owner corrects it when it is wrong."""
import argparse
import collections
import math
import os
import re
import numpy as np
import cv2
import pymupdf

NOTE_KEYS = ('DECK PLATE', 'DECK HEIGHT', 'FRAME SPACE', 'PLATE THK', 'STIFF', 'DECK BEAM')
DESPECKLE = False
OCR_SCALE = 0.4            # scanned pages are OCR-read at this share of their resolution (benchmark: better numbers, 4x faster)
TITLE_MIN_RATIO = 0.9          # a view title = text whose font size is >= this share of the largest size on the drawing


def _spans(page):
    for b in page.get_text('dict')['blocks']:
        for ln in b.get('lines', []):
            for s in ln['spans']:
                t = s['text'].strip()
                if t:
                    yield s['size'], t, s['bbox']


def titles(page, max_size):
    out, seen = [], set()
    for sz, t, bb in _spans(page):
        if sz >= TITLE_MIN_RATIO * max_size and len(t) > 3 and (t, round(bb[0])) not in seen:
            seen.add((t, round(bb[0]))); out.append((t, bb[0], bb[1]))
    return out


def assign_note(note_xy, view_titles):
    """PROPOSED rule N1 (unconfirmed): a note belongs to the view title nearest to it (straight distance).  Replace this function when the owner teaches the right rule."""
    if not view_titles:
        return None, None
    d = [(math.hypot(note_xy[0] - x, note_xy[1] - y), t) for t, x, y in view_titles]
    d.sort()
    return d[0][1], round(d[0][0])


def chains(page):
    rows = collections.defaultdict(list)
    for w in page.get_text('words'):
        if re.fullmatch(r'\d{3,4}', w[4]):
            rows[round((w[1] + w[3]) / 2 / 4)].append(((w[0] + w[2]) / 2, int(w[4])))
    out = []
    for y, r in sorted(rows.items()):
        r.sort()
        if len(r) < 10:
            continue
        xs = np.array([a[0] for a in r]); vs = np.array([a[1] for a in r])
        span = xs[-1] - xs[0]
        if span <= 0:
            continue
        mm = vs[0] / 2 + vs[1:-1].sum() + vs[-1] / 2
        cum = bool(np.mean(np.diff(vs) > 0) > 0.8 or np.mean(np.diff(vs) < 0) > 0.8)          # values that keep growing are positions (cumulative), not spacings
        out.append({'cum': cum, 'y': y * 4, 'n': len(r), 'x0': xs[0], 'x1': xs[-1], 'mm': mm, 'scale': mm / span, 'set': sorted(set(vs.tolist()))})
    return out


def read(pdf):
    doc = pymupdf.open(pdf)
    max_size = max((sz for p in doc for sz, t, bb in _spans(p) if len(t) > 3), default=0)
    pages = []
    for i, p in enumerate(doc):
        tt = titles(p, max_size)
        notes = []
        for b in p.get_text('blocks'):
            t = b[4].replace('\n', ' ').strip()
            if any(k in t.upper() for k in NOTE_KEYS):
                v, d = assign_note((b[0], b[1]), [x for x in tt if re.search(r'PLAN|DECK|ELEV|SEC', x[0].upper())])
                notes.append((t, b[0], b[1], v, d))
        pages.append({'n': i + 1, 'rect': p.rect, 'paths': len(p.get_drawings()), 'words': len(p.get_text('words')), 'images': len(p.get_images()),
                      'titles': tt, 'notes': notes, 'chains': chains(p),
                      'frames': sorted({(w[4], round(w[0]), round(w[1])) for w in p.get_text('words') if re.fullmatch(r'FR\.\d+([+-]\d+)?', w[4])}),
                      'details': sorted(set(re.findall(r'["\']\w+-\d["\'] (?:ELEV|SEC|PLAN)[^\n]*', p.get_text())))})
    return pages


def dump_raw(pdf, outdir, name):
    """R1 (owner 2026-10-24): STEP 1 = extract ALL raw vector data of EVERY page, nothing interpreted:
    <name>_pN_text.csv   every text span: text, bbox, font size, font, colour, direction (rotation), flags
    <name>_pN_paths.csv  every vector path: index, type (stroke/fill), colour, fill, line width, dash, closed, bbox, item count, item kinds
    <name>_pN_segments.csv every item of every path: path index, kind (l line / c curve / re rect / qu quad), coordinates (pt)"""
    import csv
    doc = pymupdf.open(pdf)
    tot = []
    for i, pg in enumerate(doc):
        n = i + 1
        nt = 0
        with open(os.path.join(outdir, f'{name}_p{n}_text.csv'), 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f); w.writerow(['text', 'x0', 'y0', 'x1', 'y1', 'size', 'font', 'color', 'dir_x', 'dir_y', 'flags', 'source', 'score'])
            for b in pg.get_text('dict')['blocks']:
                for ln in b.get('lines', []):
                    dx, dy = ln.get('dir', (1, 0))
                    for sp in ln['spans']:
                        if sp['text'].strip():
                            bb = sp['bbox']; nt += 1
                            w.writerow([sp['text'], round(bb[0], 2), round(bb[1], 2), round(bb[2], 2), round(bb[3], 2), round(sp['size'], 2), sp['font'], sp['color'], round(dx, 3), round(dy, 3), sp['flags'], 'vector', ''])
        npth = nseg = 0
        with open(os.path.join(outdir, f'{name}_p{n}_paths.csv'), 'w', newline='', encoding='utf-8') as f1, open(os.path.join(outdir, f'{name}_p{n}_segments.csv'), 'w', newline='', encoding='utf-8') as f2:
            w1 = csv.writer(f1); w2 = csv.writer(f2)
            w1.writerow(['path', 'type', 'stroke_rgb', 'fill_rgb', 'width', 'dash', 'closed', 'x0', 'y0', 'x1', 'y1', 'items', 'kinds', 'source'])
            w2.writerow(['path', 'kind', 'x1', 'y1', 'x2', 'y2', 'x3', 'y3', 'x4', 'y4'])
            for k, d in enumerate(pg.get_drawings()):
                r = d['rect']; npth += 1
                col = lambda c: '' if c is None else ' '.join(f'{v:.3f}' for v in c)
                w1.writerow([k, d.get('type', ''), col(d.get('color')), col(d.get('fill')), d.get('width', ''), d.get('dashes', ''), d.get('closePath', ''),
                             round(r.x0, 2), round(r.y0, 2), round(r.x1, 2), round(r.y1, 2), len(d['items']), ''.join(it[0] for it in d['items']), 'vector'])
                for it in d['items']:
                    pts = []
                    for v in it[1:]:
                        if hasattr(v, 'x0'):
                            pts += [v.x0, v.y0, v.x1, v.y1]
                        elif hasattr(v, 'x'):
                            pts += [v.x, v.y]
                    w2.writerow([k, it[0]] + [round(float(v), 2) for v in pts[:8]]); nseg += 1
        # embedded raster images (scanned pages): every image saved as it is, with its place on the page
        with open(os.path.join(outdir, f'{name}_p{n}_images.csv'), 'w', newline='', encoding='utf-8') as f3:
            w3 = csv.writer(f3); w3.writerow(['image', 'xref', 'width_px', 'height_px', 'bpc', 'colorspace', 'x0', 'y0', 'x1', 'y1', 'dpi_x', 'dpi_y', 'file'])
            for k, im in enumerate(pg.get_image_info(xrefs=True)):
                bb = im['bbox']; fn = f'{name}_p{n}_img{k}.png'
                try:
                    pix = pymupdf.Pixmap(doc, im['xref'])
                    if pix.n - pix.alpha > 3:
                        pix = pymupdf.Pixmap(pymupdf.csRGB, pix)
                    pix.save(os.path.join(outdir, fn))
                except Exception as e:
                    fn = f'not saved: {e}'
                wpt, hpt = bb[2] - bb[0], bb[3] - bb[1]
                w3.writerow([k, im['xref'], im['width'], im['height'], im.get('bpc', ''), im.get('colorspace', ''), round(bb[0], 2), round(bb[1], 2), round(bb[2], 2), round(bb[3], 2),
                             round(im['width'] / wpt * 72, 1) if wpt else '', round(im['height'] / hpt * 72, 1) if hpt else '', fn])
        tot.append((n, nt, npth, nseg))
    return tot


def ocr_scanned(pdf, outdir, name, pages=None, backend='auto', log=print):
    """R1 (scanned pages): a page whose embedded image covers most of the page is OCR-read OFFLINE (local RapidOCR / Tesseract, models inside the package, no network).
    The image is turned to the DISPLAYED orientation (page rotation), tiled, read, and every text line is written as
    <name>_pN_ocr_text.csv: text, box in page pt (displayed orientation, y down), score, vertical.  Nothing is interpreted."""
    import csv
    import time
    from .ocr import OCR
    doc = pymupdf.open(pdf)
    eng = None
    res = []
    for i, pg in enumerate(doc):
        n = i + 1
        if pages and n not in pages:
            continue
        infos = pg.get_image_info(xrefs=True)
        area = pg.rect.width * pg.rect.height
        big = [im for im in infos if (im['bbox'][2] - im['bbox'][0]) * (im['bbox'][3] - im['bbox'][1]) >= 0.8 * area]
        if not big:
            continue
        if eng is None:
            eng = OCR(backend)
        im = big[0]
        pix = pymupdf.Pixmap(doc, im['xref'])
        if pix.n - pix.alpha > 1:
            pix = pymupdf.Pixmap(pymupdf.csGRAY, pix)
        g = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)[:, :, 0].copy()
        if pix.n == 1 and g.max() <= 1:
            g = g * 255
        k = {90: -1, 180: 2, 270: 1}.get(pg.rotation, 0)              # image turned the way the page is DISPLAYED
        if k:
            g = np.ascontiguousarray(np.rot90(g, k))
        from . import scanvec as _sv
        g, skew_deg = _sv.deskew(g)                       # R-S7 straighten a skewed scan (skew 0.5 deg: recall 0.42 -> 0.96 in the noise benchmark)
        if DESPECKLE:                                     # R-S8 scanner dust: OFF by default (no measurable gain; it erased fine-dot logo letters, 142 -> 66 OCR lines on EC page 3)
            g = _sv.despeckle(g, dpi=72.0 * g.shape[1] / (pg.rect.height if pg.rotation in (90, 270) else pg.rect.width))
        log(f'page {n}: skew {skew_deg:+.2f} deg' + (' (straightened)' if skew_deg else ''))
        sc = 72.0 / (im['width'] / (im['bbox'][2] - im['bbox'][0]) * 72.0) if False else None
        wpt = pg.rect.height if pg.rotation in (90, 270) else pg.rect.width          # displayed width in pt
        pt_per_px = wpt / g.shape[1]
        t0 = time.time()
        # OCR works best at about 200 dpi (benchmark on rendered scans: numbers exact 0.79 at 400 dpi -> 0.87 at 200 dpi, 4x faster)
        gs = cv2.resize(g, None, fx=OCR_SCALE, fy=OCR_SCALE, interpolation=cv2.INTER_AREA)
        lines = eng.read_tiled(gs, tile=1000)
        for ln_ in lines:
            ln_.box = ln_.box / OCR_SCALE
        try:
            lines = eng.reread_short(g, lines)           # R-T11 / R-T12
        except Exception as e:
            log(f'reread skipped: {e}')
        try:                                              # R-T1..R-T10 second pass: isolated marks (B, L, #1 ...) the detector skips
            lines = list(lines) + eng.read_residual(g, [(l.box[:, 0].min(), l.box[:, 1].min(), l.box[:, 0].max(), l.box[:, 1].max(), l.text) for l in lines], dpi=72.0 / pt_per_px)
        except Exception as e:
            log(f'residual pass skipped: {e}')
        try:                                              # R-T14 digit extension (vertical text reads bottom -> top, the drawing-sheet convention)
            lines = eng.extend_digits(g, lines, dpi=72.0 / pt_per_px, vertical_up=True)
        except Exception as e:
            log(f'digit extension skipped: {e}')
        try:                                              # R-T15 / R-T16 numeric check against dimension chains
            from . import numcheck
            fx = numcheck.check(lines)
            if fx:
                log(f'numeric check: {len(fx)} number(s) repaired: ' + ', '.join(f'{a}->{b}' for a, b, _ in fx[:12]))
        except Exception as e:
            log(f'numeric check skipped: {e}')
        with open(os.path.join(outdir, f'{name}_p{n}_ocr_text.csv'), 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f); w.writerow(['text', 'x0', 'y0', 'x1', 'y1', 'score', 'vertical', 'engine'])
            for ln in sorted(lines, key=lambda l: (l.box[:, 1].min(), l.box[:, 0].min())):
                b = ln.box
                w.writerow([ln.text, round(b[:, 0].min() * pt_per_px, 2), round(b[:, 1].min() * pt_per_px, 2), round(b[:, 0].max() * pt_per_px, 2), round(b[:, 1].max() * pt_per_px, 2),
                            round(ln.score, 3), ln.vertical, eng.backend])
        log(f'OCR page {n}: {len(lines)} text lines in {time.time() - t0:.0f} s ({eng.backend})')
        res.append((n, len(lines), eng.backend))
        # ---- unify with the vector layout: OCR text spans + vectorised strokes are APPENDED to the page's text / paths / segments files (same columns, source = scan-*)
        from . import scanvec
        rinv = ~pg.rotation_matrix
        conv = [(ln.text.strip(), tuple(float(v) * 1.0 for v in (ln.box[:, 0].min() * pt_per_px, ln.box[:, 1].min() * pt_per_px, ln.box[:, 0].max() * pt_per_px, ln.box[:, 1].max() * pt_per_px)), ln.score, ln.vertical) for ln in lines if ln.text.strip()]
        tb = []
        for t_, (x0_, y0_, x1_, y1_), sc_, v_ in conv:
            a_ = pymupdf.Point(x0_, y0_) * rinv; b_ = pymupdf.Point(x1_, y1_) * rinv
            tb.append((min(a_.x, b_.x), min(a_.y, b_.y), max(a_.x, b_.x), max(a_.y, b_.y)))
        tmp_t = os.path.join(outdir, f'{name}_p{n}_text.csv')
        with open(tmp_t, 'a', newline='', encoding='utf-8') as ft:
            wt = csv.writer(ft)
            for (t_, (x0_, y0_, x1_, y1_), sc_, v_), (X0, Y0, X1, Y1) in zip(conv, tb):
                dd_ = pymupdf.Point(0, -1 if v_ else 1)
                dd_ = pymupdf.Point(dd_.x * rinv.a + dd_.y * rinv.c, dd_.x * rinv.b + dd_.y * rinv.d)
                wt.writerow([t_, round(X0, 2), round(Y0, 2), round(X1, 2), round(Y1, 2), round((min(x1_ - x0_, y1_ - y0_) if not v_ else (x1_ - x0_)) / 1.4, 2), 'OCR-' + eng.backend, 0, round(dd_.x, 3), round(dd_.y, 3), 0, 'scan-ocr', round(sc_, 3)])
        _vectorize_append(doc, pg, n, tb, outdir, name, log)
    return res


import csv


def _vectorize_append(doc, pg, n, tb, outdir, name, log):
    """pixels -> strokes, grouped into paths with fitted arcs (R-S9 / R-S10); APPENDED to the page's paths / segments files (source = scan-*).  The page image is straightened first (R-S7)."""
    from . import scanvec, scanpaths
    log(f'  page {n}: vectorising strokes ...')
    pw, ph = pg.mediabox.width, pg.mediabox.height
    gimg = scanvec.page_image(doc, pg)
    gimg, sk = scanvec.deskew(gimg)
    if sk:
        log(f'  page {n}: image straightened by {sk:+.2f} deg')
    segs = scanvec.vectorize_gray(gimg, pw, ph, text_boxes_pt=tb, log=log)
    paths, st = scanpaths.group(segs)
    npaths = sum(1 for _ in open(os.path.join(outdir, f'{name}_p{n}_paths.csv'), encoding='utf-8')) - 1
    with open(os.path.join(outdir, f'{name}_p{n}_paths.csv'), 'a', newline='', encoding='utf-8') as f1, open(os.path.join(outdir, f'{name}_p{n}_segments.csv'), 'a', newline='', encoding='utf-8') as f2:
        w1 = csv.writer(f1); w2 = csv.writer(f2)
        for q, p in enumerate(paths):
            k_ = npaths + q
            xs = [c[0] for _, pts in p['items'] for c in pts]; ys = [c[1] for _, pts in p['items'] for c in pts]
            w1.writerow([k_, 's', '0.000 0.000 0.000', '', p['w'], scanvec._dash_txt(p['dash']), p['closed'], round(min(xs), 2), round(min(ys), 2), round(max(xs), 2), round(max(ys), 2),
                         len(p['items']), ''.join(kd for kd, _ in p['items']), 'scan-' + p['src']])
            for kd, pts in p['items']:
                w2.writerow([k_, kd] + [round(v, 2) for c in pts for v in c])
    log(f'  page {n}: {st["segments"]} line pieces -> {st["paths"]} paths, {st["arcs"]} arcs')
    SCANSEG[n] = st['paths']


def revectorize(pdf, outdir, name, pages=None, log=print):
    """re-run ONLY the pixel -> path step of already OCR-read scanned pages (text boxes taken from <name>_pN_ocr_text.csv); the earlier scan paths are dropped first."""
    doc = pymupdf.open(pdf)
    for i, pg in enumerate(doc):
        n = i + 1
        fo = os.path.join(outdir, f'{name}_p{n}_ocr_text.csv')
        if (pages and n not in pages) or not os.path.exists(fo):
            continue
        rinv = ~pg.rotation_matrix
        tb = []
        for r in csv.DictReader(open(fo, encoding='utf-8')):
            if not r['text'].strip():
                continue
            a_ = pymupdf.Point(float(r['x0']), float(r['y0'])) * rinv; b_ = pymupdf.Point(float(r['x1']), float(r['y1'])) * rinv
            tb.append((min(a_.x, b_.x), min(a_.y, b_.y), max(a_.x, b_.x), max(a_.y, b_.y)))
        for suf in ('paths', 'segments'):                         # keep the rows that are not scan-made
            fp = os.path.join(outdir, f'{name}_p{n}_{suf}.csv')
            rows = list(csv.reader(open(fp, encoding='utf-8')))
            if suf == 'paths':
                keep = {r[0] for r in rows[1:] if not r[-1].startswith('scan-')}
                new = [rows[0]] + [r for r in rows[1:] if r[0] in keep]
            else:
                new = [rows[0]] + [r for r in rows[1:] if r[0] in keep]
            with open(fp, 'w', newline='', encoding='utf-8') as f:
                csv.writer(f).writerows(new)
        _vectorize_append(doc, pg, n, tb, outdir, name, log)


RAW = []
OCRR = []
SCANSEG = {}


def doc1(name, pages):
    L = [f'# STEP 1 (offline) - {name}: raw vector data read\n', 'Read by deckrules.read_drawing (pymupdf only, no OCR, no AI).\n', '| page | size pt | vector paths | words | images |', '|---|---|---|---|---|']
    for p in pages:
        L.append(f"| {p['n']} | {p['rect'].width:.0f} x {p['rect'].height:.0f} | {p['paths']} | {p['words']} | {p['images']} |")
    L.append('\n## ALL raw data written (rule R1: nothing interpreted)\n\n| page | text spans | vector paths | path items | files |\n|---|---|---|---|---|')
    for n_, nt_, np_, ns_ in RAW:
        L.append(f'| {n_} | {nt_} | {np_} | {ns_} | {name}_p{n_}_text.csv, _paths.csv, _segments.csv |')
    if OCRR:
        L.append('\n## OCR of scanned pages (offline RapidOCR / Tesseract)\n\n| page | text lines | engine | file |\n|---|---|---|---|')
        for n_, c_, e_ in OCRR:
            L.append(f'| {n_} | {c_} | {e_} | {name}_p{n_}_ocr_text.csv (also appended to _text.csv, source = scan-ocr); {SCANSEG.get(n_, 0)} vector segments from pixels appended to _paths.csv / _segments.csv (source = scan-*) |')
    for p in pages:
        L.append(f"\n## Page {p['n']}\n\nViews (title text, largest font), position x, y pt:")
        for t, x, y in p['titles']:
            L.append(f'- {t}  ({x:.0f}, {y:.0f})')
        if p['details']:
            L.append('- detail views: ' + '; '.join(p['details']))
        if p['notes']:
            L.append('\nPrinted notes, position, and the view the PROPOSED rule N1 (nearest title, UNCONFIRMED - owner corrects) gives:\n')
            L.append('| note | x, y | proposed view | distance pt |\n|---|---|---|---|')
            for t, x, y, v, d in p['notes']:
                L.append(f'| {t[:70]} | {x:.0f}, {y:.0f} | {v} | {d} |')
    return '\n'.join(L) + '\n'


def doc2(name, pages):
    L = [f'# STEP 2 (offline) - {name}: scale calibration\n', 'Each printed dimension chain (a row of 3-4 digit numbers) is matched with the pt distance between its numbers; scale = mm per pt.\n']
    for p in pages:
        L.append(f"## Page {p['n']}")
        if p['chains']:
            L.append('| chain y (pt) | numbers | x from..to (pt) | sum of dims (mm) | scale mm/pt | values |\n|---|---|---|---|---|---|')
            for c in p['chains']:
                L.append(f"| {c['y']} | {c['n']} | {c['x0']:.0f}..{c['x1']:.0f} | {c['mm']:.0f} | {c['scale']:.2f}{' (cumulative values - NOT a spacing chain, ignored)' if c['cum'] else ''} | {c['set'][:8]} |")
            sc = [c['scale'] for c in p['chains'] if not c['cum']] or [0.0]
            L.append(f"\nscale spread on this page: {min(sc):.2f} .. {max(sc):.2f} mm/pt" + ('  (consistent)' if max(sc) - min(sc) < 0.1 else '  (DIFFERENT scales - views differ)'))
        else:
            L.append('no dimension chain found')
        L.append('frame labels: ' + (', '.join(f'{a} ({b},{c})' for a, b, c in p['frames']) or 'none'))
        L.append('')
    return '\n'.join(L)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf'); ap.add_argument('--out', default='.')
    ap.add_argument('--ocr-pages', default='', help='scanned pages: OCR only these page numbers (comma list); default all scanned pages')
    ap.add_argument('--no-ocr', action='store_true')
    ap.add_argument('--revectorize', action='store_true', help='only redo the pixel -> path step of an earlier run in --out')
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    nm = os.path.splitext(os.path.basename(a.pdf))[0]
    pages = read(a.pdf)
    if a.revectorize:
        revectorize(a.pdf, a.out, nm, log=print)
        cnt = lambda suf, n: sum(1 for _ in open(os.path.join(a.out, f'{nm}_p{n}_{suf}.csv'), encoding='utf-8')) - 1
        RAW[:] = [(n, cnt('text', n), cnt('paths', n), cnt('segments', n)) for n in range(1, len(pages) + 1)]
        OCRR[:] = [(n, cnt('ocr_text', n), 'rapid') for n in range(1, len(pages) + 1) if os.path.exists(os.path.join(a.out, f'{nm}_p{n}_ocr_text.csv'))]
        for k, f in (('step1_raw_data', doc1), ('step2_calibration', doc2)):
            fp = os.path.join(a.out, f'{nm}_{k}.md'); open(fp, 'w', encoding='utf-8').write(f(nm, pages)); print('wrote', fp)
        return
    RAW[:] = dump_raw(a.pdf, a.out, nm)
    if not a.no_ocr:
        OCRR[:] = ocr_scanned(a.pdf, a.out, nm, pages=[int(x) for x in a.ocr_pages.split(',') if x])
    from . import textnorm                      # R-T17..R-T19: label normalisation (vector and scan)
    print('textnorm changes:', textnorm.fix_folder(a.out, nm))
    for k, f in (('step1_raw_data', doc1), ('step2_calibration', doc2)):
        fp = os.path.join(a.out, f'{nm}_{k}.md'); open(fp, 'w', encoding='utf-8').write(f(nm, pages)); print('wrote', fp)


if __name__ == '__main__':
    main()
