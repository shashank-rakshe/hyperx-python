"""Step 2 (Rule 2 e) - the facts table.  Every WRITTEN fact on a page, parsed once, with its place:
<name>_pN_facts.csv  kind | text | x | y | + parsed fields
  title   : type(section|elevation|longitudinal-elevation|deck-plan|plan|arrangement|detail|view), id, side(P|S), deck, height, offcl
  frame   : frame_no, frame_off   ('FR.31+350')
  height  : height                ('(42400 A/B)')
  member  : shape, size, h, b, t, t2, fw, ft, cond, role, grade, level(full|height-only)
  plate   : role, size(thickness)
Step 3 reads this table and the plans/marks tables; it parses no text itself."""
import csv, os, re, glob

NOTE_RX = re.compile(r'\b(ALL|NOTE|LOOKING|CONSTITUTES|TRADE SECRET|SHIP DESIGN|SEC\.NO|HISTORY|DWG|SCALE|REMARK)\b', re.I)
TITLE_RX = re.compile(r'(SEC\.|SECTION|ELEV\.|ELEVATION|\bPLAN\b|DETAIL|\bVIEW\b)', re.I)
ID_RX = re.compile(r'^\W*"?\s*([0-9A-Z]{1,3}[0-9A-Z]*-\d{1,3})\s*"?\s*(SEC|ELEV|SECTION|ELEVATION|VIEW)', re.I)
SIDE_RX = re.compile(r'\(\s*([PS])\s*\)')
HEIGHT_RX = re.compile(r'(\d{3,6})\s*A\s*/\s*B', re.I)
OFFCL_RX = re.compile(r'(\d{3,6})\s*OFF\s*C\.?\s*L', re.I)
FRAME_RX = re.compile(r'\bFR\.?\s?(-?\d{1,3})(?:\s*([+-])\s*(\d{1,4})(?:\s*/\s*(\d{1,2}))?)?', re.I)       # FR.12 | FR.14+1150 (mm) | FR.11 + 1/5 (a fraction of one frame)
DECKPLAN_RX = re.compile(r'^\W*(.*?)\s*DECK\s+PLAN', re.I)
# member size:  HxBxT[/T2] shape   |  Wh X t + Fw X ft F.B(T)  |  H shape (height only)
SHAPE = r'(I\.?A|U\.?A|F\.?B|L\.?A|H\.?A|T\.?B|B\.?B)'
M_ANGLE = re.compile(r'(\d{2,4})\s*X\s*(\d{2,3})\s*X\s*(\d{1,3}(?:\.\d)?)(?:\s*/\s*(\d{1,3}(?:\.\d)?))?\s*(?:["\']{1,2}[A-Z]{1,3}["\']{1,2}\s*)?' + SHAPE, re.I)
M_TBAR = re.compile(r'(\d{2,4})\s*X\s*(\d{1,3}(?:\.\d)?)\s*\+\s*(\d{2,4})\s*X?\s*(\d{1,3}(?:\.\d)?)\s*F\.?B\s*(?:\(\s*([A-Z0-9, ]+?)\s*\))?', re.I)
M_TRIP = re.compile(r'(?<![\dX+/.])(\d{2,4})\s*X\s*(\d{1,3}(?:\.\d)?)\s*T\.?B\b', re.I)       # '250X10.0 T.B' : T.B = tripping bracket (plate size)
M_FLAT = re.compile(r'(?<![\dX+/.])(\d{2,4})\s*X\s*(\d{1,3}(?:\.\d)?)\s*F\.?B\s*(?:\(\s*([A-Z0-9, ]+?)\s*\))?', re.I)
M_HONLY = re.compile(r'^\W*(\d{2,4})\s*(I\.?A|U\.?A|F\.?B|L\.?A)\s*(?:\(\s*([A-Z0-9, ]+?)\s*\))?\W*$', re.I)
ROLE_RX = re.compile(r'(DEEP\s+GIR\.?\s*&?\s*WEB|GIR\.?\s*&?\s*WEB|GIR\.?|DECK\s+BEAM|STIFF\.?(?:\s+SIZE)?|LONGL\.?|BKT\.?|BRACKET|FACE\s+BAR|PILLAR|WEB\s+FRAME|TRANS\.?|BEAM)', re.I)
THK_RX = re.compile(r'(PLATE\s+THK\.?|DECK\s+PLATE|SHELL\s+PLATE|THK\.?)\s*:?\s*(\d{1,3}(?:\.\d)?)', re.I)
GRADE_RX = re.compile(r'\b(AH\d{2}|DH\d{2}|EH\d{2}|AH|DH|EH|A|B|D|E)\b(?=\s*$)')


def classify_title(t):
    """-> dict(type, id, side, deck, height, offcl) or None.  Written title text only (universal for ship drawings)."""
    s = t.strip()
    if len(s) > 80 or not (TITLE_RX.search(s) or re.match(r"^\W*ARRG'?T\b", s, re.I)) or NOTE_RX.search(s):
        return None
    if re.match(r'^\W*SIM(\.|ILAR)\s+TO\b', s, re.I) or re.match(r'^\(.*\b(SEC|ELEV)\w*\.?\s*~', s, re.I):
        return None                      # 'SIM. TO FR.11 + 1/5 SEC. EXC. AS SHOWN' is a note under a view; '(FR.11+1/5 SEC. ~ FR.15 SEC.)' is the sheet's contents list
    if re.match(r'^\d+\.\s', s) or re.search(r'[a-z]{4,}', s):      # numbered notes and sentences ('Added or rearranged the view.') are not view titles
        return None
    side = (SIDE_RX.search(s) or [None, ''])[1] if SIDE_RX.search(s) else ''
    h = HEIGHT_RX.search(s)
    oc = OFFCL_RX.search(s)
    m = ID_RX.match(s)
    d = DECKPLAN_RX.match(s)
    arr = re.match(r"^\W*ARRG'?T\b.*?\bON\s+(.*?)\s*\.?\s*-?\s*DECK", s, re.I)
    if arr:
        dk = re.sub(r'\s*-\s*', '-', arr.group(1).strip().upper().rstrip('.')).strip('-')
        return dict(type='arrangement', id='', side='', deck=dk + ('-DECK' if len(dk) <= 3 else ' DECK'), height=None, offcl=None)
    if (oc or re.search(r'\bNO\.?\s*\d+\s*L(ONGL)?\b', s, re.I)) and re.search(r'ELEV', s, re.I):     # '7750 OFF C.L ELEV.' or 'NO.1 LONGL. ELEV.' (the longitudinal's own line)
        typ = 'longitudinal-elevation'
    elif d:
        typ = 'deck-plan'
    elif m:
        typ = 'elevation' if m.group(2).upper().startswith('ELEV') else 'section'
    elif re.search(r'\bPLAN\b', s, re.I):
        typ = 'plan'
        if h and not re.search(r'LONGL|HORI|STIFF|SHELL|GIR|WEB', s, re.I):
            typ = 'deck-plan'            # a deck is sometimes titled only 'NO.3 STR. PLAN (14960 A/B)': a plan with a deck height A/B is a deck plan
    elif re.search(r'ELEV', s, re.I):
        typ = 'elevation'
    elif re.search(r'SEC', s, re.I):
        typ = 'section'
    elif re.search(r'DETAIL', s, re.I):
        typ = 'detail'
    else:
        typ = 'view'
    deck = ''
    if d and d.group(1).strip():
        deck = re.sub(r'\s*-\s*', '-', d.group(1).strip().upper()).strip('-').strip()
        deck = deck + ('-DECK' if len(deck) <= 3 else ' DECK')
    if typ == 'deck-plan' and not deck:
        sd = re.match(r'^\W*(NO\.?\s*\d+\s*STR\.?)', s, re.I)
        deck = re.sub(r'\s+', ' ', re.sub(r'NO\.?\s*(\d+)\s*STR\.?', r'NO.\1 STR.', sd.group(1).upper())) if sd else ''
    return dict(type=typ, id=(m.group(1).upper() if m else ''), side=side,
                deck=deck, height=int(h.group(1)) if h else None, offcl=int(oc.group(1)) if oc else None)




def norm_text(t):
    t = t.replace('×', 'X').replace('✕', 'X')
    t = re.sub(r'(\d)\s+(\d{1,3})\s*F\.?B', r'\1X\2 F.B', t) if re.search(r'\+\s*\d+\s+\d+\s*F', t) else t
    return t


def parse_member(t):
    """-> dict(shape,size,h,b,t,t2,fw,ft,grade,role) or None"""
    s = norm_text(t)
    role = ROLE_RX.search(s)
    role = re.sub(r'\s+', ' ', role.group(1).upper()) if role else ''
    g = GRADE_RX.search(s.strip())
    grade = g.group(1) if g and re.search(r'\bAH|DH|EH', s) else ''
    q = re.search(r'["\']([ADE]H\d{0,2})["\']', s)         # grade written in quotes: 250X90X10/15 "AH" I.A
    grade = q.group(1) if q else grade
    m = M_TBAR.search(s)
    if m:
        return dict(shape='T-bar(F.B(T))', size='%sX%s+%sX%s' % m.group(1, 2, 3, 4), h=int(m.group(1)), b='', t=m.group(2), t2='',
                    fw=m.group(3), ft=m.group(4), cond=(m.group(5) or ''), role=role, grade=grade, level='full')
    m = M_ANGLE.search(s)
    if m:
        sh = m.group(5).upper().replace('.', '')
        sh = sh[0] + '.' + sh[1]
        sz = '%sX%sX%s' % m.group(1, 2, 3) + ('/%s' % m.group(4) if m.group(4) else '')
        role = 'TRIPPING BRACKET' if sh == 'T.B' else role
        return dict(shape=sh, size=sz, h=int(m.group(1)), b=m.group(2), t=m.group(3), t2=m.group(4) or '', fw='', ft='',
                    cond='', role=role, grade=grade, level='full')
    m = M_TRIP.search(s)
    if m:
        return dict(shape='T.B', size='%sX%s' % m.group(1, 2), h=int(m.group(1)), b='', t=m.group(2), t2='', fw='', ft='', cond='',
                    role='TRIPPING BRACKET', grade=grade, level='full')
    m = M_FLAT.search(s)
    if m:
        return dict(shape='F.B', size='%sX%s' % m.group(1, 2), h=int(m.group(1)), b='', t=m.group(2), t2='', fw='', ft='',
                    cond=(m.group(3) or ''), role=role, grade=grade, level='full')
    m = M_HONLY.match(s)
    if m:
        sh = m.group(2).upper().replace('.', '')
        return dict(shape=sh[0] + '.' + sh[1], size=m.group(1), h=int(m.group(1)), b='', t='', t2='', fw='', ft='',
                    cond=(m.group(3) or ''), role=('TRIPPING BRACKET' if sh == 'TB' else role), grade=grade, level='height-only')
    return None



LONGL_NO_RX = re.compile(r'^\W*(?:ONLY\s+)?NO\.?\s*(\d[\d\-,~&\s]*?)\s*(?:NO\.?\s*)?(SIDE\s+SHELL\s+|S\.?\s*SHELL\s+|S\.S\.?\s+)?(?:L\.|LONGL|HORI|STIFF)', re.I)


def longl_numbers(t):
    """'NO.57 SIDE SHELL LONGL. PLAN' -> ('57', True); 'NO.58-1 ~ 60-1 LONGL.: ...' -> ('58-1~60-1', False); not a longitudinal reference -> None"""
    m = LONGL_NO_RX.match(t.strip())
    if not m:
        return None
    toks = re.findall(r'\d+(?:-\d+)?|~', m.group(1))
    return ''.join(toks) if '~' in toks else '|'.join(toks), bool(m.group(2))


COLS = ['page', 'kind', 'text', 'x', 'y', 'type', 'id', 'side', 'deck', 'height', 'offcl', 'longl_no', 'shell', 'frame_no', 'frame_off', 'frame_frac',
        'shape', 'size', 'h', 'b', 't', 't2', 'fw', 'ft', 'cond', 'role', 'grade', 'level']


def _fl(v):
    try:
        return float(v)
    except Exception:
        return 0.0


def build(folder, name, pages=None):
    pgs = pages or sorted(int(m.group(1)) for m in (re.search(r'_p(\d+)_text\.csv$', f) for f in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')))
                          if m and os.path.basename(m.string)[:-len(m.group(0))] == name)
    rows = []
    for pg in pgs:
        for r in csv.DictReader(open(os.path.join(folder, '%s_p%d_text.csv' % (name, pg)), encoding='utf-8')):
            t = (r.get('text') or '').strip()
            if not t:
                continue
            x = round((_fl(r['x0']) + _fl(r['x1'])) / 2, 1)
            y = round((_fl(r['y0']) + _fl(r['y1'])) / 2, 1)
            base = dict(page=pg, text=t[:100], x=x, y=y)
            info = classify_title(t)
            tf = {}
            if info:
                m0 = FRAME_RX.match(t.strip().lstrip('"\'( '))
                if m0 and info['type'] == 'section':            # 'FR.11 + 1/5 SEC.' : the frame is written IN the title - it is the view's own frame, not a frame tick of the drawing
                    sg = 1 if m0.group(2) != '-' else -1
                    fr_ = ('%s%s/%s' % ('-' if sg < 0 else '', m0.group(3), m0.group(4))) if (m0.group(3) and m0.group(4)) else ''
                    tf = dict(frame_no=int(m0.group(1)), frame_off=(int(m0.group(3)) * sg if (m0.group(3) and not m0.group(4)) else 0), frame_frac=fr_)
                rows.append(dict(base, kind='title', type=info['type'], id=info['id'], side=info['side'], deck=info['deck'],
                                 height=info['height'] if info['height'] is not None else '', offcl=info['offcl'] if info['offcl'] is not None else '', **tf))
            m = FRAME_RX.search(t)
            if m and len(t) < 24 and not tf:
                sg = 1 if m.group(2) != '-' else -1
                frac = ''
                if m.group(3) and m.group(4):                      # '+ 1/5' = one fifth of a frame, not 1 mm
                    frac = '%s%s/%s' % ('-' if sg < 0 else '', m.group(3), m.group(4))
                off = int(m.group(3)) * sg if (m.group(3) and not m.group(4)) else 0
                rows.append(dict(base, kind='frame', frame_no=int(m.group(1)), frame_off=off, frame_frac=frac))
            h = HEIGHT_RX.search(t)
            if h:
                rows.append(dict(base, kind='height', height=int(h.group(1))))
            pm = parse_member(t) if len(t) < 90 else None
            if pm:
                rows.append(dict(base, kind='member', **{k: pm[k] for k in ('shape', 'size', 'h', 'b', 't', 't2', 'fw', 'ft', 'cond', 'role', 'grade', 'level')}))
            if len(t) < 24 and re.match(r'^\W*NO\.?\s*\d[\d\-]*\s*L(?:ONGL)?\.?\s*$', t, re.I):
                rows.append(dict(base, kind='longl_tag'))                       # 'NO.57 LONGL.' tag drawn beside a member of a frame section
            th = THK_RX.search(t) if len(t) < 60 else None
            if th:
                rows.append(dict(base, kind='plate', shape='PLATE', size=th.group(2), t=th.group(2), role=re.sub(r'\s+', ' ', th.group(1).upper()), level='full'))
    # side shell longitudinals (owner rule v2.100b): the numbers from the first one titled SIDE SHELL upward lie ON the side shell
    firsts = []
    for r in rows:
        ln = longl_numbers(r['text'])
        if ln:
            r['longl_no'] = ln[0]
            if ln[1]:
                firsts.append(int(re.match(r'\d+', ln[0]).group(0)))
    shell_from = min(firsts) if firsts else None
    for r in rows:
        if r.get('longl_no') and shell_from is not None:
            r['shell'] = 'side shell' if int(re.match(r'\d+', r['longl_no']).group(0)) >= shell_from else 'inner'
    with open(os.path.join(folder, name + '_facts.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, COLS, extrasaction='ignore')
        w.writeheader()
        w.writerows(rows)
    return rows


def load(folder, name):
    fp = os.path.join(folder, name + '_facts.csv')
    if not os.path.exists(fp):
        build(folder, name)
    out = []
    for r in csv.DictReader(open(fp, encoding='utf-8')):
        r['page'] = int(r['page'])
        r['x'] = float(r['x'])
        r['y'] = float(r['y'])
        out.append(r)
    return out
