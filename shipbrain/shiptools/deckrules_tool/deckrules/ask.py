"""Step 3 (Rule 3) - what is NOT written anywhere: look further, then ASK the user (owner rule v2.88).

Order for a missing deck height (Z of a deck):
  1. same drawing, every page      (a written height of the same deck)
  2. every other drawing in the folder (same deck name)
  3. nothing / several different values  -> ask the user
Also asked (never guessed, never taken from scaling):
  - for a deck that is asked: camber (height n, from which OFF C.L to which OFF C.L) and sheer (n, from which frame to which frame), or 'none'
  - the X distance of the frame start, when no drawing in the folder gives any frame row
  - the OFF C.L (Y) of a section/elevation that has no written Y and no cut mark
Answers are kept in <folder>/deckrules_answers.csv, so a question is never asked twice and applies to every drawing of the folder.
Ways to ask: window (tkinter) -> console -> headless file <folder>/deckrules_questions.csv (fill 'answer', run again).
"""
import csv, os, re, sys, glob, collections, argparse

ANS = 'deckrules_answers.csv'
QST = 'deckrules_questions.csv'
DET = 'deckrules_deck_details.csv'
YTYPES = ('section', 'elevation', 'longitudinal-elevation')


def _read(fp):
    with open(fp, encoding='utf-8', newline='') as f:
        return list(csv.DictReader(f))


def _write(fp, rows, cols):
    with open(fp, 'w', encoding='utf-8', newline='') as f:
        w = csv.DictWriter(f, cols, extrasaction='ignore')
        w.writeheader()
        w.writerows(rows)


def drawings(folder):
    return sorted(os.path.basename(f)[:-len('_step3_views.csv')] for f in glob.glob(os.path.join(folder, '*_step3_views.csv')))


def _dk(d):
    return (d or '').strip().upper()


HULL_RX = re.compile(r'(?<![0-9A-Za-z])H?(\d{4})(?![0-9])', re.I)


def hull_of(name):
    """hull number = the first 4-digit number of the drawing name ('1003-AFT-...', 'H1008-3H-...', '1007 3H8...'); '' if none."""
    m = HULL_RX.search(name)
    return m.group(1) if m else ''


def dkey(name, deck):
    h = hull_of(name)
    return (h + '/' if h else '') + _dk(deck)


def same_hull(T, name):
    """the other drawings that may be used to complete this one: the same hull number only (a drawing without a hull number borrows from nobody)"""
    h = hull_of(name)
    return [n for n in T if n != name and h and hull_of(n) == h]


def load_answers(folder):
    fp = os.path.join(folder, ANS)
    return {r['key']: r['answer'].strip() for r in _read(fp) if r.get('answer', '').strip()} if os.path.exists(fp) else {}


def save_answers(folder, ans):
    _write(os.path.join(folder, ANS), [dict(key=k, answer=v) for k, v in sorted(ans.items())], ['key', 'answer'])


FS_RX = re.compile(r'FRAME\s*SPACE\s*:?\s*(\d[\d,]{2,5})')


def spacing(folder, T):
    """written FRAME SPACE (mm): {drawing: value}; a drawing without its own note takes the one of the other drawings of the folder (single distinct value only)."""
    own = {}
    for name in T:
        v = []
        for tf in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')):
            m = re.search(r'_p(\d+)_text\.csv$', tf)
            if m and os.path.basename(tf)[:-len(m.group(0))] == name:
                for r in _read(tf):
                    mm = FS_RX.search(r['text'].upper())
                    if mm:
                        v.append(int(mm.group(1).replace(',', '')))
        if v:
            own[name] = collections.Counter(v).most_common(1)[0][0]
    out = {}
    for n in T:
        allv = {own[o] for o in same_hull(T, n) if o in own}
        out[n] = own.get(n, next(iter(allv)) if len(allv) == 1 else None)
    return out


FT_NAME = re.compile(r'frame', re.I)
FT_SKIP = re.compile(r'(_frames|_framechain|_step4|_facts|_text|_step3|_plans|_viewscale|_sheerchain|_marks|_index|_views|_paths|_segments|_images|_textnorm|deckrules_).*\.csv$', re.I)


def _table_rows(fp):
    if fp.lower().endswith('.csv'):
        with open(fp, encoding='utf-8-sig', newline='') as f:
            return [list(r) for r in csv.reader(f)]
    import openpyxl
    wb = openpyxl.load_workbook(fp, read_only=True, data_only=True)
    ws = wb.worksheets[0]
    return [list(r) for r in ws.iter_rows(values_only=True)]


def _num(v):
    try:
        return float(str(v).replace(',', '').replace('FR.', '').replace('FR', '').strip())
    except ValueError:
        return None


def frame_tables(folder):
    """the user's frame table (Excel / csv in the folder, file name contains 'frame'): frame number -> X distance mm.
    The header row says which column is which ('frame'/'fr' and 'x'/'mm'/'distance'); without a header the first two numeric columns are used.
    A hull number in the file name ties the table to that hull; otherwise it serves every hull of the folder. -> {hull or '': {frame: x_mm}}"""
    out = {}
    for fp in sorted(glob.glob(os.path.join(folder, '*.xlsx')) + glob.glob(os.path.join(folder, '*.xlsm')) + glob.glob(os.path.join(folder, '*.csv'))):
        b = os.path.basename(fp)
        if not FT_NAME.search(b) or FT_SKIP.search(b) or b.startswith('~$'):
            continue
        try:
            rows = _table_rows(fp)
        except Exception:
            continue
        ci = cx = None
        for r in rows[:10]:
            lo = [str(c).strip().lower() if c is not None else '' for c in r]
            f_ = [i for i, c in enumerate(lo) if c in ('frame', 'fr', 'fr.', 'frame no', 'frame no.', 'frame number', 'frame_no')]
            x_ = [i for i, c in enumerate(lo) if re.search(r'^(x|x\s*\(?mm\)?|mm|dist\w*.*|x[ _]?mm|x[ _]?dist\w*)$', c)]
            if f_ and x_:
                ci, cx = f_[0], x_[0]
                break
        tab = {}
        for r in rows:
            a, b2 = (_num(r[ci]), _num(r[cx])) if ci is not None and len(r) > max(ci, cx) else ((_num(r[0]), _num(r[1])) if len(r) > 1 else (None, None))
            if a is not None and b2 is not None and float(a).is_integer():
                tab[int(a)] = b2
        if len(tab) >= 2:
            h = hull_of(b)
            out.setdefault(h, {}).update(tab)
    return out


def table_x(tab, frame, off=0.0):
    """exact frame -> X; between two listed frames -> linear; outside the table -> None (nothing extrapolated)"""
    if frame in tab:
        return tab[frame] + off, 'table'
    ks = sorted(tab)
    lo = [k for k in ks if k < frame]
    hi = [k for k in ks if k > frame]
    if lo and hi:
        a, b = lo[-1], hi[0]
        return tab[a] + (tab[b] - tab[a]) * (frame - a) / (b - a) + off, 'table (interpolated %d..%d)' % (a, b)
    return None, ''


AP_RX = re.compile(r'A\.?\s?P\.?\s*[(=:\- ]+\s*(?:AT\s*)?FR\.?\s*(-?\d+)|FR\.?\s*(-?\d+)\s*[(=:\- ]+\s*A\.?\s?P\b', re.I)
EQ_RX = re.compile(r'\bFR\.?\s*(-?\d+)\s*[=@]\s*(-?\d[\d,]{0,7})\s*(?:MM)?\b', re.I)
GA_RX = re.compile(r'GENERAL\s+ARRANGEMENT|\bG\.?A\.?\s+PLAN', re.I)


def _texts(folder, name):
    for tf in sorted(glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv'))):
        m = re.search(r'_p(\d+)_text\.csv$', tf)
        if m and os.path.basename(tf)[:-len(m.group(0))] == name:
            for r in _read(tf):
                yield r['text']


def anchors(folder, T, SP=None):
    """frame start anchor (frame number, X mm) written in the drawings of the same hull - typically the general arrangement:
       'FR.n = x mm'  or  'A.P. (FR.n)' (X origin at A.P.).  {drawing: (frame, x_mm, source)}; none written / contradicting -> no entry (the user is asked)"""
    byhull = collections.defaultdict(list)
    for n in T:
        byhull[hull_of(n) or ('?' + n)].append(n)
    out = {}
    for h, names in byhull.items():
        cand = []
        for n in names:
            ga = any(GA_RX.search(t or '') for t in _texts(folder, n))
            for t in _texts(folder, n):
                for m in AP_RX.finditer(t or ''):
                    cand.append((int(m.group(1) or m.group(2)), 0, '%s: A.P. at FR.%s (X origin at A.P.)' % ('general arrangement ' + n if ga else n, m.group(1) or m.group(2))))
                for m in EQ_RX.finditer(t or ''):
                    cand.append((int(m.group(1)), int(m.group(2).replace(',', '')), '%s: FR.%s = %s mm' % ('general arrangement ' + n if ga else n, m.group(1), m.group(2))))
        if not cand:          # owner rule v2.105: a drawing that writes frame 0 / negative frames (FR.-3) or a TRANSOM starts at that end: frame 0 = X origin
            for n in names:
                tx = [t or '' for t in _texts(folder, n)]
                if any(re.search(r'\bFR\.?\s?(?:0|-\d{1,3})\b(?!\s*[+-]?\s*\d)', t, re.I) or re.search(r'\bTRANSOM\b', t, re.I) for t in tx):
                    cand.append((0, 0, '%s: frame 0 / negative frames / TRANSOM written (X origin at frame 0, owner rule)' % n))
                    break
        sp = next((SP[n] for n in names if SP and SP.get(n)), None)
        distinct = {(a, b) for a, b, _ in cand}
        ok = len(distinct) == 1 or (sp and len(distinct) > 1 and len({b - a * sp for a, b in distinct}) == 1)
        if cand and ok:
            for n in names:
                out[n] = cand[0]
    return out


def frame_found(folder, T):
    """does the drawing (or any other drawing of the folder) give a frame row - consecutive or sparse integer labels?  {drawing: bool}"""
    from . import labels
    own = {}
    for name in T:
        ok = False
        for tf in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')):
            m = re.search(r'_p(\d+)_text\.csv$', tf)
            if m and os.path.basename(tf)[:-len(m.group(0))] == name:
                items = []
                for r in _read(tf):
                    t = (r['text'] or '').strip()
                    if t:
                        items.append(dict(t=t, x=(float(r['x0']) + float(r['x1'])) / 2, y=(float(r['y0']) + float(r['y1'])) / 2))
                if labels.frame_rows(items) or labels.sparse_frame_rows(items, 4):
                    ok = True
                    break
        own[name] = ok
    return own


# ------------------------------------------------------------------ 1-2: look in every page / every drawing first
def _isnum(v):
    return str(v).strip().lstrip('-').isdigit()


def resolve(folder):
    """Fill missing deck heights from the same drawing (all pages), then from other drawings of the folder. Returns (tables, report)."""
    T = {n: _read(os.path.join(folder, n + '_step3_views.csv')) for n in drawings(folder)}
    for rows in T.values():
        for r in rows:
            r['_miss'] = (r['deck'] != '' and '~' not in r['deck'] and r['type'] in ('deck-plan', 'arrangement') and r['z_mm'] == '')
    rep = collections.Counter()
    for name, rows in T.items():
        for r in rows:
            if not r['_miss']:
                continue
            for scope, pool in (('same drawing', [name]), ('other drawing (same hull)', same_hull(T, name))):
                vals = collections.defaultdict(set)
                for n in pool:
                    for o in T[n]:
                        if _dk(o['deck']) == _dk(r['deck']) and _isnum(o['z_mm']) and o['z_src'].startswith(('written', 'user')):
                            vals[int(o['z_mm'])].add(n)
                if len(vals) == 1:
                    z, srcs = next(iter(vals.items()))
                    r['z_mm'] = z
                    r['z_src'] = 'correlated(%s: %s)' % (scope, sorted(srcs)[0] if scope.startswith('other') else 'all pages')
                    r['_miss'] = False
                    rep[scope] += 1
                    break
                if len(vals) > 1:
                    r['_cand'] = sorted(vals)
                    rep['ambiguous'] += 1
                    break
    return T, rep


# ------------------------------------------------------------------ printed camber / sheer values (read from the drawings, offline)
PRINT_RX = re.compile(r'(CAMBER|SHEER)\s*:?\s*(\d{2,4})\b')


def printed(folder, T):
    """'(CAMBER : 100)', 'SLANTED : CAMBER 100', '(SHEER : 50)' ... -> {deck: {'camber': {n,...}, 'sheer': {n,...}}}.
    The value belongs to the deck of the nearest title on the same page (a deck-plan / arrangement title that names one deck)."""
    out = collections.defaultdict(lambda: dict(camber=set(), sheer=set()))
    for name in T:
        fp = os.path.join(folder, name + '_facts.csv')
        if not os.path.exists(fp):
            continue
        tit = collections.defaultdict(list)
        for r in _read(fp):
            if r['kind'] == 'title' and r['deck'] and '~' not in r['deck'] and r['type'] in ('deck-plan', 'arrangement'):
                tit[r['page']].append((float(r['x']), float(r['y']), _dk(r['deck'])))
        for tf in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')):
            m = re.search(r'_p(\d+)_text\.csv$', tf)
            if not m or os.path.basename(tf)[:-len(m.group(0))] != name or m.group(1) not in tit:
                continue
            for r in _read(tf):
                mm = PRINT_RX.search(r['text'].upper())
                if not mm:
                    continue
                x, y = float(r['x0']), float(r['y0'])
                d = min(tit[m.group(1)], key=lambda t: (t[0] - x) ** 2 + (t[1] - y) ** 2)
                if (d[0] - x) ** 2 + (d[1] - y) ** 2 <= 1500 ** 2:
                    out[dkey(name, d[2])][mm.group(1).lower()].add(int(mm.group(2)))
    return out


def chain(folder, T):
    """sheer ranges read from the dimension chain (Step 2 sheerchain.py): {deck: [(n, from_fr, to_fr), ...]}"""
    out = collections.defaultdict(list)
    for name in T:
        fp = os.path.join(folder, name + '_sheerchain.csv')
        if os.path.exists(fp):
            for r in _read(fp):
                if r['deck'] and r['from_fr'] != '' and r['to_fr'] != '':
                    out[dkey(name, r['deck'])].append((int(r['n']), float(r['from_fr']), float(r['to_fr'])))
    return out


# ------------------------------------------------------------------ 3: what is still unknown -> questions
def questions(folder, T, ans):
    Q = []

    def add(key, q, hint=''):
        if key not in ans and not any(x['key'] == key for x in Q):
            Q.append(dict(key=key, question=q, hint=hint, answer=''))
    decks = {}
    for name, rows in T.items():
        for r in rows:
            if r.get('_miss'):
                decks.setdefault(dkey(name, r['deck']), set()).update(r.get('_cand', []))
    PR = printed(folder, T)
    CH = chain(folder, T)
    for d, kinds in sorted(PR.items()):          # value printed on the drawing: only the range is asked
        for kind, rng, ex in (('camber', 'OFF C.L', '0; 11690'), ('sheer', 'frame', '180; 190')):
            v = sorted(kinds[kind])
            if v and not (kind == 'sheer' and CH.get(d)):      # sheer range already read from the dimension chain
                add('deck:%s:%s' % (d, kind), 'Deck %s: printed %s %s found on the drawing. %s from which %s to which %s?  (from; to, e.g. %s; or "none")' %
                    (d, kind.upper(), ' / '.join(map(str, v)), kind.capitalize(), rng, rng, ex), 'from; to' + ('   (several printed values: %s - add the one to use first: n; from; to)' % v if len(v) > 1 else ''))
    for d, cand in sorted(decks.items()):
        k = 'deck:%s:' % d
        if (k + 'z') not in ans:
            add(k + 'z', 'Deck %s: height (Z, mm) is not written in any page of any drawing in this folder. Height of deck?' % d,
                ('several different values found: %s - which one?' % ', '.join(map(str, sorted(cand)))) if cand else 'number, mm')
        if (k + 'camber') not in ans and not PR[d]['camber']:
            add(k + 'camber', 'Deck %s: camber? "none", or  height; from OFF C.L; to OFF C.L   (e.g. 100; 0; 11690)' % d, 'none | n; from; to')
        if (k + 'sheer') not in ans and not PR[d]['sheer']:
            add(k + 'sheer', 'Deck %s: sheer? "none", or  height; from frame; to frame   (e.g. 50; 180; 190)' % d, 'none | n; from FR; to FR')
    SP = spacing(folder, T)
    AN = anchors(folder, T, SP)
    FTAB = frame_tables(folder)
    asked = set()
    for name in T:
        if SP[name] is None and ('frame:%s:space' % name) not in ans and not chain_intervals(folder, T, name, ans):
            add('frame:%s:space' % name, '%s: FRAME SPACE (mm between frames) is not written in this drawing or in another drawing of the same hull. Frame spacing in mm?' % name, 'mm')
        h = hull_of(name)
        gk = ('frame:hull:%s:start' % h) if h else ('frame:%s:start' % name)
        if name not in AN and gk not in ans and ('frame:%s:start' % name) not in ans and gk not in asked and not (FTAB.get(h) or FTAB.get('')):
            asked.add(gk)
            grp = [n for n in T if hull_of(n) == h] if h else [name]
            add(gk, 'Hull %s (%s): no start frame / frame distance is written in these drawings or in a general arrangement of this hull. '
                'Which frame number, and what is its distance in mm from the X origin?' % (h or '-', ', '.join(grp)), 'frame; distance mm   (e.g. FR.18 = 0 mm, or 18; 0)')
    for name in T:                         # gaps in the chain of written frame spacings (owner rule v2.106): no drawing writes the spacing between two reached frames
        h = hull_of(name) or name
        for a, b in chain_gaps(folder, T, name, ans):
            add('gap:%s:%g:%g' % (h, a, b), 'Hull %s: no drawing writes the frame spacing between frame %g and frame %g (the chain of written spacings stops there). Spacing in mm per frame?' % (h, a, b), 'mm per frame (one value; or "none" if unknown)')
    for name, rows in T.items():           # views whose frame (X) could not be found in any drawing -> X distance in mm
        seen = set()
        for r in rows:
            if r.get('x_src', 'missing').split('(')[0] == 'missing' and r.get('frame', '') == '' and r['type'] != 'arrangement' and r.get('x_mm', '') == '':
                k = 'x:%s:%s' % (name, ('%s:%s' % (r['id'], r['side'])) if r['id'] else 'p%s:v%s' % (r['page'], r.get('view', '')))
                if k not in seen:
                    seen.add(k)
                    add(k, '%s p%s %s %s%s: frame / X distance not found in any drawing of the folder. X distance in mm? (blank = unknown)' %
                        (name, r['page'], r['type'], r['id'] or r.get('title', '')[:30], (' ' + r['side']) if r['side'] else ''), 'mm')
    for name, rows in T.items():
        seen = set()
        for r in rows:
            if r['type'] == 'longitudinal-elevation' and r.get('longl_no') and r['y_mm'] == '' and r['y_src'] == 'missing':
                k = 'longl:%s:%s' % (name, r['longl_no'])          # inner longitudinal NO.n: its OFF C.L (Y) is not written
                if k not in seen:
                    seen.add(k)
                    add(k, '%s p%s NO.%s LONGL. ELEV.: OFF C.L of longitudinal number %s (number 1 nearest the centre line) is not written. OFF C.L in mm? (blank = unknown)' %
                        (name, r['page'], r['longl_no'], r['longl_no']), 'mm')
            elif r['type'] in YTYPES and r['id'] and r['y_mm'] == '' and r['y_src'].split('(')[0] == 'missing' and not r.get('mark'):
                k = 'y:%s:%s:%s' % (name, r['id'], r['side'])
                if k not in seen:
                    seen.add(k)
                    add(k, '%s p%s %s %s%s: no OFF C.L (Y) written. OFF C.L in mm? (blank = leave unknown)' % (name, r['page'], r['type'], r['id'], (' ' + r['side']) if r['side'] else ''), 'mm')
    return Q


# ------------------------------------------------------------------ ask
def ask_gui(Q):
    import tkinter as tk
    from tkinter import ttk
    root = tk.Tk()
    root.title('deckrules - details not found in the drawings')
    tk.Label(root, text='These are not written in any drawing of the folder (and cannot come from scaling). Please enter them; blank = unknown.',
             wraplength=760, justify='left').pack(padx=10, pady=6, anchor='w')
    holder = tk.Frame(root)
    holder.pack(fill='both', expand=True, padx=10)
    cv = tk.Canvas(holder, width=780, height=420)
    sb = ttk.Scrollbar(holder, orient='vertical', command=cv.yview)
    inner = tk.Frame(cv)
    inner.bind('<Configure>', lambda e: cv.configure(scrollregion=cv.bbox('all')))
    cv.create_window((0, 0), window=inner, anchor='nw')
    cv.configure(yscrollcommand=sb.set)
    cv.pack(side='left', fill='both', expand=True)
    sb.pack(side='right', fill='y')
    vars_ = []
    for q in Q:
        tk.Label(inner, text=q['question'], wraplength=740, justify='left').pack(anchor='w', pady=(8, 0))
        v = tk.StringVar()
        tk.Entry(inner, textvariable=v, width=60).pack(anchor='w')
        if q['hint']:
            tk.Label(inner, text=q['hint'], fg='gray').pack(anchor='w')
        vars_.append(v)
    tk.Button(root, text='OK', width=12, command=root.destroy).pack(pady=8)
    root.mainloop()
    for q, v in zip(Q, vars_):
        q['answer'] = v.get().strip()


def ask_console(Q):
    for q in Q:
        print('\n' + q['question'] + ('\n  [' + q['hint'] + ']' if q['hint'] else ''))
        q['answer'] = input('> (Enter = skip, q = skip all) ').strip()
        if q['answer'].lower() == 'q':
            q['answer'] = ''
            break


def ask(folder, Q, mode='auto'):
    """returns True if the questions were answered now, False if left in the headless file"""
    if not Q:
        return True
    if mode == 'auto':
        gui = False
        try:
            import tkinter  # noqa
            gui = bool(os.environ.get('DISPLAY') or sys.platform in ('win32', 'darwin'))
        except Exception:
            pass
        mode = 'gui' if gui else ('console' if sys.stdin.isatty() else 'headless')
    if mode == 'gui':
        try:
            ask_gui(Q)
            return True
        except Exception as e:
            print('window not possible (%s); using the console' % e)
            mode = 'console' if sys.stdin.isatty() else 'headless'
    if mode == 'console':
        ask_console(Q)
        return True
    _write(os.path.join(folder, QST), Q, ['key', 'question', 'hint', 'answer'])
    print('%d question(s) written to %s - fill the "answer" column, copy rows into %s (key,answer) or rename, and run again.' % (len(Q), os.path.join(folder, QST), ANS))
    return False


# ------------------------------------------------------------------ apply the answers
def _parts(v, n):
    p = [x.strip() for x in re.split(r'[;,]', v)]
    return (p + [''] * n)[:n]


def _frac(f):
    """'1/5' -> 0.2 (a fraction of one frame, from 'FR.11 + 1/5 SEC.'); '' -> 0"""
    m = re.match(r'^(-?)(\d+)/(\d+)$', f or '')
    return (-1 if m.group(1) else 1) * int(m.group(2)) / int(m.group(3)) if m and int(m.group(3)) else 0.0


def anchor_answer(v):
    """'18; 0'  'FR.18 = 0 mm'  '18, 15200'  'FR 19 15,200 mm' -> (18, 0): frame number first, then its distance in mm"""
    nums = re.findall(r'-?\d[\d,]*', v or '')
    nums = [int(n.replace(',', '')) for n in nums if n.replace(',', '').lstrip('-').isdigit()]
    return (nums[0], nums[1]) if len(nums) >= 2 else None


# ---------------------------------------------------------------- frame chain (owner rule v2.106): X of a frame = sum of the spacings WRITTEN between the frame labels
def chain_intervals(folder, T, name, ans=None):
    """[(a, b, spacing_mm)] with a < b: every gap between frame labels whose spacing a drawing of the same hull writes (<name>_framechain.csv, Step 2).
    The same gap written in several rows: the most frequent value; a coarse gap that finer gaps already tile is dropped (AHD '11 -> 9: 800' vs 9->10 800, 10->11 850)."""
    h = hull_of(name)
    names = [n for n in T if (hull_of(n) == h if h else n == name)]
    votes = collections.defaultdict(collections.Counter)
    for n in names:
        fp = os.path.join(folder, n + '_framechain.csv')
        if os.path.exists(fp):
            for r in _read(fp):
                if r['spacing_mm'] != '':
                    a, b = sorted((float(r['f_from']), float(r['f_to'])))
                    votes[(a, b)][int(r['spacing_mm'])] += 1
    for k, v in (ans or {}).items():                       # the user's answer for a gap: key gap:<hull>:<a>:<b>
        m = re.match(r'^gap:%s:(-?[\d.]+):(-?[\d.]+)$' % re.escape(h or name), k)
        if m and _isnum(v):
            votes[(float(m.group(1)), float(m.group(2)))][int(v)] += 1000
    iv = {k: c.most_common(1)[0][0] for k, c in votes.items()}
    acc = []
    for (a, b) in sorted(iv, key=lambda k: (k[1] - k[0], k[0])):
        inside = sorted((x, y) for (x, y, _) in acc if x >= a - 1e-9 and y <= b + 1e-9 and (x, y) != (a, b))
        pos = a
        for x, y in inside:
            if x <= pos + 1e-9:
                pos = max(pos, y)
        if inside and pos >= b - 1e-9:
            continue                                        # tiled by finer gaps
        acc.append((a, b, iv[(a, b)]))
    return sorted(acc)


def chain_x(folder, T, name, ans=None, SP=None):
    """-> (function frame -> X mm or None, source text, nodes) ; None when the hull has no written gaps or no anchor (GA / frame 0 / user)"""
    iv = chain_intervals(folder, T, name, ans)
    if not iv:
        return None, '', {}
    SP = SP or spacing(folder, T)
    AN = anchors(folder, T, SP)
    h = hull_of(name)
    fa = (AN[name][0], AN[name][1]) if name in AN else None
    src = AN[name][2] if name in AN else ''
    v = (ans or {}).get('frame:%s:start' % name) or ((ans or {}).get('frame:hull:%s:start' % h) if h else None)
    if v and anchor_answer(v):
        fa, src = anchor_answer(v), 'user'
    if not fa:
        return None, '', {}
    node = {float(fa[0]): float(fa[1])}
    changed = True
    while changed:
        changed = False
        for a, b, s in iv:
            if a in node and b not in node:
                node[b] = node[a] + s * (b - a)
                changed = True
            elif b in node and a not in node:
                node[a] = node[b] - s * (b - a)
                changed = True

    def fn(f):
        f = float(f)
        if f in node:
            return node[f]
        for a, b, s in iv:
            if a < f < b and a in node:
                return node[a] + s * (f - a)
            if a < f < b and b in node:
                return node[b] - s * (b - f)
        return None
    return fn, 'frame chain of written spacings (anchor frame %s = X %s; %s)' % (fa[0], fa[1], src), node


def chain_gaps(folder, T, name, ans=None):
    """gaps in the chain that stop the anchor from reaching frames the drawings use: [(a, b)] = nearest reached frame below / lowest frame above"""
    iv = chain_intervals(folder, T, name, ans)
    fn, src, node = chain_x(folder, T, name, ans)
    if not iv or not node:
        return []
    allf = sorted({x for a, b, _ in iv for x in (a, b)})
    lost = [f for f in allf if f not in node]
    out = []
    for f in lost:
        below = [x for x in node if x < f]
        if below and not any(x < f and x > max(below) for x in lost):
            pass
    prev_known = None
    for f in allf:
        if f in node:
            prev_known = f
        elif prev_known is not None and f > prev_known:
            nxt = [x for x in allf if x > prev_known and x not in node]
            if nxt and (prev_known, nxt[0]) not in out:
                out.append((prev_known, nxt[0]))
            prev_known = None
    return out


def apply(folder, T, ans):
    det = {}
    PR = printed(folder, T)
    CH = chain(folder, T)
    SP = spacing(folder, T)
    if ans.get('frame:space', '').isdigit():
        SP = {n: v or int(ans['frame:space']) for n, v in SP.items()}
    FA, FA_SRC = {}, {}
    FTAB = frame_tables(folder)
    AN = anchors(folder, T, SP)
    for name in T:
        if name in AN:
            FA[name], FA_SRC[name] = (AN[name][0], AN[name][1]), AN[name][2]
        h = hull_of(name)
        v = ans.get('frame:%s:start' % name) or (ans.get('frame:hull:%s:start' % h) if h else None)
        if v and anchor_answer(v):
            FA[name], FA_SRC[name] = anchor_answer(v), 'user'
        if ans.get('frame:%s:space' % name, '').isdigit():
            SP[name] = int(ans['frame:%s:space' % name])
    for name, rows in T.items():
        fa = FA.get(name)
        tab = FTAB.get(hull_of(name)) or FTAB.get('')
        cfn, csrc, _nodes = chain_x(folder, T, name, ans, SP)
        has_chain = bool(chain_intervals(folder, T, name, ans))
        for r in rows:
            d = dkey(name, r['deck'])
            if r['deck'] and ('deck:%s:z' % d) in ans and r['z_mm'] == '' and _isnum(ans['deck:%s:z' % d]):
                r['z_mm'], r['z_src'] = int(ans['deck:%s:z' % d]), 'user'
            if r['deck'] and r['type'] in ('deck-plan', 'arrangement'):
                dd = det.setdefault(d, dict(deck=d, z_mm='', z_src='', camber_n='', camber_from_offcl='', camber_to_offcl='', camber_src='', sheer_src='', sheer_n='', sheer_from_fr='', sheer_to_fr=''))
                if dd['z_mm'] == '' and r['z_mm'] != '':
                    dd['z_mm'], dd['z_src'] = r['z_mm'], r['z_src']
            r.setdefault('x_mm', '')
            r.setdefault('x_end_mm', '')
            kx = 'x:%s:%s' % (name, ('%s:%s' % (r['id'], r['side'])) if r['id'] else 'p%s:v%s' % (r['page'], r.get('view', '')))
            if kx in ans and _isnum(ans[kx]) and r['x_mm'] == '':
                r['x_mm'], r['x_src'] = int(ans[kx]), 'user'
            elif r['x_mm'] == '' and r.get('frame', '') != '' and (tab or cfn or (fa and SP.get(name) and not has_chain)):
                try:
                    fr = str(r['frame'])
                    off = float(r['frame_off_mm']) if r.get('frame_off_mm') not in ('', None) else 0.0
                    ends = [float(x) for x in fr.split('..')] if '..' in fr else [float(fr) + _frac(r.get('frame_frac', ''))]
                    xs, how = [], ''
                    for e in ends:
                        x = None
                        if tab and float(e).is_integer():
                            x, how = table_x(tab, int(e), off if len(ends) == 1 else 0.0)
                        if x is None and cfn:
                            cv = cfn(e)
                            if cv is not None:
                                x, how = cv + (off if len(ends) == 1 else 0.0), 'frame ' + csrc
                        if x is None and fa and SP.get(name) and not has_chain:
                            x, how = fa[1] + (e - fa[0]) * SP[name] + (off if len(ends) == 1 else 0), 'frame x %s mm (frame %d = X %d mm; %s)' % (SP[name], fa[0], fa[1], FA_SRC[name])
                        xs.append(None if x is None else round(x))
                    if None not in xs:
                        r['x_mm'] = xs[0]
                        r['x_end_mm'] = xs[-1] if len(xs) > 1 else ''
                        r['x_src'] = r.get('x_src', '') + ' + ' + (how if how.startswith('frame') else 'user frame table: ' + how)
                except ValueError:
                    pass
            k = 'y:%s:%s:%s' % (name, r['id'], r['side'])
            if r.get('longl_no'):
                k = 'longl:%s:%s' % (name, r['longl_no'])
            if k in ans and r['y_mm'] == '' and _isnum(ans[k]):
                sg = -1 if r['side'] == 'S' else 1
                r['y_mm'], r['y_src'] = sg * int(ans[k]) if r.get('longl_no') else int(ans[k]), 'user'
    for d in list(PR) + list(CH):
        det.setdefault(d, dict(deck=d, z_mm='', z_src='', camber_n='', camber_from_offcl='', camber_to_offcl='', camber_src='', sheer_src='', sheer_n='', sheer_from_fr='', sheer_to_fr=''))
    for d, dd in det.items():
        for key, cols in (('camber', ('camber_n', 'camber_from_offcl', 'camber_to_offcl')), ('sheer', ('sheer_n', 'sheer_from_fr', 'sheer_to_fr'))):
            v = ans.get('deck:%s:%s' % (d, key))
            pv = sorted(PR[d][key]) if d in PR else []
            if v and v.lower() == 'none':
                dd[cols[0]] = 'none'
                continue
            if key == 'sheer' and not v and CH.get(d):          # read from the dimension chain
                rs = sorted(set(CH[d]))
                dd['sheer_n'] = '|'.join(str(a) for a, _, _ in rs)
                dd['sheer_from_fr'] = '|'.join('%g' % b for _, b, _ in rs)
                dd['sheer_to_fr'] = '|'.join('%g' % c for _, _, c in rs)
                dd['sheer_src'] = 'printed + dimension chain (+-0.5 frame)'
                continue
            p = [x for x in _parts(v or '', 3) if x != ''] if v else []
            if len(p) == 3:
                dd[cols[0]], dd[cols[1]], dd[cols[2]] = p
                dd[key + '_src'] = 'user'
            elif len(p) == 2 and len(pv) == 1:            # printed value + user range
                dd[cols[0]], dd[cols[1]], dd[cols[2]] = str(pv[0]), p[0], p[1]
                dd[key + '_src'] = 'printed + user range'
            elif len(pv) == 1:                            # printed value, range still unknown
                dd[cols[0]] = str(pv[0])
                dd[key + '_src'] = 'printed (range unknown)'
            elif len(pv) > 1:
                dd[cols[0]] = '|'.join(map(str, pv))
                dd[key + '_src'] = 'printed (several)'
    for name, rows in T.items():
        cols = [c for c in rows[0].keys() if not c.startswith('_')] if rows else []
        for c in ('x_mm', 'x_end_mm'):
            if rows and c not in cols:
                cols.append(c)
        for r in rows:
            r.setdefault('x_mm', '')
            r.setdefault('x_end_mm', '')
        _write(os.path.join(folder, name + '_step3_views.csv'), rows, cols)
    _write(os.path.join(folder, DET), sorted(det.values(), key=lambda x: x['deck']),
           ['deck', 'z_mm', 'z_src', 'camber_n', 'camber_from_offcl', 'camber_to_offcl', 'camber_src', 'sheer_n', 'sheer_from_fr', 'sheer_to_fr', 'sheer_src'])
    return det


def run(folder, mode='auto'):
    T, rep = resolve(folder)
    ans = load_answers(folder)
    Q = questions(folder, T, ans)
    done = ask(folder, Q, mode)
    if done:
        for q in Q:
            if q['answer']:
                ans[q['key']] = q['answer']
        save_answers(folder, ans)
        Q = []
    apply(folder, T, ans)
    print('deck heights found in same drawing %d, in other drawings %d, ambiguous %d; questions left open %d'
          % (rep['same drawing'], rep['other drawing (same hull)'], rep['ambiguous'], len(Q)))
    return T, rep, Q


def main(argv=None):
    ap = argparse.ArgumentParser(description='look in every drawing of the folder, then ask for what is not written')
    ap.add_argument('folder')
    ap.add_argument('--mode', choices=['auto', 'gui', 'console', 'headless'], default='auto')
    a = ap.parse_args(argv)
    run(a.folder, a.mode)


if __name__ == '__main__':
    main()
