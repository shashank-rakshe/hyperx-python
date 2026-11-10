from deckrules import windows


def _box(x0, y0, x1, y1):
    s = []
    for a, b in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        pass
    return [(x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)]


def test_each_title_gets_its_own_window_titles_above_views():
    segs = _box(100, 200, 300, 500) + _box(400, 200, 600, 500) + _box(100, 640, 300, 900) + _box(400, 640, 600, 900)   # 2 x 2 views, touching rows
    segs += [(100, 350, 300, 350), (400, 350, 600, 350), (100, 760, 300, 760), (400, 760, 600, 760)]
    titles = [(200, 170), (500, 170), (200, 610), (500, 610)]           # every title above its view
    w = windows.windows(segs, titles, 700, 1000, u=(1, 0))
    for (tx, ty), b in zip(titles, w):
        assert b[0] is not None
        assert b[0] <= tx <= b[2] and b[1] >= ty - 20 and b[3] - b[1] < 340     # own view only, never the row below / above
    assert w[0][3] < 520 and w[2][1] > 600                              # upper view ends at its bottom; lower title's window starts below the upper view
