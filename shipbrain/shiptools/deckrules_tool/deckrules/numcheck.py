"""R-T15 numeric check against dimension chains (Step 1, scanned pages).

A row (or column) of spacing numbers on a drawing is printed centred in its segments, so neighbouring numbers a, b stand (a + b) / 2 apart in the drawing scale:
pitch = distance / ((a + b) / 2) is the same all along the chain.  A number that breaks this for BOTH of its pairs while one single-character edit (substitute / drop-in a digit)
restores it for both is a misread and is repaired.  Nothing else is changed; chains with growing values (cumulative positions) and rows with less than 4 numbers are skipped.
"""
import re
import numpy as np

TOL = 0.12          # pair pitch must be within 12 % of the chain median after repair
MINROW = 6          # rows of fewer numbers are not chains
MINOK = 0.8         # share of consistent pairs a chain needs
BAD = 0.30          # a pair is 'broken' when it deviates by more than 30 %


_ROT = str.maketrans('69', '96')


def rot180(s):
    """The digits as they read when the text is turned 180 degrees (6 <-> 9, order reversed; 0, 1, 8 unchanged)."""
    return s[::-1].translate(_ROT)


def _candidates(v):
    s = str(v)
    out = set()
    for i, c in enumerate(s):
        for d in '0123456789':
            if d != c:
                t = s[:i] + d + s[i + 1:]
                if t[0] != '0':
                    out.add(int(t))
    for i in range(len(s) + 1):
        for d in '123456789' if i == 0 else '0123456789':
            out.add(int(s[:i] + d + s[i:]))
    for i in range(len(s)):                      # an extra glyph read (a line taken for 1)
        t = s[:i] + s[i + 1:]
        if t and t[0] != '0':
            out.add(int(t))
    r = rot180(s)
    if r[0] != '0':
        out.add(int(r))
    out.discard(v)
    return [c for c in out if 2 <= len(str(c)) <= 5]


def _clusters(items, key, size):
    items = sorted(items, key=lambda it: it[key])
    cl, cur = [], []
    for it in items:
        if cur and abs(it[key] - np.mean([c[key] for c in cur])) > 0.6 * np.mean([c[size] for c in cur]):
            cl.append(cur); cur = []
        cur.append(it)
    if cur:
        cl.append(cur)
    return cl


def check(lines):
    """lines: objects with .text and .box (4x2 array, px or pt, same unit) and .vertical.  Repairs .text in place; returns [(old, new, n_in_chain)]."""
    items = []
    for ln in lines:
        t = ln.text.strip()
        if re.fullmatch(r'\d{2,5}', t):
            b = ln.box
            x0, y0, x1, y1 = b[:, 0].min(), b[:, 1].min(), b[:, 0].max(), b[:, 1].max()
            vert = bool(ln.vertical) or (y1 - y0) > 1.3 * (x1 - x0)
            items.append(dict(ln=ln, v=int(t), cx=(x0 + x1) / 2, cy=(y0 + y1) / 2, th=(x1 - x0) if vert else (y1 - y0), vert=vert, cw=((y1 - y0) if vert else (x1 - x0)) / len(t)))
    # duplicates (the same number read twice at the same place by the OCR and the residual pass) would give zero spacing
    seen, uniq = [], []
    for it in sorted(items, key=lambda q: -q['ln'].score):
        if any(abs(it['cx'] - o['cx']) < 0.6 * max(it['th'], 1) and abs(it['cy'] - o['cy']) < 0.6 * max(it['th'], 1) for o in seen):
            continue
        seen.append(it); uniq.append(it)
    items_all, items = items, uniq
    fixes = []
    # R-T16: a dimension never starts with 0: a number that does was read upside down ('088' = 880, '009' = 600, '068' = 890, '806' is no case) -> turn it 180 degrees
    for it in items:
        s = it['ln'].text.strip()
        if len(s) >= 3 and s[0] == '0' and rot180(s)[0] != '0':      # 2-digit '07' may be a real label (revision, item no.)
            it['ln'].text = rot180(s)
            fixes.append((int(s), int(rot180(s)), 0))
            it['v'] = int(rot180(s))
    for vert in (False, True):
        sub = [it for it in items if it['vert'] == vert]
        key, pos = ('cx', 'cy') if vert else ('cy', 'cx')
        for row in _clusters(sub, key, 'th'):
            if len(row) < MINROW:
                continue
            row.sort(key=lambda it: it[pos])
            vs = np.array([it['v'] for it in row], float)
            if np.mean(np.diff(vs) > 0) > 0.8 or np.mean(np.diff(vs) < 0) > 0.8:
                continue
            ps = np.array([it[pos] for it in row], float)
            def pitch(i, a, b):
                return (ps[i + 1] - ps[i]) / ((a + b) / 2.0)
            sc = np.array([pitch(i, vs[i], vs[i + 1]) for i in range(len(row) - 1)])
            med = float(np.median(sc))
            if med <= 0:
                continue
            ok = np.abs(sc / med - 1) <= BAD
            if ok.mean() < MINOK or np.any(np.diff(ps) <= 0):
                continue
            for k in range(len(row)):
                pairs = [i for i in (k - 1, k) if 0 <= i < len(row) - 1]
                if not pairs or not all(not ok[i] for i in pairs) or len(pairs) < 2 and len(row) > 2 and False:
                    continue
                best = []
                cws = np.median([it['cw'] for it in row])
                same_len = abs(row[k]['cw'] / cws - 1) <= 0.30          # the box holds as many characters as its neighbours' boxes -> only a substitution is allowed
                for c in _candidates(row[k]['v']):
                    if same_len and len(str(c)) != len(str(row[k]['v'])):
                        continue
                    dev = []
                    for i in pairs:
                        a, b = (c, vs[i + 1]) if i == k else (vs[i], c)
                        dev.append(abs(pitch(i, a, b) / med - 1))
                    if max(dev) <= TOL:
                        best.append((max(dev), c))
                best.sort()
                if best and (len(best) == 1 or best[1][0] > 2 * best[0][0] + 0.03):
                    old = row[k]['v']
                    row[k]['ln'].text = str(best[0][1])
                    vs[k] = best[0][1]
                    fixes.append((old, best[0][1], len(row)))
    return fixes
