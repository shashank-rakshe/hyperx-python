"""Raster front end: scanned / image-only / outlined-text drawing -> the same Page
object that pdfsrc.load_page returns, so every rule runs unchanged.

  text   offline OCR (ocr.py), tiled, vertical text handled
  lines  horizontal / vertical strokes by morphological opening, oblique by Hough;
         line weight = ink coverage across the stroke (relative thin/thick is what
         the rules use, so it survives scanning)
  dashes collinear strokes with a regular on/off pattern are merged into ONE dashed
         line carrying the same 'dash2:on,off' / 'dash4:..' signature as vector input
  rings  inner outlines of closed shapes (circles, radiused cut-outs), with their weight

Everything is measured in page points: pt = pixel / zoom (zoom = dpi / 72).
"""
from . import textnorm as _tn
from . import fourier as _F
import math
import numpy as np
import cv2
from .pdfsrc import Page, Seg, Word

MIN_RUN_PT = 2.5            # shortest stroke kept (letters and ticks are shorter)


def load_gray(path, page_no=0, zoom=3.0):
    """-> (gray uint8, zoom).  PDF pages are rendered; image files use zoom = dpi/72."""
    if path.lower().endswith('.pdf'):
        import pymupdf
        p = pymupdf.open(path)[page_no]
        pix = p.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), colorspace=pymupdf.csGRAY, alpha=False)
        return np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width).copy(), zoom
    g = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if g is None:
        raise ValueError('cannot read image ' + path)
    return g, zoom


def _strokes(B, dark, z, vertical):
    """straight strokes of one orientation -> list of (a, b, width_pt) in pt."""
    if vertical:
        B, dark = B.T, dark.T
    L = max(5, int(round(MIN_RUN_PT * z)))
    M = cv2.morphologyEx(B, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (L, 1)))
    n, lab, st, _ = cv2.connectedComponentsWithStats(M, connectivity=8)
    out = []
    H = B.shape[0]
    for i in range(1, n):
        x, y, w, h, _a = st[i]
        if h > 6 * z:                                   # a blob, not a stroke
            continue
        y0, y1 = max(y - 1, 0), min(y + h + 1, H)
        prof = dark[y0:y1, x:x + w].astype(np.float32).sum(axis=1)
        tot = float(prof.sum())
        if tot <= 0:
            continue
        yc = y0 + 0.5 + float((prof * np.arange(len(prof))).sum() / tot)
        wid = tot / 255.0 / w / z
        a, b = (x / z, yc / z), ((x + w) / z, yc / z)
        if vertical:
            a, b = (a[1], a[0]), (b[1], b[0])
        out.append([a, b, wid])
    return out


def _merge_dashes(strokes, vertical, z, img=None):
    """group collinear strokes that repeat with a regular gap into one dashed line."""
    k = 1 if not vertical else 0                          # coordinate that is constant along the line
    t = 0 if not vertical else 1                          # coordinate along the line
    strokes = sorted(strokes, key=lambda s: (round(s[0][k] * z / 1.5), s[0][t]))
    out, i = [], 0
    while i < len(strokes):
        j = i + 1
        row = [strokes[i]]
        while j < len(strokes) and abs(strokes[j][0][k] - strokes[i][0][k]) * z < 1.6:
            row.append(strokes[j])
            j += 1
        i = j
        row.sort(key=lambda s: s[0][t])
        run = [row[0]]
        runs = []
        for s in row[1:]:
            gap = s[0][t] - run[-1][1][t]
            if 0.4 <= gap <= 9.0 and abs(s[2] - run[-1][2]) < 0.35 * max(s[2], run[-1][2], 0.2):
                run.append(s)
            else:
                runs.append(run)
                run = [s]
        runs.append(run)
        for r in runs:
            if len(r) >= 3:
                lens = [s[1][t] - s[0][t] for s in r]
                gaps = [r[q + 1][0][t] - r[q][1][t] for q in range(len(r) - 1)]
                if len(set(round(g / 1.2) for g in gaps)) > 3 and np.std(gaps) > 0.5 * np.mean(gaps):
                    per = _fft_dash(img, r, vertical, z) if img is not None else None
                    if per:                                # R-FT2: gaps irregular (faded scan) but the ink has ONE period -> dashed
                        out.append(dict(a=r[0][0], b=r[-1][1], w=float(np.median([s[2] for s in r])), dash='dash2:%.1f,%.1f' % per))
                        continue
                    out += [dict(a=s[0], b=s[1], w=s[2], dash='') for s in r]
                    continue
                longs = [x for x in lens if x > 10.0]
                if len(longs) >= 2 and len(longs) < len(lens):          # long-short chain line
                    sig = 'dash4:%.1f,%.1f,%.1f,%.1f' % (np.median(longs), np.median(gaps),
                                                         np.median([x for x in lens if x <= 10.0]), np.median(gaps))
                else:
                    sig = 'dash2:%.1f,%.1f' % (np.median(lens), np.median(gaps))
                out.append(dict(a=r[0][0], b=r[-1][1], w=float(np.median([s[2] for s in r])), dash=sig))
            else:
                out += [dict(a=s[0], b=s[1], w=s[2], dash='') for s in r]
    return out



def _fft_dash(img, run, vertical, z):
    """R-FT2: ink profile along the run (1 px band) -> (dash_pt, gap_pt) when the 1D FFT shows one clear period, else None"""
    t = 1 if vertical else 0
    a, b = run[0][0], run[-1][1]
    c = (a[0] if vertical else a[1]) * z
    lo, hi = int(a[t] * z), int(b[t] * z)
    ci = int(round(c))
    if hi - lo < 30:
        return None
    band = img[lo:hi, max(ci - 1, 0):ci + 2] if vertical else img[max(ci - 1, 0):ci + 2, lo:hi]
    prof = (band.max(axis=1 if vertical else 0) > 0).astype(np.float32)
    per, strength, ink = _F.line_period(prof, min_p=max(4, int(1.5 * z)), max_p=int(40 * z))
    if not per or ink > 0.9 or ink < 0.2:
        return None
    return per * ink / z, per * (1 - ink) / z


def _fourier_shapes(Bt, z, tri_pt=(1.2, 7.0), cloud_min_pt=40.0):
    """R-FT3: outlines of the line image classified by Fourier descriptors -> (triangles [(3,2) pt], cloud contours [px])"""
    tris, clouds = [], []
    L = max(9, int(round(8.0 * z)))                          # end marks touch their line: take the long H/V strokes away first
    lines = cv2.morphologyEx(Bt, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (L, 1)))
    lines |= cv2.morphologyEx(Bt, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (1, L)))
    rest = cv2.bitwise_and(Bt, cv2.bitwise_not(cv2.dilate(lines, np.ones((3, 3), np.uint8))))
    # end marks of the sheet note are OPEN triangles (outline): their hole is a triangle. Filled arrowheads are dimension arrows -> ignored.
    cs, hier = cv2.findContours(Bt, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)   # holes: a triangle touching its line still has its own hole
    if hier is not None:
        for c, hh in zip(cs, hier[0]):
            if hh[3] < 0:
                continue                                     # outer outline; only holes are tested
            x, y, w, h = cv2.boundingRect(c)
            big = max(w, h) / z
            if not (0.6 <= big <= tri_pt[1] and len(c) >= 6):
                continue
            ap = cv2.approxPolyDP(c, 0.1 * cv2.arcLength(c, True), True)
            if len(ap) != 3:
                continue
            # tiny holes (a few px; a line through the mark splits it in two right-angled halves): the 3-vertex polygon must fill the hole;
            # larger holes are also checked by their Fourier descriptors
            if cv2.contourArea(ap) > 0 and (0.7 < cv2.contourArea(c) / cv2.contourArea(ap) < (2.2 if big < 4.0 else 1.4)) and (big < 4.0 or _F.classify(c[:, 0, :]) == 'triangle'):
                tris.append(ap[:, 0, :].astype(float) / z)
    cs_full, _ = cv2.findContours(Bt, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    for c in cs_full:
        x, y, w, h = cv2.boundingRect(c)
        if max(w, h) / z >= cloud_min_pt and len(c) >= 60 and w > 2 * z and h > 2 * z and _F.classify(c[:, 0, :]) == 'cloud':
            clouds.append(c)
    return tris, clouds


OBL = dict(th=3.0, minlen=3.0, gap=3.0, angmin=3.0, excl=3)      # tuned on the scan benchmark (v2.73)


def _oblique(B, masks, z):
    rest = cv2.bitwise_and(B, cv2.bitwise_not(cv2.dilate(masks, np.ones((int(OBL['excl']), int(OBL['excl'])), np.uint8))))
    ls = cv2.HoughLinesP(rest, 1, math.pi / 360, threshold=int(OBL['th'] * z), minLineLength=int(OBL['minlen'] * z), maxLineGap=int(OBL['gap'] * z))
    out = []
    if ls is None:
        return out
    ls = ls.reshape(-1, 4)
    for x0, y0, x1, y1 in ls:
        ang = abs(math.degrees(math.atan2(y1 - y0, x1 - x0))) % 90
        if min(ang, 90 - ang) < OBL['angmin']:
            continue
        out.append(((x0 / z, y0 / z), (x1 / z, y1 / z)))
    return out


def _rings(B, dark, z, min_len_pt=18.0, max_frac=0.2):
    """inner outlines of closed shapes -> list of (points_pt, weight_pt)."""
    Bc = cv2.morphologyEx(B, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    cnts, hier = cv2.findContours(Bc, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    if hier is None:
        return []
    H, W = B.shape
    out = []
    for c, hh in zip(cnts, hier[0]):
        if hh[3] == -1:                                  # outer boundary of ink: skip, only holes
            continue
        per = cv2.arcLength(c, True)
        area = cv2.contourArea(c)
        if per < min_len_pt * z or area > max_frac * H * W or area < (4 * z) ** 2:
            continue
        ap = cv2.approxPolyDP(c, 0.5 * z * 0.35, True)[:, 0, :].astype(float)
        if len(ap) < 3:
            continue
        # stroke weight: ink coverage along the outward radial from the hole centroid
        cx, cy = c[:, 0, 0].mean(), c[:, 0, 1].mean()
        idx = np.linspace(0, len(c) - 1, min(24, len(c))).astype(int)
        ws = []
        for q in idx:
            px, py = c[q, 0]
            d = np.array([px - cx, py - cy], float)
            nrm = np.linalg.norm(d)
            if nrm < 1e-6:
                continue
            d /= nrm
            s = 0.0
            for step in range(0, 9):
                xx, yy = int(round(px + d[0] * step)), int(round(py + d[1] * step))
                if 0 <= xx < W and 0 <= yy < H:
                    s += dark[yy, xx] / 255.0
            ws.append(s)
        out.append(((ap + 0.5) / z, float(np.median(ws)) / z if ws else 0.0))
    return out


def _cached_ocr(ocr, gray, cache_dir):
    """OCR is the slow step: results are cached by image hash + backend (offline, local file)."""
    import hashlib, json, os
    from .ocr import Line
    key = hashlib.sha256(gray.tobytes()).hexdigest()[:20] + '_' + ocr.backend
    path = os.path.join(cache_dir, key + '.json') if cache_dir else None
    if path and os.path.exists(path):
        return [Line(t, np.array(b, float), sc, v) for t, b, sc, v in json.load(open(path, encoding='utf-8'))]
    lines = ocr.read_tiled(gray)
    if path:
        os.makedirs(cache_dir, exist_ok=True)
        json.dump([[l.text, l.box.tolist(), l.score, bool(l.vertical)] for l in lines], open(path, 'w', encoding='utf-8'))
    return lines


def _norm_text(t):
    import re
    t = t.strip()
    t = re.sub(r'\bOFF\s*C\s*[.,]?\s*[LI1l|]\b', 'OFF C.L', t)
    t = re.sub(r'^C[.,][LI1l|]$', 'C.L', t)
    return t


def merge_pieces(words):
    """OCR often cuts one printed label into pieces ('OFF' + 'C.L'). Join pieces that sit on the
    same line with a small gap; pure numbers stay separate (R-OC1)."""
    import re
    num = lambda w: re.fullmatch(r'[\d.,+:()-]+', w.text.strip()) is not None
    used = set()
    out = []
    for vert in (True, False):
        cand = [w for w in words if w.vertical == vert and not num(w) and len(w.text.strip()) <= 6]
        for i, a in enumerate(cand):
            if id(a) in used:
                continue
            for b in cand:
                if b is a or id(b) in used or id(a) in used:
                    continue
                if vert:
                    wd = a.bbox[2] - a.bbox[0]
                    if abs(a.cx - b.cx) < 0.3 * wd and -0.6 * wd <= a.bbox[1] - b.bbox[3] < 0.8 * max(wd, 1) * 1.5 \
                            and a.text.strip() == 'OFF' and _norm_text(b.text) == 'C.L':
                        bb = (min(a.bbox[0], b.bbox[0]), b.bbox[1], max(a.bbox[2], b.bbox[2]), a.bbox[3])
                        out.append(Word('OFF C.L', bb, a.size, True))
                        used.update((id(a), id(b)))
                else:
                    ht = a.bbox[3] - a.bbox[1]
                    if abs(a.cy - b.cy) < 0.3 * ht and -0.6 * ht <= b.bbox[0] - a.bbox[2] < 0.8 * ht \
                            and a.text.strip() == 'OFF' and _norm_text(b.text) == 'C.L':
                        bb = (a.bbox[0], min(a.bbox[1], b.bbox[1]), b.bbox[2], max(a.bbox[3], b.bbox[3]))
                        out.append(Word('OFF C.L', bb, a.size, False))
                        used.update((id(a), id(b)))
    rest = [w for w in words if id(w) not in used]
    for w in rest:
        w.text = _norm_text(w.text)
    # R-OC2 (8366 scan): the OCR cuts a deck-plan title in two ('A - DECK PLAN (31.300 /' + '300 A/B)', 'B - DECK PLAN (35,6' + '00 A/B)',
    # 'C - DECK PLAN (38,500' + '8,500 A/B)'): comma read as '.', digits printed twice or split. Join the pieces: height = the integer
    # part of the left piece + a 3-digit tail made from the left remainder and/or the right piece.
    cut = [w for w in rest if re.search(r'DECK\s*PLAN\s*\(\s*\d{1,2}[.,]\d{0,3}\s*/?\s*$', w.text.strip()) and not w.vertical]
    tails = [w for w in rest if re.fullmatch(r'[\d.,]{0,6}\s*A\s*/\s*B\s*\)?', w.text.strip()) and not w.vertical]
    for a in cut:
        ht = a.bbox[3] - a.bbox[1]
        b = next((t for t in tails if abs(t.cy - a.cy) < 0.5 * ht and -4 * ht <= t.bbox[0] - a.bbox[2] < 3 * ht), None)
        if b is None:
            continue
        m = re.search(r'^(.*?)\(\s*(\d{1,2})[.,](\d{0,3})', a.text.strip())
        q = m.group(3)
        r = re.sub(r'\D', '', re.sub(r'A\s*/\s*B.*', '', b.text))
        tail = q if len(q) == 3 else (q + r if len(q + r) == 3 else r[-3:])
        if len(tail) != 3:
            continue
        a.text = f'{m.group(1)}({m.group(2)}{tail} A/B)'
        a.bbox = (a.bbox[0], min(a.bbox[1], b.bbox[1]), b.bbox[2], max(a.bbox[3], b.bbox[3]))
        a.size = max(a.size, b.size)          # the OCR size of the joined title is that of its larger piece
        rest = [w for w in rest if w is not b]
    return rest + out


def load_raster_page(path, page_no=0, zoom=3.0, ocr=None, ocr_cache=None, log=print):
    gray, z = load_gray(path, page_no, zoom)
    _ang = _F.estimate_skew(gray)                     # R-FT1: page skew from the 2D FFT spokes, rotated back before reading
    if abs(_ang) >= 0.05:
        gray = _F.deskew(gray, _ang)
        log(f'raster: R-FT1 skew {_ang:+.2f} deg corrected')
    H, W = gray.shape
    page = Page(rect=(0, 0, W / z, H / z))
    page.raster = True
    dark = (255 - gray)
    B = (gray < 175).astype(np.uint8) * 255
    # ---- text ---------------------------------------------------------
    textmask = np.zeros_like(B)
    if ocr is not None:
        log('raster: OCR ...')
        lines = _cached_ocr(ocr, gray, ocr_cache)
        for ln in lines:
            xs, ys = ln.box[:, 0], ln.box[:, 1]
            x0, y0, x1, y1 = xs.min() / z, ys.min() / z, xs.max() / z, ys.max() / z
            short = min(x1 - x0, y1 - y0)
            page.words.append(Word(_tn.fix_text(ln.text.strip())[0], (x0, y0, x1, y1), short / 1.4, ln.vertical))   # R-T20
            pad = 1
            cv2.rectangle(textmask, (int(xs.min()) - pad, int(ys.min()) - pad),
                          (int(xs.max()) + pad, int(ys.max()) + pad), 255, -1)
        page.words = merge_pieces(page.words)
        log(f'raster: {len(page.words)} text lines (after piece merge)')
    Bt = cv2.bitwise_and(B, cv2.bitwise_not(textmask))      # geometry without glyph strokes
    _tris, _clouds = _fourier_shapes(Bt, z)                  # R-FT3: end-mark triangles + revision clouds by Fourier descriptors
    for c in _clouds:
        cv2.drawContours(Bt, [c], -1, 0, 5)                  # a revision cloud is not structure (R-RV1): its outline leaves the line work
        x_, y_, w_, h_ = cv2.boundingRect(c)
        page.clouds.append((x_ / z, y_ / z, (x_ + w_) / z, (y_ + h_) / z))
    if _tris or _clouds:
        log(f'raster: R-FT3 {len(_tris)} end-mark triangles, {len(_clouds)} revision clouds')
    # ---- straight strokes ---------------------------------------------------
    pid = 0
    hv = np.zeros_like(B)
    for vertical in (False, True):
        st = _strokes(Bt, dark, z, vertical)
        for d in _merge_dashes(st, vertical, z, Bt):
            page.segs.append(Seg(tuple(d['a']), tuple(d['b']), round(d['w'], 2), d['dash'], pid))
            pid += 1
            cv2.line(hv, (int(d['a'][0] * z), int(d['a'][1] * z)), (int(d['b'][0] * z), int(d['b'][1] * z)), 255, 3)
    log(f'raster: {len(page.segs)} H/V strokes')
    for tri in _tris:                                        # a filled triangle mark = its three short sides (what the end-mark rules read)
        for q in range(3):
            page.segs.append(Seg(tuple(tri[q]), tuple(tri[(q + 1) % 3]), 0.3, '', pid))
        pid += 1
    for a, b in _oblique(Bt, hv, z):
        page.segs.append(Seg(a, b, 0.36, '', pid))
        pid += 1
    # ---- rings (circles, radiused cut-outs, closed outlines) --------------------------
    for pts, wid in _rings(Bt, dark, z):
        n = len(pts)
        for i in range(n):
            page.segs.append(Seg(tuple(pts[i]), tuple(pts[(i + 1) % n]), round(wid, 2), '', pid, 'l'))
        pid += 1
    log(f'raster: {len(page.segs)} segments total')
    return page
