import math, pytest
from shipbrain import propeller as P


def test_zero_thrust_at_j_equal_pitch_ratio_for_flat_sections():
    for pd in (0.8, 1.0, 1.3):
        lo, hi = 0.05, 2.5
        for _ in range(45):
            m = (lo + hi) / 2
            if P.bem(m, pitch_ratio=pd, alpha0_deg=0.0, cd=0.0, stall_deg=30)['KT'] > 0:
                lo = m
            else:
                hi = m
        assert m == pytest.approx(pd, rel=0.01)                              # hydrodynamic pitch = geometric pitch when the section does not lift


def test_efficiency_never_exceeds_the_actuator_disk_limit_and_curves_are_monotonic():
    rows = [P.bem(J, pitch_ratio=1.0) for J in (0.1, 0.3, 0.5, 0.7, 0.9)]
    for r in rows:
        CT = 8 * r['KT'] / (math.pi * r['J'] ** 2)
        assert r['eta0'] <= 2 / (1 + math.sqrt(1 + CT)) + 1e-6
    assert all(a['KT'] > b['KT'] for a, b in zip(rows, rows[1:])) and all(a['KQ'] > b['KQ'] for a, b in zip(rows, rows[1:]))
    assert 0.35 < P.bem(0.0, pitch_ratio=1.0)['KT'] < 0.65                   # the right order for a P/D 1 four-blade propeller


def test_more_elements_converge_and_more_pitch_gives_more_thrust():
    a, b = P.bem(0.5, n=40)['KT'], P.bem(0.5, n=80)['KT']
    assert a == pytest.approx(b, rel=0.03)
    assert P.bem(0.5, pitch_ratio=1.2)['KT'] > P.bem(0.5, pitch_ratio=0.8)['KT']
    assert P.bem(0.5, ear=0.9)['KT'] > P.bem(0.5, ear=0.4)['KT']


def test_operating_point_is_consistent_and_momentum_identity_holds():
    op = P.performance(4.0, 120, 16, immersion_m=5.0)
    n, V = 2.0, 16 * 0.514444
    assert op['thrust_kN'] * 1000 == pytest.approx(op['KT'] * 1025 * n * n * 4.0 ** 4, rel=1e-9)
    assert op['eta0'] == pytest.approx(op['thrust_kN'] * 1000 * V / (op['power_kW'] * 1000), rel=1e-6)
    ad = P.actuator_disk(1000e3, 8.0, 4.0)
    CT = 1000e3 / (0.5 * 1025 * 64 * math.pi * 4)
    assert ad['ideal_efficiency'] == pytest.approx(2 / (1 + math.sqrt(1 + CT)), rel=1e-12) and ad['CT'] == pytest.approx(CT, rel=1e-12)
    assert 0 < op['cavitation_number_07R'] < 5


def test_tool(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('propeller_bem', {'D': 4.0, 'pitch_ratio': 1.0, 'rpm': 120, 'speed_kn': 16, 'immersion_m': 5.0})
    assert 'error' not in r and 'thrust' in r['plain_english'] and (tmp_path / 'propeller.png').stat().st_size > 3000
