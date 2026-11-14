import numpy as np
from deckrules.ocr import Line
from deckrules import numcheck


def _l(t, x, y=100, w=30, h=12, v=False):
    return Line(t, np.array([[x, y], [x + w, y], [x + w, y + h], [x, y + h]], float), 0.9, v)


def test_upside_down_leading_zero():
    ls = [_l('088', 0), _l('009', 100)]
    numcheck.check(ls)
    assert [l.text for l in ls] == ['880', '600']


def test_chain_substitution():
    vals = [800, 900] * 6
    xs = [0]
    for a, b in zip(vals, vals[1:]):
        xs.append(xs[-1] + (a + b) / 2 / 10)       # 10 mm per pt
    ls = [_l(str(v), x) for v, x in zip(vals, xs)]
    ls[3].text = '300'
    fx = numcheck.check(ls)
    assert ls[3].text == '900' and fx


def test_good_chain_unchanged():
    vals = [800, 900, 800, 900, 800]
    xs = [0]
    for a, b in zip(vals, vals[1:]):
        xs.append(xs[-1] + (a + b) / 2 / 10)
    ls = [_l(str(v), x) for v, x in zip(vals, xs)]
    assert numcheck.check(ls) == []
