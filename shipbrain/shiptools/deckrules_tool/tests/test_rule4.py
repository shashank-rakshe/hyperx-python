import csv, os, tempfile
from deckrules import rule4

def _w(fp, rows):
    cols = list(rows[0])
    with open(fp, 'w', newline='') as f:
        w = csv.DictWriter(f, cols); w.writeheader(); w.writerows(rows)

def test_place_and_legend():
    d = tempfile.mkdtemp(); n = '1005-TEST'
    _w(os.path.join(d, n + '_step3_views.csv'), [dict(page=1, title='X', type='deck-plan', id='', side='', deck='A-DECK', x_mm='', y_mm='', z_mm=26128, frame='', x_src='missing', y_src='', z_src='written(title)')])
    _w(os.path.join(d, n + '_frames.csv'), [dict(page=1, row=0, title='A-DECK PLAN', deck='A-DECK', height_ab=26128, rect_x0=0, rect_y0=0, rect_x1=500, rect_y1=500, offcl_axis='x', offcl_c=250, offcl_k=100, frame_axis='y', frame_ppf=-10, frame_f0=400, frame_first=10, frame_last=40, kind='plan')])
    mem = [dict(page=1, view=0, kind='member', role='', shape='I.A', size='150X90X12', grade='', prov='written', text='t', x=300, y=300)]
    mem += [dict(page=1, view=0, kind='member', role='', shape='F.B', size='100X10', grade='', prov='written', text='t', x=100 + 5 * i, y=50) for i in range(5)]
    _w(os.path.join(d, n + '_step3_members.csv'), mem)
    out, st = rule4.run(d, n)
    p = [r for r in out if r['status'].startswith('placed')]
    assert len(p) == 1 and st['legend'] == 5
    assert p[0]['y_abs_mm'] == 5000 and p[0]['sheet_side'] == 'right' and p[0]['z_mm'] == '26128'
    assert float(p[0]['frame']) == 10.0 and p[0]['x_mm'] == ''


def test_view_placement_height_fit():
    from deckrules import rule4
    ctx = dict(items=[dict(t='10000 A/B', x=100, y=400), dict(t='12000 A/B', x=100, y=300)], u=(1, 0),
               vw=[((0, 0, 500, 500), dict(page='1', title='FR.20 SEC.', type='section', id='', side='', frame='20', x_src='written(title)', x_mm='', y_mm='', y_src='', z_mm='', z_src='', mm_per_pt='20', tx='1', ty='1', view='0'))],
               views={})
    r = rule4.place_in_view(ctx, dict(x=300, y=350, view=0))
    assert r['view_frame'] == '20' and r['z_mm'] == 11000 and r['z_src'].startswith('fit of 2')


def test_negative_frame_and_frame0_anchor():
    from deckrules import facts, ask
    m = facts.FRAME_RX.match('FR.-3 SEC.')
    assert int(m.group(1)) == -3
    m = facts.FRAME_RX.match('FR.-7+270 SEC.')
    assert int(m.group(1)) == -7 and m.group(2) == '+' and m.group(3) == '270'


def test_frame_chain_x():
    import collections
    from deckrules import ask
    d = tempfile.mkdtemp()
    n = '1003-T1'
    _w(os.path.join(d, n + '_step3_views.csv'), [dict(page=1, title='x', type='section', id='', side='', deck='', x_mm='', y_mm='', z_mm='', frame='', x_src='missing', y_src='', z_src='')])
    _w(os.path.join(d, n + '_framechain.csv'), [dict(page=1, row=1, axis='y', f_from=f, f_to=t, spacing_mm=s, measured_mm=s, source='w') for f, t, s in
                                               [(0, 1, 800), (1, 2, 850), (2, 3, 4200), (3, 4, 1950)]])
    T = {n: ask._read(os.path.join(d, n + '_step3_views.csv'))}
    with open(os.path.join(d, 'deckrules_answers.csv'), 'w') as f:
        f.write('key,answer\nframe:hull:1003:start,"0; 0"\n')
    ans = ask.load_answers(d)
    fn, src, nodes = ask.chain_x(d, T, n, ans)
    assert fn(0) == 0 and fn(2) == 1650 and fn(4) == 1650 + 4200 + 1950 and fn(2.5) == 1650 + 2100 and fn(9) is None


def test_split_two_plans_on_one_row():
    from deckrules import labels
    g = [(v, x, 985.0) for v, xs in ((2640, (628.4, 745.5)), (5160, (555.4, 816.9)), (7680, (485.8, 888.2)),
                                      (2640, (1682.4, 1799.5)), (5160, (1609.4, 1870.9)), (7680, (1539.8, 1942.2))) for x in xs]
    parts = labels._split_plans(g, 'x')
    assert len(parts) == 2 and all(len(p) == 6 for p in parts)


def test_beam_cut_at_girder():
    from deckrules import supports
    deck = {'members': [dict(kind='beam', a=(1000.0, -500.0), b=(1000.0, 5000.0), evidence=[], bracket_a=True, bracket_b=True,
                             bracket_size_a=None, bracket_size_b=None, bracket_unknown_a=False, bracket_unknown_b=False),
                        dict(kind='girder', a=(0.0, 2000.0), b=(3000.0, 2000.0), evidence=[])], 'deep': []}
    import copy
    d2 = copy.deepcopy(deck)
    # R-PN1 (default): the beam penetrates the girder - one continuous member
    assert supports.split_at_crossings(d2) == 1 and len([m for m in d2['members'] if m['kind'] == 'beam']) == 1
    # old R-G1b behaviour kept as an option
    assert supports.split_at_crossings(deck, penetrate=False) == 1
    beams = [m for m in deck['members'] if m['kind'] == 'beam']
    assert len(beams) == 2 and beams[0]['bracket_a'] and not beams[0]['bracket_b'] and beams[1]['bracket_b'] and not beams[1]['bracket_a']


def test_nl_beams_cut_at_drawn_member():
    from deckrules import supports
    nl = dict(kind='beam', a=(0.0, 880.0), b=(5000.0, 880.0), evidence=['R-NL: x'], bracket_a=False, bracket_b=False,
              bracket_size_a=None, bracket_size_b=None, bracket_unknown_a=False, bracket_unknown_b=False)
    drawn = dict(kind='beam', a=(2000.0, 0.0), b=(2000.0, 3000.0), evidence=['drawn'])
    deck = {'members': [nl, drawn], 'deep': []}
    assert supports.split_at_crossings(deck) == 1
    assert len([m for m in deck['members'] if m['evidence'][0].startswith('R-NL')]) == 2


def test_boxed_frame_rows_split_stacked_plans():
    from deckrules import labels
    it = []
    for y0 in (1000.0, 1900.0):
        for t, dy in (('FR.19+1/2', 181), ('FR.21', 113), ('FR.22+1/2', 45), ('FR.24', 0)):
            it.append({'t': t, 'x': 453.0, 'y': y0 + dy})
    rows = labels.boxed_frame_rows(it)
    assert len(rows) == 2 and all(r['first'] == 19.5 and r['last'] == 24.0 for r in rows)


def test_xv_mirror_and_confirm():
    """R-XV / R-SY2: a mirrored member is kept only where the views of that side show it; a stub without a member is reported"""
    from shapely.geometry import box
    from deckrules import crossverify as xv
    xv._CACHE[('sym', 'X.pdf')] = 'p1: BOTH SIDES ARE SYMMETRIC EXCEPT AS SHOWN'
    fp = box(0, -8000, 8000, 8000)
    mem = [{'kind': 'beam', 'a': (2000, 500), 'b': (2000, 7000), 'section': 'x', 'evidence': []},     # transverse, P side
           {'kind': 'beam', 'a': (5000, 500), 'b': (5000, 7000), 'section': 'x', 'evidence': []}]
    deck = {'z': 100.0, 'members': mem}
    cuts = [{'view': 'S elev', 'type': 'elev', 'pos': -3000.0, 'z': 100.0, 'deck': 'D', 'stubs': [2050.0, 6000.0], 'range': (0, 8000)},
            {'view': 'P elev', 'type': 'elev', 'pos': 3000.0, 'z': 100.0, 'deck': 'D', 'stubs': [2050.0, 5050.0], 'range': (0, 8000)}]
    drawn = [(2000, -500, 2000, -7000), (5000, -500, 5000, -7000), (1000, 3000, 1200, 3000)]
    log = xv.verify(deck, cuts, 'X.pdf', {}, fp, [], drawn)
    ys = sorted((round(m['a'][0]), round(m['a'][1])) for m in deck['members'])
    assert (2000, -500) in ys            # mirrored, confirmed by the S elevation
    assert (5000, -500) not in ys        # S elevation shows no cut at X=5000 -> 'except as shown'
    assert log['mirrored'] == 1 and len(log['mirror_rejected']) == 1
    assert any('X=6000' in m for m in log['missing'])


def test_xv_cover():
    from deckrules import crossverify as xv
    assert abs(xv._cover((0, 0), (1000, 0), [(0, 10, 600, 10), (500, -5, 800, -5)]) - 0.8) < 1e-6


def test_elev_label_codes():
    """R-E15: '33080 A/B' names a deck of that height (local), a known deck within 20 mm keeps its code; R-E10 split E/C label"""
    from deckrules import elevation
    class W:
        def __init__(s, t): s.text = t
    dz = {'A': 34600.0, '3': 32930.0, 'E': 41600.0}
    assert elevation._label_code(W('32930 A/B'), dz) == '3'
    assert elevation._label_code(W('33080 A/B'), dz) == 'Z33080' and dz['Z33080'] == 33080.0
    assert elevation._label_code(W('E/C MONORAIL'), dz) == 'E'
    assert elevation._label_code(W('A - DECK'), dz) == 'A'


def test_rule5_cover_and_merge():
    """Rule 5: collinear drawn pieces merge into one line; a projected XML line covers it within 2.5 pt"""
    from deckrules import verify5 as v5
    D = v5._merge_lines([((0, 10), (40, 10)), ((41, 10), (80, 10))])
    assert len(D) == 1 and D[0][2] == 0 and D[0][3] == 80
    P = v5._merge_lines([((0, 11.5), (60, 11.5))])
    assert 0.74 < v5._covered(D[0], P) < 0.8
