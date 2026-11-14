"""Offline OCR front end: returns text lines with page-point boxes.

Backends (first available wins, or choose with backend=...):
  paddle    PaddleOCR with LOCAL PP-OCRv5 mobile det/rec model folders (no download)
  rapid     rapidocr_onnxruntime (PP-OCR models bundled in the wheel)
  tesseract pytesseract + local tesseract binary

Vertical text (drawings are read from the bottom and the right) is handled by
trying a tall box in both 90-degree readings and keeping the better score.
Nothing here touches the network.
"""
import math
import numpy as np


_STROKE = set('Iil!|/\'4')


def clean_marks(t):
    """R-T7: a short box holding ONE letter plus a neighbouring dash / extension / section line is read as 'IB', 'Bi', 'B/4', 'BIB'.  Drop the stroke-like characters when exactly one distinct letter remains."""
    u = t.strip()
    if 2 <= len(u) <= 4 and any(c in _STROKE for c in u):
        rest = [c for c in u if c not in _STROKE]
        if rest and all(c.isalpha() and c.isupper() for c in rest) and len(set(rest)) == 1:
            return rest[0]
    return t


def _ed1(a, b):
    """True if the edit distance of a and b is exactly 1 (substitution / insertion / deletion)."""
    if a == b or abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) == 1
    if len(a) > len(b):
        a, b = b, a
    return any(b[:i] + b[i + 1:] == a for i in range(len(b)))


_LEX = None


def repair_words(t):
    """R-T13: tokens one edit away from exactly ONE word of the ship-drawing vocabulary are repaired ('GIR' -> 'GIR.', 'VEB' -> 'WEB', 'LONGL' -> 'LONGL.'); known words and anything with digits are left alone; \
a lone 'C' behind 'OFF' is the centre-line mark 'C.L'."""
    global _LEX
    if _LEX is None:
        try:
            from .lexicon import WORDS
            _LEX = set(WORDS)
        except Exception:
            _LEX = set()
    toks = t.split(' ')
    out = []
    for i, tok in enumerate(toks):
        u = tok.upper()
        if u == 'C' and i > 0 and toks[i - 1].upper().strip('.') == 'OFF':
            out.append('C.L'); continue
        if len(u) >= 3 and u not in _LEX and u.replace('.', '').replace('/', '').isalpha() and u.isupper():
            cand = [w for w in _LEX if len(w) >= 3 and (_ed1(u, w) or w == u + '.' or w == u.rstrip('.'))]
            if len(cand) == 1:
                out.append(cand[0]); continue
        out.append(tok)
    return ' '.join(out)


class Line:
    __slots__ = ('text', 'box', 'score', 'vertical')

    def __init__(self, text, box, score, vertical):
        import unicodedata
        # R-T3: the recogniser emits full-width forms (Ｂ, ２) for drawing lettering; engineering drawings use ASCII only -> NFKC
        self.text, self.box, self.score, self.vertical = repair_words(clean_marks(unicodedata.normalize('NFKC', text))), box, score, vertical


def _tile_origins(n, tile, step):
    o = list(range(0, max(n - tile, 0) + 1, step))
    if not o or o[-1] + tile < n:
        o.append(max(n - tile, 0))
    return o


class OCR:
    def __init__(self, backend='auto', model_dir=None):
        self.backend = None
        self.eng = None
        order = [backend] if backend != 'auto' else ['paddle', 'rapid', 'tesseract']
        err = []
        for b in order:
            try:
                if b == 'paddle':
                    import os
                    os.environ.setdefault('FLAGS_use_mkldnn', '0')   # R-APP4: Paddle 3.x oneDNN bug on Windows CPU
                    from paddleocr import PaddleOCR
                    if model_dir:
                        self.eng = PaddleOCR(text_detection_model_dir=model_dir + '/PP-OCRv5_mobile_det',
                                             text_recognition_model_dir=model_dir + '/en_PP-OCRv5_mobile_rec',
                                             use_doc_orientation_classify=False, use_doc_unwarping=False,
                                             use_textline_orientation=False, enable_mkldnn=False)
                    else:
                        # R-APP2 (owner's run 1009 2026-10-27): paddleocr was installed but no --ocr-models folder was given, so the paddle branch
                        # was skipped silently and the error listed only rapid / tesseract. Use the models already cached on this computer
                        # (~/.paddlex); if they are not there paddle fails here with its own message (no download is attempted by the rules).
                        self.eng = PaddleOCR(text_detection_model_name='PP-OCRv5_mobile_det',
                                             text_recognition_model_name='en_PP-OCRv5_mobile_rec',
                                             use_doc_orientation_classify=False, use_doc_unwarping=False,
                                             use_textline_orientation=False, enable_mkldnn=False)
                    # R-APP5: probe with a tiny image; a Paddle that loads but crashes while reading (oneDNN bug, owner 1009) is dropped for the next engine
                    self.backend = 'paddle'
                    try:
                        self._paddle(np.full((64, 256), 255, np.uint8))
                    except Exception as pe:
                        self.backend = None
                        self.eng = None
                        raise RuntimeError('paddle loads but cannot read: ' + str(pe)[:120])
                elif b == 'rapid':
                    from rapidocr_onnxruntime import RapidOCR
                    self.eng = RapidOCR()
                elif b == 'tesseract':
                    import pytesseract
                    pytesseract.get_tesseract_version()
                    self.eng = pytesseract
                else:
                    continue
                self.backend = b
                break
            except Exception as e:                      # try the next backend
                err.append(f'{b}: {e}')
        if self.backend is None:
            raise RuntimeError('no offline OCR backend available: ' + '; '.join(err))

    # ------------------------------------------------------------------
    def read_image(self, img):
        """img: uint8 gray/BGR array -> list of Line in image pixels."""
        if self.backend == 'rapid':
            return self._rapid(img)
        if self.backend == 'tesseract':
            return self._tess(img)
        return self._paddle(img)

    def _rapid(self, img):
        import cv2
        if img.ndim == 2:
            img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
        e = self.eng
        boxes, _ = e.text_detector(img)
        if boxes is None or len(boxes) == 0:
            return []
        crops = e.get_crop_img_list(img, boxes)
        res, _ = e.text_recognizer(crops)
        out = []
        tall = []
        for i, (b, r) in enumerate(zip(boxes, res)):
            b = np.array(b, dtype=float)
            w = np.linalg.norm(b[1] - b[0])
            h = np.linalg.norm(b[3] - b[0])
            vert = h > 1.5 * w
            if vert:
                tall.append(i)
            out.append([b, r[0], float(r[1]), vert])
        if tall:                                         # second reading: crop turned 180 degrees
            flip = [np.rot90(crops[i], 2).copy() for i in tall]
            res2, _ = e.text_recognizer(flip)
            for i, r in zip(tall, res2):
                if float(r[1]) > out[i][2]:
                    out[i][1], out[i][2] = r[0], float(r[1])
        return [Line(t, b, s, v) for b, t, s, v in out if t.strip() and s >= 0.5]

    def _tess(self, img):
        import pytesseract
        d = pytesseract.image_to_data(img, config='--psm 11', output_type=pytesseract.Output.DICT)
        out = []
        for i, t in enumerate(d['text']):
            if t.strip() and float(d['conf'][i]) > 40:
                x, y, w, h = d['left'][i], d['top'][i], d['width'][i], d['height'][i]
                out.append(Line(t, np.array([[x, y], [x + w, y], [x + w, y + h], [x, y + h]], float),
                                float(d['conf'][i]) / 100, h > 1.5 * w))
        return out

    def _paddle(self, img):
        # R-APP3 (owner's run 1009 2026-10-27: 'not enough values to unpack (expected 3, got 2)' on every page): PaddleOCR needs a 3-channel image;
        # the page tiles are grey (2-D). RapidOCR path already converted; paddle did not.
        if img.ndim == 2:
            import cv2
            img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
        img = np.ascontiguousarray(img, dtype=np.uint8)
        res = self.eng.predict(img)
        out = []
        for r in res:
            for poly, t, s in zip(r['dt_polys'], r['rec_texts'], r['rec_scores']):
                b = np.array(poly, float)
                if b.ndim == 1 and b.size == 4:           # R-APP3: axis box x0,y0,x1,y1 -> 4 corners
                    x0, y0, x1, y1 = b
                    b = np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], float)
                b = b.reshape(-1, 2)
                w = np.linalg.norm(b[1] - b[0])
                h = np.linalg.norm(b[3] - b[0])
                out.append(Line(t, b, float(s), h > 1.5 * w))
        return out

    # ------------------------------------------------------------------
    def read_tiled(self, gray, tile=1400, overlap=160, min_ink=0.002, progress=None):
        """Whole large page: tile it, skip near-empty tiles, merge duplicates."""
        H, W = gray.shape[:2]
        step = tile - overlap
        lines = []
        for y0 in _tile_origins(H, tile, step):
            for x0 in _tile_origins(W, tile, step):
                t = gray[y0:y0 + tile, x0:x0 + tile]
                if (t < 160).mean() < min_ink:
                    continue
                for ln in self.read_image(t):
                    ln.box = ln.box + np.array([x0, y0])
                    lines.append(ln)
                if progress:
                    progress(x0, y0)
        return _dedupe(lines)


    # ------------------------------------------------------------------
    def extend_digits(self, gray, lines, dpi=400.0, vertical_up=True):
        """R-T14: a digit touching an underline / dimension line is dropped by the detector ('12' -> '2', '15' -> '5', '30' -> '0').  For every short purely numeric line the strip
        of one glyph pitch at each end of the text axis is searched for a text-sized component (strokes longer than 8 pt removed first); it is read alone (glyph x3) and, if it is a digit, joined
        to the text.  Horizontal text reads left->right; vertical text reads bottom->top (vertical_up) or top->bottom."""
        import cv2
        if self.backend != 'rapid':
            return lines
        z = dpi / 72.0
        H, W = gray.shape[:2]
        K = int(round(8.0 * z))
        for ln in lines:
            t = ln.text.strip()
            if not (1 <= len(t) <= 5) or not all(c.isdigit() or c == '.' for c in t) or not any(c.isdigit() for c in t):
                continue
            x0, y0, x1, y1 = _bbox(ln.box)
            w, h = x1 - x0, y1 - y0
            vert = bool(ln.vertical) or h > 1.3 * w
            thick = w if vert else h                       # glyph height (perpendicular to the text axis)
            axis = h if vert else w
            pitch = axis / max(len(t), 1)
            reach = int(max(1.3 * pitch, 0.9 * thick))
            if thick < 3 * z or thick > 14 * z:
                continue
            m = int(0.5 * thick)
            X0, Y0, X1, Y1 = int(max(x0 - (m if vert else reach), 0)), int(max(y0 - (reach if vert else m), 0)), int(min(x1 + (m if vert else reach), W)), int(min(y1 + (reach if vert else m), H))
            raw = gray[Y0:Y1, X0:X1]
            if raw.size == 0:
                continue
            Bk = (raw < 160).astype(np.uint8) * 255
            lm = cv2.bitwise_or(cv2.morphologyEx(Bk, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (min(K, Bk.shape[1]), 1))),
                                cv2.morphologyEx(Bk, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (1, min(K, Bk.shape[0])))))
            Bk = cv2.bitwise_and(Bk, cv2.bitwise_not(cv2.dilate(lm, np.ones((3, 3), np.uint8))))
            n, lab, st, _ = cv2.connectedComponentsWithStats(Bk, connectivity=8)
            ex0, ey0, ex1, ey1 = x0 - X0, y0 - Y0, x1 - X0, y1 - Y0
            found = {}
            for i in range(1, n):
                cx, cy, cw, ch = st[i, 0], st[i, 1], st[i, 2], st[i, 3]
                if st[i, 4] < 0.05 * thick * thick:
                    continue
                gh = cw if vert else ch                      # perpendicular extent
                ga = ch if vert else cw                      # along the axis
                if not (0.55 * thick <= gh <= 1.5 * thick) or ga > 1.3 * thick or ga < 0.12 * thick:
                    continue
                mid = (cy + ch / 2) if vert else (cx + cw / 2)
                lo, hi = (ey0, ey1) if vert else (ex0, ex1)
                if lo - 0.2 * pitch <= mid <= hi + 0.2 * pitch:
                    continue                                 # lies on the text itself
                side = 'lo' if mid < lo else 'hi'
                gap = (lo - (cy + ch if vert else cx + cw)) if side == 'lo' else ((cy if vert else cx) - hi)
                if gap > 0.9 * pitch + 0.3 * thick:
                    continue
                if side not in found or gap < found[side][0]:
                    found[side] = (gap, i)
            for side, (gap, i) in found.items():
                cx, cy, cw, ch = st[i, 0], st[i, 1], st[i, 2], st[i, 3]
                crop = np.where(lab[max(cy - 4, 0):cy + ch + 4, max(cx - 4, 0):cx + cw + 4] == i, 0, 255).astype(np.uint8)
                if vert:
                    crop = cv2.rotate(crop, cv2.ROTATE_90_CLOCKWISE if vertical_up else cv2.ROTATE_90_COUNTERCLOCKWISE)
                crop = cv2.copyMakeBorder(crop, 8, 8, 8, 8, cv2.BORDER_CONSTANT, value=255)
                crop = cv2.resize(crop, (max(int(crop.shape[1] * 48 / crop.shape[0]), 8), 48), interpolation=cv2.INTER_CUBIC)
                gp = np.full((48, 12), 255, np.uint8)
                r3, _ = self.eng.text_recognizer([cv2.cvtColor(np.hstack([crop, gp, crop, gp, crop]), cv2.COLOR_GRAY2BGR)])
                t3, s3 = unicodedata_norm(r3[0][0].strip()), float(r3[0][1])
                if len(t3) == 3 and t3[0] == t3[1] == t3[2] and t3[0].isdigit() and s3 >= 0.5:
                    d = t3[0]
                    # reading order: horizontal lo = start; vertical bottom->top: hi (top) = end, lo = start -> mirrored when vertical_up
                    start = (side == 'lo') if (not vert or not vertical_up) else (side == 'hi')
                    # vertical bottom->top: the BOTTOM (side 'hi' in image rows) is the start of the string
                    ln.text = (d + ln.text.strip()) if start else (ln.text.strip() + d)
                    nb = ln.box.copy()
                    gx0, gy0, gx1, gy1 = X0 + cx, Y0 + cy, X0 + cx + cw, Y0 + cy + ch
                    ln.box = np.array([[min(x0, gx0), min(y0, gy0)], [max(x1, gx1), min(y0, gy0)], [max(x1, gx1), max(y1, gy1)], [min(x0, gx0), max(y1, gy1)]], float)
                    x0, y0, x1, y1 = _bbox(ln.box)
        return lines

    def reread_short(self, gray, lines, max_chars=8, pad=14):
        """R-T11: short texts (C.L, GIR., 9., 12, OFF, WEB, 5.5) lose their dots / first digit at the reduced OCR scale: every line of <= max_chars is read again from the FULL
        resolution crop; the new reading replaces the old one when its score is not lower (or when it is longer with the old text inside)."""
        import cv2
        if self.backend != 'rapid':
            return lines
        H, W = gray.shape[:2]
        for ln in lines:
            if len(ln.text.strip()) > max_chars:
                continue
            x0, y0, x1, y1 = _bbox(ln.box)
            X0, Y0, X1, Y1 = int(max(x0 - pad, 0)), int(max(y0 - pad, 0)), int(min(x1 + pad, W)), int(min(y1 + pad, H))
            if X1 - X0 < 8 or Y1 - Y0 < 8:
                continue
            raw = gray[Y0:Y1, X0:X1]
            cx, cy = (x0 + x1) / 2 - X0 + 16, (y0 + y1) / 2 - Y0 + 16
            best = None
            # R-T12: vertical short texts (OFF, C.L, 15 ... turned 90 degrees, underlined) are read badly by the detector's own turning: read the crop turned upright both ways
            base = cv2.copyMakeBorder(raw, 16, 16, 16, 16, cv2.BORDER_CONSTANT, value=255)
            Hh, Ww = base.shape
            variants = [(base, cx, cy)]
            if (y1 - y0) > 1.2 * (x1 - x0):
                variants.append((cv2.rotate(base, cv2.ROTATE_90_CLOCKWISE), Hh - 1 - cy, cx))
                variants.append((cv2.rotate(base, cv2.ROTATE_90_COUNTERCLOCKWISE), cy, Ww - 1 - cx))
            for im_, vx, vy in variants:
                for c in self._rapid(im_):
                    bx = _bbox(c.box)
                    if bx[0] - 8 <= vx <= bx[2] + 8 and bx[1] - 8 <= vy <= bx[3] + 8 and (best is None or c.score > best.score):
                        best = c
            if best is not None and best.text.strip() != ln.text.strip():
                old = ln.text.strip().upper(); new = best.text.strip().upper()
                if best.score >= ln.score or (len(new) > len(old) and old in new and best.score >= 0.5):
                    ln.text, ln.score = best.text, max(best.score, ln.score)
        return lines

    def read_residual(self, gray, known, **kw):
        """R-T6: banded wrapper (large scans of 400 Mpx would need GBs for the component labelling): bands of 4000 px rows with 300 px overlap."""
        H, W = gray.shape[:2]
        BAND, OV = 4000, 300
        if H <= BAND + OV:
            return self._residual(gray, known, **kw)
        out = []
        y = 0
        while y < H:
            y1 = min(y + BAND + OV, H)
            kn = [(k[0], k[1] - y, k[2], k[3] - y) + tuple(k[4:]) for k in known if k[3] >= y and k[1] <= y1]
            for ln in self._residual(np.ascontiguousarray(gray[y:y1]), kn, **kw):
                ln.box = ln.box + np.array([0, y], float)
                if ln.box[:, 1].mean() < y + BAND or y1 >= H:         # the overlap rows belong to the next band
                    out.append(ln)
            y += BAND
        return out

    def _residual(self, gray, known, min_pt=2.2, max_pt=12.0, dpi=400.0, min_score=0.55):
        """R-T1 (second pass, owner 2026-10-24): isolated marks (single letters like 'B' on a dimension line, '#1', 'L') are skipped by the text detector.  Ink components of text
        size that no OCR box covers are grouped into short candidate boxes and read directly by the recognizer (4 turns).  known = list of (x0,y0,x1,y1) px of lines already read."""
        import cv2
        if self.backend != 'rapid':
            return []
        z = dpi / 72.0
        B = (gray < 160).astype(np.uint8) * 255
        # long straight strokes (dimension / extension lines) touch the marks: take them away first so the mark becomes its own component
        L = int(round(14.0 * z))
        lines_ = cv2.bitwise_or(cv2.morphologyEx(B, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (L, 1))),
                                cv2.morphologyEx(B, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (1, L))))
        Bfull = B
        B = cv2.bitwise_and(B, cv2.bitwise_not(cv2.dilate(lines_, np.ones((3, 3), np.uint8))))
        cov = np.zeros_like(B)
        for k in known:
            cv2.rectangle(cov, (int(k[0]) - 2, int(k[1]) - 2), (int(k[2]) + 2, int(k[3]) + 2), 255, -1)
        n, lab, st, _ = cv2.connectedComponentsWithStats(B, connectivity=8)
        lo, hi = min_pt * z, max_pt * z
        keep = np.zeros(n, bool)
        w, h = st[:, 2], st[:, 3]
        ok = (np.maximum(w, h) >= lo) & (np.maximum(w, h) <= hi) & (np.minimum(w, h) >= 0.35 * lo) & (np.maximum(w, h) <= 3.2 * np.minimum(w, h) + 4)
        ok[0] = False
        cx = (st[:, 0] + st[:, 2] // 2).clip(0, B.shape[1] - 1); cy = (st[:, 1] + st[:, 3] // 2).clip(0, B.shape[0] - 1)
        ok &= cov[cy, cx] == 0
        idx = np.nonzero(ok)[0]
        if len(idx) == 0:
            return []
        # group neighbours (same text line / same mark): union of boxes grown by 0.7 glyph height horizontally
        mask = np.zeros_like(B)
        for i in idx:
            x, y, ww, hh = st[i, 0], st[i, 1], st[i, 2], st[i, 3]
            g = int(0.7 * max(ww, hh))
            cv2.rectangle(mask, (x - g, y), (x + ww + g, y + hh), 255, -1)
        nb, labb, stb, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
        crops, boxes = [], []
        def _add(x, y, ww, hh, sel):
            pad = 4
            x0, y0, x1, y1 = max(x - pad, 0), max(y - pad, 0), min(x + ww + pad, B.shape[1]), min(y + hh + pad, B.shape[0])
            sub = B[y0:y1, x0:x1]
            if sel is not None:
                sub = np.where(np.isin(lab[y0:y1, x0:x1], sel), sub, 0).astype(np.uint8)
            crop = np.where(sub > 0, 0, 255).astype(np.uint8)
            if crop.size:
                crops.append(crop); boxes.append((x0, y0, x1, y1))
        for j in range(1, nb):
            x, y, ww, hh = stb[j, 0], stb[j, 1], stb[j, 2], stb[j, 3]
            if hh > 1.5 * hi or ww > 14 * hi:
                continue
            members = [i for i in idx if x <= st[i, 0] and st[i, 0] + st[i, 2] <= x + ww and y <= st[i, 1] and st[i, 1] + st[i, 3] <= y + hh]
            _add(x, y, ww, hh, None)
        out = []
        for crop, bx in zip(crops, boxes):
            best = ('', 0.0, False)
            for rot in (None, cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_90_COUNTERCLOCKWISE, cv2.ROTATE_180):
                im = crop if rot is None else cv2.rotate(crop, rot)
                im = cv2.copyMakeBorder(im, 8, 8, 8, 8, cv2.BORDER_CONSTANT, value=255)
                if im.shape[0] > 2.5 * 48 or im.shape[0] < 20:
                    im = cv2.resize(im, (max(int(im.shape[1] * 48 / im.shape[0]), 8), 48), interpolation=cv2.INTER_AREA if im.shape[0] > 48 else cv2.INTER_CUBIC)
                im = cv2.cvtColor(im, cv2.COLOR_GRAY2BGR)
                res, _ = self.eng.text_recognizer([im])
                t, sc = res[0][0], float(res[0][1])
                if t.strip() and t.isascii() and sc > best[1]:      # R-T5: lettering on ship drawings is ASCII; a rotated 'B' read as a CJK glyph is a wrong turn
                    best = (t.strip(), sc, rot in (cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_90_COUNTERCLOCKWISE))
                # R-T2: the recognizer fails on ONE glyph alone but reads it when the glyph is repeated three times (57/60 vs 26/60) -> read x3, keep the single character
                if im.shape[1] < 2.2 * im.shape[0]:
                    g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY)
                    gap = np.full((g.shape[0], 12), 255, np.uint8)
                    tri = np.hstack([g, gap, g, gap, g])
                    tri = cv2.cvtColor(tri, cv2.COLOR_GRAY2BGR)
                    res3, _ = self.eng.text_recognizer([tri])
                    t3, s3 = res3[0][0].strip(), float(res3[0][1])
                    if not t3.isascii():
                        t3 = ''
                    if len(t3) >= 3 and len(t3) % 3 == 0:
                        k = len(t3) // 3
                        if t3[:k] == t3[k:2 * k] == t3[2 * k:] and k == 1 and s3 > best[1]:
                            best = (t3[:k], s3, rot in (cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_90_COUNTERCLOCKWISE))
            if best[0] and best[1] >= min_score and any(ch.isalnum() or ch in '#' for ch in best[0]):
                x0, y0, x1, y1 = bx
                out.append(Line(best[0], np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], float), best[1], best[2]))
        # R-T4/R-T10: a lone letter inside a group that also holds curve / hatch fragments (a 'B' inside a triangle) is lost; every glyph-shaped component not
        # inside an accepted box is read ALONE (single capital / digit, score >= 0.6, tripled reading)
        accepted = [_bbox(l.box) for l in out]
        for i in idx:
            x, y, ww, hh, ar = st[i, 0], st[i, 1], st[i, 2], st[i, 3], st[i, 4]
            cxm, cym = x + ww / 2, y + hh / 2
            if any(a0 - 2 <= cxm <= a2 + 2 and a1 - 2 <= cym <= a3 + 2 for a0, a1, a2, a3 in accepted):
                continue
            if ar < 0.25 * ww * hh or max(ww, hh) > 2.0 * min(ww, hh) + 2:
                continue
            pad = 4
            X0, Y0, X1, Y1 = max(x - pad, 0), max(y - pad, 0), min(x + ww + pad, B.shape[1]), min(y + hh + pad, B.shape[0])
            crop = np.where(lab[Y0:Y1, X0:X1] == i, 0, 255).astype(np.uint8)
            best = ('', 0.0, False)
            for rot in (None, cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_90_COUNTERCLOCKWISE):
                im = crop if rot is None else cv2.rotate(crop, rot)
                im = cv2.copyMakeBorder(im, 8, 8, 8, 8, cv2.BORDER_CONSTANT, value=255)
                im = cv2.resize(im, (max(int(im.shape[1] * 48 / im.shape[0]), 8), 48), interpolation=cv2.INTER_CUBIC)
                gap = np.full((48, 12), 255, np.uint8)
                res3, _ = self.eng.text_recognizer([cv2.cvtColor(np.hstack([im, gap, im, gap, im]), cv2.COLOR_GRAY2BGR)])
                t3, s3 = unicodedata_norm(res3[0][0].strip()), float(res3[0][1])
                if len(t3) == 3 and t3[0] == t3[1] == t3[2] and t3[0].isalnum() and t3.isascii() and s3 > best[1]:
                    best = (t3[0], s3, rot is not None)
            if best[0] and best[1] >= 0.5 and not (hh > 1.3 * ww and best[0] in 'Il1|'):
                out.append(Line(best[0], np.array([[X0, Y0], [X1, Y0], [X1, Y1], [X0, Y1]], float), best[1], best[2]))
        return out


def unicodedata_norm(t):
    import unicodedata
    return unicodedata.normalize('NFKC', t)


def _bbox(b):
    return b[:, 0].min(), b[:, 1].min(), b[:, 0].max(), b[:, 1].max()


def _dedupe(lines):
    keep = []
    for ln in sorted(lines, key=lambda l: -l.score):
        a = _bbox(ln.box)
        dup = False
        for k in keep:
            b = _bbox(k.box)
            ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
            iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
            inter = ix * iy
            if inter > 0.5 * min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1])):
                dup = True
                break
        if not dup:
            keep.append(ln)
    return keep
