import math, os, random, numpy as np, pytest
from shipbrain import hullgen as H, intake


def P(**kw):
    return H.params(**kw)


def test_bilge_and_deadrise_sections_match_closed_forms():
    for r in (1.0, 2.0):
        c = H.coefficients(P(L=30, B=8, D=4, T=2.4, r_bilge=r, ent=0.02, run=0.02, n_ent=1, n_run=1, transom=1.0))
        assert c['Cm'] == pytest.approx(1 - (2 - math.pi / 2) * r * r / (8 * 2.4), abs=2e-4)          # rounded bilge: two corners of (1 - pi/4) r2 missing
    for beta in (10, 20):
        c = H.coefficients(P(L=30, B=8, D=4, T=2.4, r_bilge=0, deadrise=beta, ent=0.02, run=0.02, n_ent=1, n_run=1, transom=1.0))
        assert c['Cm'] == pytest.approx(1 - 2 * 0.5 * 4 * 4 * math.tan(math.radians(beta)) / (8 * 2.4), abs=1e-4)


def test_waterplane_coefficient_is_the_exact_integral_of_the_plan_form():
    c = H.coefficients(P(L=100, B=16, D=9, T=6, r_bilge=1.5, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.4))
    assert c['Cwp'] == pytest.approx((1 - 0.3 - 0.25) + 0.3 * 2 / 3 + 0.25 * (0.4 + 0.6 * 3 / 4), abs=1e-4)
    assert c['Cp'] == pytest.approx(c['Cb'] / c['Cm'], rel=1e-9)


def test_symmetric_hull_has_lcb_at_midships_and_box_limit_cb_one():
    c = H.coefficients(P(L=60, B=10, D=5, T=3, r_bilge=0, ent=0.25, run=0.25, n_ent=2, n_run=2, transom=0.0))
    assert abs(c['LCB_percent_L']) < 0.01
    c = H.coefficients(P(L=30, B=8, D=4, T=2.4, r_bilge=0, ent=0.02, run=0.02, n_ent=1, n_run=1, transom=1.0))
    assert c['Cb'] > 0.98


def test_vessel_js_agrees_with_the_own_integration_on_the_same_hull():
    from shipbrain import vesselbridge as VB
    if VB.node() is None:
        pytest.skip('Node.js not installed')
    p = P(L=100, B=16, D=9, T=6, r_bilge=1.5, deadrise=5, flare=4, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.4, vee=0.8)
    c = H.coefficients(p)
    tab, bmax = H.vessel_table(p)
    spec = VB.make_spec(H.loa(p), bmax, p['D'], 'box', [{'mass_t': c['volume_m3'] * 1.025, 'cg': [c['LCB_m'], 0, 4.0]}], table=tab)
    h = VB.run(spec, drafts=[6.0])['hydrostatics'][0]
    assert h['Vs'] == pytest.approx(c['volume_m3'], rel=0.01) and h['KB'] == pytest.approx(c['KB_m'], rel=0.01)
    assert h['LCB'] == pytest.approx(c['LCB_m'], abs=0.3) and h['Awp'] == pytest.approx(c['Awp_m2'], rel=0.005)


@pytest.mark.parametrize('kw', [dict(), dict(transom=0.0, deadrise=8, flare=5), dict(bulb_len=3, bulb_b=5, bulb_h=5, bulb_z=2.5), dict(r_bilge=0, vee=2.0)])
def test_stl_is_watertight_and_has_the_right_volume(tmp_path, kw):
    p = P(L=100, B=16, D=9, T=6, **kw) if 'r_bilge' in kw else P(L=100, B=16, D=9, T=6, r_bilge=1.5, **kw)
    f = H.write_stl(p, str(tmp_path / 'h.stl'), nx=201, nz=61)
    d, _ = intake.describe_stl(f)
    assert d['closed']
    hull_only = dict(p, bulb_len=0.0)
    ref = H.coefficients(hull_only, T=p['D'], nx=801, nz=301)['volume_m3']
    if not kw.get('bulb_len'):
        assert d['volume'] == pytest.approx(ref, rel=0.012)


def test_target_cb_is_hit_or_refused_plainly():
    base = dict(H.DEFAULTS, L=120, B=20, D=11, T=7.5, ent=0.35, run=0.25)
    for t in (0.62, 0.7, 0.85):
        q = H.solve_cb(base, t)
        assert H.coefficients(q)['Cb'] == pytest.approx(t, abs=2e-3)
    with pytest.raises(ValueError, match='cannot be reached'):
        H.solve_cb(base, 0.2)


def test_invalid_hulls_are_refused_and_random_hulls_are_valid():
    for kw, msg in ((dict(T=12), 'deeper'), (dict(ent=0.7, run=0.5), 'longer'), (dict(r_bilge=9), 'bilge'), (dict(bulb_len=3, bulb_b=5, bulb_h=5, bulb_z=7), 'bulb'), (dict(zzz=1), 'unknown')):
        with pytest.raises(ValueError, match=msg):
            P(**kw)
    rng = random.Random(3)
    for _ in range(25):
        q = H.random_hull(rng)
        assert not H.check(q)
        assert 0.3 < H.coefficients(q, nx=101, nz=41)['Cb'] < 1.0


def test_tool_makes_a_hull_a_dataset_and_a_picture(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('hull_generate', {'L': 120, 'B': 20, 'D': 11, 'T': 7.5, 'ent': 0.3, 'run': 0.22, 'target_cb': 0.72, 'name': 'h'})
    assert 'error' not in r and r['stl']['closed'] and abs(r['coefficients']['Cb'] - 0.72) < 2e-3
    assert (tmp_path / 'h.png').stat().st_size > 3000
    assert 'cannot be reached' in T.call('hull_generate', {'L': 120, 'B': 20, 'D': 11, 'T': 7.5, 'ent': 0.3, 'run': 0.22, 'target_cb': 0.4})['error']
    d = T.call('hull_generate', {'samples': 20, 'name': 'd', 'seed': 2})
    assert d['hulls'] == 20 and (tmp_path / 'd_dataset.csv').read_text().count('\n') == 21


def test_wetted_area_matches_the_closed_form_and_the_stl_surface():
    p = P(L=30, B=8, D=4, T=2.4, r_bilge=0, ent=0.02, run=0.02, n_ent=1, n_run=1, transom=1.0)
    assert H.coefficients(p)['wetted_area_m2'] == pytest.approx(30 * (8 + 2 * 2.4), rel=0.04)       # bottom + two sides of a barge
    p = P(L=120, B=20, D=7.5, T=7.5, r_bilge=1.5, ent=0.35, run=0.25, n_ent=2, n_run=2.5, transom=0.0)
    V, F = H.stl_mesh(p, nx=241, nz=61)
    A, B_, C = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    ar = 0.5 * np.linalg.norm(np.cross(B_ - A, C - A), axis=1)
    flat = lambda ax, v: (abs(A[:, ax] - v) < 1e-6) & (abs(B_[:, ax] - v) < 1e-6) & (abs(C[:, ax] - v) < 1e-6)
    stl_wetted = ar[~(flat(2, 7.5) | flat(0, 0.0))].sum()
    assert H.coefficients(p)['wetted_area_m2'] == pytest.approx(stl_wetted, rel=0.02)
