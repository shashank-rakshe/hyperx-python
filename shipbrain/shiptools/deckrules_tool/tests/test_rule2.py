from deckrules import rule2


def _it(t, x=0, y=0, w=50, h=10, dx=1, dy=0):
    return dict(t=t, x0=x, y0=y, x1=x + w, y1=y + h, cx=x + w / 2, cy=y + h / 2, dx=dx, dy=dy, src='vector', score=1.0)


def test_written_forms():
    for txt, den in (('(S : 1/50)', 50), ('(SCALE : 1/20)', 20), ('(S=1/25)', 25), ('SCALE: 1/15', 15), ('DETAIL OF PAD (S=1/20)', 20), ('(S:1/200)', 200)):
        w = rule2.find_written([_it(txt)])
        assert w and w[0]['den'] == den and w[0]['kind'] == 'view', txt


def test_nonscale_and_sheet():
    w = rule2.find_written([_it('(NON-SCALE)'), _it('SCALE', 800, 100), _it('1/100', 900, 100)])
    kinds = sorted(x['kind'] for x in w)
    assert kinds == ['nonscale', 'sheet']


def test_mm_per_pt():
    assert abs(rule2.mm_per_pt(100) - 35.28) < 0.01
    assert abs(rule2.mm_per_pt(100, 2.83) - 99.8) < 0.1


def test_chain_scale_and_compare():
    vals = [840, 880, 840, 880, 840, 880]
    xs = [0.0]
    for a, b in zip(vals, vals[1:]):
        xs.append(xs[-1] + (a + b) / 2 / 35.28)                   # 1:100 on a 1:1 page
    items = [_it(str(v), x - 15, 100, 30, 10) for v, x in zip(vals, xs)]
    ch = rule2.measure_chains(items)
    assert len(ch) == 1 and abs(ch[0]['den'] - 100) < 2
    w = [dict(kind='sheet', den=100, text='', x=0, y=0, src='v')]
    rows = rule2.compare(w, ch)
    assert rows[0]['supports'] == 100


def test_written_first():
    w = [dict(kind='view', den=50, text='', x=0, y=0, src='v')]
    assert rule2.scale_for(w, [], 10, 10) == (50, 'written(view)')
    assert rule2.scale_for([], [dict(nearest_std=100)])[1] == 'measured'


def test_views_and_scale_per_view():
    import numpy as np
    segs = [(100, 100, 400, 100), (100, 100, 100, 400), (400, 100, 400, 400), (100, 400, 400, 400),
            (900, 100, 1200, 100), (900, 100, 900, 400), (1200, 100, 1200, 400), (900, 400, 1200, 400)]
    boxes = rule2.find_views(segs, 1500, 800)
    assert len(boxes) == 2
    items = [_it('PLAN', 200, 430), _it('(S : 1/50)', 200, 450), _it('SEC.', 1000, 430), _it('(NON SCALE)', 1000, 450)]
    wr = rule2.find_written(items)
    vt = rule2.view_table(items, wr, [], boxes, 1.0, 100)
    st = {v['box'][0] // 500: (v['den'], v['status']) for v in vt}
    assert st[0] == (50, 'no chain') and st[1] == (None, 'non-scale')
    assert rule2.scale_for_view(vt, 250, 250)[0] == 50


def test_correlate_by_frame():
    idx = {1: [dict(kind='frame', key='19', text='FR.19', x=0, y=0, view=0)], 2: [dict(kind='frame', key='19', text='FR.19 SEC.', x=0, y=0, view=3)]}
    got = rule2.correlate(idx, 'frame', 'FR 19'.replace('FR ', ''), 1, 0)
    assert got == [(2, 3, 'FR.19 SEC.')]
