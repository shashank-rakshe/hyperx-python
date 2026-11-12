"""
Component-based finite element method (CBFEM) for steel connections - own implementation of the published method (Wald, Sokol et al.:
plates as elastic-plastic shells, bolts as non-linear springs, contact between plates, plastic strain limit 5 % - EN 1993-1-5 annex C),
on ShipBrain's own shell mesher and CalculiX. NOT IDEA StatiCa's solver and not its code: it is built from the method as published and
from the EN 1993-1-8 bolt rules.

Model (units mm, N, MPa):
  plates     mid-surface shells (S4 / S3), elastic - perfectly plastic steel (fy, E, tiny hardening E/10000), bolt holes in every plate
  welds      plates that meet along a line share nodes (welded) - no weld failure check here
  bolts      each hole: its rim nodes form a rigid spider on a reference node; the two reference nodes (or one and the ground) are joined by
             three non-linear springs: axial (tension stiffness 1.6 E As / Lb, capacity Ft,Rd = 0.9 fub As / 1.25, compression stiff) and two shear
             springs (stiffness 16 d^2 fub / 16 mm, capacity Fv,Rd per EN 1993-1-8 3.6.1)
  contact    compression-only springs between facing plates (and plate to ground), no friction
  load       proportional ramp of the given forces / moments up to lf_max times; the capacity is the load factor at which the first limit is hit:
             plastic strain 5 %, a bolt at its tension, shear or interaction capacity (T/(1.4 Ft) + V/Fv = 1); the model failing to converge beyond
             a load factor is reported as collapse at that factor.
Results: load factor of capacity, governing limit, at the design load (factor 1): peak plastic strain, bolt tensions and shears with utilisation.
Checked against the EN 1993-1-8 T-stub resistance (see tests). Not covered: weld strength, buckling (use large deformation / eigen buckling separately),
slip-critical bolts and preload, friction, bearing failure of bolt holes, section root fillets.
"""
import math, os, re, subprocess
import numpy as np

EPS_LIM = 0.05


def bolt_props(d, cls, grip, planes=1):
    """EN 1993-1-8: tension and shear capacity (N) and spring stiffnesses (N/mm) of one bolt"""
    from .bolts import thread
    from .bolt_group import bolt_shear_rd
    fub = {'4.6': 400, '5.6': 500, '8.8': 800, '10.9': 1000}[cls]
    As = float(thread(float(d))['As'])
    Ft = 0.9 * fub * As / 1.25
    Fv = bolt_shear_rd(float(d), cls, planes)[0] * 1000.0
    return {'Ft': Ft, 'Fv': Fv, 'kt': 210000.0 * 1.6 * As / max(grip, 1.0), 'kv': 16.0 * d * d * fub / 16.0, 'As': As}


def _name(s):
    return re.sub(r'[^A-Za-z0-9_]', '_', str(s))[:24]


def _rim(X, ids, pt, axis, d0):
    V = X[ids - 1] - np.array(pt)
    V = V - np.outer(V @ axis, axis)
    r = np.linalg.norm(V, axis=1)
    return ids[np.where(abs(r - d0 / 2) < max(1.0, 0.08 * d0))[0]]


def prepare(spec, out_dir, name='cbfem'):
    """mesh once: nodes, shell elements, bolt spiders and springs, contact node pairs, load rigid bodies"""
    from .platemesh import build_plates
    h = float(spec['size'])
    plates = [dict(p, holes=[list(x) for x in p.get('holes', [])]) for p in spec['plates']]
    byid = {p['id']: p for p in plates}
    bolts = spec.get('bolts', [])
    for b in bolts:                                           # hole in every plate a bolt passes through
        for pt, pid in ((b['a'], b['plate_a']), (b.get('b'), b.get('plate_b'))):
            p = byid.get(pid)
            if not p:
                continue
            o = np.array(p['outline'], float)
            u = (o[1] - o[0]) / np.linalg.norm(o[1] - o[0])
            v = (o[3] - o[0]) / np.linalg.norm(o[3] - o[0])
            c = np.array(pt, float)
            n = 16
            p['holes'].append([(c + u * (b['d0'] / 2) * math.cos(2 * math.pi * k / n) + v * (b['d0'] / 2) * math.sin(2 * math.pi * k / n)).round(4).tolist()
                               for k in range(n)])
    m, info = build_plates({'name': name, 'element_size': h, 'plates': plates, 'fix': [], 'loads': [], 'close_gap': False}, out_dir, formats=())
    X = np.array(m.xyz, float)
    P = {'X': X, 'nN': len(X), 'h': h, 'extra': [], 'elems': m.elems, 'byid': byid, 'spec': spec, 'mesh_info': info}
    groups = {}
    for e in m.elems:
        groups.setdefault(e['group'], set()).update(e['nodes'])
    P['groups'] = groups

    def new_node(p):
        P['extra'].append(tuple(float(v) for v in p))
        return P['nN'] + len(P['extra'])
    P['ground'] = new_node((0, 0, 0))
    rigid, bolt_rec = [], []
    for b in bolts:
        axis = np.array(b['axis'], float)
        axis /= np.linalg.norm(axis)
        k_ax = int(np.argmax(abs(axis)))
        ends = []
        for pt, pid in ((b['a'], b['plate_a']), (b.get('b'), b.get('plate_b'))):
            if pid is None or pid not in groups:
                ends.append(P['ground'])
                continue
            ids = np.array(sorted(groups[pid]))
            rim = _rim(X, ids, pt, axis, b['d0'])
            if len(rim) < 4:
                raise ValueError(f'bolt {b["name"]}: hole rim not found on plate {pid} (mesh size {h:g} mm too coarse for a {b["d0"]:g} mm hole?)')
            ref, rot = new_node(pt), new_node(pt)
            rigid.append((rim, ref, rot))
            ends.append(ref)
        pr = b.get('props') or bolt_props(b['d'], b['cls'], b.get('grip', 2 * b['d']))
        ts = [byid[pid]['t'] for pid in (b['plate_a'], b.get('plate_b')) if pid in byid]
        fu_p = float(spec.get('material', {}).get('fu') or 490.0)
        # EN 1993-1-8 table 3.4 bearing: k1 alpha_b fu d t / 1.25 with k1 = 2.5 and alpha_b = 0.5 (edge distance 1.5 d0: conservative simplification)
        Fb = 2.5 * 0.5 * fu_p * b['d'] * min(ts) / 1.25 if ts else 1e12
        bolt_rec.append({'name': b['name'], 'a': ends[0], 'b': ends[1], 'k_ax': k_ax, 'sgn': 1.0 if axis[k_ax] > 0 else -1.0,
                         'tang': [i for i in range(3) if i != k_ax], 'Ft': pr['Ft'], 'Fv': pr['Fv'], 'kt': pr['kt'], 'kv': pr['kv'], 'Fb': Fb})
    # contact: node pairs facing each other along the axis (mid-surfaces are at their true distance, so zero relative displacement = touching)
    pairs = []                                                 # (nodeA, nodeB, axis index, sign: +1 when B is on the + side of A, stiffness)
    E = float(spec.get('material', {}).get('E', 210000.0))
    for c in spec.get('contacts', []):
        axk = int(c['axis'])
        if c['a'] not in groups or c['b'] not in groups:
            continue
        A, Bn = np.array(sorted(groups[c['a']])), np.array(sorted(groups[c['b']]))
        t = (byid[c['a']]['t'] + byid[c['b']]['t']) / 2
        k = E * h * h / max(t, 1.0)
        oth = [i for i in range(3) if i != axk]
        for n in A:
            d = np.linalg.norm((X[Bn - 1] - X[n - 1])[:, oth], axis=1)
            j = int(np.argmin(d))
            if d[j] <= 0.8 * h:
                nb = int(Bn[j])
                pairs.append((int(n), nb, axk, 1.0 if X[nb - 1][axk] > X[n - 1][axk] else -1.0, k))
    P['pairs'] = pairs
    P['rigid'], P['bolts'] = rigid, bolt_rec
    # loads: distributed over the nodes of a section (no rigid body: CalculiX does not converge with plastic shells on a rigid body);
    # force: equally; bending moment: forces along the section normal proportional to the distance from the neutral axis (exact couple)
    loads = []
    for ld in spec.get('loads', []):
        ax, val = ld['select']
        kk = {'x': 0, 'y': 1, 'z': 2}[ax]
        sel = np.where(abs(X[:, kk] - float(val)) < 1e-3 * max(h, 1))[0]
        if len(sel) == 0:
            raise ValueError(f'load: no nodes at {ax} = {val}')
        F = np.array(ld.get('force', [0, 0, 0]), float) * 1000.0
        M = np.array(ld.get('moment', [0, 0, 0]), float) * 1e6
        nvec = np.zeros(3)
        nvec[kk] = 1.0
        if abs(M[kk]) > 1e-9:
            raise ValueError('a torque about the member axis is not supported (use shear and bending moments)')
        # shear goes to the web nodes of the section (the flanges would be bent by a load across them); axial force to all nodes
        webn = {int(n) - 1 for g, ns in groups.items() if 'web' in g.lower() for n in ns}
        wsel = [j for j, n in enumerate(sel) if int(n) in webn]
        Fn = np.array([F[kk], 0.0, 0.0]) * 0 + 0.0
        f = np.zeros((len(sel), 3))
        f[:, kk] += F[kk] / len(sel)                              # axial component (along the member): all nodes
        shear = F.copy()
        shear[kk] = 0.0
        tgt = wsel if wsel else list(range(len(sel)))
        for j in tgt:
            f[j] += shear / len(tgt)
        if np.linalg.norm(M) > 0:
            c = X[sel].mean(0)
            D = np.cross(X[sel] - c, nvec)                      # in-plane lever vectors (r x n)
            S = D.T @ D
            lam = np.linalg.pinv(S) @ M
            f += np.outer(D @ lam, nvec)
        for j, n in enumerate(sel):
            for i in range(3):
                if abs(f[j, i]) > 1e-12:
                    loads.append((int(n) + 1, i + 1, float(f[j, i])))
    P['loads'] = loads
    # supports
    sup = set()
    for f in spec.get('fix', []):
        sel = np.ones(P['nN'], bool)
        for axn, kk in (('x', 0), ('y', 1), ('z', 2)):
            if axn in f:
                sel &= abs(X[:, kk] - float(f[axn])) < 1e-3 * max(h, 1)
        for i in np.where(sel)[0]:
            for dd in f.get('dof', '123456'):
                sup.add((int(i) + 1, int(dd)))
    P['sup_fix'] = sorted(sup)                                  # real supports (the ground plate below a plate is not a point support)
    for gid in spec.get('fix_plates', []):
        for n in groups.get(gid, ()):
            for dd in '123456':
                sup.add((int(n), int(dd)))
    P['sup'] = sorted(sup)
    # load introduction and supports: elastic zone (the point loads there would only produce meaningless local plastic strain)
    zone = np.zeros(P['nN'], bool)
    for ld in spec.get('loads', []):
        ax_, val_ = ld['select']
        zone |= abs(X[:, {'x': 0, 'y': 1, 'z': 2}[ax_]] - float(val_)) < 2.5 * h
    fixed = np.array([n - 1 for n, _ in P['sup_fix'] if n - 1 < P['nN']], int)
    if len(fixed):
        ps = X[np.unique(fixed)]
        for j in range(P['nN']):
            if np.min(np.linalg.norm(ps - X[j], axis=1)) < 2.5 * h:
                zone[j] = True
    P['zone'] = zone
    return P


def write_input(P, lf, active, path, name='cbfem', incs=None, elastic=False):
    """CalculiX input: plastic shells, bolt spiders and springs, the contact springs in `active`, loads ramped to lf times the given loads"""
    spec = P['spec']
    mat = spec.get('material', {})
    E, nu, fy = float(mat.get('E', 210000.0)), float(mat.get('nu', 0.3)), float(mat.get('fy', 355.0))
    mat = dict(mat, fu=mat.get('fu', 0))
    L = ['*HEADING', name, '*NODE']
    allx = list(map(tuple, P['X'])) + P['extra']
    L += [f'{i}, {x:.5f}, {y:.5f}, {z:.5f}' for i, (x, y, z) in enumerate(allx, 1)]
    elset = {}
    zone = P['zone']
    for e in P['elems']:
        el_ = bool(any(zone[n - 1] for n in e['nodes']))
        elset.setdefault((e['group'], 'S4' if e['type'] == 'quad' else 'S3', el_), []).append(e)
    ELN, eid = [], 0
    for (gid, typ, el_), es in elset.items():
        nm = f'{_name(gid)}_{typ}' + ('_E' if el_ else '')
        ELN.append((nm, P['byid'][gid]['t'], el_))
        L.append(f'*ELEMENT, TYPE={typ}, ELSET={nm}')
        for e in es:
            eid += 1
            e['_id'] = eid
            L.append(f'{eid}, ' + ', '.join(map(str, e['nodes'])))
    for k, (rim, ref, rot) in enumerate(P['rigid']):          # RBE3-like: the reference node moves with the average of the hole rim (the hole stays flexible)
        n = len(rim)
        for dof in (1, 2, 3):
            L += ['*EQUATION', f'{n + 1}']
            terms = [(ref, dof, 1.0)] + [(int(r_), dof, -1.0 / n) for r_ in rim]
            for j in range(0, len(terms), 4):
                L.append(', '.join(f'{a_}, {b_}, {c_:.8g}' for a_, b_, c_ in terms[j:j + 4]))
    for rec in P['bolts']:
        nm = _name(rec['name'])
        specs = [('T', rec['k_ax'], [('0., 0.', None), (f"{rec['Ft']:.4f}, {rec['Ft'] / rec['kt']:.6f}", None),
                                       (f"{rec['Ft'] * 1.0001:.4f}, {rec['Ft'] / rec['kt'] + 5:.6f}", None)])]
        for tk in rec['tang']:
            specs.append(('XYZ'[tk], tk, [('0., 0.', None), (f"{rec['Fv']:.4f}, {rec['Fv'] / rec['kv']:.6f}", None),
                                           (f"{rec['Fv'] * 1.0001:.4f}, {rec['Fv'] / rec['kv'] + 5:.6f}", None)]))
        for lab, dof, rows in specs:                           # CalculiX mirrors the curve for negative values
            eid += 1
            L += [f'*ELEMENT, TYPE=SPRING2, ELSET=B{lab}_{nm}', f"{eid}, {rec['a']}, {rec['b']}"]
            if not spec.get('nonlinear_bolts'):                # linear springs converge fast; the first bolt limit ends the analysis anyway
                L += [f'*SPRING, ELSET=B{lab}_{nm}', f'{dof + 1}, {dof + 1}', f"{float(rec['kt'] if lab == 'T' else rec['kv']):.6e}"]
            else:
                L += [f'*SPRING, ELSET=B{lab}_{nm}, NONLINEAR', f'{dof + 1}, {dof + 1}'] + [r_[0] for r_ in rows]
    # contact springs (linear, both ways: the active set makes them compression-only)
    cnodes = set()
    by_k = {}
    for i in sorted(active):
        n1, n2, axk, sg, k = P['pairs'][i]
        by_k.setdefault((axk, round(k, 3)), []).append((n1, n2))
        cnodes.update((n1, n2))
    for gi, ((axk, k), prs) in enumerate(sorted(by_k.items())):
        L.append(f'*ELEMENT, TYPE=SPRING2, ELSET=CONT{gi}')
        for n1, n2 in prs:
            eid += 1
            L.append(f'{eid}, {n1}, {n2}')
        L += [f'*SPRING, ELSET=CONT{gi}', f'{axk + 1}, {axk + 1}', f'{float(k):.6e}']
    # very soft springs to ground keep the matrix regular while contact opens
    stab = sorted({n for pr in P['pairs'] for n in pr[:2]})
    if stab and elastic and spec.get('stabilise', True):
        for dof in (1, 2, 3):
            L.append(f'*ELEMENT, TYPE=SPRING2, ELSET=STAB{dof}')
            for n in stab:
                eid += 1
                L.append(f'{eid}, {n}, {P["ground"]}')
            L += [f'*SPRING, ELSET=STAB{dof}', f'{dof}, {dof}', f'{float(spec.get("stab_k", 0.01)):.6e}']
    L.append('*MATERIAL, NAME=STEEL')
    ycal = float(spec.get('yield_correction', 0.866))
    fy, fu_in = fy * ycal, float(mat.get('fu', 0))
    fu = fu_in * ycal if fu_in else 0.0
    if elastic:                                               # cheap linear solve to find the contact set
        L += ['*ELASTIC', f'{E:g}, {nu:g}']
        incs = 1
    elif fu > fy:                                               # EN 1993-1-5 annex C.6: strain hardening to fu at 15 % plastic strain
        L += ['*ELASTIC', f'{E:g}, {nu:g}', '*PLASTIC', f'{fy:g}, 0.', f'{fu:.4f}, 0.15', f'{fu + 1:.4f}, 1.0']
    else:                                                     # ideal elastic - plastic (tiny hardening so the solver can follow the plateau)
        L += ['*ELASTIC', f'{E:g}, {nu:g}', '*PLASTIC', f'{fy:g}, 0.', f'{fy + E / 10000 * 0.05:.4f}, 0.05', f'{fy + E / 10000 * 1.0:.4f}, 1.0']
    L += ['*MATERIAL, NAME=STEELE', '*ELASTIC', f'{E:g}, {nu:g}']
    for nm, t, el_ in ELN:
        L += [f'*SHELL SECTION, ELSET={nm}, MATERIAL={"STEELE" if el_ else "STEEL"}', f'{t:g}']
    rimset = {int(n) for rim, _, _ in P['rigid'] for n in rim}
    ev = [e['_id'] for e in P['elems'] if not rimset.intersection(e['nodes']) and not any(zone[n - 1] for n in e['nodes'])]
    L.append('*ELSET, ELSET=EVAL')                               # plastic strain is read away from the bolt holes (bearing is checked per bolt)
    L += [', '.join(map(str, ev[j:j + 16])) for j in range(0, len(ev), 16)] or ['1']
    L.append('*ELSET, ELSET=SHELLS')
    L += [', '.join(sorted({nm for nm, _, _ in ELN})[j:j + 6]) for j in range(0, len(ELN), 6)]
    refs = sorted({n for r_ in P['bolts'] for n in (r_['a'], r_['b']) if n != P['ground']} | {n for pr in P['pairs'] for n in pr[:2]})
    L.append('*NSET, NSET=REFS')
    L += [', '.join(map(str, refs[j:j + 16])) for j in range(0, len(refs), 16)] or [str(P['ground'])]
    L.append('*BOUNDARY')
    L.append(f"{P['ground']}, 1, 6")
    L += [f'{n}, {d}, {d}' for n, d in P['sup']]
    inc = 1.0 / max(1, incs or int(math.ceil(lf / 0.1)))
    if elastic:
        inc = 1.0
    L += [f'*STEP, NLGEOM=NO, INC={int(spec.get("max_inc", 200))}', '*CONTROLS, PARAMETERS=FIELD', '0.02, 0.05', '*STATIC', f'{inc:g}, 1., {inc / 64:g}, {inc:g}', '*CLOAD']
    for n, dof, v in P['loads']:
        L.append(f'{n}, {dof}, {v * lf:.5f}')
    L += ['*NODE PRINT, NSET=REFS', 'U', '*EL PRINT, ELSET=EVAL', 'PEEQ', '*END STEP']
    open(path, 'w').write('\n'.join(L) + '\n')
    return path


def _read_dat(path):
    """time -> {'u': {node: (ux, uy, uz)}, 'peeq': max}"""
    T = {}
    mode, t = None, None
    for ln in open(path, errors='replace'):
        mm = re.search(r'for set (\S+) and time\s+([-+0-9.Ee]+)', ln)
        if mm:
            t = float(mm.group(2))
            T.setdefault(t, {'u': {}, 'peeq': 0.0})
            mode = 'u' if 'displacements' in ln else ('p' if 'plastic' in ln.lower() else None)
            continue
        w = ln.split()
        if not w or mode is None:
            continue
        try:
            if mode == 'u' and len(w) == 4:
                T[t]['u'][int(w[0])] = (float(w[1]), float(w[2]), float(w[3]))
            elif mode == 'p' and len(w) == 3:
                T[t]['peeq'] = max(T[t]['peeq'], float(w[2]))
        except ValueError:
            continue
    return T


def _bolt_state(rec, u):
    ua = np.array(u.get(rec['a'], (0, 0, 0)))
    ub = np.array(u.get(rec['b'], (0, 0, 0))) if rec['b'] in u else np.zeros(3)
    d = ub - ua
    dax = d[rec['k_ax']] * rec['sgn']
    T = min(max(rec['kt'] * dax, -1e12), rec['Ft'])
    vx = [min(abs(rec['kv'] * d[k]), rec['Fv']) for k in rec['tang']]
    V = math.hypot(*[rec['kv'] * d[k] for k in rec['tang']]) if rec['tang'] else 0.0
    V = min(V, rec['Fv'] * math.sqrt(2))
    tt = max(T, 0.0)
    return {'tension': tt, 'shear': V, 'ut_t': tt / rec['Ft'], 'ut_v': V / rec['Fv'], 'ut_b': V / rec['Fb'], 'ut_int': tt / (1.4 * rec['Ft']) + V / rec['Fv'],
            'sat_t': tt >= 0.995 * rec['Ft'], 'sat_v': any(abs(rec['kv'] * d[k]) >= 0.995 * rec['Fv'] for k in rec['tang'])}


def _solve(P, lf, active, d, name, ccx, timeout, elastic=False):
    path = write_input(P, lf, active, os.path.join(d, name + '.inp'), name, elastic=elastic)
    for ext in ('dat', 'frd', 'sta', 'cvg', '12d'):
        try:
            os.remove(os.path.join(d, name + '.' + ext))
        except OSError:
            pass
    r = subprocess.run([ccx, name], capture_output=True, text=True, cwd=d, timeout=timeout)
    dat = os.path.join(d, name + '.dat')
    T = _read_dat(dat) if os.path.exists(dat) else {}
    return (T or None), r.stdout[-400:]


def _gaps(P, u):
    """overclosure of every contact pair (positive = pressed together, negative = open) from the displacements u"""
    g = np.zeros(len(P['pairs']))
    for i, (n1, n2, axk, sg, k) in enumerate(P['pairs']):
        d = u.get(n2, (0, 0, 0))[axk] - u.get(n1, (0, 0, 0))[axk]
        g[i] = -sg * d
    return g


def run(spec, out_dir, name='cbfem', timeout=3600, ftol=1.0, max_iter=3, max_elastic=40):
    """staged non-linear run: design load first (load factor 1), then up in steps to lf_max; at every stage the contact set is iterated
    (springs that open are removed, pairs that close are added) until it no longer changes"""
    os.makedirs(out_dir, exist_ok=True)
    spec = dict(spec)
    for b in spec.get('bolts', []):
        if 'props' not in b:
            b['props'] = bolt_props(b['d'], b['cls'], b.get('grip', 2 * b['d']))
    from .solver import ccx_path
    ccx = ccx_path()
    if not ccx:
        raise RuntimeError('CalculiX is not installed: sudo apt install calculix-ccx (needed for the CBFEM run)')
    P = None
    for fac in (1.0, 0.85, 1.15, 0.7, 1.3):                    # some mesh sizes give a distorted element CalculiX cannot expand: try neighbours
        spec2 = dict(spec, size=float(spec['size']) * fac)
        P = prepare(spec2, out_dir, name)
        Tt, _ = _solve(P, 1.0, set(range(len(P['pairs']))), out_dir, name, ccx, timeout, elastic=True)
        if Tt:
            break
    else:
        raise RuntimeError('CalculiX cannot solve this model at any of the tried mesh sizes (distorted shell elements): change the mesh size')
    lfm = float(spec.get('lf_max', 2.0))
    nst = int(spec.get('stages', 4))
    stages = [1.0] + [1.0 + (lfm - 1.0) * (k + 1) / nst for k in range(nst)] if lfm > 1.0 else [lfm]
    active = set(range(len(P['pairs'])))
    series, cap, why, collapse, prev_lf, iters, last_T = [], None, None, False, 0.0, 0, None
    at_design = None
    for lf in stages:
        T = None
        kk = np.array([pr[4] for pr in P['pairs']])

        def update(Tx, act):
            g = _gaps(P, Tx[max(Tx)]['u'])
            f = kk * g                                         # contact force: positive = pressed together
            return {i for i in range(len(P['pairs'])) if (f[i] >= -ftol if i in act else f[i] > ftol)}
        for it in range(max_elastic):                           # 1. contact set from cheap elastic solves
            Te, _ = _solve(P, lf, active, out_dir, name, ccx, timeout, elastic=True)
            iters += 1
            if Te is None:
                break
            new = update(Te, active)
            if new == active:
                break
            active = new
        for it in range(max_iter):                              # 2. the non-linear ramp, contact set corrected if plasticity changes it
            T, tail = _solve(P, lf, active, out_dir, name, ccx, timeout)
            iters += 1
            if T is None:
                break
            new = update(T, active)
            if new == active or max(T) < 0.999:
                break
            active = new
        if T is None:                                          # no convergence: collapse / mechanism
            collapse = True
            break
        last_T = T
        incomplete = max(T) < 0.999
        ser = []
        for t in sorted(T):
            ser.append({'lf': t * lf, 'peeq': T[t]['peeq'], 'bolts': [(_bolt_state(rec, T[t]['u']), rec['name']) for rec in P['bolts']]})
        if at_design is None:
            at_design = ser[-1] if abs(ser[-1]['lf'] - 1.0) < 1e-6 else min(ser, key=lambda x: abs(x['lf'] - 1.0))
        # limits, only for increments beyond the previous stage
        prev = {'lf': prev_lf, 'peeq': next((x['peeq'] for x in series if abs(x['lf'] - prev_lf) < 1e-6), 0.0)}
        hit_here = None
        for sx in ser:
            if sx['lf'] <= prev_lf + 1e-9:
                continue
            hit = []
            if sx['peeq'] >= EPS_LIM:
                hit.append(('plastic strain 5 %', prev['lf'] + (sx['lf'] - prev['lf']) * (EPS_LIM - prev['peeq']) / max(sx['peeq'] - prev['peeq'], 1e-12)))
            for st, nm in sx['bolts']:
                if st['ut_int'] >= 1.0 or st['sat_t'] or st['sat_v'] or st['ut_b'] >= 1.0:
                    kind = 'bolt bearing on the plate' if st['ut_b'] >= 1.0 and st['ut_v'] < 1 else 'bolt shear' if st['sat_v'] or st['ut_v'] >= 1 else ('bolt tension' if st['sat_t'] or st['ut_t'] >= 1 else 'bolt tension-shear interaction')
                    hit.append((f'{kind} ({nm})', sx['lf']))
            if hit:
                hit_here = min(hit, key=lambda x: x[1])
                break
            prev = sx
        series += [x for x in ser if x['lf'] > prev_lf + 1e-9]
        prev_lf = lf
        if hit_here:
            why, cap = hit_here
            break
        if incomplete:                                         # CalculiX stopped before the stage load: collapse at the last converged factor
            collapse = True
            prev_lf = ser[-1]['lf']
            break
    if cap is None and collapse:
        cap, why = prev_lf, 'no convergence beyond this load factor (collapse / mechanism)'
    if at_design is None:
        raise RuntimeError('CalculiX did not converge even at the design load: the model is a mechanism or the loads are far above its capacity (try a smaller load or a finer / coarser mesh)')
    reached = max([x['lf'] for x in series] or [0.0])
    res = {'capacity_factor': round(cap, 3) if cap is not None else None, 'limit': why or f'none up to load factor {reached:.2f}',
           'lf_reached': round(reached, 3), 'ok': bool(cap is None or cap >= 1.0),
           'at_design_load': {'lf': round(at_design['lf'], 3), 'max_plastic_strain_percent': round(at_design['peeq'] * 100, 3),
                              'bolts': [{'bolt': nm, 'tension_kN': round(float(st['tension']) / 1000, 2), 'shear_kN': round(float(st['shear']) / 1000, 2),
                                         'utilisation_tension': round(float(st['ut_t']), 3), 'utilisation_shear': round(float(st['ut_v']), 3),
                                         'utilisation_bearing': round(float(st['ut_b']), 3), 'utilisation_interaction': round(float(st['ut_int']), 3)} for st, nm in at_design['bolts']]},
           'curve': [{'lf': round(x['lf'], 3), 'max_plastic_strain_percent': round(x['peeq'] * 100, 3)} for x in series],
           'input': name + '.inp', 'nodes': P['nN'], 'mesh_size_mm': P['h'], 'contact_pairs': len(P['pairs']), 'contact_active_final': len(active),
           'calculix_runs': iters}
    return res


# ======================================================================== from a ShipBrain connection
def from_connection(c, V=0.0, M=0.0, N=0.0, size=30.0, fy=355.0, fu=0.0, lf_max=2.0, **kw):
    """CBFEM spec for a connection built by connections.build(): loads at the free end of the member, given as the internal forces at the
    column face / base: V shear (kN, downward / along +x for a column), M bending moment (kNm; beams: positive = hogging, tension in the top
    flange; column base: about the strong axis, positive lifts the +y side), N axial (kN, tension positive; column base: compression positive)"""
    import copy
    plates = copy.deepcopy(c.plates)
    bt = c.bolt
    byid = {p['id']: p for p in plates}
    bolts = []
    for a, b, nm, ga, gb in c.links:
        a, b = np.array(a, float), np.array(b, float)
        ax = b - a
        grip = float(np.linalg.norm(ax) + (byid[ga]['t'] + byid[gb]['t']) / 2) if ga in byid and gb in byid else 2 * bt['d']
        bolts.append({'name': nm, 'a': tuple(a), 'b': tuple(b), 'plate_a': ga, 'plate_b': gb, 'axis': tuple(ax), 'd': bt['d'], 'cls': bt['cls'],
                      'd0': bt['d0'], 'grip': grip})
    contacts, fix_plates, loads = [], [], []
    spec = {'plates': plates, 'bolts': bolts, 'contacts': contacts, 'fix': list(c.fix), 'fix_plates': fix_plates, 'loads': loads, 'size': size,
            'lf_max': lf_max, 'material': {'fy': fy, 'fu': fu}}
    spec.update(kw)
    k = c.kind
    ids = {p['id'] for p in plates}
    if k == 'end_plate':
        contacts.append({'a': 'end_plate', 'b': 'column_flange_top', 'axis': 1})
    elif k == 'fin_plate':
        contacts.append({'a': 'fin_plate', 'b': 'beam_web', 'axis': 0})
    elif k == 'splice':
        raise ValueError('CBFEM of bolted splices is not available yet (the model has not been validated): use end_plate, fin_plate or base_plate')
        for sz in ('top', 'bot'):
            for side in ('left', 'right'):
                contacts.append({'a': f'flange_plate_{sz}', 'b': f'beam_{side}_flange_{sz}', 'axis': 2})
        for sx in ('front', 'back'):
            for side in ('left', 'right'):
                contacts.append({'a': f'web_plate_{sx}', 'b': f'beam_{side}_web', 'axis': 0})
    elif k == 'base_plate':
        spec['fix'] = []                                        # the concrete is the ground plate below, not a rigid support
        tp = c.info['base_plate_mm'][2]
        bp = byid['base_plate']
        xs = [p[0] for p in bp['outline']]
        ys = [p[1] for p in bp['outline']]
        gz = -tp - 0.5
        plates.append(K_plate_rect('ground', (min(xs) - 40, max(xs) + 40, min(ys) - 40, max(ys) + 40), gz, 1.0))
        contacts.append({'a': 'base_plate', 'b': 'ground', 'axis': 2})
        fix_plates.append('ground')
        for j, (x, y, z) in enumerate(c.anchors):
            bolts.append({'name': f'anchor_{j + 1}', 'a': (x, y, z), 'b': None, 'plate_a': 'base_plate', 'plate_b': None, 'axis': (0, 0, -1),
                          'd': bt['d'], 'cls': bt['cls'], 'd0': c.info['anchor_hole_mm'], 'grip': tp + 8 * bt['d']})
    contacts[:] = [x for x in contacts if x['a'] in {p['id'] for p in plates} and x['b'] in {p['id'] for p in plates}]
    ax, val, dirn = c.tip
    kk = {'x': 0, 'y': 1, 'z': 2}[ax]
    if k == 'base_plate':
        L = val + c.info['base_plate_mm'][2] / 2
        Mt = M + V * L / 1000.0                                 # tip couple so that the moment at the base equals M (about x; V along y)
        loads.append({'select': (ax, val), 'force': [0.0, V, -N], 'moment': [Mt, 0.0, 0.0]})
    else:
        start = c.fix[0].get('y') if k == 'splice' else next(P for P in c.parts if P['name'] == 'column')['solid'].val().BoundingBox().ymax
        L = val - start
        Mt = -M + V * L / 1000.0                                # hogging M gives a negative moment about x; tip shear V adds -V L
        loads.append({'select': (ax, val), 'force': [0.0, N, -V], 'moment': [Mt, 0.0, 0.0]})
    return spec


def K_plate_rect(pid, box, z, t):
    x0, x1, y0, y1 = box
    return {'id': pid, 't': float(t), 'outline': [[x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z]], 'holes': []}
