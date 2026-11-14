import os, shutil, zipfile, numpy as np, pytest
from shipbrain import intake
from shipbrain.fileinfo import file_info


def test_stl_closed_and_volume(tmp_path):
    import cadquery as cq
    cq.exporters.export(cq.Workplane('XY').box(100, 50, 20), str(tmp_path / 'b.stl'))
    r = file_info(str(tmp_path / 'b.stl'))
    assert r['closed'] and r['volume'] == pytest.approx(100000, rel=1e-6) and r['triangles'] == 12


def test_foreign_mesh_converted_to_inp_and_fields_listed(tmp_path):
    import meshio
    pts = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1.]])
    for ext in ('msh', 'vtu', 'vtk'):
        meshio.write(str(tmp_path / f't.{ext}'), meshio.Mesh(pts, [('tetra', np.array([[0, 1, 2, 3], [1, 2, 3, 4]]))], point_data={'pressure': np.arange(5.)}))
        r = file_info(str(tmp_path / f't.{ext}'))
        assert r['points'] == 5 and r['cells'] == {'tetra': 2}
        inp = tmp_path / r['inp']
        from shipbrain.femodel import FEModel
        m = FEModel.read(str(inp))
        assert len(m.nodes) == 5 and len(m.elems) == 2                   # the converted file is a normal ShipBrain mesh
    assert 'pressure' in r['fields']


def test_office_files_and_tables(tmp_path):
    from pptx import Presentation
    import docx, openpyxl
    p = Presentation(); s = p.slides.add_slide(p.slide_layouts[1]); s.shapes.title.text = 'Hull girder results'; p.save(str(tmp_path / 'd.pptx'))
    d = docx.Document(); d.add_heading('Strength report', 1); d.add_table(rows=2, cols=2); d.save(str(tmp_path / 'r.docx'))
    wb = openpyxl.Workbook(); wb.active.append(['case', 'p']); wb.active.append(['a', 1]); wb.save(str(tmp_path / 'l.xlsx'))
    (tmp_path / 't.csv').write_text('x,y\n1,2\n3,4\n')
    assert 'Hull girder results' in file_info(str(tmp_path / 'd.pptx'))['plain_english']
    r = file_info(str(tmp_path / 'r.docx')); assert r['tables'] == 1 and 'Strength report' in r['headings']
    assert file_info(str(tmp_path / 'l.xlsx'))['sheets'][0]['header'] == ['case', 'p']
    assert file_info(str(tmp_path / 't.csv'))['columns'] == ['x', 'y']


def test_zip_with_a_case_is_recognised_and_unpacked(tmp_path):
    z = tmp_path / 'c.zip'
    with zipfile.ZipFile(z, 'w') as f:
        f.writestr('system/controlDict', 'x'); f.writestr('constant/polyMesh/points', 'x'); f.writestr('0/U', 'x')
    r = file_info(str(z))
    assert r['case'] == 'OpenFOAM case' and (tmp_path / 'c' / 'system' / 'controlDict').exists()
    f2 = tmp_path / 'e.zip'
    with zipfile.ZipFile(f2, 'w') as f:
        f.writestr('case.sif', 'x'); f.writestr('mesh/mesh.header', 'x')
    assert file_info(str(f2))['case'] == 'Elmer case'


def test_closed_binary_results_and_unknown_files_are_described_not_refused(tmp_path):
    (tmp_path / 'j.op2').write_bytes(b'\x00\x00\x00\x04' + os.urandom(100))
    r = file_info(str(tmp_path / 'j.op2'))
    assert r['readable'] is False and 'export' in r['plain_english']
    (tmp_path / 'w.xyz').write_bytes(b'\x89HDF\r\n' + os.urandom(40))
    assert 'HDF5' in file_info(str(tmp_path / 'w.xyz'))['plain_english']
    (tmp_path / 'n.abc').write_text('hello\nworld\n')
    assert file_info(str(tmp_path / 'n.abc'))['lines'] == 2
    (tmp_path / 'bad.pptx').write_bytes(b'not a pptx')                   # a broken file gives a description, not a crash
    assert 'could not read' in file_info(str(tmp_path / 'bad.pptx'))['plain_english']


def test_frd_summary(tmp_path):
    from shipbrain import solver
    if solver.ccx_path() is None:
        pytest.skip('CalculiX not installed')
    from shipbrain.platemesh import build_plates
    spec = {'name': 'c', 'element_size': 100, 'plates': [{'id': 'P1', 'group': 'P1', 't': 10.0, 'outline': [[0, 0, 0], [500, 0, 0], [500, 100, 0], [0, 100, 0]], 'holes': []}],
            'loads': [{'plates': ['P1'], 'pressure': 0.1}], 'fix': [{'x': 0, 'dof': '123456'}]}
    build_plates(spec, str(tmp_path))
    solver.run_calculix(str(tmp_path / 'c.inp'))
    r = file_info(str(tmp_path / 'c.frd'))
    assert r['has_displacement'] and r['has_stress'] and r['max_displacement_mm'] > 0
