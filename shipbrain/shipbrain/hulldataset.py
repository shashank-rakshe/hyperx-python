"""
A dataset of random valid ship hulls with their hydrostatics, stability and resistance, all computed by ShipBrain's own tools (hullgen, stability, hullresist / Vessel.js):

    python -m shipbrain.hulldataset --n 2000 --seed 1 --out training/data/hull_dataset.csv.gz

Per hull: the 16 hull parameters; Cb, Cp, Cm, Cwp, LCB, KB, BMt, wetted area; GM and the GZ curve summary at KG = 0.6 D (maximum GZ and its angle, GZ at 30 degrees, the angle at which the lee deck edge
goes under); and, where Holtrop's range holds, the resistance at Fn 0.18 and 0.24. Nothing in it comes from a third-party dataset.
"""
import argparse, csv, gzip, math, random

import numpy as np

from . import hullgen as H, stability as ST, hullresist as HR, seakeeping as SK


def row(p, with_resistance=True):
    c = H.coefficients(p, nx=201, nz=61)
    kg = 0.6 * p['D']
    r = {k: round(float(v), 5) for k, v in p.items()}
    r.update({k: round(float(c[k]), 5) for k in ('Cb', 'Cp', 'Cm', 'Cwp', 'LCB_percent_L', 'KB_m', 'wetted_area_m2', 'volume_m3')})
    res = ST.gz_curve(p, kg, nx=61, nz=121, heels=list(np.arange(0.0, 90.1, 5.0)))
    gz = np.array([x['GZ_m'] for x in res['curve']])
    ang = np.array([x['heel_deg'] for x in res['curve']])
    imm = [x['heel_deg'] for x in res['curve'] if x['deck_edge_clearance_m'] <= 0]
    r.update({'KG_m': round(kg, 4), 'GM_m': round(float(res['GM_from_slope_m']), 4), 'GZmax_m': round(float(gz.max()), 4), 'GZmax_angle_deg': float(ang[int(gz.argmax())]),
              'GZ30_m': round(float(np.interp(30.0, ang, gz)), 4), 'deck_edge_deg': float(imm[0]) if imm else None})
    try:
        per = SK.periods(p, kg, nx=201, nz=61)
        r.update({'roll_period_s': round(per['roll_period_imo_s'], 3) if per['roll_period_imo_s'] else None, 'heave_period_s': round(per['heave_period_s'], 3), 'pitch_period_s': round(per['pitch_period_s'], 3)})
    except Exception:
        pass
    if with_resistance and not HR.validity(p, c):
        try:
            for fn in (0.18, 0.24):
                x = HR.holtrop(p, fns=[fn], c=c, check_range=False)[0]
                r[f'Rt_kN_Fn{int(fn * 100)}'] = x['Rt_kN']
        except Exception:
            pass
    return r


def make(n, seed=0, log=None):
    rng = random.Random(seed)
    rows = []
    while len(rows) < n:
        p = H.random_hull(rng, 'ship')
        try:
            rows.append(row(p))
        except Exception:
            continue
        if log and len(rows) % 200 == 0:
            log(f'{len(rows)} hulls')
    return rows


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=2000)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--out', default='training/data/hull_dataset.csv.gz')
    a = ap.parse_args()
    rows = make(a.n, a.seed, print)
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    op = gzip.open if a.out.endswith('.gz') else open
    with op(a.out, 'wt', newline='') as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    print(a.out, len(rows), 'hulls,', len(keys), 'columns')
