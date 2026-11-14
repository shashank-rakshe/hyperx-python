from deckrules import textnorm as t, labels


def test_offcl_and_height():
    assert t.fix_text('* OFF C.L')[0] == 'OFF C.L'
    assert t.fix_text('12720 OFFCL')[0] == '12720 OFF C.L'
    assert t.fix_text('OFF C.L')[1] == ''
    assert t.fix_text('B - DECK PLAN(39,170 A/B')[0] == 'B - DECK PLAN(39170 A/B)'
    assert t.fix_text('A - DECK PLAN(34.750 A/B)')[0] == 'A - DECK PLAN(34750 A/B)'
    assert t.fix_text('SHIP DESIGN OFFICE')[1] == ''


def test_split_frames():
    row = dict(text='FR.23 FR.24', x0='100', y0='50', x1='160', y1='60', dir_x='1', dir_y='0', source='scan')
    a, b = t.split_frames(row)
    assert a['text'] == 'FR.23' and b['text'] == 'FR.24' and float(a['x1']) <= float(b['x0']) + 0.01
    assert t.split_frames(dict(row, text='FR.23'))is None
    r2 = dict(row, text='FR.21+500FR.22+800')
    assert [x['text'] for x in t.split_frames(r2)] == ['FR.21+500', 'FR.22+800']


def test_label_axis():
    items = []
    for v, xl, xr in ((2640, 1368, 1485), (5160, 1295, 1557), (7680, 1226, 1628)):
        for x in (xl, xr):
            items += [dict(t='OFF C.L', x=x, y=786), dict(t=str(v), x=x + 6, y=793)]
    oa = labels.offcl_axis(items, (-1e9, -1e9, 1e9, 1e9), (1041, 937))
    assert oa and 33 < oa['k'] < 38 and 1415 < oa['c'] < 1440
