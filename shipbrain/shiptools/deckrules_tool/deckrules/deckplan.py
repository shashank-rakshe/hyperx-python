"""Deck plating from a calibrated plan view: footprint, plate zones, openings.

Generic rules (drawing only):
 R-FP  Footprint = largest connected union of closed faces formed by SOLID
       lines inside the view region (plate edges, seams, wall lines).
 R-SM  Plate seams/butts = straight thin solid lines >= 1 m whose BOTH ends
       land on the footprint boundary or on another accepted seam
       (iterated).  Dimension and leader lines end on extension lines or
       in free space and are therefore not accepted.
 R-TH  A zone takes the thickness printed inside it ('8.0', '10.0', ...);
       zones without a mark take the header 'DECK PLATE' default.
 R-OP  A closed face inside the deck is an OPENING when it carries no
       thickness mark and (a) it is circular, or (b) its corners are
       radiused, or (c) a printed 'AxB' size inside it matches its size.
Everything is returned in ship millimetres on the moulded deck plane.
"""
import math
import re
from . import numclass
PROVISION = re.compile(r'\bPROVISION\s+FOR\b|^\s*FUTURE\b', re.I)   # not room names such as 'PROVISIONS STORE'
from shapely.geometry import LineString, Polygon, Point, MultiPolygon
from shapely.ops import unary_union, polygonize
from shapely import affinity

CLOSE_PT = 3.0                # page points (~106 mm at 1/100): notch closing width
TOL = 1.5                     # page points (~53 mm at 1/100)
THK = re.compile(r'^\s*(\d{1,2}\.\d)\s*("?\s*AH\s*"?)?\s*$')   # '12.0 "AH"' = grade AH (note 5)
SIZE = re.compile(r'(\d{3,5})\s*X\s*(\d{3,5})(?:\s*XR\s*(\d+))?')


def _in_region(s, r):
    return all(r[0] < p[0] < r[2] and r[1] < p[1] < r[3] for p in (s.a, s.b))


def to_ship(v, geom):
    """page-point geometry -> ship mm (X fwd, Y port)."""
    g = affinity.affine_transform(geom, [v.k, 0, 0, -v.k, -v.x0 * v.k, v.cl_y * v.k])
    return g


def solid_segments(page, v):
    return [s for s in page.segs if not s.dash and s.length > 0.3 and _in_region(s, v.region)]


def _rect_outline(segs, min_len=60.0, tol=2.0):
    """R-FP3: a plan whose outline is four long straight lines (two horizontal, two vertical, each spanning >= 90% of its side)
    is that rectangle, even when the lines do not close into a ring."""
    hs = [s for s in segs if abs(s.a[1] - s.b[1]) < 0.2 and s.length >= min_len]
    vs = [s for s in segs if abs(s.a[0] - s.b[0]) < 0.2 and s.length >= min_len]
    if len(hs) < 2 or len(vs) < 2:
        return None
    x0 = min(min(s.a[0], s.b[0]) for s in hs + vs)
    x1 = max(max(s.a[0], s.b[0]) for s in hs + vs)
    y0 = min(min(s.a[1], s.b[1]) for s in hs + vs)
    y1 = max(max(s.a[1], s.b[1]) for s in hs + vs)
    W, H = x1 - x0, y1 - y0
    if W < 80 or H < 80:
        return None

    def span(ss, lo, hi, ax, val):
        iv = sorted((min(s.a[ax], s.b[ax]), max(s.a[ax], s.b[ax])) for s in ss if abs((s.a[1 - ax] + s.b[1 - ax]) / 2 - val) < tol)
        cov, end = 0.0, lo
        for a, b in iv:
            if b > end:
                cov += b - max(a, end)
                end = b
        return cov / (hi - lo)
    ok = (span(hs, x0, x1, 0, y0) > 0.9 and span(hs, x0, x1, 0, y1) > 0.9 and span(vs, y0, y1, 1, x0) > 0.9 and span(vs, y0, y1, 1, x1) > 0.9)
    return Polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)]) if ok else None


def footprint(page, v):
    segs = solid_segments(page, v)
    faces = [f for f in polygonize(unary_union([LineString([s.a, s.b]) for s in segs])) if f.area > 1]
    u = unary_union(faces)
    parts = sorted(getattr(u, 'geoms', [u]), key=lambda g: -g.area)
    fp = Polygon(parts[0].exterior)
    fb = _rect_outline(segs)
    if fb is not None and fp.area < 0.5 * fb.area:
        fp = fb                                   # R-FP3: outline not closed by solid lines (symbols / the centre line cut it)
    # R-FP2: close dents narrower than 2*CLOSE_PT (small symbols touching the edge) with mitred joins,
    # so straight edges and corners keep their coordinates
    closed = fp.buffer(CLOSE_PT, join_style=2).buffer(-CLOSE_PT, join_style=2)
    if closed.geom_type == 'Polygon' and closed.area >= fp.area:
        fp = Polygon(closed.exterior)
    return fp, segs, faces


def seams(fp, segs, v, min_len_mm=300):
    cand = [s for s in segs if s.width < 0.5 and (s.vertical or s.horizontal)
            and s.length * v.k >= min_len_mm]
    # R-SM2: a seam may cross a cut-out (the plates on either side meet along it), so
    # containment is tested against the outer footprint, not the footprint with holes
    inside = Polygon(fp.exterior).buffer(TOL)
    cand = [s for s in cand if inside.contains(LineString([s.a, s.b]))]
    # keep a candidate while both its ends land on the footprint boundary or on
    # another surviving candidate (grids of seams support each other)
    keep = list(cand)
    ext = unary_union([fp.exterior] + list(fp.interiors))
    while True:
        lines = [LineString([s.a, s.b]) for s in keep]
        nxt = []
        for i, s in enumerate(keep):
            ok = True
            for p in (Point(s.a), Point(s.b)):
                if ext.distance(p) < TOL:
                    continue
                if any(j != i and lines[j].distance(p) < TOL for j in range(len(keep))):
                    continue
                ok = False
                break
            if ok:
                nxt.append(s)
        if len(nxt) == len(keep):
            break
        keep = nxt
    accepted = keep
    return accepted


def _rounded(poly):
    """radiused-corner rectangle/obround: near-rectangular, not a plain
    rectangle, and the extra vertices are short arc chords."""
    mrr = poly.minimum_rotated_rectangle
    ratio = poly.area / mrr.area if mrr.area else 0
    c = list(poly.exterior.coords)
    edges = [math.dist(c[i], c[i + 1]) for i in range(len(c) - 1)]
    per = sum(edges)
    short = sum(1 for e in edges if e < 0.03 * per)
    convex = poly.area / poly.convex_hull.area if poly.convex_hull.area else 0
    return len(edges) >= 8 and short >= 4 and 0.80 < ratio < 0.9999 and convex > 0.985   # R-CV: clouds are not convex


def _circular(poly):
    x0, y0, x1, y1 = poly.bounds
    w, h = x1 - x0, y1 - y0
    if w <= 0 or abs(w - h) > 0.08 * w:
        return False
    r = (w + h) / 4
    return abs(poly.area / (math.pi * r * r) - 1) < 0.06 and len(poly.exterior.coords) > 10


def thin_weight(segs, min_len=5.0):
    """Dominant (length-weighted) solid line weight of the plan: the plate seam /
    cut-out outline weight.  Heavier lines are walls, casings and cloud marks."""
    acc = {}
    for s in segs:
        if s.length >= min_len:
            acc[round(s.width, 2)] = acc.get(round(s.width, 2), 0.0) + s.length
    return max(acc, key=acc.get) if acc else 0.0


def closed_paths(segs, max_width=None):
    """Polygons of drawing paths whose own segments form one closed ring.
    R-OW: with max_width, rings drawn heavier than the plate/opening weight
    (casings, walls, revision clouds) are not cut-out candidates."""
    by = {}
    for s in segs:
        by.setdefault(s.pid, []).append(s)
    out = []
    for pid, ss in by.items():
        if len(ss) < 3:
            continue
        if max_width is not None and max(q.width for q in ss) > max_width:
            continue
        pts = [ss[0].a] + [q.b for q in ss]
        cont = all(math.dist(ss[i].b, ss[i + 1].a) < 0.3 for i in range(len(ss) - 1))
        if cont and math.dist(pts[0], pts[-1]) < 0.5:
            p = Polygon(pts[:-1])
            if not p.is_valid:
                p = p.buffer(0)
                if p.geom_type != 'Polygon':
                    continue
            out.append((pid, p))
    return out


def _has_corner_diagonal(poly, diag):
    """a straight line joining two opposite corners of a rectangle-like ring."""
    x0, y0, x1, y1 = poly.bounds
    cs = [(x0, y0), (x1, y1), (x0, y1), (x1, y0)]
    for s in diag:
        ends = [min(range(4), key=lambda i: math.dist(p, cs[i])) for p in (s.a, s.b)]
        if all(math.dist(p, cs[i]) < 3 for p, i in zip((s.a, s.b), ends)) and set(ends) in ({0, 1}, {2, 3}):
            return True
    return False


def _extend(a, b, d):
    L = math.dist(a, b)
    ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
    return (a[0] - ux * d, a[1] - uy * d), (b[0] + ux * d, b[1] + uy * d)


def _dbox(p, b):
    dx = max(b[0] - p[0], 0, p[0] - b[2])
    dy = max(b[1] - p[1], 0, p[1] - b[3])
    return math.hypot(dx, dy)


_LT = {}


def _leader_index(segs):
    """P5: paths of <= 6 strokes grouped once per segment list, their two end points in a 10-pt grid"""
    k = id(segs)
    if k not in _LT or _LT[k][0] is not segs or _LT[k][1] != len(segs):
        by = {}
        for s in segs:
            by.setdefault(s.pid, []).append(s)
        grid = {}
        for pid, ss in by.items():
            if len(ss) > 6:
                continue
            p0, p1 = ss[0].a, ss[-1].b
            for p in (p0, p1):
                grid.setdefault((int(p[0] // 10), int(p[1] // 10)), set()).add(pid)
        _LT[k] = (segs, len(segs), by, grid)
    return _LT[k][2], _LT[k][3]


def leader_tip(word, segs, reach=2.5):
    """R-LD: a mark with a leader -> far end of the thin path that starts at the text."""
    best = None
    by, grid = _leader_index(segs)
    x0, y0, x1, y1 = word.bbox
    cand = set()
    for gx in range(int((x0 - reach) // 10), int((x1 + reach) // 10) + 1):
        for gy in range(int((y0 - reach) // 10), int((y1 + reach) // 10) + 1):
            cand |= grid.get((gx, gy), set())
    for pid in sorted(cand):
        ss = by[pid]
        pts = [ss[0].a] + [q.b for q in ss]
        d0 = _dbox(pts[0], word.bbox)
        d1 = _dbox(pts[-1], word.bbox)
        if min(d0, d1) > reach:
            continue
        tip = pts[-1] if d0 <= d1 else pts[0]
        L = _dbox(tip, word.bbox)
        if L > 8 and (best is None or min(d0, d1) < best[0]):
            best = (min(d0, d1), tip)
    return best[1] if best else None


def _empty(poly, hidden, v, min_area_m2=1.0, min_width_mm=300):
    """R-OP(e): deck plating always has beams/carlings (hidden lines) under it;
    a sizeable closed outline that no hidden member line enters is a cut-out."""
    if poly.area * v.k ** 2 / 1e6 < min_area_m2:
        return False
    mrr = poly.minimum_rotated_rectangle
    c = list(mrr.exterior.coords)
    w = min(math.dist(c[0], c[1]), math.dist(c[1], c[2]))
    if w * v.k < min_width_mm:
        return False
    core = poly.buffer(-2.0)
    if core.is_empty:
        return False
    return not any(core.intersects(h) for h in hidden)


def find_openings(fp, segs, faces, words, thk_pts, v, hidden=()):
    size_marks = [(w, SIZE.search(w.text)) for w in words if SIZE.search(w.text)]
    min_open = 250 / v.k
    diag = [s for s in segs if not (s.vertical or s.horizontal) and s.length > 5]
    tw = thin_weight(segs)
    cands = [(p, 'ring') for _, p in closed_paths(segs, max_width=tw * 1.5 if tw else None)] + \
            [(Polygon(f.exterior), 'face') for f in faces]
    found = []
    for poly, src in cands:
        if poly.area < (min_open ** 2) or poly.area > 0.25 * fp.area:
            continue
        if not fp.buffer(TOL).contains(poly):
            continue
        if any(poly.contains(p) for p in thk_pts):
            continue
        why = None
        if src == 'ring' and _circular(poly):
            why = 'circle'
        elif src == 'ring' and _rounded(poly):
            why = 'radiused corners'
        else:
            x0, y0, x1, y1 = poly.bounds
            grow = Polygon([(x0 - 6, y0 - 6), (x1 + 6, y0 - 6), (x1 + 6, y1 + 6), (x0 - 6, y1 + 6)])
            for w, m in size_marks:
                if grow.contains(Point(w.cx, w.cy)):
                    a, b = int(m.group(1)) / v.k, int(m.group(2)) / v.k
                    dims = sorted([x1 - x0, y1 - y0])
                    if all(abs(d - e) < 0.06 * e for d, e in zip(dims, sorted([a, b]))):
                        why = f'printed size {m.group(0)}'
                        break
            if why is None and _has_corner_diagonal(poly, diag):
                why = 'diagonal opening symbol'
            if why is None and src == 'face' and _empty(poly, hidden, v):
                why = 'closed outline with no structure under it'
        if why:
            found.append((poly, why))
    keep = []
    for p, why in sorted(found, key=lambda t: -t[0].area):
        if not any(q.buffer(TOL).contains(p) or (q.intersection(p).area > 0.5 * p.area) for q, _ in keep):
            keep.append((p, why))
    return keep


def plate_zones_and_openings(page, v):
    fp, segs, faces = footprint(page, v)
    words = [w for w in page.words if v.region[0] < w.cx < v.region[2] and v.region[1] < w.cy < v.region[3]]
    marks = []
    for w in words:
        m = THK.match(w.text)
        if not m:
            continue
        if numclass.is_weld_size(w, words):              # R2.1: a weld size is never a plate thickness
            continue
        # R-LD: a mark with a leader points at the plate it describes
        tip = leader_tip(w, segs)
        if tip is not None and fp.contains(Point(tip)):
            p, how = Point(tip), 'leader'
        elif fp.contains(Point(w.cx, w.cy)):
            p, how = Point(w.cx, w.cy), 'inside'
        else:
            continue
        marks.append((float(m.group(1)), p, how, 'AH' if m.group(2) else 'A'))
    default_t = float(v.notes.get('plate', '0') or 0)
    hidden = [LineString([s.a, s.b]) for s in page.segs if s.dash.startswith('dash2') and s.length > 3
              and _in_region(s, v.region)]
    openings = find_openings(fp, segs, faces, [w for w in words if fp.buffer(10).contains(Point(w.cx, w.cy))],
                             [p for _, p, h, g in marks], v, hidden)
    sm = seams(Polygon(fp.exterior, [o.exterior.coords for o, _ in openings if fp.contains(o)]), segs, v)
    lines = [fp.exterior] + [LineString(_extend(s.a, s.b, 1.5 * TOL)) for s in sm] + [o.exterior for o, _ in openings]
    zfaces = [z for z in polygonize(unary_union(lines)) if z.area > 4 and fp.buffer(TOL).contains(z)]
    zones = []
    for z in zfaces:
        if any(o.buffer(TOL).contains(z) for o, _ in openings):
            continue
        if z.area < 0.5 * fp.area and any(PROVISION.search(w.text or '') and z.contains(Point(w.cx, w.cy)) for w in words):
            # R2.8 (online rule book v2.3): a 'PROVISION FOR ...' / 'FUTURE ...' area inside its own outline has no plate now -> opening (ASSUMED, asked)
            openings.append((z, 'R2.8 PROVISION / FUTURE area = no plate now (ASSUMED)'))
            continue
        t, src, grade = default_t, 'header DECK PLATE default', 'A'
        inz = [m for m in marks if z.contains(m[1])]
        if inz:
            vals = sorted({m[0] for m in inz})
            grade = 'AH' if any(m[3] == 'AH' for m in inz if m[0] == vals[-1]) else 'A'
            t, src = vals[-1], 'printed mark ' + '/'.join(f'{x:g}' for x in vals) + (' via leader' if any(m[2] == 'leader' for m in inz) else '')
        zones.append({'poly': z, 't': t, 'source': src, 'grade': grade})
    return {'footprint': fp, 'seams': sm, 'zones': zones, 'openings': openings,
            'thickness_marks': len(marks)}
