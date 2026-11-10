"""No-gap rule (R-NG): every member end lies ON the moulded line of its support.

Supports of an under-deck member are: the deck edge, cut-out edges, other members
and the walls / bulkheads of the tier below (thick dashed lines on the plan).
The draughtsman stops stiffeners short of their support by the standard end
clearance (35 mm nominal, 25-40 mm tolerance); moulded-line mode has no
clearance, so a short end is extended along its own axis until it touches the
first support.  A larger gap is NEVER guessed: it is left as drawn and reported.
"""
import math
from shapely.geometry import LineString, Point
from shapely.ops import unary_union


def wall_lines(page, v, min_width=0.5, min_len_pt=2.0):
    """thick lines inside the view = walls / bulkheads that carry the members (ship mm):
    thick DASHED = wall of the tier below, thick SOLID straight = wall cut at this level."""
    k = v.k
    out = []
    for s in page.segs:
        if s.kind == 'l' and s.width >= min_width and s.length > min_len_pt and (s.dash or s.horizontal or s.vertical) and \
           all(v.region[0] < p[0] < v.region[2] and v.region[1] < p[1] < v.region[3] for p in (s.a, s.b)):
            out.append(LineString([((s.a[0] - v.x0) * k, (v.cl_y - s.a[1]) * k),
                                   ((s.b[0] - v.x0) * k, (v.cl_y - s.b[1]) * k)]))
    return out


def drawn_lines(page, v):
    """every straight drawn line inside the view, ship mm (for R-NG3 bridging)."""
    k = v.k
    out = []
    for s in page.segs:
        if s.kind == 'l' and s.length > 0.5 and \
           all(v.region[0] < p[0] < v.region[2] and v.region[1] < p[1] < v.region[3] for p in (s.a, s.b)):
            out.append(((s.a[0] - v.x0) * k, (v.cl_y - s.a[1]) * k, (s.b[0] - v.x0) * k, (v.cl_y - s.b[1]) * k))
    return out


def _end_mark(p, lines, r=250.0):
    """R-EC2 (owner 2026-10-25, note 4 'STIFFENER END CONNECTION': the arrow / triangle at a member end = the member is stopped and
    WELDED on the frame / OFF C.L line it points to, no gap): >= 2 short oblique lines (the triangle sides) within r of the end."""
    n = 0
    for x0, y0, x1, y1 in lines:
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        L = math.hypot(dx, dy)
        if 40 < L < 400 and dx > 0.2 * L and dy > 0.2 * L and min(math.dist(p, (x0, y0)), math.dist(p, (x1, y1))) < r:
            n += 1
    return n >= 2


def _bridged(p, d, lines, lat=40.0, cover=0.9):
    """R-NG3: is the stretch from p to p+d*(ux,uy)... drawn as a line collinear with the member?
    p: start, d: (ux, uy, length).  True when collinear drawn lines cover >= cover of the stretch."""
    ux, uy, L = d
    iv = []
    for x0, y0, x1, y1 in lines:
        # lateral offsets of both ends from the member axis
        l0 = abs((x0 - p[0]) * uy - (y0 - p[1]) * ux)
        l1 = abs((x1 - p[0]) * uy - (y1 - p[1]) * ux)
        if l0 > lat or l1 > lat:
            continue
        t0 = (x0 - p[0]) * ux + (y0 - p[1]) * uy
        t1 = (x1 - p[0]) * ux + (y1 - p[1]) * uy
        a, b = max(min(t0, t1), 0.0), min(max(t0, t1), L)
        if b > a:
            iv.append((a, b))
    iv.sort()
    cov, cur = 0.0, 0.0
    for a, b in iv:
        a = max(a, cur)
        if b > a:
            cov += b - a
            cur = b
    return cov >= cover * L


def close_gaps(deck, walls, max_gap=45.0, touch=1.0, probe=1600.0, drawn=None, max_bridge=260.0):
    """Extend short ends onto their support.  Returns a report dict.
    R-NG  gap <= max_gap (standard end clearance)               -> extend
    R-NG3 gap <= max_bridge and the gap is drawn as a collinear line -> extend"""
    mem = deck['members'] + deck.get('deep', [])
    bnd = unary_union([deck['footprint'].boundary] + [o['poly'].boundary for o in deck['openings']])      # a footprint may be several pieces (stringer)
    # R-EC3 (owner 2026-10-25: 'the small line denotes another member coming from the frame that stops on the deck member exactly'):
    # a short (< 400 mm) wall-weight stroke COLLINEAR with a member is that frame-member mark, not a support for the member itself
    walls = list(walls or [])
    short = [w for w in walls if w.length < 400]
    wall_u = unary_union([w for w in walls if w.length >= 400]) if walls else None
    lines = [LineString([m['a'], m['b']]) for m in mem]
    rep = {'ends': 0, 'touching': 0, 'closed': 0, 'closed_gap_mm': [], 'left_open': []}
    for i, m in enumerate(mem):
        L = math.dist(m['a'], m['b'])
        if L < 1:
            continue
        ux_, uy_ = (m['b'][0] - m['a'][0]) / L, (m['b'][1] - m['a'][1]) / L
        def _col(w):
            (x0, y0), (x1, y1) = w.coords[0], w.coords[-1]
            return all(abs((x - m['a'][0]) * uy_ - (y - m['a'][1]) * ux_) < 40 for x, y in ((x0, y0), (x1, y1)))
        sh = [w for w in short if not _col(w)]
        others = [bnd] + ([wall_u] if wall_u is not None and not wall_u.is_empty else []) + sh + [lines[j] for j in range(len(mem)) if j != i]
        sup = unary_union(others)
        for which, p, q in (('b', m['b'], m['a']), ('a', m['a'], m['b'])):
            rep['ends'] += 1
            P = Point(p)
            if sup.distance(P) <= touch:
                rep['touching'] += 1
                continue
            ux, uy = (p[0] - q[0]) / L, (p[1] - q[1]) / L
            ray = LineString([p, (p[0] + ux * probe, p[1] + uy * probe)])
            hit = ray.intersection(sup)
            if hit.is_empty:
                rep['left_open'].append({'member': [round(c) for c in m['a'] + m['b']], 'end': which, 'gap_mm': None,
                                         'issue': 'no support found along the member axis'})
                continue
            nearest = min(getattr(hit, 'geoms', [hit]), key=lambda g: P.distance(g))
            d = P.distance(nearest)
            bridged = d <= max_bridge and drawn and _bridged(p, (ux, uy, d), drawn)
            marked = d <= 600 and drawn and _end_mark(p, drawn)        # R-EC2 welded end mark -> ends ON the support
            if d <= max_gap or bridged or marked:
                # R-NG4 (2026-10-25): the end goes to the NEAREST point of the support. A collinear member hit along the axis is a line, and its
                # centroid put the end in the middle of it (EC weather shield NO.8L / NO.7L ran back over the '#' carlings to X 31600 / 31665).
                from shapely.ops import nearest_points as _np
                c = _np(nearest, P)[0] if nearest.geom_type != 'Point' else nearest
                m[which] = (c.x, c.y)
                lines[i] = LineString([m['a'], m['b']])
                m['evidence'].append(f"{('R-NG3' if bridged else 'R-EC2 end mark') if d > max_gap else 'R-NG'} end {which} extended {d:.0f} mm onto support moulded line"
                                     + (' (gap drawn as a continuing line)' if d > max_gap else ''))
                rep['closed'] += 1
                rep['closed_gap_mm'].append(round(d, 1))
            else:
                rep['left_open'].append({'member': [round(c) for c in m['a'] + m['b']], 'end': which,
                                         'gap_mm': round(d), 'issue': 'gap larger than end clearance: support not confirmed, left as drawn'})
    return rep


def used_walls(deck, walls, touch=1.0):
    """wall lines that carry at least one member end (exported as SupportLine so the XML is self-checking)."""
    out = []
    ends = [Point(p) for m in deck['members'] + deck.get('deep', []) for p in (m['a'], m['b'])]
    for w in walls:
        if any(w.distance(e) <= touch for e in ends):
            out.append(w)
    return out


def clip_to_footprint(deck, tol=1.5):
    """R-FC: a member cannot run past the deck edge; trim it onto the edge (the edge is its support)."""
    fp = deck['footprint'].buffer(tol)
    n = 0
    drop = []
    for m in deck['members']:
        l = LineString([m['a'], m['b']])
        if fp.contains(l):
            continue
        part = l.intersection(fp)
        if part.is_empty:
            drop.append(m)      # R-DM4: a member wholly outside the deck outline (section-detail box, wall strip) is not built
            continue
        piece = max(getattr(part, 'geoms', [part]), key=lambda g: g.length)
        if piece.length < 100:
            drop.append(m)
            continue
        a, b = piece.coords[0], piece.coords[-1]
        # keep the original direction
        if math.dist(a, m['a']) > math.dist(b, m['a']):
            a, b = b, a
        m['a'], m['b'] = tuple(a), tuple(b)
        m['evidence'].append('R-FC trimmed to the deck edge')
        n += 1
    for m in drop:
        deck['members'].remove(m)
    deck['dropped_outside'] = len(drop)
    return n


def split_at_crossings(deck, min_piece=60.0, penetrate=True):
    """R-G1b: a beam / carling that CROSSES a girder or deep web is cut at that web (it ends on the girder moulded line from each side) - a stiffener drawn
    through a girder would otherwise lie inside its web (EC NO.1-5 STR.: 110 overlapping pairs). Returns the number of cuts."""
    from shapely.geometry import LineString
    _nl = lambda m: bool(m.get('evidence')) and str(m['evidence'][0]).startswith('R-NL')
    girders = [(LineString([m['a'], m['b']]), m) for m in list(deck.get('members', [])) + list(deck.get('deep', [])) if m.get('kind') in ('girder', 'deep')]
    # R-NL2: the NO.nL beams are generated (no drawn line): wherever a DRAWN beam / carling crosses them, the generated beam ends on that member too
    drawn = [(LineString([m['a'], m['b']]), m) for m in deck.get('members', []) if m.get('kind') in ('beam', 'carling') and not _nl(m)]
    if not girders and not drawn:
        return 0
    cuts = 0
    out = []
    for m in deck.get('members', []):
        if m.get('kind') not in ('beam', 'carling'):
            out.append(m)
            continue
        pieces = [m]
        for gl, g in (girders + (drawn if _nl(m) else [])):
            nxt = []
            for p in pieces:
                pl = LineString([p['a'], p['b']])
                x = pl.intersection(gl)
                if x.geom_type != 'Point' or pl.length < 2 * min_piece:
                    nxt.append(p)
                    continue
                d0, d1 = math.dist(p['a'], (x.x, x.y)), math.dist(p['b'], (x.x, x.y))
                if d0 < min_piece or d1 < min_piece:
                    nxt.append(p)               # ends on / at the girder: a connection, not a crossing
                    continue
                pt = (x.x, x.y)
                if penetrate and not _nl(m):
                    # R-PN1 (online rule v2.3, owner 2026-11-04): members PENETRATE each other - a beam / carling is never cut by the girder it crosses;
                    # it stays one continuous member and passes through the web (cut-out). Only the generated NO.nL beams are still ended on a member.
                    p.setdefault('evidence', []).append('R-PN1: continuous through the girder / web crossing (not cut)')
                    nxt.append(p)
                    cuts += 1
                    continue
                p1 = dict(p, b=pt, bracket_b=False, bracket_size_b=None, bracket_unknown_b=False,
                          evidence=list(p['evidence']) + ['R-G1b: cut at the girder web crossing (ends on its moulded line)'])
                p2 = dict(p, a=pt, bracket_a=False, bracket_size_a=None, bracket_unknown_a=False,
                          evidence=list(p['evidence']) + ['R-G1b: cut at the girder web crossing (ends on its moulded line)'])
                nxt += [p1, p2]
                cuts += 1
            pieces = nxt
        out += pieces
    deck['members'] = out
    return cuts


def drop_generated_at_openings(deck, tol=5.0):
    """R-NL3 (owner 2026-10-25: 'longitudinal should stop on beam and that hole is inside the both side members'): a generated
    NO.nL piece (no drawn line) that ends on an opening edge is not built - the longitudinal stops on the beam / carling before the
    opening, the opening lies between the members on both sides. Returns the number of pieces dropped."""
    from shapely.geometry import Point
    ops = [o['poly'] if isinstance(o, dict) else o for o in deck.get('openings', [])]
    ops = [o for o in ops if hasattr(o, 'exterior')]
    if not ops:
        return 0
    _nl = lambda m: bool(m.get('evidence')) and str(m['evidence'][0]).startswith('R-NL')
    from shapely.geometry import LineString
    cross = [LineString([m['a'], m['b']]) for m in deck.get('members', []) + deck.get('deep', [])
             if not _nl(m) and m.get('kind') in ('beam', 'carling', 'girder', 'deep')]
    keep, n = [], 0
    for m in deck.get('members', []):
        if not _nl(m):
            keep.append(m)
            continue
        for e, o_ in (('a', 'b'), ('b', 'a')):
            if not any(o.exterior.distance(Point(m[e])) < tol or o.contains(Point(m[e])) for o in ops):
                continue
            # trim back from the opening end to the nearest crossing member (the longitudinal stops on that beam)
            ln = LineString([m['a'], m['b']])
            pts = []
            for c in cross:
                x = ln.intersection(c)
                if x.geom_type == 'Point' and Point(m[e]).distance(x) > tol and Point(m[o_]).distance(x) > tol:
                    pts.append((Point(m[e]).distance(x), (x.x, x.y)))
            if not pts:
                m = None
                break
            m = dict(m)
            m[e] = min(pts)[1]
            m['evidence'] = list(m['evidence']) + [f'R-NL3: end {e} stops on the member before the opening (opening lies between the members on both sides)']
        if m is None or math.dist(m['a'], m['b']) < 60:
            n += 1
            continue
        keep.append(m)
    deck['members'] = keep
    return n


def evidence_gate(deck, drawn, lat=40.0, cover=0.5):
    """R-EV (review 2026-10-26, principle 1): before export every deck member must lie on drawn geometry of its own plan - collinear
    drawn lines (any style) covering >= 50 % of its length within 40 mm. Members built from the symmetry note (R-SY2) keep their
    evidence 'from symmetry note'. A member that fails goes to the question list, not into the XML. Returns the questions."""
    qs = []
    for key in ('members', 'deep'):
        keep = []
        for m in deck.get(key, []):
            ev = ' '.join(str(e) for e in (m.get('evidence') or []))
            L = math.dist(m['a'], m['b'])
            if L < 1 or 'R-SY2' in ev or 'symmetry' in ev.lower() or m.get('pid') is not None:   # traced from a drawn path (pid) = drawn
                keep.append(m)
                continue
            ux, uy = (m['b'][0] - m['a'][0]) / L, (m['b'][1] - m['a'][1]) / L
            if _bridged(m['a'], (ux, uy, L), drawn, lat=lat, cover=cover):
                keep.append(m)
                continue
            qs.append({'member': [round(c) for c in tuple(m['a']) + tuple(m['b'])], 'kind': m.get('kind'),
                       'issue': 'R-EV: no drawn line of the plan under this member - not exported; ' + ev[:160]})
        deck[key] = keep
    return qs


def end_on_web_face(deck, touch=3.0):
    """R-CN8 (owner 2026-10-27): a carling / beam that butts on a girder or deep web STARTS AT THE FRONT FACE of that web (half the web thickness before the
    moulded line), never on the moulded line itself - so its volume is not above / across the web and flange.  The girder web and flange belong to the deck connection."""
    sup = [m for m in deck.get('deep', []) + deck['members'] if m.get('kind') in ('deep', 'girder')]
    rep = {'moved': 0, 'checked': 0}
    for m in deck['members']:
        if m.get('kind') in ('deep', 'girder'):
            continue
        L = math.dist(m['a'], m['b'])
        if L < 1:
            continue
        for which, other in (('a', 'b'), ('b', 'a')):
            P = m[which]
            for g in sup:
                if g is m:
                    continue
                gl = LineString([g['a'], g['b']])
                if gl.distance(Point(P)) > touch:
                    continue
                gx, gy = g['b'][0] - g['a'][0], g['b'][1] - g['a'][1]
                GL = math.hypot(gx, gy)
                if GL < 1:
                    continue
                ux, uy = (m[other][0] - P[0]) / L, (m[other][1] - P[1]) / L        # from the end into the member
                sin = abs(ux * gy - uy * gx) / GL                                   # angle between member axis and the girder line
                if sin < 0.3:
                    continue                                                        # (nearly) collinear: not a butt joint
                t = g.get('web_t')
                if not t:
                    sec = g.get('section')
                    t = (sec[3] if isinstance(sec, (list, tuple)) and len(sec) > 3 and isinstance(sec[3], (int, float)) else 10.0)
                back = (t / 2.0) / sin
                if back >= 0.4 * L:
                    continue
                rep['checked'] += 1
                m[which] = (P[0] + ux * back, P[1] + uy * back)
                m['evidence'].append(f"R-CN8 end {which} starts at the web front face ({back:.1f} mm before the moulded line of the {g.get('kind')})")
                rep['moved'] += 1
                break
    return rep
