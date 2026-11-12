import math, pytest
cq = pytest.importorskip('cadquery')
from shipbrain import cadplates


def _bent(t=30.0, L=500.0, ang=45.0, w=1000.0):
    h = t / 2 * math.tan(math.radians(ang) / 2)
    s1 = cq.Workplane('XY').polyline([(-L, -t / 2), (h, -t / 2), (-h, t / 2), (-L, t / 2)]).close().extrude(w)
    s2 = cq.Workplane('XY').box(L, t, w, centered=(False, True, False)).rotate((0, 0, 0), (0, 0, 1), ang)
    return s1.union(s2).val()


def test_bent_plate_gives_one_plate_per_slab():
    plates, rep = cadplates.shape_to_plates(_bent(), 50.0, 30.0)
    assert len(plates) == 2 and rep['solids_to_plates'] == 2 and not rep['skipped']
    assert all(abs(p['t'] - 30) < 0.01 for p in plates)
    import numpy as np
    pts = np.array([q for p in plates for q in p['outline']])
    assert pts[:, 0].min() == pytest.approx(-500, abs=1e-6)
    assert pts[:, 1].max() == pytest.approx(500 * math.sin(math.radians(45)), abs=16)       # the inclined slab is not lost


def test_flat_plate_still_one_plate():
    box = cq.Workplane('XY').box(1000, 1000, 30).val()
    plates, rep = cadplates.shape_to_plates(box, 100.0, 30.0)
    assert len(plates) == 1 and abs(plates[0]['t'] - 30) < 0.01
