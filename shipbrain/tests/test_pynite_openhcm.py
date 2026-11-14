import os, pytest
from shipbrain import pynite_bridge as PB, openhcm as OH

HERE = os.path.dirname(os.path.abspath(__file__))
needs_pynite = pytest.mark.skipif(not PB.available(), reason='PyNite not installed')
E, I, A, L = 206000.0, 2.0e7, 5000.0, 3000.0
SEC = {'A': A, 'Iy': I, 'Iz': I, 'J': 1e7}
BASE = {'materials': {'s': {'E': E, 'nu': 0.3}}, 'sections': {'x': SEC}, 'nodes': {'A': [0, 0, 0], 'B': [L, 0, 0]}, 'members': [{'name': 'M', 'i': 'A', 'j': 'B', 'material': 's', 'section': 'x'}]}


@needs_pynite
def test_cantilever_and_simply_supported_beam_match_beam_theory():
    r = PB.analyse(dict(BASE, supports={'A': 'fixed'}, node_loads=[{'node': 'B', 'dir': 'FY', 'value': -1000.0}]))
    assert r['nodes']['B']['DY'] == pytest.approx(-1000 * L ** 3 / (3 * E * I), rel=1e-6)
    assert r['reactions']['A']['FY'] == pytest.approx(1000.0, rel=1e-9) and abs(r['reactions']['A']['MZ']) == pytest.approx(1000 * L, rel=1e-6)
    w = -2.0
    r = PB.analyse(dict(BASE, supports={'A': 'pinned', 'B': 'roller_y'}, member_loads=[{'member': 'M', 'dir': 'Fy', 'w1': w, 'w2': w}]))
    assert r['members']['M']['min_deflection_y'] == pytest.approx(5 * w * L ** 4 / (384 * E * I), rel=2e-3)
    assert r['reactions']['A']['FY'] == pytest.approx(-w * L / 2, rel=1e-9)
    assert max(abs(r['members']['M']['max_M_z']), abs(r['members']['M']['min_M_z'])) == pytest.approx(abs(w) * L * L / 8, rel=1e-6)


@needs_pynite
def test_plate_deflection_matches_timoshenko():
    E_, nu, t, a, q = 206000.0, 0.3, 10.0, 1000.0, 0.01
    D = E_ * t ** 3 / (12 * (1 - nu ** 2))
    base = {'materials': {'s': {'E': E_, 'nu': nu}}}
    ss = {k: 'simple' for k in ('left', 'right', 'bottom', 'top')}
    cl = {k: 'clamped' for k in ('left', 'right', 'bottom', 'top')}
    r = PB.analyse(dict(base, plates=[{'name': 'P', 'width': a, 'height': a, 't': t, 'mesh': 50.0, 'material': 's', 'pressure': -q, 'edges': ss}]))
    assert r['plates']['P']['max_deflection'] == pytest.approx(0.00406 * q * a ** 4 / D, rel=0.01)          # simply supported square plate, alpha = 0.00406
    r = PB.analyse(dict(base, plates=[{'name': 'P', 'width': a, 'height': a, 't': t, 'mesh': 25.0, 'material': 's', 'pressure': -q, 'edges': cl}]))
    assert r['plates']['P']['max_deflection'] == pytest.approx(0.00126 * q * a ** 4 / D, rel=0.02)          # clamped, alpha = 0.00126


@needs_pynite
def test_tool_and_a_model_error_is_reported(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('pynite_fea', {'model': dict(BASE, supports={'A': 'fixed'}, node_loads=[{'node': 'B', 'dir': 'FY', 'value': -1000.0}])})
    assert 'error' not in r and 'reaction at A' in r['plain_english']
    assert 'error' in T.call('pynite_fea', {'model': {'nodes': {'A': [0, 0, 0]}, 'members': [{'name': 'M', 'i': 'A', 'j': 'Z', 'material': 's', 'section': 'x'}]}})


def test_openhcm_reader_summary_and_conversion(tmp_path):
    m = OH.read(os.path.join(HERE, 'data', 'sample_openhcm.xml'))
    s = OH.summary(m)
    assert s['plates'] == 3 and s['plates_with_triangle_mesh'] == 1 and s['stiffeners'] == 2 and s['compartments'] == 2 and s['stiffener_types'] == ['FB', 'T']
    assert s['plate_area_m2_if_mm'] == pytest.approx(2.4 * 1.6 + 1.6 * 0.8 - 0.5 * 0.2 * 0.2 + 0.5 * 0.1 * 0.1, rel=0.02)
    assert OH._profile(m['stiffeners'][1]) == {'type': 'TBar', 'h': 250.0, 't': 8.0, 'bf': 90.0, 'tf': 12.0}
    spec, rep = OH.to_plate_spec(m, 200.0)
    assert rep['plates_meshed'] == 2 and 'P3' in rep['plates_skipped'][0] and rep['stiffener_segments'] == 2
    from shipbrain import agent, knowledge
    import shutil
    shutil.copy(os.path.join(HERE, 'data', 'sample_openhcm.xml'), tmp_path / 'm.xml')
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('openhcm_read', {'file': 'm.xml', 'mesh': True, 'element_size': 200, 'name': 'hcm'})
    assert 'error' not in r and r['mesh']['elements'] > 50 and (tmp_path / 'hcm.inp').exists() and 'OpenHCM model: 3 plates' in r['plain_english']
