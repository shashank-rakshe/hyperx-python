import math, ezdxf
from PIL import Image, ImageDraw
from shipbrain import vectorize


def _drawing(tmp):
    im = Image.new('L', (600, 400), 255)
    d = ImageDraw.Draw(im)
    d.rectangle([50, 50, 350, 250], outline=0, width=5)      # 300 x 200 box, 5 px pen
    d.line([(350, 150), (550, 350)], fill=0, width=5)        # diagonal, length sqrt(200^2+200^2)
    d.ellipse([400, 60, 480, 140], outline=0, width=4)
    p = str(tmp / 'd.png')
    im.save(p)
    return p


def test_centerline_lengths(tmp_path):
    r = vectorize.trace_centerline(_drawing(tmp_path), scale=0.5)
    exp = (2 * (300 + 200) + math.hypot(200, 200) + math.pi * 80) * 0.5
    assert abs(r['total_length'] - exp) / exp < 0.06
    msp = ezdxf.readfile(r['dxf']).modelspace()
    assert len(msp.query('LWPOLYLINE')) == r['lines'] and r['lines'] >= 3
    # strokes are single lines, not outlines: a box outline would double the length
    assert r['total_length'] < exp * 1.1


def test_tool(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    _drawing(tmp_path)
    r = T.call('trace_drawing', {'file': 'd.png', 'mode': 'centerline'})
    assert r['lines'] >= 3 and r['dxf'] == 'd_centerline.dxf'


def test_dust_and_rough_edges_give_no_extra_lines(tmp_path):
    import numpy as np
    im = Image.new('L', (600, 400), 255)
    d = ImageDraw.Draw(im)
    d.line([(50, 200), (550, 200)], fill=0, width=6)
    a = np.array(im).astype(float)
    rng = np.random.default_rng(3)
    for _ in range(40):                                      # dust
        y, x = rng.integers(0, 395), rng.integers(0, 595)
        if abs(y - 200) > 12:
            a[y:y + 3, x:x + 3] = 0
    for x in range(60, 540, 7):                              # rough pen edge: one-pixel bumps
        a[193, x] = 0
    p = str(tmp_path / 'r.png')
    Image.fromarray(a.astype('uint8')).save(p)
    r = vectorize.trace_centerline(p)
    assert r['lines'] == 1
    assert abs(r['total_length'] - 500) < 12


def test_auto_picks_the_right_mode(tmp_path):
    thin = _drawing(tmp_path)
    im = Image.new('L', (600, 400), 255)
    ImageDraw.Draw(im).rectangle([100, 80, 450, 300], fill=0)          # filled shape
    solid = str(tmp_path / 's.png')
    im.save(solid)
    assert vectorize.suggest_mode(thin) == 'centerline'
    assert vectorize.suggest_mode(solid) == 'outline'
