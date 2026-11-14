"""Written-label geometry shared by Step 2 (scale) and Step 3 (placement).  Universal, offline, text only.

 offcl_axis  : the OFF C.L label row of a plan  -> written scale k (mm/pt), centre line position, largest written value
 frame_axis  : a row of consecutive frame numbers -> pt per frame, frame 0 position
 FRAMESP_RX  : "FRAME SPACE : 1600"
"""
import re, statistics, collections

BARE_NUM = re.compile(r'^\s*(?:FR\.?\s*)?(\d{1,3})\s*$')      # frame label: '79' or 'FR.79' (no offset such as FR.83+60)


def _fn(t):
    return int(BARE_NUM.match(t).group(1))
NUM_RX = re.compile(r'^\s*(\d{3,6})\s*$')
FRAMESP_RX = re.compile(r'FRAME\s*SPACE\s*:?\s*(\d{1,2},\d{3}|\d{3,5})', re.I)
OFFCL_WORD = re.compile(r'\s*(\d{3,6})?\s*[*"\']?\s*OFF\s*C\.?\s*L\.?["\']?\s*', re.I)


OFFW = r'[*"\']?\s*OFF[\s.]*C(?:[./]|\s)*L\.?["\']?'      # OFF C.L  OFF.C.L  OFF CL  OFFCL  OFF C/L  * OFF C.L
OFF_ONLY = re.compile(r'\s*' + OFFW + r'\s*', re.I)
OFF_NUM = re.compile(r'\s*(\d{3,6})\s*' + OFFW + r'\s*', re.I)


def _pairs(inb):
    """(value, x, y) for every OFF C.L label: number inside the same text, or a number beside the words (<40 pt)."""
    pairs = []
    for o in inb:
        m = OFF_NUM.fullmatch(o['t'])
        if m:
            pairs.append((int(m.group(1)), o['x'], o['y']))
        elif OFF_ONLY.fullmatch(o['t']):
            c = [n for n in inb if NUM_RX.match(n['t']) and abs(n['x'] - o['x']) < 40 and abs(n['y'] - o['y']) < 40]
            if c:
                n = min(c, key=lambda n: (n['x'] - o['x']) ** 2 + (n['y'] - o['y']) ** 2)
                pairs.append((int(n['t']), o['x'], o['y']))
    return pairs


def _rows(pairs, near, min_n):
    """labels of one plan lie on one line: group by the other coordinate, take the row nearest the plan title (more labels win ties)."""
    best = None
    for ax_ in ('x', 'y'):
        rows = collections.defaultdict(list)
        for v, x, y in pairs:
            rows[round((y if ax_ == 'x' else x) / 12)].append((v, x, y))
        for g in rows.values():
            if len(g) < min_n:
                continue
            oc = statistics.mean([(q[2] if ax_ == 'x' else q[1]) for q in g])
            d = abs(oc - (near[1] if ax_ == 'x' else near[0])) if near else 0
            key = (d, -len(g))
            if best is None or key < best[0]:
                best = (key, ax_, g)
    return best


def offcl_axis(items, box, near=None, sheet_k=None):
    """OFF C.L labels of a plan (any written form, see OFFW).
    mode 'both sides': the same value written on both sides of the centre line -> centre = midpoint, k = (v2-v1)/(p2-p1) on the same side.
    mode 'one side'  : >=3 distinct values on one line that fit v = k*(p-c) (max error <= 3 % of the largest value), or 2 values whose k agrees with the
                       Step-2 sheet scale within 5 %  -> the written text decides the scale (Rule 2 d); the sheet scale only confirms.
    -> dict(axis 'x'|'y', c, k, n, vmax, mode) or None"""
    inb = [i for i in items if box[0] - 20 <= i['x'] <= box[2] + 20 and box[1] - 20 <= i['y'] <= box[3] + 20]
    pairs = _pairs(inb)
    r = _rows(pairs, near, 4)
    if r:
        _, ax, g = r
        pos = sorted({(v, round(x if ax == 'x' else y, 1)) for v, x, y in g})
        by = collections.defaultdict(list)
        for v, q in pos:
            by[v].append(q)
        mids = [(min(q) + max(q)) / 2 for q in by.values() if len(q) >= 2 and max(q) - min(q) > 20]
        if mids:
            c0 = statistics.median(mids)
            ks = []
            for side in (-1, 1):
                sp = sorted((v, q) for v, q in pos if (q - c0) * side > 0)
                for (v1, q1), (v2, q2) in zip(sp, sp[1:]):
                    if v2 != v1 and 8 < abs(q2 - q1) < 300:
                        k = abs((v2 - v1) / (q2 - q1))
                        if 5 < k < 120:
                            ks.append(k)
            if len(ks) >= 2:
                k = statistics.median(ks)
                ests = [q + (v / k if q < c0 else -v / k) for v, q in pos]
                return dict(axis=ax, c=statistics.median(ests), k=k, n=len(ks), vmax=max(v for v, q in pos), mode='both sides',
                            oc=statistics.mean([(y if ax == 'x' else x) for v, x, y in g]))
    r = _rows(pairs, near, 2)
    if r:
        _, ax, g = r
        pts = sorted({(round(x if ax == 'x' else y, 1), v) for v, x, y in g})
        vals = {v for q, v in pts}
        if len(vals) >= 2:
            n = len(pts)
            xs = [q for q, v in pts]
            ys = [v for q, v in pts]
            mx, my = sum(xs) / n, sum(ys) / n
            sxx = sum((x - mx) ** 2 for x in xs)
            if sxx > 0:
                k = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx          # signed slope: v = k (p - c)
                c = mx - my / k if k else None
                err = max(abs(y - k * (x - c)) for x, y in zip(xs, ys)) if c is not None else 1e9
                ok = c is not None and 5 < abs(k) < 120 and err <= 0.03 * max(ys)
                if ok and (len(vals) >= 3 or (sheet_k and abs(abs(k) / sheet_k - 1) <= 0.05)):
                    return dict(axis=ax, c=c, k=abs(k), n=len(vals), vmax=max(ys), mode='one side',
                                oc=statistics.mean([(y if ax == 'x' else x) for v, x, y in g]))
    return None


def frame_axis(items, box, other_axis, near=None, radius=900.0):
    """a row of >=4 bare integers that are CONSECUTIVE (n, n+1, ...) with equal spacing along one axis = frame numbers.
    Only rows within `radius` of the plan title (`near`) count."""
    inb = [i for i in items if box[0] - 20 <= i['x'] <= box[2] + 20 and box[1] - 20 <= i['y'] <= box[3] + 20 and BARE_NUM.match(i['t'])
           and (near is None or (i['x'] - near[0]) ** 2 + (i['y'] - near[1]) ** 2 < radius ** 2)]
    best = None
    for ax in ('x', 'y'):
        if ax == other_axis:
            continue
        rows = collections.defaultdict(list)
        for i in inb:
            rows[round(i['y' if ax == 'x' else 'x'] / 6)].append(i)
        for r in rows.values():
            pts = sorted({(_fn(i['t']), round(i[ax], 1)) for i in r})
            run_ = [pts[0]]
            for q in pts[1:]:
                if q[0] == run_[-1][0] + 1:
                    run_.append(q)
                else:
                    if len(run_) >= 4 and (best is None or len(run_) > best['n']):
                        best = _fit_frames(run_, ax)
                    run_ = [q]
            if len(run_) >= 4 and (best is None or len(run_) > best['n']):
                best = _fit_frames(run_, ax)
    if best is None:                        # frame labels that skip numbers (21, 23, 26, 29, 31 ...): a straight line of value vs position
        for sr in sparse_frame_rows(inb, 4):
            if sr['axis'] != other_axis and (best is None or sr['n'] > best['n']):
                best = dict(axis=sr['axis'], pt_per_frame=sr['pt_per_frame'], f0=sr['f0'], n=sr['n'], first=sr['first'], last=sr['last'])
    return best


def _fit_frames(run_, ax):
    sp = [(b[1] - a[1]) for a, b in zip(run_, run_[1:])]
    m = statistics.median(sp)
    if abs(m) < 8:
        return None
    f0 = statistics.median([q[1] - m * q[0] for q in run_])
    return dict(axis=ax, pt_per_frame=m, f0=f0, n=len(run_), first=run_[0][0], last=run_[-1][0])




def _cluster(vals, tol=20.0):
    """indices of consecutive groups of a sorted list whose gaps are <= tol (labels of one row may be staggered by a few points)"""
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    groups, cur = [], [order[0]] if order else []
    for a, b in zip(order, order[1:]):
        if vals[b] - vals[a] <= tol:
            cur.append(b)
        else:
            groups.append(cur)
            cur = [b]
    if cur:
        groups.append(cur)
    return groups


def _fit_group(g, ax, sheet_k):
    pos = sorted({(v, round(x if ax == 'x' else y, 1)) for v, x, y in g})
    by = collections.defaultdict(list)
    for v, q in pos:
        by[v].append(q)
    oc = statistics.mean([(y if ax == 'x' else x) for v, x, y in g])
    mids = [(min(q) + max(q)) / 2 for q in by.values() if len(q) >= 2 and max(q) - min(q) > 20]
    if mids and len(g) >= 4:
        c0 = statistics.median(mids)
        ks = []
        for side in (-1, 1):
            sp = sorted((v, q) for v, q in pos if (q - c0) * side > 0)
            for (v1, q1), (v2, q2) in zip(sp, sp[1:]):
                if v2 != v1 and 8 < abs(q2 - q1) < 300:
                    k = abs((v2 - v1) / (q2 - q1))
                    if 5 < k < 120:
                        ks.append(k)
        if len(ks) >= 2:
            k = statistics.median(ks)
            ests = [q + (v / k if q < c0 else -v / k) for v, q in pos]
            return dict(axis=ax, c=statistics.median(ests), k=k, n=len(ks), vmax=max(v for v, q in pos), mode='both sides', oc=oc,
                        lo=min(q for v, q in pos), hi=max(q for v, q in pos), vals=sorted({v for v, q in pos}))
    pts = sorted({(round(x if ax == 'x' else y, 1), v) for v, x, y in g})
    vals = {v for q, v in pts}
    if len(vals) >= 2:
        n = len(pts)
        xs = [q for q, v in pts]
        ys = [v for q, v in pts]
        mx, my = sum(xs) / n, sum(ys) / n
        sxx = sum((x - mx) ** 2 for x in xs)
        if sxx > 0:
            k = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
            c = mx - my / k if k else None
            err = max(abs(y - k * (x - c)) for x, y in zip(xs, ys)) if c is not None else 1e9
            if c is not None and 5 < abs(k) < 120 and err <= 0.03 * max(ys) and (len(vals) >= 3 or (sheet_k and abs(abs(k) / sheet_k - 1) <= 0.05)):
                return dict(axis=ax, c=c, k=abs(k), n=len(vals), vmax=max(ys), mode='one side', oc=oc, lo=min(xs), hi=max(xs), vals=sorted(vals))
    return None


def offcl_rows(items, sheet_k=None):
    """EVERY OFF C.L label row on the page (no title needed): labels sharing a line (other coordinate within 20 pt) -> fitted axis."""
    pairs = _pairs(items)
    out = []
    for ax in ('x', 'y'):
        other = [(y if ax == 'x' else x) for v, x, y in pairs]
        for grp in _cluster(other, 20.0):
            g0 = [pairs[i] for i in grp]
            for g in _split_plans(g0, ax):
                if len(g) >= 2:
                    a = _fit_group(g, ax, sheet_k)
                    if a:
                        out.append(a)
    return out


def _split_plans(g, ax):
    """R-OF1: two plans side by side on one sheet row share the other coordinate, so their OFF C.L labels fall into ONE cluster (centre between the
    plans, scale wrong). Split the cluster where the gap between neighbouring label positions is more than 5x the usual gap and both parts keep >= 3 labels."""
    pos = sorted({round(x if ax == 'x' else y, 1) for v, x, y in g})
    if len(pos) < 6:
        return [g]
    gaps = [b - a for a, b in zip(pos, pos[1:])]
    med = statistics.median(gaps)
    cut = max(range(len(gaps)), key=lambda i: gaps[i])
    if gaps[cut] <= max(5 * med, 150) or cut + 1 < 3 or len(pos) - cut - 1 < 3:
        return [g]
    mid = (pos[cut] + pos[cut + 1]) / 2
    left = [p for p in g if (p[1] if ax == 'x' else p[2]) < mid]
    right = [p for p in g if (p[1] if ax == 'x' else p[2]) >= mid]
    return _split_plans(left, ax) + _split_plans(right, ax)


def frame_rows(items):
    """EVERY row of >=4 consecutive integers with equal spacing (frame numbers) on the page."""
    nums = [i for i in items if BARE_NUM.match(i['t'])]
    out = []
    for ax in ('x', 'y'):
        other = [i['y' if ax == 'x' else 'x'] for i in nums]
        if not other:
            continue
        for grp in _cluster(other, 12.0):
            r = [nums[i] for i in grp]
            pts = sorted({(_fn(i['t']), round(i[ax], 1)) for i in r})
            run_ = [pts[0]]
            for q in pts[1:] + [None]:
                if q is not None and q[0] == run_[-1][0] + 1:
                    run_.append(q)
                    continue
                if len(run_) >= 4:
                    fa = _fit_frames(run_, ax)
                    if fa:
                        fa['oc'] = statistics.mean([i['y' if ax == 'x' else 'x'] for i in r])
                        fa['lo'] = min(a[1] for a in run_)
                        fa['hi'] = max(a[1] for a in run_)
                        out.append(fa)
                run_ = [q] if q is not None else []
    return out


def sparse_frame_rows(items, min_n=3):
    """Frame labels that are NOT consecutive integers (21, 23, 26, 29, 31 ...): a column/row of bare integers whose position is a straight line of the value.
    >= min_n labels on the line, distinct values, 8 < |pt per frame| < 300. Returns dicts like frame_rows (+ sparse=True); frame at p = (p - f0) / pt_per_frame."""
    nums = [i for i in items if BARE_NUM.match(i['t'])]
    out = []
    for ax in ('x', 'y'):
        oth = 'y' if ax == 'x' else 'x'
        if not nums:
            continue
        for grp in _cluster([i[oth] for i in nums], 12.0):
            r = [nums[i] for i in grp]
            pts = sorted({(_fn(i['t']), round(i[ax], 1)) for i in r})
            best = None
            for a in range(len(pts)):
                for b in range(a + 1, len(pts)):
                    dv = pts[b][0] - pts[a][0]
                    if dv == 0:
                        continue
                    ppf = (pts[b][1] - pts[a][1]) / dv
                    if not (8 < abs(ppf) < 300):
                        continue
                    f0 = pts[a][1] - ppf * pts[a][0]
                    inl = [q for q in pts if abs(q[1] - (f0 + ppf * q[0])) <= 0.2 * abs(ppf) + 1]
                    if len({q[0] for q in inl}) >= min_n and (best is None or len(inl) > len(best[0])):
                        best = (inl, ppf)
            if best:
                inl, ppf = best
                f0 = statistics.median([q[1] - ppf * q[0] for q in inl])
                out.append(dict(axis=ax, pt_per_frame=ppf, f0=f0, n=len(inl), first=min(q[0] for q in inl), last=max(q[0] for q in inl),
                                oc=statistics.mean([i[oth] for i in r]), lo=min(q[1] for q in inl), hi=max(q[1] for q in inl), sparse=True))
    return out


BOXED_FR = re.compile(r'^\W*FR\.?\s*(-?\d{1,3})(?:\s*\+\s*(\d+)\s*/\s*(\d+)|\s*\+\s*(\d*\.\d+))?\s*$', re.I)


def boxed_frame_rows(items, min_n=3):
    """R-OF3: the boxed 'FR.n' labels printed at the edge of a plan ('FR.19+1/2  FR.21  FR.22+1/2  FR.24'; a fraction = part of the gap spacing) form a frame row of
    their own although they are not consecutive integers: >= 3 distinct frames on one line; slope and origin are medians (labels are staggered by a few pt
    when boxes collide), so the row gives the plan's frame RANGE and pt/frame, not an exact position (Rule 3 calibrates the exact one)."""
    lab = []
    for i in items:
        m = BOXED_FR.match(i['t'])
        if not m:
            continue
        v = int(m.group(1)) + (int(m.group(2)) / int(m.group(3)) if m.group(2) else (float(m.group(4)) if m.group(4) else 0.0))
        lab.append((v, i['x'], i['y']))
    out = []
    for ax in ('x', 'y'):
        oth = 'y' if ax == 'x' else 'x'
        if not lab:
            continue
        for grp in _cluster([(q[2] if oth == 'y' else q[1]) for q in lab], 12.0):
            r_all = sorted([lab[k] for k in grp], key=lambda q: q[1] if ax == 'x' else q[2])
            pos_ = [q[1] if ax == 'x' else q[2] for q in r_all]
            gaps_ = [b - a for a, b in zip(pos_, pos_[1:])]
            medg = statistics.median(gaps_) if gaps_ else 0
            chunks, cur = [], [r_all[0]]
            for q, g_ in zip(r_all[1:], gaps_):          # several plans stacked in one label column: a gap > 4x the usual one starts the next plan's row
                if g_ > max(150, 4 * medg):
                    chunks.append(cur)
                    cur = []
                cur.append(q)
            chunks.append(cur)
            for r in chunks:
                row = _boxed_fit(r, ax, min_n)
                if row:
                    out.append(row)
    return out


def _boxed_fit(r, ax, min_n):
    if True:
        if True:
            pts = sorted({(v, round(x if ax == 'x' else y, 1)) for v, x, y in r})
            if len({p[0] for p in pts}) < min_n:
                return None
            sl = [(b[1] - a[1]) / (b[0] - a[0]) for a in pts for b in pts if b[0] > a[0]]
            m_ = statistics.median(sl)
            if abs(m_) < 8:
                return None
            f0 = statistics.median([p - m_ * v for v, p in pts])
            if max(abs(p - (f0 + m_ * v)) for v, p in pts) > 25:
                return None
            return dict(axis=ax, pt_per_frame=m_, f0=f0, n=len(pts), first=min(p[0] for p in pts), last=max(p[0] for p in pts),
                        oc=statistics.mean([(y if ax == 'x' else x) for v, x, y in r]), lo=min(p[1] for p in pts), hi=max(p[1] for p in pts), boxed=True)


def all_frame_rows(items, has_frame_space=False):
    """consecutive rows + sparse rows (not duplicating a consecutive row); sparse needs >= 4 labels, or 3 when a FRAME SPACE is written to check the scale."""
    rows = list(frame_rows(items))
    for sr in sparse_frame_rows(items, 3 if has_frame_space else 4):
        if not any(r['axis'] == sr['axis'] and abs(r['oc'] - sr['oc']) < 15 and abs(r['pt_per_frame'] - sr['pt_per_frame']) < 0.5 for r in rows):
            rows.append(sr)
    for br in boxed_frame_rows(items):             # R-OF3
        if not any(r['axis'] == br['axis'] and abs(r['oc'] - br['oc']) < 40 and abs(r['lo'] - br['lo']) < 40 and abs(r['hi'] - br['hi']) < 40 and abs(r['pt_per_frame'] - br['pt_per_frame']) < 0.2 * abs(br['pt_per_frame']) for r in rows):
            rows.append(br)
    return rows
