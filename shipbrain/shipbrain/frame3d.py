"""
Built-in linear static 3D frame solver (numpy / SciPy, no external program). Idea and feature set from Awatif
(MIT, https://github.com/madil4/awatif): beams with 6 DOF per node, end moment releases, local axes, load cases and ULS
combinations, member report. Own implementation (standard Euler-Bernoulli 3D beam element).

Units: mm, N, MPa (N/mm2), t/mm3 for density, g = 9810 mm/s2.

model = {
  'nodes':   {id: [x, y, z]},
  'members': [{'id', 'n1', 'n2', 'section': S, 'ref': [x, y, z] (optional local z direction), 'release': 'end' | 'start' |
               'both' (pinned ends: no bending moment there), 'divisions': 4}],
  'supports': {node: 'fixed' | 'pinned' | 'roller' (z only) | '123' (dof list, 1-3 = x y z, 4-6 = rotations)},
  'loads': {'G': [...], 'Q': [...], 'W': [...]}   # load cases, each a list of
           {'node', 'F': [Fx, Fy, Fz, Mx, My, Mz]} | {'member', 'w': [wx, wy, wz]} (N/mm, global) | {'self_weight': 1.0}
  'combinations': {'ULS1': {'G': 1.35, 'Q': 1.5, 'W': 0.9}, ...}   # default: EN 1990 set for the cases present
}
Section S: {'E', 'G', 'A', 'Iy', 'Iz', 'J', 'cy', 'cz'} (c = distance to the extreme fibre) or a shape:
  {'pipe': [OD, wall]} | {'rect': [b, h]} | {'I': [h, b, tw, tf]} | {'box': [h, b, t]}; plus optional 'E', 'rho', 'yield'.
Local axes: x along the member; z = 'ref' made square to x (default global Z; global X for vertical members); y = z x x.
Iy = bending in the local x-z plane (vertical loads on horizontal members with the default ref): the strong axis.
"""
import math

import numpy as np

STEEL = {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9, 'yield': 235.0}
G_ACC = 9810.0


# ====================================================================== sections
def section(s):
    s = dict(s or {})
    E = float(s.get('E', STEEL['E']))
    G = float(s.get('G', E / (2 * (1 + STEEL['nu']))))
    if 'pipe' in s:
        D, t = map(float, s['pipe'])
        d = max(D - 2 * t, 0.0)
        I = math.pi / 64 * (D ** 4 - d ** 4)
        p = {'A': math.pi / 4 * (D ** 2 - d ** 2), 'Iy': I, 'Iz': I, 'J': 2 * I, 'cy': D / 2, 'cz': D / 2, 'shape': f'pipe {D:g}x{t:g}'}
    elif 'rect' in s:
        b, h = map(float, s['rect'])
        a, c = max(b, h), min(b, h)
        J = a * c ** 3 * (1 / 3 - 0.21 * c / a * (1 - c ** 4 / (12 * a ** 4)))
        p = {'A': b * h, 'Iy': b * h ** 3 / 12, 'Iz': h * b ** 3 / 12, 'J': J, 'cy': b / 2, 'cz': h / 2, 'shape': f'rect {b:g}x{h:g}'}
    elif 'I' in s:
        h, b, tw, tf = map(float, s['I'])
        hw = h - 2 * tf
        Iy = b * h ** 3 / 12 - (b - tw) * hw ** 3 / 12
        Iz = 2 * tf * b ** 3 / 12 + hw * tw ** 3 / 12
        p = {'A': 2 * b * tf + hw * tw, 'Iy': Iy, 'Iz': Iz, 'J': (2 * b * tf ** 3 + hw * tw ** 3) / 3, 'cy': b / 2, 'cz': h / 2,
             'shape': f'I {h:g}x{b:g}x{tw:g}x{tf:g}'}
    elif 'box' in s:
        h, b, t = map(float, s['box'])
        Iy = (b * h ** 3 - (b - 2 * t) * (h - 2 * t) ** 3) / 12
        Iz = (h * b ** 3 - (h - 2 * t) * (b - 2 * t) ** 3) / 12
        Am = (b - t) * (h - t)
        p = {'A': b * h - (b - 2 * t) * (h - 2 * t), 'Iy': Iy, 'Iz': Iz, 'J': 4 * Am ** 2 * t / (2 * (b - t + h - t)),
             'cy': b / 2, 'cz': h / 2, 'shape': f'box {h:g}x{b:g}x{t:g}'}
    else:
        p = {k: float(s[k]) for k in ('A', 'Iy', 'Iz', 'J') if k in s}
        if len(p) < 4:
            raise ValueError('section needs A, Iy, Iz, J (mm2, mm4) or a shape: pipe [OD, t] | rect [b, h] | I [h, b, tw, tf] | box [h, b, t]')
        p.update(cy=float(s.get('cy', 0)), cz=float(s.get('cz', 0)), shape=s.get('name', 'generic'))
    p.update(E=E, G=G, rho=float(s.get('rho', STEEL['rho'])), fy=float(s.get('yield', STEEL['yield'])))
    return p


# ====================================================================== one element
def _axes(P1, P2, ref=None):
    x = P2 - P1
    L = float(np.linalg.norm(x))
    if L <= 0:
        raise ValueError('a member has zero length')
    x = x / L
    r = np.asarray(ref, float) if ref is not None else (np.array([0.0, 0, 1]) if abs(x[2]) < 0.999 else np.array([1.0, 0, 0]))
    z = r - (r @ x) * x
    if np.linalg.norm(z) < 1e-9:
        raise ValueError('the member\'s ref vector is along the member')
    z /= np.linalg.norm(z)
    y = np.cross(z, x)
    return L, np.array([x, y, z])


def _k_local(p, L):
    E, G, A, Iy, Iz, J = p['E'], p['G'], p['A'], p['Iy'], p['Iz'], p['J']
    k = np.zeros((12, 12))
    a, t = E * A / L, G * J / L
    k[0, 0] = k[6, 6] = a
    k[0, 6] = k[6, 0] = -a
    k[3, 3] = k[9, 9] = t
    k[3, 9] = k[9, 3] = -t
    for (v1, r1, v2, r2, I, s) in ((1, 5, 7, 11, Iz, 1.0), (2, 4, 8, 10, Iy, -1.0)):   # v-thz plane, w-thy plane
        c = E * I / L ** 3
        m = np.array([[12, 6 * L * s, -12, 6 * L * s], [6 * L * s, 4 * L * L, -6 * L * s, 2 * L * L],
                      [-12, -6 * L * s, 12, -6 * L * s], [6 * L * s, 2 * L * L, -6 * L * s, 4 * L * L]]) * c
        idx = [v1, r1, v2, r2]
        for i in range(4):
            for j in range(4):
                k[idx[i], idx[j]] = m[i, j]
    return k


def _f_udl(w, L):
    """equivalent nodal loads (local) of a uniform load w = [wx, wy, wz] (local, N/mm)"""
    wx, wy, wz = w
    f = np.zeros(12)
    f[0] = f[6] = wx * L / 2
    f[1] = f[7] = wy * L / 2
    f[5], f[11] = wy * L * L / 12, -wy * L * L / 12
    f[2] = f[8] = wz * L / 2
    f[4], f[10] = -wz * L * L / 12, wz * L * L / 12
    return f


def _condense(k, f, released):
    """remove end moment stiffness at released dofs (static condensation)"""
    if not released:
        return k, f
    r = sorted(released)
    c = [i for i in range(12) if i not in r]
    Krr = k[np.ix_(r, r)]
    Kcr = k[np.ix_(c, r)]
    inv = np.linalg.pinv(Krr)
    kc = np.zeros_like(k)
    kc[np.ix_(c, c)] = k[np.ix_(c, c)] - Kcr @ inv @ Kcr.T
    fc = np.zeros_like(f)
    fc[c] = f[c] - Kcr @ inv @ f[r]
    return kc, fc


_REL = {'start': [4, 5], 'end': [10, 11], 'both': [4, 5, 10, 11], None: [], '': [], 'none': []}
_SUP = {'fixed': '123456', 'pinned': '123', 'roller': '3', 'rollerx': '1', 'rollery': '2', 'rollerz': '3'}


# ====================================================================== the solver
class Frame:
    def __init__(self, model):
        self.raw = model
        nodes = {str(k): np.asarray(v, float) for k, v in model['nodes'].items()}
        self.members = []
        # line meshing: each member into 'divisions' elements (exact nodal values; more points along the member)
        self.nodes = dict(nodes)
        self.elems = []
        for m in model['members']:
            p = section(m.get('section'))
            n1, n2 = str(m['n1']), str(m['n2'])
            nd = max(1, int(m.get('divisions', 4)))
            chain = [n1] + [f"{m['id']}.{k}" for k in range(1, nd)] + [n2]
            for k in range(1, nd):
                self.nodes[chain[k]] = nodes[n1] + (nodes[n2] - nodes[n1]) * k / nd
            rel = _REL.get(m.get('release'), [])
            for k in range(nd):
                er = [d for d in rel if (d < 6 and k == 0) or (d >= 6 and k == nd - 1)]
                self.elems.append({'member': str(m['id']), 'n1': chain[k], 'n2': chain[k + 1], 'p': p, 'ref': m.get('ref'), 'rel': er})
            self.members.append({'id': str(m['id']), 'p': p, 'nodes': chain})
        self.order = {n: i for i, n in enumerate(self.nodes)}
        self.ndof = 6 * len(self.nodes)
        self.sup = {}
        for n, s in (model.get('supports') or {}).items():
            n = str(n)
            if n not in self.nodes:
                raise ValueError(f'support at unknown node {n}')
            code = _SUP.get(str(s).lower(), str(s))
            self.sup[n] = sorted({int(c) - 1 for c in code if c in '123456'})
        for e in self.elems:
            L, R = _axes(self.nodes[e['n1']], self.nodes[e['n2']], e['ref'])
            e['L'], e['R'] = L, R
            e['T'] = np.kron(np.eye(4), R)
            e['k'] = _k_local(e['p'], L)

    def _dofs(self, e):
        a, b = 6 * self.order[e['n1']], 6 * self.order[e['n2']]
        return list(range(a, a + 6)) + list(range(b, b + 6))

    def _case(self, items):
        """global load vector and per-element local UDL for one load case"""
        F = np.zeros(self.ndof)
        w_el = {i: np.zeros(3) for i in range(len(self.elems))}
        for it in items or []:
            if 'node' in it:
                n = str(it['node'])
                if n not in self.nodes:
                    raise ValueError(f'load at unknown node {n}')
                f = list(it['F']) + [0] * (6 - len(it['F']))
                F[6 * self.order[n]: 6 * self.order[n] + 6] += np.asarray(f[:6], float)
            elif 'member' in it:
                for i, e in enumerate(self.elems):
                    if e['member'] == str(it['member']):
                        w_el[i] += e['R'] @ np.asarray(it['w'], float)
            elif 'self_weight' in it:
                for i, e in enumerate(self.elems):
                    w_el[i] += e['R'] @ np.array([0, 0, -e['p']['rho'] * e['p']['A'] * G_ACC * float(it['self_weight'])])
        return F, w_el

    def solve(self, loads):
        """loads: list of load items (one combination already factored) -> results dict"""
        from scipy.sparse import coo_matrix
        from scipy.sparse.linalg import spsolve
        F, w_el = self._case(loads)
        rows, cols, vals = [], [], []
        kfs = []
        for i, e in enumerate(self.elems):
            fl = _f_udl(w_el[i], e['L'])
            k, f = _condense(e['k'], fl, e['rel'])
            kfs.append((k, f))
            kg = e['T'].T @ k @ e['T']
            d = self._dofs(e)
            for a in range(12):
                for b in range(12):
                    if kg[a, b] != 0:
                        rows.append(d[a]); cols.append(d[b]); vals.append(kg[a, b])
            F[d] += e['T'].T @ f
        K = coo_matrix((vals, (rows, cols)), shape=(self.ndof, self.ndof)).tocsr()
        fixed = sorted({6 * self.order[n] + d for n, ds in self.sup.items() for d in ds})
        # dofs with no stiffness at all (rotations at released joints): fix them so the system can be solved
        diag = K.diagonal()
        free_mask = np.ones(self.ndof, bool)
        free_mask[fixed] = False
        free_mask &= np.abs(diag) > 1e-9 * max(1.0, float(np.abs(diag).max()))
        free = np.nonzero(free_mask)[0]
        U = np.zeros(self.ndof)
        Kff = K[free][:, free]
        try:
            U[free] = spsolve(Kff.tocsc(), F[free])
        except Exception as ex:
            raise ValueError(f'the frame cannot be solved ({ex}): check the supports, it may be a mechanism')
        if not np.all(np.isfinite(U)) or np.abs(Kff @ U[free] - F[free]).max() > 1e-6 * max(1.0, np.abs(F).max()):
            raise ValueError('the frame is a mechanism (it can move without resistance): add supports or remove releases')
        Rv = K @ U - F
        out_el = []
        for i, e in enumerate(self.elems):
            k, f = kfs[i]
            ul = e['T'] @ U[self._dofs(e)]
            fe = k @ ul - f                                   # local end forces: [N1 Vy1 Vz1 T1 My1 Mz1 N2 ... ]
            out_el.append(fe)
        return U, Rv, out_el

    def results(self, U, Rv, fe):
        disp = {n: U[6 * i: 6 * i + 3] for n, i in self.order.items()}
        dmax_n = max(disp, key=lambda n: np.linalg.norm(disp[n]))
        reac = {n: Rv[6 * self.order[n]: 6 * self.order[n] + 6].round(3).tolist() for n in self.sup}
        mem = {}
        for e, f in zip(self.elems, fe):
            p = e['p']
            r = mem.setdefault(e['member'], {'N_max': 0.0, 'V_max': 0.0, 'My_max': 0.0, 'Mz_max': 0.0, 'T_max': 0.0, 'sigma_max': 0.0,
                                             'section': p['shape'], 'fy': p['fy']})
            for end in (0, 6):
                N, Vy, Vz, T, My, Mz = f[end:end + 6]
                N = -N if end == 0 else N                         # tension positive
                sig = abs(N) / p['A'] + (abs(My) * p['cz'] / p['Iy'] if p['cz'] else 0) + (abs(Mz) * p['cy'] / p['Iz'] if p['cy'] else 0)
                r['N_max'] = max(r['N_max'], N, key=abs)
                r['V_max'] = max(r['V_max'], math.hypot(Vy, Vz))
                r['My_max'] = max(r['My_max'], abs(My))
                r['Mz_max'] = max(r['Mz_max'], abs(Mz))
                r['T_max'] = max(r['T_max'], abs(T))
                r['sigma_max'] = max(r['sigma_max'], sig)
        for r in mem.values():
            r['utilisation'] = round(r['sigma_max'] / r['fy'], 4) if r['fy'] else None
            for k in ('N_max', 'V_max', 'My_max', 'Mz_max', 'T_max', 'sigma_max'):
                r[k] = round(float(r[k]), 3)
        return {'max_displacement_mm': round(float(np.linalg.norm(disp[dmax_n])), 4), 'at_node': dmax_n,
                'displacements': {n: v.round(4).tolist() for n, v in disp.items() if '.' not in n},
                'reactions': reac, 'members': mem,
                'sum_reactions': Rv.reshape(-1, 6)[:, :3].sum(0).round(3).tolist()}


def default_combinations(cases):
    """EN 1990 (STR, fundamental) for the cases present: G permanent, Q imposed, W wind; SLS characteristic"""
    c = set(cases)
    out = {}
    if 'G' in c:
        out['ULS_G'] = {'G': 1.35}
    if {'G', 'Q'} <= c:
        out['ULS_Q'] = {'G': 1.35, 'Q': 1.5, **({'W': 0.9} if 'W' in c else {})}
    if {'G', 'W'} <= c:
        out['ULS_W'] = {'G': 1.35, 'W': 1.5, **({'Q': 1.05} if 'Q' in c else {})}
        out['ULS_W_uplift'] = {'G': 1.0, 'W': 1.5}
    out['SLS'] = {k: 1.0 for k in c}
    for k in c - {'G', 'Q', 'W'}:
        out.setdefault(f'ULS_{k}', {k: 1.5})
    return out


def analyse(model):
    """all combinations -> {'combinations': {name: results}, 'governing': ..., 'plain_english'}"""
    fr = Frame(model)
    cases = model.get('loads') or {}
    if isinstance(cases, list):
        cases = {'LC1': cases}
    combos = model.get('combinations') or default_combinations(cases)
    res = {}
    for name, factors in combos.items():
        items = []
        for case, fac in factors.items():
            for it in cases.get(case, []):
                it2 = dict(it)
                if 'F' in it2:
                    it2['F'] = [float(v) * fac for v in it2['F']]
                if 'w' in it2:
                    it2['w'] = [float(v) * fac for v in it2['w']]
                if 'self_weight' in it2:
                    it2['self_weight'] = float(it2['self_weight']) * fac
                items.append(it2)
        res[name] = fr.results(*fr.solve(items))
    return summarise(res, combos, len(fr.members))


def summarise(res, combos, n_members):
    """governing combination / member + plain English, from results per combination"""
    uls = {k: v for k, v in res.items() if not k.upper().startswith('SLS')} or res
    gov = max(uls, key=lambda k: max((m['utilisation'] or 0) for m in uls[k]['members'].values()))
    gm = max(uls[gov]['members'].items(), key=lambda kv: kv[1]['utilisation'] or 0)
    sls = res.get('SLS') or res[gov]
    pe = (f"{n_members} member(s), {len(res)} combination(s). Governing: {gov}, member {gm[0]} ({gm[1]['section']}): "
          f"max stress {gm[1]['sigma_max']:g} MPa, utilisation {gm[1]['utilisation']:g} -> {'PASS' if gm[1]['utilisation'] <= 1 else 'FAIL'} "
          f"(axial + bending, elastic). Max displacement {sls['max_displacement_mm']:g} mm at node {sls['at_node']} "
          f"({'SLS' if 'SLS' in res else gov}).")
    return {'combinations': res, 'governing': {'combination': gov, 'member': gm[0], **gm[1]},
            'plain_english': pe, 'combination_factors': combos}


def report(out, title='Frame check'):
    """Markdown report: per combination, per member forces and utilisation"""
    L = [f'# {title}', '', out['plain_english'], '', '## Load combinations', '']
    for k, v in out['combination_factors'].items():
        L.append(f"- {k}: " + ' + '.join(f'{f:g} {c}' for c, f in v.items()))
    for name, r in out['combinations'].items():
        L += ['', f'## {name}', '', f"Max displacement {r['max_displacement_mm']} mm at node {r['at_node']}; "
              f"sum of reactions {r['sum_reactions']} N.", '',
              '| member | section | N max (N) | V max (N) | My max (N.mm) | Mz max (N.mm) | sigma (MPa) | utilisation |',
              '|---|---|---|---|---|---|---|---|']
        for mid, m in r['members'].items():
            L.append(f"| {mid} | {m['section']} | {m['N_max']:g} | {m['V_max']:g} | {m['My_max']:g} | {m['Mz_max']:g} | "
                     f"{m['sigma_max']:g} | {m['utilisation']:g} |")
    L += ['', 'Elastic first-order analysis; stress = |N|/A + |My|/Wy + |Mz|/Wz. Buckling, shear and local checks are not '
              'included: an engineer reviews this report.']
    return '\n'.join(L)


def from_femodel(fem, supports, loads, combinations=None):
    """an FEModel of bars (e.g. pipe_extract's 1D pipe model) -> frame model. supports / loads may give 'at': [x, y, z]
    instead of 'node' (the nearest node is used)"""
    nodes = {str(n): v.tolist() for n, v in fem.nodes.items()}
    X = np.array(list(fem.nodes.values()))
    ids = [str(n) for n in fem.nodes]

    def near(p):
        return ids[int(np.argmin(np.linalg.norm(X - np.asarray(p, float), axis=1)))]
    members = []
    for eid, e in fem.elems.items():
        if e['type'] != 'bar':
            continue
        p = fem.props[e['pid']]
        if p.get('od'):
            sec = {'pipe': [p['od'], p['wall']]}
        elif abs(p['I1'] - p['I2']) <= 1e-6 * max(p['I1'], 1.0):        # round tube from a .bdf: OD back from A and I
            D = math.sqrt((16 * p['I1'] / p['A'] + 4 * p['A'] / math.pi) / 2)
            sec = {'A': p['A'], 'Iy': p['I1'], 'Iz': p['I2'], 'J': p['J'], 'cy': D / 2, 'cz': D / 2, 'name': f'tube OD{D:.1f}'}
        else:
            sec = {'A': p['A'], 'Iy': p['I1'], 'Iz': p['I2'], 'J': p['J']}
        members.append({'id': str(eid), 'n1': str(e['nodes'][0]), 'n2': str(e['nodes'][1]), 'section': sec, 'divisions': 1})
    sup = {}
    for s in supports:
        sup[str(s['node']) if 'node' in s else near(s['at'])] = s.get('type', 'fixed')
    cases = {}
    for case, items in (loads or {}).items():
        out = []
        for it in items:
            it = dict(it)
            if 'at' in it:
                it['node'] = near(it.pop('at'))
            out.append(it)
        cases[case] = out
    return {'nodes': nodes, 'members': members, 'supports': sup, 'loads': cases, **({'combinations': combinations} if combinations else {})}
