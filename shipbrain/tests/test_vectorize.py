import os
import pytest
from shipbrain import vectorize


def test_svg_path_parser():
    pl = vectorize.path_polylines('M10,10l20,0l0,10l-20,0Z M50 50 L60 50 C70 50 70 60 60 60', dx=5, dy=0)
    assert pl[0][0] == (15.0, 10.0) and pl[0][-1] == pl[0][0] and len(pl[0]) == 5
    assert pl[1][1] == (65.0, 50.0) and abs(pl[1][-1][0] - 65.0) < 1e-9 and abs(pl[1][-1][1] - 60.0) < 1e-9


def test_trace_scan(tmp_path):
    vt = pytest.importorskip('vtracer')
    if not hasattr(vt, 'Config'):
        pytest.skip('old vtracer')
    from PIL import Image, ImageDraw
    im = Image.new('RGB', (800, 500), 'white')
    d = ImageDraw.Draw(im)
    d.rectangle([100, 100, 700, 400], outline='black', width=5)
    d.ellipse([350, 200, 450, 300], outline='black', width=4)
    p = str(tmp_path / 'scan.png')
    im.save(p)
    assert vectorize.is_scan(p)
    r = vectorize.trace(p, str(tmp_path / 't'), scale=2.0)
    assert r['shapes'] >= 2 and os.path.exists(r['dxf']) and os.path.exists(r['svg'])
    import ezdxf
    pts = [q for e in ezdxf.readfile(r['dxf']).modelspace() for q in e.get_points('xy')]
    xs, ys = [q[0] for q in pts], [q[1] for q in pts]
    assert 190 < min(xs) < 210 and 1390 < max(xs) < 1410          # 100..700 px x 2 units/px
    assert 190 < min(ys) < 210 and 790 < max(ys) < 810            # y flipped: (500-400)..(500-100) px x 2
