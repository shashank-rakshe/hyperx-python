"""Score rule output against the sample XML answer key (diagnostic only)."""
import math
from shapely.geometry import Polygon, Point, LineString
from shapely.ops import unary_union


def _poly(pts):
    p = Polygon(pts)
    return p if p.is_valid else p.buffer(0)


def score_plates(out, ref, step=100.0):
    ref_plates = [(_poly(p['poly']), p['t']) for p in ref['plates'] if len(p['poly']) >= 3]
    ref_holes = [_poly(h['poly']) if len(h['poly']) > 3 else None for h in ref['holes']]
    ref_holes = [h for h in ref_holes if h is not None and h.area > 0]
    R = unary_union([p for p, _ in ref_plates])
    for h in ref_holes:
        R = R.difference(h)
    O = unary_union([z['poly'] for z in out['zones']])
    inter = R.intersection(O).area
    iou = inter / R.union(O).area
    # thickness on a grid inside both
    x0, y0, x1, y1 = R.bounds
    n = agree = 0
    bad = {}
    y = y0 + step / 2
    zones = out['zones']
    while y < y1:
        x = x0 + step / 2
        while x < x1:
            pt = Point(x, y)
            rt = next((t for p, t in ref_plates if p.contains(pt)), None)
            if rt is not None and O.contains(pt):
                ot = next((z['t'] for z in zones if z['poly'].contains(pt)), None)
                n += 1
                if ot is not None and abs(ot - rt) < 0.05:
                    agree += 1
                else:
                    bad[(rt, ot)] = bad.get((rt, ot), 0) + 1
            x += step
        y += step
    return {'footprint_iou': round(iou, 4), 'ref_area_m2': round(R.area / 1e6, 2),
            'out_area_m2': round(O.area / 1e6, 2),
            'thickness_agreement': round(agree / n, 4) if n else None,
            'thickness_mismatch_cells': {f'ref {k[0]} / out {k[1]}': v * step * step / 1e6
                                         for k, v in sorted(bad.items(), key=lambda kv: -kv[1])}}


def score_openings(out, ref):
    refh = [_poly(h['poly']) for h in ref['holes'] if len(h['poly']) > 3]
    # circles stored as two arcs -> rebuild from box
    for h in ref['holes']:
        if len(h['poly']) <= 3 and h['box']:
            xs = [p[0] for p in h['poly']]
            ys = [p[1] for p in h['poly']]
            c = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)
            refh.append(Point(c).buffer(h['box'][0] / 2, 32))
    outh = [o['poly'] for o in out['openings']]
    matched = 0
    used = set()
    for r in refh:
        best = None
        for i, o in enumerate(outh):
            if i in used:
                continue
            iou = r.intersection(o).area / r.union(o).area
            if iou > 0.6 and (best is None or iou > best[0]):
                best = (iou, i)
        if best:
            used.add(best[1])
            matched += 1
    return {'ref_openings': len(refh), 'out_openings': len(outh), 'matched_iou_0.6': matched,
            'extra_out': len(outh) - len(used)}


def score_members(out, ref, offset_tol=60.0, sec_check=True):
    """Length-weighted coverage of reference stiffener traces by output members
    lying on the same line (perpendicular offset <= offset_tol mm)."""
    outm = [m for m in out['members']]
    tot = cov = cov_sec = 0.0
    per_sec = {}
    for s in ref['stiffeners']:
        a, b = s['a'], s['b']
        L = math.dist(a, b)
        if L < 50:
            continue
        rl = LineString([a, b])
        best = 0.0
        best_sec = 0.0
        for m in outm:
            ml = LineString([m['a'], m['b']])
            # parallel and close
            ang = abs(math.atan2(b[1] - a[1], b[0] - a[0]) - math.atan2(m['b'][1] - m['a'][1], m['b'][0] - m['a'][0])) % math.pi
            if min(ang, math.pi - ang) > 0.05:
                continue
            if ml.distance(rl) > offset_tol:
                continue
            # overlap length along reference
            d1 = rl.project(Point(m['a']))
            d2 = rl.project(Point(m['b']))
            if Point(m['a']).distance(rl) > offset_tol * 1.5 and Point(m['b']).distance(rl) > offset_tol * 1.5:
                # crosses only near endpoints; use projection anyway
                pass
            ov = max(0.0, min(max(d1, d2), L) - max(min(d1, d2), 0))
            best = max(best, ov)
            if m.get('section_key') == s.get('section_key'):
                best_sec = max(best_sec, ov)
        best = min(best, L)
        tot += L
        cov += best
        cov_sec += min(best_sec, L)
        k = s['section']
        d = per_sec.setdefault(k, [0.0, 0.0, 0.0])
        d[0] += L
        d[1] += best
        d[2] += min(best_sec, L)
    return {'ref_length_m': round(tot / 1000, 1),
            'position_coverage': round(cov / tot, 4) if tot else None,
            'position_and_section_coverage': round(cov_sec / tot, 4) if tot else None,
            'by_section': {k: {'ref_m': round(v[0] / 1000, 1), 'pos': round(v[1] / v[0], 3),
                               'pos+sec': round(v[2] / v[0], 3)} for k, v in sorted(per_sec.items(), key=lambda kv: -kv[1][0])}}


def member_position_error(out, ref, offset_tol=120.0):
    """for each output member matched to a parallel reference trace: perpendicular
    offset and end-point error along the trace (mm)."""
    perp, ends = [], []
    rl = [(LineString([s['a'], s['b']]), s) for s in ref['stiffeners']]
    for m in out['members']:
        ml = LineString([m['a'], m['b']])
        if ml.length < 100:
            continue
        best = None
        for l, s in rl:
            ang = abs(math.atan2(s['b'][1] - s['a'][1], s['b'][0] - s['a'][0]) - math.atan2(m['b'][1] - m['a'][1], m['b'][0] - m['a'][0])) % math.pi
            if min(ang, math.pi - ang) > 0.03:
                continue
            d = l.distance(Point(ml.interpolate(0.5, normalized=True)))
            if d < offset_tol and abs(l.length - ml.length) < 0.25 * l.length and (best is None or d < best[0]):
                best = (d, l, s)
        if best:
            d, l, s = best
            perp.append(d)
            e = min(math.dist(m['a'], s['a']) + math.dist(m['b'], s['b']), math.dist(m['a'], s['b']) + math.dist(m['b'], s['a'])) / 2
            ends.append(e)
    def st(x):
        x = sorted(x)
        if not x:
            return None
        return {'n': len(x), 'median': round(x[len(x) // 2], 1), 'p90': round(x[int(len(x) * .9)], 1),
                'exact_le_2mm': round(sum(1 for v in x if v <= 2) / len(x), 3)}
    return {'perpendicular_offset_mm': st(perp), 'end_error_mm': st(ends)}


# P3 (review 2026-10-26): the old score_members took the single best output piece per reference member and never looked at
# output that is NOT in the reference. Benchmark scoring now uses the union of all output pieces and measures both directions.
NOT_DRAWN_IN_PLAN = ('FlatBar75*6', 'FlatBar75*7', 'SquareBar22', 'RoundBar16')   # benchmark list: members the 1005 plans do not draw


def _ang(a, b):
    return math.atan2(b[1] - a[1], b[0] - a[0]) % math.pi


def _parallel(t1, t2, tol=0.05):
    d = abs(t1 - t2) % math.pi
    return min(d, math.pi - d) <= tol


def score_members_union(out, ref, band=60.0, not_drawn=NOT_DRAWN_IN_PLAN):
    """found = share of drawn reference length lying inside the 60 mm band of the union of parallel output pieces;
    found_size = same, output pieces of the same section only; real = share of output length inside the band of any (parallel)
    reference member (all reference members, drawn or not)."""
    refs = [(s, LineString([s['a'], s['b']]), _ang(s['a'], s['b'])) for s in ref['stiffeners'] if math.dist(s['a'], s['b']) >= 50]
    outs = [(m, LineString([m['a'], m['b']]), _ang(m['a'], m['b'])) for m in out['members'] if math.dist(m['a'], m['b']) >= 1]
    tot = fnd = fsz = 0.0
    excl = 0.0
    for s, rl, ra in refs:
        if s.get('section') in not_drawn:
            excl += rl.length
            continue
        near = [(m, ol) for m, ol, oa in outs if _parallel(ra, oa) and ol.distance(rl) <= band]
        tot += rl.length
        if near:
            U = unary_union([ol.buffer(band, cap_style=2) for _, ol in near])
            fnd += rl.intersection(U).length
            same = [ol for m, ol in near if m.get('section_key') == s.get('section_key')]
            if same:
                fsz += rl.intersection(unary_union([ol.buffer(band, cap_style=2) for ol in same])).length
    olen = real = 0.0
    for m, ol, oa in outs:
        olen += ol.length
        near = [rl for s, rl, ra in refs if _parallel(ra, oa) and rl.distance(ol) <= band]
        if near:
            real += ol.intersection(unary_union([rl.buffer(band, cap_style=2) for rl in near])).length
    return {'found': round(fnd / tot, 3) if tot else None, 'found_size': round(fsz / tot, 3) if tot else None,
            'real': round(real / olen, 3) if olen else None, 'out_m': round(olen / 1000), 'ref_m': round(tot / 1000),
            'ref_not_drawn_m': round(excl / 1000)}
