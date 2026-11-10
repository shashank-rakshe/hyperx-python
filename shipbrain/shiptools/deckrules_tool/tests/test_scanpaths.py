import math
import numpy as np
from deckrules import scanpaths as sp, scanvec as sv


def _poly(pts, closed=True):
    n = len(pts)
    segs = [dict(a=tuple(pts[i]), b=tuple(pts[(i + 1) % n]), w=0.4, dash='', kind='ring') for i in range(n if closed else n - 1)]
    s = sv.SegList(segs)
    s.contours = [(pts, 0.4, 'ring')] if closed else ()
    return s


def test_circle_becomes_arcs():
    r = 20.0
    pts = [(100 + r * math.cos(t), 100 + r * math.sin(t)) for t in np.linspace(0, 2 * math.pi, 72, endpoint=False)]
    paths, st = sp.group(_poly(pts))
    assert st['arcs'] >= 1
    assert any(k == 'c' for p in paths for k, _ in p['items'])


def test_rectangle_stays_lines():
    pts = [(0, 0), (30, 0), (30, 10), (0, 10)]
    paths, st = sp.group(_poly(pts))
    assert st['arcs'] == 0 and all(k == 'l' for p in paths for k, _ in p['items'])


def test_chain_two_segments_one_path():
    segs = sv.SegList([dict(a=(0, 0), b=(10, 0), w=0.3, dash='', kind='hv'), dict(a=(10, 0.1), b=(10, 10), w=0.3, dash='', kind='hv')])
    paths, st = sp.group(segs)
    assert st['paths'] == 1 and len(paths[0]['items']) == 2
