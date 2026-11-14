"""Under-deck members from a calibrated plan view (drawing only).

 R-HM  Hidden members are the thin DASHED paths (long-dash family) inside the
       deck footprint.  Each path is one member trace; the drawing already
       stops it at its supports.  Thick dashed lines are walls of the tier
       below and short thick dashes are bracket symbols - not members.
 R-LB  Member type from the nearest parallel label within 6 pt:
         'GIR.' / 'WEB'           -> header  GIR. & WEB
         'DEEP GIR.' / 'DEEP WEB' -> header  DEEP GIR. & WEB (web panel + face)
         '#' / '#n'               -> CARLING table (note 6) entry
         printed size with leader -> that size (alias table for short forms)
       Unlabelled transverse member -> header DECK BEAM.
 R-SY  Note 1 'BOTH SIDES ARE SYMMETRIC EXCEPT AS SHOWN': an unlabelled member
       takes the label of its mirror image about C.L when that exists.
Everything is reported with its evidence; nothing is read from the sample XML.
"""
import math
import os
import re
from shapely.geometry import LineString, Point

LABEL_GAP = 6.0          # pt, label to line (perpendicular)
DEEP = re.compile(r'^DEEP\s+(GIR|WEB)')
GIRWEB = re.compile(r'^(GIR\.|WEB)$')
CARL = re.compile(r'^#(\d?)$')
SEC = re.compile(r'(?P<h>\d{2,3})\s*(?:X\s*(?P<w>\d{1,3}))?(?:\s*X\s*(?P<t>\d{1,2}(?:\.\d)?))?(?:\s*/\s*(?P<t2>\d{1,2}))?\s*(?P<k>U\.A|I\.A|F\.B|R\.B|S\.B|L\.A)')


BRK_CALLOUT = re.compile(r'^(\d{2,3})\s*X\s*(\d{1,2}(?:\.\d)?)$')
BRK_CALLOUT_DIST = 45.0   # page pt between the B mark and its callout
CALLOUT_BRACKETS = True
CALLOUT_TIP_DIST = 30.0   # page pt between a callout leader tip and the member end it points at
BMARK_DIST = 14.0      # page pt: a 'B' this close to a member end marks a bracket


def parse_section(text, aliases=None):
    """'250X90X12/16 I.A' -> ('L',250,90,12,16); '100X7 F.B' -> ('F',100,7)."""
    t = re.sub(r'"\s*[A-Z]{1,2}\d{0,2}\s*"', ' ', text).strip()        # R-GR1: grade marks are not part of the size
    t = re.sub(r'F\.B\s+\(T\)', 'F.B(T)', t)
    # R-TB1: 'WxT + wxt F.B(T)' (also 'WxT+wxt F.B(T)') = T section: web W x T, face flange w x t -> ('TB', W, T, w, t)
    mt = re.search(r'(\d{2,4})\s*X\s*(\d{1,2}(?:\.\d)?)\s*\+\s*(\d{2,4})\s*X\s*(\d{1,2}(?:\.\d)?)\s*F\.?B\s*\(\s*T\s*\)', t)
    if mt:
        return ('TB', int(mt.group(1)), float(mt.group(2)), int(mt.group(3)), float(mt.group(4)))
    if aliases:
        key = ' '.join(t.replace('(A)', '').split())
        for k, v in aliases.items():
            if ' '.join(k.split()) == key:
                return tuple(v)
    m = SEC.search(t)
    if not m:
        return None
    h = int(m.group('h'))
    w = m.group('w')
    th = m.group('t')
    t2 = m.group('t2')
    k = m.group('k')
    if k in ('U.A', 'I.A', 'L.A'):
        if w is None or th is None:
            return None            # short form needs the alias table
        tw = float(th)
        tf = float(t2) if t2 else tw
        return ('L', h, int(w), tw, tf)
    if k == 'F.B':
        if w is None:
            return None
        return ('F', h, float(w))
    if k == 'R.B':
        return ('R', h)
    return None


def sheet_sizes(page):
    """full printed angle sizes on the sheet, for resolving short forms."""
    full = {}
    for w in page.words:
        for m in SEC.finditer(w.text):
            if m.group('w') and m.group('t') and m.group('k') in ('U.A', 'I.A'):
                sec = parse_section(m.group(0))
                full.setdefault((int(m.group('h')), m.group('k')), set()).add(sec)
    return full


GLOBAL_CARL = {}      # sheet-wide carling table (first page that prints note 6), set by the runners


def carling_table(page):
    """note 6 'TYPICAL SIZE OF CARLING': mark -> section."""
    tab = {}
    rows = [w for w in page.words if CARL.match(w.text.strip())]
    for w in rows:
        cand = [u for u in page.words if u is not w and abs(u.cy - w.cy) < 3 and 20 < u.cx - w.cx < 120
                and 'F.B' in u.text]
        if cand:
            sec = parse_section(min(cand, key=lambda u: u.cx - w.cx).text)
            if sec:
                tab.setdefault(w.text.strip(), sec)
    return tab


_SHEET_CARL = {}


def sheet_carling(pdf):
    if not pdf:
        return {}
    if pdf not in _SHEET_CARL:
        t = {}
        try:
            from . import pdfsrc
            import fitz
            for p in range(len(fitz.open(pdf))):
                t1 = carling_table(pdfsrc.load_page(pdf, p))
                if len(t1) >= 3:
                    t = t1
                    break
        except Exception:
            t = {}
        _SHEET_CARL[pdf] = t
    return _SHEET_CARL[pdf]


def _path_lines(page, v, fp):
    by = {}
    for s in page.segs:
        if s.width < 0.5 and s.dash.startswith('dash2') and s.length > 0.5:
            nums = [float(x) for x in s.dash.split(':')[1].split(',')]
            if nums[0] < 4.0:               # short-dash family: symbols
                continue
            by.setdefault(s.pid, []).append(s)
        elif s.width >= 0.5 and s.dash.startswith('dash4') and s.length > 0.5:
            # R-DG: deep girders/webs are drawn as thick chain lines; kept only if labelled DEEP
            by.setdefault(s.pid, []).append(s)
    out = []
    core = fp.buffer(2.0)
    for pid, ss in by.items():
        pts = [ss[0].a] + [q.b for q in ss]
        a, b = pts[0], pts[-1]
        L = math.dist(a, b)
        if L < 3:
            continue
        line = LineString([a, b])
        if line.intersection(core).length < 0.8 * L:
            if os.environ.get('MDBG'):
                print('MDBG drop footprint', round(line.intersection(core).length / L, 2), round(v.X(a[0])), round(v.Y(a[1])), round(v.X(b[0])), round(v.Y(b[1])))
            continue
        # straightness check
        if any(line.distance(Point(p)) > 0.6 for p in pts):
            if os.environ.get('MDBG'):
                print('MDBG drop straight', round(v.X(a[0])), round(v.Y(a[1])), round(v.X(b[0])), round(v.Y(b[1])))
            continue
        out.append({'pid': pid, 'a': a, 'b': b, 'line': line, 'thick_chain': ss[0].width >= 0.5})
    return out


def _orient(a, b):
    dx, dy = abs(b[0] - a[0]), abs(b[1] - a[1])
    if dy < 0.03 * dx:
        return 'H'
    if dx < 0.03 * dy:
        return 'V'
    return 'D'


def _label_dist(w, m):
    """perpendicular distance from label to member when it lies alongside."""
    a, b = m['a'], m['b']
    o = m['o']
    if o == 'H':
        x0, x1 = sorted((a[0], b[0]))
        if not (x0 - 3 <= w.cx <= x1 + 3):
            return None
        return abs(w.cy - a[1])
    if o == 'V':
        y0, y1 = sorted((a[1], b[1]))
        if not (y0 - 3 <= w.cy <= y1 + 3):
            return None
        return abs(w.cx - a[0])
    d = m['line'].distance(Point(w.cx, w.cy))
    return d


def extract(page, v, fp, settings):
    aliases = dict(settings.get('section_aliases', {}))
    # R-SF: short form 'NNN I.A' -> the one full size of that depth/type printed on the sheet
    for (h, k), secs in sheet_sizes(page).items():
        key = f'{h} {k}'
        if key not in aliases and len(secs) == 1:
            aliases[key] = list(next(iter(secs)))
    carl = carling_table(page)
    if len(carl) < 3:                      # R-CT: the carling size table is printed once per sheet (first page): use it for every page
        carl = dict(sheet_carling(settings.get('_pdf')) or GLOBAL_CARL)
    hdr = {k: parse_section(v.notes[k], aliases) for k in ('beam', 'girder') if k in v.notes}
    deep = v.notes.get('deep')
    mem = _path_lines(page, v, fp)
    for m in mem:
        m['o'] = _orient(m['a'], m['b'])
        m['kind'] = None
        m['section'] = None
        m['evidence'] = []
    words = [w for w in page.words if fp.buffer(15).contains(Point(w.cx, w.cy))]
    # R-LB labels
    for w in words:
        t = ' '.join(w.text.split())
        kind = None
        if DEEP.match(t):
            kind = 'deep'
        elif GIRWEB.match(t):
            kind = 'girder'
        elif CARL.match(t):
            kind = 'carling'
        if not kind:
            continue
        best = None
        for m in mem:
            if m['thick_chain'] and kind != 'deep':
                continue
            if kind in ('girder', 'deep'):
                # label text runs along its member
                if (m['o'] == 'H') == w.vertical and m['o'] != 'D':
                    continue
            d = _label_dist(w, m)
            if d is not None and d <= LABEL_GAP and (best is None or d < best[0]):
                best = (d, m)
        if best:
            m = best[1]
            if kind == 'carling':
                m['kind'] = 'carling'
                m['section'] = carl.get(t)
                m['mark'] = t
                m['evidence'].append(f"mark '{t}' -> carling table {carl.get(t)}")
            elif m['kind'] != 'carling':
                m['kind'] = kind
                m['section'] = hdr.get('girder') if kind == 'girder' else ('T', deep)
                m['evidence'].append(f"label '{t}' -> header {v.notes.get('girder' if kind == 'girder' else 'deep')}")
    # R-DG3: 'DEEP WEB' / 'DEEP GIR.' label that found no chain/dash line: the deep web is drawn as a thin SOLID line right beside its label (EC NO.5 STR.: FR.22 deep web).
    # Take the collinear solid run of that line (touching segments, same x or y within 0.6 pt) that passes the label, inside the footprint.
    bound = {id(m) for m in mem if m['kind'] == 'deep'}
    for w in words:
        t = ' '.join(w.text.split())
        if not DEEP.match(t) or not w.vertical:
            continue
        if any(m['kind'] == 'deep' and _label_dist(w, m) is not None and _label_dist(w, m) <= LABEL_GAP for m in mem):
            continue
        xs = [q for q in page.segs if not q.dash and q.width < 0.5 and abs(q.a[0] - q.b[0]) < 0.6 and q.length > 4
              and (w.bbox[0] - LABEL_GAP) <= q.a[0] <= (w.bbox[2] + LABEL_GAP) and min(q.a[1], q.b[1]) - 2 <= w.cy <= max(q.a[1], q.b[1]) + 2]
        if not xs:
            continue
        x0 = min(xs, key=lambda q: abs(q.a[0] - w.cx)).a[0]
        col = sorted([q for q in page.segs if not q.dash and q.width < 0.5 and abs(q.a[0] - q.b[0]) < 0.6 and abs(q.a[0] - x0) < 0.8 and q.length > 1],
                     key=lambda q: min(q.a[1], q.b[1]))
        # contiguous runs as [ya, yb] pairs
        runs = []
        for q in col:
            ya, yb = sorted((q.a[1], q.b[1]))
            if runs and ya <= runs[-1][1] + 3:
                runs[-1][1] = max(runs[-1][1], yb)
            else:
                runs.append([ya, yb])
        mine = [r_ for r_ in runs if r_[0] - 2 <= w.cy <= r_[1] + 2]
        if not mine or mine[0][1] - mine[0][0] < 30:
            continue
        a, b = (x0, mine[0][0]), (x0, mine[0][1])
        line = LineString([a, b])
        if line.intersection(fp.buffer(2.0)).length < 0.8 * line.length:
            continue
        mem.append({'pid': -1, 'a': a, 'b': b, 'line': line, 'thick_chain': False, 'o': 'V', 'kind': 'deep', 'section': ('T', deep),
                    'evidence': [f"R-DG3: label '{t}' -> thin solid line beside it (no chain line) -> header {v.notes.get('deep')}"]})
    # R-DG2 (owner 2026-10-23): plan note 'GIR. & TRANSV. : WxT+wxt F.B(T)' -> every dark chain line (heavy dash-dot) is a girder / transverse of that T section
    if v.notes.get('deep_gt'):
        for m in mem:
            if m['thick_chain'] and m['kind'] is None:
                m['kind'] = 'deep'
                m['evidence'].append("R-DG2: dark chain line = girder/transverse per note 'GIR. & TRANSV.' " + v.notes.get('deep', ''))
    # R-FW: 'FR.n' + 'WEB' printed at the frame head -> transverse WEB on frame n
    ft = settings.get('frame_x') or (lambda n: n * v.frame_space)
    frs = [w for w in page.words if re.fullmatch(r'FR\.\s*\d+', w.text.strip()) and w.vertical
           and v.region[0] < w.cx < v.region[2] and v.region[1] < w.cy < v.region[3]]
    for f in frs:
        if not any(u.text.strip() == 'WEB' and u.vertical and abs(u.cx - f.cx) < 12 and abs(u.cy - f.cy) < 40
                   for u in page.words):
            continue
        n = int(re.search(r'\d+', f.text).group())
        xp = v.px(ft(n))
        for m in mem:
            if m['o'] == 'V' and abs(m['a'][0] - xp) < 2.0 and m['kind'] in (None,):
                m['kind'] = 'girder'
                m['section'] = hdr.get('girder')
                m['evidence'].append(f"frame head label 'FR.{n} WEB' -> header GIR. & WEB")
    # explicit section callouts with leaders
    from .deckplan import leader_tip
    segs = [s for s in page.segs if not s.dash]
    for w in words:
        sec = parse_section(w.text, aliases)
        if not sec:
            continue
        best = None
        # printed beside its member (text runs along it) ...
        for m in mem:
            if m['o'] != 'D' and (m['o'] == 'H') == w.vertical:
                continue
            d = _label_dist(w, m)
            if d is not None and d <= LABEL_GAP + 2 and (best is None or d < best[0]):
                best = (d, m, 'alongside')
        # ... or pointing at it with a leader
        if best is None:
            tip = leader_tip(w, segs)
            if tip is not None:
                for m in mem:
                    d = m['line'].distance(Point(tip))
                    if d < 3 and (best is None or d < best[0]):
                        best = (d, m, 'leader')
        if best:
            m = best[1]
            m['kind'] = 'callout'
            m['section'] = sec
            m['evidence'].append(f"callout '{w.text}' ({best[2]})")
    # thick chain lines that no DEEP label claimed are centre/datum lines, not members
    mem = [m for m in mem if not m['thick_chain'] or m['kind'] == 'deep']
    # R-SY symmetry
    for m in mem:
        if m['kind']:
            continue
        mx = (v.px(v.X(m['a'][0])), v.py(-v.Y(m['a'][1]))), (v.px(v.X(m['b'][0])), v.py(-v.Y(m['b'][1])))
        ml = LineString(mx)
        for n in mem:
            if n is m or not n['kind']:
                continue
            if n['line'].hausdorff_distance(ml) < 1.5:
                m['kind'], m['section'] = n['kind'], n['section']
                m['evidence'].append('note 1 symmetry: mirror of labelled member')
                break
    # defaults
    for m in mem:
        if m['kind']:
            continue
        # header 'DECK BEAM : ... (EXC. AS SHOWN)' covers every unmarked deck stiffener
        m['kind'] = 'beam'
        m['section'] = hdr.get('beam')
        m['evidence'].append(f"unmarked -> header DECK BEAM {v.notes.get('beam')} (EXC. AS SHOWN)")
        if m['o'] != 'V':
            m['evidence'].append('longitudinal/oblique unmarked member: confirm default applies')
    # R-B1: owner answer Q3 - a printed 'B' at a stiffener end = bracket connection (note 4 of the drawing)
    bmarks = [w for w in page.words if w.text.strip() == 'B' and w.size < 12 and not w.vertical
              and fp.buffer(20).contains(Point(w.cx, w.cy))]
    out = []
    # R-B3: a printed bracket callout 'WxT' (e.g. 200X8.0, 150X8.0, 300X10.0) near the B mark gives the leg W and the thickness T
    from .elevation import callout_near, callout_tips

    def _size(w):
        return callout_near(page, w, BRK_CALLOUT_DIST)
    from .elevation import frame_sizes
    fsz = frame_sizes(page)
    out = []
    for m in mem:
        ba = bb = False
        unk_a = unk_b = False
        sa = sb = None
        for w in bmarks:
            da, db = Point(w.cx, w.cy).distance(Point(m['a'])), Point(w.cx, w.cy).distance(Point(m['b']))
            dl = m['line'].distance(Point(w.cx, w.cy))
            if dl < BMARK_DIST and min(da, db) < BMARK_DIST + 4:
                if da <= db:
                    ba = True
                    sa = sa or _size(w)
                else:
                    bb = True
                    sb = sb or _size(w)
        if CALLOUT_BRACKETS:          # R-B4: a callout leader whose tip lands on a member end = bracket there (size from the callout)
            for c, tip, W, T in callout_tips(page):
                da, db = Point(tip).distance(Point(m['a'])), Point(tip).distance(Point(m['b']))
                if min(da, db) < CALLOUT_TIP_DIST and m['line'].distance(Point(tip)) < CALLOUT_TIP_DIST:
                    if da <= db:
                        ba, sa = True, sa or (W, T)
                    else:
                        bb, sb = True, sb or (W, T)
        # R-B6: no size at the bracket itself -> the size drawn at that frame in the elevations / typical sections
        for side in ('a', 'b'):
            if (ba if side == 'a' else bb) and not (sa if side == 'a' else sb):
                pt = m[side]
                Xe = v.X(pt[0])
                cand = [(abs(ft(n) - Xe), n) for n in fsz]
                if cand:
                    dmin, n = min(cand)
                    if dmin < 150:
                        sz_ = fsz[n].most_common(1)[0][0]
                        if side == 'a': sa = sz_
                        else: sb = sz_
                        m['evidence'].append('R-B6: bracket size %s from the callout at FR.%d' % (sz_, n))
                        continue
                # R-DT: the detail section of this deck that spans the same OFF C.L pair gives the bracket size at each end
                try:
                    from . import details
                    ya_, yb_ = abs(v.Y(m['a'][1])), abs(v.Y(m['b'][1]))
                    y_me = abs(v.Y(m[side][1]))
                    for (ya, yb, sza, szb, ttl) in details.bracket_spans(page, v.name):
                        lo, hi = sorted((ya_, yb_))
                        if abs(lo - ya) < 60 and abs(hi - yb) < 60:
                            near_lo = abs(y_me - lo) <= abs(y_me - hi)
                            sz_ = sza if near_lo else szb
                            if sz_:
                                if side == 'a': sa = sz_
                                else: sb = sz_
                                details.USED.add(ttl)
                                m['evidence'].append('R-DT: bracket size %s from %s (%d..%d OFF C.L)' % (sz_, ttl, ya, yb))
                                raise StopIteration
                    if m['o'] == 'H':          # beam along X: ELEV views with frame +/- offset marks
                        xa_, xb_ = v.X(m['a'][0]), v.X(m['b'][0])
                        xm_ = v.X(m[side][0])
                        lo_, hi_ = sorted((xa_, xb_))
                        for (xa, xb, sza, szb, ttl) in details.bracket_spans_x(page, v.name, ft):
                            xa, xb = sorted((xa, xb))
                            if abs(lo_ - xa) < 90 and abs(hi_ - xb) < 90:
                                sz_ = sza if abs(xm_ - lo_) <= abs(xm_ - hi_) else szb
                                if sz_:
                                    if side == 'a': sa = sz_
                                    else: sb = sz_
                                    details.USED.add(ttl)
                                    m['evidence'].append('R-DT: bracket size %s from %s (X %d..%d)' % (sz_, ttl, xa, xb))
                                    raise StopIteration
                    ty = details.typical_size(page, v.name)
                    if ty:
                        if side == 'a': sa = ty
                        else: sb = ty
                        m['evidence'].append('R-DT: bracket size %s = typical of the sections printed for this deck (no section for this span)' % (ty,))
                        raise StopIteration
                except StopIteration:
                    continue
                m['evidence'].append('R-B6: bracket size UNKNOWN (no callout / table mark found) - default used')
                if side == 'a': unk_a = True
                else: unk_b = True
        # R-B5: members carrying a carling mark listed in settings 'no_bracket_marks' (default '#1') are plain stiffeners: the B symbols at their ends are not built
        if m.get('mark') in set(settings.get('no_bracket_marks', ['#1'])):
            if ba or bb:
                m['evidence'].append('R-B5: mark %s = no bracket' % m['mark'])
            ba = bb = False
            sa = sb = None
        # R-DX1 (owner 2026-10-23): a girder / transverse measured at X must agree with the printed frame offset ('FR.48 - 345') -> cross-check, report
        if m['kind'] in ('deep', 'girder') and m['o'] == 'V':
            Xm = v.X(m['a'][0])
            try:
                n_ = min(range(-20, 400), key=lambda k: abs(ft(k) - Xm))
                d_ = Xm - ft(n_)
                mid = ((m['a'][0] + m['b'][0]) / 2, (m['a'][1] + m['b'][1]) / 2)
                lo, hi = sorted((m['a'][1], m['b'][1]))
                nums = [int(w.text) for w in page.words if re.fullmatch(r'\d{2,4}', w.text.strip()) and lo - 30 < w.cy < hi + 30
                        and abs(w.cx - mid[0]) < 70]
                hit = [q for q in nums if abs(abs(d_) - q) <= 25]
                if abs(d_) > 12:
                    m['evidence'].append('R-DX1: measured FR.%d %+d mm%s' % (n_, round(d_), (' - printed %d confirms' % hit[0]) if hit else ' - NO printed dimension agrees (nearby %s)' % sorted(set(nums))[:8]))
                if hit and abs(abs(d_) - hit[0]) > 0.5:          # printed dimension wins over the measured position
                    Xs = ft(n_) + (1 if d_ > 0 else -1) * hit[0]
                    m['snap_x'] = Xs
                    m['evidence'].append('R-DX1: X snapped %.0f -> %.0f (FR.%d %+d)' % (Xm, Xs, n_, (1 if d_ > 0 else -1) * hit[0]))
                m['dim_check'] = {'frame': n_, 'offset': round(d_), 'confirmed': bool(hit) or abs(d_) <= 12}
            except Exception as _e:
                from . import openitems as _oi
                _oi.record('members R-DX1 dimension check', _e)
        _xa, _xb = v.X(m['a'][0]), v.X(m['b'][0])
        if m.get('snap_x') is not None:
            _xa = _xb = m['snap_x']
        out.append({'a': (_xa, v.Y(m['a'][1])), 'b': (_xb, v.Y(m['b'][1])),
                    'kind': m['kind'], 'section': m['section'], 'pid': m['pid'],
                    'evidence': m['evidence'], 'bracket_a': ba, 'bracket_b': bb,
                    'bracket_size_a': sa, 'bracket_size_b': sb,
                    'bracket_unknown_a': unk_a and ba, 'bracket_unknown_b': unk_b and bb, 'dim_check': m.get('dim_check')})
    return out, carl


MARK_TOKEN = re.compile(r'^\s*([$#%&@]\d{1,2}|S\d{1,2})\s*(?:"?\s*AH\s*"?)?\s*$')
_MARK_TAB = {}


def mark_table(pdf):
    """R-ST1 [DRAWING] (PPT 'stiffener table #1-#5'; ERM '$1 125 X 75 X 10 U.A' ... '$9 350 X 100 X 12 / 17 I.A'): a column of >= 3 mark
    tokens ('$n', '#n', 'Sn', ...), each followed on its own line (within 400 pt) by a section size, is the drawing's stiffener mark table:
    mark -> section. One table per drawing (the first page that prints it). {} when the drawing has none."""
    if not pdf:
        return {}
    if pdf in _MARK_TAB:
        return _MARK_TAB[pdf]
    tab = {}
    try:
        from . import pdfsrc
        import pymupdf
        for p in range(len(pymupdf.open(pdf))):
            pg = pdfsrc.load_page(pdf, p)
            toks = [w for w in pg.words if not w.vertical and re.fullmatch(r'\s*([$#%&@]\d{1,2}|S\d{1,2})\s*', w.text)]
            cols = {}
            for w in toks:
                cols.setdefault(round(w.cx / 6), []).append(w)
            for ws in cols.values():
                rows = {}
                for w in ws:
                    cand = [u for u in pg.words if u is not w and abs(u.cy - w.cy) < 3 and 0 < u.cx - w.cx < 400 and not u.vertical]
                    for u in sorted(cand, key=lambda u: u.cx):
                        sec = parse_section(u.text.replace(' X ', 'X').replace(' / ', '/'))
                        if sec:
                            rows[w.text.strip()] = (sec, u.text.strip(), p + 1)
                            break
                if len(rows) >= 3:
                    for k, v in rows.items():
                        tab.setdefault(k, v)
            if tab:
                break
    except Exception as e:
        from . import openitems
        openitems.record('R-ST1 mark table', e)
    _MARK_TAB[pdf] = tab
    return tab
