from types import SimpleNamespace as W
from deckrules import numclass


def w(t, x, y, x1=None):
    x1 = x + 12 if x1 is None else x1
    return W(text=t, bbox=(x, y, x1, y + 9), cx=(x + x1) / 2, cy=y + 4.5)


def test_weld_size_not_plate_thickness():
    n = w('4.5', 100, 100)
    assert numclass.is_weld_size(n, [n, w('LEG LENGTH OF FILLET WELDING TO BE', 0, 101, 200)])
    assert numclass.is_weld_size(w('F6.0', 0, 0), [])
    p = w('12.0', 500, 500)
    assert not numclass.is_weld_size(p, [p, w('FLOOR PLATE THK. : 14.0 WELDING', 480, 503, 700)])
    assert not numclass.is_weld_size(p, [p, w('WELDING', 900, 900)])


def test_wall_view_marks():
    from shapely.geometry import box
    from deckrules import elevation as E
    assert E._sw_mark([w('S.W', 95, 50)], 100, 0, 200)
    assert not E._sw_mark([w('S.W', 300, 50)], 100, 0, 200)
    door = box(0, 0, 100, 200)
    assert E._door_label([w('700X1800XR100', 30, 90)], door)
    assert not E._door_label([w('300X100X11', 30, 90)], door)


def test_stiffener_starts_at_door_top():
    from deckrules import elevation as E
    st = [{'x': 1000, 'a_z': 0, 'b_z': 2600, 'evidence': ''}, {'x': 3000, 'a_z': 0, 'b_z': 2600, 'evidence': ''}]
    out = E._clip_at_doors(st, [[(600, 0), (1500, 0), (1500, 1900), (600, 1900)]])
    assert out[0]['a_z'] == 1900 and out[1]['a_z'] == 0


class _V:
    k = 10.0
    def X(self, x): return x * 10.0
    def Z(self, y): return (1000 - y) * 10.0


class _S:
    def __init__(self, a, b, dash=''):
        self.a, self.b, self.dash = a, b, dash
        self.horizontal = a[1] == b[1]


def test_wall_carling_portal_corner():
    from deckrules import elevation as E, members
    members.GLOBAL_CARL.clear(); members.GLOBAL_CARL['#2'] = ('F', 150, 12.0)
    page = W(words=[w('#2', 140, 795), w('150X10 F.B', 400, 880), w('300X300/12', 15, 985)], segs=[_S((100, 800), (300, 800))])
    st = [{'x': 1000}, {'x': 2000}, {'x': 3000}]
    hc = E._wall_carlings(page, _V(), (0, 500, 700, 1000), st, {})
    assert len(hc) == 1 and hc[0]['x0'] == 1000 and hc[0]['x1'] == 2000 and hc[0]['z'] == 2000 and hc[0]['section'] == ('F', 150, 12.0)
    pb = E._portal_bars(page, _V(), (0, 500, 700, 1000), [[(500, 0), (4500, 0), (4500, 2000), (500, 2000)]], (0, 5000), (0, 3000))
    assert pb and pb[0]['z'] == 2000 and pb[0]['section'] == ('F', 150.0, 10.0)
    cb = E._corner_brackets(page, _V(), (0, 500, 700, 1000), (0, 5000), (0, 3000))
    assert cb and cb[0]['u'] == 0 and cb[0]['z'] == 0 and cb[0]['a'] == 300 and cb[0]['t'] == 12


def test_ocr_rule_tokens():
    from deckrules.textnorm import fix_rule_tokens as f
    assert f('K L') == 'K.L' and f('S W') == 'S.W' and f('# 2') == '#2' and f('I2,0') == '12.0' and f('12.O') == '12.0'
    assert f('150X10 F.B') == '150X10 F.B' and f('OFF C.L') == 'OFF C.L' and f('KLM') == 'KLM'
