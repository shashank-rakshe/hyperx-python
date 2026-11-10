"""RULE 2 (Step 2) - scale and dimensions, WRITTEN TEXT FIRST (owner 2026-10-24; RULES.md v2.76).  Universal, offline; reads only the Step-1 CSV files.

a) find the scale WRITTEN in the drawing           ->  find_written()
b) scale it (mm per page unit)                      ->  mm_per_pt(denominator): a page unit is 1/72 inch of paper, so 1:D means D * 25.4 / 72 mm of ship per pt
c) compare the drawn dimensions with the written text ->  measure_chains() + compare(): rows / columns of printed dimension numbers give the scale the drawing really has
d) the written text has first priority              ->  a written scale is never replaced by a measured one; a mismatch is REPORTED
e) a dimension not written -> correlate with other views (section, deck, OFF C.L, frame)  ->  Step 3 asks scale_for(); the lookup list is recorded as `lookup`
f) last option = the scale check                      ->  scale_for() returns source 'written' / 'sheet' / 'measured'
Everything keeps its SOURCE.
"""
import csv
import os
import re
import glob
import collections
import numpy as np

PT_MM = 25.4 / 72.0
STD = (5, 10, 15, 20, 25, 30, 40, 50, 60, 75, 80, 100, 125, 150, 200, 250, 300, 500)
RX = [
    re.compile(r'\(?\s*S(?:CALE)?\s*[:=]\s*:?\s*1\s*[:/]\s*(\d{1,4})\s*\)?', re.I),       # (S : 1/50) (SCALE : 1/50) (S=1/20) SCALE: 1/15
    re.compile(r'\bSCALE\s*1\s*[:/]\s*(\d{1,4})\b', re.I),
]
NONSCALE = re.compile(r'N\.?\s*T\.?\s*S\b|NON[\s-]*SCALE|NOT\s+TO\s+SCALE', re.I)
TITLE = re.compile(r'\b(PLAN|DECK|ELEV|SEC\.?|SECTION|DETAIL|VIEW|BULKHEAD|FRAME|SHELL|PROFILE|ARRANGEMENT)\b', re.I)
BARE = re.compile(r'^\s*1\s*[:/]\s*(\d{1,4})\s*$')


SHRINK = (1.0, 2 ** 0.5, 2.0, 2 ** 1.5, 4.0, 2 ** 2.5, 8.0)       # plot sheet -> PDF page: 1, A0->A1, ->A2, ->A3, ->A4 ...  (the PDF is often a reduced copy of the plotted sheet)


def mm_per_pt(den, f=1.0):
    """b) a page unit is 1/72 inch of the PLOT SHEET; when the PDF is a reduced copy (factor f) one pt is f times more ship"""
    return PT_MM * den * f


def _read_text(fp):
    out = []
    if not os.path.exists(fp):
        return out
    for r in csv.DictReader(open(fp, encoding='utf-8')):
        t = r['text'].strip()
        if not t:
            continue
        x0, y0, x1, y1 = (float(r[k]) for k in ('x0', 'y0', 'x1', 'y1'))
        out.append(dict(t=t, x0=x0, y0=y0, x1=x1, y1=y1, cx=(x0 + x1) / 2, cy=(y0 + y1) / 2, dx=float(r['dir_x'] or 1), dy=float(r['dir_y'] or 0), src=r['source'], score=float(r['score'] or 1)))
    return out


def find_written(items):
    """(a) every written scale: dict(kind='view'|'sheet'|'nonscale', den, text, x, y, title, title_pos)"""
    found = []
    for it in items:
        t = it['t']
        if NONSCALE.search(t) and len(t) < 40:
            found.append(dict(kind='nonscale', den=None, text=t, x=it['cx'], y=it['cy'], src=it['src']))
            continue
        for rx in RX:
            m = rx.search(t)
            if m and len(t) < 70:
                found.append(dict(kind='view', den=int(m.group(1)), text=t, x=it['cx'], y=it['cy'], src=it['src']))
                break
    # title-block pair: a 'SCALE' label followed by a bare 1/100 close by -> the sheet scale
    labels = [it for it in items if re.fullmatch(r'SCALE\s*:?', it['t'], re.I)]
    bares = [(it, BARE.match(it['t'])) for it in items if BARE.match(it['t'])]
    for lb in labels:
        near = [(abs(b['cx'] - lb['cx']) + abs(b['cy'] - lb['cy']), b, m) for b, m in bares if abs(b['cx'] - lb['cx']) < 400 and abs(b['cy'] - lb['cy']) < 120]
        if near:
            _, b, m = min(near, key=lambda q: q[0])
            found.append(dict(kind='sheet', den=int(m.group(1)), text='SCALE ' + b['t'], x=b['cx'], y=b['cy'], src=b['src']))
    # titles -> nearest title of each view scale
    titles = [it for it in items if TITLE.search(it['t']) and 3 <= len(it['t']) <= 70 and not RX[0].search(it['t'])]
    for f in found:
        if f['kind'] == 'view' and titles:
            d, ti = min(((abs(t['cx'] - f['x']) * 0.6 + abs(t['cy'] - f['y'])), t) for t in titles)
            f['title'] = ti['t']; f['title_pos'] = (round(ti['cx']), round(ti['cy'])); f['title_dist'] = round(d)
    return found


def measure_chains(items, min_n=4):
    """(c) rows / columns of 3-4 digit dimension numbers -> list of dict(n, orient, pos, mm, span, mm_per_pt, den)"""
    res = []
    nums = [it for it in items if re.fullmatch(r'\d{3,4}', it['t'])]
    for orient in ('H', 'V'):
        sel = [it for it in nums if (abs(it['dx']) >= abs(it['dy'])) == (orient == 'H')]
        if orient == 'H':
            sel = [it for it in sel if (it['x1'] - it['x0']) >= (it['y1'] - it['y0'])]
        else:
            sel = [it for it in sel if (it['y1'] - it['y0']) > (it['x1'] - it['x0'])]
        key, ax = ('cy', 'cx') if orient == 'H' else ('cx', 'cy')
        rows = collections.defaultdict(list)
        for it in sel:
            rows[round(it[key] / 3)].append(it)
        for k, r in rows.items():
            r.sort(key=lambda q: q[ax])
            # split into runs at big gaps
            xs = np.array([q[ax] for q in r])
            if len(r) < min_n:
                continue
            gaps = np.diff(xs)
            med = np.median(gaps[gaps > 0.5]) if np.any(gaps > 0.5) else 0
            runs, cur = [], [0]
            for i, g in enumerate(gaps):
                if med and g > 3.5 * med:
                    runs.append(cur); cur = []
                cur.append(i + 1)
            runs.append(cur)
            for run in runs:
                if len(run) < min_n:
                    continue
                its = [r[i] for i in run]
                vs = np.array([int(q['t']) for q in its], float)
                ps = np.array([q[ax] for q in its])
                if np.mean(np.diff(vs) > 0) > 0.8 or np.mean(np.diff(vs) < 0) > 0.8:
                    continue                                   # cumulative positions, not spacings
                span = ps[-1] - ps[0]
                if span <= 0:
                    continue
                mm = vs[0] / 2 + vs[1:-1].sum() + vs[-1] / 2
                # robust: every neighbouring pair (a, b) stands (a + b) / 2 apart (numbers are printed centred in their segments); the MEDIAN of the pairs ignores stray numbers
                pr = ((vs[:-1] + vs[1:]) / 2.0) / np.maximum(np.diff(ps), 1e-6)
                s = float(np.median(pr))
                if np.mean(np.abs(pr / s - 1) <= 0.10) < 0.6:
                    continue                                   # not a regular chain
                th = np.median([(q['y1'] - q['y0']) if orient == 'H' else (q['x1'] - q['x0']) for q in its])
                if np.median(np.diff(ps)) > 30 * max(th, 1.0):
                    continue                                   # numbers spread over the sheet (a table row), not a dimension line
                res.append(dict(n=len(its), orient=orient, pos=round(float(np.mean([q[key] for q in its]))), a0=round(float(ps[0])), a1=round(float(ps[-1])), mm=round(float(mm)), mm_per_pt=round(float(s), 3),
                                den=round(float(s / PT_MM), 1)))
    return res


def page_factor(written, chains, tol=0.08):
    """the PDF page may be a reduced copy of the plot sheet (A0 -> A3 = 2.83): the factor f for which most chains agree with a written scale (written scale x f).  f = 1 when nothing contradicts."""
    dens = sorted({w['den'] for w in written if w['den']})
    best = (0, 1.0)
    for f in SHRINK:
        n = sum(1 for c in chains if any(abs(c['den'] / (d * f) - 1) <= tol for d in dens))
        if n > best[0] or (n == best[0] and n and f == 1.0):
            best = (n, f)
    return best[1], best[0]


def compare(written, chains, tol=0.08, f=1.0):
    """(c)+(d): which written scale does each measured chain support?  Written text stays first; a measured scale equal to no written one is reported."""
    dens = sorted({w['den'] for w in written if w['den']})
    rows = []
    for c in chains:
        hit = [d for d in dens if abs(c['den'] / (d * f) - 1) <= tol]
        std = min(STD, key=lambda d: abs(np.log(c['den'] / f / d)))
        c = dict(c, supports=hit[0] if hit else None, nearest_std=std if abs(c['den'] / f / std - 1) <= tol else None)
        rows.append(c)
    return rows


def scale_for(written, rows, x=None, y=None):
    """what a later step gets for a point: (denominator, source).  e) correlation with other views is the caller's job (lookup list in LOOKUP)."""
    views = [w for w in written if w['kind'] == 'view']
    if x is not None and views:
        w = min(views, key=lambda w: abs(w['x'] - x) * 0.6 + abs(w['y'] - y))
        return w['den'], 'written(view)'
    sheet = [w for w in written if w['kind'] == 'sheet']
    if sheet:
        return sheet[0]['den'], 'written(sheet)'
    sup = collections.Counter(r['nearest_std'] for r in rows if r['nearest_std'])
    if sup:
        return sup.most_common(1)[0][0], 'measured'
    return None, 'none'


VIEWS = {}
INDEX = {}
LOOKUP = ('same frame number in another view', 'same member in a section / detail', 'deck plan', 'OFF C.L / longitudinal view', 'then scale check (measured)')


def run(outdir, name, pages, sizes=None):
    lines = ['# STEP 2 / RULE 2 - written scale first (offline)', '',
             'a) written scales found, b) in mm per pt (1 pt = 1/72 inch of paper), c) compared with the scale the printed dimension chains really have, d) written text first.', '']
    summary = []
    # the plot-sheet -> PDF reduction is a property of the SHEET SIZE: pages of the same size vote together (few chains per page make a single page unreliable)
    data = {}
    for n in pages:
        items = _read_text(os.path.join(outdir, f'{name}_p{n}_text.csv'))
        if items:
            wr = find_written(items)
            data[n] = (items, wr, measure_chains(items))
    groups = collections.defaultdict(list)
    for n in data:
        groups[round(min(sizes[n])) if sizes else 0].append(n)             # same short side = same sheet height / scanner setting
    fac = {}
    for g, ns in groups.items():
        votes = {}
        for f_ in SHRINK:
            uniq = set()                                   # the same chain printed in several stacked views must count ONCE
            for n in ns:
                _, wr_, raw_ = data[n]
                dens = sorted({w['den'] for w in wr_ if w['den']})
                for c in raw_:
                    if any(abs(c['den'] / (d * f_) - 1) <= 0.08 for d in dens):
                        uniq.add((n, c['mm'], round(c['den'])))
            votes[f_] = len(uniq)
        # f = 1 (the PDF page IS the plot sheet) unless another factor wins clearly: at least 3 distinct chains and twice the votes of f = 1
        best = (votes[1.0], 1.0)
        for f_, v in votes.items():
            if f_ != 1.0 and v >= 3 and v >= 2 * max(votes[1.0], 1) and v > best[0]:
                best = (v, f_)
        # refine: the exact factor = median of (measured denominator / written denominator) of the chains that agree with the winning factor (scans are not exact A-series copies)
        if best[1] != 1.0 or True:
            rat = []
            for n in ns:
                _, wr_, raw_ = data[n]
                dens = sorted({w['den'] for w in wr_ if w['den']})
                for c in raw_:
                    hit = [d for d in dens if abs(c['den'] / (d * best[1]) - 1) <= 0.08]
                    if hit:
                        rat.append(c['den'] / hit[0])
            if len(set(round(r, 1) for r in rat)) >= 1 and len(rat) >= 3:
                best = (best[0], float(np.median(rat)))
        for n in ns:
            fac[n] = best
    for n in pages:
        if n not in data:
            continue
        items, wr, raw = data[n]
        nf, f = fac[n]
        ch = compare(wr, raw, f=f)
        sup = collections.Counter(c['supports'] for c in ch if c['supports'])
        lines += [f'## Page {n}', '']
        if abs(f - 1.0) > 0.03:
            lines += [f'**This PDF page is a reduced copy of the plotted sheet: factor {f:.2f} (A0 -> A3 = 2.83, A0 -> A1 = 1.41), found from {nf} dimension chains of all pages of this sheet size that agree with a written scale with it.  mm per pt = 25.4/72 x denominator x {f:.2f}.**', '']
        if wr:
            lines += ['| written | kind | 1 : | mm per pt | position pt | nearest view title | chains supporting it |', '|---|---|---|---|---|---|---|']
            for w in sorted(wr, key=lambda w: (w['kind'], w['y'])):
                d = w['den']
                lines.append(f"| {w['text']} | {w['kind']} | {d or ''} | {round(mm_per_pt(d, f), 2) if d else ''} | ({round(w['x'])}, {round(w['y'])}) | {w.get('title', '')} | {sup.get(d, 0) if d else ''} |")
        else:
            lines.append('no written scale found on this page')
        lines.append('')
        if ch:
            lines += ['| chain | numbers | along pt | dims sum mm | measured mm/pt | = 1 : | supports written | nearest standard |', '|---|---|---|---|---|---|---|---|']
            for c in ch:
                lines.append(f"| {c['orient']} {c['pos']} | {c['n']} | {c['a0']}..{c['a1']} | {c['mm']} | {c['mm_per_pt']} | {c['den']} | {c['supports'] or '-'} | {c['nearest_std'] or '-'} |")
            nsup = sum(1 for c in ch if c['supports'])
            lines.append('')
            lines.append(f'{nsup} of {len(ch)} chains agree with a written scale (within 8 %); {len(ch) - nsup} do not (listed above with "-").')
            unw = collections.Counter(c['nearest_std'] for c in ch if not c['supports'] and c['nearest_std'])
            if unw:
                lines += ['', 'Measured but NOT written (rule d: the written text stays first - these views have no written scale or a different one; rule e / f decide for them): ' + ', '.join(f'1:{d} ({k} chains)' for d, k in unw.most_common()) + '.']
        else:
            lines.append('no dimension chain of >= 4 numbers on this page')
        lines.append('')
        # ---- scale PER VIEW REGION, non-scale views, correlation index
        segs = _read_segments(outdir, name, n)
        sheet = [w['den'] for w in wr if w['kind'] == 'sheet']
        vt = []
        if segs and sizes:
            boxes = find_views(segs, sizes[n][0], sizes[n][1])
            vt = view_table(items, wr, raw, boxes, f, sheet[0] if sheet else None)
            idx = build_index(items, vt)
            with open(os.path.join(outdir, f'{name}_p{n}_views.csv'), 'w', newline='', encoding='utf-8') as fv:
                wv = csv.writer(fv); wv.writerow(['view', 'x0', 'y0', 'x1', 'y1', 'title', 'denominator', 'mm_per_pt', 'scale_source', 'status', 'chains', 'measured_denominator'])
                for i, v in enumerate(vt):
                    wv.writerow([i, *v['box'], ' | '.join(v['titles']), v['den'] or '', round(mm_per_pt(v['den'], f), 2) if v['den'] else '', v['source'], v['status'], v['nchain'], v['measured'] or ''])
            with open(os.path.join(outdir, f'{name}_p{n}_index.csv'), 'w', newline='', encoding='utf-8') as fi:
                wi = csv.writer(fi); wi.writerow(['kind', 'key', 'text', 'x', 'y', 'view'])
                for r in idx:
                    wi.writerow([r['kind'], r['key'], r['text'], r['x'], r['y'], '' if r['view'] is None else r['view']])
            INDEX[(name, n)] = idx
            lines += [f'### Views of page {n} (scale per view region; written text first)', '', '| view | region pt | title | 1 : | mm per pt | source | status | chains |', '|---|---|---|---|---|---|---|---|']
            for i, v in enumerate(vt):
                lines.append(f"| {i} | {v['box'][0]},{v['box'][1]}..{v['box'][2]},{v['box'][3]} | {'; '.join(v['titles'][:2])[:60]} | {v['den'] or ''} | {round(mm_per_pt(v['den'], f), 2) if v['den'] else ''} | {v['source']} | {v['status']} | {v['nchain']} |")
            lines.append('')
        VIEWS[(name, n)] = vt
        summary.append((n, len(wr), len(ch), sum(1 for c in ch if c['supports']), round(f, 2)))
    lines += ['## Lookup order when a dimension is not written (rule e)', ''] + [f'{i + 1}. {t}' for i, t in enumerate(LOOKUP)]
    fp = os.path.join(outdir, f'{name}_step2_rule2.md')
    open(fp, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    return fp, summary


def main(argv=None):
    import argparse
    from . import read_drawing as rd
    import pymupdf
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf'); ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    nm = os.path.splitext(os.path.basename(a.pdf))[0]
    os.makedirs(a.out, exist_ok=True)
    if not glob.glob(os.path.join(a.out, f'{nm}_p1_text.csv')):
        rd.dump_raw(a.pdf, a.out, nm)
    n = len(pymupdf.open(a.pdf))
    doc = pymupdf.open(a.pdf)
    fp, summ = run(a.out, nm, range(1, n + 1), {i + 1: (p.mediabox.width, p.mediabox.height) for i, p in enumerate(doc)})
    print('wrote', fp)
    from . import plans, facts, viewscale
    facts.build(a.out, nm)
    pl = plans.build(a.out, nm)
    vs = viewscale.build(a.out, nm)
    from . import windows as _windows, sheerchain
    wn = _windows.build(a.out, nm)
    print('view windows:', sum(1 for w in wn if w[2][0] is not None), 'of', len(wn), 'titles have their own window')
    sc = sheerchain.build(a.out, nm)
    print('sheer ranges read from the dimension chain:', sum(1 for r in sc if r['from_fr'] != ''), 'of', len(sc), 'printed SHEER labels')
    print('view scales:', len(vs), 'titles;', sum(1 for r in vs if r['status'].startswith('DIFFERENT')), 'label/text conflicts;', sum(1 for r in vs if r['source'].startswith('label')), 'from written labels')
    print('plan table:', len(pl), 'plan/arrangement titles;', sum(1 for r in pl if r['verdict'].startswith('DIFFERENT')), 'drawn at another scale than the sheet')
    for s in summ:
        print('page %d: written %d, chains %d, agreeing %d, page factor %s' % s)



# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# views: scale PER VIEW REGION, non-scale views, correlation index (owner 2026-10-24: "update rule 2, the points you are missing")
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
def _read_segments(outdir, name, n):
    fp = os.path.join(outdir, f'{name}_p{n}_segments.csv')
    out = []
    if not os.path.exists(fp):
        return out
    for r in csv.DictReader(open(fp, encoding='utf-8')):
        try:
            if r['kind'] == 'l':
                out.append((float(r['x1']), float(r['y1']), float(r['x2']), float(r['y2'])))
            elif r['kind'] == 'c':
                out.append((float(r['x1']), float(r['y1']), float(r['x4']), float(r['y4'])))
            elif r['kind'] == 're':
                x1, y1, x2, y2 = (float(r[k]) for k in ('x1', 'y1', 'x2', 'y2'))
                out += [(x1, y1, x2, y1), (x2, y1, x2, y2), (x2, y2, x1, y2), (x1, y2, x1, y1)]
        except (ValueError, KeyError, TypeError):
            continue
    return out


def find_views(segs, page_w, page_h, cell=10.0, grow=45.0, min_size=120.0):
    """view regions = connected clouds of line work: every line is drawn on a coarse grid (10 pt cells), the grid is grown by `grow` pt (a gap smaller than this stays inside one view), connected
    components are the views.  Lines longer than 45 % of the sheet (sheet border, title-block frame) are ignored.  -> list of (x0, y0, x1, y1) pt"""
    import cv2
    W, H = int(page_w / cell) + 2, int(page_h / cell) + 2
    g = np.zeros((H, W), np.uint8)
    for x1, y1, x2, y2 in segs:
        if abs(x2 - x1) > 0.45 * page_w or abs(y2 - y1) > 0.45 * page_h:
            continue
        cv2.line(g, (int(x1 / cell), int(y1 / cell)), (int(x2 / cell), int(y2 / cell)), 255, 1)
    k = int(grow / cell) | 1
    g = cv2.dilate(g, np.ones((k, k), np.uint8))
    n, lab, st, _ = cv2.connectedComponentsWithStats(g, connectivity=8)
    out = []
    for i in range(1, n):
        x, y, w, h = st[i, :4]
        # shrink back by the growth margin
        bx0, by0, bx1, by1 = x * cell + grow / 2, y * cell + grow / 2, (x + w) * cell - grow / 2, (y + h) * cell - grow / 2
        if bx1 - bx0 >= min_size and by1 - by0 >= min_size:
            out.append((bx0, by0, bx1, by1))
    return out


def _inside(it, box, m=0.0):
    return box[0] - m <= it['cx'] <= box[2] + m and box[1] - m <= it['cy'] <= box[3] + m


def view_table(items, written, chains_all, boxes, f, page_den_sheet=None):
    """per view region: its titles, the scale written for it (own > sheet), non-scale flag, the chains inside it and what they measure"""
    titles = [it for it in items if TITLE.search(it['t']) and 3 <= len(it['t']) <= 70 and not RX[0].search(it['t'])]
    views = []
    for b in sorted(boxes, key=lambda q: (round(q[1] / 200), q[0])):
        own = [w for w in written if w['kind'] == 'view' and b[0] - 60 <= w['x'] <= b[2] + 60 and b[1] - 60 <= w['y'] <= b[3] + 90]
        non = [w for w in written if w['kind'] == 'nonscale' and b[0] - 60 <= w['x'] <= b[2] + 60 and b[1] - 60 <= w['y'] <= b[3] + 90]
        tt = [t['t'] for t in titles if b[0] - 60 <= t['cx'] <= b[2] + 60 and b[1] - 60 <= t['cy'] <= b[3] + 90]
        ch = []
        for c in chains_all:
            pos = c['pos']; a0, a1 = c['a0'], c['a1']
            xs, ys = ((a0, a1), (pos, pos)) if c['orient'] == 'H' else ((pos, pos), (a0, a1))
            if b[0] - 30 <= (xs[0] + xs[1]) / 2 <= b[2] + 30 and b[1] - 30 <= (ys[0] + ys[1]) / 2 <= b[3] + 30:
                ch.append(c)
        dens = sorted({w['den'] for w in own})
        meas = float(np.median([c['den'] for c in ch])) / f if ch else None
        std = min(STD, key=lambda d: abs(np.log(meas / d))) if meas else None
        std = std if meas and abs(meas / std - 1) <= 0.08 else None
        if non and not own:
            status, den, src = 'non-scale', None, 'written(non-scale)'
        elif dens:
            den, src = dens[0], 'written(view)'
            status = 'no chain' if not ch else ('agree' if abs(meas / den - 1) <= 0.08 else f'DIFFERENT: measured 1:{std or round(meas)}')
        elif page_den_sheet:
            den, src = page_den_sheet, 'written(sheet)'
            status = 'no chain' if not ch else ('agree' if abs(meas / den - 1) <= 0.08 else f'DIFFERENT: measured 1:{std or round(meas)}')
        else:
            den, src, status = (std, 'measured', 'measured only') if std else (None, 'none', 'no scale')
        views.append(dict(box=tuple(round(v) for v in b), titles=tt[:3], den=den, source=src, status=status, written=dens, nchain=len(ch), measured=std or (round(meas) if meas else None)))
    return views


def scale_for_view(views, x, y):
    """the scale of the view region that contains the point (rule b + d); nearest region when it lies in none"""
    best = None
    for v in views:
        b = v['box']
        d = 0 if (b[0] <= x <= b[2] and b[1] <= y <= b[3]) else min(abs(x - b[0]), abs(x - b[2])) + min(abs(y - b[1]), abs(y - b[3]))
        if best is None or d < best[0]:
            best = (d, v)
    return (best[1]['den'], best[1]['source'], best[1]['status']) if best else (None, 'none', '')


INDEX_RX = collections.OrderedDict([
    ('frame', re.compile(r'\bFR\.?\s?(\d{1,3}(?:[+-]\d{1,4}(?:/\d)?)?)', re.I)),
    ('member', re.compile(r'\b(\d{2,4}\s?X\s?\d{2,3}\s?X\s?\d{1,3}(?:\s?/\s?\d{1,3})?)', re.I)),
    ('thickness', re.compile(r'(?:THK\.?\s*:?\s*|T\s*=\s*)(\d{1,3}(?:\.\d)?)|(\d{1,3}(?:\.\d)?)\s*THK', re.I)),
    ('offcl', re.compile(r'(\d{3,5})\s*OFF\s*C\.?L|OFF\s*C\.?L\.?\s*(\d{3,5})', re.I)),
    ('frame_space', re.compile(r'FRAME\s*SPACE\s*:?\s*(\d{1,2},\d{3}|\d{3,5})', re.I)),
    ('height_ab', re.compile(r'(\d{3,6})\s*A\s*/\s*B', re.I)),
    ('cut_mark', re.compile(r'^\W*"\s*([0-9A-Z]{1,3}[0-9A-Z]*-\d{1,3})\s*"\W*$')),
    ('deck', re.compile(r'\b([A-Z0-9]{1,3}[\s-]?DECK|UPPER DECK|MAIN DECK|TANK TOP|INNER BOTTOM)\b', re.I)),
])


def build_index(items, views):
    """(e) every written fact with the view it stands in: frame labels, member sizes, plate thicknesses, OFF C.L offsets, decks -> rows (kind, key, text, x, y, view_index)"""
    rows = []
    for it in items:
        t = it['t']
        for kind, rx in INDEX_RX.items():
            for m in rx.finditer(t):
                key = next((g for g in m.groups() if g), m.group(0)).replace(' ', '').upper()
                vi = next((i for i, v in enumerate(views) if v['box'][0] - 20 <= it['cx'] <= v['box'][2] + 20 and v['box'][1] - 20 <= it['cy'] <= v['box'][3] + 20), None)
                rows.append(dict(kind=kind, key=key, text=t[:60], x=round(it['cx']), y=round(it['cy']), view=vi))
    return rows


def correlate(index_by_page, kind, key, page, view):
    """rule e: where else is `kind`/`key` written?  Order of the lookup list: other views of the same page first (same sheet), then other pages.  -> list of (page, view, text)"""
    same, other = [], []
    for pg, rows in index_by_page.items():
        for r in rows:
            if r['kind'] == kind and r['key'] == key.replace(' ', '').upper() and not (pg == page and r['view'] == view):
                (same if pg == page else other).append((pg, r['view'], r['text']))
    return same + other



if __name__ == '__main__':
    main()
