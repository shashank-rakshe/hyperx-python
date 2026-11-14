"""
Pipe routes from plain words: legs in compass / vertical directions (or waypoints) -> a 3D pipe solid (STEP) with exact circular
bends, plus everything the hydraulics tool needs (length, net rise, bends by angle).

  legs      [{"dir": "east" | "west" | "north" | "south" | "up" | "down" | "+x" | "-y" ..., "length": mm}, ...]   or
  waypoints [[x, y, z], ...]  the centre-line corners (mm)
  od, wall  outside diameter and wall thickness (mm); wall omitted = a solid rod of diameter od
  bend      "LR" long radius (centre-line radius 1.5 x OD, the default), "SR" short radius (1.0 x OD) or a radius in mm

Geometry: straight legs joined by circular arcs of the bend radius (tangent to both legs, tangent length R tan(theta / 2));
the solid is a circle swept along that G1 path by OpenCascade. Checked against the analytic volume and against an independent
kernel (cadcore, Rust): the same route gave the same volume within 0.01 %.
"""
import math, os
import numpy as np

DIRS = {'east': (1, 0, 0), 'west': (-1, 0, 0), 'north': (0, 1, 0), 'south': (0, -1, 0), 'up': (0, 0, 1), 'down': (0, 0, -1),
        'forward': (1, 0, 0), 'back': (-1, 0, 0), 'aft': (-1, 0, 0), 'fwd': (1, 0, 0), 'port': (0, 1, 0), 'starboard': (0, -1, 0),
        '+x': (1, 0, 0), '-x': (-1, 0, 0), '+y': (0, 1, 0), '-y': (0, -1, 0), '+z': (0, 0, 1), '-z': (0, 0, -1),
        'x': (1, 0, 0), 'y': (0, 1, 0), 'z': (0, 0, 1), 'vertical': (0, 0, 1), 'horizontal': (1, 0, 0)}
STEEL = 7850.0                                                       # kg/m3


def waypoints_from_legs(legs, start=(0.0, 0.0, 0.0)):
    p = np.array(start, float)
    pts = [p.copy()]
    for k, leg in enumerate(legs, 1):
        d = leg.get('dir')
        v = np.array(DIRS[str(d).lower().strip()], float) if isinstance(d, str) and str(d).lower().strip() in DIRS else (
            np.array(d, float) if isinstance(d, (list, tuple)) and len(d) == 3 else None)
        if v is None:
            raise ValueError(f'leg {k}: unknown direction {d!r}; use east / west / north / south / up / down or +x -x +y -y +z -z')
        L = float(leg['length'])
        if L <= 0:
            raise ValueError(f'leg {k}: the length must be positive')
        p = p + v / np.linalg.norm(v) * L
        pts.append(p.copy())
    return np.array(pts)


def bend_radius(od, bend):
    if isinstance(bend, (int, float)):
        return float(bend)
    b = str(bend or 'LR').upper()
    if b in ('LR', 'LONG', 'LONG RADIUS'):
        return 1.5 * od
    if b in ('SR', 'SHORT', 'SHORT RADIUS'):
        return 1.0 * od
    try:
        return float(b)
    except ValueError:
        raise ValueError('bend: "LR" (1.5 x OD), "SR" (1.0 x OD) or a radius in mm')


def plan(pts, R):
    """centre-line pieces: [('line', a, b)] and [('arc', a, mid, b)] for every corner, plus the bend list"""
    n = len(pts)
    dirs = []
    for i in range(n - 1):
        v = pts[i + 1] - pts[i]
        dirs.append(v / np.linalg.norm(v))
    cut = [0.0] * n                                                # tangent length taken from each corner
    bends = []
    for i in range(1, n - 1):
        u, v = dirs[i - 1], dirs[i]
        cosang = float(np.clip(u @ v, -1, 1))
        th = math.acos(cosang)                                     # deflection angle
        if th < 1e-6:
            continue
        if abs(th - math.pi) < 1e-6:
            raise ValueError(f'the route turns back on itself at point {i}')
        t = R * math.tan(th / 2)
        cut[i] = t
        bends.append({'at_point': i, 'angle_deg': round(math.degrees(th), 2), 'tangent_mm': round(t, 1)})
    for i in range(n - 1):
        L = float(np.linalg.norm(pts[i + 1] - pts[i]))
        if cut[i] + cut[i + 1] > L + 1e-6:
            raise ValueError(f'leg {i + 1} is {L:g} mm long but the two bends at its ends need {cut[i] + cut[i + 1]:.0f} mm of it '
                             f'(tangents {cut[i]:.0f} + {cut[i + 1]:.0f}): lengthen the leg, use a smaller bend radius or a short radius bend')
    pieces, cur = [], pts[0]
    for i in range(1, n - 1):
        if cut[i] == 0.0:
            continue
        u, v = dirs[i - 1], dirs[i]
        a, b = pts[i] - u * cut[i], pts[i] + v * cut[i]
        nrm = v - (v @ u) * u
        nrm /= np.linalg.norm(nrm)
        c = a + nrm * R
        m = c + (pts[i] - c) / np.linalg.norm(pts[i] - c) * R
        pieces.append(('line', cur, a))
        pieces.append(('arc', a, m, b))
        cur = b
    pieces.append(('line', cur, pts[-1]))
    return pieces, bends


def build(pts, od, wall, R):
    import cadquery as cq
    pieces, bends = plan(pts, R)
    edges = []
    for p in pieces:
        if p[0] == 'line':
            if np.linalg.norm(p[2] - p[1]) > 1e-6:
                edges.append(cq.Edge.makeLine(cq.Vector(*p[1]), cq.Vector(*p[2])))
        else:
            edges.append(cq.Edge.makeThreePointArc(cq.Vector(*p[1]), cq.Vector(*p[2]), cq.Vector(*p[3])))
    path = cq.Wire.assembleEdges(edges)
    d0 = (pts[1] - pts[0]) / np.linalg.norm(pts[1] - pts[0])
    plane = cq.Plane(origin=tuple(pts[0]), xDir=tuple(np.cross(d0, (0, 0, 1)) if abs(d0[2]) < 0.99 else (1, 0, 0)), normal=tuple(d0))
    wp = cq.Workplane(plane).circle(od / 2)
    if wall:
        wp = wp.circle(od / 2 - wall)
    solid = wp.sweep(cq.Workplane(obj=path), transition='round')
    return solid, path, bends


def route(legs=None, waypoints=None, od=None, wall=None, bend='LR', start=(0.0, 0.0, 0.0), out=None, density=STEEL, name='pipe_route'):
    if not od or od <= 0:
        raise ValueError('give the pipe outside diameter od (mm)')
    if wall and wall >= od / 2:
        raise ValueError('the wall thickness must be less than half the outside diameter')
    pts = np.array(waypoints, float) if waypoints else (waypoints_from_legs(legs, start) if legs else None)
    if pts is None or len(pts) < 2:
        raise ValueError('give the route as legs [{"dir": "east", "length": 5000}, ...] or as waypoints')
    R = bend_radius(od, bend)
    if R < od:
        raise ValueError(f'a bend radius of {R:g} mm is smaller than the pipe diameter {od:g} mm: use at least {od:g} (short radius)')
    solid, path, bends = build(pts, od, wall, R)
    from .rhino import volume
    shp = solid.val()
    vol = volume(shp)
    straight = float(sum(np.linalg.norm(pts[i + 1] - pts[i]) for i in range(len(pts) - 1)))
    cl = sum(b['tangent_mm'] * 2 - math.radians(b['angle_deg']) * R for b in bends)
    length = straight - cl
    rise = float(pts[-1][2] - pts[0][2])
    bore = od - 2 * wall if wall else od
    elbows = {}
    for b in bends:
        a = round(b['angle_deg'])
        key = ('standard_elbow_90_deg' if a >= 75 else 'standard_elbow_45_deg') if str(bend).upper() in ('SR', 'SHORT') or R < 1.4 * od else \
            ('long_radius_90_deg' if a >= 75 else 'standard_elbow_45_deg')
        elbows[key] = elbows.get(key, 0) + 1
    res = {'waypoints': [[round(float(x), 1) for x in p] for p in pts], 'od_mm': od, 'wall_mm': wall, 'bend_radius_mm': round(R, 1),
           'bends': bends, 'centreline_length_mm': round(length, 1), 'net_rise_mm': round(rise, 1), 'volume_mm3': round(vol, 1),
           'mass_kg': round(vol * 1e-9 * density, 3), 'bbox_mm': [round(v, 1) for v in (shp.BoundingBox().xlen, shp.BoundingBox().ylen, shp.BoundingBox().zlen)],
           'valid': bool(shp.isValid()),
           'pipe_flow_input': {'segments': [{'d_mm': round(bore, 1), 'length_m': round(length / 1000, 3), 'rise_m': round(rise / 1000, 3),
                                             'fittings': elbows}]}}
    if out:
        import cadquery as cq
        cq.exporters.export(solid, out)
        res['file'] = out
    nb = len(bends)
    res['plain_english'] = (
        f"Routed a {od:g} mm" + (f" x {wall:g} mm wall" if wall else ' solid') + f" pipe through {len(pts)} points: {straight:,.0f} mm of straight legs "
        f"joined by {nb} bend(s) of {R:g} mm centre-line radius ({'long' if abs(R - 1.5 * od) < 0.01 * od else 'short' if abs(R - od) < 0.01 * od else 'custom'} radius). "
        f"Centre-line length {length / 1000:.3f} m, net rise {rise / 1000:+.3f} m, bounding box {res['bbox_mm'][0]:g} x {res['bbox_mm'][1]:g} x {res['bbox_mm'][2]:g} mm"
        + (f"; steel mass {res['mass_kg']:.1f} kg" if wall else '') + f"; the solid is {'valid' if res['valid'] else 'NOT valid'}."
        + (f" Written to {os.path.basename(out)}." if out else '') +
        ' For the pressure drop of this route call pipe_flow with the segment in pipe_flow_input (bore, length, rise, bends).')
    return res
