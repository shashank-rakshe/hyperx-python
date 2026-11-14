"""R-FC2 (2026-10-25): 'FRAME SPACE : 1600 (EXC. AS SHOWN)' - the written spacing holds for every bay EXCEPT the bays the drawing
shows differently. A shown bay is read from the frame-number rows of the sheets: every row is scaled on its own bays that equal the
written spacing (so 1/100 and 1/150 rows agree), and a bay is taken as drawn only when at least 2 rows show it and >= 70 % of
them agree within 3 % (value snapped to 50 mm). Disagreeing bays keep the written spacing and are reported as a question.
Found on EC 1003: FR.23-24 = 800 and FR.24-25 = 2000 in every plan row; X(24) = 37600, not 24 x 1600.
Offline: only the PDF text."""
import re, statistics
from collections import defaultdict

ROW_NUM = re.compile(r'^\s*(?:FR\.?\s*)?(\d{1,3})\s*$')


def _rows(page):
    rows = defaultdict(list)
    for w in page.words:
        m = ROW_NUM.match(w.text)
        if m and not w.vertical and w.size < 9:
            rows[round(w.cy / 3)].append((int(m.group(1)), w.cx))
    out = []
    for ws in rows.values():
        ws.sort(key=lambda t: t[1])
        grp = [ws[0]]
        for n, x in ws[1:]:
            if n != grp[-1][0] + 1 or x - grp[-1][1] > 200 or x <= grp[-1][1]:
                if len(grp) >= 3:
                    out.append(grp)
                grp = [(n, x)]
            else:
                grp.append((n, x))
        if len(grp) >= 3:
            out.append(grp)
    return out


def sheet_mm_per_pt(page):
    """R-FC3: mm per pt of the sheet scale printed in the title block ('SCALE' next to '1/100'); None when not found."""
    sc = [w for w in page.words if w.text.upper().startswith('SCALE')]
    for w in page.words:
        m = re.match(r'^1\s*/\s*(\d{2,3})$', w.text)
        if m and int(m.group(1)) in (50, 75, 100, 150, 200, 250, 300, 500) and any(abs(w.cx - s.cx) < 250 and abs(w.cy - s.cy) < 250 for s in sc):
            return 25.4 / 72.0 * int(m.group(1)), int(m.group(1))
    return None


def table(pdf, spacing, pages=None):
    """{'table': {n: X}, 'bays': {(n, n+1): mm}, 'questions': [...], 'rows': k}; X(n) = n * spacing up to the first shown bay."""
    from . import pdfsrc
    import pymupdf
    n_pages = len(pymupdf.open(pdf))
    meas = defaultdict(list)
    rowpos = []                                              # (k, {n: x}) per measured row
    nrows = 0
    for pg in (pages or range(n_pages)):
        page = pdfsrc.load_page(pdf, pg)
        for row in _rows(page):
            d = [(row[i][0], row[i + 1][1] - row[i][1]) for i in range(len(row) - 1)]
            med = statistics.median(dx for _, dx in d)
            base = [dx for _, dx in d if abs(dx / med - 1) < 0.03]
            k = None
            sh = sheet_mm_per_pt(page)
            if sh:
                # R-FC3: a row printed at the SHEET scale (some bays = the written spacing at that scale) is measured with that scale -
                # a row with two kinds of bays (1800 and 900: 6 + 6) has no usable median
                ks = sh[0]
                if sum(1 for _, dx in d if abs(dx * ks / spacing - 1) < 0.03) >= 2:
                    k = ks
            if k is None:
                if len(base) < 2:
                    continue
                k = spacing / statistics.median(base)        # mm per pt of THIS row, from its written-spacing bays
            nrows += 1
            rowpos.append((k, dict(row)))
            for n, dx in d:
                meas[n].append(dx * k)
    bays, questions = {}, []
    for n, vals in sorted(meas.items()):
        if len(vals) < 2:
            continue
        med = statistics.median(vals)
        agree = [v for v in vals if abs(v / med - 1) <= 0.03]
        val = round(statistics.median(agree) / 50.0) * 50.0
        if abs(val - spacing) < 0.03 * spacing:
            continue
        if len(agree) >= 0.7 * len(vals):
            bays[(n, n + 1)] = val
        else:
            questions.append(f'FR.{n}-{n + 1}: the rows disagree ({", ".join("%.0f" % v for v in vals)} mm); written spacing {spacing:g} kept - frame table?')
    # R-FC4: a run of neighbouring drawn bays of about the same size is the span of the run / its bays (a label centre is +-1 pt off,
    # one bay alone is +-35 mm at 1/100; the span of a run is not)
    keys = sorted(bays)
    runs, cur = [], []
    for kk in keys:
        if cur and kk[0] == cur[-1][0] + 1 and abs(bays[kk] / bays[cur[-1]] - 1) <= 0.03:
            cur.append(kk)
        else:
            if cur:
                runs.append(cur)
            cur = [kk]
    if cur:
        runs.append(cur)
    for run in runs:
        if len(run) < 3:
            continue
        a, b = run[0][0], run[-1][1]
        vals = [(pos[b] - pos[a]) * kk / (b - a) for kk, pos in rowpos if a in pos and b in pos]
        if len(vals) >= 2:
            v = round(statistics.median(vals) / 10.0) * 10.0
            for kk in run:
                bays[kk] = v
    if not bays:
        return {'table': {}, 'bays': {}, 'questions': questions, 'rows': nrows}
    nmax = max(max(meas), max(b for _, b in bays)) + 40
    tab, x = {}, 0.0
    for n in range(0, nmax + 1):
        tab[n] = x
        x += bays.get((n, n + 1), spacing)
    return {'table': tab, 'bays': {f'{a}-{b}': v for (a, b), v in bays.items()}, 'questions': questions, 'rows': nrows}
