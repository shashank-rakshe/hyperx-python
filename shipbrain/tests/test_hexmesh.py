import math, os
import numpy as np
import pytest

cq = pytest.importorskip('cadquery')
from shipbrain import hexmesh as hm


def test_box_exact_and_valid():
    X, H, r = hm.mesh(cq.Workplane().box(100, 40, 20).val(), 5.0)
    assert r['inverted'] == 0 and abs(r['volume_error_percent']) < 1e-6 and r['min_sj'] > 0.99
    assert r['snapped_to_corners'] == 8                                          # the eight box corners found


def test_curved_part_snapped_valid_and_more_exact():
    shp = cq.Workplane().box(120, 60, 15).faces('>Z').workplane().hole(30).val()
    X, H, r = hm.mesh(shp, 3.0)
    assert r['inverted'] == 0 and r['min_sj'] > 0.3
    assert abs(r['volume_error_percent']) < 1.0                                  # exact volume reproduced within 1 %
    X0, H0, r0 = hm.mesh(shp, 3.0, do_snap=False)
    assert abs(r['volume_error_percent']) <= abs(r0['volume_error_percent']) + 1e-9 or abs(r['volume_error_percent']) < 0.3
    # every boundary node on the hole wall lies on the true cylinder (radius 15), within the tessellation tolerance
    bn, _ = hm.boundary_nodes(H)
    rad = np.hypot(X[bn, 0], X[bn, 1])
    wall = (rad < 25) & (np.abs(X[bn, 2]) < 7.5 - 1e-6)
    assert wall.sum() > 100 and np.abs(rad[wall] - 15).max() < 0.5


def test_write_formats_and_guard(tmp_path):
    shp = cq.Workplane().box(40, 20, 10).val()
    for ext in ('inp', 'bdf', 'fem'):
        r = hm.write(shp, 5.0, str(tmp_path / f'b.{ext}'))
        assert os.path.exists(r['file']) and 'hexahedra' in r['plain_english']
    from shipbrain.femodel import FEModel
    m = FEModel.read(str(tmp_path / 'b.bdf'))
    assert len(m.elems) == r['elements'] and all(e['type'] == 'hexa' for e in m.elems.values())
    with pytest.raises(ValueError, match='million cells'):
        hm.mesh(cq.Workplane().box(1000, 1000, 1000).val(), 1.0)
    with pytest.raises(ValueError, match='cell size'):
        hm.mesh(shp, 0)


def test_stl_input(tmp_path):
    shp = cq.Workplane().box(30, 20, 10).val()
    cq.exporters.export(cq.Workplane().add(shp), str(tmp_path / 'p.stl'))
    X, H, r = hm.mesh(str(tmp_path / 'p.stl'), 5.0)
    assert r['inverted'] == 0 and abs(X[:, 0].max() - X[:, 0].min() - 30) < 1e-6 and 'exact_volume' not in r
