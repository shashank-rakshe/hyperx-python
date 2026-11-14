import os, shutil
import pytest
from shipbrain import reversecad, engines, installs


def test_vendored_and_licence_marked():
    assert reversecad.available()
    root = os.path.dirname(reversecad.ROOT)
    assert os.path.exists(os.path.join(root, 'NONCOMMERCIAL.md'))
    assert 'PolyForm' in open(os.path.join(reversecad.ROOT, 'LICENSE')).read()


def test_routing_and_install_hint():
    assert 'reverse' in engines.classify('convert my scanned STL bracket to STEP')
    assert 'reverse_cad' in installs.SOFTWARE


@pytest.mark.skipif(not shutil.which('node'), reason='needs Node.js')
def test_convert_box(tmp_path):
    cq = pytest.importorskip('cadquery')
    stl = str(tmp_path / 'plate.stl')
    cq.exporters.export(cq.Workplane().box(80, 40, 10).faces('>Z').workplane().hole(10), stl, tolerance=0.05)
    out = reversecad.convert(stl, str(tmp_path / 'o'), material='steel')
    assert os.path.exists(out['files']['step'])
    assert abs(out['summary']['totalVolumeMm3'] - (80 * 40 * 10 - 3.14159 * 25 * 10)) < 0.01 * 32000
    assert out['verification']['overall'] == 'PASSED' and 'non-commercial' in out['plain_english']
