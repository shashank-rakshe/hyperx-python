import numpy as np
from deckrules import gapaudit


def _box(c, h):
    return (np.array(c, float), np.eye(3), np.array(h, float))


def test_box_distance_gap_and_touch():
    a = _box([0, 0, 0], [10, 10, 10])
    assert abs(gapaudit._box_dist(a, _box([30, 0, 0], [10, 10, 10])) - 10) < 0.1      # 10 mm gap
    assert gapaudit._box_dist(a, _box([20, 0, 0], [10, 10, 10])) < 0.1                # touching
    assert gapaudit._box_dist(a, _box([5, 0, 0], [10, 10, 10])) < 0.1                 # overlapping


def test_point_plate_distance():
    from shapely.geometry import Polygon
    pl = {'O': np.zeros(3), 'U': np.array([1., 0, 0]), 'V': np.array([0, 1., 0]), 'W': np.array([0, 0, 1.]),
          'poly': Polygon([(0, 0), (100, 0), (100, 100), (0, 100)]), 't': 10.0, 'off': 0.0}
    assert gapaudit._pt_plate(np.array([50, 50, 5.]), pl) == 0.0
    assert abs(gapaudit._pt_plate(np.array([50, 50, 25.]), pl) - 20) < 1e-6
    assert abs(gapaudit._pt_plate(np.array([130, 50, 0.]), pl) - 30) < 1e-6
