import pytest
from shipbrain import hullgen as H, navalbridge as NB, stability as S

pytestmark = pytest.mark.skipif(not NB.available(), reason='navaltoolbox not installed')
P = dict(L=100, B=16, D=13, T=6, r_bilge=1.5, ent=0.3, run=0.25, n_ent=2, n_run=3, transom=0.0)


@pytest.fixture(scope='module')
def stl(tmp_path_factory):
    return H.write_stl(H.params(**P), str(tmp_path_factory.mktemp('h') / 'h.stl'), nx=161, nz=61)


def test_hydrostatics_agree_with_the_hull_generators_own_numbers(stl):
    c = H.coefficients(H.params(**P))
    r = NB.analyse(stl, kg=5.0, draft=6.0)
    h = r['hydrostatics']
    assert h['volume_m3'] == pytest.approx(c['volume_m3'], rel=0.02)
    assert h['waterplane_area_m2'] == pytest.approx(c['Awp_m2'], rel=0.01)
    assert h['LCF_m'] == pytest.approx(c['LCF_m'], abs=0.2) and h['cob'][0] == pytest.approx(c['LCB_m'], abs=0.2) and h['cob'][2] == pytest.approx(c['KB_m'], rel=0.02)


def test_gz_curve_agrees_with_the_own_heeled_hull_integration(stl):
    r = NB.analyse(stl, kg=5.0, draft=6.0, heels=[0, 10, 20, 30, 40, 50, 60])
    own = S.gz_curve(H.params(**P), 5.0, mass_t=r['hydrostatics']['displacement_t'], heels=[0, 10, 20, 30, 40, 50, 60])
    for a, b in zip(r['GZ_m'], [x['GZ_m'] for x in own['curve']]):
        assert a == pytest.approx(b, abs=0.04, rel=0.05)                       # two independent methods (the library also optimises the trim)


def test_rules_pass_and_fail_with_the_kg_and_bad_input_is_refused(stl):
    assert NB.analyse(stl, kg=5.0, draft=6.0)['overall_pass'] is True
    bad = NB.analyse(stl, kg=8.5, draft=6.0)
    assert bad['overall_pass'] is False and any(c['status'] != 'PASS' for c in bad['criteria'])
    assert 'is_code_2008_general' in NB.rule_names()
    with pytest.raises(ValueError, match='either the draft or the displacement'):
        NB.analyse(stl, kg=5.0)
    with pytest.raises(ValueError, match='rule must be'):
        NB.analyse(stl, kg=5.0, draft=6.0, rule='nonsense')


def test_tool(stl, tmp_path):
    import shutil
    from shipbrain import agent, knowledge
    shutil.copy(stl, tmp_path / 'hull.stl')
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('stl_stability', {'file': 'hull.stl', 'kg': 5.0, 'draft': 6.0})
    assert 'error' not in r and 'all criteria pass' in r['plain_english'] and (tmp_path / 'stl_gz.png').stat().st_size > 3000
    assert 'error' in T.call('stl_stability', {'file': 'hull.stl', 'kg': 5.0})
