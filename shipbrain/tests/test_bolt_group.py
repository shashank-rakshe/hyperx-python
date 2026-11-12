import pytest
from shipbrain import bolt_group as B

COL = [[0, i * 76.2] for i in range(4)]          # 4 bolts, 3 in spacing


def test_concentric_load_shares_equally():
    r = B.solve(Vy=-100, bolts=COL, capacity_kn=79.6)
    assert r['methods']['elastic']['max_bolt_force_kN'] == pytest.approx(25.0, abs=0.01)
    assert 'not_applicable' in r['methods']['icr']


def test_eccentric_icr_beats_elastic_and_ex_equals_torsion():
    a = B.solve(Vy=-177.9, torsion=-177.9 * 101.6, bolts=COL, capacity_kn=79.6)
    b = B.solve(Vy=-177.9, ex=101.6, bolts=COL, capacity_kn=79.6)
    assert a['methods'] == b['methods']
    assert a['methods']['icr']['Cu'] == pytest.approx(2.365, abs=0.01)          # 4 bolts, 3 in pitch, 4 in eccentricity
    assert a['methods']['icr']['DCR'] < a['methods']['elastic']['DCR']
    assert a['methods']['icr']['group_capacity_kN_at_this_eccentricity'] == pytest.approx(2.365 * 79.6, rel=0.01)


def test_en_bolt_shear_and_errors():
    fv, note = B.bolt_shear_rd(20, '8.8')
    assert fv == pytest.approx(94.1, abs=0.3)                                    # M20 8.8, thread in the shear plane
    with pytest.raises(ValueError, match='capacity_kn'):
        B.solve(Vy=-10, bolts=COL)
    with pytest.raises(ValueError, match='at least two'):
        B.solve(Vy=-10, bolts=[[0, 0]], capacity_kn=50)


def test_unit_conversion_is_consistent():
    # the same group in kN / mm and scaled forces: DCR scales with load / capacity
    a = B.solve(Vy=-100, ex=150, bolts=COL, capacity_kn=100)['methods']['icr']['DCR']
    b = B.solve(Vy=-200, ex=150, bolts=COL, capacity_kn=200)['methods']['icr']['DCR']
    assert a == pytest.approx(b, rel=1e-6)


def test_tool_plain_words(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('bolt_group', {'grid': {'width': 100, 'height': 225, 'nx': 2, 'ny': 4}, 'vy': -120, 'ex': 200, 'd': 20, 'cls': '8.8'})
    assert r['bolts'] == 8 and 'Instant centre' in r['plain_english']
