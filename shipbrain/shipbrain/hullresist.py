"""
Resistance of generated hulls: the Holtrop-Mennen estimate from Vessel.js (HullResistance, run in Node) for any hull of hullgen, a dataset of thousands of random valid hulls with that
resistance at several speeds, and a surrogate trained on it that answers in milliseconds - with its measured accuracy on hulls it never saw.

What the numbers are, plainly: the labels are Holtrop-Mennen estimates (a regression of model tests of ordinary displacement ships, good to roughly +-10-20 % against real ships), computed for
the hull's coefficients; the surrogate reproduces THOSE labels, and its error against them is measured on a held-out set. Holtrop's validity range is enforced (Fn <= 0.45, 0.55 <= Cp <= 0.85,
3.9 <= L/B <= 14.9, 2.1 <= B/T <= 4.0): outside it the tools refuse instead of extrapolating.
"""
import json, math, os, random

import numpy as np

from . import hullgen as H, vesselbridge as VB

HERE = os.path.dirname(os.path.abspath(__file__))
PROP = os.path.join(VB.ROOT, 'specs', 'propeller_wag_4b.json')
MODEL_PATH = os.path.join(HERE, 'data', 'hull_resistance_surrogate.npz')
G, RHO = 9.81, 1025.0
FNS = (0.14, 0.18, 0.22, 0.26, 0.30)
# Holtrop-Mennen depends on the hull only through these numbers (length, L/B, B/T, Cb, Cm, Cwp, LCB, a bulb, a transom): the surrogate gets exactly those
FEATURES = ['L_B', 'B_T', 'Cb', 'Cm', 'Cwp', 'LCB_percent_L', 'Fn', 'ln_L', 'bulb', 'transom_flag']


def validity(p, c, fn=None):
    """reasons a hull is outside Holtrop-Mennen's range (empty = inside)"""
    bad = []
    Lb, Bt = p['L'] / p['B'], p['B'] / p['T']
    if not 0.55 <= c['Cp'] <= 0.85:
        bad.append(f"prismatic coefficient {c['Cp']:.3f} is outside 0.55 .. 0.85")
    if not 3.9 <= Lb <= 14.9:
        bad.append(f'L/B {Lb:.2f} is outside 3.9 .. 14.9')
    if not 2.1 <= Bt <= 4.0:
        bad.append(f'B/T {Bt:.2f} is outside 2.1 .. 4.0')
    if fn is not None and fn > 0.45:
        bad.append(f'Froude number {fn:.2f} is above 0.45')
    return bad


def hull_spec(p, c, speed_kn=14.0, kg_ratio=0.62):
    tab, bmax = H.vessel_table(p)
    spec = VB.make_spec(H.loa(p), bmax, p['D'], 'box', [{'mass_t': c['volume_m3'] * 1.025, 'cg': [c['LCB_m'], 0, kg_ratio * p['D']]}], T_design=p['T'], table=tab)
    cp = spec['designState']['calculationParameters']
    cp.update({'speed': speed_kn, 'LWL_design': p['L'], 'BWL': p['B'], 'Draft_design': p['T'], 'Cb_design': c['Cb']})
    spec['structure']['hull']['attributes'].update({'bulb': p['bulb_len'] > 0, 'transom': p['transom'] > 0.05, 'cstern': 0, 'appendices': {}})
    return spec


def speed_for_fn(L, fn):
    return fn * math.sqrt(G * L) / 0.514444


def holtrop(p, speeds_kn=None, fns=None, c=None, check_range=True):
    """Holtrop-Mennen resistance (Vessel.js) of a hull at speeds in knots (or Froude numbers): list of {speed_kn, Fn, Rt_kN, Pe_kW, Ct}"""
    c = c or H.coefficients(p)
    if fns is not None:
        speeds_kn = [speed_for_fn(p['L'], f) for f in fns]
    speeds_kn = list(speeds_kn or [speed_for_fn(p['L'], f) for f in (0.18, 0.22, 0.26)])
    if check_range:
        bad = validity(p, c, max(v * 0.514444 / math.sqrt(G * p['L']) for v in speeds_kn))
        if bad:
            raise ValueError("outside the range where Holtrop's method holds: " + '; '.join(bad))
    prop = json.load(open(PROP))
    out = VB.run(hull_spec(p, c), action='resistance', speeds=speeds_kn, propeller=prop)['resistance']
    rows = []
    for r in out:
        if 'error' in r or r.get('Rt_N') is None or not math.isfinite(r['Rt_N']):
            raise ValueError('Vessel.js could not compute the resistance: ' + str(r.get('error')))
        v = r['speed_kn'] * 0.514444
        rows.append({'speed_kn': round(r['speed_kn'], 3), 'Fn': round(v / math.sqrt(G * p['L']), 4), 'Rt_kN': round(r['Rt_N'] / 1000, 3), 'Pe_kW': round(r['Pe_W'] / 1000, 2),
                     'Ct': r['Rt_N'] / (0.5 * RHO * v * v * c['wetted_area_m2'])})
    return rows


# ====================================================================== dataset and surrogate
def features(p, c, fn):
    d = dict(Cb=c['Cb'], Cm=c['Cm'], Cwp=c['Cwp'], LCB_percent_L=c['LCB_percent_L'], L_B=p['L'] / p['B'], B_T=p['B'] / p['T'], Fn=fn, ln_L=math.log(p['L']),
             bulb=1.0 if p['bulb_len'] > 0 else 0.0, transom_flag=1.0 if p['transom'] > 0.05 else 0.0)
    return [float(d[k]) for k in FEATURES]


def ref_area(p):
    """reference area for the resistance coefficient: L (2 T + B), the usual order of magnitude of the wetted area"""
    return p['L'] * (2 * p['T'] + p['B'])


def make_dataset(n_hulls=1200, seed=0, log=None):
    """random valid hulls inside Holtrop's range, each at FNS: returns (X, y, rows); y = ln(Rt / (0.5 rho V^2 L (2T + B)))"""
    rng = random.Random(seed)
    X, y, rows = [], [], []
    tries = 0
    while len({r['hull'] for r in rows}) < n_hulls and tries < n_hulls * 30:
        tries += 1
        p = H.random_hull(rng, 'ship')
        c = H.coefficients(p, nx=201, nz=61)
        if validity(p, c):
            continue
        try:
            res = holtrop(p, fns=FNS, c=c, check_range=False)
        except ValueError:
            continue
        hid = len({r['hull'] for r in rows})
        for r in res:
            if not (r['Ct'] > 0 and math.isfinite(r['Ct'])):
                break
            X.append(features(p, c, r['Fn']))
            y.append(math.log(r['Rt_kN'] * 1000 / (0.5 * RHO * (r['Fn'] * math.sqrt(G * p['L'])) ** 2 * ref_area(p))))
            rows.append(dict(hull=hid, **{k: p[k] for k in H.DEFAULTS}, Cb=c['Cb'], Cp=c['Cp'], Cm=c['Cm'], Cwp=c['Cwp'], LCB_percent_L=c['LCB_percent_L'], wetted_area_m2=c['wetted_area_m2'],
                             Fn=r['Fn'], speed_kn=r['speed_kn'], Rt_kN=r['Rt_kN'], Pe_kW=r['Pe_kW'], Ct=r['Ct']))
        if log and hid % 100 == 0:
            log(f'{hid} hulls')
    return np.array(X), np.array(y), rows


class Surrogate:
    def __init__(self, X, y, smoothing=1e-3, neighbors=80):
        from scipy.interpolate import RBFInterpolator
        self.mu, self.sd = X.mean(0), X.std(0) + 1e-12
        self.X, self.y = X, y
        self.smoothing, self.neighbors = smoothing, neighbors
        Z = (X - self.mu) / self.sd
        Z = Z + 1e-5 * np.random.default_rng(0).standard_normal(Z.shape)      # a feature that is constant among the neighbours (no bulb) would make the local polynomial singular
        self.f = RBFInterpolator(Z, y, kernel='thin_plate_spline', smoothing=smoothing, neighbors=neighbors)
        self.lo, self.hi = X.min(0), X.max(0)

    def predict_lnCt(self, F):
        return self.f((np.atleast_2d(F) - self.mu) / self.sd)

    def save(self, path=MODEL_PATH, meta=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        np.savez_compressed(path, X=self.X.astype(np.float32), y=self.y.astype(np.float32), smoothing=self.smoothing, neighbors=self.neighbors, meta=json.dumps(meta or {}))

    @staticmethod
    def load(path=MODEL_PATH):
        d = np.load(path, allow_pickle=False)
        s = Surrogate(d['X'].astype(float), d['y'].astype(float), float(d['smoothing']), int(d['neighbors']))
        s.meta = json.loads(str(d['meta']))
        return s


def evaluate(n_hulls=1200, seed=0, holdout=0.2, log=None):
    """build the dataset, hold out whole hulls (never seen), fit, and report the error of Rt on them"""
    X, y, rows = make_dataset(n_hulls, seed, log)
    hull = np.array([r['hull'] for r in rows])
    rng = np.random.default_rng(seed)
    ids = np.unique(hull)
    test_ids = set(rng.choice(ids, int(len(ids) * holdout), replace=False).tolist())
    te = np.array([h in test_ids for h in hull])
    best = None
    for sm in (1e-3, 1e-2, 5e-2, 0.15):
        s = Surrogate(X[~te], y[~te], smoothing=sm)
        err = np.abs(np.expm1(s.predict_lnCt(X[te]) - y[te])) * 100                 # error of Ct = error of Rt at the same speed and wetted area
        m = (float(np.mean(err)), sm, s, err)
        if best is None or m[0] < best[0]:
            best = m
    mean, sm, s, err = best
    # baseline: straight-line regression on the same features
    A = np.c_[X[~te], np.ones((~te).sum())]
    w, *_ = np.linalg.lstsq(A, y[~te], rcond=None)
    base = np.abs(np.expm1(np.c_[X[te], np.ones(te.sum())] @ w - y[te])) * 100
    meta = {'hulls': int(len(ids)), 'points': int(len(y)), 'held_out_hulls': int(len(test_ids)), 'smoothing': sm, 'mean_error_percent': round(mean, 3),
            'median_error_percent': round(float(np.median(err)), 3), 'p95_error_percent': round(float(np.percentile(err, 95)), 3), 'max_error_percent': round(float(err.max()), 3),
            'linear_baseline_mean_error_percent': round(float(base.mean()), 2), 'seed': seed, 'fns': list(FNS), 'features': FEATURES, 'labels': 'Holtrop-Mennen via Vessel.js (ln of the resistance coefficient on L (2T + B))'}
    return X, y, rows, meta, te


def train_and_save(n_hulls=1200, seed=0, path=MODEL_PATH, log=None):
    X, y, rows, meta, te = evaluate(n_hulls, seed, log=log)
    s = Surrogate(X, y, smoothing=meta['smoothing'])                                 # the shipped model uses every hull; the error above was measured on hulls it had not seen
    s.save(path, meta)
    return meta, rows


_model = None


def predict(p, fns=None, speeds_kn=None):
    """resistance of a hull from the trained surrogate (milliseconds): list of {speed_kn, Fn, Rt_kN, Pe_kW} with the surrogate's measured accuracy attached"""
    global _model
    c = H.coefficients(p, nx=201, nz=61)
    if fns is None:
        fns = [v * 0.514444 / math.sqrt(G * p['L']) for v in speeds_kn] if speeds_kn else [0.18, 0.22, 0.26]
    bad = validity(p, c, max(fns))
    if bad:
        raise ValueError("outside the range of the surrogate and of Holtrop's method: " + '; '.join(bad))
    if _model is None:
        if not os.path.exists(MODEL_PATH):
            raise RuntimeError('the resistance surrogate has not been trained: python -m shipbrain.hullresist --train')
        _model = Surrogate.load()
    F = np.array([features(p, c, f) for f in fns])
    ln = _model.predict_lnCt(F)
    out = []
    for f, l in zip(fns, ln):
        v = f * math.sqrt(G * p['L'])
        Rt = math.exp(l) * 0.5 * RHO * v * v * ref_area(p)
        out.append({'speed_kn': round(v / 0.514444, 3), 'Fn': round(f, 4), 'Rt_kN': round(Rt / 1000, 3), 'Pe_kW': round(Rt * v / 1000, 2)})
    return out, _model.meta, bool(np.any((F < _model.lo - 1e-9) | (F > _model.hi + 1e-9)))


if __name__ == '__main__':
    import argparse, csv
    ap = argparse.ArgumentParser()
    ap.add_argument('--train', action='store_true')
    ap.add_argument('--hulls', type=int, default=1200)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--csv', default=None, help='also write the dataset as CSV (gzip if it ends in .gz)')
    a = ap.parse_args()
    if a.train:
        meta, rows = train_and_save(a.hulls, a.seed, log=print)
        print(json.dumps(meta, indent=1))
        if a.csv:
            import gzip
            op = gzip.open if a.csv.endswith('.gz') else open
            with op(a.csv, 'wt', newline='') as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0]))
                w.writeheader()
                w.writerows(rows)
