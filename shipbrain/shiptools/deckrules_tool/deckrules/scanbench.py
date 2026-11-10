"""Scan-vectoriser benchmark (owner 2026-10-24): turn VECTOR pdfs into 400 dpi 1-bit 'scans', run the offline scan->vector tool, compare with the true vector data and
list WHERE it fails (by width, dash, angle, length, kind).  python -m deckrules.scanbench PDF [PDF ...] --pages 1,2 --crops 2 --out report.md"""
import argparse
import collections
import math
import os
import numpy as np
import cv2
import pymupdf
from . import scanvec as sv

CW, CH = 900.0, 700.0


def pick_crops(pg, n):
    """n non-overlapping CWxCH windows (page space) with the most vector ink"""
    R = pg.mediabox
    gx, gy = int(R.width // 150) + 1, int(R.height // 150) + 1
    hist = np.zeros((gy, gx))
    for d in pg.get_drawings():
        r = d['rect']
        hist[min(int(r.y0 // 150), gy - 1), min(int(r.x0 // 150), gx - 1)] += 1
    out = []
    best = []
    for iy in range(gy):
        for ix in range(gx):
            x0, y0 = ix * 150.0, iy * 150.0
            if x0 + CW > R.width or y0 + CH > R.height:
                continue
            sc = hist[iy:iy + int(CH // 150), ix:ix + int(CW // 150)].sum()
            best.append((sc, x0, y0))
    for sc, x0, y0 in sorted(best, reverse=True):
        if sc <= 0:
            break
        if all(abs(x0 - a) >= CW or abs(y0 - b) >= CH for a, b in out):
            out.append((x0, y0))
        if len(out) >= n:
            break
    return out


def classify(s):
    L = math.dist(s['a'], s['b'])
    ang = abs(math.degrees(math.atan2(s['b'][1] - s['a'][1], s['b'][0] - s['a'][0]))) % 90
    obl = min(ang, 90 - ang) > 3
    return dict(len='<3pt' if L < 3 else '3-10pt' if L < 10 else '10-50pt' if L < 50 else '>50pt',
                width='thin<0.3' if s['w'] < 0.3 else 'mid0.3-0.7' if s['w'] < 0.7 else 'thick>=0.7',
                dash='dashed' if s.get('dash') else 'solid', angle='oblique' if obl else 'H/V',
                kind={'l': 'line', 're': 'rect edge', 'qu': 'quad edge', 'c': 'curve chord'}.get(s.get('kind'), '?'))


def run_crop(pg, crop, log=lambda *a: None):
    cr = pymupdf.Rect(crop[0], crop[1], crop[0] + CW, crop[1] + CH)
    g = sv.render_scan_like(pg, cr, 400.0)
    tb = [(w[0] - cr.x0, w[1] - cr.y0, w[2] - cr.x0, w[3] - cr.y0) for w in pg.get_text('words', clip=cr)]
    segs = sv.vectorize_gray(g, cr.width, cr.height, text_boxes_pt=tb, log=log)
    gt = [dict(s, a=(s['a'][0] - cr.x0, s['a'][1] - cr.y0), b=(s['b'][0] - cr.x0, s['b'][1] - cr.y0)) for s in sv.vector_truth(pg, tuple(cr))]
    return segs, gt, tb


def evaluate(segs, gt, tb, z=sv.ZOOM):
    W, H = int(CW * z), int(CH * z)
    _, dd = sv.mask_of(segs, W, H, z)
    md, _ = sv.mask_of(segs, W, H, z)
    tm0 = np.zeros((H, W), np.uint8)
    for x0, y0, x1, y1 in tb:
        cv2.rectangle(tm0, (int(x0 * z) - 1, int(y0 * z) - 1), (int(x1 * z) + 1, int(y1 * z) + 1), 255, -1)
    gt_all = gt
    gt = [q for q in gt if not tm0[min(max(int((q['a'][1] + q['b'][1]) / 2 * z), 0), H - 1), min(max(int((q['a'][0] + q['b'][0]) / 2 * z), 0), W - 1)]]   # text glyph outlines are the OCR's job
    mg, _unused = sv.mask_of(gt, W, H, z)
    _unused2, dg = sv.mask_of(gt_all, W, H, z)
    rec = float(((mg > 0) & (dd > 0)).sum()) / max(int((mg > 0).sum()), 1)
    pre = float(((md > 0) & (dg > 0)).sum()) / max(int((md > 0).sum()), 1)
    tm = np.zeros((H, W), np.uint8)
    for x0, y0, x1, y1 in tb:
        cv2.rectangle(tm, (int(x0 * z) - 1, int(y0 * z) - 1), (int(x1 * z) + 1, int(y1 * z) + 1), 255, -1)
    def frac(q, mask):
        n = max(int(math.dist(q['a'], q['b']) * z), 1) + 1
        t = np.linspace(0, 1, n)
        xs = np.clip(((q['a'][0] + (q['b'][0] - q['a'][0]) * t) * z).astype(int), 0, W - 1)
        ys = np.clip(((q['a'][1] + (q['b'][1] - q['a'][1]) * t) * z).astype(int), 0, H - 1)
        return n, int((mask[ys, xs] > 0).sum())
    cls = collections.defaultdict(lambda: [0, 0])
    for s_ in gt:
        n, ok = frac(s_, dd)
        for k, v in classify(s_).items():
            cls[f'{k}={v}'][0] += n; cls[f'{k}={v}'][1] += ok
    fk = collections.defaultdict(lambda: [0, 0])
    for q in segs:
        n, ok = frac(q, dg)
        fk[q['kind']][0] += n; fk[q['kind']][1] += ok
    return rec, pre, cls, fk


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('pdfs', nargs='+'); ap.add_argument('--pages', default='1'); ap.add_argument('--crops', type=int, default=2); ap.add_argument('--out', default='scanbench.md')
    a = ap.parse_args(argv)
    rows, CLS, FK = [], collections.defaultdict(lambda: [0, 0]), collections.defaultdict(lambda: [0, 0])
    for pdf in a.pdfs:
        doc = pymupdf.open(pdf)
        for pn in [int(x) for x in a.pages.split(',')]:
            if pn > len(doc):
                continue
            pg = doc[pn - 1]
            for crop in pick_crops(pg, a.crops):
                segs, gt, tb = run_crop(pg, crop)
                if not gt:
                    continue
                rec, pre, cls, fk = evaluate(segs, gt, tb)
                rows.append((os.path.basename(pdf)[:28], pn, crop, len(gt), len(segs), rec, pre))
                for k, v in cls.items():
                    CLS[k][0] += v[0]; CLS[k][1] += v[1]
                for k, v in fk.items():
                    FK[k][0] += v[0]; FK[k][1] += v[1]
                print(rows[-1], flush=True)
    L = ['# Scan vectoriser benchmark (vector pdfs rendered as 400 dpi 1-bit scans, perfect text masking)\n', '| pdf | page | crop (x,y pt) | true segs | found segs | recall | precision |', '|---|---|---|---|---|---|---|']
    for r in rows:
        L.append(f'| {r[0]} | {r[1]} | {r[2][0]:.0f},{r[2][1]:.0f} | {r[3]} | {r[4]} | {r[5]:.3f} | {r[6]:.3f} |')
    if rows:
        L.append(f'\n**mean recall {np.mean([r[5] for r in rows]):.3f}, mean precision {np.mean([r[6] for r in rows]):.3f}** over {len(rows)} crops\n')
    L.append('\n## Recall by class of TRUE line (pixel length weighted)\n\n| class | recall | true px |\n|---|---|---|')
    for k, v in sorted(CLS.items()):
        L.append(f'| {k} | {v[1] / max(v[0], 1):.3f} | {v[0]} |')
    L.append('\n## Precision by detector kind\n\n| kind | precision | found px |\n|---|---|---|')
    for k, v in sorted(FK.items()):
        L.append(f'| {k} | {v[1] / max(v[0], 1):.3f} | {v[0]} |')
    open(a.out, 'w').write('\n'.join(L))
    print('\n'.join(L[-40:]))


if __name__ == '__main__':
    main()
