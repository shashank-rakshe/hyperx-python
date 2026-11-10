"""
AI layers for the CAE chain that run on a CPU with numpy + SciPy only (no GPU, no PyTorch needed):

  dataset      every FE run (parameters, node coordinates, von Mises and displacement fields, peak values) saved in one
               consistent file (.npz), plus ParaView .vtk files of the fields.
  study        a parametric study: Latin-hypercube samples of the parameters, mesh (own mesher) + CalculiX for each.
  surrogate    POD + RBF reduced-order model trained on the study: predicts the FULL stress / displacement field and the
               peak values in milliseconds. Accuracy is measured by leave-one-out validation; every prediction carries an
               error estimate, and when the estimate is too high (or the point is outside the trained range) it says so
               and the real solver is run instead (the new run is added to the data: the model gets better with use).
               Peaks are predicted in log space (stress ~ p * b^2 / t^2 is a straight line there), field SHAPES by POD.
               export_cpp() writes a self-contained C++ header so a C++ program (e.g. a CAD / FE GUI) can call the surrogate.
  insight      post-processing of any CalculiX result: hotspot clusters, utilisation vs yield with pass/fail, elements
               that need refinement (stress jump inside an element), comparison against a baseline run, a report draft.
"""
import json, math, os, time

import numpy as np

# ====================================================================== results in, fields out
def von_mises(s):
    s = np.asarray(s, float)
    sx, sy, sz, sxy, syz, szx = (s[:, k] for k in range(6))
    return np.sqrt(0.5 * ((sx - sy) ** 2 + (sy - sz) ** 2 + (sz - sx) ** 2) + 3 * (sxy ** 2 + syz ** 2 + szx ** 2))


def read_result(frd):
    """CalculiX .frd -> node ids, coordinates, von Mises (MPa), |u| (mm), u (n x 3) at the nodes that have results"""
    from .solver import read_frd_full
    xyz, stress, disp = read_frd_full(frd)
    ids = sorted(n for n in stress if n in xyz)
    X = np.array([xyz[n][:3] for n in ids])
    vm = von_mises([stress[n][:6] for n in ids])
    U = np.array([disp.get(n, [0, 0, 0])[:3] for n in ids])
    return {'ids': np.array(ids), 'xyz': X, 'vm': vm, 'u': U, 'umag': np.linalg.norm(U, axis=1)}


def write_vtk(path, xyz, fields, title='ShipBrain result'):
    """legacy ASCII .vtk point cloud with scalar fields (opens in ParaView)"""
    n = len(xyz)
    with open(path, 'w') as f:
        f.write(f'# vtk DataFile Version 3.0\n{title}\nASCII\nDATASET POLYDATA\nPOINTS {n} float\n')
        for p in xyz:
            f.write(f'{p[0]:.6g} {p[1]:.6g} {p[2]:.6g}\n')
        f.write(f'VERTICES {n} {2 * n}\n' + ''.join(f'1 {i}\n' for i in range(n)))
        f.write(f'POINT_DATA {n}\n')
        for name, v in fields.items():
            f.write(f'SCALARS {name} float 1\nLOOKUP_TABLE default\n' + '\n'.join(f'{x:.6g}' for x in v) + '\n')
    return path


# ====================================================================== parametric problems
PLATE_PARAMS = {'L': 'plate length (mm)', 'B': 'plate breadth (mm)', 't': 'thickness (mm)', 'p': 'lateral pressure (MPa)'}


def _subst(obj, params):
    """template spec: any string "$name" (or a list item) is replaced by params[name]"""
    if isinstance(obj, str) and obj.startswith('$') and obj[1:] in params:
        return float(params[obj[1:]])
    if isinstance(obj, list):
        return [_subst(x, params) for x in obj]
    if isinstance(obj, dict):
        return {k: _subst(v, params) for k, v in obj.items()}
    return obj


def plate_template(edge='clamped', divisions=20):
    dof = '123456' if edge == 'clamped' else '3'
    fx = [{'x': 0, 'dof': dof}, {'x': '$L', 'dof': dof}, {'y': 0, 'dof': dof}, {'y': '$B', 'dof': dof}]
    if edge != 'clamped':
        fx += [{'x': 0, 'y': 0, 'dof': '12'}, {'x': '$L', 'y': 0, 'dof': '2'}]
    return {'element_size': '$h', 'fix': fx, 'loads': [{'plates': ['P'], 'pressure': '$p'}],
            'plates': [{'id': 'P', 't': '$t', 'outline': [[0, 0, 0], ['$L', 0, 0], ['$L', '$B', 0], [0, '$B', 0]]}],
            '_divisions': divisions}


def solve_case(template, params, workdir, name):
    """one real run: substitute the parameters, mesh with the own mesher, solve with CalculiX -> read_result dict"""
    from .platemesh import build_plates
    from .solver import run_calculix
    p = dict(params)
    if '$h' in json.dumps(template) and 'h' not in p:
        div = template.get('_divisions', 16)
        p['h'] = min(p.get('L', 1000.0), p.get('B', 1000.0)) / div
    spec = _subst({k: v for k, v in template.items() if not k.startswith('_')}, p)
    spec['name'] = name
    os.makedirs(workdir, exist_ok=True)
    build_plates(spec, workdir, formats=('inp',))
    r = run_calculix(os.path.join(workdir, name + '.inp'))
    res = read_result(r['frd'])
    res['frd'] = r['frd']
    return res


def latin_hypercube(ranges, n, seed=0):
    from scipy.stats import qmc
    keys = list(ranges)
    u = qmc.LatinHypercube(d=len(keys), seed=seed).random(n)
    out = []
    for row in u:
        d = {}
        for k, x in zip(keys, row):
            lo, hi = ranges[k]
            d[k] = float(lo * (hi / lo) ** x) if lo > 0 and hi / lo > 4 else float(lo + (hi - lo) * x)   # wide range: log spacing
        out.append(d)
    return out


# ====================================================================== the surrogate
def _tps(r):
    with np.errstate(divide='ignore', invalid='ignore'):
        v = r * r * np.log(r)
    return np.nan_to_num(v)


class RBF:
    """thin-plate-spline RBF with a linear polynomial (exact for linear data), small smoothing for stability"""
    def __init__(self, X, Y, smooth=1e-9):
        X, Y = np.asarray(X, float), np.asarray(Y, float)
        n, d = X.shape
        K = _tps(np.linalg.norm(X[:, None] - X[None], axis=2)) + smooth * np.eye(n)
        P = np.hstack([np.ones((n, 1)), X])
        A = np.block([[K, P], [P.T, np.zeros((d + 1, d + 1))]])
        rhs = np.vstack([Y.reshape(n, -1), np.zeros((d + 1, Y.reshape(n, -1).shape[1]))])
        sol = np.linalg.lstsq(A, rhs, rcond=None)[0]
        self.X, self.w, self.c = X, sol[:n], sol[n:]

    def __call__(self, x):
        x = np.atleast_2d(np.asarray(x, float))
        K = _tps(np.linalg.norm(x[:, None] - self.X[None], axis=2))
        return K @ self.w + np.hstack([np.ones((len(x), 1)), x]) @ self.c


class Surrogate:
    """POD + RBF reduced-order model of a parametric FE problem (see module doc)"""
    def __init__(self, keys, ranges):
        self.keys, self.ranges = list(keys), {k: list(map(float, ranges[k])) for k in keys}
        self.runs = []                      # {'params', 'xyz', 'vm', 'umag'}
        self.meta = {}

    # ---- inputs: log of positive parameters, scaled to 0..1 over the trained range
    def _x(self, params):
        out = []
        for k in self.keys:
            lo, hi = self.ranges[k]
            v = float(params[k])
            if lo > 0 and v > 0:
                out.append((math.log(v) - math.log(lo)) / ((math.log(hi) - math.log(lo)) or 1))
            else:
                out.append((v - lo) / ((hi - lo) or 1))
        return np.array(out)

    def _params(self, x):
        """inverse of _x"""
        out = {}
        for k, v in zip(self.keys, x):
            lo, hi = self.ranges[k]
            v = min(max(float(v), 0.0), 1.0)
            out[k] = math.exp(math.log(lo) + v * (math.log(hi) - math.log(lo))) if lo > 0 else lo + v * (hi - lo)
        return out

    def add(self, params, res):
        self.runs.append({'params': {k: float(params[k]) for k in self.keys}, 'xyz': np.asarray(res['xyz'], float),
                          'vm': np.asarray(res['vm'], float), 'umag': np.asarray(res['umag'], float)})

    def _reference(self):
        """reference points: the first run's nodes in normalised (0..1 bounding box) coordinates"""
        X = self.runs[0]['xyz']
        lo, hi = X.min(0), X.max(0)
        live = (hi - lo) > 1e-9 * max(1.0, float(np.abs(X).max()))
        return (X[:, live] - lo[live]) / (hi - lo)[live], live

    def _on_ref(self, run, ref, live):
        """a run's fields mapped onto the reference points (inverse-distance of the 4 nearest nodes, normalised coords)"""
        from scipy.spatial import cKDTree
        X = run['xyz']
        lo, hi = X.min(0), X.max(0)
        Xn = (X[:, live] - lo[live]) / np.where((hi - lo)[live] > 0, (hi - lo)[live], 1)
        d, i = cKDTree(Xn).query(ref, k=min(4, len(Xn)))
        d, i = np.atleast_2d(d), np.atleast_2d(i)
        w = 1 / np.maximum(d, 1e-12) ** 2
        w /= w.sum(1, keepdims=True)
        return {f: np.sum(run[f][i] * w, 1) for f in ('vm', 'umag')}

    def fit(self, energy=0.9999):
        ref, live = self._reference()
        self._ref, self._live = ref, live
        Xin = np.array([self._x(r['params']) for r in self.runs])
        F = [self._on_ref(r, ref, live) for r in self.runs]
        self.models = {}
        for f in ('vm', 'umag'):
            Y = np.array([g[f] for g in F])
            peak = np.maximum(Y.max(1), 1e-30)
            shape = Y / peak[:, None]                       # field shape (0..1) and its peak, learned separately
            mean = shape.mean(0)
            U, S, Vt = np.linalg.svd(shape - mean, full_matrices=False)
            cum = np.cumsum(S ** 2) / max(np.sum(S ** 2), 1e-30)
            r = int(np.searchsorted(cum, energy) + 1) if len(S) else 0
            r = max(1, min(r, len(S)))
            coef = (shape - mean) @ Vt[:r].T
            sm, loo = _best_smoothing(Xin, np.log(peak))
            self.models[f] = {'mean': mean, 'modes': Vt[:r], 'coef_rbf': RBF(Xin, coef, sm), 'peak_rbf': RBF(Xin, np.log(peak)[:, None], sm),
                              'n_modes': r, 'energy': float(cum[r - 1]) if len(cum) else 1.0, 'smoothing': sm, 'loo': loo}
        self.Xin = Xin
        self.validate()
        return self

    def validate(self):
        """leave-one-out errors of the peak values (computed while choosing the smoothing in fit)"""
        n = len(self.runs)
        if n < 5:
            self.meta['loo'] = None
            return None
        self.meta['loo'] = {f + '_peak': {'mean_pct': round(100 * float(np.mean(m['loo'])), 3),
                                          'max_pct': round(100 * float(np.max(m['loo'])), 3)} for f, m in self.models.items()}
        self.meta['smoothing'] = {f: m['smoothing'] for f, m in self.models.items()}
        dists = np.linalg.norm(self.Xin[:, None] - self.Xin[None], axis=2) + np.eye(n) * 1e9
        self.meta['spacing'] = float(np.median(dists.min(1)))
        return self.meta['loo']

    def predict(self, params, tol_pct=5.0):
        x = self._x(params)
        out = {'params': {k: float(params[k]) for k in self.keys}}
        for f in ('vm', 'umag'):
            m = self.models[f]
            shape = m['mean'] + m['coef_rbf'](x)[0] @ m['modes']
            peak = float(np.exp(m['peak_rbf'](x)[0, 0]))
            out[f] = np.clip(shape, 0, None) * peak / max(float(np.clip(shape, 0, None).max()), 1e-30)
            out[f + '_max'] = peak
        # error estimate: the leave-one-out errors of the 3 nearest training runs (local accuracy), growing with the
        # distance to them; outside the trained range = extrapolation, never trusted
        dist = np.linalg.norm(self.Xin - x, axis=1)
        near = np.argsort(dist)[:3]
        loo = np.asarray(self.models['vm'].get('loo') or [0.05] * len(dist))
        sp = max(self.meta.get('spacing', 0.1), 1e-6)
        est = 100 * float(np.mean(loo[near])) * (0.5 + float(dist[near[0]]) / sp)
        inside = bool(np.all(x >= -1e-9) and np.all(x <= 1 + 1e-9))
        out.update(error_estimate_pct=round(est, 2), inside_range=inside, confident=inside and est <= tol_pct)
        return out

    # ---- save / load / C++ export
    def save(self, path):
        arr = {'Xin': self.Xin, 'ref': self._ref, 'live': self._live}
        for f, m in self.models.items():
            arr.update({f'{f}_mean': m['mean'], f'{f}_modes': m['modes'], f'{f}_cX': m['coef_rbf'].X, f'{f}_cw': m['coef_rbf'].w,
                        f'{f}_cc': m['coef_rbf'].c, f'{f}_pw': m['peak_rbf'].w, f'{f}_pc': m['peak_rbf'].c})
        for i, r in enumerate(self.runs):
            arr.update({f'run{i}_xyz': r['xyz'], f'run{i}_vm': r['vm'], f'run{i}_umag': r['umag']})
        meta = dict(self.meta, keys=self.keys, ranges=self.ranges, params=[r['params'] for r in self.runs],
                    n_modes={f: m['n_modes'] for f, m in self.models.items()},
                    loo_runs={f: [float(v) for v in m.get('loo', [])] for f, m in self.models.items()})
        np.savez_compressed(path, meta=json.dumps(meta), **arr)
        return path

    @classmethod
    def load(cls, path):
        z = np.load(path, allow_pickle=False)
        meta = json.loads(str(z['meta']))
        s = cls(meta['keys'], meta['ranges'])
        s.meta = {k: v for k, v in meta.items() if k not in ('keys', 'ranges', 'params', 'n_modes', 'loo_runs')}
        for i, p in enumerate(meta['params']):
            s.runs.append({'params': p, 'xyz': z[f'run{i}_xyz'], 'vm': z[f'run{i}_vm'], 'umag': z[f'run{i}_umag']})
        s.Xin, s._ref, s._live = z['Xin'], z['ref'], z['live']
        s.models = {}
        for f in ('vm', 'umag'):
            c, p = RBF.__new__(RBF), RBF.__new__(RBF)
            c.X, c.w, c.c = z[f'{f}_cX'], z[f'{f}_cw'], z[f'{f}_cc']
            p.X, p.w, p.c = z[f'{f}_cX'], z[f'{f}_pw'], z[f'{f}_pc']
            s.models[f] = {'mean': z[f'{f}_mean'], 'modes': z[f'{f}_modes'], 'coef_rbf': c, 'peak_rbf': p,
                           'n_modes': int(meta['n_modes'][f]), 'loo': meta.get('loo_runs', {}).get(f, [])}
        return s

    def export_cpp(self, path, name='ShipBrainSurrogate'):
        """header-only C++ (no dependencies): peak von Mises and peak displacement from the parameters"""
        def arr(a):
            return '{' + ', '.join(f'{float(v):.17g}' for v in np.ravel(a)) + '}'
        n, d = self.Xin.shape
        lo = [self.ranges[k][0] for k in self.keys]
        hi = [self.ranges[k][1] for k in self.keys]
        logs = [1 if (lo[i] > 0) else 0 for i in range(d)]
        body = [f'// generated by ShipBrain: surrogate of a parametric FE study ({n} runs)',
                f'// inputs (in this order): {", ".join(self.keys)}; outputs: peak von Mises (MPa), peak |u| (mm)',
                '#pragma once', '#include <cmath>', f'namespace {name} {{',
                f'static const int N = {n}, D = {d};', f'static const double X[N*D] = {arr(self.Xin)};',
                f'static const double LO[D] = {arr(lo)}, HI[D] = {arr(hi)};', f'static const int LOGS[D] = {{{", ".join(map(str, logs))}}};']
        for f in ('vm', 'umag'):
            m = self.models[f]['peak_rbf']
            body += [f'static const double W_{f}[N] = {arr(m.w)};', f'static const double C_{f}[D+1] = {arr(m.c)};']
        body += ['inline double rbf(const double* x, const double* W, const double* C) {',
                 '  double s = C[0];', '  for (int k = 0; k < D; ++k) s += C[k + 1] * x[k];',
                 '  for (int i = 0; i < N; ++i) { double r2 = 0; for (int k = 0; k < D; ++k) { double t = x[k] - X[i*D+k]; r2 += t*t; }',
                 '    if (r2 > 0) s += W[i] * 0.5 * r2 * std::log(r2); }', '  return s; }',
                 'inline void normalise(const double* p, double* x) {',
                 '  for (int k = 0; k < D; ++k) x[k] = LOGS[k] ? (std::log(p[k]) - std::log(LO[k])) / (std::log(HI[k]) - std::log(LO[k]))',
                 '                                  : (p[k] - LO[k]) / (HI[k] - LO[k]); }',
                 'inline double peakVonMises(const double* p) { double x[D]; normalise(p, x); return std::exp(rbf(x, W_vm, C_vm)); }',
                 'inline double peakDisplacement(const double* p) { double x[D]; normalise(p, x); return std::exp(rbf(x, W_umag, C_umag)); }',
                 '}  // namespace']
        with open(path, 'w') as fh:
            fh.write('\n'.join(body) + '\n')
        return path


def _next_point(s, rng, n_cand=4000):
    """where to run next: far from the existing runs AND where the nearby runs are predicted badly
    (score = distance to the nearest run x (local leave-one-out error + 1 %)): fills gaps and refines bad regions"""
    C = rng.random((n_cand, s.Xin.shape[1]))
    D = np.linalg.norm(C[:, None] - s.Xin[None], axis=2)
    near = np.argsort(D, 1)[:, :3]
    loo = np.asarray(s.models['vm']['loo'])
    score = D.min(1) * (loo[near].mean(1) + 0.01)
    return C[int(np.argmax(score))]


def _loo(X, y, smooth):
    n = len(X)
    e = []
    for j in range(n):
        keep = [i for i in range(n) if i != j]
        pred = RBF(X[keep], y[keep][:, None], smooth)(X[j])[0, 0]
        e.append(abs(math.exp(pred - y[j]) - 1))
    return e


def _best_smoothing(X, y, grid=(1e-9, 1e-4, 1e-3, 1e-2, 3e-2, 0.1, 0.3, 1.0)):
    """FE peaks carry mesh noise (where the nodes fall): pick the smoothing with the lowest leave-one-out error"""
    if len(X) < 5:
        return 1e-9, [0.0]
    best = None
    for sm in grid:
        e = _loo(X, y, sm)
        if best is None or np.mean(e) < np.mean(best[1]):
            best = (sm, e)
    return best


def build(template, ranges, n, workdir, name='surrogate', seed=0, log=print, target_pct=3.0, max_runs=None):
    """run the study and train the surrogate -> Surrogate.
    Adaptive: after the first n runs, a new real run is added between the worst-predicted run (leave-one-out) and its
    nearest neighbour, until the mean leave-one-out error of the peak stress is below target_pct or max_runs is reached."""
    s = Surrogate(list(ranges), ranges)
    t0 = time.time()
    max_runs = max_runs or 2 * n
    work = os.path.join(workdir, name + '_runs')

    def run(p, tag):
        res = solve_case(template, p, work, f'{name}_{len(s.runs):03d}')
        s.add(p, res)
        log and log(f'{tag} run {len(s.runs)}: ' + ', '.join(f'{k}={v:.4g}' for k, v in p.items()) + f' -> max vM {res["vm"].max():.1f} MPa')
    for p in latin_hypercube(ranges, n, seed):
        run(p, 'study')
    s.fit()
    added = 0
    rng_np = np.random.default_rng(seed + 1)
    while len(s.runs) < max_runs and s.meta.get('loo') and s.meta['loo']['vm_peak']['mean_pct'] > target_pct:
        run(s._params(_next_point(s, rng_np)), 'adaptive')
        added += 1
        s.fit()
    s.meta.update(template=template, seconds_per_solve=round((time.time() - t0) / max(len(s.runs), 1), 2), name=name,
                  study_runs=n, adaptive_runs=added)
    return s


# ====================================================================== insight from one result
def insight(frd, yield_MPa=235.0, safety=1.0, baseline=None, inp=None, top_frac=0.9):
    """hotspots, utilisation, refinement flags, baseline comparison, report draft"""
    r = read_result(frd)
    X, vm = r['xyz'], r['vm']
    vmax = float(vm.max())
    i_max = int(np.argmax(vm))
    allow = yield_MPa / safety
    # hotspot clusters: nodes above top_frac * max, joined when closer than 3 x typical node spacing
    from scipy.spatial import cKDTree
    tree = cKDTree(X)
    dnn = tree.query(X, k=min(5, len(X)))[0][:, -1]          # 4th neighbour: in-plane spacing (shells have top/bottom points)
    hsel = np.nonzero(vm >= top_frac * vmax)[0]
    parent = {int(i): int(i) for i in hsel}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    rad = 3 * float(np.median(dnn))
    sub = cKDTree(X[hsel]) if len(hsel) else None
    if sub is not None:
        for a, b in sub.query_pairs(rad):
            parent[find(int(hsel[a]))] = find(int(hsel[b]))
    clusters = {}
    for i in hsel:
        clusters.setdefault(find(int(i)), []).append(int(i))
    hot = sorted(({'peak_MPa': round(float(vm[c].max()), 2), 'at': X[c[int(np.argmax(vm[c]))]].round(2).tolist(), 'nodes': len(c),
                   'utilisation': round(float(vm[c].max()) / allow, 3)} for c in clusters.values()), key=lambda h: -h['peak_MPa'])
    out = {'max_von_mises_MPa': round(vmax, 2), 'at': X[i_max].round(2).tolist(), 'max_displacement_mm': round(float(r['umag'].max()), 4),
           'allowable_MPa': round(allow, 2), 'utilisation': round(vmax / allow, 3), 'pass': bool(vmax <= allow), 'hotspots': hot[:8]}
    # refinement: elements whose nodal von Mises varies a lot inside the element, in the highly stressed region
    inp = inp or (frd[:-4] + '.inp')
    if os.path.exists(inp):
        try:
            from .femodel import FEModel, DIM
            m = FEModel.read(inp)
            idx = {int(n): k for k, n in enumerate(r['ids'])}
            flags = []
            for eid, e in m.elems.items():
                if DIM.get(e['type']) != 2:
                    continue
                v = [vm[idx[n]] for n in e['nodes'] if n in idx]
                if len(v) < 3 or max(v) < 0.5 * vmax:
                    continue
                jump = (max(v) - min(v)) / vmax
                if jump > 0.2:
                    P = np.array([m.nodes[n] for n in e['nodes']])
                    h = float(np.max(np.linalg.norm(P - np.roll(P, 1, 0), axis=1)))
                    flags.append({'element': eid, 'jump_pct': round(100 * jump, 1), 'size_mm': round(h, 1),
                                  'suggested_size_mm': round(h / math.ceil(jump / 0.1), 1)})
            flags.sort(key=lambda f: -f['jump_pct'])
            out['refine'] = {'elements_to_refine': len(flags), 'worst': flags[:8]}
        except Exception as ex:
            out['refine'] = {'note': f'mesh not read: {ex}'}
    if baseline:
        b = read_result(baseline)
        d, j = cKDTree(b['xyz']).query(X)
        ok = d <= max(1e-6, 0.5 * float(np.median(dnn)))
        diff = np.where(ok, vm - b['vm'][j], 0.0)
        k = int(np.argmax(np.abs(diff)))
        out['vs_baseline'] = {'matched_nodes_pct': round(100 * float(ok.mean()), 1), 'baseline_max_MPa': round(float(b['vm'].max()), 2),
                              'max_change_MPa': round(float(diff[k]), 2), 'at': X[k].round(2).tolist(),
                              'peak_change_pct': round(100 * (vmax / max(float(b['vm'].max()), 1e-30) - 1), 2)}
    out['report_draft'] = report_text(out)
    out['vtk'] = write_vtk(frd[:-4] + '_result.vtk', X, {'von_mises_MPa': vm, 'displacement_mm': r['umag']})
    return out


def report_text(s):
    """structured result -> short report draft (an engineer reviews it)"""
    lines = [f"Maximum von Mises stress {s['max_von_mises_MPa']} MPa at {s['at']} mm; maximum displacement {s['max_displacement_mm']} mm.",
             f"Allowable {s['allowable_MPa']} MPa: utilisation {s['utilisation']} -> {'PASS' if s['pass'] else 'FAIL'}."]
    if s.get('hotspots'):
        lines.append(f"{len(s['hotspots'])} hotspot area(s) above 90 % of the peak; the highest is {s['hotspots'][0]['peak_MPa']} MPa.")
    rf = s.get('refine') or {}
    if rf.get('elements_to_refine'):
        w = rf['worst'][0]
        lines.append(f"{rf['elements_to_refine']} element(s) in the highly stressed area change a lot inside the element "
                     f"(up to {w['jump_pct']} %): refine there to about {w['suggested_size_mm']} mm and check that the peak converges.")
    elif 'elements_to_refine' in rf:
        lines.append('The mesh looks fine enough in the highly stressed area.')
    vb = s.get('vs_baseline')
    if vb:
        lines.append(f"Compared with the baseline the peak changed by {vb['peak_change_pct']} % (largest local change {vb['max_change_MPa']} MPa "
                     f"at {vb['at']} mm).")
    return ' '.join(lines)
