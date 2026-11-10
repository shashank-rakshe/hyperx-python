"""R-LG2  longitudinals NO.n: OFF C.L from the longitudinal table, section from the 'NO.n LONGL. ELEV.' view (labels first).

* table(page):  the vertical 'NNNN OFF C.L' values printed beside the 'NO.n LONGL.' rows -> {OFF C.L: n}
  (the label sits ~9 pt above its row; rows are extrapolated by the row pitch beyond the last printed one, e.g. NO.22).
* scan(pdf, fx): every 'NO.n LONGL. ELEV.' view -> {n: [(X_mm, text)]}: the printed section texts 'WxT + wxt F.B(T)' and bracket marks
  'B50', placed in X by the printed frame-number row of the view (47, 48, ... at known frame X).
* section_at(n, x0, x1): section text(s) printed inside the X span of a deck (e.g. FR.47-4000 .. FR.47).
"""
import re
import statistics
from . import pdfsrc

_T = re.compile(r'(\d+)\s*[Xx]\s*(\d+)\s*\+\s*(\d+)\s*[Xx]\s*(\d+)\s*F\.B\(T\)')


def table(page):
    nos = []
    for w in page.words:
        m = re.fullmatch(r'NO\.(\d+) LONGL\.', w.text.strip())
        if m and not w.vertical:
            nos.append((int(m.group(1)), w))
    if len(nos) < 4:
        return {}
    # use the table with the most rows (the sheet repeats it)
    best = None
    for n0, w0 in nos:
        col = [(n, w) for n, w in nos if abs(w.cx - w0.cx) < 15 and abs(w.cy - w0.cy) < 900]
        if best is None or len(col) > len(best):
            best = col
    col = sorted(best, key=lambda t: t[0])
    ys = {n: w.cy for n, w in col}
    ns = sorted(ys)
    pitch = statistics.median([(ys[b] - ys[a]) / (b - a) for a, b in zip(ns, ns[1:]) if b > a])
    cx = statistics.median([w.cx for _, w in col])
    out = {}
    for w in page.words:
        if re.fullmatch(r'\d{4,5}', w.text.strip()) and w.vertical and 60 < w.cx - cx < 400:
            yrow = w.cy + 9.0
            if not (min(ys.values()) - 30 < yrow < max(ys.values()) + 2.5 * pitch):
                continue
            n = min(ns, key=lambda k: abs(ys[k] - yrow))
            n_ex = ns[-1] + round((yrow - ys[ns[-1]]) / pitch) if yrow > ys[ns[-1]] + 0.6 * pitch else n
            out[int(w.text)] = n_ex
    return out


def scan(pdf, fx, pages=None):
    import pymupdf
    res = {}
    n_pages = len(pymupdf.open(pdf))
    for pn in (pages or range(n_pages)):
        page = pdfsrc.load_page(pdf, pn)
        titles = []
        for w in page.words:
            m = re.fullmatch(r'NO\.(\d+) LONGL\. ELEV\.\(S\)', w.text.strip())
            if m:
                titles.append((int(m.group(1)), w))
        for n, t in titles:
            row = {}
            for w in page.words:
                if re.fullmatch(r'\d{2,3}', w.text.strip()) and not w.vertical and abs(w.cx - t.cx) < 700 and 40 < w.cy - t.cy < 520:
                    row.setdefault(round(w.cy / 4), []).append(w)
            rows = [r for r in row.values() if len(r) >= 5]
            if not rows:
                continue
            rows.sort(key=lambda r: statistics.median(w.cy for w in r))
            r = rows[0]       # the first row below the title = the view's frame row (the last row closes the view)
            by = {}
            for w in r:      # one word per frame number: the nearest to the title (neighbouring views print the same numbers)
                k_ = int(w.text)
                if k_ not in by or abs(w.cx - t.cx) < abs(by[k_].cx - t.cx):
                    by[k_] = w
            pts = sorted((w.cx, k_) for k_, w in by.items())
            if len(pts) < 4:
                continue
            xs = [p[0] for p in pts]
            fr = [fx(p[1]) for p in pts]
            k = (fr[-1] - fr[0]) / (xs[-1] - xs[0])

            def to_mm(x):
                return fr[0] + (x - xs[0]) * k
            ycut = statistics.median(w.cy for w in rows[-1])
            items = []
            for w in page.words:
                if abs(w.cx - t.cx) < 700 and statistics.median(w.cy for w in r) - 3 < w.cy < ycut + 3:
                    m = _T.search(w.text)
                    if m:
                        items.append((to_mm(w.cx), w.text.strip(), (float(m.group(1)), float(m.group(2)), float(m.group(3)), float(m.group(4)))))
                    elif re.fullmatch(r'B\d{2}', w.text.strip()):
                        items.append((to_mm(w.cx), w.text.strip(), None))
            res[n] = items
    return res


def section_at(secs, n, x0, x1):
    """[(X, text, (H, tw, wf, tf))] of the T sections printed between X0 and X1 in the NO.n elevation"""
    return [i for i in secs.get(n, []) if i[2] and x0 - 50 <= i[0] <= x1 + 50]
