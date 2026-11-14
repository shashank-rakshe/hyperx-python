import pytest
from shipbrain import catamaran as CM, navalbridge as NB, intake

numba = pytest.importorskip('numba')
needs_nt = pytest.mark.skipif(not NB.available(), reason='navaltoolbox not installed')


@pytest.fixture(scope='module')
def demi():
    return CM.demihull(16, 2.5, 0.5, volume_m3=100.0)


def test_demihull_stl_is_closed_and_has_the_requested_proportions(demi, tmp_path):
    f = CM.write_stl(demi['points'], demi['faces'], str(tmp_path / 'd.stl'))
    d, _ = intake.describe_stl(f)
    assert d['closed'] and d['triangles'] > 1000
    assert demi['lwl'] / demi['b'] == pytest.approx(16, rel=0.01) and demi['b'] / demi['T'] == pytest.approx(2.5, rel=0.01) and demi['volume_m3'] == pytest.approx(100.0, rel=1e-6)


@needs_nt
def test_navaltoolbox_reproduces_the_generators_displacement_and_catamaran_stiffness(demi, tmp_path):
    f = CM.write_stl(demi['points'], demi['faces'], str(tmp_path / 'd.stl'))
    r = NB.analyse(f, kg=1.8, draft=demi['T'], heels=[0, 10, 20])
    assert r['hydrostatics']['volume_m3'] == pytest.approx(100.0, rel=0.005)             # two independent codes: the generator's volume and the library's section integration
    assert r['hydrostatics']['LWL_m'] == pytest.approx(demi['lwl'], rel=0.005)
    P, F = CM.catamaran(demi['points'], demi['faces'], 8.0)
    f2 = CM.write_stl(P, F, str(tmp_path / 'c.stl'))
    h = NB.analyse(f2, kg=2.2, draft=demi['T'], heels=[0, 10, 20])['hydrostatics']
    assert h['volume_m3'] == pytest.approx(200.0, rel=0.005)
    awp = h['waterplane_area_m2']
    assert h['BMt_m'] > 5 * r['hydrostatics']['BMt_m']                                    # the wide stance gives the catamaran its stability
    # parallel-axis estimate: I = 2 (I_own + A_demi (s/2)^2), BM = I / V
    assert h['BMt_m'] == pytest.approx(awp / 2 * 16 * 2 / 200.0, rel=0.12)


def test_broken_rule_scripts_are_refused_plainly_and_the_tool_works(tmp_path):
    assert 'hsc_2000_monohull_intact' not in NB.rule_names() and 'is_code_2008_general' in NB.rule_names()
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('catamaran_hull', {'l_to_b': 16, 'b_to_t': 2.5, 'tt_to_t': 0.5, 'volume_m3': 60, 'separation': 7.0})
    assert 'error' not in r and len(r['files']) == 2 and (tmp_path / r['files'][1]).exists() and 'stl_stability' in r['plain_english']
    assert 'error' in T.call('catamaran_hull', {'l_to_b': 16, 'b_to_t': 2.5, 'tt_to_t': 0.5})
