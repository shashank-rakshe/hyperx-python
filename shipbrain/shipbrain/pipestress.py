"""
Pipe stress analysis with psi - Pipe Stress Infinity (https://github.com/denisgomes/psi, GPL-3.0, Denis Gomes; copied in
vendor/psi with two numpy-2 compatibility edits and one data typo fixed, all listed in vendor/psi/SOURCE.md).

From plain words to a psi model: the route (legs or waypoints, mm - the same as pipe_route), pipe size (NPS + schedule),
temperature, pressure, water inside or not, supports (anchors, rests, guides) -> psi runs the stiffness solution and the
ASME B31.1 code check for the load cases
    OPE  operating   = weight + pressure + thermal
    SUS  sustained   = weight + pressure          (code check against Sh)
    EXP  expansion   = OPE - SUS                  (code check against the allowable expansion stress range SA)
and ShipBrain converts everything to mm, kN, kNm, MPa, deg C.

What psi has today (its own state, not ShipBrain's): one material (A53 grade A carbon steel), one code (B31.1, 1967
edition), water as the only fluid, straight runs only - a corner is a sharp joint, so bend flexibility and bend stress
intensification are NOT included (a real elbow is more flexible: expansion stresses and anchor loads come out higher,
bend stresses are not raised by the bend SIF). The answer always says this.
"""
import json, math, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'psi', 'repo')
IN = 25.4
LBF = 4.4482216152605e-3            # kN
FTLBF = 1.3558179483314e-3          # kNm
PSI = 6.894757293168e-3             # MPa

SCHEDULES = ['5S', '5', '10S', '10', '20', '30', '40S/STD', '40', '60', '80S/XH', '80', '100', '120', '140', '160', 'DBL/XXH']


def pipe_table():
    import csv
    rows = list(csv.DictReader(open(os.path.join(ROOT, 'psi', 'data', 'pipes.csv'))))
    return {r['nps']: r for r in rows}


def schedule_name(s):
    s = str(s).upper().replace('SCH', '').strip()
    for name in SCHEDULES:
        if s == name or s in name.split('/'):
            return name
    raise ValueError(f'schedule {s!r}: use one of {", ".join(SCHEDULES)}')


def nps_name(nps=None, od_mm=None):
    T = pipe_table()
    if nps is not None:
        key = str(nps).replace('"', '').replace('in', '').strip()
        try:
            v = float(key)
            for k in T:
                if abs(float(k) - v) < 1e-9:
                    return k
        except ValueError:
            pass
        raise ValueError(f'NPS {nps!r} is not in psi\'s pipe table ({", ".join(T)})')
    if od_mm:
        k = min(T, key=lambda k: abs(float(T[k]['od']) * IN - float(od_mm)))
        if abs(float(T[k]['od']) * IN - float(od_mm)) > 0.03 * float(od_mm):
            raise ValueError(f'outside diameter {od_mm} mm is not a standard NPS size (nearest: NPS {k}, {float(T[k]["od"]) * IN:.1f} mm)')
        return k
    raise ValueError('give the pipe size: nps (e.g. 6) or od_mm (e.g. 168.3)')


def _nodes(pts, rest_spacing=None, extra=(), seg=1000.0):
    """split the route into analysis nodes: corners, rest points every rest_spacing (mm) along each leg, the extra support points,
    and mesh points so that no element is longer than seg (mm; psi reports movements and stresses at nodes only).
    Returns the nodes, the leg of each inner node (None for corners / ends) and whether it is a rest point."""
    import numpy as np
    pts = [np.array(p, float) for p in pts]
    nodes, onleg, isrest = [pts[0]], [None], [False]
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        L = float(np.linalg.norm(b - a))
        cuts = {}
        if rest_spacing:
            n = int(L // rest_spacing)
            for k in range(1, n + 1):
                if L - k * rest_spacing > 1e-6:
                    cuts[round(k * rest_spacing, 6)] = True
        for e in extra:
            e = np.array(e, float)
            t = float((e - a) @ (b - a)) / (L * L)
            if 1e-9 < t < 1 - 1e-9 and np.linalg.norm(a + t * (b - a) - e) < 1.0:
                cuts.setdefault(round(t * L, 6), False)
        marks = sorted([0.0] + list(cuts) + [L])
        for x0, x1 in zip(marks, marks[1:]):                    # mesh points between the marks
            m = int(math.ceil((x1 - x0) / seg - 1e-9))
            for k in range(1, m):
                cuts.setdefault(round(x0 + (x1 - x0) * k / m, 6), False)
        for s_ in sorted(cuts):
            nodes.append(a + (b - a) * s_ / L)
            onleg.append(i)
            isrest.append(bool(cuts[s_]))
        nodes.append(b)
        onleg.append(None)
        isrest.append(False)
    return nodes, onleg, isrest


def build_script(pts, nps, sch, t_oper_c, t_amb_c, p_bar, water, supports, out_json, vertical='z'):
    """psi input (Python, psi's own language) for the model; writes the results as JSON"""
    L = ['import json, math', 'from psi.app import App', 'from psi.model import Model', 'from psi.point import Point',
         'from psi.elements import Run', 'from psi.sections import Pipe', 'from psi.material import Material',
         'from psi.codes.b311 import B31167', 'from psi.supports import Anchor, X, Y, Z, Lateral',
         'from psi.loads import Weight, Pressure, Thermal, Fluid', 'from psi.loadcase import LoadCase, LoadComb',
         'app = App()', "mdl = Model('shipbrain')", f"mdl.settings.vertical = '{vertical}'",
         f"Pipe.from_file('pipe1', '{nps}', '{sch}')", "Material.from_file('mat1', 'A53A', 'B31.1')", "code = B31167('code1')"]
    names = [10 * (i + 1) for i in range(len(pts))]
    L.append(f'Point({names[0]}, {pts[0][0] / IN:.6f}, {pts[0][1] / IN:.6f}, {pts[0][2] / IN:.6f})')
    L.append('runs = []')
    for i in range(1, len(pts)):
        d = (pts[i] - pts[i - 1]) / IN
        L.append(f'runs.append(Run({names[i]}, {d[0]:.6f}, {d[1]:.6f}, {d[2]:.6f}))')
    L.append('code.apply(runs)')
    L.append('elem_at = {}')
    L.append('for r in runs:\n    elem_at.setdefault(r.from_point.name, r); elem_at.setdefault(r.to_point.name, r)')
    for k, (node, kind) in enumerate(supports):
        nm = names[node]
        if kind == 'anchor':
            L.append(f"s = Anchor('S{k}', {nm}); s.apply([elem_at[{nm}]])")
        elif kind == 'rest':
            L.append(f"s = {vertical.upper()}('S{k}', {nm}, direction='+'); s.apply([elem_at[{nm}]])")
        elif kind == 'hold':
            L.append(f"s = {vertical.upper()}('S{k}', {nm}); s.apply([elem_at[{nm}]])")
        elif kind == 'guide':
            L.append(f"s = Lateral('S{k}', {nm}); s.apply([elem_at[{nm}]])")
        elif kind in ('x', 'y', 'z'):
            L.append(f"s = {kind.upper()}('S{k}', {nm}); s.apply([elem_at[{nm}]])")
        else:
            raise ValueError(f'support type {kind!r}: anchor, rest, hold, guide, x, y, z')
    L.append("W1 = Weight('W1', 1); W1.apply(runs)")
    if water:
        L.append("FL1 = Fluid.from_file('FL1', 1, 'water'); FL1.apply(runs)")
    t_oper_f, t_amb_f = t_oper_c * 9 / 5 + 32, t_amb_c * 9 / 5 + 32
    L.append(f"P1 = Pressure('P1', 1, {p_bar * 100 / 6.894757293168:.6f}); P1.apply(runs)")
    L.append(f"T1 = Thermal('T1', 1, {t_oper_f:.4f}, {t_amb_f:.4f}); T1.apply(runs)")
    sus = '[Weight, Fluid, Pressure], [1, 1, 1]' if water else '[Weight, Pressure], [1, 1]'
    ope = '[Weight, Fluid, Pressure, Thermal], [1, 1, 1, 1]' if water else '[Weight, Pressure, Thermal], [1, 1, 1]'
    L += [f"L1 = LoadCase('L1', 'ope', {ope})", f"L2 = LoadCase('L2', 'sus', {sus})",
          "L3 = LoadComb('L3', 'exp', 'algebraic', [L1, L2], [1, -1])", 'mdl.analyze()']
    L.append(f'''
out = {{'nodes': {names}, 'supports': {[[names[n], k] for n, k in supports]}, 'cases': {{}}}}
f = lambda v: float(v[0]) if hasattr(v, '__len__') else float(v)
for lc in (L1, L2, L3):
    rows = {{}}
    for nm in {names}:
        pt = app.points(nm)
        mv = [f(x) for x in lc.movements[pt]]
        st = lc.stresses[pt]
        rows[nm] = {{'mov': mv, 'sl': f(st.sl), 'sallow': f(st.sallow), 'sratio': f(st.sratio), 'shoop': f(st.shoop)}}
        if nm in [s[0] for s in out['supports']]:
            rows[nm]['reac'] = [f(x) for x in lc.reactions[pt]]
    out['cases'][lc.stype] = rows
json.dump(out, open({out_json!r}, 'w'))
''')
    return '\n'.join(L) + '\n'


def analyse(legs=None, waypoints=None, nps=None, od_mm=None, schedule='40', t_oper_c=20.0, t_amb_c=21.1, pressure_bar=0.0,
            water=True, supports=None, rest_spacing_m=None, start=(0, 0, 0), workdir='.', name='pipe_stress', timeout=600):
    """supports: [{'at': waypoint index (0 = start, -1 = end) or [x, y, z] mm on the route, 'type': anchor | rest | hold | guide | x | y | z}];
    default: anchors at both ends. rest_spacing_m: rests (one-way vertical supports) every so many metres along every leg."""
    import numpy as np
    from .piperoute import waypoints_from_legs
    pts = np.array(waypoints, float) if waypoints else (waypoints_from_legs(legs, start) if legs else None)
    if pts is None or len(pts) < 2:
        raise ValueError('give the route as legs [{"dir": "east", "length": 3000}, ...] or waypoints [[x, y, z], ...] in mm')
    npsn = nps_name(nps, od_mm)
    sch = schedule_name(schedule)
    row = pipe_table()[npsn]
    if not row.get(sch):
        raise ValueError(f'NPS {npsn} has no schedule {sch} in psi\'s table')
    supports = supports or [{'at': 0, 'type': 'anchor'}, {'at': -1, 'type': 'anchor'}]
    extra = [s['at'] for s in supports if isinstance(s.get('at'), (list, tuple))]
    nodes, onleg, isrest = _nodes(pts, rest_spacing_m * 1000 if rest_spacing_m else None, extra)
    sup = []
    for s in supports:
        at = s.get('at', 0)
        if isinstance(at, (list, tuple)):
            j = int(np.argmin([np.linalg.norm(n - np.array(at, float)) for n in nodes]))
        else:
            target = pts[int(at)]
            j = int(np.argmin([np.linalg.norm(n - target) for n in nodes]))
        sup.append((j, str(s.get('type', 'anchor')).lower()))
    if rest_spacing_m:                                        # rests inside horizontal legs only (a vertical rest on a riser makes no sense)
        taken = {j for j, _ in sup}
        for j, leg in enumerate(onleg):
            if j in taken or leg is None or not isrest[j]:
                continue
            dz = abs(float(pts[leg + 1][2] - pts[leg][2]))
            if dz < 1e-6:
                sup.append((j, 'rest'))
    if not any(k == 'anchor' for _, k in sup):
        raise ValueError('the model needs at least one anchor (otherwise it can move as a whole)')
    os.makedirs(workdir, exist_ok=True)
    name = re.sub(r'[^A-Za-z0-9_\-]', '_', name)
    inp = os.path.join(workdir, name + '_psi.py')
    out = os.path.join(workdir, name + '_psi.json')
    open(inp, 'w').write(build_script(nodes, npsn, sch, float(t_oper_c), float(t_amb_c), float(pressure_bar), bool(water), sup, out))
    env = dict(os.environ, PYTHONPATH=ROOT + os.pathsep + os.environ.get('PYTHONPATH', ''))
    r = subprocess.run([sys.executable, inp], capture_output=True, text=True, timeout=timeout, cwd=workdir, env=env)
    if r.returncode or not os.path.exists(out):
        msg = [l for l in (r.stderr or r.stdout).splitlines() if l.strip() and 'it/s' not in l][-4:]
        if 'pint' in (r.stderr or '') and 'No module' in (r.stderr or ''):
            raise RuntimeError("No module named 'pint' - psi (pipe stress) needs it: pip install pint tqdm jinja2")
        raise RuntimeError('psi failed: ' + ' | '.join(msg))
    data = json.load(open(out))
    return _summary(data, nodes, pts, npsn, sch, row, t_oper_c, t_amb_c, pressure_bar, water, sup, os.path.basename(inp))


def _summary(data, nodes, pts, npsn, sch, row, t_oper_c, t_amb_c, p_bar, water, sup, inp_name):
    names = data['nodes']
    od = float(row['od']) * IN
    t = float(row[sch]) * IN
    res = {'pipe': {'nps': npsn, 'schedule': sch, 'od_mm': round(od, 1), 'wall_mm': round(t, 2), 'material': 'A53 grade A', 'code': 'ASME B31.1 (1967)'},
           'nodes': [{'node': nm, 'xyz_mm': [round(float(v), 1) for v in p]} for nm, p in zip(names, nodes)],
           'conditions': {'t_oper_c': t_oper_c, 't_amb_c': t_amb_c, 'pressure_bar': p_bar, 'water_filled': bool(water)},
           'cases': {}, 'input': inp_name}
    for case, rows in data['cases'].items():
        mov = {int(k): v['mov'] for k, v in rows.items()}
        mx = max(mov, key=lambda k: math.sqrt(sum(x * x for x in mov[k][:3])))
        c = {'max_displacement_mm': round(math.sqrt(sum(x * x for x in mov[mx][:3])) * IN, 2), 'at_node': mx,
             'displacement_mm': {k: [round(x * IN, 2) for x in mov[k][:3]] for k in mov}}
        reac = {}
        for nm, kind in data['supports']:
            rr = rows[str(nm)].get('reac')
            if rr:
                reac[f'{nm} ({kind})'] = {'F_kN': [round(x * LBF, 3) for x in rr[:3]], 'M_kNm': [round(x * FTLBF, 3) for x in rr[3:]]}
        c['support_loads'] = reac
        if case in ('sus', 'exp'):
            worst = max(rows, key=lambda k: rows[k]['sratio'])
            w = rows[worst]
            c['code_stress'] = {'max_ratio': round(w['sratio'], 3), 'at_node': int(worst), 'stress_MPa': round(w['sl'] * PSI, 1),
                                'allowable_MPa': round(w['sallow'] * PSI, 1), 'passes': w['sratio'] <= 1.0}
        res['cases'][case] = c
    sus, exp, ope = res['cases'].get('sus', {}), res['cases'].get('exp', {}), res['cases'].get('ope', {})
    ok = all(res['cases'][k]['code_stress']['passes'] for k in ('sus', 'exp') if 'code_stress' in res['cases'].get(k, {}))
    an = [k for k in ope.get('support_loads', {}) if 'anchor' in k]
    biggest = max(an, key=lambda k: math.sqrt(sum(x * x for x in ope['support_loads'][k]['F_kN'])), default=None)
    s = (f"Pipe stress (psi, ASME B31.1-1967): NPS {npsn} sch {sch} ({od:.1f} x {t:.2f} mm, A53 grade A), {len(pts) - 1} legs, "
         f"{t_oper_c:g} deg C / {p_bar:g} bar, {'water filled' if water else 'empty'}, {len(sup)} supports. ")
    if 'code_stress' in sus:
        s += (f"Sustained stress {sus['code_stress']['stress_MPa']} MPa of {sus['code_stress']['allowable_MPa']} allowed "
              f"(ratio {sus['code_stress']['max_ratio']:.2f}, node {sus['code_stress']['at_node']}). ")
    if 'code_stress' in exp:
        s += (f"Expansion stress {exp['code_stress']['stress_MPa']} MPa of {exp['code_stress']['allowable_MPa']} allowed "
              f"(ratio {exp['code_stress']['max_ratio']:.2f}, node {exp['code_stress']['at_node']}). ")
    if ok:
        s += 'The code check PASSES. '
    else:
        why = []
        if not sus.get('code_stress', {}).get('passes', True):
            why.append('the sustained stress is too high: add supports (shorter spans between rests)')
        if not exp.get('code_stress', {}).get('passes', True):
            why.append('the expansion stress is too high: add flexibility (a longer offset leg or an expansion loop), or move an anchor')
        s += 'The code check FAILS - ' + '; '.join(why) + '. '
    s += f"Largest operating movement {ope.get('max_displacement_mm', 0)} mm at node {ope.get('at_node')}. "
    if biggest:
        F = ope['support_loads'][biggest]['F_kN']
        s += f"Largest anchor force (operating) at {biggest}: {math.sqrt(sum(x * x for x in F)):.2f} kN. "
    s += ("Limits of psi today: corners are sharp joints (no bend flexibility, no bend stress factor), one material (A53 grade A), "
          "B31.1-1967 only: treat bend regions with care and confirm a final design with a full pipe stress program.")
    res['passes'] = ok
    res['plain_english'] = s
    return res
