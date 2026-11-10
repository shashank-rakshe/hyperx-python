import numpy as np
import cv2
from deckrules import scanvec as sv


def test_vectorize_simple_lines():
    g = np.full((900, 1200), 255, np.uint8)
    cv2.line(g, (100, 200), (1000, 200), 0, 3)       # horizontal
    cv2.line(g, (300, 100), (300, 800), 0, 3)        # vertical
    segs = sv.vectorize_gray(g, 1200 / 3.0, 900 / 3.0, log=lambda *a: None)
    hv = [s for s in segs if s['kind'] == 'hv']
    ys = [s for s in hv if abs(s['a'][1] - s['b'][1]) < 1 and abs(s['a'][0] - s['b'][0]) > 250]
    xs = [s for s in hv if abs(s['a'][0] - s['b'][0]) < 1 and abs(s['a'][1] - s['b'][1]) > 200]
    assert ys and xs
