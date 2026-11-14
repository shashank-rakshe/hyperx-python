"""
In-plane bolt groups (shear + torsion) with EZbolt (https://github.com/wcfrobert/ezbolt, MIT, Robert Wang; copied as written in
vendor/ezbolt): elastic method (superposition and elastic centre of rotation) and the instant centre of rotation (ICR) method of the AISC
manual (Brandt's iteration, the Crawford-Kulak load-deformation curve of one bolt). Any layout, any load direction, any eccentricity.

ShipBrain units in and out: mm, kN, kN.mm (EZbolt itself works in kip and inch: converted here; the ICR curve's 0.34 in
ultimate bolt deformation is the AISC value).
Only the bolt SHEAR limit state is computed - not bearing, tear-out, block shear or plate rupture.
"""
import math, os, sys, io, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'ezbolt', 'repo')
KN_PER_KIP = 4.4482216
IN = 25.4


def _ez():
    if ROOT not in sys.path:
        sys.path.insert(0, ROOT)
    import matplotlib
    matplotlib.use('Agg', force=False)
    import ezbolt
    return ezbolt


def solve(Vx=0.0, Vy=0.0, torsion=0.0, capacity_kn=None, bolts=None, grid=None, d=None, cls=None, shear_planes=1, threads_in_plane=True, ex=0.0, ey=0.0):
    """bolts: [[x, y], ...] mm, or grid: {"width", "height", "nx", "ny", "perimeter_only"} mm (lower left corner at 0, 0).
    ex, ey (mm): the force acts offset from the centroid of the group by ex, ey - adds torsion = Vy ex - Vx ey (the AISC eccentricity).
    Vx, Vy kN and torsion kN.mm act at the centroid of the group (counter-clockwise torsion positive, +x right, +y up).
    capacity_kn: design shear resistance of ONE bolt (kN) - or give d (mm) and cls (e.g. 8.8) and it is taken as the EN 1993-1-8 value
    Fv,Rd = alpha_v fub As / gamma_M2 per shear plane (alpha_v 0.6 for 4.6 5.6 8.8, 0.5 for 10.9, threads in the shear plane)."""
    torsion = float(torsion) + float(Vy) * float(ex) - float(Vx) * float(ey)
    ez = _ez()
    g = ez.BoltGroup()
    if bolts:
        for x, y in bolts:
            g.add_bolt_single(x / IN, y / IN)
    elif grid:
        g.add_bolts(xo=0, yo=0, width=grid['width'] / IN, height=grid['height'] / IN, nx=int(grid['nx']), ny=int(grid['ny']),
                    perimeter_only=bool(grid.get('perimeter_only', False)))
    else:
        raise ValueError('give the bolts as [[x, y], ...] (mm) or as a grid {"width", "height", "nx", "ny"}')
    n = len(g.bolts)
    if n < 2:
        raise ValueError('a bolt group needs at least two bolts')
    note = ''
    if capacity_kn is None:
        if not (d and cls):
            raise ValueError('give capacity_kn (shear resistance of one bolt, kN) or the bolt size d (mm) and class cls such as 8.8')
        capacity_kn, note = bolt_shear_rd(float(d), str(cls), int(shear_planes), threads_in_plane)
    with contextlib.redirect_stdout(io.StringIO()):
        res = g.solve(Vx=Vx / KN_PER_KIP, Vy=Vy / KN_PER_KIP, torsion=torsion / (KN_PER_KIP * IN), bolt_capacity=capacity_kn / KN_PER_KIP, verbose=False)
    out = {'bolts': n, 'capacity_per_bolt_kN': round(capacity_kn, 2), 'capacity_note': note, 'methods': {}}
    names = {'Elastic Method - Superposition': 'elastic', 'Elastic Method - Center of Rotation': 'elastic_centre_of_rotation',
             'Instant Center of Rotation Method': 'icr'}
    for k, key in names.items():
        r = res[k]
        if not isinstance(r, dict):
            out['methods'][key] = {'not_applicable': str(r)}           # no torsion: no rotation centre
            continue
        m = {'DCR': round(float(r['DCR']), 3)}
        if 'Bolt Demand' in r:
            m['max_bolt_force_kN'] = round(float(r['Bolt Demand']) * KN_PER_KIP, 2)
        if 'Connection Capacity' in r:
            m['group_capacity_kN_at_this_eccentricity'] = round(float(r['Connection Capacity']) * KN_PER_KIP, 1)
        if 'Cu' in r:
            m['Cu'] = round(float(r['Cu']), 3)
        if 'ICR' in r:
            m['instant_centre_mm'] = [round(float(v) * IN, 1) for v in r['ICR']]
        if 'Center of Rotation' in r:
            m['centre_of_rotation_mm'] = [round(float(v) * IN, 1) for v in r['Center of Rotation']]
        out['methods'][key] = m
    e, i = out['methods']['elastic'], out['methods']['icr']
    head = (f"Bolt group of {n} bolts, one bolt resists {capacity_kn:.1f} kN in shear. Elastic method: the most loaded bolt carries "
            f"{e['max_bolt_force_kN']:.1f} kN (utilisation {e['DCR']:.2f}). ")
    if 'DCR' in i:
        tail = (f"Instant centre of rotation method (AISC): utilisation {i['DCR']:.2f}, coefficient C = {i['Cu']:.2f} so the group carries "
                f"{i['group_capacity_kN_at_this_eccentricity']:.0f} kN at this eccentricity. "
                + ('The group passes by the ICR method. ' if i['DCR'] <= 1 else 'The group is overloaded by the ICR method. '))
    else:
        tail = ('There is no torsion (the load acts through the centre of the group), so every bolt shares the load equally and the elastic '
                'result is the answer. ' + ('The group passes. ' if e['DCR'] <= 1 else 'The group is overloaded. '))
    out['plain_english'] = head + tail + 'Only bolt shear is checked: bearing, tear-out, block shear and plate rupture are not.' + (' ' + note if note else '')
    return out


def bolt_shear_rd(d, cls, planes=1, threads_in_plane=True):
    """EN 1993-1-8 table 3.4 shear resistance of one bolt (kN): alpha_v f_ub A / 1.25 per shear plane"""
    fub = {'4.6': 400, '4.8': 400, '5.6': 500, '5.8': 500, '6.8': 600, '8.8': 800, '10.9': 1000}.get(cls)
    if fub is None:
        raise ValueError(f'bolt class {cls}: use 4.6 5.6 8.8 10.9')
    pitch = {12: 1.75, 14: 2.0, 16: 2.0, 18: 2.5, 20: 2.5, 22: 2.5, 24: 3.0, 27: 3.0, 30: 3.5, 36: 4.0}.get(int(round(d)), 0.0)
    As = math.pi / 4 * (d - 0.9382 * pitch) ** 2 if pitch else math.pi / 4 * (0.8 * d) ** 2          # tensile stress area (ISO 898-1)
    if threads_in_plane:
        av = 0.5 if cls in ('4.8', '5.8', '6.8', '10.9') else 0.6
        A = As
    else:
        av, A = 0.6, math.pi / 4 * d ** 2
    fv = av * fub * A / 1.25 * planes / 1000
    return fv, f'(Fv,Rd = {av} x {fub} MPa x {A:.0f} mm2 / 1.25 x {planes} plane(s) = {fv:.1f} kN, EN 1993-1-8 table 3.4)'
