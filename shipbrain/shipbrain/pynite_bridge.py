"""
Frame, truss and plate finite-element analysis with PyNite (https://github.com/JWock82/Pynite, MIT, D. Craig Brinck; `pip install PyNiteFEA`): 3D beams with releases, member and nodal
loads, load combinations, rectangular plate meshes with pressure. ShipBrain takes a plain-data description of the model (units are yours: keep them consistent, for example N, mm, MPa), builds
the PyNite model, solves it and reads the results back as numbers (displacements, reactions, member forces, plate deflection and moments).

    analyse({'materials': {'steel': {'E': 206000, 'nu': 0.3}}, 'sections': {'s': {'A': .., 'Iy': .., 'Iz': .., 'J': ..}},
             'nodes': {'A': [0, 0, 0], 'B': [3000, 0, 0]}, 'members': [{'name': 'M1', 'i': 'A', 'j': 'B', 'material': 'steel', 'section': 's'}],
             'supports': {'A': 'fixed'}, 'node_loads': [{'node': 'B', 'dir': 'FY', 'value': -1000}]})
"""
import math

SUPPORTS = {'fixed': (1, 1, 1, 1, 1, 1), 'pinned': (1, 1, 1, 0, 0, 0), 'roller_y': (0, 1, 0, 0, 0, 0), 'roller_x': (1, 0, 0, 0, 0, 0), 'roller_z': (0, 0, 1, 0, 0, 0),
            'pinned_planar': (1, 1, 1, 0, 0, 0)}


def available():
    try:
        import Pynite  # noqa: F401
        return True
    except ImportError:
        return False


def analyse(spec):
    try:
        from Pynite import FEModel3D
    except ImportError:
        raise RuntimeError('PyNite is not installed: pip install PyNiteFEA (free), then ask again')
    m = FEModel3D()
    for name, v in spec.get('materials', {}).items():
        E = float(v['E'])
        nu = float(v.get('nu', 0.3))
        m.add_material(name, E, float(v.get('G', E / (2 * (1 + nu)))), nu, float(v.get('rho', 0.0)), v.get('fy'))
    for name, v in spec.get('sections', {}).items():
        m.add_section(name, float(v['A']), float(v['Iy']), float(v['Iz']), float(v['J']))
    for name, xyz in spec.get('nodes', {}).items():
        m.add_node(name, *[float(c) for c in xyz])
    for mem in spec.get('members', []):
        m.add_member(mem['name'], mem['i'], mem['j'], mem['material'], mem['section'], float(mem.get('rotation', 0.0)), bool(mem.get('tension_only', False)), bool(mem.get('comp_only', False)))
        if mem.get('releases'):
            m.def_releases(mem['name'], *[bool(x) for x in mem['releases']])
    for node, s in spec.get('supports', {}).items():
        flags = SUPPORTS[s] if isinstance(s, str) else tuple(s)
        m.def_support(node, *[bool(f) for f in flags])
    cases = set()
    for ld in spec.get('node_loads', []):
        c = ld.get('case', 'Case 1')
        cases.add(c)
        m.add_node_load(ld['node'], ld['dir'], float(ld['value']), c)
    for ld in spec.get('member_loads', []):
        c = ld.get('case', 'Case 1')
        cases.add(c)
        m.add_member_dist_load(ld['member'], ld['dir'], float(ld['w1']), float(ld.get('w2', ld['w1'])), ld.get('x1'), ld.get('x2'), c)
    plates = []
    for pl in spec.get('plates', []):
        name = pl['name']
        m.add_rectangle_mesh(name, float(pl['mesh']), float(pl['width']), float(pl['height']), float(pl['t']), pl['material'], origin=tuple(pl.get('origin', (0, 0, 0))), plane=pl.get('plane', 'XY'))
        m.meshes[name].generate()                                              # the mesh exists only after this: nodes and elements are needed for loads and supports
        c = pl.get('case', 'Case 1')
        cases.add(c)
        if pl.get('pressure'):
            for q in m.meshes[name].elements.values():
                m.add_quad_surface_pressure(q.name, float(pl['pressure']), c)
        plates.append(name)
        _edges(m, name, pl)
    combos = spec.get('combos') or {'Combo 1': {c: 1.0 for c in (cases or {'Case 1'})}}
    for cn, fac in combos.items():
        m.add_load_combo(cn, fac)
    m.analyze(check_statics=False)
    combo = next(iter(combos))
    out = {'combo': combo, 'nodes': {}, 'reactions': {}, 'members': {}, 'plates': {}}
    for n, nd in m.nodes.items():
        out['nodes'][n] = {k: float(getattr(nd, k)[combo]) for k in ('DX', 'DY', 'DZ', 'RX', 'RY', 'RZ')}
    for n in spec.get('supports', {}):
        nd = m.nodes[n]
        out['reactions'][n] = {k: float(getattr(nd, 'Rxn' + k)[combo]) for k in ('FX', 'FY', 'FZ', 'MX', 'MY', 'MZ')}
    for name, mem in m.members.items():
        out['members'][name] = {'max_M_y': float(mem.max_moment('My', combo)), 'min_M_y': float(mem.min_moment('My', combo)), 'max_M_z': float(mem.max_moment('Mz', combo)),
                                'min_M_z': float(mem.min_moment('Mz', combo)), 'max_V_y': float(mem.max_shear('Fy', combo)), 'min_V_y': float(mem.min_shear('Fy', combo)),
                                'max_axial': float(mem.max_axial(combo)), 'min_axial': float(mem.min_axial(combo)), 'max_deflection_y': float(mem.max_deflection('dy', combo)),
                                'min_deflection_y': float(mem.min_deflection('dy', combo)), 'length': float(mem.L())}
    for name in plates:
        mesh = m.meshes[name]
        dz = [abs(float(nd.DZ[combo])) for nd in mesh.nodes.values()]
        out['plates'][name] = {'max_deflection': max(dz), 'elements': len(mesh.elements), 'nodes': len(mesh.nodes)}
    out['max_displacement'] = max(max(abs(v) for k, v in d.items() if k in ('DX', 'DY', 'DZ')) for d in out['nodes'].values()) if out['nodes'] else 0.0
    out['model'] = m
    return out


def _edges(m, name, pl):
    """edge supports of a rectangular plate mesh: 'simple' (out-of-plane displacement fixed) or 'clamped' (and the rotations) on 'left' 'right' 'bottom' 'top', plus the in-plane
    constraints that stop rigid-body motion (both in-plane displacements at one corner, one at the next)"""
    mesh = m.meshes[name]
    kinds = pl.get('edges', {})
    if not kinds:
        return
    plane = pl.get('plane', 'XY')
    u, v, w = {'XY': (0, 1, 2), 'YZ': (1, 2, 0), 'XZ': (0, 2, 1)}[plane]
    ov = [float(c) for c in pl.get('origin', (0, 0, 0))]
    W, Hh = float(pl['width']), float(pl['height'])
    tol = float(pl['mesh']) * 1e-3
    pts = {n: (nd.X, nd.Y, nd.Z) for n, nd in mesh.nodes.items()}

    def kind_of(p):
        sides = []
        if abs(p[u] - ov[u]) < tol:
            sides.append('left')
        if abs(p[u] - (ov[u] + W)) < tol:
            sides.append('right')
        if abs(p[v] - ov[v]) < tol:
            sides.append('bottom')
        if abs(p[v] - (ov[v] + Hh)) < tol:
            sides.append('top')
        ks = [kinds[s] for s in sides if s in kinds]
        return ('clamped' if 'clamped' in ks else 'simple') if ks else None
    flags = {}
    for n, p in pts.items():
        k = kind_of(p)
        if k:
            f = [False] * 6
            f[w] = True
            if k == 'clamped':
                f[3 + u] = f[3 + v] = True
            flags[n] = f
    c0 = min(pts, key=lambda n: (pts[n][u] - ov[u]) ** 2 + (pts[n][v] - ov[v]) ** 2)
    c1 = min(pts, key=lambda n: (pts[n][u] - ov[u] - W) ** 2 + (pts[n][v] - ov[v]) ** 2)
    flags.setdefault(c0, [False] * 6)[u] = True
    flags[c0][v] = True
    flags.setdefault(c1, [False] * 6)[v] = True
    for n, f in flags.items():
        m.def_support(n, *f)
