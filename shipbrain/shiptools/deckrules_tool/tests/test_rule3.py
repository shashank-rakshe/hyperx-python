from deckrules import rule3 as r, facts as fa


def test_classify():
    a = fa.classify_title('C - DECK PLAN (42400 A/B)')
    assert a['type'] == 'deck-plan' and a['deck'] == 'C-DECK' and a['height'] == 42400
    b = fa.classify_title('"1B3-3" SEC.(P)')
    assert b['type'] == 'section' and b['id'] == '1B3-3' and b['side'] == 'P'
    c = fa.classify_title('21130 OFF C.L ELEV. (S)')
    assert c['type'] == 'longitudinal-elevation' and c['offcl'] == 21130 and c['side'] == 'S'
    assert fa.classify_title('LOOKING PORT AND ALL PLANS LOOKING DOWNWARD.') is None
    assert fa.classify_title('2. ALL SECTIONS ARE SHOWN') is None


def test_members():
    m = fa.parse_member('GIR. & WEB : 300X90X11/16 I.A')
    assert m['shape'] == 'I.A' and m['size'] == '300X90X11/16' and m['role'].startswith('GIR')
    t = fa.parse_member('500X10 + 150 12 F.B (T)')
    assert t['size'] == '500X10+150X12'
    f = fa.parse_member('150X15 F.B')
    assert f['shape'] == 'F.B' and f['t'] == '15'
    h = fa.parse_member('300 I.A')
    assert h['level'] == 'height-only'


def test_fill():
    full = dict(level='full', kind='member', shape='I.A', size='300X90X11/16', h=300, view=1, page=1, b='90', t='11', t2='16', fw='', ft='', prov='written', candidates='')
    gap = dict(level='height-only', kind='member', shape='I.A', size='300', h=300, view=2, page=1, b='', t='', t2='', fw='', ft='', prov='gap', candidates='')
    amb = dict(level='height-only', kind='member', shape='F.B', size='100', h=100, view=2, page=1, b='', t='', t2='', fw='', ft='', prov='gap', candidates='')
    f1 = dict(full, shape='F.B', size='100X10', h=100, t='10')
    f2 = dict(full, shape='F.B', size='100X12', h=100, t='12')
    r.fill_gaps([full, gap, amb, f1, f2])
    assert gap['size'] == '300X90X11/16' and gap['prov'].startswith('correlated')
    assert amb['prov'].startswith('ambiguous') and amb['candidates'] == '100X10|100X12'
