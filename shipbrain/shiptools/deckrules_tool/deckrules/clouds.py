"""R-RV1 (universal): revision clouds are found from the GEOMETRY of the line work, not from how the CAD system wrote them (arcs, short chords, one path
or thousands of one-segment paths all look the same once the strokes are joined end to end).

A revision cloud = a chain of strokes joined end to end (degree <= 2) whose outline is a row of smooth bulges (small turning angles) separated by sharp
inward cusps (turning the OTHER way), >= 6 cusps, bigger than 40 pt.  A circle has no cusps, a zig-zag / hatch has no smooth bulges, text and break marks are small.
"""
import math
import numpy as np


def find_clouds(segs, max_chord=14.0, min_cusps=6, min_extent=40.0):
    """segs: objects with .a .b .length .kind.  Returns [(bbox, set(index of segs))]."""
    from scipy.spatial import cKDTree
    idx = [i for i, s in enumerate(segs) if getattr(s, 'kind', 'l') == 'l' and 0.2 < s.length <= max_chord]
    if len(idx) < 30:
        return []
    pts = np.array([p for i in idx for p in (segs[i].a, segs[i].b)], float)
    tree = cKDTree(pts)
    par = list(range(len(pts)))

    def find(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x
    for i, j in tree.query_pairs(0.7):
        par[find(i)] = find(j)
    vid = [find(k) for k in range(len(pts))]
    adj = {}
    for n, i in enumerate(idx):
        a, b = vid[2 * n], vid[2 * n + 1]
        if a == b:
            continue
        adj.setdefault(a, []).append((b, i))
        adj.setdefault(b, []).append((a, i))
    P = {}
    for k in range(len(pts)):
        P.setdefault(vid[k], pts[k])
    seen = set()
    out = []
    for start in adj:
        if start in seen:
            continue
        comp, stack = [], [start]
        seen.add(start)
        while stack:
            u = stack.pop()
            comp.append(u)
            for w, _ in adj[u]:
                if w not in seen:
                    seen.add(w)
                    stack.append(w)
        if len(comp) < 30:
            continue
        deg = [len(adj[u]) for u in comp]
        if sum(1 for d in deg if d > 2) > 0.1 * len(comp):
            continue
        xs = [P[u][0] for u in comp]
        ys = [P[u][1] for u in comp]
        if max(max(xs) - min(xs), max(ys) - min(ys)) < min_extent:
            continue
        # order the chain: from an end (degree 1) or any vertex of a loop
        ends = [u for u in comp if len(adj[u]) == 1]
        cur = ends[0] if ends else comp[0]
        order, prev, used = [cur], None, set()
        while True:
            nxt = None
            for w, si in adj[cur]:
                if si not in used:
                    nxt = (w, si)
                    break
            if nxt is None:
                break
            used.add(nxt[1])
            prev, cur = cur, nxt[0]
            order.append(cur)
            if cur == order[0] or len(order) > len(comp) + 2:
                break
        if len(order) < 30:
            continue
        pp = np.array([P[u] for u in order])
        turns = []
        for k in range(1, len(pp) - 1):
            a = pp[k] - pp[k - 1]
            b = pp[k + 1] - pp[k]
            if np.hypot(*a) < 1e-6 or np.hypot(*b) < 1e-6:
                continue
            turns.append(math.degrees(math.atan2(a[0] * b[1] - a[1] * b[0], a[0] * b[0] + a[1] * b[1])))
        if len(turns) < 30:
            continue
        t = np.array(turns)
        smooth = np.abs(t) < 35
        if smooth.mean() < 0.55:
            continue
        sgn = np.sign(np.median(t[smooth])) or 1.0
        cusps = int(np.sum((np.abs(t) > 55) & (np.sign(t) == -sgn)))
        if cusps >= min_cusps:
            members = {si for u in comp for _, si in adj[u]}
            out.append(((min(xs), min(ys), max(xs), max(ys)), members))
    return out
