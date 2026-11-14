import numpy as np, cv2
from deckrules import fourier as F


def _cloud(a, b, nb, depth=0.6):
    t = np.linspace(0, 2 * np.pi, 4000, endpoint=False); P = np.c_[a * np.cos(t), b * np.sin(t)]
    seg = np.r_[0, np.cumsum(np.hypot(*np.diff(np.vstack([P, P[:1]]), axis=0).T))]; L = seg[-1]
    s = np.linspace(0, L, nb * 40, endpoint=False); x = np.interp(s, seg[:-1], P[:, 0]); y = np.interp(s, seg[:-1], P[:, 1])
    dx, dy = np.gradient(x), np.gradient(y); n = np.hypot(dx, dy)
    h = depth * (L / nb) / 2 * np.sin(np.pi * ((s % (L / nb)) / (L / nb)))
    return np.c_[x + dy / n * h, y - dx / n * h]


def _poly(P, n=40):
    return np.vstack([np.linspace(P[i], P[(i + 1) % len(P)], n, endpoint=False) for i in range(len(P))])


def test_shapes():
    t = np.linspace(0, 2 * np.pi, 400, endpoint=False)
    assert F.classify(np.c_[50 * np.cos(t), 50 * np.sin(t)]) == 'circle'
    assert F.classify(_poly(np.array([[0, 0], [100, 0], [50, 86.6]]))) == 'triangle'
    for a, b, nb in ((50, 50, 10), (300, 60, 20)):
        assert F.classify(_cloud(a, b, nb)) == 'cloud'
    assert F.classify(_poly(np.array([[0, 0], [300, 0], [300, 100], [0, 100]]))) is None
    assert F.classify(np.c_[150 * np.cos(t), 50 * np.sin(t)]) is None


def test_skew_and_dash_period():
    g = np.full((1200, 1600), 255, np.uint8)
    for y in range(100, 1100, 60):
        cv2.line(g, (50, y), (1550, y), 0, 2)
    for x in range(100, 1500, 90):
        cv2.line(g, (x, 50), (x, 1150), 0, 2)
    assert abs(F.estimate_skew(g)) < 0.05
    r = cv2.warpAffine(g, cv2.getRotationMatrix2D((800, 600), 1.2, 1), (1600, 1200), borderValue=255)
    assert abs(F.estimate_skew(r) - 1.2) < 0.2
    per, strength, ink = F.line_period(np.tile([1] * 12 + [0] * 6, 30))
    assert abs(per - 18) < 0.5 and abs(ink - 2 / 3) < 0.01
    assert F.line_period(np.ones(500))[0] is None
