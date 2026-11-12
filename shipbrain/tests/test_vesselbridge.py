import json, os, shutil, pytest
from shipbrain import vesselbridge as V

pytestmark = pytest.mark.skipif(V.node() is None, reason='Node.js not installed')


def test_box_barge_matches_the_exact_formulas():
    L, B, D, m, kg = 30.0, 8.0, 4.0, 600.0, 1.5
    s = V.analyse(L, B, D, 'box', [{'mass_t': m, 'cg': [L / 2, 0, kg]}])['summary']
    T = m * 1000 / 1025 / (L * B)
    assert s['draft_m'] == pytest.approx(T, abs=1e-3)
    assert s['KB_m'] == pytest.approx(T / 2, abs=1e-3)
    assert s['BMt_m'] == pytest.approx(B * B / (12 * T), abs=1e-3)
    assert s['GMt_m'] == pytest.approx(T / 2 + B * B / (12 * T) - kg, abs=2e-3)
    assert s['GMl_m'] == pytest.approx(T / 2 + L * L / (12 * T) - kg, abs=0.05)


def test_wigley_hull_matches_its_analytical_hydrostatics():
    Tw, L, B = 2.4, 30.0, 5.0
    r = V.analyse(L, B, 4.0, 'wigley', [{'mass_t': 4 / 9 * L * B * Tw * 1.025, 'cg': [L / 2, 0, 2.0]}], T_design=Tw)
    s = r['summary']
    assert s['draft_m'] == pytest.approx(Tw, rel=0.01)                      # Cb = 4/9
    assert s['KB_m'] == pytest.approx(0.625 * Tw, rel=0.01)                 # KB = 5 T / 8
    assert s['BMt_m'] == pytest.approx(3 * B * B / (35 * Tw), rel=0.01)     # BM = 3 B^2 / (35 T)


def test_library_reference_case_from_its_own_tests():
    spec = json.load(open(os.path.join(V.ROOT, 'specs', 'blockCase.json')))
    st = V.run(spec)['stability']                                           # values asserted by the library's own jest test
    assert st['T'] == pytest.approx(3.322, abs=1e-3) and st['trim_deg'] == pytest.approx(0.129, abs=1e-3) and st['GMt'] == pytest.approx(2.402, abs=1e-3)


def test_fresh_water_and_off_centre_load_and_errors():
    s = V.analyse(30, 8, 4, 'box', [{'mass_t': 600, 'cg': [15, 0, 1.5]}], rho=1000.0)['summary']
    assert s['draft_m'] == pytest.approx(600 / 240, abs=1e-3) and s['mass_t'] == pytest.approx(600, abs=1e-6)
    s = V.analyse(30, 8, 4, 'box', [{'mass_t': 600, 'cg': [15, 0.2, 1.5]}])['summary']
    assert s['heel_offset_m'] > 0                                            # the load is off the centre line: the ship heels
    with pytest.raises(ValueError, match='weights'):
        V.analyse(30, 8, 4, 'box', [])
    with pytest.raises(ValueError):
        V.analyse(30, 8, 4, 'sphere', [{'mass_t': 1, 'cg': [1, 0, 1]}])


def test_tool_answers_in_plain_words_and_flags_instability(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('ship_hydrostatics', {'hull': 'box', 'length': 30, 'beam': 8, 'depth': 4, 'weights': [{'mass_t': 600, 'cg': [15, 0, 1.5]}]})
    assert 'GM' in r['plain_english'] and r['table'][0]['T'] > 0
    r = T.call('ship_hydrostatics', {'hull': 'box', 'length': 30, 'beam': 8, 'depth': 4, 'weights': [{'mass_t': 600, 'cg': [15, 0, 6.5]}]})
    assert r['summary']['GMt_m'] < 0 and 'NEGATIVE' in r['plain_english']     # KG above the metacentre
    shutil.copy(os.path.join(V.ROOT, 'specs', 'barge.json'), tmp_path / 'b.json')
    r = T.call('ship_hydrostatics', {'spec_file': 'b.json'})
    assert 'error' not in r and r['summary']['draft_m'] > 0
    assert 'error' in T.call('ship_hydrostatics', {'hull': 'box'})
