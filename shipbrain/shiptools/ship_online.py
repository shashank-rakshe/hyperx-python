"""
ship_online.py - teaches the LLM the ONLINE method (2D structural drawing -> moulded-line ship XML) and every rule of the
rule book (ONLINE_METHOD_RULES.md v2.7 + RULES.md), and runs the same rules as checks at run time.

Why: the online build (an assistant reading a scanned engine casing drawing) worked because every step used the rules in order:
  Step 1 raw data -> Step 2 labelling -> Step 3 alignment -> Step 4 XML -> Step 5 cross-verify -> Step 6 report.
The offline tool failed mostly at Steps 1-2 (OCR spellings, weld size taken as plate thickness, labels not linked).
So the model gets one training task per weak spot, each labelled by CODE (never by hand), plus a run-time loop.

Training tasks (all text-only, answers computed by the rule functions below, so they are always right):
  ship_ocr_fix      R-T17..R-T22  noisy OCR label/note line -> corrected text + rule id
  ship_numclass     R2.1          a number with its neighbour text -> class (plate_thk / weld / section / dimension / frame /
                                  offcl / height / carling_mark / bracket_mark / door / scale)
  ship_label        R2.2-R2.19    line style + label (+ view) -> member kind / action, with rule id
  ship_joint        R4.x, R-CN8, R-BR5, R3.6, R4.11, R4.13   a joint / geometry case -> decision + computed numbers
  ship_method       steps 1-6     "what do you do at step n / with this situation" -> rule-ordered answer
  ship_members_json real online XML panels -> compact member JSON (the only format the model writes; XML is made by code)
  ship_review_plus  member table -> violations incl. PN1 (collinear pieces that must be one member) and PN4 (split at C.L)

Run time:
  core_rules()          the principles P1-P6 + the step order, always put in front of a ship prompt
  solve_ship_panel()    model reads a plan -> member JSON -> check (C3-C6, PN1, PN4) -> errors back to the model (<= 3 tries)
                        -> members_to_xml() -> validate_file()
Selftest:  python ship_online.py --selftest   (compares with deckrules textnorm / numclass when that folder is given)
"""
import json, math, re, random

# ============================================================== R-T17..R-T22  OCR normalisation (same as deckrules textnorm v2.155)
OFF_RX = re.compile(r'^(\s*\d{3,6})?\s*[*"\']*\s*OFF[\s.]*C(?:[./]|\s)*L\.?[*"\']*\s*(.*)$', re.I)
HT_RX = re.compile(r'(?<![\d.,])(\d{1,2})[.,](\d{3})(?=\s*A\s*/\s*B)')
_TOK = [
    (re.compile(r'^\s*K\s*[.,\s]?\s*L\s*[.,]?\s*$', re.I), 'K.L'),
    (re.compile(r'^\s*S\s*[.,\s]?\s*W\s*[.,]?\s*$', re.I), 'S.W'),
    (re.compile(r'^\s*C\s*[.,\s]\s*L\s*[.,]?\s*$', re.I), 'C.L'),
    (re.compile(r'^\s*[#＃]\s*(\d?)\s*[.,]?\s*$'), r'#\1'),
    (re.compile(r'^\s*OFF\s*(?:C\.?|C\.?\s*[|lI1]|\(|C\s*\.\s*\()?\s*$', re.I), 'OFF C.L'),
]
_THK_OCR = re.compile(r'^\s*([IlO|\d])(\d)?\s*[.,]\s*([0-9OoD])\s*(("?\s*AH\s*"?)?)\s*$')
_DIG = str.maketrans({'I': '1', 'l': '1', '|': '1', 'O': '0', 'o': '0', 'D': '0'})
_GLUE = [(re.compile(r'FRAME\s*SPACE', re.I), 'FRAME SPACE'), (re.compile(r'DECK\s*BEAM', re.I), 'DECK BEAM'),
         (re.compile(r'DECK\s*PLATE', re.I), 'DECK PLATE'), (re.compile(r'PLATE\s*THK', re.I), 'PLATE THK'),
         (re.compile(r'DECK\s*HEIGHT', re.I), 'DECK HEIGHT'), (re.compile(r'DECK\s*LONGL', re.I), 'DECK LONGL'),
         (re.compile(r'(\d)(U\.A|I\.A|F\.B)\b'), r'\1 \2')]
_NOTE_KEY = re.compile(r'(FRAME SPACE|DECK BEAM|DECK PLATE|PLATE THK\.?|DECK HEIGHT|DECK LONGL\.?|GIR\.\s*&\s*WEB|STIFF\.?(?:\s*SIZE)?)\s*[;:]\s*', re.I)


def fix_rule_tokens(t):
    if not t or len(t) > 14:
        return t
    for rx, rep in _TOK:
        if rx.match(t):
            return rx.sub(rep, t).strip()
    m = _THK_OCR.match(t)
    if m:
        a = (m.group(1) + (m.group(2) or '')).translate(_DIG)
        b = m.group(3).translate(_DIG)
        if a.isdigit() and b.isdigit() and 4 <= int(a) <= 60:
            return f'{int(a)}.{b}' + (' "AH"' if m.group(4) else '')
    return t


def fix_note_line(t):
    if not t or len(t) > 70 or not re.search(r'[;:]', t):
        return t
    s = t
    for rx, rep in _GLUE:
        s = rx.sub(rep, s)
    return _NOTE_KEY.sub(lambda m: m.group(1) + ' : ', s)


def fix_text(t):
    """-> (text, rule)  rule '' when unchanged.  Same order as deckrules.textnorm.fix_text."""
    s = t
    m = OFF_RX.match(s)
    if m and s.strip().upper() not in ('OFF C.L',) and len(s) < 40:
        rest = m.group(2).strip(); n = (m.group(1) or '').strip()
        s2 = (n + ' ' if n else '') + 'OFF C.L' + (' ' + rest if rest else '')
        if s2 != s:
            return s2, 'R-T17'
    if HT_RX.search(s):
        s2 = HT_RX.sub(lambda m: m.group(1) + m.group(2), s)
        if s2.count('(') > s2.count(')') and re.search(r'A\s*/\s*B\s*$', s2):
            s2 += ')'
        return s2, 'R-T18'
    if re.search(r'A\s*/\s*B\s*$', s) and s.count('(') > s.count(')'):
        return s + ')', 'R-T18'
    s2 = fix_rule_tokens(s)
    if s2 != s:
        return s2, ('R-T21' if s2 == 'OFF C.L' else 'R-T20')
    s2 = fix_note_line(s)
    if s2 != s:
        return s2, 'R-T22'
    return s, ''


def _corrupt(r, clean):
    """make an OCR-like misreading of a clean label (the kinds seen on scanned drawings)"""
    s = clean
    ops = []
    if s == 'OFF C.L':
        return r.choice(['OFF', 'OFF C.', 'OFF (', 'OFFCL', 'OFF CL', '"OFF C.L', 'OFFC.L', 'OFF C.l'])
    if s in ('K.L', 'S.W', 'C.L'):
        return r.choice([s.replace('.', ' '), s.replace('.', ''), s.replace('.', ','), s + '.'])
    if re.fullmatch(r'#\d', s):
        return r.choice(['# ' + s[1], s + '.', '＃' + s[1]])
    if re.fullmatch(r'\d{1,2}\.\d', s):
        a, b = s.split('.')
        return r.choice([a.replace('1', 'I', 1) + ',' + b, a.replace('1', 'l', 1) + '.' + b, a + '.' + b.replace('0', 'O'), a + ',' + b])
    m = re.search(r'(\d{2})(\d{3})(\s*A/B)', s)
    if m:
        return s.replace(m.group(0), m.group(1) + r.choice(['.', ',']) + m.group(2) + m.group(3)).rstrip(')') + r.choice([')', ''])
    if ':' in s:
        s = s.replace(' : ', r.choice([';', ' ; ', ';', ' :']))
        ops.append('sep')
        if r.random() < 0.6:
            s = re.sub(r'(FRAME|DECK|PLATE) (SPACE|BEAM|PLATE|THK|HEIGHT|LONGL)', r'\1\2', s)
        if r.random() < 0.5:
            s = re.sub(r'(\d) (U\.A|I\.A|F\.B)', r'\1\2', s)
    return s


OCR_CLEAN = ['OFF C.L', 'K.L', 'S.W', 'C.L', '#1', '#2', '#3', '#4', '#6', '6.0', '8.0', '10.0', '11.5', '12.0', '14.0', '20.0',
             'A - DECK PLAN(34750 A/B)', 'B - DECK PLAN(39170 A/B)', 'NAV. BRI. DECK PLAN(46840 A/B)', 'UPPER DECK PLAN(29850 A/B)',
             'FRAME SPACE : 1600mm', 'FRAME SPACE : 800mm', 'DECK BEAM : 150X90X9 U.A', 'DECK BEAM : 125X75X7 U.A',
             'DECK PLATE THK. : 10.0 (EXC. AS SHOWN)', 'DECK PLATE THK. : 8.0 (EXC. AS SHOWN)', 'DECK HEIGHT : 4600mm (AT THE CENTER)',
             'DECK GIR. & WEB : 300X90X11/16 I.A', 'STIFF. SIZE : 200X90X10/14 I.A']


def ocr_case(r):
    """only cases the rules restore exactly are used as training labels ('CL' alone is ambiguous and is left out)"""
    while True:
        clean = r.choice(OCR_CLEAN)
        bad = _corrupt(r, clean)
        fixed, rule = fix_text(bad)
        if fixed == clean:
            return bad, fixed, rule


# ============================================================== R2.1 number classification
WELD_NEAR = re.compile(r'WELD|FILLET|\bF\.P\b|F/P|PENETRATION|BEVEL|\bLEG\b|THROAT|D/F|S/F|\bGRIND', re.I)


def classify_number(text, near=''):
    """R2.1 - what a printed number IS. text = the number word, near = the words printed beside it."""
    t = text.strip(); n = near.upper()
    if re.match(r'^(?:F\.?W?|L|Z|a|D/F|S/F)\s*\d', t) or (WELD_NEAR.search(n) and not re.search(r'THK|PLATE', n)):
        return 'weld_size'
    if re.fullmatch(r'#\d?', t):
        return 'carling_mark'
    if re.fullmatch(r'B\d{2}', t) or t == 'B':
        return 'bracket_mark'
    if re.fullmatch(r'\d{3,4}\s*X\s*\d{3,4}(\s*X\s*R?\s*\d{2,3})?', t, re.I):
        a, b = [int(x) for x in re.findall(r'\d+', t)[:2]]
        if 500 <= a <= 2500 and 500 <= b <= 2500:
            return 'door_or_opening'
    if re.search(r'X', t, re.I) and re.search(r'U\.A|I\.A|F\.B|T\)|\+', t + ' ' + n, re.I):
        return 'section_size'
    if re.fullmatch(r'\d{3,4}\s*X\s*\d{2,3}(\s*X\s*\d{1,2}(\.\d)?)?', t, re.I):
        return 'section_size'
    if re.fullmatch(r'FR\.?\s*\d{1,3}([+-]\d{1,4})?', t, re.I) or ('FR' in n and re.fullmatch(r'\d{1,3}', t)):
        return 'frame'
    if 'OFF C.L' in n or re.search(r'OFF\s*C\.?L', t, re.I):
        return 'offcl'
    if re.search(r'A\s*/\s*B', t + ' ' + n):
        return 'height'
    if re.fullmatch(r'1\s*/\s*\d{2,3}', t) or 'SCALE' in n:
        return 'scale'
    if re.fullmatch(r'\d{1,2}\.\d', t):
        return 'plate_thk'
    if re.fullmatch(r'\d{2,5}', t):
        return 'dimension'
    return 'unknown'


NUM_CASES = [
    ('4.5', 'LEG LENGTH OF FILLET WELDING TO BE mm EXCEPT AS SHOWN'), ('6.0', 'MIN. WELDING LEG LENGTH(mm)'), ('F6', ''),
    ('11.5', '/// MARKED : PARTIAL PENET. WELD.( )'), ('12.0', 'inside the deck plate zone between two seams'),
    ('10.0', 'inside the wall elevation, no weld symbol'), ('14.0', 'FLOOR PLATE THK. : 14.0 (EXC. AS SHOWN)'),
    ('150X90X9 U.A', 'beside a thin dashed line'), ('300X90X11/16 I.A', 'DECK GIR. & WEB'), ('500X10+150X12 F.B(T)', 'on a heavy chain line'),
    ('150X10 F.B', 'on the edge of an opening'), ('#3', 'on a short dashed line between two beams'), ('B25', 'at a stiffener end'),
    ('700X2000XR100', 'inside a closed outline in a wall elevation'), ('1700X3020', 'inside a deck opening outline'),
    ('FR.21', 'boxed label under the plan'), ('21', 'frame-number row FR'), ('FR.24+650', 'section mark'),
    ('5160', 'OFF C.L (written over the dimension line)'), ('34750 A/B', 'deck title'), ('46840', 'A/B height mark'),
    ('840', 'in a dimension chain between two OFF C.L lines'), ('1600', 'dimension between frame ticks'), ('1/100', 'SCALE'),
    ('6.0', 'beside a weld symbol, TYP. detail'), ('8.0', 'printed in the strip zone of the deck'),
]


# ============================================================== R2.2-R2.19 line + label -> member kind
LABEL_CASES = [
    ('heavy chain line, label DEEP GIR.', 'deep girder (header size DEEP GIR. & WEB)', 'R2.2'),
    ('heavy chain line, label DEEP WEB', 'deep web frame (header size DEEP GIR. & WEB)', 'R2.2'),
    ('chain line, label GIR.', 'deck girder (header size GIR. & WEB)', 'R2.2'),
    ('chain line, label WEB', 'web frame (header size GIR. & WEB)', 'R2.2'),
    ('short dashed line with #3 printed on it', 'carling, section from the carling table #3', 'R2.2'),
    ('thin dashed line with end marks, no label', 'deck beam (header DECK BEAM size)', 'R2.2'),
    ('line with 450X10+150X12 F.B(T) printed on it', 'T-girder 450x10 web + 150x12 face flat', 'R2.2 / R-TB1'),
    ('heavy dashed line in a deck plan', 'wall of the tier BELOW: support line only, not built in this plan; confirm with its own view', 'R2.3'),
    ('solid heavy plan boundary line', 'casing wall: built from its own elevation / section, not from the plan', 'R2.4'),
    ('triangle at a member end', 'welded end ON the support', 'R2.5'),
    ('small tick at a member end', 'snipped end', 'R2.5'),
    ("'B' or 'B25' at a member end", 'bracket at that end (size from the bracket table, B25 = 250 leg)', 'R2.5'),
    ("short stub + 'B' at a wall line in a plan", "bracket of that WALL's stiffener (belongs to the wall)", 'R2.6'),
    ("'PROVISION FOR ...' area with its own outline", 'opening (no plate now), ASSUMED and asked', 'R2.8'),
    ("revision cloud (scalloped outline)", 'revision mark: not structure, removed; the lines inside it stay', 'R1.6 / R-RV1'),
    ("thick line marked 'S.W' inside a wall elevation", 'another wall meeting this wall edge-on: never a stiffener', 'R2.13'),
    ('solid stiffener line in an elevation looking to port', "stiffener on the viewer's side of the plate", 'R2.14'),
    ('dashed stiffener line in an elevation', 'stiffener on the far side of the plate', 'R2.14'),
    ("'STIFF : 200 I.A' as tier note and '150X90X9 U.A' beside one line", 'that line is 150X90X9 U.A (label beside the line beats the tier note)', 'R2.15 / P4'),
    ("'10.0' printed inside a zone bounded by S.W lines", 'wall plate 10.0 in that zone (printed zone beats the header WALL PLATE THK.)', 'R2.16'),
    ("closed outline '700X2000XR100' in a wall", 'door 700 wide, 2000 high, corner radius 100; sill height from its dimension', 'R2.17'),
    ("'#6' over a door", 'header flat bar from the carling table #6', 'R2.17'),
    ("'#2' on a horizontal line between two wall stiffeners", 'short carling at that height from stiffener to stiffener', 'R2.18'),
    ("tier drawn open under a 600 band with '150X10 F.B'", 'portal: plate only in the band, face bar 150X10 on the opening edge', 'R2.19'),
    ("'K.L' beside an OFF C.L line + 'SLANTED CAMBER 50'", 'deck flat inboard of the K.L, sloping 50 mm down to the deck edge (separate tilted panel)', 'R3.6'),
    ("weld size '6' beside a fillet symbol", 'weld size: never a plate thickness', 'R2.1'),
]


# ============================================================== joints / geometry decisions (numbers computed)
def joint_case(r):
    k = r.choice(['pn1', 'pn2', 'cn8', 'br5', 'r411', 'r36', 'r413', 'pn4'])
    if k == 'pn1':
        sec = r.choice(['150X90X9 U.A', '300X90X11/16 I.A', '125X75X7 U.A'])
        x = r.choice([1600, 3200, 4800]); y0, y1, y2 = -r.choice([3480, 5160, 7680]), 0, r.choice([3480, 5160, 7680])
        q = (f"Two pieces of {sec}: piece A from ({x},{y0}) to ({x},{y1}), piece B from ({x},{y1}) to ({x},{y2}). A girder crosses at "
             f"({x},{y1}). No end mark is drawn at the crossing. Model them as?")
        a = (f"R-PN1 / R4.6: ONE continuous member {sec} from ({x},{y0}) to ({x},{y2}); it penetrates the girder (cut-out), "
             f"it is not cut there. R4.7: a member ends only where the drawing shows an end mark, an opening or a change of type.")
    elif k == 'pn2':
        q = "A deck beam ends at a girder and a welded triangle is drawn at that end. Does it run through?"
        a = "R-PN2 / R4.7 + R2.5: no - the triangle is a welded end ON the support: the beam ends on the girder line (at its web front face, R-CN8)."
    elif k == 'cn8':
        t = r.choice([10, 11, 12]); ang = r.choice([90, 60, 45])
        d = (t / 2) / math.sin(math.radians(ang))
        q = f"A carling butts on a girder with web thickness {t} mm at {ang} deg. Where does the carling start?"
        a = (f"R-CN8 / R4.10: at the FRONT FACE of the girder web, never over the web and flange: move the end back along the carling "
             f"by (t/2)/sin(angle) = ({t}/2)/sin({ang}) = {d:.1f} mm from the girder moulded line.")
    elif k == 'br5':
        h = r.choice([150, 200, 250, 300]); leg = r.choice([200, 250, 300])
        q = (f"A deck end bracket ({leg}x{leg}) has its corner on a wall stiffener of depth {h} mm that lies in the bracket plane. "
             f"Where is the corner placed?")
        a = (f"R-BR5 / R4.15 (offline R-G5): a bracket starts OUTSIDE the members it connects: move the corner {h} mm along the "
             f"member, off the stiffener web; it must still touch the stiffener. Check R5.7: no bracket inside a stiffener web.")
    elif k == 'r411':
        top = r.choice([1800, 1900, 2000, 2100]); hh = r.choice([2600, 2850, 3200])
        q = f"A wall stiffener runs deck to deck (0..{hh}) and crosses a door opening from the deck up to {top}. Stiffener ends?"
        a = f"R4.11: the stiffener starts at the door top: from {top} to {hh} (above the header); the part inside the opening is not built."
    elif k == 'r36':
        kn = r.choice([11690, 12720, 16920]); edge = kn + r.choice([3000, 4440, 5000]); n = r.choice([50, 100])
        y = r.randint(kn - 2000, edge); z0 = r.choice([34750, 39170, 43750])
        z = z0 - n * max(0, min(y, edge) - kn) / (edge - kn)
        q = (f"Deck at {z0} A/B, 'K.L' at OFF C.L {kn}, 'SLANTED CAMBER {n}', deck edge at {edge}. Deck height at OFF C.L {y}?")
        a = (f"R3.6: flat inboard of the K.L, sloping {n} mm from the K.L to the edge: z = {z0} - {n} x max(0, {y} - {kn}) / ({edge} - {kn}) "
             f"= {z:.0f} mm. Wall tops / feet at that Y follow the same height (R3.7).")
    elif k == 'r413':
        sizes = r.choice([['B25', 'B25', 'B20'], ['B30', 'B15', 'B30'], ['B20', 'B20', 'B25']])
        common = max(set(sizes), key=sizes.count)
        q = f"Printed bracket marks on this deck: {', '.join(sizes)}. One more bracket is marked only 'B'. Its size?"
        a = f"R4.13: the most common printed size of the same deck: {common} - marked ASSUMED (A) and asked."
    else:
        q = "The deck is flat (sections draw it straight). Beams cross the centre line. Split them at C.L?"
        a = "R4.9 / R-PN4: no - a flat deck has no knuckle at C.L; the beams stay continuous across C.L (camber only if the sections draw it curved, R3.4)."
    return k, q, a


# ============================================================== method (6 steps)
METHOD_QA = [
    ("Step 1 (raw data): what do you do first with a new drawing?",
     "R1.1 page type (vector / scan; scans at >= 4 px/pt), R1.2 every view with its title and its own window, R1.3 per-view header lines, "
     "R1.4 sheet-wide tables read once (bracket table, carling #n table, angle table, camber scheme, notes), R1.5 every line and text measured "
     "but not classified, R1.6 revision clouds / review marks removed. Normalise OCR spellings (R-T17..R-T22) before Step 2."),
    ("Step 2 (labelling): what must be decided before alignment?",
     "Classify every number (R2.1: weld size is never a thickness), every line by style + label (R2.2-R2.6), plates and openings "
     "(R2.7-R2.12), wall views (R2.13-R2.19), overhangs / platforms from their sections (R2.22-R2.25). Errors here spread into Steps 3-4 (P3)."),
    ("Step 3 (alignment): how are drawing positions turned into ship coordinates?",
     "R3.1 scale per view from the two written labels farthest apart, checked by a dimension chain (1 %); X from the frame row and FRAME SPACE, "
     "Y from OFF C.L labels, Z from the A/B heights; camber only if the sections draw the deck curved (R3.4); K.L slope (R3.6); wall tops follow "
     "the deck above (R3.7)."),
    ("Step 4 (XML): what does the model write?",
     "Never raw XML: a compact member JSON per panel (outline, holes, members with id, kind, section, a, b). members_to_xml() writes the ship "
     "moulded-line XML (R4.1-R4.20): members penetrate (R-PN1), webs start at the front face (R-CN8), brackets off the stiffener (R-BR5)."),
    ("Step 5 (verify): which checks run on every build?",
     "R5.1 read the XML back and draw it over the drawing; R5.2 cross-view check; R5.4 heights; R5.5 joints (every split needs a drawn reason or is "
     "merged); R5.6 ends; R5.7 no bracket inside a web; R5.8 counts per kind vs marks; R5.9 schema (validate_xml); R5.10 printed tokens vs used."),
    ("Step 6 (report): what goes into the report?",
     "R6.x every value with its source (P2: written / dimensioned / correlated / measured / assumed), every ASSUMED value as a question with a crop, "
     "counts, check results, and the rule ids used."),
    ("Two readings are possible for one value. What do you do?",
     "P5: build the safer one, mark it (A) and ask with a crop. Never guess silently. P1: written text > dimension chain > other view > pixels."),
    ("The typical view and the specific plan disagree. Which wins?",
     "P4 / R5.3: the specific view wins; the difference is reported as a question."),
    ("A check in Step 5 fails. Where do you fix it?",
     "P3: in the step that produced it (usually Step 1-2), then rerun - a later step never repairs an earlier one."),
]


# ============================================================== extra checks for member tables
def _coll(m, o, tol=3.0):
    (ax, ay), (bx, by) = m['a'], m['b']
    for p in (o['a'], o['b']):
        cr = (bx - ax) * (p[1] - ay) - (by - ay) * (p[0] - ax)
        if abs(cr) / (math.hypot(bx - ax, by - ay) or 1) > tol:
            return False
    return True


def check_plus(t, tol=3.0):
    """PN1: two members of the same section, collinear, meeting end to end -> must be ONE member (R4.6) unless a reason is given
    ('end' field = 'welded' / 'snipped' / 'bracket' / 'opening'). PN4: a member split exactly at C.L (v=0) on a flat deck."""
    out = []
    M = t['members']
    for i in range(len(M)):
        for j in range(i + 1, len(M)):
            m, o = M[i], M[j]
            if m.get('sec') != o.get('sec') or not _coll(m, o, tol):
                continue
            for e1 in 'ab':
                for e2 in 'ab':
                    if math.dist(m[e1], o[e2]) <= tol and not (m.get('end_' + e1) or o.get('end_' + e2)):
                        msg = f"{m['id']} + {o['id']} meet end to end on one line with the same section - one continuous member (R4.6)"
                        out.append(('PN1', msg, m['id']))
                        if abs(m[e1][1]) <= tol and t.get('flat', True) and (m['a'][1] * m['b'][1] <= 0 or o['a'][1] * o['b'][1] <= 0):
                            out.append(('PN4', f"{m['id']}/{o['id']} split at C.L on a flat deck (R4.9)", m['id']))
    return out


# ============================================================== core rules for every ship prompt
def core_rules(entries=None):
    base = ("Method: Step 1 raw data -> Step 2 labelling -> Step 3 alignment -> Step 4 member JSON (code writes the XML) -> Step 5 checks -> Step 6 report.\n"
            "P1 written text > dimension chain > other view > pixels. P2 every value has a source. P3 fix the step that made the error. "
            "P4 specific beats general. P5 never guess silently: mark (A) and ask. P6 universal: only what is printed.\n"
            "R2.1 weld size is never a plate thickness. R4.6 members penetrate (no cut at crossings). R4.7 an end only where drawn. "
            "R-CN8 a butting member starts at the web front face. R4.15 brackets start outside the stiffener.")
    if entries:
        p = {e['id']: e['text'] for e in entries if re.fullmatch(r'P\d', e['id']) and e.get('file') == 'ONLINE_METHOD_RULES.md'}
        if p:
            base += "\n" + "\n".join(f"{k} {v}" for k, v in sorted(p.items()))
    return base


# ============================================================== training samples
def make_online_samples(rec, r, n, src_xmls=(), entries=None):
    """rec(kind, img, prompt, answer) is the writer of ship_xml_kit.make_ship_samples."""
    from ship_xml_kit import xml_to_members, panel_to_table, _clusters, _inject, check_table, review_answer
    cr = core_rules(entries)
    for _ in range(n):
        bad, fixed, rule = ocr_case(r)
        rec('ship_ocr_fix', None, f"OCR read this label from a scanned drawing: \"{bad}\". Give the corrected label and the rule.",
            json.dumps({'text': fixed, 'rule': rule or 'unchanged'}))
    for _ in range(n):
        t, near = r.choice(NUM_CASES)
        c = classify_number(t, near)
        rec('ship_numclass', None, f"R2.1: classify the printed number \"{t}\" (printed beside: {near or 'nothing'}).",
            json.dumps({'class': c, 'rule': 'R2.1', 'use_as_thickness': c == 'plate_thk'}))
    for _ in range(n):
        q, a, rid = r.choice(LABEL_CASES)
        rec('ship_label', None, f"What is this on a ship structural drawing: {q}?", f"{a} ({rid})")
    for _ in range(n):
        k, q, a = joint_case(r)
        rec('ship_joint', None, f"{cr}\n\nCase: {q}", a)
    for _ in range(max(1, n // 3)):
        q, a = r.choice(METHOD_QA)
        rec('ship_method', None, q, a)
    panels = []
    for p_ in src_xmls:
        try:
            M = xml_to_members(p_)
            panels += [p for b in M['blocks'] for p in b['panels'] if len(p['stiffeners']) >= 3 and not p['attrs'].get('Kind')]
        except Exception as e:
            print('skip', p_, e)
    made = tries = 0
    while panels and made < n and tries < n * 20:
        tries += 1
        p = r.choice(panels)
        tb = _clusters(p, r)
        if not tb:
            continue
        made += 1
        if r.random() < 0.5:
            js = {'panel': p['id'], 'outline': tb['outline'], 'members': tb['members']}
            rec('ship_members_json', None,
                f"{cr}\n\nWrite the member JSON (panel UV, mm) for these members of panel {p['id']}: " +
                "; ".join(f"{m['id']} {m['kind'] or 'member'} {m['sec']} from {m['a']} to {m['b']}" for m in tb['members']),
                json.dumps(js, separators=(',', ':')))
        else:
            if r.random() < 0.5 and len(tb['members']) >= 1:      # inject a PN1 split: cut one member in two at its middle
                m = r.choice(tb['members'])
                mid = [round((m['a'][0] + m['b'][0]) / 2), round((m['a'][1] + m['b'][1]) / 2)]
                tb['members'].append(dict(m, id=m['id'] + 'b', a=mid)); m['b'] = mid
            else:
                _inject(tb, r)
            f = check_table(tb) + check_plus(tb)
            rec('ship_review_plus', None,
                "Check this member table against the rules C3 closed outline, C4 unique ids, C5 no gap, C6 inside, PN1 one member, PN4 no split at C.L.\n"
                + json.dumps(tb, separators=(',', ':')), review_answer(f))


# ============================================================== run-time loop
SHIP_PANEL_PROMPT = ("{core}\n\nRelevant rules:\n{ctx}\n\nRead this deck plan and return ONLY JSON: "
                     "{{\"outline\": [[u,v],...], \"holes\": [[[u,v],...]], \"members\": [{{\"id\",\"kind\",\"sec\",\"a\":[u,v],\"b\":[u,v]}}]}} "
                     "(mm, panel UV). Mark assumed values with \"assumed\": true.")


def solve_ship_panel(ask, image_path, entries, tries=3, k=6, codes=None, extra_check=None):
    """ask(image_path, prompt) -> text. Model writes member JSON; checks C3-C6 + PN1/PN4 go back to it; then code writes the XML."""
    from ship_xml_kit import RuleIndex, check_table
    idx = RuleIndex(entries)
    ctx = "\n".join(f"- {e['id']}: {e['text'][:400]}" for e in idx.search('deck plan member girder beam carling opening end bracket penetrate', k))
    prompt = SHIP_PANEL_PROMPT.format(core=core_rules(entries), ctx=ctx)
    fb, js, f = '', None, []
    for t in range(tries):
        out = ask(image_path, prompt + fb)
        i, j = out.find('{'), out.rfind('}')
        try:
            js = json.loads(out[i:j + 1])
        except Exception:
            fb = "\n\nYour answer was not valid JSON. Return only the JSON."
            continue
        if not isinstance(js.get('members'), list):
            fb = "\n\nThe JSON has no 'members' list. Return {\"members\": [...]}."
            continue
        f = (check_table(js) if js.get('outline') else [(c, m, x) for c, m, x in check_table(dict(js, outline=[])) if c == 'C4']) + check_plus(js)
        if codes:
            f = [x for x in f if x[0] in codes]
        if extra_check:                        # measured check against the drawing (alike score), never the model's own words
            f += extra_check(js)
        if not f:
            return {'ok': True, 'table': js, 'tries': t + 1}
        fb = "\n\nYour table breaks these rules: " + "; ".join(f"{c}: {m}" for c, m, _ in f[:12]) + ". Fix them (P3: fix the reading, not the symptom)."
    return {'ok': False, 'table': js, 'errors': [f"{c}: {m}" for c, m, _ in f]}


# ============================================================== selftest
def selftest(deckrules_dir=None):
    r = random.Random(1)
    ok = 0
    assert fix_text('OFF')[0] == 'OFF C.L' and fix_text('34.750 A/B')[0] == '34750 A/B' and fix_text('FRAMESPACE;1600mm')[0] == 'FRAME SPACE : 1600mm'
    assert fix_text('I2,0')[0] == '12.0' and fix_text('K L')[0] == 'K.L' and fix_text('# 2')[0] == '#2'
    for _ in range(300):                       # every corruption must come back to its clean label
        clean = r.choice(OCR_CLEAN); bad = _corrupt(r, clean)
        got = fix_text(bad)[0]
        if got == clean:
            ok += 1
    print(f'OCR fix: {ok}/300 corruptions restored exactly')
    assert classify_number('4.5', 'LEG LENGTH OF FILLET WELDING') == 'weld_size'
    assert classify_number('14.0', 'FLOOR PLATE THK. : 14.0 WELDING') == 'plate_thk'
    assert classify_number('700X2000XR100') == 'door_or_opening' and classify_number('300X100X11') == 'section_size'
    assert classify_number('#3') == 'carling_mark' and classify_number('5160', 'OFF C.L') == 'offcl'
    tb = {'outline': [[0, -9000], [9000, -9000], [9000, 9000], [0, 9000], [0, -9000]],
          'members': [{'id': 'S1', 'sec': 'A', 'a': [1600, -5160], 'b': [1600, 0]}, {'id': 'S2', 'sec': 'A', 'a': [1600, 0], 'b': [1600, 5160]}]}
    codes = [c for c, _, _ in check_plus(tb)]
    assert 'PN1' in codes and 'PN4' in codes, codes
    if deckrules_dir:
        import sys
        sys.path.insert(0, deckrules_dir)
        from deckrules import textnorm
        same = sum(1 for _ in range(500) for c in [r.choice(OCR_CLEAN)] for b in [_corrupt(r, c)] if textnorm.fix_text(b)[0] == fix_text(b)[0])
        print(f'same result as deckrules textnorm: {same}/500')
        assert same == 500
    print('selftest OK')


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--deckrules', help='folder that holds the deckrules package (compares the OCR rules)')
    a = ap.parse_args()
    if a.selftest:
        selftest(a.deckrules)
