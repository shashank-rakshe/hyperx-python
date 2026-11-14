"""Step 2: every view title gets its OWN view window (owner rule v2.98).

Why: the line-work clouds of rule2.find_views often merge several views (one box with 20 titles) or lie beside a title (rotated sheets: the title is
outside the cloud), so Step 3 could not find the frame / height labels that belong to a title.

How (all on the page's own drawn line work, offline):
  1. titles = Step-2 title facts; titles closer than 80 pt (stacked title lines) form one title cluster;
  2. the line work is grown by 45, 30, 20, 12 pt and cut into connected clouds at each level;
  3. a title cluster belongs to the cloud that contains it, or the nearest cloud within 6 % of the short sheet side;
  4. its window = the cloud at the LARGEST growth level in which no other title cluster shares that cloud (the whole view, gaps included);
  5. if the clusters still share a cloud at the finest level, the cloud is split: every line-work cell goes to the nearest title cluster, window = bounding box of its cells.
Output <name>_pN_windows.csv: title, x, y, x0, y0, x1, y1, method.
"""
import csv, os, re, glob
import numpy as np

LEVELS = (45.0, 30.0, 20.0, 12.0)
CELL = 10.0
MIN_SIZE = 120.0


def _segs(folder, name, n):
    from . import rule2
    return rule2._read_segments(folder, name, n)


def _clusters(pts, gap):
    seen, out = set(), []
    for i in range(len(pts)):
        if i in seen:
            continue
        grp, st = [], [i]
        seen.add(i)
        while st:
            a = st.pop()
            grp.append(a)
            for b in range(len(pts)):
                if b not in seen and (pts[a][0] - pts[b][0]) ** 2 + (pts[a][1] - pts[b][1]) ** 2 <= gap ** 2:
                    seen.add(b)
                    st.append(b)
        out.append(grp)
    return out


def _text_axis(folder, name, n):
    """the reading direction of the sheet's text (unit axis vector in the text csv's coordinates): the most common direction of long words"""
    import collections
    c = collections.Counter()
    fp = os.path.join(folder, '%s_p%d_text.csv' % (name, n))
    if os.path.exists(fp):
        for r in csv.DictReader(open(fp, encoding='utf-8')):
            if len((r['text'] or '').strip()) >= 8:
                try:
                    dx, dy = float(r['dir_x']), float(r['dir_y'])
                except (ValueError, KeyError, TypeError):
                    continue
                c[(round(dx), round(dy))] += 1
    return c.most_common(1)[0][0] if c else (1, 0)


def windows(segs, titles, W, H, u=(1, 0)):
    """titles: [(x, y)] -> [(x0, y0, x1, y1, method)] one per title.
    Sheet layout (any rotation): every title sits at one end of its view (above or below it) and the view fills the strip of the sheet between it and the
    next title of that direction.  In the reading frame of the text (s along the text, w across) every line-work cell goes to the nearest title that FACES it:
    cost = |s - s_title| + 0.15 x (distance along the view side); a cell behind a title is excluded; a title with no line work on either side has no window."""
    import cv2
    n_t = len(titles)
    if not titles or not segs:
        return [(None,) * 4 + ('no line work',) for _ in titles]
    gw, gh = int(W / CELL) + 2, int(H / CELL) + 2
    base = np.zeros((gh, gw), np.uint8)
    for x1, y1, x2, y2 in segs:
        if abs(x2 - x1) > 0.45 * W or abs(y2 - y1) > 0.45 * H:
            continue
        cv2.line(base, (int(x1 / CELL), int(y1 / CELL)), (int(x2 / CELL), int(y2 / CELL)), 255, 1)
    ys, xs = np.nonzero(base)
    cx, cy = xs * CELL + CELL / 2, ys * CELL + CELL / 2
    ux, uy = u
    sc, wc = cx * ux + cy * uy, -cx * uy + cy * ux
    cl = _clusters(titles, 80.0)
    P = [(np.mean([titles[i][0] for i in g]), np.mean([titles[i][1] for i in g])) for g in cl]
    ts = np.array([p[0] * ux + p[1] * uy for p in P])
    tw = np.array([-p[0] * uy + p[1] * ux for p in P])
    ups, dns = np.zeros(len(cl)), np.zeros(len(cl))
    for j in range(len(cl)):
        col = np.abs(sc - ts[j]) <= 120
        ups[j] = np.sum(col & (wc - tw[j] > 5) & (wc - tw[j] <= 160))
        dns[j] = np.sum(col & (tw[j] - wc > 5) & (tw[j] - wc <= 160))
    tot = (ups - dns) / np.maximum(ups + dns, 1)
    page_side = 1.0 if tot.sum() >= 0 else -1.0                        # the sheet's layout: titles above their views or below them (majority)
    side = np.zeros(len(cl))
    for j in range(len(cl)):
        if ups[j] + dns[j] == 0:
            continue
        mine = ups[j] if page_side > 0 else dns[j]
        side[j] = page_side if mine >= 5 else (1.0 if ups[j] >= dns[j] else -1.0)   # the sheet's layout decides; only a title with no line work on that side turns round
    # column band of every title: halfway to the nearest title of the same row on each side (never wider than one typical column pitch)
    pitch = []
    for j in range(len(cl)):
        row = [k for k in range(len(cl)) if k != j and abs(tw[k] - tw[j]) <= 60]
        if row:
            pitch.append(min(abs(ts[k] - ts[j]) for k in row))
    bmax = float(np.median(pitch)) if pitch else 0.12 * max(W, H)
    lo, hi = np.zeros(len(cl)), np.zeros(len(cl))
    for j in range(len(cl)):
        row = [k for k in range(len(cl)) if k != j and abs(tw[k] - tw[j]) <= 60]
        left = [ts[k] for k in row if ts[k] < ts[j]]
        right = [ts[k] for k in row if ts[k] > ts[j]]
        lo[j] = max((ts[j] + max(left)) / 2, ts[j] - bmax) if left else ts[j] - bmax
        hi[j] = min((ts[j] + min(right)) / 2, ts[j] + bmax) if right else ts[j] + bmax
    best = np.full(len(cx), np.inf)
    own = np.full(len(cx), -1)
    for j in range(len(cl)):
        if side[j] == 0:
            continue
        dw = side[j] * (wc - tw[j])
        ok = (dw >= -15) & (sc >= lo[j]) & (sc <= hi[j])
        c = np.where(ok, np.maximum(dw, 0), np.inf)
        better = c < best
        best[better] = c[better]
        own[better] = j
    valid = own >= 0
    res = [None] * n_t
    gap = np.ones((7, 7), np.uint8)                                    # cells closer than 3 cells (30 pt) belong together
    for j, g in enumerate(cl):
        m = valid & (own == j)
        if side[j] == 0 or m.sum() < 3:
            box = (None, None, None, None, 'no line work near the title')
        else:
            mask = np.zeros((gh, gw), np.uint8)
            mask[ys[m], xs[m]] = 255
            n_, lab_ = cv2.connectedComponents(cv2.dilate(mask, gap), connectivity=8)[:2]
            ids = lab_[ys[m], xs[m]]
            d2 = (cx[m] - P[j][0]) ** 2 + (cy[m] - P[j][1]) ** 2
            seed = ids[int(np.argmin(d2))]                               # the part of the strip that starts at the title (sheet-border ticks and strays are not part of it)
            keep = ids == seed
            box = (float(cx[m][keep].min() - CELL / 2), float(cy[m][keep].min() - CELL / 2), float(cx[m][keep].max() + CELL / 2), float(cy[m][keep].max() + CELL / 2),
                   'facing line work (%s of the title)' % ('beyond' if side[j] > 0 else 'before'))
        for i in g:
            res[i] = box
    return res


def build(folder, name):
    facts = os.path.join(folder, name + '_facts.csv')
    if not os.path.exists(facts):
        return []
    byp = {}
    for r in csv.DictReader(open(facts, encoding='utf-8')):
        if r['kind'] == 'title':
            byp.setdefault(int(r['page']), []).append(r)
    out = []
    for n, rows in sorted(byp.items()):
        segs = _segs(folder, name, n)
        tf = os.path.join(folder, '%s_p%d_text.csv' % (name, n))
        xs = [float(r['x1']) for s in [segs] for r in []]
        W = max([max(s[0], s[2]) for s in segs] + [float(r['x']) for r in rows]) + 20 if segs else 100
        H = max([max(s[1], s[3]) for s in segs] + [float(r['y']) for r in rows]) + 20 if segs else 100
        pts = [(float(r['x']), float(r['y'])) for r in rows]
        wins = windows(segs, pts, W, H, _text_axis(folder, name, n))
        with open(os.path.join(folder, '%s_p%d_windows.csv' % (name, n)), 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f)
            w.writerow(['title', 'x', 'y', 'x0', 'y0', 'x1', 'y1', 'method'])
            for r, b in zip(rows, wins):
                w.writerow([r['text'][:70], round(float(r['x'])), round(float(r['y'])), *(['' if v is None else round(v) for v in b[:4]]), b[4]])
                out.append((n, r['text'][:70], b))
    return out


def load(folder, name, page):
    fp = os.path.join(folder, '%s_p%d_windows.csv' % (name, page))
    out = {}
    if os.path.exists(fp):
        for r in csv.DictReader(open(fp, encoding='utf-8')):
            if r['x0'] != '':
                out[(r['title'], int(r['x']), int(r['y']))] = (float(r['x0']), float(r['y0']), float(r['x1']), float(r['y1']), r['method'])
    return out
