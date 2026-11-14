"""Scanned page -> the SAME step-1 data as a vector page (owner 2026-10-24: "scanned PDF should be 100 % like vector PDF").
Pixels are turned into text spans (offline OCR) and straight vector segments (strokes by morphology + Hough, dash merge, ring outlines), written with the
SAME columns as the vector extraction:  <name>_pN_text.csv, _paths.csv, _segments.csv  (+ provenance columns source / score).  Coordinates are in the PDF's own
page space (unrotated pt), exactly like the vector reader.  evaluate_vs_vector() measures how close the scan result is to the true vector data of the same drawing."""
import csv
import math
import os
import numpy as np
import cv2
import pymupdf
from . import raster_front as rf

USE_BLOB = True
ZOOM = 3.0            # working resolution (216 dpi) the stroke finder was tuned for


def page_image(doc, pg):
    """the page's big embedded image as uint8 gray (0 = ink), unrotated, + its size in pt (page space)"""
    area = pg.rect.width * pg.rect.height
    big = [im for im in pg.get_image_info(xrefs=True) if (im['bbox'][2] - im['bbox'][0]) * (im['bbox'][3] - im['bbox'][1]) >= 0.8 * area]
    if not big:
        return None
    pix = pymupdf.Pixmap(doc, big[0]['xref'])
    if pix.n - pix.alpha > 1:
        pix = pymupdf.Pixmap(pymupdf.csGRAY, pix)
    g = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)[:, :, 0].copy()
    if g.max() <= 1:
        g = g * 255
    return g


def _remove_glyphs(B, tm):
    """remove only the GLYPH components (connected ink lying completely inside a text box); lines that run through / past a text box are longer than the box,
    stay in one component and are kept (a plain rectangle mask would cut them out: 15 % of the true line length lies inside text boxes)."""
    n, lab, st, _ = cv2.connectedComponentsWithStats(B, connectivity=8)
    if n <= 1:
        return B
    ii = cv2.integral((tm > 0).astype(np.uint8))
    x, y, w, h = st[:, 0], st[:, 1], st[:, 2], st[:, 3]
    x1, y1 = x + w, y + h
    cover = (ii[y1, x1] - ii[y, x1] - ii[y1, x] + ii[y, x]).astype(np.float64) / np.maximum(w * h, 1)
    kill = cover >= 0.98                                    # whole bounding box inside text boxes
    kill[0] = False
    return np.where(kill[lab], 0, B).astype(np.uint8)


def merge_collinear(segs, ang_tol_deg=1.0, off_tol_pt=0.5, gap_pt=1.0):
    """join pieces of the same straight line (same direction, same offset, touching or a gap <= gap_pt) into ONE segment; dashed pieces (carrying a dash signature) are kept apart."""
    solid = [q for q in segs if not q['dash']]
    keep = [q for q in segs if q['dash']]
    buckets = {}
    for q in solid:
        (ax, ay), (bx, by) = q['a'], q['b']
        th = math.atan2(by - ay, bx - ax) % math.pi
        if th > math.pi - 1e-9:
            th = 0.0
        nx, ny = -math.sin(th), math.cos(th)
        off = ax * nx + ay * ny
        key = (int(round(math.degrees(th) / ang_tol_deg)) % int(180 / ang_tol_deg), int(round(off / off_tol_pt)))
        buckets.setdefault(key, []).append((th, ax * math.cos(th) + ay * math.sin(th), bx * math.cos(th) + by * math.sin(th), q['w'], q['kind']))
    out = list(keep)
    for (kb, ko), items in buckets.items():
        th = float(np.mean([i[0] for i in items])) if max(i[0] for i in items) - min(i[0] for i in items) < 0.5 else items[0][0]
        c, sn = math.cos(th), math.sin(th)
        nx, ny = -sn, c
        off = float(np.mean([ (q[1] * 0) for q in items]))
        iv = sorted((min(i[1], i[2]), max(i[1], i[2]), i[3], i[4]) for i in items)
        cur = list(iv[0])
        ws = [cur[2]]
        def emit(a, b, w, kind):
            offs = ko * off_tol_pt
            out.append(dict(a=(a * c + offs * nx, a * sn + offs * ny), b=(b * c + offs * nx, b * sn + offs * ny), w=round(float(np.median(w)), 2), dash='', kind=kind))
        for a, b, w, kind in iv[1:]:
            if a <= cur[1] + gap_pt:
                cur[1] = max(cur[1], b); ws.append(w)
            else:
                emit(cur[0], cur[1], ws, cur[3]); cur = [a, b, w, kind]; ws = [w]
        emit(cur[0], cur[1], ws, cur[3])
    return out


def _blob_outlines(Bt, zoom, min_thick_pt=2.3):
    """outer outline of FILLED shapes (solid arrowheads, filled rectangles): ink that survives an opening wider than a line.  Holes are handled by _rings; outer
    boundaries of thin line work are not outlines (the line itself is found by the stroke finder)."""
    k = max(3, int(round(min_thick_pt * zoom)) | 1)
    core = cv2.morphologyEx(Bt, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    if not core.any():
        return []
    cnts, _ = cv2.findContours(core, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    out = []
    for c in cnts:
        if cv2.contourArea(c) < (k * k) * 0.8:
            continue
        ap = cv2.approxPolyDP(c, 0.35 * zoom * 0.5, True)[:, 0, :].astype(float)
        if len(ap) >= 3:
            out.append((ap + 0.5) / zoom)
    return out


class SegList(list):
    """list of segments that also carries the closed contours (rings / filled outlines) they came from (for path grouping + arc fitting)"""
    contours = ()


def vectorize_gray(gray, pt_w, pt_h, text_boxes_pt=(), zoom=ZOOM, log=print):
    """gray: uint8 image covering pt_w x pt_h pt (unrotated).  -> list of dict(a, b, w, dash)  (pt)"""
    W = int(round(pt_w * zoom)); H = int(round(pt_h * zoom))
    G = cv2.resize(gray, (W, H), interpolation=cv2.INTER_AREA) if gray.shape[1] != W else gray
    dark = 255 - G
    B = (G < 175).astype(np.uint8) * 255
    tm = np.zeros_like(B)
    for x0, y0, x1, y1 in text_boxes_pt:                         # glyph strokes are text, not geometry
        cv2.rectangle(tm, (int(x0 * zoom) - 1, int(y0 * zoom) - 1), (int(x1 * zoom) + 1, int(y1 * zoom) + 1), 255, -1)
    Bt = _remove_glyphs(B, tm)
    out = []
    hv = np.zeros_like(B)
    for vertical in (False, True):
        st = rf._strokes(Bt, dark, zoom, vertical)
        for d in rf._merge_dashes(st, vertical, zoom):
            out.append(dict(a=tuple(d['a']), b=tuple(d['b']), w=round(d['w'], 2), dash=d['dash'], kind='hv'))
            cv2.line(hv, (int(d['a'][0] * zoom), int(d['a'][1] * zoom)), (int(d['b'][0] * zoom), int(d['b'][1] * zoom)), 255, 3)
    log(f'  strokes H/V: {len(out)}')
    nobl = len(out)
    for a, b in rf._oblique(Bt, hv, zoom):
        out.append(dict(a=a, b=b, w=0.36, dash='', kind='obl'))
    log(f'  oblique: {len(out) - nobl}')
    nr = len(out)
    contours = []
    for pts, wid in rf._rings(Bt, dark, zoom):
        contours.append((pts, round(wid, 2), 'ring'))
        for i in range(len(pts)):
            out.append(dict(a=tuple(pts[i]), b=tuple(pts[(i + 1) % len(pts)]), w=round(wid, 2), dash='', kind='ring'))
    log(f'  ring edges: {len(out) - nr}')
    nb = len(out)
    for pts in (_blob_outlines(Bt, zoom) if USE_BLOB else []):
        contours.append((pts, 0.36, 'blob'))
        for i in range(len(pts)):
            out.append(dict(a=tuple(pts[i]), b=tuple(pts[(i + 1) % len(pts)]), w=0.36, dash='', kind='blob'))
    log(f'  filled-shape outline edges: {len(out) - nb}')
    n0 = len(out)
    out = merge_collinear(out)
    log(f'  collinear pieces merged: {n0} -> {len(out)}')
    out = SegList(out)
    out.contours = contours
    return out


def _dash_txt(sig):
    if not sig:
        return ''
    v = sig.split(':')[1].replace(',', ' ')
    return f'[ {v} ] 0'


def write_segments(segs, outdir, name, n):
    """R-S9 / R-S10: loose segments are grouped into paths (polylines / closed outlines) and arcs are fitted (kind 'c'), like the paths of a vector PDF."""
    from . import scanpaths
    paths, st = scanpaths.group(segs)
    with open(os.path.join(outdir, f'{name}_p{n}_paths.csv'), 'w', newline='', encoding='utf-8') as f1, open(os.path.join(outdir, f'{name}_p{n}_segments.csv'), 'w', newline='', encoding='utf-8') as f2:
        w1 = csv.writer(f1); w2 = csv.writer(f2)
        w1.writerow(['path', 'type', 'stroke_rgb', 'fill_rgb', 'width', 'dash', 'closed', 'x0', 'y0', 'x1', 'y1', 'items', 'kinds', 'source'])
        w2.writerow(['path', 'kind', 'x1', 'y1', 'x2', 'y2', 'x3', 'y3', 'x4', 'y4'])
        for k, p in enumerate(paths):
            xs = [q[0] for _, pts in p['items'] for q in pts]; ys = [q[1] for _, pts in p['items'] for q in pts]
            w1.writerow([k, 's', '0.000 0.000 0.000', '', p['w'], _dash_txt(p['dash']), p['closed'], round(min(xs), 2), round(min(ys), 2), round(max(xs), 2), round(max(ys), 2),
                         len(p['items']), ''.join(kd for kd, _ in p['items']), 'scan-' + p['src']])
            for kd, pts in p['items']:
                w2.writerow([k, kd] + [round(v, 2) for q in pts for v in q])
    return st


def write_text(lines, rot_inv, outdir, name, n, engine):
    """lines: OCR lines with box in DISPLAY pt; rot_inv maps display pt -> page-space pt."""
    with open(os.path.join(outdir, f'{name}_p{n}_text.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['text', 'x0', 'y0', 'x1', 'y1', 'size', 'font', 'color', 'dir_x', 'dir_y', 'flags', 'source', 'score'])
        for t, (x0, y0, x1, y1), sc, vert in lines:
            p = [pymupdf.Point(x0, y0) * rot_inv, pymupdf.Point(x1, y1) * rot_inv]
            X0, X1 = sorted((p[0].x, p[1].x)); Y0, Y1 = sorted((p[0].y, p[1].y))
            d = pymupdf.Point(0, -1 if vert else 1)
            d = pymupdf.Point(d.x * rot_inv.a + d.y * rot_inv.c, d.x * rot_inv.b + d.y * rot_inv.d)
            size = min(x1 - x0, y1 - y0) / 1.4 if not vert else (x1 - x0) / 1.4
            w.writerow([t, round(X0, 2), round(Y0, 2), round(X1, 2), round(Y1, 2), round(size, 2), 'OCR-' + engine, 0, round(d.x, 3), round(d.y, 3), 0, 'scan-ocr', round(sc, 3)])


def mask_of(segs, W, H, zoom, tol_px=2):
    m = np.zeros((H, W), np.uint8)
    for s in segs:
        cv2.line(m, (int(s['a'][0] * zoom), int(s['a'][1] * zoom)), (int(s['b'][0] * zoom), int(s['b'][1] * zoom)), 255, 1)
    return m, cv2.dilate(m, np.ones((2 * tol_px + 1, 2 * tol_px + 1), np.uint8))


def vector_truth(pg, crop=None):
    """true segments of a vector page (lines, rect / quad edges, curve chords) in page pt, optionally clipped to crop"""
    out = []
    white = lambda c: c is not None and all(v > 0.97 for v in c)
    for d in pg.get_drawings():
        sc, fc = d.get('color'), d.get('fill')
        if not ((sc is not None and not white(sc)) or (fc is not None and not white(fc))):
            continue                                            # invisible (white / no ink): a scan cannot show it
        for it in d['items']:
            pts = []
            if it[0] == 'l':
                pts = [(it[1], it[2])]
            elif it[0] == 're':
                r = it[1]; pts = [(pymupdf.Point(r.x0, r.y0), pymupdf.Point(r.x1, r.y0)), (pymupdf.Point(r.x1, r.y0), pymupdf.Point(r.x1, r.y1)),
                                  (pymupdf.Point(r.x1, r.y1), pymupdf.Point(r.x0, r.y1)), (pymupdf.Point(r.x0, r.y1), pymupdf.Point(r.x0, r.y0))]
            elif it[0] == 'qu':
                q = it[1]; pts = [(q.ul, q.ur), (q.ur, q.lr), (q.lr, q.ll), (q.ll, q.ul)]
            elif it[0] == 'c':
                P = [it[1], it[2], it[3], it[4]]
                bz = lambda t: pymupdf.Point(*[(1 - t) ** 3 * P[0][k] + 3 * (1 - t) ** 2 * t * P[1][k] + 3 * (1 - t) * t * t * P[2][k] + t ** 3 * P[3][k] for k in ('x', 'y')]) if False else pymupdf.Point(
                    (1 - t) ** 3 * P[0].x + 3 * (1 - t) ** 2 * t * P[1].x + 3 * (1 - t) * t * t * P[2].x + t ** 3 * P[3].x,
                    (1 - t) ** 3 * P[0].y + 3 * (1 - t) ** 2 * t * P[1].y + 3 * (1 - t) * t * t * P[2].y + t ** 3 * P[3].y)
                pts = [(bz(i / 6.0), bz((i + 1) / 6.0)) for i in range(6)]
            for a, b in pts:
                out.append(dict(a=(a.x, a.y), b=(b.x, b.y), w=d.get('width') or 0.36, kind=it[0], dash=bool(d.get('dashes') and d.get('dashes') not in ('[] 0', '[ ] 0')),
                                fill=d.get('type', '') == 'f'))
    if crop:
        x0, y0, x1, y1 = crop
        cl = []
        for q in out:                                            # clip to the crop (a line leaving the crop is still in the scan crop)
            (ax, ay), (bx, by) = q['a'], q['b']
            dx, dy = bx - ax, by - ay
            t0, t1 = 0.0, 1.0
            ok = True
            for pp, qq in ((-dx, ax - x0), (dx, x1 - ax), (-dy, ay - y0), (dy, y1 - ay)):
                if abs(pp) < 1e-12:
                    if qq < 0:
                        ok = False; break
                else:
                    r = qq / pp
                    if pp < 0:
                        t0 = max(t0, r)
                    else:
                        t1 = min(t1, r)
            if ok and t0 < t1:
                cl.append(dict(q, a=(ax + dx * t0, ay + dy * t0), b=(ax + dx * t1, ay + dy * t1)))
        out = cl
    return out


def render_scan_like(pg, crop, dpi=400.0):
    """simulate a scan of a vector page region: 1-bit, unrotated (page space) image of crop (page-space Rect)."""
    rot = pg.rotation
    cr = crop * pg.rotation_matrix
    pix = pg.get_pixmap(matrix=pymupdf.Matrix(dpi / 72, dpi / 72), clip=cr, colorspace=pymupdf.csGRAY, alpha=False)
    g = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width).copy()
    k = {90: 1, 180: 2, 270: -1}.get(rot, 0)
    if k:
        g = np.ascontiguousarray(np.rot90(g, k))
    return np.where(g >= 128, 255, 0).astype(np.uint8)


def evaluate_vs_vector(pdf, page_no, crop, dpi=400.0, log=print, text_boxes=None):
    """recall / precision (length-weighted, tolerance 2 px at 216 dpi = 0.67 pt) of the scan-vectoriser against the TRUE vector data of the same region."""
    doc = pymupdf.open(pdf); pg = doc[page_no]
    crop = pymupdf.Rect(*crop)
    g = render_scan_like(pg, crop, dpi)
    if text_boxes is None:                                   # default: the glyph areas of the vector text (= a perfect OCR); pass [] for none
        text_boxes = [(b[0] - crop.x0, b[1] - crop.y0, b[2] - crop.x0, b[3] - crop.y0) for b in (pg.get_text('words', clip=crop * 1.0))]
        text_boxes = [(w[0], w[1], w[2], w[3]) for w in text_boxes]
    segs = vectorize_gray(g, crop.width, crop.height, text_boxes_pt=text_boxes, log=log)
    gt = [dict(a=(s['a'][0] - crop.x0, s['a'][1] - crop.y0), b=(s['b'][0] - crop.x0, s['b'][1] - crop.y0), w=s['w']) for s in vector_truth(pg, tuple(crop))]
    W, H = int(crop.width * ZOOM), int(crop.height * ZOOM)
    mg, dg = mask_of(gt, W, H, ZOOM); md, dd = mask_of(segs, W, H, ZOOM)
    return dict(gt_segments=len(gt), det_segments=len(segs), recall=float((mg & dd).sum()) / max(int(mg.sum()), 1), precision=float((md & dg).sum()) / max(int(md.sum()), 1)), segs, gt


def estimate_skew(gray, max_deg=2.0, step=0.05):
    """R-S7: skew of a scanned sheet in degrees (rotate by -angle to straighten).  Projection-profile method on a 1/4 size binary image: at the right angle the long horizontal / vertical
    strokes of a drawing fall into few rows / columns, so the variance of the row + column sums is maximal.  Coarse step 0.25 deg then fine step on a band."""
    h, w = gray.shape[:2]
    f = 0.25 if max(h, w) > 3000 else 1.0
    small = cv2.resize(255 - gray, None, fx=f, fy=f, interpolation=cv2.INTER_AREA) if f != 1.0 else 255 - gray
    small = (small > 90).astype(np.float32)
    c = (small.shape[1] / 2.0, small.shape[0] / 2.0)

    def score(a):
        M = cv2.getRotationMatrix2D(c, a, 1.0)
        r = cv2.warpAffine(small, M, (small.shape[1], small.shape[0]), flags=cv2.INTER_LINEAR)
        return float(np.var(r.sum(1)) + np.var(r.sum(0)))
    coarse = np.arange(-max_deg, max_deg + 1e-9, 0.25)
    sc = [score(a) for a in coarse]
    a0 = float(coarse[int(np.argmax(sc))])
    fine = np.arange(a0 - 0.25, a0 + 0.25 + 1e-9, step)
    sf = [score(a) for a in fine]
    return float(fine[int(np.argmax(sf))])


def deskew(gray, min_deg=0.08):
    """-> (straightened image, angle).  Angles below min_deg are left alone (a rotation costs a little sharpness)."""
    a = estimate_skew(gray)
    if abs(a) < min_deg:
        return gray, 0.0
    h, w = gray.shape[:2]
    M = cv2.getRotationMatrix2D((w / 2.0, h / 2.0), a, 1.0)
    return cv2.warpAffine(gray, M, (w, h), flags=cv2.INTER_LINEAR, borderValue=255), a


def despeckle(gray, dpi=400.0, max_pt=0.35):
    """banded (a 400 Mpx page would need GBs for the labelling)"""
    H = gray.shape[0]
    if H <= 5000:
        return _despeckle(gray, dpi, max_pt)
    out = np.empty_like(gray)
    for y in range(0, H, 4000):
        y0, y1 = max(y - 20, 0), min(y + 4000 + 20, H)
        r = _despeckle(np.ascontiguousarray(gray[y0:y1]), dpi, max_pt)
        out[y:min(y + 4000, H)] = r[y - y0:y - y0 + min(4000, H - y)]
    return out


def _despeckle(gray, dpi=400.0, max_pt=0.35):
    """R-S8: scanner dust.  Black components smaller than a 0.35 pt square that touch nothing are removed (a full stop is ~0.8 pt, a dash piece much larger)."""
    B = (gray < 128).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(B, connectivity=8)
    lim = (max_pt * dpi / 72.0) ** 2
    small = (st[:, 4] < lim) & (np.maximum(st[:, 2], st[:, 3]) < 2.5 * max_pt * dpi / 72.0)
    small[0] = False
    if not small.any():
        return gray
    kill = small[lab]
    out = gray.copy(); out[kill] = 255
    return out
