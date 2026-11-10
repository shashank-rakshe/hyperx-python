"""Step 2: the FRAME CHAIN - the spacing between frame labels as the drawing WRITES it (owner rule v2.106).

A ship's frame spacing is not one number: the drawing writes it per gap ("FRAME SPACING : 800 | 850", "FRAME SPACE : 4200", "F.S : 1950", ...).
This module reads, offline, for every page:
  1. frame labels: "12", "FR.12", "-3", with an attached "+1/2" (12 + 1/2 = 12.5);
  2. rows of labels: a monotone sequence along one sheet axis, drifting at most 1:1 across it (slanted hull sides), >= 3 labels;
  3. written spacing values of the page: "F.S : n", "FRAME SPACE : n", "FRAME SPACING : n" and the bare numbers on the same dimension line ("| 850");
  4. the measured spacing of each gap = distance x scale / frames, snapped to the nearest written value (within 8 %);
     a gap that matches no written value is NOT taken (that is how zone numbers 1..6 or section ids are rejected).
Output <name>_framechain.csv: page,row,f_from,f_to,spacing_mm,measured_mm,source
Nothing is guessed: a gap without a written value is left out and listed as a gap by ask.py."""
import csv, os, re, glob, statistics

LAB_RX = re.compile(r'^\s*(?:FR\.?\s*)?(-?\d{1,3})\s*$')
FRAC_RX = re.compile(r'^\s*\+\s*(\d)\s*/\s*(\d)\s*$')
FS_RX = re.compile(r'(?:\bF\.?\s?S\.?|FRAME\s+SPAC(?:E|ING))\s*:?\s*(\d{3,5})(?!\d)', re.I)
TOL = 0.08


def _items(fp):
    out = []
    if os.path.exists(fp):
        for r in csv.DictReader(open(fp, encoding='utf-8')):
            t = (r.get('text') or '').strip()
            if t:
                x0, y0, x1, y1 = (float(r[k]) for k in ('x0', 'y0', 'x1', 'y1'))
                out.append(dict(t=t, x=(x0 + x1) / 2, y=(y0 + y1) / 2, x0=x0, x1=x1, y0=y0, y1=y1))
    return out


def labels(items):
    """frame labels with their value (fraction attached)"""
    fr = [i for i in items if FRAC_RX.match(i['t'])]
    out = []
    for i in items:
        m = LAB_RX.match(i['t'])
        if not m:
            continue
        v = float(m.group(1))
        near = [f for f in fr if abs(f['x'] - i['x']) < 22 and abs(f['y'] - i['y']) < 22]
        if near:
            f = min(near, key=lambda f: (f['x'] - i['x']) ** 2 + (f['y'] - i['y']) ** 2)
            fm = FRAC_RX.match(f['t'])
            v += int(fm.group(1)) / int(fm.group(2)) if int(fm.group(2)) else 0
        out.append(dict(v=v, x=i['x'], y=i['y'], t=i['t']))
    return out


def chains(labs, ax):
    """monotone label sequences along axis ax (value changes by <= 6 per step, 6..400 pt apart, drift across the axis <= along + 12)"""
    oth = 'y' if ax == 'x' else 'x'
    L = sorted(labs, key=lambda l: l[ax])
    used = set()
    out = []
    for i, a in enumerate(L):
        if i in used:
            continue
        for sgn in (1, -1):
            seq, cur = [i], a
            while True:
                nxt = None
                for j in range(seq[-1] + 1, len(L)):
                    b = L[j]
                    d = b[ax] - cur[ax]
                    if d > 400:
                        break
                    if d < 6 or j in used:
                        continue
                    dv = (b['v'] - cur['v']) * sgn
                    if 0 < dv <= 6 and abs(b[oth] - cur[oth]) <= d + 12:
                        nxt = j
                        break
                if nxt is None:
                    break
                seq.append(nxt)
                cur = L[nxt]
            if len(seq) >= 3:
                out.append([L[k] for k in seq])
                used.update(seq)
                break
    return out


def written(items):
    """written spacing values and where they stand: [(value, x, y)]"""
    out = []
    fs = []
    for i in items:
        m = FS_RX.search(i['t'])
        if m:
            fs.append((int(m.group(1)), i['x'], i['y']))
    out += fs
    for v, x, y in fs:                     # '| 850' : a bare number on the same dimension line
        for i in items:
            if re.fullmatch(r'\s*\d{3,4}\s*', i['t']) and 300 <= int(i['t']) <= 6000 and (abs(i['y'] - y) < 4 or abs(i['x'] - x) < 4) and abs(i['x'] - x) + abs(i['y'] - y) < 260:
                out.append((int(i['t']), i['x'], i['y']))
    return out


def _scale_for(row, footprints, ax):
    """mm per pt along the row: the plan footprint that holds the row (its written OFF C.L scale), else the median of the page"""
    cx = statistics.mean(l['x'] for l in row)
    cy = statistics.mean(l['y'] for l in row)
    best = None
    for f in footprints:
        try:
            x0, y0, x1, y1 = (float(f[k]) for k in ('rect_x0', 'rect_y0', 'rect_x1', 'rect_y1'))
            k = float(f['offcl_k'])
        except (ValueError, KeyError, TypeError):
            continue
        d = max(x0 - cx, 0, cx - x1) ** 2 + max(y0 - cy, 0, cy - y1) ** 2
        if best is None or d < best[0]:
            best = (d, k)
    return best[1] if best else None


def build(folder, name):
    from . import ask as A
    pages = sorted(int(m.group(1)) for m in (re.search(r'_p(\d+)_text\.csv$', f) for f in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv'))) if m)
    fp_all = A._read(os.path.join(folder, name + '_frames.csv')) if os.path.exists(os.path.join(folder, name + '_frames.csv')) else []
    rows = []
    for pg in pages:
        items = _items(os.path.join(folder, '%s_p%d_text.csv' % (name, pg)))
        W = written(items)
        vals = sorted({v for v, _, _ in W})
        if not vals:
            continue
        labs = labels(items)
        foot = [f for f in fp_all if int(f['page']) == pg]
        rid = 0
        for ax in ('x', 'y'):
            for seq in chains(labs, ax):
                k = _scale_for(seq, [f for f in foot if f.get('offcl_axis') and f['offcl_axis'] != ax], ax)
                if not k:
                    continue
                rid += 1
                for a, b in zip(seq, seq[1:]):
                    df = abs(b['v'] - a['v'])
                    meas = abs(b[ax] - a[ax]) * k / df
                    v = min(vals, key=lambda v: abs(v - meas))
                    ok = abs(v / meas - 1) <= TOL
                    rows.append(dict(page=pg, row=rid, axis=ax, f_from=a['v'], f_to=b['v'], spacing_mm=v if ok else '', measured_mm=round(meas),
                                     source='written %d (measured %d)' % (v, round(meas)) if ok else 'no written value matches %d' % round(meas)))
    cols = ['page', 'row', 'axis', 'f_from', 'f_to', 'spacing_mm', 'measured_mm', 'source']
    with open(os.path.join(folder, name + '_framechain.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, cols)
        w.writeheader()
        w.writerows(rows)
    return rows


if __name__ == '__main__':
    import sys
    r = build(sys.argv[1], sys.argv[2])
    print(len(r), 'gaps,', sum(1 for x in r if x['spacing_mm'] != ''), 'with a written value')
