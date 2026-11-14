"""
Run Awatif's own linear 3D frame solver (https://github.com/madil4/awatif, MIT) from Python.

The solver is Awatif's compiled C++/Eigen code (shipbrain/vendor/awatif/lSolver.wasm, unchanged); it runs on any CPU through
`wasmtime` (pip install wasmtime, Apache-2.0). The input is prepared with Awatif's own rules (vendor/awatif/getLoads.ts):
line loads become nodal loads, L/2 to each end of every element of the line mesh; ULS combinations use Awatif's factors.

    l_solve(nodes, elements, supports, loads, props, releases) -> positions (n x 3), forces (m x 13), status
    analyse(model)  same model format as frame3d (nodes, members, supports, loads per case, combinations) solved by Awatif

If wasmtime is not installed, analyse() falls back to ShipBrain's own numpy solver (frame3d) and says so.
"""
import math, os, struct

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WASM = os.path.join(HERE, 'vendor', 'awatif', 'lSolver.wasm')
# Awatif's ULS combinations (vendor/awatif/loads-data-model.ts): dead / live / wind
ULS_COMBINATIONS = {'ULS-1': {'G': 1.35, 'Q': 1.5, 'W': 0.9}, 'ULS-2': {'G': 1.35, 'Q': 1.05, 'W': 1.5}}
STATUS = {1: 'the stiffness matrix could not be factorised (the frame is a mechanism: add supports or remove releases)',
          2: 'the solve failed', 3: 'a load acts on a direction with no stiffness (a mechanism or a released joint)',
          4: 'an element refers to a node that does not exist'}
_MOD = {}


def available():
    try:
        import wasmtime  # noqa: F401
        return os.path.exists(WASM)
    except ImportError:
        return False


class _Wasm:
    """one instance of Awatif's solver (WASI + the few Emscripten helpers it imports)"""
    def __init__(self):
        import wasmtime as wt
        if 'module' not in _MOD:
            _MOD['engine'] = wt.Engine()
            _MOD['module'] = wt.Module.from_file(_MOD['engine'], WASM)
        self.store = wt.Store(_MOD['engine'])
        self.store.set_wasi(wt.WasiConfig())
        link = wt.Linker(_MOD['engine'])
        link.define_wasi()
        hold = {}

        def fail(*a):
            raise RuntimeError('Awatif solver aborted')

        def resize(size):
            mem = hold['mem']
            cur = mem.data_len(self.store)
            if size <= cur:
                return 1
            try:
                mem.grow(self.store, (size - cur + 65535) // 65536)
                return 1
            except Exception:
                return 0
        I32 = wt.ValType.i32()
        link.define_func('env', '__assert_fail', wt.FuncType([I32] * 4, []), fail)
        link.define_func('env', '__cxa_throw', wt.FuncType([I32] * 3, []), fail)
        link.define_func('env', '_abort_js', wt.FuncType([], []), fail)
        link.define_func('env', 'emscripten_resize_heap', wt.FuncType([I32], [I32]), resize)
        link.define_func('env', '_tzset_js', wt.FuncType([I32] * 4, []), lambda *a: None)
        self.inst = link.instantiate(self.store, _MOD['module'])
        ex = self.inst.exports(self.store)
        self.mem = hold['mem'] = ex['memory']
        self.malloc, self.free, self.solve = ex['malloc'], ex['free'], ex['lSolve']
        for f in ('emscripten_stack_init', '__wasm_call_ctors'):
            if f in ex:
                ex[f](self.store)

    def put(self, data, fmt):
        raw = struct.pack('<%d%s' % (len(data), fmt), *data) if len(data) else b'\0' * 8
        p = self.malloc(self.store, max(8, len(raw)))
        self.mem.write(self.store, raw, p)
        return p

    def get(self, p, n, fmt, size):
        return struct.unpack('<%d%s' % (n, fmt), self.mem.read(self.store, p, p + n * size)) if n else ()


def l_solve(nodes, elements, supports, loads, props, releases=None):
    """Awatif's lSolve. nodes (n x 3), elements (m x 2, node indices), supports {node: 6 bools}, loads {node: 6 floats},
    props {'E','A','Iz','Iy','G','J'}: one value per element (lists), releases {element: [startMy, startMz, endMy, endMz]}
    -> positions (n x 3: deformed coordinates), forces (m x 13, Awatif's order and signs), status (0 = ok)"""
    w = _Wasm()
    N, M = len(nodes), len(elements)
    ptrs = []

    def put(d, f):
        p = w.put(d, f)
        ptrs.append(p)
        return p
    args = [put(np.asarray(nodes, float).ravel().tolist(), 'd'), N, put(np.asarray(elements, int).ravel().tolist(), 'I'), M]
    sk = sorted(supports)
    args += [put(sk, 'i'), put([bool(b) for k in sk for b in supports[k]], '?'), len(sk)]
    lk = sorted(loads)
    args += [put(lk, 'i'), put([float(v) for k in lk for v in loads[k]], 'd'), len(lk)]
    for key in ('E', 'A', 'Iz', 'Iy', 'G', 'J'):                           # lSolve order
        vals = [float(v) for v in props[key]]
        args += [put(list(range(M)), 'i'), put(vals, 'd'), M]
    rel = releases or {}
    rk = sorted(rel)
    args += [put(rk, 'i'), put([bool(b) for k in rk for b in rel[k]], '?'), len(rk)]
    outs = [put([0], 'i') for _ in range(5)]                               # positions**, size*, forces**, size*, status*
    w.solve(w.store, *args, *outs)
    status = w.get(outs[4], 1, 'i', 4)[0]
    if status:
        return None, None, status
    pp, ps = w.get(outs[0], 1, 'I', 4)[0], w.get(outs[1], 1, 'i', 4)[0]
    fp, fs = w.get(outs[2], 1, 'I', 4)[0], w.get(outs[3], 1, 'i', 4)[0]
    pos = np.array(w.get(pp, ps, 'd', 8)).reshape(-1, 3)
    frc = np.array(w.get(fp, fs, 'd', 8)).reshape(-1, 13)
    return pos, frc, 0


def _lambda(P1, P2):
    """Awatif's local axes (lSolver.cpp getTransformationMatrix)"""
    v = P2 - P1
    L = float(np.linalg.norm(v))
    l, m, n = v / L
    if abs(n - 1) < 1e-12:
        return np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0.0]])
    if abs(n + 1) < 1e-12:
        return np.array([[0, 0, -1], [0, 1, 0], [1, 0, 0.0]])
    D = math.sqrt(l * l + m * m)
    return np.array([[l, m, n], [-m / D, l / D, 0], [-l * n / D, -m * n / D, D]])


def _f_local(o):
    """Awatif's 12 output values -> the local end-force vector (undo its sign convention)"""
    f = np.zeros(12)
    f[0], f[6], f[1], f[7], f[2], f[8] = o[0], -o[1], -o[2], o[3], -o[4], o[5]
    f[3], f[9], f[4], f[10], f[5], f[11] = o[6], -o[7], -o[8], o[9], -o[10], o[11]
    return f


def analyse(model, divisions=10):
    """frame3d-style model -> results per combination, solved by Awatif's solver"""
    from . import frame3d
    if not available():
        out = frame3d.analyse(model)
        out['solver'] = 'ShipBrain numpy frame solver (install wasmtime to use Awatif\'s solver)'
        return out
    nodes = {str(k): np.asarray(v, float) for k, v in model['nodes'].items()}
    names = list(nodes)
    elems = []                                                     # (member id, i, j, props, rel flags)
    members = []
    for m in model['members']:
        p = frame3d.section(m.get('section'))
        n1, n2 = str(m['n1']), str(m['n2'])
        nd = max(1, int(m.get('divisions', divisions)))
        chain = [n1]
        for k in range(1, nd):
            nm = f"{m['id']}.{k}"
            nodes[nm] = nodes[n1] + (nodes[n2] - nodes[n1]) * k / nd
            names.append(nm)
            chain.append(nm)
        chain.append(n2)
        rel = str(m.get('release') or '')
        for k in range(nd):
            flags = [rel in ('start', 'both') and k == 0] * 2 + [rel in ('end', 'both') and k == nd - 1] * 2
            elems.append((str(m['id']), chain[k], chain[k + 1], p, flags))
        members.append(str(m['id']))
    idx = {n: i for i, n in enumerate(names)}
    X = np.array([nodes[n] for n in names])
    E = [[idx[a], idx[b]] for _, a, b, _, _ in elems]
    props = {k: [e[3][k] for e in elems] for k in ('E', 'A', 'Iz', 'Iy', 'G', 'J')}
    releases = {i: e[4] for i, e in enumerate(elems) if any(e[4])}
    sup = {}
    for n, s in (model.get('supports') or {}).items():
        code = frame3d._SUP.get(str(s).lower(), str(s))
        sup[idx[str(n)]] = [str(d) in code for d in range(1, 7)]
    cases = model.get('loads') or {}
    if isinstance(cases, list):
        cases = {'LC1': cases}
    combos = model.get('combinations') or _combos(cases)

    def case_loads(factors):
        F = np.zeros((len(names), 6))
        for case, fac in factors.items():
            for it in cases.get(case, []):
                if 'node' in it:
                    f = (list(it['F']) + [0] * 6)[:6]
                    F[idx[str(it['node'])]] += fac * np.asarray(f, float)
                    continue
                for (mid, a, b, p, _) in elems:                     # line loads: L/2 to each end (Awatif getLoads.ts)
                    if 'member' in it and mid != str(it['member']):
                        continue
                    L = float(np.linalg.norm(nodes[b] - nodes[a]))
                    if 'w' in it:
                        q = fac * np.asarray(it['w'], float)
                    elif 'self_weight' in it:
                        q = np.array([0, 0, -fac * float(it['self_weight']) * p['rho'] * p['A'] * frame3d.G_ACC])
                    else:
                        continue
                    F[idx[a], :3] += q * L / 2
                    F[idx[b], :3] += q * L / 2
        return F
    res = {}
    for name, factors in combos.items():
        F = case_loads(factors)
        loads = {i: F[i].tolist() for i in range(len(names)) if np.any(F[i])}
        pos, frc, st = l_solve(X, E, sup, loads, props, releases)
        if st:
            raise ValueError(f'{name}: ' + STATUS.get(st, f'Awatif solver status {st}'))
        U = pos - X
        Fg = np.zeros((len(names), 6))                              # element end forces in global axes -> reactions
        memres = {}
        for e, o in zip(elems, frc):
            mid, a, b, p, _ = e
            fl = _f_local(o[1:])
            T = np.kron(np.eye(4), _lambda(nodes[a], nodes[b]))
            fg = T.T @ fl
            Fg[idx[a]] += fg[:6]
            Fg[idx[b]] += fg[6:]
            r = memres.setdefault(mid, {'N_max': 0.0, 'V_max': 0.0, 'My_max': 0.0, 'Mz_max': 0.0, 'T_max': 0.0, 'sigma_max': 0.0,
                                        'section': p['shape'], 'fy': p['fy']})
            for end in (0, 6):
                N, Vy, Vz, Tt, My, Mz = fl[end:end + 6]
                N = -N if end == 0 else N
                sig = abs(N) / p['A'] + (abs(My) * p['cz'] / p['Iy'] if p['cz'] else 0) + (abs(Mz) * p['cy'] / p['Iz'] if p['cy'] else 0)
                r['N_max'] = max(r['N_max'], N, key=abs)
                r['V_max'] = max(r['V_max'], math.hypot(Vy, Vz))
                r['My_max'], r['Mz_max'] = max(r['My_max'], abs(My)), max(r['Mz_max'], abs(Mz))
                r['T_max'] = max(r['T_max'], abs(Tt))
                r['sigma_max'] = max(r['sigma_max'], sig)
        for r in memres.values():
            r['utilisation'] = round(r['sigma_max'] / r['fy'], 4)
            for k in ('N_max', 'V_max', 'My_max', 'Mz_max', 'T_max', 'sigma_max'):
                r[k] = round(float(r[k]), 3)
        R = Fg - F
        dn = int(np.argmax(np.linalg.norm(U, axis=1)))
        res[name] = {'max_displacement_mm': round(float(np.linalg.norm(U[dn])), 4), 'at_node': names[dn],
                     'displacements': {n: U[idx[n]].round(4).tolist() for n in model['nodes']},
                     'reactions': {names[i]: R[i].round(3).tolist() for i in sup}, 'members': memres,
                     'sum_reactions': R[list(sup)][:, :3].sum(0).round(3).tolist() if sup else [0, 0, 0]}
    out = frame3d.summarise(res, combos, len(members))
    out['solver'] = "Awatif linear frame solver (C++/Eigen, MIT) run through wasmtime"
    return out


def _combos(cases):
    """single cases + Awatif's ULS combinations for the cases present + SLS"""
    c = set(cases)
    out = {}
    if c <= {'G', 'Q', 'W'} and 'G' in c:
        for k, v in ULS_COMBINATIONS.items():
            out[k] = {x: f for x, f in v.items() if x in c}
        out['SLS'] = {x: 1.0 for x in c}
        return out
    from .frame3d import default_combinations
    return default_combinations(cases)
