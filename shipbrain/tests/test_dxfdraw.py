import math, os
import pytest
ezdxf = pytest.importorskip('ezdxf')
from shipbrain import dxfdraw as dd


def _doc(path):
    return ezdxf.readfile(path)


def test_plate_geometry_layers_units(tmp_path):
    out = str(tmp_path / 'p.dxf')
    r = dd.draw([{'type': 'plate', 'length': 300, 'width': 150, 'thickness': 10,
                  'holes': [{'x': 40, 'y': 40, 'd': 18}, {'x': 260, 'y': 110, 'd': 18}]}], out, title='T', sheet='A4', png=False)
    d = _doc(out)
    assert d.header['$INSUNITS'] == 4
    circles = [e for e in d.modelspace() if e.dxftype() == 'CIRCLE' and e.dxf.layer == 'HOLES']
    assert sorted((round(c.dxf.center.x), round(c.dxf.center.y), round(c.dxf.radius * 2)) for c in circles) == [(40, 40, 18), (260, 110, 18)]
    outline = next(e for e in d.modelspace() if e.dxf.layer == 'OUTLINE')
    xs = [p[0] for p in outline.get_points()]
    assert min(xs) == 0 and max(xs) == 300 and r['dimensions'] >= 4 and r['scale'] == '1:2'
    assert {'OUTLINE', 'HOLES', 'CENTER', 'DIM', 'TITLE'} <= set(r['entities_by_layer']) | {'DIM'}


def test_panel_counts_and_flange_and_errors(tmp_path):
    out = str(tmp_path / 'n.dxf')
    r = dd.draw([{'type': 'panel', 'length': 4800, 'width': 3200, 'thickness': 12, 'stiffeners': {'spacing': 800, 'profile': 'FB 150x12'},
                  'frames': {'spacing': 1200}}], out, sheet='A3', png=False)
    d = _doc(out)
    assert len([e for e in d.modelspace() if e.dxf.layer == 'STIFFENER']) == 3                    # 800, 1600, 2400
    assert len([e for e in d.modelspace() if e.dxf.layer == 'FRAME']) == 3                        # 1200, 2400, 3600
    assert r['scale'] == '1:20' and r['text_height_mm'] == 50.0
    r = dd.draw([{'type': 'flange', 'od': 220, 'id': 100, 'bolt_circle': 170, 'n_bolts': 8, 'bolt_d': 18}], str(tmp_path / 'f.dxf'), png=False)
    assert r['entities_by_layer']['HOLES'] == 8
    with pytest.raises(ValueError, match='outside'):
        dd.draw([{'type': 'plate', 'length': 200, 'width': 100, 'holes': [{'x': 250, 'y': 20, 'd': 12}]}], out, png=False)
    with pytest.raises(ValueError, match='missing length'):
        dd.draw([{'type': 'plate', 'width': 100}], out, png=False)
    with pytest.raises(ValueError, match='bore'):
        dd.draw([{'type': 'flange', 'od': 100, 'id': 120}], out, png=False)


def test_check_finds_planted_problems_and_passes_clean(tmp_path):
    clean = str(tmp_path / 'c.dxf')
    dd.draw([{'type': 'plate', 'length': 300, 'width': 150, 'holes': [{'x': 40, 'y': 40, 'd': 14}]}], clean, sheet='A4', png=False)
    assert 'no drafting problems' in dd.check(clean)['plain_english']
    doc = ezdxf.new('R2018')
    doc.header['$INSUNITS'] = 0
    m = doc.modelspace()
    for a, b in [((0, 0), (100, 0)), ((100, 0), (100, 50)), ((100, 50), (0, 50)), ((0, 50.4), (0, 0)), ((0, 0), (100, 0)), ((10, 10), (10, 10)),
                 ((5, 5, 3), (20, 5, 3)), ((5000, 5000), (5010, 5000))]:
        m.add_line(a, b)
    for i in range(10):
        m.add_line((i * 10, 60), (i * 10 + 5, 60))
    m.add_circle((50, 25), 0)
    m.add_linear_dim(base=(0, -10), p1=(0, 0), p2=(100, 0), text='120', dimstyle='EZDXF').render()
    bad = str(tmp_path / 'b.dxf')
    doc.saveas(bad)
    what = ' | '.join(i['what'] for i in dd.check(bad)['issues'])
    for needle in ('units', 'layer 0', 'zero-length', 'duplicate', 'Z coordinate', 'far away', 'nearly meet', 'typed over'):
        assert needle in what, needle
