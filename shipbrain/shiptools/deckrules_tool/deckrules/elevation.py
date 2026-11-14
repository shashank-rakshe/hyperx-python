"""Longitudinal bulkhead elevations ('NNNN OFF C.L ELEV.(P|S)') -> wall panels on the moulded line.

Rules (drawing only; the reference XML is never read here):
  R-E1  Title 'NNNN OFF C.L ELEV.(P|S)' = plane Y=+NNNN (P, port) / -NNNN (S); 'CENTER LINE ELEV.' = Y=0.
        Notes under the title: 'PLATE THK. : t (EXC. AS SHOWN)', 'STIFF. SIZE : hXwXt U.A (EXC. AS SHOWN)'.
  R-E2  Frame-number row below the view: ship X = n * frame_space (project frame table) -> page x.
        Deck lines are long horizontal lines; Z comes from the deck heights read on the deck plans
        (UPP. DECK = A-DECK - 3200). The UPP.DECK line sits a fixed distance above the frame-number row.
  R-E3  A wall exists in a deck-to-deck tier where vertical lines span the whole tier.
        Lines with triangle end-markers are STIFFENERS; the others are wall EDGES. A run of stiffeners
        (spacing <= 1.7 x median) plus the nearest edge on each side is one wall panel; its plate is the
        rectangle edge-to-edge, deck-to-deck, ON THE MOULDED LINE (no thickness shift, no MaterialSide).
  R-E4  Thickness: a 'n.n' note inside the wall (not an 'xx FL.' tab), else the title default.
  R-E5  Stiffener section: nearest vertical label ('125X75X7 U.A', '100 U.A' short form -> title/sheet size),
        else the title default. Stiffener ends touch the deck lines (moulded) - no gap.
  R-E6  Cut-outs: closed thin rings / rounded rectangles inside the wall.
"""
import copy
import math
import os
import re
import statistics
from collections import Counter, defaultdict

from shapely.geometry import LineString, Polygon, box

from . import members
from .deckplan import closed_paths, thin_weight, _rounded

TITLE = re.compile(r'^\s*(?P<n>\d+)\s*OFF C\.L ELEV\.?\s*(?:\((?P<s>[PS])\))?\s*$')
CL_TITLE = re.compile(r'^\s*CENTER\s*LINE\s*ELEV(?:ATION|\.)?\s*$')
NO_TITLE = re.compile(r'^\s*NO\.?\s*(?P<n>\d{1,2})\s*LONGL\.?\s*ELEV\.?\s*(?:\((?P<s>[PS])\))?\s*(?:SIM.*)?$')   # R-E22
NOTE_T = re.compile(r'PLATE\s+THK\.?\s*:\s*([\d.]+)')
NOTE_S = re.compile(r'STIFF\.?\s*(?:SIZE)?\s*:\s*([0-9X/]+\s*[A-Z.]+)')
THK = re.compile(r'^(\d{1,2}\.\d)\s*("?\s*AH\s*"?)?$')


def _thk(w, words):
    """plate thickness mark ('12.0', '12.0 "AH"') - None when R2.1 says it is a weld size"""
    m = THK.match(w.text.strip())
    if m:
        from . import numclass
        if numclass.is_weld_size(w, words):
            return None
    return m
_MODE = 0                      # 0 = first reading; 1 = second reading (R-E1c/R-E3g/R-E15b/R-E2h/R-E23): only when the first one fails
MIN_ROW = 3                    # printed frame numbers per row (typical sketches print only 4-5)
UPPER_OFFSET = 3200.0          # A-DECK to UPP. DECK
DECK_ORDER = ['UPP', 'A', 'B', 'C', 'D', 'NAV', 'COMP']


class ElevView:
    def __init__(self, name, y, side, title):
        self.name, self.y, self.side, self.title = name, y, side, title
        self.notes = {}
        self.k = None
        self.x0 = None
        self.y_upp = None            # page y of the UPP. DECK line
        self.row_cy = None
        self.ytop = None             # page y of the top of the view (title bottom, or row-700 for titles below the view)
        self.xr = None               # page x range of the view
        self.decks = {}              # deck code -> page y
        self.zov = {}                # deck code -> measured Z (mm) where it differs from the sheet table
        self.evidence = {}

    def X(self, px):
        return (px - self.x0) * self.k

    def Z(self, py):
        return 19700.0 + (self.y_upp - py) * self.k

    def py(self, Z):
        return self.y_upp - (Z - 19700.0) / self.k


SW = re.compile(r'^\s*S\.?\s*W\.?\s*$')
DOOR = re.compile(r'^\s*\d{3,4}\s*[Xx×]\s*\d{3,4}(\s*[Xx×]\s*R?\s*\d{2,3})?\s*$')


def _sw_mark(words, x, y0, y1, r=20.0):
    """R2.13 (online rule book v2.3): 'S.W' printed beside a vertical line of a wall view marks another wall seen edge-on"""
    return any(SW.match(w.text or '') and abs(w.cx - x) < r and y0 - r < w.cy < y1 + r for w in words)


def _door_label(words, poly):
    """R2.17: a printed door size 'AxB' or 'AxBxR' inside the closed outline"""
    from shapely.geometry import Point
    for w in words:
        m = DOOR.match(w.text or '')
        if m and poly.contains(Point(w.cx, w.cy)):
            a, b = [int(t) for t in re.findall(r'\d+', w.text)[:2]]
            if 500 <= a <= 2500 and 500 <= b <= 2500:       # door / opening sizes, not a section such as 300X100X11
                return True
    return False


def _clip_at_doors(st, holes, tol=50.0):
    """R4.11 (online rule book v2.3): a wall stiffener whose line crosses a door / opening starts at the opening top (above the header);
    a stiffener that lies wholly inside the opening is dropped. Openings are [(X, Z), ...] in the wall's own coordinates."""
    out = []
    for s_ in st:
        x, a, b = s_['x'], s_['a_z'], s_['b_z']
        keep = True
        for h in holes:
            xs = [q[0] for q in h]; zs = [q[1] for q in h]
            if not (min(xs) + tol < x < max(xs) - tol):
                continue
            z0, z1 = min(zs), max(zs)
            if z0 <= a + tol and z1 < b - 300:            # opening from the deck up: the stiffener starts above it
                s_ = dict(s_, a_z=z1, evidence=s_.get('evidence', '') + ' (R4.11 starts at the opening top)')
                a = z1
            elif z0 <= a + tol and z1 >= b - tol:
                keep = False
        if keep:
            out.append(s_)
    return out


HASH = re.compile(r'^\s*#\s*(\d?)\s*$')
CORNER_BKT = re.compile(r'^\s*(\d{2,4})\s*[Xx×]\s*(\d{2,4})\s*/\s*(\d{1,2}(?:\.\d)?)\s*(?:R\s*\d+)?\s*$')
FB = re.compile(r'(\d{2,3})\s*[Xx×]\s*(\d{1,2}(?:\.\d)?)\s*F\.?\s*B', re.I)


def _wall_carlings(page, v, box_, st, settings):
    """R2.18 (online rule book v2.3): a '#' / '#n' mark on a HORIZONTAL line inside a wall view, between two vertical stiffeners,
    is a short carling at the drawn height, from stiffener to stiffener; section from the sheet's carling table (note 6)."""
    xL, xR, yt, yb = box_
    out = []
    xs = sorted(s_['x'] for s_ in st)
    if len(xs) < 2:
        return out
    carl = dict(members.sheet_carling(settings.get('_pdf')) or members.GLOBAL_CARL)
    for w in page.words:
        m = HASH.match(w.text or '')
        if not m or not (xL < w.cx < xR and yt < w.cy < yb):
            continue
        hs = [g for g in page.segs if g.horizontal and abs(g.a[1] - w.cy) < 8 and min(g.a[0], g.b[0]) - 3 < w.cx < max(g.a[0], g.b[0]) + 3]
        if not hs:
            continue
        y_ = statistics.median(g.a[1] for g in hs)
        X = v.X(w.cx)
        lo_ = [x for x in xs if x <= X]
        hi_ = [x for x in xs if x >= X]
        if not lo_ or not hi_ or hi_[0] - lo_[-1] < 200:
            continue
        key = '#' + m.group(1)
        sec = carl.get(key) or carl.get(m.group(1))
        out.append({'z': round(v.Z(y_)), 'x0': lo_[-1], 'x1': hi_[0], 'section': sec, 'far': any(g.dash for g in hs),
                    'evidence': f"R2.18 '{w.text.strip()}' on a horizontal line between wall stiffeners" + ('' if sec else ' - size not in the carling table (ASK)')})
    return out


def _portal_bars(page, v, box_, holes, U, Z, tol=60.0):
    """R2.19 (online rule book v2.3): a wall tier drawn OPEN under a band = portal: the opening (from the deck up) is a hole of the
    wall plate, and the printed face bar 'wxt F.B' inside the view runs along the opening top edge."""
    xL, xR, yt, yb = box_
    fbs = [FB.search(w.text or '') for w in page.words if xL - 20 < w.cx < xR + 20 and yt - 20 < w.cy < yb + 20]
    fbs = [f for f in fbs if f]
    if not fbs or not holes:
        return []
    w_, t_ = float(fbs[0].group(1)), float(fbs[0].group(2))
    out = []
    for h in holes:
        hx = [q[0] for q in h]; hz = [q[1] for q in h]
        if min(hz) <= Z[0] + tol and (max(hx) - min(hx)) >= 0.5 * (U[1] - U[0]):
            out.append({'z': max(hz), 'x0': min(hx), 'x1': max(hx), 'section': ('F', w_, t_), 'far': False,
                        'evidence': f"R2.19 portal: face bar {fbs[0].group(0)} on the opening top edge"})
    return out


def _corner_brackets(page, v, box_, U, Z):
    """R4.14 (online rule book v2.3): a corner bracket printed 'AxB / t' (radius optional) at a wall corner: leg A horizontal, pointing
    OUT of the wall end, leg B vertical along the wall edge into the tier, thickness t; it stands at the nearest wall corner
    (radius edge written straight, ASSUMED)."""
    xL, xR, yt, yb = box_
    out = []
    for w in page.words:
        m = CORNER_BKT.match(w.text or '')
        if not m or not (xL - 60 < w.cx < xR + 60 and yt - 30 < w.cy < yb + 30):
            continue
        X, Zw = v.X(w.cx), v.Z(w.cy)
        u = min(U, key=lambda a: abs(a - X)); z = min(Z, key=lambda a: abs(a - Zw))
        out.append({'u': u, 'z': z, 'su': 1.0 if u == U[1] else -1.0, 'sz': 1.0 if z == Z[0] else -1.0,
                    'a': float(m.group(1)), 'b': float(m.group(2)), 't': float(m.group(3)),
                    'evidence': f"R4.14 '{w.text.strip()}' at the wall corner (ASSUMED orientation)"})
    return out


def find_views(page):
    out = []
    for w in page.words:
        if w.size < 12:
            continue
        t = w.text.strip()
        m = TITLE.match(t)
        if m:
            sgn = {'P': 1, 'S': -1, None: 1}[m.group('s')]
            out.append(ElevView(t, sgn * int(m.group('n')), m.group('s') or '', w))
        elif CL_TITLE.match(t):
            out.append(ElevView(t, 0, '', w))
        elif NO_TITLE.match(t):
            # R-E22: 'NO.n LONGL.ELEV.(P)' - the OFF C.L of longitudinal NO.n from the drawing's own anchors (deckrules.longlno)
            from . import longlno
            m = NO_TITLE.match(t)
            yv, ev = longlno.y_of(page, int(m.group('n')))
            sgn = {'P': 1, 'S': -1, None: 1}[m.group('s')]
            v = ElevView(t, sgn * int(round(yv)) if yv is not None else None, m.group('s') or '', w)
            v.evidence['offcl'] = ev
            out.append(v)
    for v in out:
        t = v.title
        for w in page.words:
            if abs(w.bbox[0] - t.bbox[0]) < 25 and t.bbox[3] - 8 < w.bbox[1] < t.bbox[3] + 40 and not w.vertical:
                if 'sim' not in v.notes:
                    _sm = re.search(r'SIM(?:\.|ILAR)?\s*TO\s*(PORT|STBD|STARBOARD|P|S)(?:[\s.-]*SIDE|\b[\s.]*EXC)', w.text, re.I)   # also 'SIM.TO P-SIDE'
                    if _sm:
                        v.notes['sim'] = _sm.group(1).upper()[0]        # R-SY3: 'SIM. TO PORT SIDE EXCEPT AS SHOWN' under the title
                for key, rx in (('plate', NOTE_T), ('stiff', NOTE_S)):
                    m = rx.search(w.text)
                    if m and key not in v.notes:
                        v.notes[key] = m.group(1).strip()
    return out


def _fnum(w):
    return int(re.sub(r'\D', '', w.text))


def _digit_rows(page, min_row=None):
    min_row = min_row or MIN_ROW
    rows = defaultdict(list)
    for w in page.words:
        if re.fullmatch(r'(?:FR\.?\s*)?\d{1,3}', w.text.strip()) and w.size < 9 and not w.vertical:
            rows[round(w.cy / 3)].append(w)
    out = []
    for ws in rows.values():
        ws.sort(key=lambda w: w.cx)
        grp = [ws[0]]
        for w in ws[1:]:
            if w.cx - grp[-1].cx > 140 or _fnum(w) <= _fnum(grp[-1]):   # R-E3b: a number that does not increase starts another view's row
                if len(grp) >= min_row:
                    out.append(grp)
                grp = [w]
            else:
                grp.append(w)
        if len(grp) >= min_row:
            out.append(grp)
    res, seen = [], set()
    for g in out:
        m = _merge_staggered(page, g) if _MODE >= 1 else g
        k = tuple(sorted(id(w) for w in m))
        if k not in seen:
            seen.add(k)
            res.append(m)
    return res


def _merge_staggered(page, g):
    """R-E3g: a frame-number row may be printed at two heights (labels of the frames carrying a long tick line are lifted above
    the others) and with wide gaps (irregular bays). The frame numbers of one row share one text height: a number of another
    height (a dimension '300' next to FR.30) is not a frame label. Numbers of that height within 30 pt of the row height and
    within 140 pt of the row ends (grown one label at a time) that keep the numbers increasing left to right join the row."""
    if len(g) < 2:
        return g
    cy = statistics.median(w.cy for w in g)
    hs = statistics.median(w.size for w in g)
    m = [w for w in g if abs(w.size - hs) < 0.4]
    if len(m) < 2:
        return g
    pool = [w for w in page.words if not w.vertical and abs(w.size - hs) < 0.4 and re.fullmatch(r'(?:FR\.?\s*)?\d{1,3}', w.text.strip())
            and abs(w.cy - cy) < 30]
    grown = True
    while grown:
        grown = False
        ids = {id(w) for w in m}
        for w in pool:
            if id(w) in ids or not (m[0].cx - 140 < w.cx < m[-1].cx + 140):
                continue
            t = sorted(m + [w], key=lambda u: u.cx)
            if all(_fnum(b) > _fnum(a) for a, b in zip(t, t[1:])):
                m, grown = t, True
                break
    return m


AB_LABEL = re.compile(r'^\s*\(?\s*(\d{4,5})\s*A/B\s*\)?\s*$')   # R-E15: 4- or 5-digit heights ('(8248 A/B)')


def _label_code(w, deck_z):
    """deck code of a deck label: 'B - DECK', 'NO. 3 STRINGER', 'WEATHER SHIELD', 'E/C MONORAIL HOIST DECK' (E: the deck plan of that name),
    R-E15: '32930 A/B' / '(34450 A/B)' = the deck at that height (the known deck within 20 mm, else a new deck of that height)"""
    from .section import DECK_LABEL
    t = w.text.strip()
    from . import decknames
    c = decknames.key(t)                                   # R-DN1
    if c:
        return c if c in deck_z else None
    if re.match(r'^\s*E/C\s+MONORAIL(\s+HOIST\s+DECK)?\s*$', t) and 'E' in deck_z:
        return 'E'                      # the label may be split in two lines ('E/C MONORAIL' / 'HOIST DECK'): the first line names the deck
    m = AB_LABEL.match(t)
    if m and len(m.group(1)) == 4 and _MODE < 1:
        m = None
    if m:
        z = float(m.group(1))
        near = [c for c, zz in deck_z.items() if abs(zz - z) <= 20]
        if near:
            return min(near, key=lambda c: abs(deck_z[c] - z))
        deck_z['Z' + m.group(1)] = z
        return 'Z' + m.group(1)
    return None


def _decks_from_labels(page, v, ys, deck_z, cy):
    """R-E2c: right-hand deck labels ('COMP. DECK', 'NAV. DECK', 'C - DECK', 'NO.1 STR.') name the long deck lines;
    works for typical sketches that show only two decks and no UPP. DECK line."""
    # R-E15b: a deck NAME without a plan height ('E/R 4TH DECK') with its height label right under it ('(8248 A/B)') is that deck
    # at that height (local to this view, like R-E15)
    from . import decknames
    for w in (page.words if _MODE >= 1 else []):
        c_ = decknames.key(w.text) if not w.vertical and v.xr[0] - 260 < w.cx < v.xr[1] + 260 and v.ytop < w.cy < cy + 25 else None
        if not c_ or c_ in deck_z:
            continue
        hs_ = [u for u in page.words if u is not w and not u.vertical and AB_LABEL.match(u.text) and abs(u.cx - w.cx) < 40
               and 0 < u.cy - w.cy < 20]
        if hs_:
            deck_z[c_] = float(AB_LABEL.match(min(hs_, key=lambda u: u.cy).text).group(1))
            v.evidence.setdefault('deck_named_with_height', []).append(f'{c_} = {deck_z[c_]:g} ("{w.text.strip()}")')
    ests = []
    for w in page.words:
        c = _label_code(w, deck_z)
        if c is None or w.vertical or not (v.xr[0] - 260 < w.cx < v.xr[1] + 260 and v.ytop < w.cy < cy + 25):
            continue
        near = [yy for yy in ys if -4 < w.cy - yy < 16]
        if not near:
            # R-E10: the deck label written ON its leader line (underlined, text just above the deck line): bottom of the text on the line
            near = [yy for yy in ys if -3.0 < yy - w.bbox[3] < 6.0]
            if not near:
                continue
            y = min(near, key=lambda yy: abs(yy - w.bbox[3]))
        else:
            y = min(near, key=lambda yy: abs(w.cy - 8 - yy))
        ests.append((y + deck_z[c] / v.k, c))
    if any(c != 'UPP' for _, c in ests):
        ests = [e for e in ests if e[1] != 'UPP']        # R-E2e: the UPP. DECK is cambered (its height changes with OFF C.L): never the anchor
    lab_codes = {c for _, c in ests}
    ests = [e for e, _ in ests]
    if not ests:
        return False
    def _score(e):          # how many known deck heights have a long line where this calibration predicts it
        return (sum(1 for z in deck_z.values() if any(abs(yy - (e - z / v.k)) < 2.5 for yy in ys)),
                sum(1 for f in ests if abs(f - e) < 2.5))
    best = max(ests, key=_score)
    good = [f for f in ests if abs(f - best) < 2.5]
    yz0 = statistics.median(good)
    v.y_upp = yz0 - 19700.0 / v.k
    for code, z in deck_z.items():
        py = yz0 - z / v.k
        near = [yy for yy in ys if abs(yy - py) < 2.5]
        if near:
            v.decks[code] = float(statistics.median(near))
    # R-E2g: a deck height that no label names is accepted only when its line runs across at least half of the view
    for c_ in list(v.decks):
        if c_ in lab_codes or c_ == 'UPP':
            continue
        yy_ = v.decks[c_]
        iv = sorted((min(s_.a[0], s_.b[0]), max(s_.a[0], s_.b[0])) for s_ in page.segs
                    if s_.horizontal and abs(s_.a[1] - yy_) < 1.6 and v.xr[0] - 20 < max(s_.a[0], s_.b[0]) and min(s_.a[0], s_.b[0]) < v.xr[1] + 20)
        tot, cur = 0.0, None
        for a_, b_ in iv:
            a_, b_ = max(a_, v.xr[0]), min(b_, v.xr[1])
            if b_ <= a_:
                continue
            if cur and a_ <= cur[1]:
                cur[1] = max(cur[1], b_)
            else:
                if cur:
                    tot += cur[1] - cur[0]
                cur = [a_, b_]
        if cur:
            tot += cur[1] - cur[0]
        if tot < 0.5 * (v.xr[1] - v.xr[0]):
            del v.decks[c_]
            v.evidence.setdefault('unnamed_short_line_not_a_deck', []).append(c_)
    # R-E2h: a level NAMED in the view ('NO.3 STR.') whose line is drawn dashed over most of the view (far side) is a member behind
    # the plate (a stringer), not a deck that bounds a tier; it is kept as a named level only
    def _cov(yy_, dashed):
        iv = sorted((max(min(s_.a[0], s_.b[0]), v.xr[0]), min(max(s_.a[0], s_.b[0]), v.xr[1])) for s_ in page.segs
                    if s_.horizontal and abs(s_.a[1] - yy_) < 1.6 and bool(s_.dash) == dashed)
        tot, cur = 0.0, None
        for a_, b_ in iv:
            if b_ <= a_:
                continue
            if cur and a_ <= cur[1]:
                cur[1] = max(cur[1], b_)
            else:
                if cur:
                    tot += cur[1] - cur[0]
                cur = [a_, b_]
        return tot + ((cur[1] - cur[0]) if cur else 0.0)
    for c_ in (list(v.decks) if _MODE >= 1 else []):
        if c_ == 'UPP':
            continue
        sol, das = _cov(v.decks[c_], False), _cov(v.decks[c_], True)
        if das > sol and sol < 0.5 * (v.xr[1] - v.xr[0]):
            v.far_levels = getattr(v, 'far_levels', {})
            v.far_levels[c_] = v.decks.pop(c_)
            v.evidence.setdefault('far_side_levels', []).append(c_)
    # R-E2f: one drawn line is one deck: when two deck heights fall on the same line, the deck NAMED by a label there wins
    for c1 in list(v.decks):
        for c2 in list(v.decks):
            if c1 != c2 and c1 in v.decks and c2 in v.decks and abs(v.decks[c1] - v.decks[c2]) < 1.0:
                drop_ = c2 if (c1 in lab_codes and c2 not in lab_codes) else c1 if (c2 in lab_codes and c1 not in lab_codes) else None
                if drop_:
                    del v.decks[drop_]
    # R-E10b: a deck whose label stands at the predicted height is located even when its line is drawn in a form not read as a line
    # (dash-dot phantom of an opening, a quad outline): the label bottom (leader line) gives its page y
    for w in page.words:
        c = _label_code(w, deck_z)
        if c is None or w.vertical or not (v.xr[0] - 260 < w.cx < v.xr[1] + 260 and v.ytop < w.cy < cy + 25):
            continue
        if c in deck_z and c not in v.decks and c != 'UPP' and c not in getattr(v, 'far_levels', {}) and abs(w.bbox[3] - (yz0 - deck_z[c] / v.k)) < 4.0:
            v.decks[c] = float(yz0 - deck_z[c] / v.k)
            v.evidence.setdefault('decks_from_label_only', []).append(c)
    if 'UPP' not in v.decks:
        # R-E2d: the long line within 12 pt of the nominal UPP. DECK is the UPP deck of this view (its own height is measured: camber)
        py_u = yz0 - deck_z.get('UPP', 19700.0) / v.k
        # (it is the line nearest the prediction that no other deck holds; above OR below the others: an engine room has UPP on top)
        low = [yy for yy in ys if abs(yy - py_u) < 12.0 and (all(abs(yy - y_) > 1.5 for y_ in v.decks.values()) if _MODE >= 1
                                                             else yy > max(v.decks.values(), default=-1e9))]
        if low and v.decks:
            yb = min(low, key=lambda yy: abs(yy - py_u))
            v.decks['UPP'] = float(yb)
            v.zov['UPP'] = deck_z.get('UPP', 19700.0) + (py_u - yb) * v.k
    v.label_decks = {c for c in (_label_code(w, deck_z) for w in page.words
                                 if not w.vertical and v.xr[0] - 260 < w.cx < v.xr[1] + 260 and v.ytop < w.cy < cy + 25) if c in v.decks}
    v.evidence['decks'] = sorted(v.decks)
    v.evidence['deck_calibration'] = f'labels ({len(good)})'
    return len(v.decks) >= 2


def calibrate(page, v, frame_x, scale, deck_z):
    """first reading (rules up to v2.129); when it fails, the second reading adds R-E1c (frame row on top of the view), R-E3g (staggered
    frame row), R-E15b (deck name + height label), R-E2h (far-side levels), R-E23/24 (plated fields) - so a view the first reading
    builds is never changed by them"""
    global _MODE
    keep = (dict(v.decks), dict(v.evidence), dict(v.zov))
    try:
        _MODE = 0
        return _calibrate(page, v, frame_x, scale, deck_z)
    except ValueError as e0:
        if 'uniform grid' in str(e0) or 'OFF C.L' in str(e0) and 'LONGL' in str(e0):
            raise
        v.decks, v.evidence, v.zov = dict(keep[0]), dict(keep[1]), dict(keep[2])
        _MODE = 1
        try:
            r = _calibrate(page, v, frame_x, scale, deck_z)
            v.evidence['second_reading'] = f'first reading failed ({e0}); R-E1c/E3g/E15b/E2h applied'
            return r
        except ValueError:
            raise e0
        finally:
            _MODE = 0


def _calibrate(page, v, frame_x, scale, deck_z):
    """Fill v.k, v.x0, v.y_upp, v.region; raise if the frame row cannot be found."""
    v.k = 25.4 / 72.0 * scale
    t = v.title
    if v.y is None:
        raise ValueError(f'{v.name}: {v.evidence.get("offcl", "OFF C.L unknown")}')
    cands = []
    titles = [w for w in page.words if w.size >= 12 and (TITLE.match(w.text.strip()) or CL_TITLE.match(w.text.strip())
                                                       or re.search(r'(SEC|ELEV|PLAN|VIEW|DET)\.?\s*(\([PS]\))?\s*$', w.text.strip()))]

    def _owner(g, cy):
        # R-E13: a frame row belongs to the nearest view title above it (a neighbouring view's row is never taken)
        gx = (g[0].cx + g[-1].cx) / 2
        above = [u for u in titles if u.bbox[3] + (15 if _MODE >= 1 else 40) < cy < u.bbox[3] + 1300 and g[0].cx - 260 < u.cx < g[-1].cx + 400]
        return min(above, key=lambda u: (cy - u.bbox[3]) + 2.0 * abs(u.cx - gx), default=None)

    for mr in (MIN_ROW, 2):              # R-E13b: a small view may print only two frame numbers; used only when no longer row is its own
        for g in _digit_rows(page, mr):
            cy = statistics.median(w.cy for w in g)
            xmin, xmax = g[0].cx, g[-1].cx
            if t.bbox[3] + (15 if _MODE >= 1 else 40) < cy < t.bbox[3] + 1300 and xmin - 160 < t.cx < xmax + 400 and _owner(g, cy) is t:   # R-E1c: a row on top of the view sits ~40 pt under the title
                if len(g) == 2 and _fnum(g[1]) - _fnum(g[0]) != 1:
                    continue
                cands.append((cy, abs(t.cx - (xmin + xmax) / 2), g, 'below'))
        if cands:
            if mr == 2:
                v.evidence['frame_row'] = 'two-label row (small view)'
            break
    if not cands:
        for g in _digit_rows(page):
            cy = statistics.median(w.cy for w in g)
            xmin, xmax = g[0].cx, g[-1].cx
            if t.bbox[3] + 150 < cy < t.bbox[3] + 1300 and xmin - 160 < t.cx < xmax + 400:
                cands.append((cy, abs(t.cx - (xmin + xmax) / 2), g, 'below'))
    if not cands:                                    # R-E1b: title printed UNDER the view -> frame row above the title
        for g in _digit_rows(page):
            cy = statistics.median(w.cy for w in g)
            xmin, xmax = g[0].cx, g[-1].cx
            if t.bbox[1] - 400 < cy < t.bbox[1] - 20 and xmin - 260 < t.cx < xmax + 400:
                cands.append((cy, abs(t.cx - (xmin + xmax) / 2), g, 'above'))
    if not cands:
        raise ValueError(f'{v.name}: no frame-number row below the view')
    if len(cands) > 1:
        # R-E3h: a row of dimension numbers ('600 600 700 800' printed in an elevation) is not the frame row. When the topmost row does not
        # sit on the drawing's frame function (> 130 mm) and another row of the view does, only the rows that fit are candidates.
        def _res(g_):
            try:
                e_ = [w.cx - frame_x(_fnum(w)) / v.k for w in g_]
                x_ = statistics.median(e_)
                return max(abs(a - x_) for a in e_) * v.k
            except Exception:
                return 1e9
        _top = min(cands, key=lambda c: c[0])
        if _res(_top[2]) > 130:
            _fit_ok = [c for c in cands if _res(c[2]) <= 130]
            if _fit_ok:
                cands = _fit_ok
                v.evidence['frame_row_filter'] = 'R-E3h: the topmost number row does not fit the frame function (dimension numbers); the row that does is used'
    cands.sort(key=lambda c: (c[0] // 60, c[1]))
    where = cands[0][3]
    cy, _, g, where = (min(cands, key=lambda c: c[0]) if where == 'below' else max(cands, key=lambda c: c[0]))
    v.ytop = t.bbox[3] if where == 'below' else cy - 700.0
    if where == 'below':
        # R-E17: a tall view prints its frame row more than once (a reference row half way down): the view runs down to the LAST row
        # of the same labels under it that no other title claims; deck lines are searched down to that row
        for g2 in _digit_rows(page):
            cy2 = statistics.median(w.cy for w in g2)
            if cy2 > cy + 60 and abs(g2[0].cx - g[0].cx) < 5 and _fnum(g2[0]) == _fnum(g[0]) and _owner(g2, cy2) is t:
                if not any(u is not t and cy < u.cy < cy2 and g[0].cx - 260 < u.cx < g[-1].cx + 260 for u in titles):
                    v.evidence['frame_rows'] = f'rows at y {cy:.0f} and {cy2:.0f} (tall view)'
                    cy = max(cy, cy2)
    v.row_cy = cy
    def _fit(k):
        e = [w.cx - frame_x(_fnum(w)) / k for w in g]
        x0 = statistics.median(e)
        return x0, max(abs(a - x0) for a in e) * k
    def _inliers(k):                 # R-E3d: largest group of labels that sit on one uniform grid (others = irregular frames)
        e = [w.cx - frame_x(_fnum(w)) / k for w in g]
        best = max(e, key=lambda a: sum(1 for b in e if abs(a - b) * k < 60))
        keep = [i for i, b in enumerate(e) if abs(best - b) * k < 60]
        return keep, statistics.median([e[i] for i in keep])
    gfull = g
    anch = getattr(frame_x, 'anchor', None)       # R-F2: start point given by the owner -> positions MEASURED from the row
    hit = [w for w in g if anch and _fnum(w) == anch[0]]
    if hit:
        v.x0 = hit[0].cx - anch[1] / v.k
        v.evidence['frame_source'] = f'row measured, anchored on FR.{anch[0]} = {anch[1]:g} (owner start point)'
        res = 0.0
    else:
        v.x0, res = _fit(v.k)
    if res > 130 and len(g) >= 3:    # R-E3c: the view may be drawn at another scale; test the standard scales on the frame row (never from 2 labels)
        best = min(((_fit(25.4 / 72.0 * sc)[1], sc) for sc in (25, 30, 40, 50, 60, 75, 100, 120, 125, 150, 200, 250, 300)))
        if best[0] < 60:
            v.k = 25.4 / 72.0 * best[1]
            v.x0, res = _fit(v.k)
            v.evidence['scale_from_frame_row'] = best[1]
    if res > 130:                    # R-E3f (same as plans R-V7): anchor on the first label pair that is exactly one frame apart
        sp_e = frame_x(1) - frame_x(0)
        for a, b in zip(g, g[1:]):
            na, nb = _fnum(a), _fnum(b)
            if nb > na and abs((b.cx - a.cx) * v.k / (nb - na) - sp_e) < 0.08 * sp_e:
                v.x0 = a.cx - frame_x(na) / v.k
                res = 0.0
                v.evidence['frame_labels_used'] = f'anchored on the bay FR.{na}-{nb} (irregular frame spacing elsewhere in the row; frame table needed to confirm)'
                break
    if res > 130:
        keep, x0 = _inliers(v.k)
        if len(keep) >= max(MIN_ROW, 3) and len(keep) >= 0.5 * len(g):
            v.x0, res = x0, 0.0
            v.evidence['frame_labels_used'] = f'{len(keep)}/{len(g)} (irregular frame spacing: frame table needed for the rest)'
            g = [g[i] for i in keep]
    if res > 130:
        # R-E16: 'FRAME SPACE : n (EXC. AS SHOWN)' - the row shows irregular bays that no written value gives: the view keeps the sheet
        # scale and is anchored on its LOWEST frame label (X from the one frame function of the drawing, R-XV1); the other labels are
        # irregular bays -> owner question (frame table)
        lo_w = min(g, key=_fnum)
        v.x0 = lo_w.cx - frame_x(_fnum(lo_w)) / v.k
        irr = ', '.join(f'FR.{_fnum(a)}-{_fnum(b)} = {(b.cx - a.cx) * v.k:.0f} mm' for a, b in zip(g, g[1:]))
        v.evidence['frame_labels_used'] = f'anchored on FR.{_fnum(lo_w)} (irregular bays measured: {irr}; not written - frame table needed)'
        v.evidence['ask'] = f'{v.name}: irregular frame bays {irr} - give the frame table (X of each frame)'
        res = 0.0
    v.evidence['frame_residual_mm'] = round(res, 1)
    if res > 130:     # label-centre jitter of one- vs two-digit numbers stays below ~100 mm
        raise ValueError(f'{v.name}: frame labels do not fit a uniform grid ({res:.0f} mm)')
    # R-E27 (1001): the label of a frame number is text, the short vertical TICK of the row is the drawn frame position (plans R-V27). When
    # >= 3 labels of the row have a tick of the same row within a quarter bay and the offsets agree within 1 pt, x0 follows the ticks and the
    # wall-line alignment (refine_x0, a 900 mm grid guess) is not applied.
    try:
        sp_t = frame_x(1) - frame_x(0)
        qb = 0.25 * abs(sp_t) / v.k
        tres = []
        for w in g:
            px = v.x0 + frame_x(_fnum(w)) / v.k
            if abs(w.cx - px) > qb:
                continue
            tk = [q.a[0] for q in page.segs if q.vertical and not q.dash and q.length < 15 and abs(q.a[0] - px) < qb
                  and abs((q.a[1] + q.b[1]) / 2 - w.cy) < 15]
            if tk:
                tres.append(min(tk, key=lambda x_: abs(x_ - w.cx)) - px)
        if len(tres) >= 3 and max(tres) - min(tres) < 1.0:
            v.x0 += statistics.median(tres)
            v.evidence['frame_ticks'] = f'R-E27: x0 from {len(tres)} frame ticks of the number row ({statistics.median(tres) * v.k:+.0f} mm)'
    except Exception:
        pass
    v.xr = (gfull[0].cx - 40, gfull[-1].cx + 40)
    v.frame_cy = cy
    v.mode = _MODE
    if where == 'below' and _MODE >= 1:
        # R-E1c: the frame-number row may be printed ON TOP of the view, just under the title (deck lines and deck labels below it).
        # Seen when no long line lies between the title and the row but deck labels stand below the row: the view then runs
        # from the row down to the next title of the same column (or the sheet border)
        _between = [s_ for s_ in page.segs if s_.horizontal and not s_.dash and s_.length > 0.5 * (v.xr[1] - v.xr[0])
                    and v.xr[0] - 20 < min(s_.a[0], s_.b[0]) and max(s_.a[0], s_.b[0]) < v.xr[1] + 220 and t.bbox[3] < s_.a[1] < cy - 8]
        _below_t = [u.bbox[1] for u in titles if u is not t and u.bbox[1] > cy and v.xr[0] < u.cx < v.xr[1]]
        _ybot = min(_below_t, default=page.rect[3] - 30) - 10
        _labs = [w for w in page.words if not w.vertical and _label_code(w, dict(deck_z)) and v.xr[0] - 260 < w.cx < v.xr[1] + 260
                 and cy + 20 < w.cy < _ybot]
        if not _between and len(_labs) >= 2 and cy - t.bbox[3] < 120:      # the row stands right under the title
            v.ytop = cy - 6
            cy = _ybot
            v.row_cy = cy
            v.evidence['frame_row'] = f'printed on top of the view (R-E1c); view runs down to y {cy:.0f}'
    # deck lines: long horizontals between the title and the frame row
    hs = [s for s in page.segs if s.horizontal and s.length > 45 and not s.dash
          and v.xr[0] - 20 < s.a[0] < v.xr[1] + 220 and v.ytop < s.a[1] < cy]
    ys = sorted({round((s.a[1] + s.b[1]) / 2, 0) for s in hs})
    # R-E11: a deck line drawn in pieces (cut by an opening, broken 'cut' line) is one deck line when its collinear pieces
    # (gaps <= 15 pt) add up to a long line inside the view
    _rows = defaultdict(list)
    for s_ in page.segs:
        if s_.horizontal and not s_.dash and s_.length > 2 and v.xr[0] - 20 < min(s_.a[0], s_.b[0]) and max(s_.a[0], s_.b[0]) < v.xr[1] + 220 \
                and v.ytop < s_.a[1] < cy:
            _rows[round(s_.a[1])].append((min(s_.a[0], s_.b[0]), max(s_.a[0], s_.b[0])))
    for yk, iv in _rows.items():
        if any(abs(yk - yy) < 1.5 for yy in ys):
            continue
        iv.sort()
        best_run, cur, tot = 0.0, None, 0.0
        for a_, b_ in iv:
            if cur is None or a_ > cur[1] + 15:
                cur = [a_, b_]
                tot = b_ - a_
            else:
                tot += max(0.0, b_ - max(a_, cur[1]))
                cur[1] = max(cur[1], b_)
            if cur[1] - cur[0] > 0.5 * (v.xr[1] - v.xr[0]) and tot > 0.5 * (cur[1] - cur[0]):
                best_run = max(best_run, cur[1] - cur[0])
        if best_run:
            ys.append(float(yk))
    ys = sorted(ys)
    _dz = dict(deck_z)                     # R-E15: a height-named deck ('33080 A/B') is local to the view that names it
    _ok = _decks_from_labels(page, v, ys, _dz, cy)
    v.local_z = {k_: z_ for k_, z_ in _dz.items() if k_ not in deck_z}
    if _ok:
        return v
    v.decks = {k_: y_ for k_, y_ in v.decks.items() if k_ in deck_z}
    # UPP. DECK line: the lowest long line above the frame row, within 60 pt
    upp = [y for y in ys if cy - 60 < y < cy - 15]
    if not upp:
        _named = {c for c in (_label_code(w, dict(deck_z)) for w in page.words
                              if not w.vertical and v.xr[0] - 260 < w.cx < v.xr[1] + 260 and v.ytop < w.cy < cy + 25) if c}
        if len(_named) < 2:
            # R-E21: a view naming fewer than two decks (detail of one deck edge) has no deck-to-deck tier: nothing to build, reported
            raise ValueError(f'{v.name}: only {len(_named)} deck named in the view ({", ".join(sorted(_named)) or "none"}) - a detail of a deck edge, no deck-to-deck wall to build')
        raise ValueError(f'{v.name}: UPP. DECK line not found')
    # R-E2b: several candidates (stray lines) -> keep the one whose predicted deck lines exist most often
    def _score(yu):
        return sum(1 for c in DECK_ORDER if c != 'UPP' and c in deck_z and any(abs(yy - (yu - (deck_z[c] - 19700.0) / v.k)) < 2.5 for yy in ys))
    v.y_upp = max(upp, key=lambda yu: (_score(yu), yu))
    # which deck lines exist (match predicted y within 2.5 pt)
    for code in DECK_ORDER:
        if code not in deck_z:
            continue
        z = deck_z[code]
        y = v.py(z)
        near = [yy for yy in ys if abs(yy - y) < 2.5]
        if near:
            v.decks[code] = float(statistics.median(near))
    v.evidence['decks'] = sorted(v.decks)
    return v


# ---------------------------------------------------------------- verticals
def _merge_vertical(segs, tol_x=0.7, gap=1.5):
    byx = []
    for s in sorted(segs, key=lambda s: (s.a[0] + s.b[0]) / 2):
        x = (s.a[0] + s.b[0]) / 2
        if byx and abs(byx[-1]['x'] - x) < tol_x:
            byx[-1]['items'].append(s)
            byx[-1]['x'] = statistics.mean((byx[-1]['x'], x))
        else:
            byx.append({'x': x, 'items': [s]})
    out = []
    for g in byx:
        ivs = sorted((min(s.a[1], s.b[1]), max(s.a[1], s.b[1]), s.width) for s in g['items'])
        cur = list(ivs[0])
        for y0, y1, w in ivs[1:]:
            if y0 <= cur[1] + gap:
                cur[1] = max(cur[1], y1)
                cur[2] = max(cur[2], w)
            else:
                out.append((g['x'], cur[0], cur[1], cur[2]))
                cur = [y0, y1, w]
        out.append((g['x'], cur[0], cur[1], cur[2]))
    return out


BRK_CALLOUT = re.compile(r'^(\d{2,3})\s*X\s*(\d{1,2}(?:\.\d)?)$')


_CALLOUT_CACHE = {}
BKT_TABLE = {}      # R-B6 / R-B11: bracket marks -> (leg, t), read from the drawing (sheet note row or DET. OF BRACKET table) - no built-in values


def load_bracket_marks(pdf):
    """R-B11: the DET. OF BRACKET table of this drawing or of any same-hull drawing in its folder"""
    from . import bkttable
    extra = os.environ.get('DECKRULES_DRAWING_FOLDERS', '')
    bkttable.EXTRA_FOLDERS[:] = [f for f in extra.split(os.pathsep) if f]
    tab = bkttable.table(pdf)
    for k, v in tab.items():
        BKT_TABLE.setdefault(k, (v['leg'], v['t']))
    return tab
_MARK = re.compile(r'^B\d{2}$')


def parse_bkt_table(page):
    """R-B6: sheet note 6 'TYPICAL STIFFENER SIZE': mark (B25) with its 'AxT' on the same row -> BKT_TABLE"""
    for w in page.words:
        t = w.text.strip()
        if _MARK.match(t) and not w.vertical:
            for c in page.words:
                m = BRK_CALLOUT.match(c.text.strip())
                if m and abs(c.cy - w.cy) < 4 and 0 < c.cx - w.cx < 90:
                    BKT_TABLE[t] = (float(m.group(1)), float(m.group(2)))
                    break


def frame_sizes(page):
    """R-B6: {frame number: Counter{(W,T): n}} of the bracket callouts drawn in the elevations / sections of the page.
    The frame number = nearest plain number printed above/below the leader tip (same column)."""
    from collections import Counter
    nums = [w for w in page.words if re.fullmatch(r'\d{1,3}', w.text.strip()) and not w.vertical]
    out = {}
    for c, tip, W, T in callout_tips(page):
        best = None
        for n in nums:
            dx, dy = abs(n.cx - tip[0]), abs(n.cy - tip[1])
            if dx < 9 and dy < 70 and (best is None or dy < best[0]):
                best = (dy, int(n.text))
        if best:
            out.setdefault(best[1], Counter())[(W, T)] += 1
    return out


def callout_tips(page):
    """[(word, tip_xy, W, T)] of the bracket callouts of a page; tip = far end of the leader that starts at the text (R-LD)"""
    key = id(page)
    if key not in _CALLOUT_CACHE:
        from .deckplan import leader_tip
        out = []
        parse_bkt_table(page)
        for c in page.words:
            t0 = c.text.strip()
            if _MARK.match(t0) and t0 in BKT_TABLE and not c.vertical:      # R-B6: 'B25' mark callout
                tip = leader_tip(c, page.segs)
                if tip:
                    out.append((c, tip, BKT_TABLE[t0][0], BKT_TABLE[t0][1]))
                continue
            m = BRK_CALLOUT.match(c.text.strip())
            if m and 100 <= int(m.group(1)) <= 400 and 6 <= float(m.group(2)) <= 16 and not c.vertical:
                tip = leader_tip(c, page.segs) or (c.cx, c.cy)
                out.append((c, tip, float(m.group(1)), float(m.group(2))))
        _CALLOUT_CACHE.clear()
        _CALLOUT_CACHE[key] = out
    return _CALLOUT_CACHE[key]


def callout_near(page, w, maxd=45.0):
    """R-B3: bracket callout 'WxT' (200X8.0, 150X8.0, 300X10.0 ...) whose leader tip is nearest to the B mark word w: (W, T) or None"""
    best = None
    for c, tip, W, T in callout_tips(page):
        d = min(math.hypot(tip[0] - w.cx, tip[1] - w.cy), math.hypot(c.cx - w.cx, c.cy - w.cy))
        if d < maxd and (best is None or d < best[0]):
            best = (d, (W, T))
    return best[1] if best else None


def _bmark_ends(page, l):
    """R-B1: printed 'B' within 14 pt of a stiffener end = bracket connection at that end ('lo' = lower end, 'hi' = upper)"""
    out = {'lo': False, 'hi': False}
    for w in page.words:
        if w.text.strip() == 'B' and w.size < 12 and not w.vertical and abs(w.cx - l['x']) < 14:
            if abs(w.cy - l['y1']) < 14:
                out['lo'] = True
                out['size_lo'] = callout_near(page, w)
            elif abs(w.cy - l['y0']) < 14:
                out['hi'] = True
                out['size_hi'] = callout_near(page, w)
    return out


def _dash_frac(segs, x, y0, y1):
    """share of the line length (at x, from y0 to y1) that is drawn dashed. Dashed = member on the FAR side of the plate
    (R-E8b, owner rule 'visibility': near side opposite the viewing direction, far side along it)."""
    tot = dsh = 0.0
    for s in segs:
        if abs((s.a[0] + s.b[0]) / 2 - x) < 0.8:
            lo, hi = min(s.a[1], s.b[1]), max(s.a[1], s.b[1])
            ov = max(0.0, min(hi, y1) - max(lo, y0))
            tot += ov
            if s.dash:
                dsh += ov
    return dsh / tot if tot else 0.0


def _marker_count(small, x, y0, y1):
    n = 0
    for s in small:
        mx = (s.a[0] + s.b[0]) / 2
        my = (s.a[1] + s.b[1]) / 2
        if abs(mx - x) < 4.5 and (abs(my - y0) < 6 or abs(my - y1) < 6):
            n += 1
    return n


def _tri_ends(small, x, y0, y1):
    """R-E20: number of line ends (0..2) carrying a stiffener end-triangle: a short steep side (|dx| 1.5..3.5 pt, |dy| > 1.4 |dx|)
    with its apex ON the line within 10 pt of the end (a bracket hypotenuse is ~45 deg and does not qualify)"""
    n = 0
    for ye in (y0, y1):
        hit = False
        for s in small:
            dx, dy = abs(s.a[0] - s.b[0]), abs(s.a[1] - s.b[1])
            if not (1.5 <= dx <= 3.5 and dy > 1.4 * dx):
                continue
            for pa, pb in ((s.a, s.b), (s.b, s.a)):
                if abs(pa[0] - x) < 1.2 and abs(pa[1] - ye) < 10 and abs(pb[1] - ye) < 12:
                    hit = True
        n += hit
    return n


STIFF_MARKERS = 8        # R-E3: a line with >= 20 arrow/triangle strokes at its ends is a stiffener
GAP_BREAK_PT = 55.0       # a wider hole between lines separates two walls
DEFAULT_ANGLE = {100: (75, 7, 7), 125: (75, 7, 7), 150: (90, 9, 9), 200: (90, 10, 14),
                 250: (90, 10, 15), 300: (90, 11, 16)}


def _tiers(v, deck_z=None):
    deck_z = deck_z or {}
    codes = sorted(v.decks, key=lambda c: deck_z.get(c, DECK_ORDER.index(c) if c in DECK_ORDER else 99))
    out = []
    for lo, hi in zip(codes, codes[1:]):
        if deck_z:
            if 1200 < deck_z[hi] - deck_z[lo] < 5500:
                out.append((lo, hi, v.decks[lo], v.decks[hi]))
            elif 1200 < deck_z[hi] - deck_z[lo] < (15000 if getattr(v, 'mode', 0) >= 1 else 9000) and getattr(v, 'label_decks', None) and lo in v.label_decks and hi in v.label_decks:
                # R-E14: two decks both NAMED in the view with no deck drawn between them form one tier (the wall runs deck to deck)
                out.append((lo, hi, v.decks[lo], v.decks[hi]))
        elif c_adj(lo, hi):
            out.append((lo, hi, v.decks[lo], v.decks[hi]))        # page y: lo is the lower deck (larger y)
    return out


def c_adj(lo, hi):
    return lo in DECK_ORDER and hi in DECK_ORDER and DECK_ORDER.index(hi) - DECK_ORDER.index(lo) == 1


def _resolve_short(h, kind, notes_sec, aliases, sheet):
    key = f'{h} {kind}'
    for k, val in (aliases or {}).items():
        if ' '.join(k.split()) == key:
            return tuple(val), 'alias table'
    if notes_sec and notes_sec[0] == 'L' and notes_sec[1] == h:
        return notes_sec, 'title default'
    full = sheet.get((h, kind))
    if full and len(full) == 1:
        return next(iter(full)), 'sheet printed size'
    if h in DEFAULT_ANGLE and kind in ('U.A', 'I.A'):
        w, a, b = DEFAULT_ANGLE[h]
        return ('L', h, w, float(a), float(b)), 'ASSUMED standard size (confirm)'
    return None, 'unresolved'


def _label_for(words, x, y0, y1):
    best = None
    for w in words:
        if not w.vertical:
            continue
        if abs(w.cx - x) < (22 if '(T)' in w.text else 9) and y0 - 3 < w.cy < y1 + 3 and members.SEC.search(w.text):
            d = abs(w.cx - x)
            if best is None or d < best[0]:
                best = (d, w)
    return best[1] if best else None


def refine_x0(v, xs, spacing=800.0):
    """digit text centres are a little off the frame lines: shift x0 so that the wall lines sit on frames."""
    if v.evidence.get('frame_ticks'):
        v.evidence['x0_shift_pt'] = 0.0
        return
    best = (0, 0.0)
    for sh in [i / 10 for i in range(-25, 26)]:          # R-E19: only label-centre jitter (<= 2.5 pt); edge-on walls sit a stiffener depth off the frame
        n = sum(1 for x in xs if abs((((x - (v.x0 + sh)) * v.k) / spacing * 2) % 1 - 0.0) < 0.03
                or abs((((x - (v.x0 + sh)) * v.k) / spacing * 2) % 1 - 1.0) < 0.03)
        if n > best[0]:
            best = (n, sh)
    if best[0] >= 3:
        v.x0 += best[1]
    v.evidence['x0_shift_pt'] = best[1]
    v.evidence['x0_aligned_lines'] = best[0]


def _snap(val, grid, tol):
    g = round(val / grid) * grid
    return g if abs(g - val) <= tol else val


def extract(page, v, deck_z, settings, sheet=None):
    deck_z = {**deck_z, **getattr(v, 'local_z', {})}
    sheet = sheet if sheet is not None else members.sheet_sizes(page)
    aliases = settings.get('section_aliases', {})
    notes_sec = members.parse_section(v.notes.get('stiff', '')) if v.notes.get('stiff') else None
    default_t = float(v.notes['plate']) if v.notes.get('plate') else None
    small_all = [s for s in page.segs if s.length < 9 and v.xr[0] - 10 < s.a[0] < v.xr[1] + 10
                 and v.ytop < s.a[1] < v.row_cy]
    tiers = _tiers(v, deck_z)
    view_t = Counter(float(_thk(w, page.words).group(1)) for w in page.words
                     if _thk(w, page.words) and not w.vertical and v.xr[0] < w.cx < v.xr[1] and v.ytop < w.cy < v.row_cy)
    walls = []
    # first pass: gather full-height lines of every tier, refine x0
    gathered = {}
    allx = []
    for lo, hi, yb, yt in tiers:
        H = yb - yt
        vs = [s for s in page.segs if s.vertical and s.length > 1.0
              and v.xr[0] - 10 < s.a[0] < v.xr[1] + 10 and yt - 14 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < yb + 14]
        # R-E8: a wall/stiffener line drawn continuously through several tiers is cut at this tier's limits
        for s in page.segs:
            if s.vertical and s.length > 1.0 and v.xr[0] - 10 < s.a[0] < v.xr[1] + 10:
                y0_, y1_ = min(s.a[1], s.b[1]), max(s.a[1], s.b[1])
                if (y0_ < yt - 14 or y1_ > yb + 14) and y0_ < yb - 0.5 * H and y1_ > yt + 0.5 * H:
                    c = copy.copy(s)
                    c.a, c.b = (s.a[0], max(y0_, yt)), (s.b[0], min(y1_, yb))
                    vs.append(c)
        lines = []
        for x, y0, y1, w in _merge_vertical(vs, gap=7.0):
            if y1 - y0 < 0.85 * H or y0 > yt + 0.15 * H or y1 < yb - 0.15 * H:
                continue
            if _sw_mark(page.words, x, y0, y1):
                continue             # R2.13: an 'S.W' line in a wall view is ANOTHER wall meeting this one - never a stiffener
            _m = _marker_count(small_all, x, y0, y1)
            if _m < STIFF_MARKERS and _tri_ends(small_all, x, y0, y1) == 2:
                _m = STIFF_MARKERS            # R-E20: end triangles at both ends = stiffener, whatever the stroke count
            lines.append({'x': x, 'y0': y0, 'y1': y1, 'w': w, 'm': _m, 'dash': _dash_frac(vs, x, y0, y1)})
        gathered[(lo, hi)] = lines
        if os.environ.get('WDBG'):
            print('WDBG', v.name, lo, hi, 'H', round(H), [(round(l['x']), l['m']) for l in lines])
        allx += [l['x'] for l in lines]
    if allx:
        refine_x0(v, allx, settings.get('frame_spacing_mm', 800) or 800)
    for lo, hi, yb, yt in tiers:
        lines = sorted(gathered[(lo, hi)], key=lambda l: l['x'])
        H = yb - yt
        clusters, cur = [], []
        for l in lines:
            if cur and l['x'] - cur[-1]['x'] > GAP_BREAK_PT:
                clusters.append(cur)
                cur = []
            cur.append(l)
        if cur:
            clusters.append(cur)
        # R-E9: a wall drawn as its two end edges, each with a labelled stiffener on the inside ('200 I.A' beside the inner line),
        # is ONE wall plate between the outer edges (the labelled inner lines are its stiffeners)
        mg = []
        for c in clusters:
            _la = _label_for(page.words, mg[-1][-1]['x'], mg[-1][-1]['y0'], mg[-1][-1]['y1']) if mg else None
            _lb = _label_for(page.words, c[0]['x'], c[0]['y0'], c[0]['y1'])
            if mg and len(mg[-1]) <= 3 and len(c) <= 3 and len(mg[-1]) >= 2 and len(c) >= 2 and _la and _lb \
                    and '+' not in _la.text and '+' not in _lb.text:      # R-E9c: a T-web label ('450X12+150X15 F.B(T)') = web frame edge-on, not a wall
                mg[-1] = mg[-1] + c
            else:
                mg.append(c)
        clusters = mg
        for cl in clusters:
            xL, xR = cl[0]['x'], cl[-1]['x']
            if sum(1 for l in cl if l['m'] >= STIFF_MARKERS) < 2:
                # R-W5 (owner Q1): a wall without marked stiffeners is still a plate when a thickness is printed in it
                if not settings.get('wall_thickness_only', True) or len(cl) < 2 or xR - xL < 14:
                    continue
                has_t = False
                for w in page.words:
                    m = _thk(w, page.words)
                    if m and xL < w.cx < xR and yt < w.cy < yb and not w.vertical:
                        tab = [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < u.cy - w.cy < 14
                               and re.search(r'FL\.|F\.B', u.text)]
                        tab += [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < w.cy - u.cy < 14
                                and re.search(r'\bPAD\b|DOUBL|INSERT|COLLAR', u.text)]       # R-E18: 'PAD / 10.0' = pad plate, not the wall
                        if not tab:
                            has_t = True
                            break
                if not has_t:
                    continue
            # partial stiffeners (cut by an opening) inside the wall
            part = []
            for x, y0, y1, w in _merge_vertical([s for s in page.segs if s.vertical and s.length > 1.0
                                                 and xL < s.a[0] < xR and yt - 6 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < yb + 14]):
                if (y1 - y0) >= 0.25 * H and not any(abs(x - l['x']) < 1.0 for l in cl) \
                        and _marker_count(small_all, x, y0, y1) >= STIFF_MARKERS:
                    part.append({'x': x, 'y0': y0, 'y1': y1, 'w': w, 'm': 99, 'partial': True, 'dash': 0.0})
            Zb, Zt = v.zov.get(lo, deck_z[lo]), v.zov.get(hi, deck_z[hi])
            U0 = _snap(v.X(xL), 400.0, 40.0)
            U1 = _snap(v.X(xR), 400.0, 40.0)
            # thickness
            ts = []
            ahs = set()
            for w in page.words:
                m = _thk(w, page.words)
                if m and xL < w.cx < xR and yt < w.cy < yb and not w.vertical:
                    tab = [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < u.cy - w.cy < 14
                           and re.search(r'FL\.|F\.B', u.text)]
                    tab += [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < w.cy - u.cy < 14
                            and re.search(r'\bPAD\b|DOUBL|INSERT|COLLAR', u.text)]       # R-E18
                    if not tab:
                        ts.append(float(m.group(1)))
                        if m.group(2):
                            ahs.add(float(m.group(1)))
            if ts:
                t = Counter(ts).most_common(1)[0][0]
                tsrc = 'note inside wall'
                if default_t is not None and t >= 1.6 * default_t and ts.count(t) < 2 and view_t[t] < 2:
                    # R-W6: one single note far above the title thickness (25.0 under a 7.0 title) and printed nowhere else in the view is a local thick strip / insert, not the wall plate
                    t, tsrc = default_t, 'title default (single local note %.1f ignored)' % t
            else:
                t, tsrc = default_t, 'title default'
            st = []
            for l in cl[1:-1] + part:
                lab = _label_for(page.words, l['x'], l['y0'], l['y1'])
                if l['m'] < STIFF_MARKERS and not (lab and members.SEC.search(lab.text) and (l.get('dash', 0) > 0.5 or l['m'] >= 1)):
                    continue      # R-E7: an inner line (dashed = far side) with a vertical size label ('200 I.A') beside it is a stiffener even without end markers
                if lab:
                    mm = members.SEC.search(lab.text)
                    sec = members.parse_section(lab.text, aliases)
                    src = 'label ' + lab.text.strip()
                    if sec is None and mm:
                        sec, src2 = _resolve_short(int(mm.group('h')), mm.group('k'), notes_sec, aliases, sheet)
                        src += ' -> ' + src2
                else:
                    sec, src = notes_sec, 'title default'
                if l['m'] < STIFF_MARKERS:
                    src += ' (R-E7: labelled line, no end markers)'
                if l.get('partial'):
                    a_z = max(Zb, min(Zt, v.Z(l['y1'])))
                    b_z = max(Zb, min(Zt, v.Z(l['y0'])))
                    if abs(b_z - a_z) < 300:
                        continue
                else:
                    a_z, b_z = Zb, Zt
                st.append({'x': _snap(v.X(l['x']), 400.0, 40.0), 'a_z': a_z, 'b_z': b_z, 'section': sec, 'far': l.get('dash', 0) > 0.5, 'bmark': _bmark_ends(page, l),
                           'evidence': src + (' (partial)' if l.get('partial') else '')})
            # openings: closed thin rings inside the wall
            holes = []
            rings = [s for s in page.segs if xL < s.a[0] < xR and yt < s.a[1] < yb and xL < s.b[0] < xR and yt < s.b[1] < yb
                     and not s.dash]
            tw = thin_weight(rings)
            for _, poly in closed_paths(rings, max_width=tw * 1.5 if tw else None):
                a_mm = poly.area * v.k * v.k
                if not (0.05e6 < a_mm < 0.5 * (U1 - U0) * (Zt - Zb)):
                    continue
                from .deckplan import _circular
                if _circular(poly) or _rounded(poly):
                    pts = [(_snap(v.X(x), 100.0, 15.0), _snap(v.Z(y), 100.0, 15.0)) for x, y in list(poly.exterior.coords)[:-1]]
                    holes.append(pts)
                elif _door_label(page.words, poly):
                    # R2.17: a closed outline holding a printed door size 'AxB' / 'AxBxR' is a DOOR opening (hole of the wall)
                    pts = [(_snap(v.X(x), 100.0, 15.0), _snap(v.Z(y), 100.0, 15.0)) for x, y in list(poly.exterior.coords)[:-1]]
                    holes.append(pts)
            st = _clip_at_doors(st, holes)       # R4.11: a stiffener crossing a door starts at the door top
            _box_ = (xL, xR, yt, yb)
            _hc = _wall_carlings(page, v, _box_, st, settings)                  # R2.18
            _hc += _portal_bars(page, v, _box_, holes, (U0, U1), (Zb, Zt))    # R2.19
            _cb = _corner_brackets(page, v, _box_, (U0, U1), (Zb, Zt))         # R4.14
            walls.append({'name': f"{v.name}|{lo}-{hi}|{len(walls) + 1}", 'y': v.y, 'tier': (lo, hi),
                          'poly': [(U0, Zb), (U1, Zb), (U1, Zt), (U0, Zt)], 't': t, 't_source': tsrc, 'grade': 'AH' if t in ahs else 'A',
                          'stiffeners': st, 'openings': holes, 'hcarl': _hc, 'corner_brackets': _cb})
    # R-E23/E24/E25: plated fields of a plated bulkhead elevation and their horizontal longitudinals
    if settings.get('plated_fields', True) and getattr(v, 'mode', 0) >= 1:
        # R-E23b: a stringer ('NO.n STR.') is a member ON the plate, not a plate boundary: plated fields run deck to deck
        _ft, _fg = _deck_tiers(page, v, deck_z, small_all)
        _plated_fields(page, v, _ft, _fg, deck_z, notes_sec, aliases, sheet, walls)
    # R-SL: wall with a slanted edge
    walls += _slanted_walls(page, v, deck_z, small_all, default_t, notes_sec, aliases, sheet, walls)
    # R-PI: pipes ('150A SCH80'): the narrow double line is a pillar, not a wall plate
    from . import pipes as _pipes
    pp_ = _pipes.find(page, v, (v.xr[0], v.ytop, v.xr[1], v.row_cy))
    if pp_:
        recs = []
        for q in pp_:
            X = v.X(q['px'])
            z_hi, z_lo = v.Z(q['y0']), v.Z(q['y1'])
            recs.append({'x': X, 'z0': min(z_lo, z_hi), 'z1': max(z_lo, z_hi), 'nominal': q['nominal'], 'sch': q['sch'], 'label': q['label']})
        walls[:] = [w_ for w_ in walls if not (any(abs(r['x'] - w_['poly'][0][0]) < 300 or w_['poly'][0][0] - 300 < r['x'] < w_['poly'][1][0] + 300 for r in recs)
                                                and (w_['poly'][1][0] - w_['poly'][0][0]) < 350 and not w_['stiffeners'])]
        for r in recs:
            host = next((w_ for w_ in walls if w_['poly'][0][0] - 50 <= r['x'] <= w_['poly'][1][0] + 50 and w_['poly'][0][1] - 50 <= r['z0'] + 1 and r['z1'] <= w_['poly'][2][1] + 50), None)
            if host is None:                                  # pipe with no wall behind it: a host panel without plate
                tier = next(((lo, hi) for lo, hi, yb, yt in tiers if deck_z[lo] - 60 <= r['z0'] and r['z1'] <= deck_z[hi] + 60), tiers[0][:2] if tiers else ('P', 'IPE'))
                host = {'name': f"{v.name}|pipe|{len(walls) + 1}", 'y': v.y, 'tier': tier, 'poly': [(r['x'] - 100, r['z0']), (r['x'] + 100, r['z0']), (r['x'] + 100, r['z1']), (r['x'] - 100, r['z1'])],
                        't': None, 't_source': 'pipe host (no plate)', 'stiffeners': [], 'openings': [], 'grade': 'A', 'host_only': True}
                walls.append(host)
            host.setdefault('pipes', []).append(r)
    # R-B4: a bracket callout 'WxT' with a leader = a bracket at the leader tip (position read from the drawing, size from the text)
    if settings.get('callout_brackets', True):
        for c, tip, W, T in callout_tips(page):
            if not (v.xr[0] - 10 < tip[0] < v.xr[1] + 10 and v.ytop < tip[1] < v.row_cy):
                continue
            X, Z = v.X(tip[0]), v.Z(tip[1])
            if False:
                print('CBDBG', v.name, c.text.strip(), round(X), round(Z), [(round(w_['poly'][0][0]), round(w_['poly'][1][0]), round(w_['poly'][0][1]), round(w_['poly'][2][1])) for w_ in walls])
            tier = [w_ for w_ in walls if w_['poly'][0][1] - 50 <= Z <= w_['poly'][2][1] + 50] or walls
            if tier:
                w_ = min(tier, key=lambda q: max(q['poly'][0][0] - X, X - q['poly'][1][0], 0))
                w_.setdefault('free_brackets', []).append({'x': X, 'z': Z, 'leg': W, 't': T, 'txt': c.text.strip()})
    return walls


def _deck_tiers(page, v, deck_z, small_all):
    """tiers between DECK levels only (stringer levels 'S<n>' skipped) and their full-height vertical lines"""
    vv = copy.copy(v)
    vv.decks = {c: y for c, y in v.decks.items() if not re.fullmatch(r'S\d+', c)}
    vv.label_decks = {c for c in getattr(v, 'label_decks', set()) if c in vv.decks} | {c for c in vv.decks if c in getattr(v, 'label_decks', set())}
    tiers = _tiers(vv, deck_z)
    gathered = {}
    for lo, hi, yb, yt in tiers:
        H = yb - yt
        vs = []
        for s in page.segs:
            if s.vertical and s.length > 1.0 and v.xr[0] - 10 < s.a[0] < v.xr[1] + 10:
                y0_, y1_ = min(s.a[1], s.b[1]), max(s.a[1], s.b[1])
                if y1_ < yt - 14 or y0_ > yb + 14:
                    continue
                c = copy.copy(s)
                c.a, c.b = (s.a[0], max(y0_, yt)), (s.b[0], min(y1_, yb))
                vs.append(c)
        lines = []
        for x, y0, y1, w in _merge_vertical(vs, gap=7.0):
            if y1 - y0 < 0.85 * H or y0 > yt + 0.15 * H or y1 < yb - 0.15 * H:
                continue
            if _sw_mark(page.words, x, y0, y1):
                continue             # R2.13: an 'S.W' line in a wall view is ANOTHER wall meeting this one - never a stiffener
            lines.append({'x': x, 'y0': y0, 'y1': y1, 'w': w, 'm': _marker_count(small_all, x, y0, y1), 'dash': _dash_frac(vs, x, y0, y1)})
        gathered[(lo, hi)] = lines
    return tiers, gathered


LONGL_ROW = re.compile(r'^\s*NO\.?\s*\d{1,2}(?:-\d)?\s*LONGL\.?\s*$')


def _crossed_boxes(page, v, yt, yb):
    """R-E25: a rectangle crossed by its two diagonals is an OPENING in the plane of the view (no plate there).
    Two diagonal strokes (any line style) whose end points are the opposite corners of one box (3 pt) give that box."""
    dg = [s for s in page.segs if not s.horizontal and not s.vertical and s.length > 30
          and v.xr[0] - 10 < min(s.a[0], s.b[0]) and max(s.a[0], s.b[0]) < v.xr[1] + 10
          and yt - 4 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < yb + 4]
    # dashed diagonals come in pieces: join collinear pieces into one stroke per line
    lines = {}
    for s in dg:
        (x1, y1), (x2, y2) = sorted([s.a, s.b])
        sl = (y2 - y1) / (x2 - x1) if abs(x2 - x1) > 1e-6 else 1e9
        k = (round(sl, 2), round((y1 - sl * x1) / 2.0))
        e = lines.setdefault(k, [x1, y1, x2, y2])
        if x1 < e[0]:
            e[0], e[1] = x1, y1
        if x2 > e[2]:
            e[2], e[3] = x2, y2
    L = list(lines.values())
    boxes = []
    for i, a in enumerate(L):
        for b in L[i + 1:]:
            if abs(a[0] - b[0]) < 3 and abs(a[2] - b[2]) < 3 and abs(a[1] - b[3]) < 3 and abs(a[3] - b[1]) < 3 and abs(a[3] - a[1]) > 20:
                boxes.append((min(a[0], b[0]), min(a[1], a[3]), max(a[2], b[2]), max(a[1], a[3])))
    return boxes


def _plated_fields(page, v, tiers, gathered, deck_z, notes_sec, aliases, sheet, walls):
    """R-E23 (plated bulkhead elevation): a thickness note stands in the plate it names. In a deck-to-deck tier the plate runs
    between the nearest full-height SOLID lines left and right of the note (plate seams / wall ends) and deck to deck; neighbouring
    intervals with the same thickness are one field. A field already built as a wall with a thickness is left as it is; a wall of
    the same span built without thickness takes the field's plate. Crossed boxes inside a field are openings (R-E25).
    R-E24: a horizontal line (solid or dashed = far side) inside a field whose right end carries a row label 'NO.n LONGL.'
    at the view's right margin is a horizontal stiffener of the field, at the Z of that line; section = a size label on the line,
    else the title default ('STIFF. : 150X90X9 U.A EXC. AS SHOWN')."""
    rowlabs = [w for w in page.words if not w.vertical and LONGL_ROW.match(w.text) and v.xr[1] - 60 < w.cx < v.xr[1] + 300]
    for lo, hi, yb, yt in tiers:
        lines = [l for l in gathered.get((lo, hi), []) if l.get('dash', 0) < 0.5]
        xs = []
        for l in sorted(lines, key=lambda l: l['x']):
            if not xs or l['x'] - xs[-1] > 1.5:
                xs.append(l['x'])
        if len(xs) < 2:
            continue
        notes = []
        for w in page.words:
            m = _thk(w, page.words)
            if not m or w.vertical or not (xs[0] < w.cx < xs[-1] and yt < w.cy < yb):
                continue
            tab = [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < u.cy - w.cy < 14 and re.search(r'FL\.|F\.B', u.text)]
            tab += [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < w.cy - u.cy < 14
                    and re.search(r'\bPAD\b|DOUBL|INSERT|COLLAR', u.text)]
            if not tab:
                notes.append((w.cx, float(m.group(1)), bool(m.group(2))))
        if os.environ.get('WDBG'):
            print('FDBG', lo, hi, [round(x) for x in xs], [(round(n[0]), n[1]) for n in notes], [(round(l['x']), round(l.get('dash', 0), 2), l['m']) for l in gathered.get((lo, hi), [])])
        if not notes:
            continue
        iv = {}
        for cx, t, ah in notes:
            xa = max(x for x in xs if x < cx)
            xb = min(x for x in xs if x > cx)
            iv.setdefault((xa, xb), []).append((t, ah))
        # every interval between two neighbouring full-height lines: its note, or none
        cells = []
        for xa, xb in zip(xs, xs[1:]):
            ts = iv.get((xa, xb))
            if ts:
                t = Counter(t_ for t_, _ in ts).most_common(1)[0][0]
                cells.append([xa, xb, t, any(a_ for t_, a_ in ts if t_ == t), 'note'])
            else:
                cells.append([xa, xb, None, False, ''])
        # an interval without a note between two noted intervals of the SAME thickness is the same plate run (the line between is a
        # member, not a seam: one note per plate); between different thicknesses the seam position is not written -> owner question
        for i, c in enumerate(cells):
            if c[2] is not None:
                continue
            L_ = next((cells[j] for j in range(i - 1, -1, -1) if cells[j][2] is not None), None)
            R_ = next((cells[j] for j in range(i + 1, len(cells)) if cells[j][2] is not None), None)
            if L_ and R_ and L_[2] == R_[2]:
                c[2], c[3], c[4] = L_[2], L_[3] or R_[3], 'run'
            elif L_ and R_:
                v.evidence.setdefault('ask', '')
                v.evidence.setdefault('ask_fields', []).append(
                    f'{v.name} {lo}-{hi}: plate X {v.X(c[0]):.0f}-{v.X(c[1]):.0f} between {L_[2]:g} and {R_[2]:g} - seam position / thickness not written')
        fields = []
        for xa, xb, t, ah, _src in cells:
            if t is None:
                continue
            if fields and abs(fields[-1][1] - xa) < 1.5 and fields[-1][2] == t:
                fields[-1][1] = xb
                fields[-1][3] = fields[-1][3] or ah
            else:
                fields.append([xa, xb, t, ah])
        Zb, Zt = v.zov.get(lo, deck_z[lo]), v.zov.get(hi, deck_z[hi])
        boxes = _crossed_boxes(page, v, yt, yb)
        for xa, xb, t, ah in fields:
            U0, U1 = _snap(v.X(xa), 400.0, 40.0), _snap(v.X(xb), 400.0, 40.0)
            if U1 - U0 < 300:
                continue
            same = [w_ for w_ in walls if tuple(w_.get('tier', ())) == (lo, hi) and not w_.get('host_only')
                    and min(U1, w_['poly'][1][0]) - max(U0, w_['poly'][0][0]) > 0.5 * min(U1 - U0, w_['poly'][1][0] - w_['poly'][0][0])]
            same = [w_ for w_ in same if not w_['t']] + [w_ for w_ in walls if tuple(w_.get('tier', ())) == (lo, hi) and w_['t']
                    and min(U1, w_['poly'][1][0]) - max(U0, w_['poly'][0][0]) > 100]
            # a wall already read WITH a thickness keeps its span: the field is cut back to it at that end, or dropped when the
            # wall covers most of the field
            for w_ in [w_ for w_ in same if w_['t']]:
                a_, b_ = w_['poly'][0][0], w_['poly'][1][0]
                if b_ - a_ >= 0.7 * (U1 - U0):
                    U1 = U0
                elif a_ <= U0 + 50:
                    U0 = max(U0, b_)
                elif b_ >= U1 - 50:
                    U1 = min(U1, a_)
            if U1 - U0 < 300:
                continue
            same = [w_ for w_ in same if not w_['t']]
            st = []
            for w_ in same:                     # a wall of this span read without thickness: its stiffeners join the field
                st += w_['stiffeners']
                walls.remove(w_)
            holes = []
            for bx in boxes:
                if bx[0] > xa - 3 and bx[2] < xb + 3:
                    hx0, hx1 = max(U0, v.X(bx[0])), min(U1, v.X(bx[2]))
                    hz0, hz1 = max(Zb, v.Z(bx[3])), min(Zt, v.Z(bx[1]))
                    if hx1 - hx0 > 200 and hz1 - hz0 > 200:
                        holes.append([(round(hx0), round(hz0)), (round(hx1), round(hz0)), (round(hx1), round(hz1)), (round(hx0), round(hz1))])
            if holes and len(holes) == 1 and (holes[0][1][0] - holes[0][0][0]) >= (U1 - U0) - 50 and (holes[0][2][1] - holes[0][0][1]) >= (Zt - Zb) - 50:
                continue                         # the whole field is an opening
            hst = _row_stiffeners(page, v, rowlabs, U0, U1, yt, yb, notes_sec)
            walls.append({'name': f"{v.name}|{lo}-{hi}|F{len(walls) + 1}", 'y': v.y, 'tier': (lo, hi),
                          'poly': [(U0, Zb), (U1, Zb), (U1, Zt), (U0, Zt)], 't': t,
                          't_source': 'R-E23 note in the field between its seam lines', 'grade': 'AH' if ah else 'A',
                          'stiffeners': st, 'hstiff': hst, 'openings': holes})


    # R-E24 for every plated wall of the view (also those read by R-E3)
    for w_ in walls:
        if w_.get('t') and 'hstiff' not in w_ and w_.get('tier'):
            tr = next(((yb, yt) for lo, hi, yb, yt in tiers if (lo, hi) == tuple(w_['tier'])), None)
            if tr:
                w_['hstiff'] = _row_stiffeners(page, v, rowlabs, w_['poly'][0][0], w_['poly'][1][0], tr[1], tr[0], notes_sec)


def _row_stiffeners(page, v, rowlabs, U0, U1, yt, yb, notes_sec):
    """R-E24: horizontal lines inside [U0, U1] x (yt, yb) that end at a 'NO.n LONGL.' row label -> horizontal stiffeners"""
    xa, xb = v.x0 + U0 / v.k, v.x0 + U1 / v.k
    hst = []
    for w in rowlabs:
        ys_ = [sg for sg in page.segs if sg.horizontal and abs(sg.a[1] - w.bbox[3]) < 3.0 and yt + 2 < sg.a[1] < yb - 2
               and min(sg.a[0], sg.b[0]) < xb - 5 and max(sg.a[0], sg.b[0]) > xa + 5]
        if not ys_:
            continue
        y_ = statistics.median(sg.a[1] for sg in ys_)
        far = sum(sg.length for sg in ys_ if sg.dash) > sum(sg.length for sg in ys_ if not sg.dash)
        from .section import _mark_on_line
        sec_, src_ = _mark_on_line(page, y_, xa, xb)
        if sec_ is None:
            sec_, src_ = notes_sec, 'section title default'
        hst.append({'z': round(v.Z(y_)), 'x0': U0, 'x1': U1, 'section': sec_, 'far': far,
                    'evidence': f'R-E24 row label "{w.text.strip()}" at the line end; {src_}'})
    return hst


def _slanted_walls(page, v, deck_z, small_all, default_t, notes_sec, aliases, sheet, walls):
    """R-SL1: the slanted line (steep, long, not vertical) is the free edge of the wall; the wall is bounded on the other side by the
    tallest vertical line next to it, below by the deck line it starts on, above by where the slanted line ends.  Walls found
    tier-by-tier inside this polygon are replaced by it.  Stiffeners = marked full-height vertical lines inside."""
    lab = [w for w in page.words if w.vertical and 'SLANTED' in w.text.upper() and v.xr[0] - 60 < w.cx < v.xr[1] + 60 and v.ytop < w.cy < v.row_cy]
    if not lab:
        return []
    cand = [s for s in page.segs if not s.vertical and abs(s.a[0] - s.b[0]) > 0.5 and abs(s.a[1] - s.b[1]) > 120
            and abs(s.a[0] - s.b[0]) < 0.25 * abs(s.a[1] - s.b[1])
            and v.xr[0] - 10 < min(s.a[0], s.b[0]) and max(s.a[0], s.b[0]) < v.xr[1] + 10
            and v.ytop - 60 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < v.row_cy]
    if not cand:
        return []
    sl = max(cand, key=lambda s: abs(s.a[1] - s.b[1]))
    (xa, ya), (xb, yb_) = sl.a, sl.b
    if ya < yb_:
        (xt, yt_), (xb_, yb2) = (xa, ya), (xb, yb_)
    else:
        (xt, yt_), (xb_, yb2) = (xb, yb_), (xa, ya)
    span = yb2 - yt_
    vs = [s for s in page.segs if s.vertical and s.length > 1.0 and xb_ - 3 < s.a[0] < xb_ + 260 and yt_ - 14 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < yb2 + 14]
    lines = [{'x': x, 'y0': y0, 'y1': y1, 'w': w, 'm': _marker_count(small_all, x, y0, y1), 'dash': _dash_frac(vs, x, y0, y1)}
             for x, y0, y1, w in _merge_vertical(vs, gap=7.0) if y1 - y0 > 0.85 * span]
    lines = [l for l in lines if l['x'] < xb_ + 260]
    if not lines:
        return []
    if os.environ.get('WDBG'):
        print('SLDBG', v.name, round(xb_), round(xt), [(round(l['x']), l['m'], round(l['w'], 2), round(l['y0']), round(l['y1'])) for l in lines], round(yt_), round(yb2))
    edge = [l for l in lines if l['w'] >= 0.6 and l['m'] < STIFF_MARKERS]
    right = max(edge or lines, key=lambda l: l['x'])
    Zb, Zt = v.Z(yb2), v.Z(yt_)
    U0b, U0t, U1 = v.X(xb_), v.X(xt), v.X(right['x'])
    if U1 - max(U0b, U0t) < 500:
        return []
    poly = [(_snap(U0b, 100.0, 15.0), _snap(Zb, 50.0, 25.0)), (_snap(U1, 100.0, 15.0), _snap(Zb, 50.0, 25.0)),
            (_snap(U1, 100.0, 15.0), _snap(Zt, 50.0, 25.0)), (_snap(U0t, 100.0, 15.0), _snap(Zt, 50.0, 25.0))]
    st = []
    for l in lines:
        if l is right or l['m'] < STIFF_MARKERS or l['x'] > right['x'] - 2:
            continue
        la = _label_for(page.words, l['x'], l['y0'], l['y1'])
        if la:
            mm = members.SEC.search(la.text)
            sec = members.parse_section(la.text, aliases)
            src = 'label ' + la.text.strip()
            if sec is None and mm:
                sec, src2 = _resolve_short(int(mm.group('h')), mm.group('k'), notes_sec, aliases, sheet)
                src += ' -> ' + src2
        else:
            sec, src = notes_sec, 'title default'
        st.append({'x': _snap(v.X(l['x']), 400.0, 40.0), 'a_z': poly[0][1], 'b_z': poly[2][1], 'section': sec, 'far': l.get('dash', 0) > 0.5,
                   'bmark': _bmark_ends(page, l), 'evidence': src + ' (slanted wall)'})
    xl_ = min(U0b, U0t)
    walls[:] = [w_ for w_ in walls if not (w_['poly'][0][0] >= xl_ - 600 and w_['poly'][1][0] <= U1 + 600
                                           and w_['poly'][0][1] >= Zb - 100 and w_['poly'][2][1] <= Zt + 100)]
    ts, ahs = [], set()
    for w in page.words:
        m = _thk(w, page.words)
        if m and xb_ < w.cx < right['x'] and yt_ < w.cy < yb2 and not w.vertical:
            ts.append(float(m.group(1)))
            if m.group(2):
                ahs.add(float(m.group(1)))
    t_, tsrc = (Counter(ts).most_common(1)[0][0], 'note inside wall (slanted wall)') if ts else (default_t, 'title default (slanted wall)')
    return [{'name': f"{v.name}|slanted|{len(walls) + 1}", 'y': v.y, 'tier': ('C', 'W'), 'poly': poly, 't': t_,
             't_source': tsrc, 'grade': 'AH' if t_ in ahs else 'A', 'stiffeners': st, 'openings': []}]


def _write_pipe(pp, gid, name, od, t, a, b, label):
    """pipe = PillarGroup with a Tube{OD}*{t} cross-section (two concentric circles), Pillar with a 3D trace in the panel frame"""
    import xml.etree.ElementTree as ET
    from .export import _f
    pg = ET.SubElement(pp, 'PillarGroup', GroupId=str(gid), BendType='Straight')
    mat = ET.SubElement(pg, 'Material', Grade='A')
    bid = f'Tube{od:g}*{t:g}'
    bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType='70')
    ET.SubElement(bs, 'Parameters').text = f'{od:g} {t:g}'
    cr = ET.SubElement(bs, 'Crossection')
    k = 0.5522847498
    for i, r in enumerate((od / 2.0, od / 2.0 - t)):
        ET.SubElement(cr, 'StartPoint2d', U=_f(0), V=_f(-r))
        for (u, v_, au, av) in ((r, 0, k * r, -k * r), (0, r, k * r, k * r), (-r, 0, -k * r, k * r), (0, -r, -k * r, -k * r)):
            sg = ET.SubElement(cr, 'Segment2d')
            ET.SubElement(sg, 'Amplitude2d', U=_f(au), V=_f(av))
            ET.SubElement(sg, 'Node2d', U=_f(u), V=_f(v_))
    pl = ET.SubElement(pg, 'Pillar', CompId='1', Name=name, Source=f'pipe label {label}; OD/t from the owner pipe table')
    tr = ET.SubElement(pl, 'Trace')
    ET.SubElement(tr, 'StartPoint3d', U=_f(a[0]), V=_f(a[1]), W=_f(a[2]))
    sg = ET.SubElement(tr, 'Segment3d')
    ET.SubElement(sg, 'Amplitude3d', U=_f(0), V=_f(0), W=_f(0))
    ET.SubElement(sg, 'Node3d', U=_f(b[0]), V=_f(b[1]), W=_f(b[2]))
    inc = ET.SubElement(pl, 'Inclination')
    for _ in range(2):
        ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(1), W=_f(0))
    ET.SubElement(pl, 'End1')
    ET.SubElement(pl, 'End2')


# ---------------------------------------------------------------- export
def write_walls(path, panels, settings):
    import xml.etree.ElementTree as ET
    from .export import _contour, _trace, _xyz, _f, bar_id, BAR_TYPE, _crossection, add_web_flange
    ship = ET.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine',
                      Source='deckrules elevations (PDF drawing only)')
    ET.SubElement(ship, 'Material', Grade='A')
    used = {}
    for p in panels:
        for s in p['stiffeners'] + p.get('hstiff', []) + p.get('hcarl', []):
            if s['section']:
                bid, tag, attrs = bar_id(s['section'])
                used[bid] = (tag, attrs)
    for bid, (tag, attrs) in sorted(used.items()):
        bs = ET.SubElement(ship, 'BarSection', BarSectionId=bid)
        ET.SubElement(bs, tag, **attrs)
    blocks = {}
    for i, p in enumerate(panels, 1):
        yk = int(p['y'])
        side = 'P' if yk > 0 else ('S' if yk < 0 else 'CL')
        bname = f'PDF-WALL-Y{abs(yk)}{side}'
        blk = blocks.get(bname)
        if blk is None:
            blk = blocks[bname] = ET.SubElement(ship, 'Block', ObjId=bname)
        pid = f"{bname}-{p['tier'][0]}{p['tier'][1]}-{i}"
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=pid, Tightness='NonTight')
        cs = ET.SubElement(pp, 'CoordSys')
        _xyz(cs, 'Origin', 0, p['y'], 0)
        _xyz(cs, 'Waxis', 0, -1, 0)
        _xyz(cs, 'Uaxis', 1, 0, 0)
        bd = ET.SubElement(pp, 'Boundary')
        _contour(bd, 'SimpleContour', p['poly'])
        gid = 1
        if p['t']:        # R-E4b (owner, Q1): a wall plate exists only where a thickness is printed; else stiffeners only
            pg = ET.SubElement(pp, 'PlateGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(pg, 'Material', Grade=p.get('grade', 'A'))
            ET.SubElement(mat, 'Thickness').text = f"{p['t']:g}"
            pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{pid}-P1', Source=p['t_source'])
            _contour(pl, 'SimpleContour', p['poly'])
        else:
            pp.set('Note', 'stiffeners only (no thickness printed)')
        if p['openings']:
            hg = ET.SubElement(pp, 'HoleGroup', GroupId=str(gid))
            gid += 1
            for j, h in enumerate(p['openings'], 1):
                hh = ET.SubElement(hg, 'Hole', CompId=str(j))
                _contour(hh, 'Contour', h)
        n = 0
        for s in p.get('hstiff', []) + p.get('hcarl', []):            # R-E24 horizontal stiffeners; R2.18 carlings; R2.19 portal face bars
            _pu = [pu for pu, _ in p['poly']]
            s['x0'], s['x1'] = max(s['x0'], min(_pu)), min(s['x1'], max(_pu))      # the panel may have been cut back (R-XV4b)
            if s['x1'] - s['x0'] < 100:
                continue
            if not s['section']:
                continue
            n += 1
            bid, tag, attrs = bar_id(s['section'])
            sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight')
            gid += 1
            mat = ET.SubElement(sg, 'Material', Grade='A')
            bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
            ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in s['section'][1:])
            _crossection(bs, tag, attrs)
            st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/H{n}', Kind='wall longitudinal', Evidence=s['evidence'][:300])
            _trace(st, (s['x0'], s['z']), (s['x1'], s['z']))
            wsign = -1.0 if s.get('far') else 1.0
            inc = ET.SubElement(st, 'Inclination')
            for _ in range(2):
                ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(wsign))
            add_web_flange(st, (s['x0'], p['y'], s['z']), (s['x1'], p['y'], s['z']), (0, -wsign, 0), s['section'])
        for s in p['stiffeners']:
            if not s['section']:
                continue
            n += 1
            bid, tag, attrs = bar_id(s['section'])
            sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight')
            gid += 1
            mat = ET.SubElement(sg, 'Material', Grade='A')
            bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
            ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in s['section'][1:])
            _crossection(bs, tag, attrs)
            st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/S{n}', Kind='wall stiffener',
                               Evidence=s['evidence'][:300])
            lo, hi = sorted((s['a_z'], s['b_z']))
            from . import connect                     # R-CN1: stand at the X of the deck beam that ends on this wall, up to its deck
            _cn = connect.wall_x(p['y'], s['x'], hi) if connect.TABLE['beams'] else None
            if _cn is not None:
                s['x'], hi = _cn[0], _cn[1]
                s['_conn'] = True
            _trace(st, (s['x'], lo), (s['x'], hi))       # R-DR: vertical members run towards +V
            # R-E8: stiffeners stand on the centreline side (reference: 87 % of the wall members):
            # panel W axis is world -Y, so +W points to the centreline for a port wall, -W for starboard
            wsign = 1.0 if p['y'] > 0 else -1.0
            if settings.get('web_side_from_line_style', True):
                # R-E8b: elevation looks PORT (+Y). Solid line = near side -> web toward the viewer (world -Y);
                # dashed line = far side -> web along the viewing direction (world +Y). Panel W axis is world -Y.
                wsign = -1.0 if s.get('far') else 1.0
            inc = ET.SubElement(st, 'Inclination')
            for _ in range(2):
                ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(wsign))
            add_web_flange(st, (s['x'], p['y'], lo), (s['x'], p['y'], hi), (0, -wsign, 0), s['section'])
            # R-B2/B3 (wall): the B mark at the upper end of a wall stiffener = bracket to the deck beam, standing in the beam web plane
            # (X-normal), hanging below the deck by 'bracket_drop_mm' (learned: 250), leg and thickness from the callout 'WxT' else 200 x 8.
            bm = s.get('bmark') or {}
            if settings.get('wall_brackets', True) and bm.get('hi') and not s.get('_conn'):
                sz = bm.get('size_hi')
                leg, bt = (sz[0], sz[1]) if sz else (float(settings.get('bracket_leg_mm', 200.0)), float(settings.get('bracket_thk_mm', 8.0)))
                if hi - lo >= 2 * leg * 0.6:
                    drop = float(settings.get('bracket_drop_mm', 250.0))
                    nbk = locals().get('nbk', 0) + 1
                    bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
                    gid += 1
                    mat = ET.SubElement(bg, 'Material', Grade='A')
                    ET.SubElement(mat, 'Thickness').text = f"{bt:g}"
                    br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{pid}/B{n}', Source='B mark at wall stiffener upper end' + (f' + callout {sz[0]:g}X{sz[1]:g}' if sz else ''))
                    cs = ET.SubElement(br, 'CoordSys')
                    inward = -wsign                      # R-B7: legs along the stiffener and along its own web side (web plane)
                    _xyz(cs, 'Origin', s['x'], p['y'], hi - drop)
                    _xyz(cs, 'Waxis', inward, 0, 0)
                    _xyz(cs, 'Uaxis', 0, 0, -1)
                    _contour(br, 'SimpleContour', [(0, 0), (leg, 0), (0, leg)])   # owner: simple right triangle, no toe / chamfer
                    ET.SubElement(br, 'End1')
                    e2 = ET.SubElement(br, 'End2')
                    ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=pid, CompType='Stiffener', CompId='1')
        for k_, pr in enumerate(p.get('pipes', []), 1):
            od_t = (settings.get('pipe_table') or {}).get((pr['nominal'], pr['sch']))
            if not od_t:                                     # no schedule row: nothing is invented, the pipe is reported as pending
                settings.setdefault('_pipes_pending', []).append(f"{p['name']}: {pr['label']} at X={pr['x']:.0f}")
                continue
            od, tt = od_t
            _write_pipe(pp, gid, f"{pid}/PIPE{k_}", od, tt, (pr['x'], pr['z0'], 0.0), (pr['x'], pr['z1'], 0.0), pr['label'])
            gid += 1
        for k_, cb in enumerate(p.get('corner_brackets', []), 1):     # R4.14 corner bracket AxB / t in the wall plane
            bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(bg, 'Material', Grade='A')
            ET.SubElement(mat, 'Thickness').text = f"{cb['t']:g}"
            br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{pid}/CB{k_}', Source=cb['evidence'])
            cs = ET.SubElement(br, 'CoordSys')
            _xyz(cs, 'Origin', cb['u'], p['y'], cb['z'])
            _xyz(cs, 'Waxis', 0, -1, 0)
            _xyz(cs, 'Uaxis', cb['su'], 0, 0)          # leg A out of the wall end; V = W x U = (0, 0, su)
            _contour(br, 'SimpleContour', [(0, 0), (cb['a'], 0), (0, cb['b'] * cb['sz'] * cb['su'])])
            ET.SubElement(br, 'End1')
            ET.SubElement(br, 'End2')
        for k_, fb in enumerate(p.get('free_brackets', []), 1):
            bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(bg, 'Material', Grade='A')
            ET.SubElement(mat, 'Thickness').text = f"{fb['t']:g}"
            br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{pid}/CB{k_}', Source=f"callout {fb['txt']} (leader tip)")
            cs = ET.SubElement(br, 'CoordSys')
            leg = fb['leg']
            _xyz(cs, 'Origin', fb['x'], p['y'], fb['z'])
            _xyz(cs, 'Waxis', -1.0 if p['y'] > 0 else 1.0, 0, 0)
            _xyz(cs, 'Uaxis', 0, 0, -1)
            _contour(br, 'SimpleContour', [(0, 0), (leg, 0), (0, leg)])   # owner: simple right triangle, no toe / chamfer
            ET.SubElement(br, 'End1')
            ET.SubElement(br, 'End2')
    ET.indent(ship)
    ET.ElementTree(ship).write(path, encoding='utf-8', xml_declaration=True)
    return {'panels': len(panels)}
