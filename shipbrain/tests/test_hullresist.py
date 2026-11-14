import math, os, random, numpy as np, pytest
from shipbrain import hullgen as H, hullresist as HR, vesselbridge as VB

pytestmark = pytest.mark.skipif(VB.node() is None, reason='Node.js not installed')
P = dict(L=120, B=20, D=11, T=7.5, r_bilge=1.5, ent=0.35, run=0.25, n_ent=2, n_run=2.5, transom=0.3)


def test_holtrop_power_is_resistance_times_speed_and_rises_with_speed():
    rows = HR.holtrop(H.params(**P), fns=[0.14, 0.18, 0.22, 0.26])
    for r in rows:
        assert r['Pe_kW'] == pytest.approx(r['Rt_kN'] * r['speed_kn'] * 0.514444, rel=2e-3)
    assert all(b['Rt_kN'] > a['Rt_kN'] for a, b in zip(rows, rows[1:]))
    assert 100 < rows[1]['Rt_kN'] < 2000                                         # hundreds of kN for a 120 m ship at 12 kn


def test_holtrop_refuses_outside_its_range_and_a_bulb_changes_the_answer():
    with pytest.raises(ValueError, match='outside the range'):
        HR.holtrop(H.params(**dict(P, B=40, T=7.5)), fns=[0.2])                  # L/B = 3 < 3.9
    with pytest.raises(ValueError, match='Froude'):
        HR.holtrop(H.params(**P), fns=[0.5])
    a = HR.holtrop(H.params(**P), fns=[0.22])[0]['Rt_kN']
    b = HR.holtrop(H.params(**dict(P, bulb_len=3.5, bulb_b=6, bulb_h=6, bulb_z=3.5)), fns=[0.22])[0]['Rt_kN']
    assert abs(a - b) / a > 0.001


def test_surrogate_error_on_unseen_hulls_matches_what_it_claims():
    if not os.path.exists(HR.MODEL_PATH):
        pytest.skip('surrogate not trained')
    claim = HR.Surrogate.load().meta['mean_error_percent']
    rng = random.Random(4242)                                                     # hulls that are not in the training set
    errs = []
    while len(errs) < 120:
        p = H.random_hull(rng, 'ship')
        c = H.coefficients(p, nx=201, nz=61)
        if HR.validity(p, c):
            continue
        fns = [0.18, 0.26]
        ex = HR.holtrop(p, fns=fns, c=c, check_range=False)
        sg, meta, _ = HR.predict(p, fns=fns)
        errs += [abs(s['Rt_kN'] / e['Rt_kN'] - 1) * 100 for s, e in zip(sg, ex)]
    assert np.mean(errs) < max(2.5 * claim, 6.0)                                  # in line with the error the model reports about itself
    assert np.median(errs) < 4.0


def test_the_shipped_dataset_and_tool(tmp_path):
    import gzip, csv
    f = os.path.join(os.path.dirname(HR.__file__), '..', 'training', 'data', 'hull_resistance_dataset.csv.gz')
    rows = list(csv.DictReader(gzip.open(f, 'rt')))
    assert len(rows) >= 5000 and {'Rt_kN', 'Cb', 'Fn', 'bulb_len'} <= set(rows[0])
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('hull_resistance', dict(P, speeds_kn=[12, 14]))
    assert 'error' not in r and len(r['results']) == 2 and 'Holtrop' in r['plain_english']
    s = T.call('hull_resistance', dict(P, speeds_kn=[12, 14], method='surrogate'))
    assert abs(s['results'][0]['Rt_kN'] / r['results'][0]['Rt_kN'] - 1) < 0.15
    assert 'outside the range' in T.call('hull_resistance', dict(P, B=40, speeds_kn=[12]))['error']
