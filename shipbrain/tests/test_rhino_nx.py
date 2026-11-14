import math, os, shutil
import pytest
from shipbrain import cadmpeg

HERE = os.path.dirname(os.path.abspath(__file__))
NX = os.path.join(HERE, 'data', 'nist_pd_ctc03_nx1980.prt')       # NIST MBE PMI test part, US public domain


def _rhino_file(path, unit='Millimeters', k=1.0):
    r = pytest.importorskip('rhino3dm')
    m = r.File3dm()
    m.Settings.ModelUnitSystem = getattr(r.UnitSystem, unit)
    m.Objects.AddBrep(r.Brep.CreateFromBox(r.Box(r.BoundingBox(r.Point3d(0, 0, 0), r.Point3d(100 / k, 50 / k, 20 / k)))))
    m.Objects.AddBrep(r.Brep.CreateFromSphere(r.Sphere(r.Point3d(200 / k, 0, 0), 25 / k)))
    m.Objects.AddBrep(r.Cylinder(r.Circle(r.Point3d(0, -100 / k, 0), 15 / k), 60 / k).ToBrep(True, True))
    m.Objects.AddExtrusion(r.Extrusion.Create(r.Circle(r.Point3d(-100 / k, 0, 0), 10 / k).ToNurbsCurve(), 40 / k, True))
    m.Objects.AddCurve(r.LineCurve(r.Point3d(0, 0, 0), r.Point3d(0, 0, 100 / k)))
    assert m.Write(path, 7)
    return path


@pytest.mark.parametrize('unit,k', [('Millimeters', 1.0), ('Meters', 1000.0)])
def test_rhino_exact_solids_and_units(tmp_path, unit, k):
    pytest.importorskip('cadquery')
    from shipbrain import rhino
    r = rhino.to_step(_rhino_file(str(tmp_path / 'p.3dm'), unit, k))
    vols = sorted(o['volume_mm3'] for o in r['objects'] if o['result'] == 'solid')
    want = sorted([100000.0, 4 / 3 * math.pi * 25 ** 3, math.pi * 225 * 60, math.pi * 100 * 40])
    assert all(abs(a - b) / b < 2e-4 for a, b in zip(vols, want)), vols
    assert any(o['result'] == 'curve' for o in r['objects']) and os.path.exists(r['file'])
    assert all(o['valid'] for o in r['objects'] if 'valid' in o)


def test_rhino_through_cad_tools(tmp_path):
    pytest.importorskip('cadquery')
    from shipbrain.fileinfo import file_info
    i = file_info(_rhino_file(str(tmp_path / 'p.3dm')))
    assert i['native'] == 'Rhino model' and 'solid' in i['plain_english']


@pytest.mark.skipif(cadmpeg.exe() is None, reason='needs the cadmpeg program')
def test_nx_part_matches_nist(tmp_path):
    from shipbrain.cadplates import import_cad
    src = str(tmp_path / 'part.prt')
    shutil.copy(NX, src)
    s = import_cad(src)
    from shipbrain.rhino import volume
    assert len(s.Solids()) == 1 and s.isValid()
    assert abs(volume(s) - 332122.9) / 332122.9 < 2e-3                # NIST's own STEP of the same part
