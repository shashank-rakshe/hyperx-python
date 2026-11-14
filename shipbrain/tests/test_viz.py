import numpy as np, pytest, shutil
from shipbrain import viz, solver

pytestmark = pytest.mark.skipif(solver.ccx_path() is None, reason='CalculiX not installed')


def _cantilever(tmp_path):
    """flat steel plate 1000 x 200 x 20 mm fixed at x = 0, 100 N down at the free end"""
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    spec = {'name': 'cant', 'element_size': 50, 'plates': [{'id': 'P1', 'group': 'P1', 't': 20.0,
            'outline': [[0, 0, 0], [1000, 0, 0], [1000, 200, 0], [0, 200, 0]], 'holes': []}], 'loads': [], 'fix': [{'x': 0, 'dof': '123456'}]}
    from shipbrain.platemesh import build_plates
    m, info = build_plates(spec, str(tmp_path))
    inp = tmp_path / 'cant.inp'
    from shipbrain.femodel import FEModel
    M = FEModel.read(str(inp))
    ids = [i for i, x in M.nodes.items() if abs(x[0] - 1000) < 1e-6]
    s = inp.read_text().replace('*STEP\n*STATIC\n', '*STEP\n*STATIC\n*CLOAD\n' + ''.join(f'{i}, 3, {-100.0 / len(ids):.8g}\n' for i in ids), 1)
    inp.write_text(s)
    solver.run_calculix(str(inp))
    return T, inp


def test_stress_and_displacement_pictures_match_calculix(tmp_path):
    T, inp = _cantilever(tmp_path)
    ref = solver.read_frd(str(tmp_path / 'cant.frd'))
    r = T.call('show_result', {'file': 'cant.inp', 'field': 'displacement', 'vtu': True})
    assert (tmp_path / 'cant_displacement.png').stat().st_size > 5000
    assert r['max'] == pytest.approx(ref['max_displacement_mm'], rel=0.02)
    r = T.call('show_result', {'file': 'cant.inp', 'field': 'von_mises'})
    assert r['max'] == pytest.approx(ref['max_von_mises_MPa'], rel=0.10)           # same field, our nodal mapping of the expanded shell nodes
    # beam theory: tip deflection P L^3 / 3 E I, I = 200 x 20^3 / 12
    assert ref['max_displacement_mm'] == pytest.approx(100 * 1000 ** 3 / (3 * 206000 * 200 * 20 ** 3 / 12), rel=0.08)
    vtu = (tmp_path / 'cant.vtu').read_text()
    assert 'von_mises_MPa' in vtu and 'displacement_mm' in vtu


def test_geometry_picture_from_stl_and_missing_result(tmp_path):
    import cadquery as cq
    cq.exporters.export(cq.Workplane('XY').box(100, 50, 20), str(tmp_path / 'b.stl'))
    info = viz.render(str(tmp_path / 'b.stl'), str(tmp_path / 'b.png'))
    assert info['faces'] == 12 and (tmp_path / 'b.png').stat().st_size > 3000
    with pytest.raises(ValueError, match='frd'):
        viz.render(str(tmp_path / 'b.stl'), str(tmp_path / 'c.png'), field='von_mises')
