import os, csv, tempfile
from deckrules import ask

COLS = ['page', 'view', 'title', 'type', 'id', 'side', 'deck', 'frame', 'frame_off_mm', 'x_src', 'y_mm', 'y_src', 'z_mm', 'z_src', 'mark']


def _w(folder, name, rows):
    with open(os.path.join(folder, name + '_step3_views.csv'), 'w', newline='') as f:
        w = csv.DictWriter(f, COLS, restval='')
        w.writeheader()
        for r in rows:
            w.writerow(r)


def test_look_everywhere_then_ask():
    d = tempfile.mkdtemp()
    _w(d, '1003-A', [dict(page=1, type='deck-plan', deck='B-DECK', z_mm='', z_src='missing'), dict(page=2, type='deck-plan', deck='B-DECK', z_mm=39100, z_src='written(title)'),
                dict(page=1, type='deck-plan', deck='C-DECK', z_mm='', z_src='missing'), dict(page=1, type='deck-plan', deck='D-DECK', z_mm='', z_src='missing')])
    _w(d, '1003-B', [dict(page=1, type='deck-plan', deck='C-DECK', z_mm=42400, z_src='written(title)')])
    T, rep = ask.resolve(d)
    assert rep['same drawing'] == 1 and rep['other drawing (same hull)'] == 1
    Q = ask.questions(d, T, {})
    keys = [q['key'] for q in Q]
    assert 'deck:1003/D-DECK:z' in keys and 'deck:1003/D-DECK:camber' in keys and 'deck:1003/D-DECK:sheer' in keys and 'deck:1003/B-DECK:z' not in keys
    assert 'frame:hull:1003:start' in keys                    # nothing written in this hull -> asked once for the hull
    ans = {'deck:1003/D-DECK:z': '45000', 'deck:1003/D-DECK:camber': '100; 0; 11690', 'deck:1003/D-DECK:sheer': 'none'}
    det = ask.apply(d, T, ans)
    rows = list(csv.DictReader(open(os.path.join(d, '1003-A_step3_views.csv'))))
    assert [r['z_src'] for r in rows if r['deck'] == 'D-DECK'] == ['user']
    assert det['1003/D-DECK']['camber_from_offcl'] == '0' and det['1003/D-DECK']['camber_to_offcl'] == '11690' and det['1003/D-DECK']['sheer_n'] == 'none'
    assert not [q for q in ask.questions(d, ask.resolve(d)[0], ans) if q['key'].startswith('deck:1003/D-DECK')]   # never asked twice


def test_printed_camber_used_only_range_asked():
    d = tempfile.mkdtemp()
    _w(d, 'A', [dict(page=1, type='deck-plan', deck='B-DECK', z_mm=39100, z_src='written(title)')])
    with open(os.path.join(d, 'A_facts.csv'), 'w', newline='') as f:
        f.write('page,kind,text,x,y,type,id,side,deck\n1,title,B-DECK PLAN,100,100,deck-plan,,,B-DECK\n')
    with open(os.path.join(d, 'A_p1_text.csv'), 'w', newline='') as f:
        f.write('text,x0,y0,x1,y1\n(CAMBER : 100),300,150,340,160\n')
    T, _ = ask.resolve(d)
    Q = ask.questions(d, T, {})
    q = [x for x in Q if x['key'] == 'deck:B-DECK:camber']
    assert q and 'printed CAMBER 100' in q[0]['question']
    det = ask.apply(d, T, {'deck:B-DECK:camber': '0; 11690'})
    assert det['B-DECK']['camber_n'] == '100' and det['B-DECK']['camber_to_offcl'] == '11690' and det['B-DECK']['camber_src'] == 'printed + user range'


def test_sparse_frame_row_and_sheer_chain():
    from deckrules import labels, sheerchain
    it = [dict(t=str(v), x=2000, y=1292 - (v - 21) * 22.7) for v in (21, 23, 26, 29, 31)] + [dict(t='7', x=2000, y=5), dict(t='99', x=2000, y=900)]
    rows = labels.sparse_frame_rows(it)
    assert len(rows) == 1 and rows[0]['n'] == 5 and abs(abs(rows[0]['pt_per_frame']) - 22.7) < 0.2
    d = tempfile.mkdtemp()
    with open(os.path.join(d, 'A_p1_text.csv'), 'w', newline='') as f:
        f.write('text,x0,y0,x1,y1\nFRAME SPACE : 800,0,0,10,10\n(SHEER : 50),1860,1290,1870,1300\n1000,1845,1296,1855,1306\n')
        for v in (21, 23, 26, 29, 31):
            y = 1292 - (v - 21) * 22.7
            f.write('%d,2000,%f,2010,%f\n' % (v, y, y))
    r = sheerchain.build(d, 'A')[0]
    assert r['mode'] == 'strip' and r['dim_mm'] == 1000 and abs((r['to_fr'] - r['from_fr']) - 1.25) < 0.11


def _drawing(d, nm, text_lines, frame=20):
    _w(d, nm, [dict(page=1, view=0, type='section', id='1A-1', x_src='written', frame=frame, y_src='written'),
               dict(page=1, view=1, type='section', id='1A-2', x_src='missing', frame='', y_src='written')])
    with open(os.path.join(d, nm + '_p1_text.csv'), 'w', newline='') as f:
        f.write('text,x0,y0,x1,y1\n')
        for tx in text_lines:
            f.write('"%s",0,0,1,1\n' % tx)


def test_same_hull_only_and_user_start_frame():
    d = tempfile.mkdtemp()
    _drawing(d, '1003-AFT', ['FRAME SPACE : 800'])
    _drawing(d, '1003-DH', ['x'])
    _drawing(d, '1005-DH', ['x'])
    T, _ = ask.resolve(d)
    sp = ask.spacing(d, T)
    assert sp['1003-DH'] == 800 and sp['1005-DH'] is None                 # spacing borrowed inside the hull only
    keys = [q['key'] for q in ask.questions(d, T, {})]
    assert 'frame:1005-DH:space' in keys and 'frame:1003-DH:space' not in keys
    assert 'frame:hull:1003:start' in keys and 'frame:hull:1005:start' in keys   # asked once per hull
    ask.apply(d, T, {'frame:hull:1003:start': '18; 0', 'frame:1005-DH:space': '700'})
    for nm, x in (('1003-AFT', (20 - 18) * 800), ('1003-DH', (20 - 18) * 800)):   # the answer serves the whole hull
        v = list(csv.DictReader(open(os.path.join(d, nm + '_step3_views.csv'))))
        assert v[0]['x_mm'] == str(x) and 'user' in v[0]['x_src'] and v[1]['x_mm'] == ''
    v = list(csv.DictReader(open(os.path.join(d, '1005-DH_step3_views.csv'))))
    assert v[0]['x_mm'] == ''                                              # other hull: nothing borrowed, no start frame yet


def test_general_arrangement_gives_the_start_frame():
    d = tempfile.mkdtemp()
    _drawing(d, '1003-GA', ['GENERAL ARRANGEMENT', 'A.P. (FR.18)', 'FRAME SPACE : 800'], frame=19)
    _drawing(d, '1003-DH', ['FRAME SPACE : 800'], frame=20)
    T, _ = ask.resolve(d)
    assert not [q for q in ask.questions(d, T, {}) if q['key'].endswith(':start')]
    ask.apply(d, T, {})
    v = list(csv.DictReader(open(os.path.join(d, '1003-DH_step3_views.csv'))))
    assert v[0]['x_mm'] == str(2 * 800) and 'general arrangement 1003-GA' in v[0]['x_src']
    _drawing(d, '1003-X', ['FR.19 = 800 mm', 'FRAME SPACE : 800'], frame=21)       # agrees with A.P. at FR.18
    T, _ = ask.resolve(d)
    assert '1003-DH' in ask.anchors(d, T, ask.spacing(d, T))
    _drawing(d, '1003-X', ['FR.19 = 15200 mm', 'FRAME SPACE : 800'], frame=21)      # contradicts A.P. at FR.18 -> nothing guessed, user asked
    T, _ = ask.resolve(d)
    assert '1003-DH' not in ask.anchors(d, T, ask.spacing(d, T))
    assert 'frame:hull:1003:start' in [q['key'] for q in ask.questions(d, T, {})]


def test_frame_answer_forms():
    for v in ('18; 0', 'FR.18 = 0 mm', '18, 0', 'FR 18  0'):
        assert ask.anchor_answer(v) == (18, 0)
    assert ask.anchor_answer('FR.19 = 15,200 mm') == (19, 15200) and ask.anchor_answer('x') is None


def test_user_frame_table_excel():
    import openpyxl
    d = tempfile.mkdtemp()
    _drawing(d, '1007-DH', ['FRAME SPACE : 1540'], frame=80)
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(['Frame', 'X (mm)'])
    for f, x in ((79, 100000), (80, 101540), (82, 104700), (86, 110900)):
        ws.append([f, x])
    wb.save(os.path.join(d, 'frame_table_1007.xlsx'))
    T, _ = ask.resolve(d)
    assert not [q for q in ask.questions(d, T, {}) if q['key'].endswith(':start')]      # the table answers it
    ask.apply(d, T, {})
    v = list(csv.DictReader(open(os.path.join(d, '1007-DH_step3_views.csv'))))
    assert v[0]['x_mm'] == '101540' and 'user frame table' in v[0]['x_src']
    assert ask.table_x({79: 100, 82: 400}, 80)[0] == 200 and ask.table_x({79: 100, 82: 400}, 90)[0] is None
