import math, pytest
from shipbrain import hullgen as H, seakeeping as SK, dbb

BOX = dict(L=60, B=14, D=6, T=3.0, r_bilge=0, ent=0.02, run=0.02, n_ent=1, n_run=1, transom=1.0)


def test_periods_equal_the_closed_forms_for_a_barge():
    p = H.params(**BOX)
    per = SK.periods(p, kg=3.0)
    c = H.coefficients(p)
    M = c['volume_m3'] * 1025
    awp = 60 * 14 * c['Cwp']
    assert per['heave_period_s'] == pytest.approx(2 * math.pi * math.sqrt((M + 1025 * math.pi / 8 * 14 ** 2 * 60) / (1025 * 9.81 * awp)), rel=0.02)
    GM = 1.5 + 14 ** 2 / (12 * 3.0) - 3.0
    assert per['GMt_m'] == pytest.approx(GM, rel=0.02)
    C = 0.373 + 0.023 * 14 / 3.0 - 0.043 * 60 / 100
    assert per['roll_period_imo_s'] == pytest.approx(2 * C * 14 / math.sqrt(GM), rel=0.02)           # IS Code 2.3.4
    assert per['roll_period_k04B_s'] == pytest.approx(2 * math.pi * 0.4 * 14 / math.sqrt(9.81 * GM), rel=0.02)


def test_higher_gm_means_shorter_roll_period_and_unstable_ship_has_none():
    p = H.params(**BOX)
    assert SK.periods(p, 2.0)['roll_period_imo_s'] < SK.periods(p, 3.5)['roll_period_imo_s']
    assert SK.periods(p, 9.0)['roll_period_imo_s'] is None


def test_response_limits_and_resonance_flag():
    p = H.params(**BOX)
    long_wave = SK.response(p, 3.0, 40.0)                                    # very long wave: the hull follows the surface
    assert long_wave['heave']['rao'] == pytest.approx(1.0, abs=0.06)
    short = SK.response(p, 3.0, 2.5)
    assert short['heave']['rao'] < 0.2                                       # short waves: little heave (e^{-kT})
    per = SK.periods(p, 3.0)
    res = SK.response(p, 3.0, per['heave_period_s'])
    assert res['heave']['near_resonance'] and res['heave']['rao'] == pytest.approx(1 / (2 * 0.2) * math.exp(-(2 * math.pi / per['heave_period_s']) ** 2 / 9.81 * 3.0), rel=1e-6)      # 1 / (2 zeta) times e^{-kT}
    roll = SK.response(p, 3.0, per['roll_period_imo_s'])
    assert roll['roll']['rao'] == pytest.approx(1 / (2 * 0.07), rel=0.05)


def test_blocks_sum_to_weight_and_cg_and_requirements_have_statuses():
    blocks = [{'name': 'hold', 'group': 'cargo', 'shape': 'box', 'size': [30, 10, 5], 'density': 0.8, 'cg': [30, 0, 3.5], 'fullness': 0.9},
              {'name': 'engine', 'group': 'machinery', 'shape': 'box', 'size': [12, 10, 5], 'density': 0.35, 'cg': [8, 0, 3.0]},
              {'name': 'hull', 'group': 'structure', 'volume': 40, 'density': 1.9625, 'cg': [25, 0, 3.0]}]
    reqs = [{'name': 'cargo volume', 'metric': 'volume', 'direction': 'at_least', 'shall': 1200, 'should': 1400, 'group': 'cargo'},
            {'name': 'total weight', 'metric': 'total_weight', 'direction': 'at_most', 'shall': 900, 'should': 700},
            {'name': 'length', 'metric': 'length', 'direction': 'at_most', 'shall': 100}]
    r = dbb.analyse(blocks, reqs, hull={'L': 80, 'B': 14, 'D': 8})
    assert r['total_weight_t'] == pytest.approx(30 * 10 * 5 * 0.8 * 0.9 + 12 * 10 * 5 * 0.35 + 78.5, rel=1e-9)
    W = r['total_weight_t']
    assert r['cg'][0] == pytest.approx((1080 * 30 + 210 * 8 + 78.5 * 25) / W, abs=1e-3)
    st = {q['name']: q['status'] for q in r['requirements']}
    assert st == {'cargo volume': 'orange', 'total weight': 'red', 'length': 'green'}        # 1500 > should 1400: an excess; 1368 t > 900 t: shall missed
    assert len(r['weights_for_hydrostatics']) == 3
    with pytest.raises(ValueError, match='no weight'):
        dbb.analyse([{'name': 'void', 'volume': 10, 'density': 0.0}])


def test_blocks_feed_the_hydrostatics_and_tools_answer(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('dbb_blocks', {'blocks': [{'name': 'ship', 'volume': 400, 'density': 1.0, 'cg': [30, 0, 3.0]}], 'requirements': [{'name': 'weight', 'metric': 'total_weight', 'direction': 'at_most', 'shall': 500}]})
    assert 'error' not in r and 'All shall requirements are met' in r['plain_english']
    h = T.call('ship_hydrostatics', {'hull': 'box', 'length': 60, 'beam': 14, 'depth': 6, 'weights': r['weights_for_hydrostatics']})
    assert 'error' not in h and h['summary']['mass_t'] == pytest.approx(400, rel=1e-3)
    m = T.call('hull_motions', dict(BOX, kg=3.0, wave_period_s=8.0))
    assert 'error' not in m and 'roll' in m['plain_english'] and 'not a seakeeping program' in m['plain_english']
