"""R-XV (owner 2026-10-25): every member hangs on a deck, so the deck plan, the OFF C.L elevations and the frame sections are
ONE structure seen three ways. While the deck members are made they are cross-verified at the same time:

  R-XV1  one frame -> X function for every view (the spacing written on the sheets), so the three views share coordinates.
  R-XV2  an OFF C.L elevation at Y cuts every transverse deck member crossing Y: the cut is drawn as a short stub hanging from the
         deck line at its X.  A frame section at X cuts every longitudinal deck member crossing X: a stub under the deck at its Y.
  R-XV3  deck member crossing a view + stub there        -> confirmed (Evidence 'R-XV confirmed by <view>').
         deck member crossing a view, no stub there      -> reported (question to the owner), never silently kept as 'checked'.
         stub in a view, no deck member at that place    -> reported as a missing member (or filled by R-SY2 when its mirror exists).
  R-XV0  two identical members (same kind, same ends within 5 mm) are one member.
  R-SY2  sheet note 'BOTH SIDES ARE SYMMETRIC / SIM. TO PORT SIDE EXCEPT AS SHOWN': a member drawn on one side whose mirror place is
         empty is mirrored, but only when no view of that side contradicts it ('except as shown'): every elevation / section of the
         mirror side that crosses it must show its stub. Mirrored members not crossed by any view are kept and reported as unverified.
Nothing here needs the network; all from the drawing text and vectors."""
import re, math, statistics

SYM_NOTE = re.compile(r'(BOTH\s+SIDES\s+(ARE\s+)?SYMM|SYMMETRIC(AL)?\s+EXCEPT|SIM(\.|ILAR)?\s+TO\s+(PORT|STBD|STARBOARD|P|S)\b.*EXCEPT|'
                      r'P(ORT)?\s*(&|AND)\s*S(TBD)?\.?\s+(ARE\s+)?SIM)', re.I)
STUB_MIN, STUB_MAX = 2.0, 14.0          # pt: a cut member hangs 2..14 pt (70..500 mm at 1/100) below the deck line
TOL = 150.0                             # mm: stub <-> member crossing
END_MEMBER = 250.0                      # mm: a member ending this close to the view plane is not cut by it
EDGE_SKIP = 300.0                       # mm: stubs this close to the deck edge are wall stiffeners / brackets
END_SKIP = 400.0                        # mm: stubs this close to a view end are end-wall brackets, not deck members
_CACHE = {}
ELEV_LONGS = []                         # R-XV8: girders / longitudinals seen side-on under the decks in the OFF C.L elevations
ELEV_BKTS = []                          # R-B9: bracket labels 'LxT' at the deck / wall corners of the OFF C.L elevations
SEC_SIDEON = []                         # R-XV8c: transverse members seen side-on under the decks in the frame sections ('300 I.A')
SEC_WEBS = []                           # R-XV7: transverse T-webs under the decks read in the frame sections
ELEV_WALLS = []                         # (Y, Zlo, Zhi, Xlo, Xhi) of the OFF C.L wall panels built (R-S17)
DECKS = {}                              # deck z -> {'name', 'footprint', 'walls'} filled while the decks are made (R-XV4)


def typ_end_connections(pdf):
    """R-B9 step 3: 'TYP. END CONNECTION' views: {section text: [bracket marks]} e.g. {'300X90X11/16 I.A': ['B25']} - the marks
    written inside the view (below the title, within 120 pt). Offline, PDF text only."""
    key = ('tec', pdf)
    if key not in _CACHE:
        from . import pdfsrc
        import pymupdf
        out = {}
        for pn in range(len(pymupdf.open(pdf))):
            page = pdfsrc.load_page(pdf, pn)
            for t in page.words:
                if 'END CONNECTION' not in t.text.upper() or 'TYP' not in t.text.upper():
                    continue
                sub = next((w for w in page.words if w.text.strip().startswith('(') and abs(w.bbox[0] - t.bbox[0]) < 10 and 0 < w.cy - t.cy < 30), None)
                if not sub:
                    continue
                ms = re.search(r'\d+\s*X\s*\d+(?:\s*X\s*\d+(?:/\d+)?)?\s*(?:I\.A|U\.A|F\.B\(T\)|F\.B)', sub.text.upper())
                if not ms:
                    continue
                sec = ms.group(0)
                marks = sorted({w.text.strip() for w in page.words if re.fullmatch(r'B\d{1,3}', w.text.strip())
                                and abs(w.cx - t.cx) < 250 and -40 < w.cy - t.cy < 160})
                if marks:
                    out[sub.text.strip('() ')] = {'section_text': sec, 'marks': marks, 'page': pn + 1}
        _CACHE[key] = out
    return _CACHE[key]


def symmetric_note(pdf):
    key = ('sym', pdf)
    if key not in _CACHE:
        from . import pdfsrc
        import pymupdf
        hit = None
        for i in range(len(pymupdf.open(pdf))):
            for w in pdfsrc.load_page(pdf, i).words:
                if SYM_NOTE.search(w.text):
                    hit = f'p{i + 1}: {w.text.strip()}'
                    break
            if hit:
                break
        _CACHE[key] = hit
    return _CACHE[key]


_IDX = {}


def _index(page):
    """P5 (review 2026-10-26): one index per page instead of a full scan of all lines for every deck / view (and a full scan inside
    that scan in _lsyms). vstub = short solid vertical strokes; hshort = short horizontal strokes bucketed by page y."""
    k = id(page)
    if k not in _IDX or _IDX[k][0] is not page:
        vs = [s for s in page.segs if s.vertical and STUB_MIN < s.length < STUB_MAX and not s.dash]
        hs = {}
        for h in page.segs:
            if h.horizontal and 0.8 < h.length < 6:
                hs.setdefault(int(h.a[1]), []).append(h)
        _IDX[k] = (page, vs, hs)
    return _IDX[k][1], _IDX[k][2]


def _stubs(page, xs_range, deck_y, axis_fn):
    out = []
    for s in _index(page)[0]:
        if not (xs_range[0] < s.a[0] < xs_range[1]):
            continue
        top = min(s.a[1], s.b[1])
        if abs(top - deck_y) < 1.5:
            out.append(axis_fn(s.a[0]))
    out.sort()
    merged = []
    for x in out:                       # the two web lines of one cut are one stub
        if merged and x - merged[-1][-1] < 60:
            merged[-1].append(x)
        else:
            merged.append([x])
    return [statistics.mean(g) for g in merged]


def _lsyms(page, xs_range, deck_y, axis_fn, wsign):
    """R-FL2 (owner 2026-10-25: "the L symbol is always drawn - if not in that view, in the other view relevant to it"): where a deck
    member is cut by a section / elevation it is drawn as an L: the web hangs from the deck line and the flange is a short stroke
    (0.8..6 pt) at the web's lower end, to one side.  -> [(u, side)] u along the view axis, side = +1 / -1 in ship axis (wsign maps the
    page +x direction to the ship axis of the view)."""
    out = []
    vs, hs = _index(page)
    for s in vs:
        if not (xs_range[0] < s.a[0] < xs_range[1]):
            continue
        if abs(min(s.a[1], s.b[1]) - deck_y) >= 1.5:
            continue
        x, yb = s.a[0], max(s.a[1], s.b[1])
        cand = [h for b in (int(yb) - 1, int(yb), int(yb) + 1) for h in hs.get(b, ())]
        fl = [h for h in cand if abs(h.a[1] - yb) < 0.8
              and (abs(min(h.a[0], h.b[0]) - x) < 0.6 or abs(max(h.a[0], h.b[0]) - x) < 0.6)]
        if not fl:
            continue
        sg = 1 if max(fl[0].a[0], fl[0].b[0]) > x + 0.5 else -1
        out.append((axis_fn(x), sg * wsign))
    return out


def collect(pdf, settings):
    """cut lines of every OFF C.L elevation and frame section: {'view', 'type': 'elev'|'sec', 'pos' (Y or X), 'z', 'stubs', 'range'}"""
    key = ('cuts', pdf)
    if key in _CACHE:
        return _CACHE[key]
    from . import pdfsrc, elevation, section, view as dview
    from .run import frame_x_fn
    from .run_elev import deck_heights, _frame_fns, _pdf_spacings
    import pymupdf
    n = len(pymupdf.open(pdf))
    deck_z = deck_heights(pdf, n)
    sp_all = _pdf_spacings(pdf, n)

    class _V:
        frame_space = settings.get('frame_spacing_mm') or (sorted(sp_all)[0] if sp_all else 800)
    fx = frame_x_fn(settings, _V)
    cuts = []
    for pn in range(n):
        page = pdfsrc.load_page(pdf, pn)
        scale = dview.sheet_scale(page) or 100
        for v in elevation.find_views(page):
            try:
                ok = False
                for cand in _frame_fns(page, settings, fx, sp_all):
                    try:
                        elevation.calibrate(page, v, cand, scale, deck_z)
                        ok = True
                        break
                    except ValueError:
                        v.decks, v.evidence = {}, {}
                if not ok:
                    continue
            except Exception:
                continue
            xr = (v.X(v.xr[0]), v.X(v.xr[1]))
            for code, py in v.decks.items():
                if code not in deck_z:
                    continue
                st = _stubs(page, v.xr, py, v.X)
                cuts.append({'view': f'p{pn + 1} {v.name}', 'type': 'elev', 'pos': float(v.y), 'z': deck_z[code], 'deck': code,
                             'stubs': st, 'range': (min(xr), max(xr)), 'lsym': _lsyms(page, v.xr, py, v.X, 1 if v.k > 0 else -1)})
                ELEV_LONGS.extend(_elev_longs(page, v, code, py, deck_z[code], pn))
                ELEV_BKTS.extend(_elev_brackets(page, v, code, py, deck_z[code], pn))
        try:
            wys = []
            for v in section.find_views(page, fx):
                try:
                    section.calibrate(page, v, scale, deck_z)
                    section.extract(page, v, deck_z, settings, wys)
                except Exception:
                    continue
                if v.xcl is None:
                    continue
                yf = lambda px, v=v: section.Y(v, px)
                rx = v.region if v.region else None
                for code, py in v.decks.items():
                    if code not in deck_z:
                        continue
                    xr_pt = (rx[0], rx[2]) if rx else (-1e9, 1e9)
                    st = _stubs(page, xr_pt, py, yf)
                    yr = sorted((yf(xr_pt[0]), yf(xr_pt[1]))) if rx else (-1e9, 1e9)
                    cuts.append({'view': f'p{pn + 1} {v.name}', 'type': 'sec', 'pos': float(v.X), 'z': deck_z[code], 'deck': code,
                                 'stubs': st, 'range': tuple(yr), 'lsym': _lsyms(page, xr_pt, py, yf, 1 if v.s > 0 else -1)})
                    SEC_WEBS.extend(_sec_webs(page, v, code, py, deck_z[code], rx, yf, pn))
                    SEC_SIDEON.extend(_sec_sideon(page, v, code, py, deck_z[code], rx, yf, pn))
        except Exception as _e:
            from . import openitems as _oi
            _oi.record('crossverify.collect (sections)', _e)
    _CACHE[key] = cuts
    return cuts


def _elev_longs(page, v, code, py, z, pn):
    """R-XV8: an OFF C.L elevation at Y shows the deck longitudinal lying in its plane side-on: a horizontal line at deck - depth
    with a horizontal size label ('300 I.A', '450X10+150X12 F.B(T)') just under the deck line. -> {'Y', 'z', 'x0', 'x1', 'h', 'kind', 'text'}"""
    from . import members
    out = []
    for w in page.words:
        if w.vertical or not (v.xr[0] < w.cx < v.xr[1]):
            continue
        m = members.SEC.search(w.text) or TWEB.search(w.text)
        if not m:
            continue
        h = float(m.group(1)) if m.re is TWEB else float(m.group('h'))
        yb = py + h / v.k
        if not (py - 1 < w.cy < yb + 12):
            continue
        segs = [q for q in page.segs if q.horizontal and abs(q.a[1] - yb) < 2.5 and v.xr[0] - 10 < min(q.a[0], q.b[0]) and max(q.a[0], q.b[0]) < v.xr[1] + 10]
        iv = sorted((min(q.a[0], q.b[0]), max(q.a[0], q.b[0])) for q in segs)
        run, hit = None, None
        for a, b in iv:
            if run and a <= run[1] + 4:
                run[1] = max(run[1], b)
            else:
                if run and run[0] - 4 <= w.cx <= run[1] + 4:
                    hit = run
                    break
                run = [a, b]
        if hit is None and run and run[0] - 4 <= w.cx <= run[1] + 4:
            hit = run
        if not hit or hit[1] - hit[0] < 15:
            continue
        out.append({'Y': float(v.y), 'z': z, 'deck': code, 'x0': round(v.X(hit[0])), 'x1': round(v.X(hit[1])), 'h': h,
                    'kind': 'TB' if m.re is TWEB else m.group('k'), 'text': w.text.strip(), 'view': f'p{pn + 1} {v.name}'})
    return out


BKT_LBL = re.compile(r'^\s*(\d{2,4})\s*X\s*(\d{1,2}(?:\.\d)?)\s*$')


def _elev_brackets(page, v, code, py, z, pn):
    """R-B9 (owner 2026-10-25: a bracket is given in the detail view of the OFF C.L / longi / frame it belongs to): in an OFF C.L
    elevation a size 'LxT' (e.g. '200X8.0') written just under a deck line near one end of the view = the bracket at that deck / wall
    corner of the longitudinal lying in this elevation plane. -> {'Y', 'z', 'X' (the end), 'leg', 't', 'text', 'view'}"""
    out = []
    x0, x1 = sorted(v.xr)
    xs = [x for q in page.segs if q.horizontal and abs(q.a[1] - py) < 1.5 and x0 - 5 < min(q.a[0], q.b[0]) and max(q.a[0], q.b[0]) < x1 + 5
          for x in (q.a[0], q.b[0])]
    if not xs:
        return out
    lo, hi = min(xs), max(xs)                       # the deck line's own ends = the walls at this deck
    for w in page.words:
        m = BKT_LBL.match(w.text)
        if not m or w.vertical or not (py - 1 < w.cy < py + 30) or not (lo - 10 < w.cx < hi + 10):
            continue
        end = lo if abs(w.cx - lo) < abs(w.cx - hi) else hi
        if abs(w.cx - end) > 60:
            continue
        out.append({'Y': float(v.y), 'z': z, 'deck': code, 'X': round(v.X(end)), 'leg': float(m.group(1)), 't': float(m.group(2)),
                    'text': w.text.strip(), 'view': f'p{pn + 1} {v.name}'})
    return out


TWEB = re.compile(r'(\d{3})\s*X\s*(\d{1,2})\s*\+\s*(\d{2,3})\s*X\s*(\d{1,2})\s*F\.?B\.?\s*\(T\)')


def _sec_webs(page, v, code, py, z, rx, yf, pn):
    """R-XV7: in a frame section, a horizontal 'WxT+wxt F.B(T)' label just under a deck line with a horizontal line at
    deck + web depth under it = a transverse deep web of that deck at the section's X, over the Y range of that line."""
    out = []
    if not rx:
        return out
    for w in page.words:
        m = TWEB.search(w.text)
        if not m or w.vertical or not (rx[0] < w.cx < rx[2]):
            continue
        h, t, fw, ft = (float(g) for g in m.groups())
        yb = py + h / v.k                              # page y of the web's lower edge (face plate)
        if not (py - 2 < w.cy < yb + 14):
            continue
        segs = [q for q in page.segs if q.horizontal and abs(q.a[1] - yb) < 2.5 and rx[0] - 10 < min(q.a[0], q.b[0]) and max(q.a[0], q.b[0]) < rx[2] + 10]
        iv = sorted((min(q.a[0], q.b[0]), max(q.a[0], q.b[0])) for q in segs)
        run = None
        for a, b in iv:                                 # the run of collinear pieces that passes the label
            if run and a <= run[1] + 4:
                run[1] = max(run[1], b)
            elif run and run[0] - 4 <= w.cx <= run[1] + 4:
                break
            else:
                run = [a, b]
        if not run or not (run[0] - 4 <= w.cx <= run[1] + 4) or run[1] - run[0] < 20:
            continue
        y0, y1 = sorted((yf(run[0]), yf(run[1])))
        out.append({'X': float(v.X), 'z': z, 'deck': code, 'y0': round(y0), 'y1': round(y1), 'sec': (h, t, fw, ft),
                    'label': w.text.strip(), 'view': f'p{pn + 1} {v.name}'})
    return out


def _sec_sideon(page, v, code, py, z, rx, yf, pn):
    """R-XV8c (owner 2026-10-25: 'always follow the detailed section'): in a frame section a size label of an angle / bar
    ('300 I.A', '150X90X9 U.A') written just under a deck line with a horizontal line at deck - height under it = the transverse
    member of that deck at the section's X, seen side-on, over the Y range of that line run."""
    from . import members
    out = []
    if not rx:
        return out
    for w in page.words:
        m = members.SEC.search(w.text)
        if not m or w.vertical or not (rx[0] < w.cx < rx[2]) or TWEB.search(w.text):
            continue
        h = float(m.group('h'))
        yb = py + h / v.k
        if not (py - 1 < w.cy < yb + 12):
            continue
        segs = [q for q in page.segs if q.horizontal and abs(q.a[1] - yb) < 2.5 and rx[0] - 10 < min(q.a[0], q.b[0]) and max(q.a[0], q.b[0]) < rx[2] + 10]
        iv = sorted((min(q.a[0], q.b[0]), max(q.a[0], q.b[0])) for q in segs)
        run = None
        for a, b in iv:
            if run and a <= run[1] + 4:
                run[1] = max(run[1], b)
            elif run and run[0] - 4 <= w.cx <= run[1] + 4:
                break
            else:
                run = [a, b]
        if not run or not (run[0] - 4 <= w.cx <= run[1] + 4) or run[1] - run[0] < 15:
            continue
        y0, y1 = sorted((yf(run[0]), yf(run[1])))
        out.append({'X': float(v.X), 'z': z, 'deck': code, 'y0': round(y0), 'y1': round(y1), 'h': h, 'text': w.text.strip(),
                    'view': f'p{pn + 1} {v.name}'})
    return out


def _crossing(m, c, strict=True):
    """coordinate along the cut line where member m crosses cut c, or None"""
    (x1, y1), (x2, y2) = m['a'], m['b']
    if c['type'] == 'elev':            # plane Y = pos; member must run across it (transverse-ish)
        Y = c['pos']
        if abs(y2 - y1) < 1e-6 or not (min(y1, y2) - (1 if strict else TOL) <= Y <= max(y1, y2) + (1 if strict else TOL)):
            return None
        if abs(x2 - x1) > abs(y2 - y1):
            return None                 # a longitudinal lying in / along the plane is not a cut
        t = min(1.0, max(0.0, (Y - y1) / (y2 - y1)))
        if strict and min(abs(Y - y1), abs(Y - y2)) < END_MEMBER:
            return None                 # the member ends at the plane (on the wall there): not a cut
        return x1 + t * (x2 - x1)
    X = c['pos']
    if abs(x2 - x1) < 1e-6 or not (min(x1, x2) - (1 if strict else TOL) <= X <= max(x1, x2) + (1 if strict else TOL)):
        return None
    if abs(y2 - y1) > abs(x2 - x1):
        return None
    t = min(1.0, max(0.0, (X - x1) / (x2 - x1)))
    if strict and min(abs(X - x1), abs(X - x2)) < END_MEMBER:
        return None
    return y1 + t * (y2 - y1)


def _cover(a, b, lines, lat=40.0):
    """share of the stretch a-b covered by drawn lines collinear with it (within lat mm)"""
    L = math.dist(a, b)
    if L < 1:
        return 0.0
    ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
    iv = []
    for x0, y0, x1, y1 in lines:
        if abs((x0 - a[0]) * uy - (y0 - a[1]) * ux) > lat or abs((x1 - a[0]) * uy - (y1 - a[1]) * ux) > lat:
            continue
        t0 = (x0 - a[0]) * ux + (y0 - a[1]) * uy
        t1 = (x1 - a[0]) * ux + (y1 - a[1]) * uy
        lo, hi = max(min(t0, t1), 0.0), min(max(t0, t1), L)
        if hi > lo:
            iv.append((lo, hi))
    iv.sort()
    tot, cur = 0.0, None
    for lo, hi in iv:
        if cur and lo <= cur[1]:
            cur[1] = max(cur[1], hi)
        else:
            if cur:
                tot += cur[1] - cur[0]
            cur = [lo, hi]
    if cur:
        tot += cur[1] - cur[0]
    return tot / L


def _offset(pairs):
    """systematic offset stub - moulded line (stubs are drawn at the web side): median of the near pairs"""
    d = [s - u for u, s in pairs if abs(s - u) < TOL]
    return statistics.median(d) if d else 0.0


def verify(deck, cuts, pdf, settings, footprint=None, openings=(), drawn=None, notes=None, sheet=None):
    """runs while the deck members are made (before clipping / splitting). Changes deck['members'] in place, returns the log."""
    mem = deck['members']
    z = float(deck['z'])
    mycuts = [c for c in cuts if abs(c['z'] - z) < 5]
    log = {'views': sorted({c['view'] for c in mycuts}), 'duplicates_removed': 0, 'confirmed': 0, 'not_shown': [], 'missing': [],
           'mirrored': 0, 'mirror_rejected': [], 'mirror_unverified': 0, 'symmetric_note': symmetric_note(pdf)}
    # R-XV0 duplicates
    keep, seen = [], []
    for m in mem:
        a, b = m['a'], m['b']
        dup = next((k for k in seen if k['kind'] == m['kind'] and
                    ((math.dist(k['a'], a) < 5 and math.dist(k['b'], b) < 5) or (math.dist(k['a'], b) < 5 and math.dist(k['b'], a) < 5))), None)
        if dup is not None:
            log['duplicates_removed'] += 1
            continue
        seen.append(m)
        keep.append(m)
    mem[:] = keep
    # R-XV0b (2026-10-25): one drawn line is ONE member. Two parallel members on the same line (offset < 20 mm) that overlap: the better
    # read one keeps the overlap - marked (label / table mark) > unmarked drawn > generated (R-NL) - and the other is trimmed to the part
    # outside it (pieces < 100 mm dropped). EC weather shield: '#1' carling at 3320 also read as an unmarked beam; NO.8L / NO.7L generated
    # beams ran over the '#' carlings drawn from the FR.19+1/2 wall.
    def _rank(m):
        ev = ' '.join(str(e) for e in (m.get('evidence') or []))
        return 0 if ev.startswith('R-NL') else 1 if ('unmarked' in ev or 'default' in ev) else 2
    log.setdefault('overlaps_trimmed', 0)
    out = []
    for m in sorted(mem, key=_rank, reverse=True):
        a, b = m['a'], m['b']
        L = math.dist(a, b)
        if L < 1:
            out.append(m); continue
        ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
        free = [(0.0, L)]
        for k in out:
            if _rank(k) <= _rank(m) or k['kind'] not in ('beam', 'carling', 'girder', 'longitudinal'):
                continue
            ka, kb = k['a'], k['b']
            kL = math.dist(ka, kb)
            if kL < 1 or abs(((kb[0] - ka[0]) * uy - (kb[1] - ka[1]) * ux) / kL) > 0.02:
                continue
            if abs((ka[0] - a[0]) * uy - (ka[1] - a[1]) * ux) > 20:
                continue
            t0, t1 = sorted(((ka[0] - a[0]) * ux + (ka[1] - a[1]) * uy, (kb[0] - a[0]) * ux + (kb[1] - a[1]) * uy))
            nf = []
            for f0, f1 in free:
                if t1 <= f0 or t0 >= f1:
                    nf.append((f0, f1)); continue
                if t0 > f0: nf.append((f0, t0))
                if t1 < f1: nf.append((t1, f1))
            free = nf
        free = [f for f in free if f[1] - f[0] >= 100]
        if free == [(0.0, L)]:
            out.append(m); continue
        log['overlaps_trimmed'] += 1
        log.setdefault('overlaps_detail', []).append([m['kind'], [round(c) for c in a + b], [[round(f0), round(f1)] for f0, f1 in free]])
        for f0, f1 in free:
            q = dict(m)
            q['a'] = (a[0] + ux * f0, a[1] + uy * f0)
            q['b'] = (a[0] + ux * f1, a[1] + uy * f1)
            q['evidence'] = list(m.get('evidence') or []) + ['R-XV0b: trimmed where a better-read member lies on the same line']
            out.append(q)
    mem[:] = out
    kinds = ('beam', 'carling', 'girder')

    def _sec_votes(m):
        """frame sections of this deck that cross the (longitudinal) member: (confirming views, contradicting views) by the cut stubs"""
        if abs(m['a'][1] - m['b'][1]) > 1:
            return [], []
        Y = m['a'][1]
        lo, hi = sorted((m['a'][0], m['b'][0]))
        ok, bad = [], []
        for c in mycuts:
            if c['type'] != 'sec' or not (lo + END_MEMBER < c['pos'] < hi - END_MEMBER):
                continue
            if not (c['range'][0] + EDGE_SKIP < Y < c['range'][1] - EDGE_SKIP):
                continue
            (ok if any(abs(st - Y) < 60.0 for st in c['stubs']) else bad).append(c['view'])     # the stub of THIS line (1.7 pt), not a neighbour's
        return ok, bad
    # R-NL4 (owner 2026-10-25: 'there is no member there - under which rule?'): a generated NO.nL longitudinal is built only where the
    # frame sections that cross it show it cut. Crossed by sections and cut in none -> not a member (the NO.nL label is a reference
    # line). EC weather shield: the sections FR.21 / 22 / 22+800 / 24 cut only the GIR. at 1760 / 4320, the C.L, the walls and the
    # hole carlings - NO.1L / 3L / 4L / 6L / 7L / 8L are not members on that deck.
    log['nl_not_cut_in_sections'] = []
    keep = []
    for m in mem:
        if str((m.get('evidence') or [''])[0]).startswith('R-NL'):
            ok, bad = _sec_votes(m)
            if not ok:              # R-NL4: a generated member needs a POSITIVE confirmation (no drawn line, no cut -> no member)
                log['nl_not_cut_in_sections'].append(f"Y={m['a'][1]:.0f} X {min(m['a'][0], m['b'][0]):.0f}..{max(m['a'][0], m['b'][0]):.0f}: " + (f"not cut in {', '.join(sorted(set(bad)))}" if bad else 'no section crosses it'))
                continue
            if ok:
                m['evidence'] = list(m['evidence']) + ['R-NL4 cut in ' + ', '.join(sorted(set(ok)))]
        keep.append(m)
    mem[:] = keep
    # offsets per cut line
    for c in mycuts:
        pairs = []
        for m in mem:
            if m['kind'] in kinds:
                u = _crossing(m, c)
                if u is not None:
                    s = min(c['stubs'], key=lambda s: abs(s - u)) if c['stubs'] else None
                    if s is not None:
                        pairs.append((u, s))
        c['_off'] = _offset(pairs)

    def shown(m, c):
        u = _crossing(m, c)
        if u is None:
            return None
        if not (c['range'][0] + END_SKIP < u < c['range'][1] - END_SKIP):
            return None                 # too near the view ends (end-wall brackets / out of the view)
        return any(abs(s - c['_off'] - u) < TOL for s in c['stubs'])

    # R-SY2 mirror
    if log['symmetric_note'] and settings.get('symmetry_mirror', True):
        from shapely.geometry import LineString
        side_drawn = {}
        if drawn and footprint is not None:
            from shapely.geometry import Point
            inside = [(x0, y0, x1, y1) for x0, y0, x1, y1 in drawn if footprint.contains(Point(((x0 + x1) / 2, (y0 + y1) / 2)))]
            npos = sum(1 for l in inside if l[1] + l[3] > 100)
            nneg = sum(1 for l in inside if l[1] + l[3] < -100)
            tot = max(1, npos + nneg)
            side_drawn = {1: npos > 0.2 * tot, -1: nneg > 0.2 * tot}
            log['plan_sides_drawn'] = {'P': side_drawn[1], 'S': side_drawn[-1]}
        add = []
        for m in list(mem):
            if m['kind'] not in kinds:
                continue
            (x1, y1), (x2, y2) = m['a'], m['b']
            if min(y1, y2) < 50 < max(y1, y2) or min(y1, y2) < -50 < max(y1, y2) or max(abs(y1), abs(y2)) < 50:
                continue                # crosses / sits on the centre line: its own mirror
            mm_ = {'a': (x1, -y1), 'b': (x2, -y2)}
            L = LineString([mm_['a'], mm_['b']])
            twin = False
            for k in mem + add:
                if k['kind'] not in kinds:
                    continue
                K = LineString([k['a'], k['b']])
                if K.length > 0 and L.length > 0 and K.hausdorff_distance(L) < 120:
                    twin = True
                    break
                if L.length > 0 and K.distance(L) < 60 and L.buffer(60).intersection(K).length > 0.5 * L.length:
                    twin = True
                    break
            if twin:
                continue
            if footprint is not None and L.intersection(footprint).length < 0.5 * L.length:
                continue
            if openings and sum(L.intersection(o).length for o in openings) > 0.5 * L.length:
                continue
            side = 1 if (y1 + y2) < 0 else -1          # sign of the mirror side
            if drawn and side_drawn.get(side):
                # R-SY2b: the plan draws that side too -> 'as shown' there: the mirror must be a drawn (unlabelled) line of the plan
                cov = _cover(mm_['a'], mm_['b'], drawn)
                if cov < 0.6:
                    log['mirror_rejected'].append(f"{m['kind']} {round(x1)},{round(-y1)}-{round(x2)},{round(-y2)}: not drawn on that side of the plan ({cov:.0%} of its length)")
                    continue
            verdicts = [(c['view'], shown(mm_, c)) for c in mycuts if shown(mm_, c) is not None]
            if any(v is False for _, v in verdicts):
                log['mirror_rejected'].append(f"{m['kind']} {round(x1)},{round(-y1)}-{round(x2)},{round(-y2)}: not shown in " +
                                              ', '.join(vn for vn, v in verdicts if v is False))
                continue
            n = dict(m)
            n['_mirror_of'] = m
            n['a'], n['b'] = mm_['a'], mm_['b']
            n['evidence'] = list(m.get('evidence', [])) + [
                f"R-SY2 from symmetry note: mirror of the drawn member at Y {round(y1)}..{round(y2)} ({log['symmetric_note']})" +
                (f"; confirmed by {', '.join(vn for vn, _ in verdicts)}" if verdicts else '; no elevation / section crosses it: UNVERIFIED')]
            if not verdicts:
                log['mirror_unverified'] += 1
            add.append(n)
        mem += add
        log['mirrored'] = len(add)
    # R-XV7 (Rule 5: FR.22 SEC. shows a 500X10+150X12 F.B(T) web under every deck, the plans built it on C deck only): a transverse
    # T-web read in a frame section under THIS deck becomes a deep member of the deck when the plan draws a line at that X over >= 50 %
    # of its length and the deck has no deep / girder there yet
    log['section_webs_added'] = []
    for wb in [w for w in SEC_WEBS if abs(w['z'] - z) < 5]:
        X = wb['X']
        if footprint is not None and not (footprint.bounds[0] - 5 <= X <= footprint.bounds[2] + 5):
            continue
        have = [m for m in list(deck.get('deep', [])) + mem if m['kind'] in ('deep', 'girder') and abs(m['a'][0] - X) < 120 and abs(m['b'][0] - X) < 120
                and min(max(m['a'][1], m['b'][1]), wb['y1']) - max(min(m['a'][1], m['b'][1]), wb['y0']) > 0.5 * (wb['y1'] - wb['y0'])]
        if have:
            continue
        cov = _cover((X, wb['y0']), (X, wb['y1']), drawn or [], lat=60.0) if drawn else 0.0
        if cov < 0.8:              # R-EV: the plan must draw the web (the section only types / sizes it); else a question
            log.setdefault('section_webs_not_in_plan', []).append(f"{wb['label']} at X={X:.0f} Y {wb['y0']}..{wb['y1']} ({wb['view']}): plan line covers {cov:.0%}")
            continue
        h, t, fw, ft = wb['sec']
        deck.setdefault('deep', []).append({'kind': 'deep', 'a': (X, wb['y1']), 'b': (X, wb['y0']), 'section': None, 'depth': h, 'web_t': t, 'face': (fw, ft),
                                            'evidence': [f"R-XV7 transverse web {wb['label']} read in {wb['view']} under this deck; the plan draws its line ({cov:.0%})"]})
        log['section_webs_added'].append(f"{wb['label']} X={X:.0f} Y {wb['y0']}..{wb['y1']}")
    # R-XV8: the size of a deck longitudinal seen side-on in an OFF C.L elevation (label under the deck line) is that member's size when
    # the plan gave it only a default (header / unmarked / NO.nL); a different printed size is reported, never silently changed
    from . import members as _mb
    log['elev_sizes'] = []
    for el in [e for e in ELEV_LONGS if abs(e['z'] - z) < 5]:
        for m in mem:
            if m['kind'] not in kinds or abs(m['a'][1] - m['b'][1]) > 1 or abs(m['a'][1] - el['Y']) > 60:
                continue
            # R-XV8d (owner 2026-10-25: 'NO.3L is not a girder'): an elevation also shows members BEYOND its plane; its size is taken only
            # when the frame sections crossing the member show it cut at this Y (or no section crosses it)
            ok_, bad_ = _sec_votes(m)
            if bad_ and not ok_:
                log.setdefault('elev_size_not_in_plane', []).append(f"Y={el['Y']:.0f}: {el['text']} in {el['view']} is not at this Y (not cut in {', '.join(sorted(set(bad_)))})")
                continue
            lo_, hi_ = sorted((m['a'][0], m['b'][0]))
            if min(hi_, el['x1']) - max(lo_, el['x0']) < 0.5 * (hi_ - lo_):
                continue
            new = _mb.parse_section(el['text'])
            if new is None and notes:
                for key in ('girder', 'beam', 'deep'):
                    cand = _mb.parse_section(notes.get(key, '')) if notes.get(key) else None
                    if cand and abs(float(cand[1]) - el['h']) < 1:
                        new = cand
                        break
            ev = ' '.join(m.get('evidence', []))
            default = any(k in ev for k in ('R-NL', 'default', 'unmarked', 'header'))
            if new and m.get('section') != new:
                if default:
                    m['section'] = new
                    # R-XV8b (owner 2026-10-25: the member's own view - plan or OFF C.L - gives what it is): the elevation size is the
                    # header GIR. size -> the member is a girder (EC weather shield NO.3L = 300X90X11/16 I.A in 2640 OFF C.L ELEV.)
                    gsec = _mb.parse_section(notes.get('girder', '')) if notes and notes.get('girder') else None
                    if gsec and tuple(new) == tuple(gsec) and m['kind'] == 'beam':
                        m['kind'] = 'girder'
                        m['evidence'] = list(m.get('evidence', [])) + ['R-XV8b kind = girder (elevation size = header GIR. size)']
                    m['evidence'] = list(m.get('evidence', [])) + [f"R-XV8 size {el['text']} from {el['view']} (member seen side-on under the deck)"]
                    log['elev_sizes'].append(f"{m['kind']} Y={el['Y']:.0f} X {lo_:.0f}..{hi_:.0f}: {el['text']} ({el['view']})")
                else:
                    log.setdefault('elev_size_conflicts', []).append(f"{m['kind']} Y={el['Y']:.0f}: plan {m.get('section')} vs {el['text']} in {el['view']}")
    # R-XV8c: the size of a transverse deck member seen side-on in its own frame section (same rules as R-XV8 / R-XV8b)
    for el in [e for e in SEC_SIDEON if abs(e['z'] - z) < 5]:
        for m in mem:
            if m['kind'] not in kinds or abs(m['a'][0] - m['b'][0]) > 1 or abs(m['a'][0] - el['X']) > 60:
                continue
            lo_, hi_ = sorted((m['a'][1], m['b'][1]))
            if min(hi_, el['y1']) - max(lo_, el['y0']) < 0.5 * (hi_ - lo_):
                continue
            new = _mb.parse_section(el['text'])
            if new is None and notes:
                for key in ('girder', 'beam', 'deep'):
                    cand = _mb.parse_section(notes.get(key, '')) if notes.get(key) else None
                    if cand and abs(float(cand[1]) - el['h']) < 1:
                        new = cand
                        break
            ev = ' '.join(m.get('evidence', []))
            default = any(k in ev for k in ('R-NL', 'default', 'unmarked', 'header'))
            if new and m.get('section') != new:
                if default:
                    m['section'] = new
                    m['evidence'] = list(m.get('evidence', [])) + [f"R-XV8c size {el['text']} from {el['view']} (member seen side-on under the deck)"]
                    gsec = _mb.parse_section(notes.get('girder', '')) if notes and notes.get('girder') else None
                    if gsec and tuple(new) == tuple(gsec) and m['kind'] == 'beam':
                        m['kind'] = 'girder'
                        m['evidence'] = list(m.get('evidence', [])) + ['R-XV8b kind = girder (section size = header GIR. size)']
                    log['elev_sizes'].append(f"{m['kind']} X={el['X']:.0f} Y {lo_:.0f}..{hi_:.0f}: {el['text']} ({el['view']})")
                else:
                    log.setdefault('elev_size_conflicts', []).append(f"{m['kind']} X={el['X']:.0f}: plan {m.get('section')} vs {el['text']} in {el['view']}")
    # R-FL2 flange side of every deck member from the L symbol where a section / elevation cuts it (votes over all cutting views)
    log['flange_from_L'] = 0
    log['flange_conflicts'] = []
    log['flange_not_found'] = 0
    for m in mem:
        if m['kind'] not in kinds or not m.get('section') or m['section'][0] != 'L':
            continue
        votes = []
        for c in mycuts:
            if not c.get('lsym') or shown(m, c) is not True:
                continue
            u = _crossing(m, c)
            near = [(abs(us - c['_off'] - u), sd) for us, sd in c['lsym'] if abs(us - c['_off'] - u) < TOL]
            if near:
                sd = min(near)[1]
                votes.append(((sd, 0.0) if c['type'] == 'elev' else (0.0, sd), c['view']))
        if votes:
            dirs = {v for v, _ in votes}
            best = max(dirs, key=lambda d: sum(1 for v, _ in votes if v == d))
            m['flange_dir'] = best
            m.setdefault('evidence', []).append('R-FL2 flange toward %s from the L symbol in %s' % (
                {(1.0, 0.0): '+X', (-1.0, 0.0): '-X', (0.0, 1.0): '+Y', (0.0, -1.0): '-Y'}.get(best, str(best)),
                ', '.join(sorted({vn for v, vn in votes if v == best}))))
            log['flange_from_L'] += 1
            if len(dirs) > 1:
                log['flange_conflicts'].append(f"{m['kind']} {round(m['a'][0])},{round(m['a'][1])}: L symbols disagree " + ', '.join(f'{v}:{vn}' for v, vn in votes))
    for m in mem:                                 # a mirrored member without its own L takes the mirror of its source's flange
        src = m.get('_mirror_of')
        if src is not None and 'flange_dir' not in m and src.get('flange_dir'):
            fx, fy = src['flange_dir']
            m['flange_dir'] = (fx, -fy)
            m.setdefault('evidence', []).append('R-FL2 flange mirrored from the source member (R-SY2)')
    for m in mem:
        m.pop('_mirror_of', None)
        if m['kind'] in kinds and m.get('section') and m['section'][0] == 'L' and 'flange_dir' not in m:
            log['flange_not_found'] += 1
    # R-FL3 (2026-10-25): the pieces of ONE member line (same kind, same line, same section) share the flange side read on any of them,
    # when the pieces that were read agree (EC: NO.3L flange from FR.22+800 SEC. on 7 pieces, 6 pieces had none)
    lines = {}
    for m in mem:
        if m['kind'] in kinds and m.get('section') and m['section'][0] == 'L':
            hz = abs(m['a'][1] - m['b'][1]) < 1
            vt = abs(m['a'][0] - m['b'][0]) < 1
            if hz or vt:
                lines.setdefault((m['kind'], 'H' if hz else 'V', round((m['a'][1] if hz else m['a'][0]) / 20.0), tuple(m['section'])), []).append(m)
    log['flange_shared_on_line'] = 0
    for grp in lines.values():
        ds = {tuple(m['flange_dir']) for m in grp if m.get('flange_dir')}
        if len(ds) == 1:
            d = ds.pop()
            for m in grp:
                if not m.get('flange_dir'):
                    m['flange_dir'] = d
                    m.setdefault('evidence', []).append('R-FL3 flange from the other pieces of the same member line')
                    log['flange_shared_on_line'] += 1
                    log['flange_not_found'] -= 1
    # R-B9 bracket source at a member end (owner 2026-10-25): 1) the detail view of the OFF C.L / longi / frame the member belongs to
    # (bracket 'LxT' drawn at that corner), 2) the typical section of that deck, 3) the TYP. END CONNECTION of that member type; else ask.
    log['brackets_from_elevation'] = []
    bmarks = deck.get('b_marks', [])
    for m in mem:
        if m['kind'] not in kinds or abs(m['a'][1] - m['b'][1]) > 1:
            continue
        Y = m['a'][1]
        for end in ('a', 'b'):
            X = m[end][0]
            el = next((e for e in ELEV_BKTS if abs(e['z'] - z) < 5 and abs(e['Y'] - Y) < 60 and abs(e['X'] - X) < 400), None)
            marked = m.get('bracket_' + end) or any(abs(by - Y) < 250 and abs(bx - X) < 600 for bx, by in bmarks)
            if el:
                m['bracket_' + end] = True
                m['bracket_size_' + end] = (el['leg'], el['t'])
                m['bracket_unknown_' + end] = False
                m.setdefault('evidence', []).append(f"R-B9 bracket {el['text']} at end {end} from {el['view']} (the member's own OFF C.L view)")
                log['brackets_from_elevation'].append(f"{m['kind']} Y={Y:.0f} end X={X:.0f}: {el['text']} ({el['view']})")
            elif marked and not m.get('bracket_' + end):
                m['bracket_' + end] = True
                m['bracket_size_' + end] = None
                m['bracket_unknown_' + end] = True
                m.setdefault('evidence', []).append(f"R-B9 'B' mark at end {end} (plan, note 4.3 bracket connection): size not in its own view - typical section / ask")
    # R-B10 wall-stiffener brackets: size from the OFF C.L elevation of that line (bracket at that deck end), else unknown (asked)
    for wb in deck.get('wall_brackets', []):
        X, Y = wb['p']
        el = next((e for e in ELEV_BKTS if abs(e['z'] - z) < 5 and abs(e['Y'] - Y) < 60 and abs(e['X'] - X) < 400), None) if wb['d'][1] == 0 else None
        if el:
            wb['size'] = (el['leg'], el['t'])
            wb['evidence'].append(f"size {el['text']} from {el['view']}")
    log['wall_brackets'] = {'n': len(deck.get('wall_brackets', [])), 'sized': sum(1 for w in deck.get('wall_brackets', []) if w['size'])}
    # R-B9 step 3: a bracket end whose size is still unknown takes the mark of the TYP. END CONNECTION of its own section
    try:
        tec = typ_end_connections(pdf)
    except Exception:
        tec = {}
    log['brackets_from_typ_end_connection'] = 0
    for m in mem:
        for end in ('a', 'b'):
            if not (m.get('bracket_' + end) and m.get('bracket_unknown_' + end)) or not m.get('section'):
                continue
            for title, t in tec.items():
                ts = _mb.parse_section(t['section_text'])
                if ts and tuple(ts) == tuple(m['section']):
                    mk = t['marks'][0]
                    m['bracket_mark_' + end] = mk
                    from .elevation import BKT_TABLE as _BT
                    if mk in _BT:          # R-B11: size of the mark from the DET. OF BRACKET table
                        m['bracket_size_' + end] = _BT[mk]
                        m['bracket_unknown_' + end] = False
                        m.setdefault('evidence', []).append(f"R-B9/R-B11 bracket {mk} = {_BT[mk][0]:g}x{_BT[mk][1]:g} at end {end} (TYP. END CONNECTION {title}; DET. OF BRACKET table)")
                    else:
                        m.setdefault('evidence', []).append(f"R-B9 bracket {mk} at end {end} from TYP. END CONNECTION ({title}), p{t['page']} - {mk} not in any DET. OF BRACKET table: ask")
                    log['brackets_from_typ_end_connection'] += 1
                    break
    # R-XV3 confirm / report
    for m in mem:
        if m['kind'] not in kinds:
            continue
        ok, bad = [], []
        for c in mycuts:
            s = shown(m, c)
            if s is True:
                ok.append(c['view'])
            elif s is False:
                bad.append(c['view'])
        if ok:
            m.setdefault('evidence', []).append('R-XV confirmed by ' + ', '.join(sorted(set(ok))))
            log['confirmed'] += 1
        if bad:
            m.setdefault('evidence', []).append('R-XV NOT shown in ' + ', '.join(sorted(set(bad))) + ' - confirm')
            log['not_shown'].append(f"{m['kind']} {round(m['a'][0])},{round(m['a'][1])}-{round(m['b'][0])},{round(m['b'][1])}: not in {', '.join(sorted(set(bad)))}")
    for c in mycuts:
        for s in c['stubs']:
            u = s - c['_off']
            if not (c['range'][0] + END_SKIP < u < c['range'][1] - END_SKIP):
                continue
            if footprint is not None:
                from shapely.geometry import Point
                P = Point((u, c['pos'])) if c['type'] == 'elev' else Point((c['pos'], u))
                if not footprint.contains(P) or footprint.boundary.distance(P) < EDGE_SKIP:
                    continue
            hit = False
            for m in mem + list(deck.get('deep', [])):
                if m['kind'] in kinds + ('deep',):
                    w = _crossing(m, c, strict=False)
                    if w is not None and abs(w - u) < TOL:
                        hit = True
                        break
            if not hit:
                where = f"X={u:.0f} at Y={c['pos']:.0f}" if c['type'] == 'elev' else f"Y={u:.0f} at X={c['pos']:.0f}"
                log['missing'].append(f"{c['view']}: member cut at {where}, no deck member there")
    return log


def _deck_extent_on_line(fp, axis, pos):
    """(lo, hi) of the deck footprint along the line X = pos (axis 'x') or Y = pos (axis 'y'), or None"""
    from shapely.geometry import LineString
    b = fp.bounds
    L = LineString([(pos, b[1] - 10), (pos, b[3] + 10)]) if axis == 'x' else LineString([(b[0] - 10, pos), (b[2] + 10, pos)])
    g = L.intersection(fp.buffer(60))
    if g.is_empty:
        return None
    k = 1 if axis == 'x' else 0
    cs = [c[k] for geom in getattr(g, 'geoms', [g]) for c in geom.coords]
    return (min(cs), max(cs)) if cs else None


def wall_support(axis, pos, u0, u1, decks):
    """R-XV4 / R-XV4b. A vertical panel on the line X = pos (axis 'x', frame section, u = Y) or Y = pos (axis 'y', OFF C.L, u = X)
    between two decks. Returns (checked, cover, clip): clip = the u range inside the built deck(s) of the tier (the panel cannot stand
    outside every deck it connects), cover = share of that range carried by a deck wall line / deck edge (deck member lines - girders,
    deep webs - are members, not walls, and do not count)."""
    from shapely.geometry import LineString
    best, checked, lo, hi = 0.0, False, None, None
    for d in decks:
        ext = _deck_extent_on_line(d['footprint'], axis, pos)
        if ext is None:
            continue
        a0, a1 = max(u0, ext[0]), min(u1, ext[1])
        lo = a0 if lo is None else min(lo, a0)
        hi = a1 if hi is None else max(hi, a1)
        if a1 - a0 < 400:
            continue
        checked = True
        A, B = ((pos, a0), (pos, a1)) if axis == 'x' else ((a0, pos), (a1, pos))
        mem = [LineString([m['a'], m['b']]) for m in d.get('members', [])]
        walls = []
        for w in d['walls']:
            W = LineString([(w[0], w[1]), (w[2], w[3])])
            if any(M.length > 0 and W.distance(M) < 60 and W.hausdorff_distance(M) < max(80, 1.05 * W.length) and
                   W.buffer(60).intersection(M).length > 0.6 * W.length for M in mem):
                continue                        # this thick line is a girder / deep web of the deck, not a wall
            walls.append(w)
        c1 = _cover(A, B, walls, lat=d.get('lat', 60.0))
        c2 = LineString([A, B]).intersection(d['footprint'].boundary.buffer(60)).length / (a1 - a0)
        best = max(best, c1, c2)
    return checked, best, ((lo, hi) if lo is not None and hi is not None and hi > lo else None)


def clip_panel(p_, lo, hi, key):
    """cut a wall / section panel to lo..hi along u; stiffeners outside are dropped. True when something was cut."""
    us = [u for u, _ in p_['poly']]
    if min(us) >= lo - 1 and max(us) <= hi + 1:
        return False
    p_['poly'] = [(min(max(u, lo), hi), v) for u, v in p_['poly']]
    p_['stiffeners'] = [s for s in p_['stiffeners'] if lo - 1 <= s[key] <= hi + 1]
    return True


WALLPLANS = {}                          # deck code -> walls standing ON that deck, from "ARRG'T OF STEEL WALL ON <deck>" plans (R-XV4c)
WP_TITLE = re.compile(r"ARR(?:AN)?G(?:EMEN)?'?T\.?\s+OF\s+(?:STEEL\s+)?WALLS?\s+ON\s+(.+?)\s*\.?\s*-?\s*(DECK|STR(?:INGER|\.)?|SHIELD)\s*$", re.I)


def _wp_code(name, kind):
    n = re.sub(r'[^A-Z0-9 ]', ' ', name.upper()).split()
    if kind.upper().startswith('STR') and n and n[-1].isdigit():
        return 'S' + n[-1]
    if kind.upper().startswith('SHIELD'):
        return 'W'
    if not n:
        return None
    return {'UPP': 'UPP', 'UPPER': 'UPP', 'NAV': 'NAV', 'COMP': 'COMP'}.get(n[0], n[0] if len(n[0]) == 1 else None)


def load_wallplans(pdf, settings):
    """R-XV4c: an "ARRG'T OF STEEL WALL ON <deck>" plan is the layout of the walls standing on that deck (tier <deck> .. next deck).
    X from its own frame-number row (its own scale), Y from its centre line = the long dash-dot line across it; walls = its solid
    straight lines inside the outline. Used by R-XV4 for the walls of that tier."""
    from . import pdfsrc, framedrawn, view as dview
    from .run import frame_x_fn
    from .run_elev import _pdf_spacings
    import pymupdf
    from shapely.geometry import box
    WALLPLANS.clear()
    n = len(pymupdf.open(pdf))
    sp = sorted(_pdf_spacings(pdf, n))

    class _V:
        frame_space = settings.get('frame_spacing_mm') or (sp[0] if sp else 800)
    ft0 = frame_x_fn(settings, _V)
    log = []
    for pn in range(n):
        page = pdfsrc.load_page(pdf, pn)
        rows = None
        for w in page.words:
            m = WP_TITLE.search(w.text.strip())
            if not m or w.size < 12:
                continue
            code = _wp_code(m.group(1), m.group(2))
            if not code:
                continue
            rows = rows if rows is not None else [(r, dview._row_y(page, r)) for r in framedrawn._rows(page)]
            cand = [(r, y) for r, y in rows if w.bbox[3] < y < w.bbox[3] + 1300 and abs(statistics.mean(x for _, x in r) - w.cx) < 400]
            if not cand:
                log.append(f'p{pn + 1} {w.text.strip()}: no frame row')
                continue
            r, ry = min(cand, key=lambda t: abs(statistics.mean(x for _, x in t[0]) - w.cx))      # the row under THIS title (not a neighbour's)
            pairs = [(ft0(b[0]) - ft0(a[0])) / (b[1] - a[1]) for a, b in zip(r, r[1:]) if b[1] > a[1]]
            ks = statistics.median(pairs)
            x0s = statistics.median(x - ft0(k_) / ks for k_, x in r)
            X0, X1 = r[0][1] - 60, r[-1][1] + 60          # the frame row spans the plan (labels at the frames over it)
            vs = [s for s in page.segs if s.vertical and not s.dash and X0 < s.a[0] < X1 and w.bbox[3] < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < ry - 3]
            if not vs:
                continue
            lg = [s for s in vs if s.length > 10]
            ox0, ox1 = min(s.a[0] for s in lg), max(s.a[0] for s in lg)
            oy0, oy1 = min(min(s.a[1], s.b[1]) for s in lg), max(max(s.a[1], s.b[1]) for s in lg)
            cls = [s for s in page.segs if s.horizontal and s.dash and len(str(s.dash).split(',')) >= 3 and
                   min(s.a[0], s.b[0]) < (ox0 + ox1) / 2 < max(s.a[0], s.b[0]) and s.length > 0.5 * (ox1 - ox0) and oy0 < s.a[1] < oy1]
            if not cls:
                log.append(f'p{pn + 1} {w.text.strip()}: no centre line (dash-dot line across the plan)')
                continue
            cly = min(cls, key=lambda s: abs(s.a[1] - (oy0 + oy1) / 2)).a[1]
            grid = []                           # R-XV5b: small-scale plan -> its aft edge snaps to the quarter-bay frame grid (<= 150 mm)
            for k_ in range(-10, 400):
                a_, b_ = ft0(k_), ft0(k_ + 1)
                if isinstance(a_, (int, float)) and isinstance(b_, (int, float)):
                    grid += [a_ + q * (b_ - a_) / 4 for q in range(4)]
            xa = (ox0 - x0s) * ks
            g = min(grid, key=lambda X: abs(X - xa)) if grid else xa
            dX = (g - xa) if abs(g - xa) <= 150 else 0.0
            Xm = lambda px, dX=dX: (px - x0s) * ks + dX
            Ym = lambda py: (cly - py) * ks
            walls = []
            for s in page.segs:
                if s.dash or not (s.horizontal or s.vertical) or s.length < 2:
                    continue
                if all(ox0 - 2 <= p[0] <= ox1 + 2 and oy0 - 2 <= p[1] <= oy1 + 2 for p in (s.a, s.b)):
                    walls.append((Xm(s.a[0]), Ym(s.a[1]), Xm(s.b[0]), Ym(s.b[1])))
            fp = box(Xm(ox0), Ym(oy1), Xm(ox1), Ym(oy0))
            WALLPLANS[code] = {'name': w.text.strip(), 'footprint': fp, 'walls': walls, 'members': [], 'lat': max(60.0, 2.5 * ks)}   # 2.5 pt of a small-scale plan
            log.append(f'p{pn + 1} {w.text.strip()}: deck {code}, X {Xm(ox0):.0f}..{Xm(ox1):.0f}, Y {Ym(oy1):.0f}..{Ym(oy0):.0f}, {len(walls)} wall lines')
    return log


def wall_at(axis_pos, u, zlo, zhi, X=None, Y=None, tol=60.0, codes=()):
    """R-S17: is there a wall standing at the line Y = u at X between the decks zlo..zhi? True / False / None (nothing known).
    Sources: the OFF C.L wall panels built, the deck plans of THIS tier (upper and lower deck, girder / deep lines excluded) and the
    wall arrangement plan of the lower deck."""
    from shapely.geometry import LineString
    srcs = [DECKS.get(round(zlo)), DECKS.get(round(zhi))] + [WALLPLANS.get(c) for c in codes[:1]]
    srcs = [d for d in srcs if d]
    if not ELEV_WALLS and not srcs:
        return None
    for (y, z0, z1, x0, x1) in ELEV_WALLS:
        if abs(y - u) < tol and z0 < (zlo + zhi) / 2 < z1 and x0 - tol <= X <= x1 + tol:
            return True
    for d in srcs:
        lat = d.get('lat', tol)
        mem = [LineString([m['a'], m['b']]) for m in d.get('members', [])]
        for w in d['walls']:
            if abs(w[1] - w[3]) < 1 and abs(w[1] - u) < lat and min(w[0], w[2]) - lat <= X <= max(w[0], w[2]) + lat and abs(w[2] - w[0]) > 300:
                W = LineString([(w[0], w[1]), (w[2], w[3])])
                if any(M.length > 0 and W.distance(M) < 60 and W.buffer(60).intersection(M).length > 0.6 * W.length for M in mem):
                    continue
                return True
    return False
