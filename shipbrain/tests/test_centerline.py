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
