"""Compare a produced moulded XML with a reference ship XML (any naming), plane by plane (benchmark scoring only).
Planes: decks (normal Z), frames (normal X), longitudinal walls (normal Y). For every reference plane: plate area overlap,
stiffener 'found' (reference length within a 60 mm band of parallel output stiffeners of the same plane) and 'real' (output length
on reference stiffeners). python tools/compare_ref.py OUT.xml REF.xml [--json out.json]"""
import sys, math, json, argparse, collections
from lxml import etree
from shapely.geometry import Polygon, LineString
from shapely.ops import unary_union


def _v(e):
    return [float(e.get('X')), float(e.get('Y')), float(e.get('Z'))]


def _cont(c):
    s = c.find('StartPoint2d')
    return [(float(s.get('U')), float(s.get('V')))] + [(float(n.get('U')), float(n.get('V'))) for n in c.iter('Node2d')]


def load(path):
    """-> list of planes {axis, val, plates:[poly2d], stiff:[(a2d,b2d,section)]} in the plane's own world 2D coordinates"""
    root = etree.parse(path).getroot()
    secs = {b.get('BarSectionId'): b for b in root.iter('BarSection')}
    planes = collections.defaultdict(lambda: {'plates': [], 'stiff': []})
    for pp in root.iter('PlanePanel'):
        cs = pp.find('CoordSys')
        if cs is None:
            continue
        O, W, U = _v(cs.find('Origin')), _v(cs.find('Waxis')), _v(cs.find('Uaxis'))
        ax = max(range(3), key=lambda i: abs(W[i]))
        if abs(W[ax]) < 0.97:
            continue                                     # strongly tilted panels are skipped
        V = [W[1] * U[2] - W[2] * U[1], W[2] * U[0] - W[0] * U[2], W[0] * U[1] - W[1] * U[0]]
        o2 = [i for i in range(3) if i != ax]
        to = lambda u, v: tuple(O[i] + u * U[i] + v * V[i] for i in o2)
        val = O[ax]
        key = (('Z', 'X', 'Y')[[2, 0, 1].index(ax)] if ax in (0, 1, 2) else '?', round(val / 20.0) * 20)
        key = ({0: 'X', 1: 'Y', 2: 'Z'}[ax], round(val / 20.0) * 20)
        P = planes[key]
        for pl in pp.iter('Plate'):
            c = pl.find('SimpleContour')
            if c is None:
                continue
            try:
                g = Polygon([to(*q) for q in _cont(c)])
                if not g.is_valid:
                    g = g.buffer(0)
                if g.area > 1:
                    P['plates'].append(g)
            except Exception:
                pass
        for st in pp.iter('Stiffener'):
            tr = st.find('Trace')
            if tr is None:
                continue
            q = _cont(tr)
            bs = st.getparent().find('.//BarShape')
            for a, b in zip(q, q[1:]):
                A, B = to(*a), to(*b)
                if math.dist(A, B) > 20:
                    P['stiff'].append((A, B, bs.get('BarSectionId') if bs is not None else ''))
    return planes


def _ang(a, b):
    return math.atan2(b[1] - a[1], b[0] - a[0]) % math.pi


def _par(t1, t2):
    d = abs(t1 - t2) % math.pi
    return min(d, math.pi - d) < 0.05


def score(out, ref, band=60.0, ztol=80.0):
    rows = []
    for (ax, val), R in sorted(ref.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        cand = [P for (a2, v2), P in out.items() if a2 == ax and abs(v2 - val) <= ztol]
        oplates = [g for P in cand for g in P['plates']]
        ost = [s for P in cand for s in P['stiff']]
        rlen = sum(math.dist(a, b) for a, b, _ in R['stiff'])
        RP = unary_union(R['plates']) if R['plates'] else None
        OP = unary_union(oplates) if oplates else None
        area = (RP.intersection(OP).area / RP.area) if (RP is not None and OP is not None and RP.area) else 0.0
        found = fsz = 0.0
        for a, b, sec in R['stiff']:
            rl = LineString([a, b]); ra = _ang(a, b)
            near = [(ol, s) for (oa, ob, s) in ost for ol in [LineString([oa, ob])] if _par(ra, _ang(oa, ob)) and ol.distance(rl) <= band]
            if near:
                found += rl.intersection(unary_union([ol.buffer(band, cap_style=2) for ol, _ in near])).length
                same = [ol for ol, s in near if s == sec]
                if same:
                    fsz += rl.intersection(unary_union([ol.buffer(band, cap_style=2) for ol in same])).length
        olen = sum(math.dist(a, b) for a, b, _ in ost)
        real = 0.0
        for oa, ob, s in ost:
            ol = LineString([oa, ob]); oa_ = _ang(oa, ob)
            near = [LineString([a, b]) for a, b, _ in R['stiff'] if _par(oa_, _ang(a, b)) and LineString([a, b]).distance(ol) <= band]
            if near:
                real += ol.intersection(unary_union([r.buffer(band, cap_style=2) for r in near])).length
        rows.append({'plane': f'{ax}={val:g}', 'ref_plate_m2': round(RP.area / 1e6, 1) if RP is not None else 0, 'plate_found': round(area, 3),
                     'ref_stiff_m': round(rlen / 1000, 1), 'out_stiff_m': round(olen / 1000, 1),
                     'found': round(found / rlen, 3) if rlen else None, 'found_size': round(fsz / rlen, 3) if rlen else None,
                     'real': round(real / olen, 3) if olen else None})
    return rows


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('out'); ap.add_argument('ref'); ap.add_argument('--json'); ap.add_argument('--min-ref-m', type=float, default=5.0)
    a = ap.parse_args()
    rows = [r for r in score(load(a.out), load(a.ref)) if r['ref_stiff_m'] >= a.min_ref_m or r['ref_plate_m2'] >= 5]
    tot = lambda k: sum(r[k] for r in rows)
    w = lambda k: sum((r[k] or 0) * r['ref_stiff_m'] for r in rows) / max(tot('ref_stiff_m'), 1e-9)
    print(f"{'plane':12s} {'ref m2':>7s} {'plate':>6s} {'ref m':>7s} {'out m':>7s} {'found':>6s} {'+size':>6s} {'real':>6s}")
    for r in rows:
        print(f"{r['plane']:12s} {r['ref_plate_m2']:7.1f} {r['plate_found']:6.2f} {r['ref_stiff_m']:7.1f} {r['out_stiff_m']:7.1f} {str(r['found']):>6s} {str(r['found_size']):>6s} {str(r['real']):>6s}")
    print(f"TOTAL ref stiff {tot('ref_stiff_m'):.0f} m, out {tot('out_stiff_m'):.0f} m, found (length-weighted) {w('found'):.3f}, found+size {w('found_size'):.3f}")
    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=1)
