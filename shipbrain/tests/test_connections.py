import math, os, pytest
pytest.importorskip('cadquery')
from shipbrain import connections as K


def area(sec):
    return 2 * sec['b'] * sec['tf'] + (sec['h'] - 2 * sec['tf']) * sec['tw']


def test_tables_and_errors():
    assert K.section('ipe 400')['h'] == 400 and K.section({'h': 300, 'b': 150, 'tw': 7, 'tf': 10})['tf'] == 10
    b = K.bolt('M20-8.8')
    assert b['d0'] == 22 and b['s'] == 30 and b['m'] == 18
    with pytest.raises(ValueError, match='unknown section'):
        K.section('IPE999')
    with pytest.raises(ValueError, match='M20-8.8'):
        K.bolt('big')
    assert K.kind_of('shear tab') == 'fin_plate' and K.kind_of('column base') == 'base_plate'


def test_end_plate_volumes_checks_and_step(tmp_path):
    c = K.build('end_plate', beam='IPE400', column='HEB300', ext=60, out=str(tmp_path / 'e.step'))
    rows = {r['part']: r for r in c.table}
    C = K.section('HEB300')
    d0 = c.bolt['d0']
    exact = (area(C) * 1500 - 8 * math.pi / 4 * d0 ** 2 * C['tf'])        # 8 holes through one column flange
    assert rows['column']['volume_mm3'] == pytest.approx(exact, rel=2e-4)
    bp, hp, tp = c.info['end_plate_mm']
    assert rows['end_plate']['volume_mm3'] == pytest.approx(bp * hp * tp - 8 * math.pi / 4 * d0 ** 2 * tp, rel=2e-4)
    assert c.warnings == [] and c.clashes == []
    assert sum(1 for r in c.table if r['role'] == 'bolt') == 8
    import cadquery as cq
    back = cq.importers.importStep(str(tmp_path / 'e.step'))
    assert len(back.solids().vals()) == len(c.table)


def test_spacing_and_fit_warnings():
    c = K.build('end_plate', beam='IPE300', column='HEB300', rows=[100.0, 112.0, -100.0, -112.0])
    assert any('less than 2.2 d0' in w for w in c.warnings)
    c = K.build('fin_plate', beam='IPE200', column='HEB200', rows=8)
    assert any('does not fit between the beam flanges' in w for w in c.warnings)
    with pytest.raises(ValueError, match='beam and a column'):
        K.build('end_plate', beam='IPE300')


def test_shell_mesh_runs_in_calculix_and_is_more_flexible_than_rigid_beam(tmp_path):
    from shipbrain import solver
    c = K.build('end_plate', beam='IPE400', column='HEB300', ext=60, name='ep')
    info = K.shell_mesh(c, 25, str(tmp_path), load_kn=100)
    assert info['bolts_tied'] == 8 and info['bolts_tied_nearest_node'] == 0 and info['loaded_nodes'] > 10
    r = solver.run_calculix(info['files']['inp'])
    ref = K.cantilever_reference(c, 100)
    assert ref['tip_deflection_mm'] == pytest.approx(0.74, abs=0.02)         # P L^3 / 3 E I, L = 1000, I(IPE400) = 2.19e8
    assert ref['tip_deflection_mm'] < r['max_displacement_mm'] < 10 * ref['tip_deflection_mm']


def test_base_plate_with_anchors_and_hex(tmp_path):
    c = K.build('base_plate', column='HEB300', ribs=True)
    assert c.info['base_plate_mm'][2] == 30 and c.warnings == [] and c.clashes == []
    assert sum(1 for r in c.table if r['part'].startswith('anchor')) == 4
    out = K.hex_meshes(c, str(tmp_path))
    ok = [x for x in out if 'error' not in x]
    assert len(ok) == 3 and all(x['min_scaled_jacobian'] >= 0.3 and not x['inverted'] for x in ok)


def test_tool_in_plain_words(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('steel_connection', {'kind': 'shear tab', 'beam': 'IPE300', 'column': 'HEB260', 'bolt': 'M16-8.8', 'rows': 4, 'name': 'fin1'})
    assert r['kind'] == 'fin_plate' and os.path.exists(tmp_path / 'fin1.step') and os.path.exists(tmp_path / 'fin1_parts.csv')
    assert 'EN 1993-1-8' in r['plain_english']
    r = T.call('steel_connection', {'kind': 'splice', 'beam': 'IPE300', 'mesh': 'shell', 'size': 30, 'load_kn': 20})
    assert r['shell']['bolts_tied'] >= 20 and os.path.exists(tmp_path / r['shell']['file'])
