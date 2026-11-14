import math, pytest
from shipbrain import hullgen as H, stability as S

BOX = dict(L=30, B=8, D=4, T=2.0, r_bilge=0, ent=0.02, run=0.02, n_ent=1, n_run=1, transom=1.0)


def test_gz_of_a_barge_follows_the_wall_sided_formula():
    L, B, D, m, kg = 30.0, 8.0, 4.0, 600.0, 1.5
    cb = H.coefficients(H.params(**BOX), T=2.0)['Cb']
    T = m * 1000 / 1025 / (L * B * cb)                                         # the hull is a box with tiny end tapers: use its own Cb
    BM = cb * 0 + B * B / (12 * T)
    res = S.gz_curve(H.params(**BOX), kg, mass_t=m)
    GM = res['GM_from_slope_m']
    assert GM == pytest.approx(T / 2 + BM - kg, rel=0.03)
    for r in res['curve']:
        a = math.radians(r['heel_deg'])
        if 0 < r['heel_deg'] <= 17.5:                                          # before the deck edge (21 deg) goes under
            assert r['GZ_m'] == pytest.approx(math.sin(a) * (GM + 0.5 * BM * math.tan(a) ** 2), rel=0.03)
    edge = [r['heel_deg'] for r in res['curve'] if r['deck_edge_clearance_m'] <= 0][0]
    assert edge == pytest.approx(math.degrees(math.atan(2 * (D - T) / B)), abs=2.6)


def test_displacement_is_kept_at_every_angle_and_gz_is_odd():
    p = H.params(L=100, B=16, D=13, T=6, r_bilge=1.5, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.0)
    res = S.gz_curve(p, 6.5, heels=[0, 10, 20, 40, 60])
    assert all(r['volume_error_percent'] < 0.2 for r in res['curve'])
    a = S.gz_curve(p, 6.5, heels=[-20, 20])['curve']
    assert a[0]['GZ_m'] == pytest.approx(-a[1]['GZ_m'], abs=1e-6)


def test_raising_kg_lowers_gz_and_fails_the_criteria():
    p = H.params(L=100, B=16, D=13, T=6, r_bilge=1.5, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.0)
    good = S.criteria(S.gz_curve(p, 5.0))
    bad = S.criteria(S.gz_curve(p, 8.0))
    assert good['max_GZ_m'] > bad['max_GZ_m']
    assert good['all_pass'] and not bad['all_pass']
    fsm = S.gz_curve(p, 5.0, free_surface_m=0.4)
    assert fsm['curve'][5]['GZ_m'] < S.gz_curve(p, 5.0)['curve'][5]['GZ_m']


def test_a_sinking_hull_is_refused_and_the_tool_answers(tmp_path):
    with pytest.raises(ValueError, match='sinks'):
        S.gz_curve(H.params(**BOX), 1.5, mass_t=5000)
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('gz_curve', dict(L=100, B=16, D=13, T=6, r_bilge=1.5, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.0, kg=5.0))
    assert 'error' not in r and r['all_pass'] and (tmp_path / 'gz.png').stat().st_size > 3000 and 'IMO' in r['plain_english']


def test_low_freeboard_fails_because_the_deck_edge_goes_under_early():
    p = H.params(L=100, B=16, D=7.0, T=6, r_bilge=1.5, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.0)
    cr = S.criteria(S.gz_curve(p, 5.0))
    assert cr['deck_edge_immersion_deg'] < 15 and not cr['all_pass']                 # 1 m of freeboard on 16 m of beam: under water at about 14 degrees
