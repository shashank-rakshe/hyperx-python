"""R-E22: longitudinal numbers -> OFF C.L (Y, mm), from the drawing only.

An elevation may be titled by its longitudinal number ('NO.2 LONGL.ELEV.(P)') instead of its OFF C.L. The drawing writes the
link for some of them: a title 'NNNN OFF C.L ELEV.(P)' with the sub-title '(NO.n LONGL. ELEV.(P))', or a title 'NO.n LONGL. ELEV.'
with the sub-title '(NNNN OFF C.L)'. Those are ANCHORS (written). Another number is placed:
  - between two anchors (or between the C.L and the first anchor): equal spacing in that interval, ACCEPTED only when the deck plan
    confirms it - the plan prints the 'NO.n LONGL.' row labels on both sides of the C.L; the plan distance of each label from the
    C.L (mid-point of its P/S pair) times the plan scale fitted on the anchors must agree within 60 mm;
  - outside the anchors: the last anchor bay continued, ACCEPTED only with the same plan confirmation.
Anything else is not placed: an owner question (the OFF C.L of NO.n LONGL.)."""
import re
import statistics
from collections import defaultdict

from . import pdfsrc

_CACHE = {}
OFF_T = re.compile(r'^\s*\(?\s*(\d{3,5})\s*OFF\s*C\.?\s*L\.?(?:\s*ELEV\.?)?\s*(?:\(([PS])\))?\s*\)?\s*$')
NO_T = re.compile(r'^\s*\(?\s*NO\.?\s*(\d{1,2})\s*LONGL\.?\s*(?:ELEV\.?)?\s*(?:\(([PS])\))?\s*\)?\s*(?:SIM.*)?$')
ROW_L = re.compile(r'^\s*NO\.?\s*(\d{1,2})\s*LONGL\.?\s*$')
TOL = 60.0


def _anchors(pages):
    anc, src = {}, {}
    for pn, pg in pages:
        big = [w for w in pg.words if w.size >= 12 and not w.vertical]
        for t in big:
            subs = [w for w in pg.words if not w.vertical and w is not t and abs(w.bbox[0] - t.bbox[0]) < 25
                    and t.bbox[3] - 8 < w.bbox[1] < t.bbox[3] + 40]
            mo, mn = OFF_T.match(t.text), NO_T.match(t.text)
            for w in subs:
                if mo and NO_T.match(w.text):
                    n, y = int(NO_T.match(w.text).group(1)), float(mo.group(1))
                elif mn and OFF_T.match(w.text):
                    n, y = int(mn.group(1)), float(OFF_T.match(w.text).group(1))
                else:
                    continue
                if n in anc and abs(anc[n] - y) > 1:
                    src.setdefault('conflict', []).append(f'NO.{n}: {anc[n]:g} vs {y:g} (p{pn})')
                    continue
                anc[n] = y
                src[n] = f'p{pn} "{t.text.strip()}" / "{w.text.strip()}"'
    return anc, src


def _plan_dist(pages):
    """{n: pt distance from the C.L} from plan row labels printed on both sides of the C.L, per column; one value per n (median)."""
    out = defaultdict(list)
    for pn, pg in pages:
        lab = sorted(((int(ROW_L.match(w.text).group(1)), w.cy, w.cx) for w in pg.words
                      if ROW_L.match(w.text) and not w.vertical and w.size < 11), key=lambda t: t[2])
        cols = []
        for n, cy, cx in lab:          # a label column: labels within 120 pt of x of the previous one
            if cols and cx - cols[-1][-1][2] < 120:
                cols[-1].append((n, cy, cx))
            else:
                cols.append([(n, cy, cx)])
        cols = [[(n, cy) for n, cy, _ in c] for c in cols]
        for ws in cols:
            by = defaultdict(list)
            for n, cy in ws:
                by[n].append(cy)
            cls = [(min(v) + max(v)) / 2 for v in by.values() if len(v) == 2 and max(v) - min(v) > 5]
            if len(cls) < 2:
                continue
            cl = statistics.median(cls)
            if any(abs(c - cl) > 3 for c in cls):
                continue
            for n, v in by.items():
                if len(v) == 2:
                    out[n].append((max(v) - min(v)) / 2)
    return {n: statistics.median(v) for n, v in out.items()}


def _ruler(pages, anc, ksheet):
    """R-E22d (1005-ERM/DER): a plan can print 'NO.n LONGL.' row labels on ONE side of the C.L only (no P/S pair, so R-E22 cannot
    measure the distance from the C.L). A column of >= 6 consecutive labels (one per n, 20-21 pt apart) is a RULER: the label position
    along the column is the OFF C.L of that longitudinal. A written anchor in the column gives the offset; the sheet scale gives the
    slope (fitted when two anchors stand in the column, it must agree with the sheet scale within 3 %).
    {n: Y mm} measured (about +/- 40 mm, one label pitch is ~730 mm): used as the plan confirmation of an interpolated row, never
    as a written value."""
    out = defaultdict(list)
    for pn, pg in pages:
        lab = sorted(((int(ROW_L.match(w.text).group(1)), w.cy, w.cx) for w in pg.words
                      if ROW_L.match(w.text) and not w.vertical and w.size < 11), key=lambda t: t[2])
        cols = []
        for n, cy, cx in lab:
            for c in cols:
                if abs(c[0][2] - cx) < 8:
                    c.append((n, cy, cx)); break
            else:
                cols.append([(n, cy, cx)])
        for c in cols:
            best = {}
            for i1 in range(len(c)):                                      # the column also holds stray labels (other views): keep the
                for i2 in range(i1 + 1, len(c)):                          # longest set that stands on one line (uniform pitch per n)
                    n1, y1, _ = c[i1]; n2, y2, _ = c[i2]
                    if n1 == n2 or not 12 <= abs((y2 - y1) / (n2 - n1)) <= 35:
                        continue
                    pit = (y2 - y1) / (n2 - n1)
                    cand_ = {}
                    for n, y, _ in c:
                        if abs(y - (y1 + pit * (n - n1))) < 3:
                            cand_[n] = y
                    if len(cand_) > len(best):
                        best = cand_
            pos = best
            if len(pos) < 6:
                continue
            ns = sorted(pos)
            ys = [pos[n] for n in ns]
            sg = 1 if ys[-1] > ys[0] else -1
            a = [n for n in anc if n in pos]
            if not a:
                continue
            k = ksheet
            if len(a) >= 2:
                a2 = sorted(a)
                kk = (anc[a2[-1]] - anc[a2[0]]) / (sg * (pos[a2[-1]] - pos[a2[0]]))
                if ksheet and abs(kk - ksheet) / ksheet > 0.03:
                    continue
                k = kk
            if not k:
                continue
            for n, y in pos.items():
                n0 = min(a, key=lambda m: abs(pos[m] - y))
                out[n].append(anc[n0] + sg * k * (y - pos[n0]))
    return {n: statistics.median(v) for n, v in out.items()}


def table(pdf):
    """{n: Y mm} for every NO.n LONGL. the drawing places, plus 'evidence' / 'ask' lists."""
    key = pdf
    if key in _CACHE:
        return _CACHE[key]
    import pymupdf
    pages = [(i + 1, pdfsrc.load_page(pdf, i)) for i in range(len(pymupdf.open(pdf)))]
    anc, src = _anchors(pages)
    d = _plan_dist(pages)
    from . import view as _view
    sk = [25.4 / 72.0 * s_ for s_ in (_view.sheet_scale(pg) for _, pg in pages) if s_]
    rul = _ruler(pages, anc, statistics.median(sk) if sk else None)
    res = {'Y': dict(anc), 'evidence': {n: 'written: ' + s for n, s in src.items() if isinstance(n, int)}, 'ask': []}
    if src.get('conflict'):
        res['ask'] += [f'NO.n LONGL. OFF C.L written twice with different values: {c}' for c in src['conflict']]
    pts = sorted([(0, 0.0)] + [(n, y) for n, y in anc.items()])
    cand = {}
    for n in sorted(set(d) | set(rul)):
        if n in anc:
            continue
        lo = max((p for p in pts if p[0] < n), default=None)
        hi = min((p for p in pts if p[0] > n), default=None)
        if lo and hi:
            y = lo[1] + (hi[1] - lo[1]) * (n - lo[0]) / (hi[0] - lo[0])
            how = f'equal spacing between NO.{lo[0]} ({lo[1]:g}) and NO.{hi[0]} ({hi[1]:g})'
        elif lo and len(pts) >= 2:
            p1 = max(p for p in pts if p[0] < lo[0])
            y = lo[1] + (lo[1] - p1[1]) / (lo[0] - p1[0]) * (n - lo[0])
            how = f'last bay NO.{p1[0]}-{lo[0]} continued'
        else:
            continue
        cand[n] = (y, how)
    # plan scale: fitted on the written anchors that the plan labels, else on the candidates; it must agree with the written
    # sheet scale (3 %) - then each label is an independent measurement of its own row
    ks = [anc[n] / d[n] for n in anc if n in d and d[n] > 1] or [y / d[n] for n, (y, _) in cand.items() if n in d and d[n] > 1]
    kp = statistics.median(ks) if ks else None
    if kp and sk and min(abs(kp - k_) / k_ for k_ in sk) > 0.03:
        res['ask'].append(f'plan label spacing gives {kp:.2f} mm/pt, not the written sheet scale: longitudinal numbers not placed')
        kp = None
    chainp = _dim_chain(pages, anc, kp) if kp else {}
    res['page_Y'] = {}
    chain = {}
    for n, byp in chainp.items():
        vals = sorted({round(y_) for y_, _ in byp.values()})
        if max(vals) - min(vals) <= 5:
            chain[n] = next(iter(byp.values()))
        else:
            # R-E22c: the sheets write DIFFERENT spacings for this row (a side-shell longitudinal: its OFF C.L changes with the deck
            # height) - each sheet's own chain holds for the views of that sheet only
            for pn_, (y_, ev_) in byp.items():
                res['page_Y'][(pn_, n)] = (y_, ev_ + ' (this sheet only: other sheets write other spacings)')
    for n, (y, how) in cand.items():
        if n in chain and abs(chain[n][0] - y) > 1:
            # R-E22b: the written dimension chain beside the row labels places it (written values beat equal-spacing / continuation)
            res['Y'][n] = chain[n][0]
            res['evidence'][n] = chain[n][1] + (f'; plan label at {d[n] * kp:.0f} mm' if kp and n in d else '')
            continue
        if any(k_[1] == n for k_ in res['page_Y']):
            continue
        if n in rul and abs(rul[n] - y) <= TOL:
            res['Y'][n] = float(round(rul[n] / 10.0) * 10)        # the ruler is drawn at the sheet scale: measured to ~5 mm on 1005 (20 rows x 2 drawings), written values are multiples of 10
            res['evidence'][n] = f'measured on the plan label ruler (R-E22d) {rul[n]:.0f} mm from the written anchors; {how} agrees within {TOL:.0f} mm'
        elif kp and n in d and abs(d[n] * kp - y) <= TOL:
            res['Y'][n] = round(y, 1)
            res['evidence'][n] = f'{how}; plan label at {d[n] * kp:.0f} mm confirms'
        else:
            res['ask'].append(f'NO.{n} LONGL.: OFF C.L not written ({how} gives {y:.0f}, plan label gives '
                              f'{(d[n] * kp) if (kp and n in d) else (rul[n] if n in rul else float("nan")):.0f}) - give the OFF C.L')
    res['plan_scale_mm_per_pt'] = kp
    _CACHE[key] = res
    return res


def y_of(page, n):
    """(Y, evidence) of NO.n LONGL. for the drawing of this page, or (None, reason)."""
    if not getattr(page, 'src', ''):
        return None, 'drawing path unknown'
    t = table(page.src)
    pn = getattr(page, 'pno', None)
    if pn is not None and (pn + 1, n) in t.get('page_Y', {}):
        return t['page_Y'][(pn + 1, n)]
    if n in t['Y']:
        return t['Y'][n], t['evidence'].get(n, '')
    return None, f'NO.{n} LONGL. OFF C.L not written and not confirmed on a plan (owner question)'


def _dim_chain(pages, anc, kp):
    """R-E22b [DRAWING]: the plan prints the row spacings as a column of dimension numbers beside the 'NO.n LONGL.' labels
    ('840', '906', '906', '975', '960'). From a written anchor (NO.24 = 20280) a row's OFF C.L is the anchor plus the numbers that
    stand between the two rows, accepted when that sum agrees with the measured label distance (60 mm). -> {n: (Y, evidence)}"""
    out = {}
    for pn, pg in pages:
        labs0 = sorted(((int(ROW_L.match(w.text).group(1)), w) for w in pg.words if ROW_L.match(w.text) and not w.vertical and w.size < 11),
                       key=lambda t: t[1].cx)
        groups = []
        for n, w in labs0:              # one label column per plan (a sheet may carry two plans)
            if groups and w.cx - groups[-1][-1][1].cx < 120:
                groups[-1].append((n, w))
            else:
                groups.append([(n, w)])
        for labs in groups:
            _chain_column(pg, pn, labs, anc, kp, out)
    return out


def _chain_column(pg, pn, labs, anc, kp, out):
    if True:
        if len(labs) < 4:
            return
        by = defaultdict(list)
        for n, w in labs:
            by[n].append(w)
        cls = [(min(v, key=lambda w: w.cy).cy + max(v, key=lambda w: w.cy).cy) / 2 for v in by.values() if len(v) == 2]
        if len(cls) < 2:
            return
        cl = statistics.median(cls)
        nums = [w for w in pg.words if w.vertical and re.fullmatch(r'\d{3,4}', w.text.strip())]
        for side in (-1, 1):
            rows = {n: min(v, key=lambda w: abs(w.cy - cl)) for n, v in by.items() if any(side * (w.cy - cl) > 5 for w in v)}
            rows = {n: [w for w in by[n] if side * (w.cy - cl) > 5][0] for n in rows}
            if not rows:
                continue
            xa_ = min(w.bbox[0] for w in rows.values()) - 80
            xb_ = max(w.bbox[2] for w in rows.values()) + 120
            col = [u for u in nums if xa_ < u.cx < xb_ and side * (u.cy - cl) > 0]
            # written positions: the anchors and every 'nnnn OFF C.L' total printed on this sheet (a wall line such as 23000)
            known = [(float(y), cl + side * y / kp, f'NO.{n}') for n, y in anc.items()]
            for w in pg.words:
                mo = re.fullmatch(r'\(?\s*(\d{3,5})\s*\)?', w.text.strip())
                if mo and any(u.text.strip().startswith('OFF C') and abs(u.cx - w.cx) < 25 and abs(u.cy - w.cy) < 40 and u is not w
                              for u in pg.words) and float(mo.group(1)) not in [k_[0] for k_ in known]:
                    y_ = float(mo.group(1))
                    known.append((y_, cl + side * y_ / kp, f'{y_:g} OFF C.L'))
            for n in sorted(rows, key=lambda n: abs(rows[n].cy - cl)):
                if n in anc:
                    continue
                meas_y = abs(rows[n].cy - cl) * kp
                base = [k_ for k_ in known if k_[0] < meas_y - 300]
                if not base:
                    continue
                y_m, py_m, nm_ = max(base)
                py_n = rows[n].cy             # label space: the C.L is the mid-point of the label pairs, so the label offset cancels
                lo_, hi_ = sorted((py_m, py_n))
                mid_, gap_ = (lo_ + hi_) / 2, hi_ - lo_
                between = [u for u in col if lo_ - 6 < u.cy < hi_ + 6 and abs(u.cy - mid_) < 0.4 * gap_ + 7] if gap_ < 40 else \
                          [u for u in col if lo_ + 4 < u.cy < hi_ + 4]
                if not between:
                    continue
                sm = sum(int(u.text) for u in between)
                if abs(sm - abs(py_n - py_m) * kp) <= 60:
                    y = y_m + sm
                    known.append((float(y), py_n, f'NO.{n}'))
                    out.setdefault(n, {}).setdefault(pn, (float(y), f'R-E22b dimension chain p{pn}: {nm_} ({y_m:g}) + ' + ' + '.join(u.text.strip() for u in sorted(between, key=lambda u: -side * u.cy))))
    return
