"""
Steel connection library (own code, from published standard practice - EN 1993-1-8 spacing rules, ISO bolt / washer sizes,
EN 10365 section sizes): a connection from plain words -> 3D CAD (STEP, every plate / bolt / weld a named part), checks, and
meshes (shell mid-surface mesh with bolt links as a CalculiX input, hex meshes of the thick plates).

Kinds (axes: column along Z, web in the Y-Z plane, beam along +Y from the column flange, beam web in the Y-Z plane):
  end_plate   beam welded to an end plate bolted to the column flange (flush, or extended with ext > 0)
  fin_plate   fin plate welded to the column flange, bolted to the beam web (shear connection)
  base_plate  column on a base plate with four anchor bolts (optional ribs, concrete block)
  splice      beam splice: flange cover plates and web cover plates, bolted

Sizes: IPE, HEA, HEB names (or {"h","b","tw","tf"} in mm); bolts "M20-8.8". Root fillets of rolled sections are not modelled.
Not here: connection resistance (strength) checks - this is geometry, spacing checks and meshes.
IDEA StatiCa's own connection library is proprietary; nothing of it is used.
"""
import math, os
import numpy as np

SECTIONS = {  # name: (h, b, tw, tf)  mm, EN 10365
    'IPE200': (200, 100, 5.6, 8.5), 'IPE240': (240, 120, 6.2, 9.8), 'IPE270': (270, 135, 6.6, 10.2), 'IPE300': (300, 150, 7.1, 10.7),
    'IPE330': (330, 160, 7.5, 11.5), 'IPE360': (360, 170, 8.0, 12.7), 'IPE400': (400, 180, 8.6, 13.5), 'IPE450': (450, 190, 9.4, 14.6),
    'IPE500': (500, 200, 10.2, 16.0), 'IPE550': (550, 210, 11.1, 17.2), 'IPE600': (600, 220, 12.0, 19.0),
    'HEA200': (190, 200, 6.5, 10.0), 'HEA240': (230, 240, 7.5, 12.0), 'HEA260': (250, 260, 7.5, 12.5), 'HEA300': (290, 300, 8.5, 14.0),
    'HEA320': (310, 300, 9.0, 15.5), 'HEA360': (350, 300, 10.0, 17.5), 'HEA400': (390, 300, 11.0, 19.0),
    'HEB200': (200, 200, 9.0, 15.0), 'HEB240': (240, 240, 10.0, 17.0), 'HEB260': (260, 260, 10.0, 17.5), 'HEB300': (300, 300, 11.0, 19.0),
    'HEB320': (320, 300, 11.5, 20.5), 'HEB360': (360, 300, 12.5, 22.5), 'HEB400': (400, 300, 13.5, 24.0),
}
# ISO 4014 head (s across flats, k height), ISO 4032 nut (m), ISO 7089 washer (OD, t)
BOLTS = {12: (18, 7.5, 10.8, 24, 2.5), 16: (24, 10.0, 14.8, 30, 3.0), 20: (30, 12.5, 18.0, 37, 3.0), 22: (34, 14.0, 19.4, 39, 3.0),
         24: (36, 15.0, 21.5, 44, 4.0), 27: (41, 17.0, 23.8, 50, 4.0), 30: (46, 18.7, 25.6, 56, 4.0)}
STEEL = 7850.0


def section(spec):
    if isinstance(spec, dict):
        h, b, tw, tf = (float(spec[k]) for k in ('h', 'b', 'tw', 'tf'))
        return {'name': spec.get('name', f'{h:g}x{b:g}x{tw:g}x{tf:g}'), 'h': h, 'b': b, 'tw': tw, 'tf': tf}
    key = str(spec).upper().replace(' ', '').replace('-', '')
    if key not in SECTIONS:
        raise ValueError(f'unknown section {spec!r}: use one of {", ".join(sorted(SECTIONS))} or {{"h","b","tw","tf"}}')
    h, b, tw, tf = SECTIONS[key]
    return {'name': key, 'h': h, 'b': b, 'tw': tw, 'tf': tf}


def bolt(spec):
    s = str(spec).upper().replace(' ', '')
    try:
        d = int(float(s.split('-')[0].lstrip('M')))
        cls = s.split('-')[1] if '-' in s else '8.8'
    except (ValueError, IndexError):
        raise ValueError('bolt: write like "M20-8.8"')
    if d not in BOLTS:
        raise ValueError(f'bolt M{d} not in the table (M12 M16 M20 M22 M24 M27 M30)')
    sw, k, m, wd, wt = BOLTS[d]
    d0 = d + (1 if d <= 14 else 2 if d <= 24 else 3)          # EN 1090-2 normal clearance hole
    return {'d': d, 'cls': cls, 's': sw, 'k': k, 'm': m, 'wd': wd, 'wt': wt, 'd0': float(d0), 'name': f'M{d}-{cls}'}


def _cq():
    import cadquery as cq
    return cq


def _plane(origin, xdir, normal):
    return _cq().Plane(origin=tuple(float(v) for v in origin), xDir=tuple(float(v) for v in xdir), normal=tuple(float(v) for v in normal))


def i_solid(sec, length, origin, axis, xdir):
    """I-section extruded from origin along axis; profile x = xdir, profile y = axis x xdir (web direction)"""
    h, b, tw, tf = sec['h'], sec['b'], sec['tw'], sec['tf']
    pts = [(-b / 2, -h / 2), (b / 2, -h / 2), (b / 2, -h / 2 + tf), (tw / 2, -h / 2 + tf), (tw / 2, h / 2 - tf), (b / 2, h / 2 - tf),
           (b / 2, h / 2), (-b / 2, h / 2), (-b / 2, h / 2 - tf), (-tw / 2, h / 2 - tf), (-tw / 2, -h / 2 + tf), (-b / 2, -h / 2 + tf)]
    return _cq().Workplane(_plane(origin, xdir, axis)).polyline(pts).close().extrude(length), pts


def box(center, size):
    cq = _cq()
    return cq.Workplane('XY').box(*size).translate(tuple(center))


def cyl(origin, axis, d, length):
    ax = np.array(axis, float)
    ax /= np.linalg.norm(ax)
    ref = np.array([1.0, 0, 0]) if abs(ax[0]) < 0.9 else np.array([0, 1.0, 0])
    return _cq().Workplane(_plane(origin, ref, ax)).circle(d / 2).extrude(length)


def bolt_solid(bt, p, axis, head_at, grip, washers=True):
    """one bolt: head on the head_at side. p = point on the axis at the start of the grip (the head side), axis points from the
    head into the joint. Returns a single fused solid and the nut-side end point."""
    ax = np.array(axis, float)
    ax /= np.linalg.norm(ax)
    p = np.array(p, float)
    d = bt['d']
    wt = bt['wt'] if washers else 0.0
    cq = _cq()
    def hexp(origin, h, across):
        pl = _plane(origin, (1, 0, 0) if abs(ax[0]) < 0.9 else (0, 1, 0), ax)
        return cq.Workplane(pl).polygon(6, across / math.cos(math.radians(30))).extrude(h)
    parts = []
    z = p - ax * (wt + bt['k'])                                # head starts above the washer
    parts.append(hexp(z, bt['k'], bt['s']))
    if washers:
        parts.append(cyl(p - ax * wt, ax, bt['wd'], wt).cut(cyl(p - ax * wt, ax, d, wt)))
    total = wt + bt['k'] + grip + (wt + bt['m'] if washers else bt['m'])
    parts.append(cyl(p - ax * (wt + bt['k']), ax, d, total + 0.3 * d))
    end = p + ax * grip
    if washers:
        parts.append(cyl(end, ax, bt['wd'], wt).cut(cyl(end, ax, d, wt)))
    parts.append(hexp(end + ax * wt, bt['m'], bt['s']))
    out = parts[0]
    for q in parts[1:]:
        out = out.union(q)
    return out


def fillet_weld(pts2, plane_origin, xdir, normal, a, toward=1.0):
    """triangular fillet weld all round an I outline: a ruled loft from the outline offset by a (on the plate face) to the outline
    a further along the beam, minus the beam itself; toward = +1 / -1 direction of the beam along the normal"""
    cq = _cq()
    pl = _plane(plane_origin, xdir, normal)
    solid = (cq.Workplane(pl).polyline(pts2).close().offset2D(a, 'intersection').workplane(offset=toward * a)
             .polyline(pts2).close().loft(ruled=True))
    beam = cq.Workplane(pl).polyline(pts2).close().extrude(toward * a)
    return solid.cut(beam)


def check_spacing(bt, plate_t, points2, plate_w, plate_h, label):
    """EN 1993-1-8 Table 3.3: e1, e2 >= 1.2 d0, p1 >= 2.2 d0, p2 >= 2.4 d0, e <= 4t + 40 (points2 in the plate's own u, v)"""
    d0, msgs = bt['d0'], []
    P = np.array(points2, float)
    sides = {'left': (P[:, 0] + plate_w / 2).min(), 'right': (plate_w / 2 - P[:, 0]).min(),
             'bottom': (P[:, 1] + plate_h / 2).min(), 'top': (plate_h / 2 - P[:, 1]).min()}
    for side, e in sides.items():                           # edge distance of the bolt nearest to each free edge
        if e > 1e5:
            continue
        if e < 1.2 * d0 - 0.01:
            msgs.append(f'{label}: edge distance {e:.0f} mm ({side}) is less than 1.2 d0 = {1.2 * d0:.0f} mm')
        if e > 4 * plate_t + 40 + 0.01:
            msgs.append(f'{label}: edge distance {e:.0f} mm ({side}) is more than 4t + 40 = {4 * plate_t + 40:.0f} mm')
    for i in range(len(P)):
        for j in range(i + 1, len(P)):
            dist = float(np.hypot(*(P[i] - P[j])))
            if dist < 2.2 * d0 - 0.01:
                msgs.append(f'{label}: bolts {dist:.0f} mm apart, less than 2.2 d0 = {2.2 * d0:.0f} mm')
    return sorted(set(msgs))


# ======================================================================== connection builders
class Conn:
    def __init__(self, kind):
        self.kind = kind
        self.parts = []                                     # {'name','role','solid'}
        self.bolts = []                                     # {'p','axis','grip','name'} axis from head into the joint
        self.holes = []                                     # (origin, axis, d0, length) cut from every non-bolt part it touches
        self.plates = []                                    # shell model plates
        self.links = []                                     # bolt links for the shell model: (a, b, name)
        self.warnings = []
        self.info = {}

    def add(self, name, role, solid):
        self.parts.append({'name': name, 'role': role, 'solid': solid})


def _plate3d(pid, origin, u, v, w, h, t, holes=(), n=16):
    """mid-surface plate: rectangle w x h about origin in the u, v plane, thickness t"""
    u, v, o = (np.array(x, float) for x in (u, v, origin))
    outline = [o + u * a + v * b for a, b in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2))]
    hs = []
    for (hu, hv, hd) in holes:
        hs.append([(o + u * (hu + hd / 2 * math.cos(2 * math.pi * k / n)) + v * (hv + hd / 2 * math.sin(2 * math.pi * k / n))).round(4).tolist() for k in range(n)])
    return {'id': pid, 't': float(t), 'outline': [p.round(4).tolist() for p in outline], 'holes': hs}


def _section_plates(prefix, sec, origin, axis, xdir, length):
    """web + two flanges as mid-surface plates; axis = length direction, xdir = flange width direction"""
    o, ax, xd = (np.array(x, float) for x in (origin, axis, xdir))
    wd = np.cross(ax, xd)                                   # web direction
    h, b, tw, tf = sec['h'], sec['b'], sec['tw'], sec['tf']
    c = o + ax * length / 2
    return [_plate3d(f'{prefix}_web', c, ax, wd, length, h - tf, tw),
            _plate3d(f'{prefix}_flange_top', c + wd * (h / 2 - tf / 2), ax, xd, length, b, tf),
            _plate3d(f'{prefix}_flange_bot', c - wd * (h / 2 - tf / 2), ax, xd, length, b, tf)]


def _fin_u(n):
    return (np.arange(n) - (n - 1) / 2.0)


def end_plate(beam, column, bt, tp=20.0, ext=0.0, rows=None, gauge=None, weld=None, stiffeners=True, Lb=1000.0, Lc=1500.0, washers=True):
    cq = _cq()
    B, C = section(beam), section(column)
    c = Conn('end_plate')
    d0 = bt['d0']
    weld = weld or max(4.0, round(0.7 * B['tw']))
    g = gauge or (90.0 if C['b'] < 230 else 100.0)
    if rows is None:                                        # bolt rows measured up from the beam axis
        m = max(40.0, 1.4 * d0)
        zin = B['h'] / 2 - B['tf'] - m                      # first row inside the beam, below the top flange
        rows = [zin]
        if ext > 0:
            e_end = max(35.0, 1.5 * d0)
            xa = max(ext - e_end, bt['wd'] / 2 + weld + 6.0)            # outer row clear of the flange weld and its washer
            ext = math.ceil((xa + e_end) / 5) * 5
            rows = [B['h'] / 2 + xa] + rows
        rows = sorted(set([r for r in rows] + [-r for r in rows]), reverse=True)
    rows = [float(r) for r in rows]
    hp = B['h'] + 2 * ext
    bp = max(B['b'], g + 2 * max(40.0, 1.5 * d0))
    bp = math.ceil(bp / 5) * 5
    yf = C['h'] / 2                                         # outer face of the column flange
    # column and beam
    col, _ = i_solid(C, Lc, (0, 0, -Lc / 2), (0, 0, 1), (1, 0, 0))
    beam_s, bpts = i_solid(B, Lb, (0, yf + tp, 0), (0, 1, 0), (1, 0, 0))
    c.add('column', 'section', col)
    c.add('beam', 'section', beam_s)
    c.add('end_plate', 'plate', box((0, yf + tp / 2, 0), (bp, tp, hp)))
    xs = (-g / 2, g / 2)
    pts_uv = [(x, z) for z in rows for x in xs]
    c.warnings += check_spacing(bt, tp, pts_uv, bp, hp, 'end plate')
    if g / 2 + d0 / 2 + 3 > C['b'] / 2:
        c.warnings.append(f'bolt gauge {g:g} mm is too wide for the column flange width {C["b"]:g} mm')
    if bp > C['b'] + 0.01:
        c.warnings.append(f'end plate {bp:g} mm wide is wider than the column flange {C["b"]:g} mm')
    # stiffeners in the column web at the beam flanges
    if stiffeners:
        ts = B['tf']
        for sgn, nm in ((1, 'top'), (-1, 'bottom')):
            zc = sgn * (B['h'] / 2 - B['tf'] / 2)
            width = (C['b'] - C['tw']) / 2 - 2
            for sx, side in ((1, 'right'), (-1, 'left')):
                c.add(f'col_stiffener_{nm}_{side}', 'stiffener',
                      box((sx * (C['tw'] / 2 + width / 2), 0, zc), (width, C['h'] - 2 * C['tf'], ts)))
    # welds: beam outline to the end plate
    if weld:
        try:
            wsol = fillet_weld(bpts, (0, yf + tp, 0), (1, 0, 0), (0, 1, 0), weld, 1.0)
            c.add('weld_beam_to_plate', 'weld', wsol)
        except Exception as e:                              # a weld that cannot be built must not stop the model
            c.warnings.append(f'weld not modelled: {type(e).__name__}')
    # bolts: head on the beam side (outside), nut inside the column
    grip = tp + C['tf']
    for z in rows:
        for x in xs:
            c.bolts.append({'p': (x, yf + tp, z), 'axis': (0, -1, 0), 'grip': grip, 'name': f'bolt_{len(c.bolts) + 1}'})
            c.holes.append(((x, yf + tp, z), (0, -1, 0), d0, grip))
    # shell model: mid-surfaces
    ym_plate = yf + tp / 2
    c.plates += _section_plates('column', C, (0, 0, -Lc / 2), (0, 0, 1), (1, 0, 0), Lc)
    c.plates += _section_plates('beam', B, (0, ym_plate, 0), (0, 1, 0), (1, 0, 0), Lb - tp / 2)
    c.plates.append(_plate3d('end_plate', (0, ym_plate, 0), (1, 0, 0), (0, 0, 1), bp, hp, tp))
    if stiffeners:
        for sgn, nm in ((1, 'top'), (-1, 'bottom')):
            zc = sgn * (B['h'] / 2 - B['tf'] / 2)
            c.plates.append(_plate3d(f'col_stiffener_{nm}', (0, 0, zc), (1, 0, 0), (0, 1, 0), C['b'] - C['tf'] * 0, C['h'] - C['tf'], B['tf']))
    for z in rows:
        for x in xs:                                         # bolt links: end plate mid-surface <-> column flange mid-surface
            c.links.append(((x, ym_plate, z), (x, yf - C['tf'] / 2, z), f'bolt_{len(c.links) + 1}', 'end_plate', 'column_flange_top'))
    c.info = {'beam': B['name'], 'column': C['name'], 'end_plate_mm': [bp, hp, tp], 'bolt_rows_z_mm': rows, 'gauge_mm': g,
              'weld_a_mm': weld, 'bolts': len(c.bolts)}
    c.fix = [{'z': -Lc / 2, 'dof': '123456'}, {'z': Lc / 2, 'dof': '123456'}]
    c.tip = ('y', yf + Lb, (0, 0, -1))
    return c


def fin_plate(beam, column, bt, tp=10.0, rows=3, cols=1, pitch=None, weld=None, Lb=1000.0, Lc=1500.0, gap=10.0, washers=True):
    B, C = section(beam), section(column)
    c = Conn('fin_plate')
    d0 = bt['d0']
    p1 = pitch or math.ceil(max(2.5 * d0, 60.0) / 5) * 5
    e1 = max(1.5 * d0, 35.0)
    e1 = math.ceil(e1 / 5) * 5
    p2 = math.ceil(2.5 * d0 / 5) * 5
    hp = (rows - 1) * p1 + 2 * e1
    wp = gap + e1 + (cols - 1) * p2 + e1
    clear = B['h'] - 2 * B['tf']
    if hp > clear:
        c.warnings.append(f'fin plate height {hp:g} mm does not fit between the beam flanges ({clear:g} mm): use fewer bolt rows')
    weld = weld or max(5.0, round(0.7 * tp))
    yf = C['h'] / 2
    col, _ = i_solid(C, Lc, (0, 0, -Lc / 2), (0, 0, 1), (1, 0, 0))
    c.add('column', 'section', col)
    xb = tp + B['tw'] / 2                                    # beam web sits beside the fin plate
    beam_s, _ = i_solid(B, Lb, (xb, yf + gap, 0), (0, 1, 0), (1, 0, 0))
    c.add('beam', 'section', beam_s)
    c.add('fin_plate', 'plate', box((tp / 2, yf + wp / 2, 0), (tp, wp, hp)))
    for sgn, nm in ((1, 'top'), (-1, 'bottom')):             # fillet welds, two sides of the plate on the column flange face
        pass
    ys = [yf + gap + e1 + k * p2 for k in range(cols)]
    zs = [(k - (rows - 1) / 2.0) * p1 for k in range(rows)]
    c.warnings += check_spacing(bt, tp, [(y - (yf + wp / 2), z) for y in ys for z in zs], 1e6, hp, 'fin plate')
    grip = tp + B['tw']
    for y in ys:
        for z in zs:
            c.bolts.append({'p': (tp + B['tw'], y, z), 'axis': (-1, 0, 0), 'grip': grip, 'name': f'bolt_{len(c.bolts) + 1}'})
            c.holes.append(((tp + B['tw'], y, z), (-1, 0, 0), d0, grip))
    # welds as 45 degree triangle prisms along both vertical edges of the plate base
    for sx, nm in ((1, 'front'), (-1, 'back')):
        cq = _cq()
        tri = cq.Workplane('XY').polyline([(sx * tp / 2 + tp / 2, yf), (sx * (tp / 2 + weld) + tp / 2, yf), (sx * tp / 2 + tp / 2, yf + weld)]).close().extrude(hp).translate((0, 0, -hp / 2))
        c.add(f'weld_fin_{nm}', 'weld', tri)
    # shell model
    c.plates += _section_plates('column', C, (0, 0, -Lc / 2), (0, 0, 1), (1, 0, 0), Lc)
    c.plates += _section_plates('beam', B, (xb, yf + gap, 0), (0, 1, 0), (1, 0, 0), Lb)
    c.plates.append(_plate3d('fin_plate', (tp / 2, yf - C['tf'] / 2 + (wp + C['tf'] / 2) / 2, 0), (0, 1, 0), (0, 0, 1), wp + C['tf'] / 2, hp, tp))
    for y in ys:
        for z in zs:
            c.links.append(((tp / 2, y, z), (xb, y, z), f'bolt_{len(c.links) + 1}', 'fin_plate', 'beam_web'))
    c.info = {'beam': B['name'], 'column': C['name'], 'fin_plate_mm': [wp, hp, tp], 'bolt_rows': rows, 'bolt_columns': cols,
              'pitch_mm': p1, 'weld_a_mm': weld, 'bolts': len(c.bolts)}
    c.fix = [{'z': -Lc / 2, 'dof': '123456'}, {'z': Lc / 2, 'dof': '123456'}]
    c.tip = ('y', yf + gap + Lb, (0, 0, -1))
    return c


def base_plate(column, bt, tp=30.0, margin=60.0, ribs=False, rib_t=12.0, rib_h=150.0, concrete=True, Lc=1000.0, embed=400.0, washers=True):
    cq = _cq()
    C = section(column)
    c = Conn('base_plate')
    d0 = bt['d0'] + (6 - (bt['d0'] - bt['d']))               # anchor holes d + 6 (oversize)
    e = math.ceil(max(1.5 * d0, 50.0) / 5) * 5
    wa = max(5.0, round(0.7 * C['tf']))
    margin = max(margin, bt['wd'] + 2 * wa + 10.0)          # washers clear of the column weld
    gx, gy = C['b'] + margin, C['h'] + margin
    bx, by = math.ceil((gx + 2 * e) / 10) * 10, math.ceil((gy + 2 * e) / 10) * 10
    col, pts = i_solid(C, Lc, (0, 0, 0), (0, 0, 1), (1, 0, 0))
    c.add('column', 'section', col)
    c.add('base_plate', 'plate', box((0, 0, -tp / 2), (bx, by, tp)))
    try:
        c.add('weld_column_to_plate', 'weld', fillet_weld(pts, (0, 0, 0), (1, 0, 0), (0, 0, 1), max(5.0, round(0.7 * C['tf'])), 1.0))
    except Exception as ex:
        c.warnings.append(f'weld not modelled: {type(ex).__name__}')
    if ribs:
        for sx in (1, -1):
            for sy, nm in ((1, 'N'), (-1, 'S')):
                pass
        for sy in (1, -1):                                   # ribs on both column flanges, in the web plane direction of the flange outer side
            c.add(f'rib_{"N" if sy > 0 else "S"}', 'stiffener',
                  box((0, sy * (C['h'] / 2 + rib_t / 2), rib_h / 2), (C['b'] * 0.9, rib_t, rib_h)))
    if ribs:
        for P in c.parts:
            if P['role'] == 'weld':
                for R in [q for q in c.parts if q['role'] == 'stiffener']:
                    P['solid'] = P['solid'].cut(R['solid'])
    if concrete:
        cm = 100.0
        c.add('concrete', 'concrete', box((0, 0, -tp - 300.0 / 2 - 0), (bx + 2 * cm, by + 2 * cm, 300.0)))
    pts_uv = []
    rod_up = tp + bt['wt'] + bt['m'] + bt['wt'] + 20.0          # rod above the concrete: plate + washer + nut + projection
    for sx in (1, -1):
        for sy in (1, -1):
            x, y = sx * gx / 2, sy * gy / 2
            pts_uv.append((x, y))
            c.bolts.append({'p': (x, y, 0.0), 'axis': (0, 0, -1), 'grip': tp, 'name': f'anchor_{len(c.bolts) + 1}', 'rod_below': embed if concrete else 0.0})
            c.holes.append(((x, y, 0.0), (0, 0, -1), d0, tp))
    c.warnings += check_spacing(dict(bt, d0=d0), tp, pts_uv, bx, by, 'base plate')
    c.plates += _section_plates('column', C, (0, 0, -tp / 2), (0, 0, 1), (1, 0, 0), Lc + tp / 2)
    c.plates.append(_plate3d('base_plate', (0, 0, -tp / 2), (1, 0, 0), (0, 1, 0), bx, by, tp))
    c.info = {'column': C['name'], 'base_plate_mm': [bx, by, tp], 'anchor_gauge_mm': [gx, gy], 'anchor_hole_mm': d0, 'bolts': 4,
              'concrete_block': bool(concrete)}
    c.fix = [{'z': -tp / 2, 'dof': '3'}]                     # concrete: bearing support (no uplift contact), anchors hold x, y
    c.anchors = [(b['p'][0], b['p'][1], -tp / 2) for b in c.bolts]
    c.tip = ('z', Lc, (1, 0, 0))
    return c


def splice(beam, bt, tp_f=None, tp_w=None, rows=3, gap=10.0, Lb=800.0, washers=True):
    cq = _cq()
    B = section(beam)
    c = Conn('splice')
    d0 = bt['d0']
    tp_f = tp_f or max(10.0, round(B['tf']))
    tp_w = tp_w or max(8.0, round(B['tw'] + 2))
    p1 = math.ceil(max(2.5 * d0, 60.0) / 5) * 5
    e1 = math.ceil(max(1.5 * d0, 35.0) / 5) * 5
    nside = rows
    half = e1 + (nside - 1) * p1 + e1                        # plate length each side of the gap
    Lp = 2 * half + gap
    e2 = math.ceil(max(1.5 * d0, 35.0) / 5) * 5
    g = B['b'] - 2 * e2
    if g < 2.4 * d0:
        c.warnings.append(f'beam flange {B["b"]:g} mm is too narrow for two bolt columns of M{bt["d"]}: use a smaller bolt')
    b1, _ = i_solid(B, Lb, (0, -Lb - gap / 2, 0), (0, 1, 0), (1, 0, 0))
    b2, _ = i_solid(B, Lb, (0, gap / 2, 0), (0, 1, 0), (1, 0, 0))
    c.add('beam_left', 'section', b1)
    c.add('beam_right', 'section', b2)
    zf = B['h'] / 2 + tp_f / 2
    c.add('flange_plate_top', 'plate', box((0, 0, zf), (B['b'], Lp, tp_f)))
    c.add('flange_plate_bot', 'plate', box((0, 0, -zf), (B['b'], Lp, tp_f)))
    hw = B['h'] - 2 * B['tf'] - 20
    xw = B['tw'] / 2 + tp_w / 2
    wl = 2 * (e1 + (nside - 1) * p1 + e1) + gap
    c.add('web_plate_front', 'plate', box((xw, 0, 0), (tp_w, wl, hw)))
    c.add('web_plate_back', 'plate', box((-xw, 0, 0), (tp_w, wl, hw)))
    ys = [sgn * (gap / 2 + e1 + k * p1) for sgn in (1, -1) for k in range(nside)]
    for y in ys:
        for x in (-g / 2, g / 2):
            for sz in (1, -1):
                c.bolts.append({'p': (x, y, sz * (B['h'] / 2 + tp_f)), 'axis': (0, 0, -sz), 'grip': tp_f + B['tf'], 'name': f'bolt_{len(c.bolts) + 1}'})
                c.holes.append(((x, y, sz * (B['h'] / 2 + tp_f)), (0, 0, -sz), d0, tp_f + B['tf']))
    nw = max(1, min(5, int((hw - 2 * e1) // p1) + 1))
    zrows = [(k - (nw - 1) / 2.0) * p1 for k in range(nw)]
    for y in ys:
        for z in zrows:
            c.bolts.append({'p': (B['tw'] / 2 + tp_w, y, z), 'axis': (-1, 0, 0), 'grip': B['tw'] + 2 * tp_w, 'name': f'bolt_{len(c.bolts) + 1}'})
            c.holes.append(((B['tw'] / 2 + tp_w, y, z), (-1, 0, 0), d0, B['tw'] + 2 * tp_w))
    c.warnings += check_spacing(bt, tp_f, [(x, y) for y in ys for x in (-g / 2, g / 2)], B['b'], Lp, 'flange plate')
    c.plates += _section_plates('beam_left', B, (0, -Lb - gap / 2, 0), (0, 1, 0), (1, 0, 0), Lb)
    c.plates += _section_plates('beam_right', B, (0, gap / 2, 0), (0, 1, 0), (1, 0, 0), Lb)
    for sz, nm in ((1, 'top'), (-1, 'bot')):
        c.plates.append(_plate3d(f'flange_plate_{nm}', (0, 0, sz * (B['h'] / 2 + tp_f / 2)), (1, 0, 0), (0, 1, 0), B['b'], Lp, tp_f))
    for sx, nm in ((1, 'front'), (-1, 'back')):
        c.plates.append(_plate3d(f'web_plate_{nm}', (sx * xw, 0, 0), (0, 1, 0), (0, 0, 1), wl, hw, tp_w))
    for y in ys:
        side = 'beam_right' if y > 0 else 'beam_left'
        for x in (-g / 2, g / 2):
            for sz, nm in ((1, 'top'), (-1, 'bot')):
                c.links.append(((x, y, sz * (B['h'] / 2 + tp_f / 2)), (x, y, sz * (B['h'] / 2 - B['tf'] / 2)), f'bolt_{len(c.links) + 1}', f'flange_plate_{nm}', f'{side}_flange_{nm}'))
        for z in zrows:
            for sx, nm in ((1, 'front'), (-1, 'back')):
                c.links.append(((sx * xw, y, z), (0, y, z), f'bolt_{len(c.links) + 1}', f'web_plate_{nm}', f'{side}_web'))
    c.info = {'beam': B['name'], 'flange_plate_mm': [B['b'], Lp, tp_f], 'web_plate_mm': [wl, hw, tp_w], 'bolt_rows_per_side': nside,
              'gap_mm': gap, 'bolts': len(c.bolts)}
    c.fix = [{'y': -Lb - gap / 2, 'dof': '123456'}]
    c.tip = ('y', gap / 2 + Lb, (0, 0, -1))
    return c


KINDS = {'end_plate': end_plate, 'fin_plate': fin_plate, 'base_plate': base_plate, 'splice': splice}
ALIASES = {'endplate': 'end_plate', 'end plate': 'end_plate', 'moment': 'end_plate', 'extended': 'end_plate', 'flush': 'end_plate',
           'finplate': 'fin_plate', 'fin plate': 'fin_plate', 'shear tab': 'fin_plate', 'shear': 'fin_plate',
           'baseplate': 'base_plate', 'base plate': 'base_plate', 'column base': 'base_plate', 'anchor': 'base_plate',
           'beam splice': 'splice', 'splice': 'splice', 'cover plate': 'splice'}


def kind_of(s):
    k = str(s).lower().strip().replace('-', '_')
    if k in KINDS:
        return k
    k = k.replace('_', ' ')
    for a, v in ALIASES.items():
        if a in k:
            return v
    raise ValueError(f'unknown connection kind {s!r}: end_plate, fin_plate, base_plate or splice')


# ======================================================================== realise: solids, checks, files
def _anchor_solid(bt, p, tp, embed, washers=True):
    cq = _cq()
    x, y, _ = p
    wt, m, d = bt['wt'], bt['m'], bt['d']
    top = wt + m + 20.0
    rod = cyl((x, y, -tp - embed), (0, 0, 1), d, tp + embed + top)
    pl = cq.Workplane('XY').workplane(offset=wt).center(x, y).polygon(6, bt['s'] / math.cos(math.radians(30))).extrude(m)
    ring = cyl((x, y, 0), (0, 0, 1), bt['wd'], wt).cut(cyl((x, y, 0), (0, 0, 1), d, wt))
    return rod.union(ring).union(pl)


def _vol(w):
    from .rhino import volume
    return volume(w.val())


def _bbox(w):
    b = w.val().BoundingBox()
    return np.array([b.xmin, b.ymin, b.zmin, b.xmax, b.ymax, b.zmax])


def realise(c, washers=True):
    """cut bolt holes, build bolt solids; fills c.solids"""
    bt = c.bolt
    for o, ax, d0, L in c.holes:
        hole = cyl(o, ax, d0, L)
        hb = _bbox(hole)
        for P in c.parts:
            if P['role'] in ('weld', 'bolt', 'concrete') or hasattr(P['solid'], 'bolt'):
                continue
            pb = _bbox(P['solid'])
            if np.any(hb[:3] > pb[3:] + 1e-6) or np.any(hb[3:] < pb[:3] - 1e-6):
                continue
            P['solid'] = P['solid'].cut(hole)
    for b in c.bolts:
        if b.get('rod_below') is not None:
            sol = _anchor_solid(bt, b['p'], c.info['base_plate_mm'][2], b['rod_below'] or 1.0)
            if b['rod_below']:
                for P in c.parts:
                    if P['role'] == 'concrete':
                        P['solid'] = P['solid'].cut(cyl((b['p'][0], b['p'][1], -c.info['base_plate_mm'][2] - b['rod_below']), (0, 0, 1), bt['d'], b['rod_below']))
        else:
            sol = bolt_solid(bt, b['p'], b['axis'], None, b['grip'], washers)
        c.add(b['name'], 'bolt', sol)


def analyse(c, clash_min=2.0):
    rows, mass, clashes = [], 0.0, []
    for P in c.parts:
        v = _vol(P['solid'])
        rows.append({'part': P['name'], 'role': P['role'], 'volume_mm3': round(v, 1), 'mass_kg': 0.0 if P['role'] == 'concrete' else round(v * 1e-9 * STEEL, 3)})
        if P['role'] != 'concrete':
            mass += v * 1e-9 * STEEL
    boxes = [_bbox(P['solid']) for P in c.parts]
    for i in range(len(c.parts)):
        for j in range(i + 1, len(c.parts)):
            A, B = c.parts[i], c.parts[j]
            if 'concrete' in (A['role'], B['role']) or (A['role'] == 'bolt' and B['role'] == 'bolt'):
                continue
            bi, bj = boxes[i], boxes[j]
            if np.any(bi[:3] > bj[3:] - 1e-6) or np.any(bi[3:] < bj[:3] + 1e-6):
                continue
            try:
                v = _vol(A['solid'].intersect(B['solid']))
            except Exception:
                continue
            if v > clash_min:
                clashes.append(f"{A['name']} overlaps {B['name']} by {v:,.0f} mm3")
    return rows, mass, clashes


def export_step(c, path):
    cq = _cq()
    colors = {'section': (0.55, 0.62, 0.72), 'plate': (0.85, 0.65, 0.2), 'stiffener': (0.9, 0.5, 0.2), 'weld': (0.8, 0.15, 0.15),
              'bolt': (0.25, 0.25, 0.3), 'concrete': (0.75, 0.75, 0.72)}
    a = cq.Assembly(name='connection_assembly')
    for P in c.parts:
        a.add(P['solid'], name=P['name'], color=cq.Color(*colors.get(P['role'], (0.6, 0.6, 0.6))))
    try:
        a.export(path, 'STEP')
    except Exception:
        a.save(path)
    return path


def build(kind, beam=None, column=None, bolt_spec='M20-8.8', out=None, name=None, washers=True, **kw):
    kind = kind_of(kind)
    bt = bolt(bolt_spec)
    if kind == 'splice':
        c = splice(beam or column, bt, washers=washers, **kw)
    elif kind == 'base_plate':
        c = base_plate(column or beam, bt, washers=washers, **kw)
    else:
        if not beam or not column:
            raise ValueError(f'{kind} needs a beam and a column section (for example beam IPE400, column HEB300)')
        c = KINDS[kind](beam, column, bt, washers=washers, **kw)
    c.bolt = bt
    c.name = name or kind
    realise(c, washers)
    rows, mass, clashes = analyse(c)
    c.table, c.mass, c.clashes = rows, mass, clashes
    if out:
        export_step(c, out)
        c.step = out
    return c


def summary(c):
    roles = {}
    for r in c.table:
        roles[r['role']] = roles.get(r['role'], 0) + 1
    return {'kind': c.kind, 'bolt': c.bolt['name'], 'hole_mm': c.bolt['d0'], 'parts': len(c.table), 'parts_by_role': roles,
            'steel_mass_kg': round(c.mass, 1), 'details': c.info, 'warnings': c.warnings, 'clashes': c.clashes,
            'part_list': c.table}


# ======================================================================== meshes
def _with_holes(plates, links, d0, n=16):
    """copy of the plates with a bolt hole (d0) wherever a bolt link touches them"""
    P = [dict(p, holes=[list(h) for h in p.get('holes', [])]) for p in plates]
    byid = {p['id']: p for p in P}
    for a, b, nm, ga, gb in links:
        for pt, gid in ((a, ga), (b, gb)):
            p = byid.get(gid)
            if not p:
                continue
            o = np.array(p['outline'], float)
            u = (o[1] - o[0]) / np.linalg.norm(o[1] - o[0])
            v = (o[3] - o[0]) / np.linalg.norm(o[3] - o[0])
            pt = np.array(pt, float)
            p['holes'].append([(pt + u * (d0 / 2) * math.cos(2 * math.pi * k / n) + v * (d0 / 2) * math.sin(2 * math.pi * k / n)).round(4).tolist()
                               for k in range(n)])
    return P


def shell_mesh(c, size, out_dir, name=None, load_kn=None, holes=True):
    """mid-surface plates -> conforming all-quad shell mesh (own mesher). Every bolt is a hole in each plate it joins; the rim
    nodes of the two holes are tied together (3 translations, node to node by angle = a rigid bolt shank). Supports and one end
    load (kN) are written into a CalculiX input."""
    from .platemesh import build_plates
    name = name or c.name + '_shell'
    d0 = c.bolt['d0']
    plates = _with_holes(c.plates, c.links, d0) if holes else c.plates
    spec = {'name': name, 'element_size': float(size), 'plates': plates, 'fix': c.fix, 'loads': []}
    m, info = build_plates(spec, out_dir, formats=('inp',))
    X = np.array(m.xyz)
    groups = {}
    for e in m.elems:
        groups.setdefault(e['group'], set()).update(e['nodes'])

    def near(pt, gid):
        ids = np.array(sorted(groups[gid]))
        d = np.linalg.norm(X[ids - 1] - np.array(pt), axis=1)
        k = int(np.argmin(d))
        return int(ids[k]), float(d[k])

    def rim(pt, gid, axis):
        ids = np.array(sorted(groups[gid]))
        V = X[ids - 1] - np.array(pt)
        V = V - np.outer(V @ axis, axis)                    # in the plane normal to the bolt axis
        r = np.linalg.norm(V, axis=1)
        sel = np.where(abs(r - d0 / 2) < max(1.0, 0.08 * d0))[0]
        ref = np.cross(axis, [0, 0, 1.0])
        if np.linalg.norm(ref) < 1e-6:
            ref = np.cross(axis, [1.0, 0, 0])
        ref /= np.linalg.norm(ref)
        w = np.cross(axis, ref)
        ang = np.arctan2(V[sel] @ w, V[sel] @ ref)
        return [(int(ids[i]), float(t)) for i, t in zip(sel, ang)]

    pairs, worst, rimmed, fell = [], 0.0, 0, 0
    for a, b, nm, ga, gb in c.links:
        if ga not in groups or gb not in groups:
            continue
        axis = np.array(b, float) - np.array(a, float)
        axis /= np.linalg.norm(axis)
        ra, rb = (rim(a, ga, axis), rim(b, gb, axis)) if holes else ([], [])
        if len(ra) >= 4 and len(rb) >= 4:
            rimmed += 1
            for na, ta in ra:
                nb, tb = min(rb, key=lambda q: abs(math.remainder(q[1] - ta, 2 * math.pi)))
                if na != nb:
                    pairs.append((na, nb))
        else:
            fell += 1
            na, da = near(a, ga)
            nb, db = near(b, gb)
            worst = max(worst, da, db)
            if na != nb:
                pairs.append((na, nb))
    pairs = sorted(set(pairs))
    lines = []
    for na, nb in pairs:
        for k in (1, 2, 3):
            lines += ['*EQUATION', '2', f'{na}, {k}, 1., {nb}, {k}, -1.']
    anchor_nodes = [near(pt, 'base_plate')[0] for pt in getattr(c, 'anchors', [])]
    ax, val, dirn = c.tip
    k = {'x': 0, 'y': 1, 'z': 2}[ax]
    cl, loaded = [], 0
    if load_kn:
        sel = np.where(abs(X[:, k] - val) < 1e-3 * max(size, 1))[0]
        if len(sel):
            P = float(load_kn) * 1000.0 / len(sel)
            for i in sel:
                for j in range(3):
                    if dirn[j]:
                        cl.append(f'{int(i) + 1}, {j + 1}, {P * dirn[j]:.4f}')
            loaded = len(sel)
    path = info['files']['inp']
    txt = open(path).read()
    if lines:
        txt = txt.replace('*STEP', '\n'.join(lines + ['*STEP']), 1)
    bnd = ''.join(f'{n}, 1, 2\n' for n in anchor_nodes)
    if bnd:
        txt = txt.replace('*BOUNDARY\n', '*BOUNDARY\n' + bnd, 1) if '*BOUNDARY' in txt else txt.replace('*NODE FILE', '*BOUNDARY\n' + bnd + '*NODE FILE', 1)
    if cl:
        txt = txt.replace('*NODE FILE', '*CLOAD\n' + '\n'.join(cl) + '\n*NODE FILE', 1)
    open(path, 'w').write(txt)
    info.update({'bolts_tied': rimmed, 'bolts_tied_nearest_node': fell, 'bolt_link_offset_max_mm': round(worst, 2), 'tied_node_pairs': len(pairs),
                 'loaded_nodes': loaded})
    return info


def hex_meshes(c, out_dir, size=None, names=None):
    """hex mesh of every thick part (plates, stiffeners): one CalculiX input per part"""
    from . import hexmesh
    cq = _cq()
    os.makedirs(out_dir, exist_ok=True)
    out = []
    for P in c.parts:
        if P['role'] not in ('plate', 'stiffener') or (names and P['name'] not in names):
            continue
        thin = min(_bbox(P['solid'])[3:] - _bbox(P['solid'])[:3])
        h = float(size) if size else max(4.0, round(thin / 2.5, 1))
        stp = os.path.join(out_dir, f"{c.name}_{P['name']}.step")
        cq.exporters.export(P['solid'], stp)
        inp = os.path.join(out_dir, f"{c.name}_{P['name']}_hex.inp")
        try:
            r = hexmesh.write(stp, h, inp)
            out.append({'part': P['name'], 'size_mm': float(h), 'file': os.path.basename(inp), 'cells': int(r['elements']),
                        'volume_error_percent': r.get('volume_error_percent'), 'min_scaled_jacobian': round(float(r['min_sj']), 3),
                        'inverted': r['inverted']})
        except Exception as e:
            out.append({'part': P['name'], 'size_mm': float(h), 'error': f'{type(e).__name__}: {str(e)[:150]}'})
        try:
            os.remove(stp)
        except OSError:
            pass
    return out


def cantilever_reference(c, load_kn, E=206000.0):
    """beam theory tip deflection P L^3 / 3 E I for the end-load cases (rigid connection, bending only): a sanity reference for the
    shell model - the connection and the shear deformation make the FE model somewhat more flexible"""
    if c.kind == 'base_plate':
        sec = section(c.info['column'])
        I = 2 * sec['tf'] * sec['b'] ** 3 / 12 + (sec['h'] - 2 * sec['tf']) * sec['tw'] ** 3 / 12      # force along x: about the weak axis
        L = c.tip[1] + c.info['base_plate_mm'][2] / 2
    else:
        sec = section(c.info['beam'])
        I = sec['b'] * sec['h'] ** 3 / 12 - (sec['b'] - sec['tw']) * (sec['h'] - 2 * sec['tf']) ** 3 / 12
        start = c.fix[0]['y'] if c.kind == 'splice' else next(P for P in c.parts if P['name'] == 'column')['solid'].val().BoundingBox().ymax
        L = c.tip[1] - start
    return {'L_mm': round(L, 1), 'I_mm4': round(I), 'tip_deflection_mm': round(load_kn * 1000 * L ** 3 / (3 * E * I), 3)}
