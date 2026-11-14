"""Transverse frame sections ('FR.n[+-mm] SEC.[(P|S)]') -> X-normal wall panels on the moulded line.

  R-S1  Title 'FR.n+-off SEC.' = plane X = n*frame_space + off (project frame spacing, drawing note otherwise).
        Notes under the title: 'PLATE THK. : t', 'STIFF. SIZE : hXwXt U.A'.
  R-S2  Z: the right-hand deck labels ('NAV. DECK', 'D - DECK' ...) name long horizontal lines; their heights come
        from the deck plans, so page y -> Z is a straight line of slope 1/k (k = mm per page pt).
  R-S3  Y: vertical wall lines sit at the OFF C.L values printed on the longitudinal elevations. The centre-line x is the
        one for which the most full-height vertical lines fall on those known Y values (or 0).
        Port (+Y) is on the LEFT of the view (checked on the window W6 of FR.26 and the reference panels).
  R-S4  One plate panel per deck-to-deck tier and per side (P: Y>0, S: Y<0): rectangle from the centre strip (100 mm,
        the printed '100' at the CL) to the outermost full-height line, on the moulded line, no thickness shift.
  R-S5  Stiffeners = vertical lines with arrow markers at their ends (same marker rule as the elevations), partial
        lines included; section from the nearest vertical label else the title default.
"""
import copy
import math
import re
import statistics
from collections import Counter, defaultdict

from . import members
from .elevation import (callout_near, callout_tips, DECK_ORDER, _merge_vertical, _marker_count, _label_for, _resolve_short, _snap, THK, NOTE_T,
                        NOTE_S, STIFF_MARKERS)
from .deckplan import closed_paths, thin_weight, _rounded

TITLE = re.compile(r'^\s*FR\.\s*(?P<n>\d+)\s*(?:(?P<frac>\+\s*1\s*/\s*2)|(?P<off>[+-]\s*\d+))?\s*SEC\.?\s*(?:\((?P<s>[PS])\))?\s*$')   # R-S19: 'FR.19+1/2 SEC.'
TIER_MAX = 7000.0      # R-V22: a girder frame may span 5.8 m (37160 -> 42961)
DECK_LABEL = re.compile(r'^\s*(?:(NAV|COMP|UPP|[A-D])\s*\.?\s*-?\s*DECK|NO\.?\s*(\d)\s*STR(?:INGER|\.)?|(WEATHER)\s*SHIELD)\s*$', re.I)
HALF = 440.0          # page pt either side of the title that belong to the view
CL_GAP = 100.0        # mm, the centre strip left open between the P and S plates (reference practice, '100' at the CL)
MARK_MIN = 8
DERIVED = set()       # R-S6: deck codes whose height is derived (not printed on a plan title) - never used to calibrate a view
REBASE = set()        # R-SS1 (owner 2026-10-24): frame numbers whose view is built at the MAIN title frame (sub-title = span only); set from settings 'subtitle_rebase'


class SecView:
    def __init__(self, title, n, off, side):
        self.title, self.n, self.off, self.side = title, n, off, side
        self.name = title.text.strip()
        self.X = None
        self.notes = {}
        self.k = None
        self.yz0 = None
        self.decks = {}
        self.xcl = None
        self.s = -1          # Y = s*(x - xcl)*k ; -1 = port on the left
        self.region = None
        self.evidence = {}
        self.xlab = 1e9      # R-S9: right limit of the label search (midpoint to the next view on the row)
        self.zov = {}        # R-S6: deck code -> Z measured in THIS view (deck height not printed, e.g. derived UPP. DECK)


def find_views(page, frame_space):
    out = []
    for w in page.words:
        if w.size < 12:
            continue
        m = TITLE.match(w.text)
        if m:
            off = int(m.group('off').replace(' ', '')) if m.group('off') else 0
            v = SecView(w, int(m.group('n')), off, m.group('s') or '')
            v.X = (frame_space(v.n) if callable(frame_space) else v.n * frame_space) + off
            if m.group('frac'):
                # R-S19: a half frame ('FR.19+1/2') lies half way between frame n and frame n+1 of the frame table (bays may differ)
                nxt = frame_space(v.n + 1) if callable(frame_space) else (v.n + 1) * frame_space
                v.X = round((v.X + nxt) / 2.0, 1)
                v.evidence = {'half_frame': f'FR.{v.n}+1/2 = mid of FR.{v.n} and FR.{v.n + 1}'}
            out.append(v)
    for v in out:
        t = v.title
        for w in page.words:
            if abs(w.bbox[0] - t.bbox[0]) < 30 and t.bbox[3] - 8 < w.bbox[1] < t.bbox[3] + 40 and not w.vertical:
                for key, rx in (('plate', NOTE_T), ('stiff', NOTE_S)):
                    m = rx.search(w.text)
                    if m and key not in v.notes:
                        v.notes[key] = m.group(1).strip()
    for v in out:
        t = v.title
        below = [u.title.bbox[1] for u in out if u is not v and u.title.bbox[1] > t.bbox[3] + 150
                 and abs(u.title.cx - t.cx) < 150]
        other = [w.bbox[1] for w in page.words if w.size >= 12 and w.bbox[1] > t.bbox[3] + 150
                 and abs(w.cx - t.cx) < 150 and re.search(r"SEC\.|ELEV\.|PLAN", w.text)]
        ylim = min(below + other + [t.bbox[3] + 1300])
        v.region = (t.cx - HALF, t.bbox[3] + 15, t.cx + HALF + 90, ylim - 10)
        # R-S18: a wide section (full breadth at 1/100) is wider than the default half-width: its deck-name column on the right (the
        # nearest column of 2+ deck names right of the title, before the next view of the row) gives its right edge, and a full section
        # is symmetric about the title / centre line, so the left edge mirrors it
        from . import decknames
        nxt = min([u.title.cx for u in out if u is not v and abs(u.title.cy - t.cy) < 60 and u.title.cx > t.cx] + [1e9])
        cols = [w for w in page.words if not w.vertical and decknames.key(w.text) and t.cx + HALF < w.cx < (t.cx + nxt) / 2
                and t.bbox[3] < w.cy < ylim]
        # only for a FULL section: 'nnnn OFF C.L' labels printed in mirror pairs about the title (two equal values, mid-point at the title)
        offs = []
        for w in page.words:
            if re.fullmatch(r'\d{3,5}', w.text.strip()) and not w.vertical and t.bbox[3] < w.cy < ylim and \
                    any(u.text.strip().startswith('OFF C') and abs(u.cx - w.cx) < 20 and 0 < u.cy - w.cy < 14 for u in page.words):
                offs.append(w)
        pairs, hw = 0, 0.0
        rows_ = defaultdict(list)
        for w in offs:
            rows_[round(w.cy / 10)].append(w)
        prv = max([u.title.cx for u in out if u is not v and abs(u.title.cy - t.cy) < 60 and u.title.cx < t.cx] + [-1e9])
        for row_ in rows_.values():
            # the row is THIS view's dimension row when most of its labels (between the neighbouring views of the title row) pair up
            # about the title, and a larger OFF C.L value stands farther from the centre (two neighbouring views' rows may pair by chance)
            row_ = [w for w in row_ if (t.cx + prv) / 2 < w.cx < (t.cx + nxt) / 2]
            pr_, paired, hw_, dist = 0, set(), 0.0, []
            for i, a_ in enumerate(row_):
                for b_ in row_[i + 1:]:
                    if a_.text.strip() == b_.text.strip() and abs((a_.cx + b_.cx) / 2 - t.cx) < 60 and abs(a_.cx - b_.cx) > 100:
                        pr_ += 1
                        paired |= {id(a_), id(b_)}
                        hw_ = max(hw_, abs(a_.cx - b_.cx) / 2)
                        dist.append((int(a_.text), abs(a_.cx - b_.cx) / 2))
            dist.sort()
            mono = all(d2 >= d1 - 5 for (_, d1), (_, d2) in zip(dist, dist[1:]))
            row_ = [w for w in row_ if abs(w.cx - t.cx) <= hw_ + 40]      # the labels within the widest pair (a neighbour view's row lies outside)
            if len(row_) >= 4 and len(paired) >= 0.6 * len(row_) and mono:
                pairs += pr_
                hw = max(hw, hw_)
        cols = [w for w in cols if w.bbox[0] - t.cx < hw + 250]       # the deck names stand just outside the widest OFF C.L pair
        # used only when the default window holds fewer than two deck names (it is a fallback for views wider than the default)
        _inwin = [w for w in page.words if not w.vertical and decknames.key(w.text) and t.cx - HALF < w.cx < t.cx + HALF + 250
                  and t.bbox[3] < w.cy < ylim]
        # (or when the OFF C.L dimension row itself is wider than the default window: the view is at least that wide)
        if len(cols) >= 2 and pairs >= 2 and (len(_inwin) < 2 or hw > HALF + 90):
            xl = statistics.median(w.bbox[0] for w in cols)
            if xl - 20 > t.cx + HALF + 90:
                v.region = (min(t.cx - HALF, 2 * t.cx - xl), t.bbox[3] + 15, xl - 20, ylim - 10)
                v.evidence = dict(getattr(v, 'evidence', {}) or {}, wide_view=f'deck-name column at x {xl:.0f} (R-S18)')
    for v in out:          # R-S9: two views side by side (titles on one row) share the space between them at the midpoint
        t = v.title
        for u in out:
            if u is v or abs(u.title.cy - t.cy) > 60:
                continue
            mid = (u.title.cx + t.cx) / 2
            x0, y0, x1, y1 = v.region
            if u.title.cx > t.cx and x1 + 160 > mid:
                x1 = min(x1, mid)
                v.xlab = min(getattr(v, 'xlab', 1e9), mid)      # labels are searched up to x1 + 160, but never past the midpoint
            elif u.title.cx < t.cx and x0 < mid:
                x0 = mid
            v.region = (x0, y0, max(x1, x0 + 50), y1)
    # R-V21 (owner 2026-10-23): a small sub-title 'FR.48-345 SEC.' inside a big 'FR.48 SEC.(S)' view = the drawing is the section (girder frame) AT THAT X
    # (frame +/- offset), not at the big title's frame. Two positions ('FR.51+1610, FR.53-1872.5 SEC.') = the same drawing at both X.
    SUB = re.compile(r'FR\.\s*(\d+)\s*([+-])\s*([\d.]+)')
    res = []
    for v in out:
        x0, y0, x1, y1 = v.region
        subs = [w for w in page.words if w.size < 12 and 'SEC' in w.text and x0 <= w.cx <= x1 + 160 and y0 <= w.cy <= y0 + 140 and SUB.search(w.text)]
        # R-V21b: a sub-title belongs to the big view whose title is nearest to it (a neighbouring view's sub-title must not replace this view)
        subs = [w for w in subs if min(out, key=lambda u: abs(u.title.cx - w.cx) if abs(u.title.cy - v.title.cy) < 60 else 1e9) is v]
        # R-S12: a sub-title written ON a dimension line (the line runs >= 15 pt past the text on both sides) names a SPAN of the view
        # (e.g. between 'SLANTED' marks), not the frame of the whole view: the main title X is kept
        def _on_dim(w):
            iv = sorted((min(s_.a[0], s_.b[0]), max(s_.a[0], s_.b[0])) for s_ in page.segs if s_.horizontal and abs(s_.a[1] - w.bbox[3]) < 3)
            cur = None
            for a_, b_ in iv:
                if cur and a_ <= cur[1] + 1.0:
                    cur[1] = max(cur[1], b_)
                else:
                    if cur and cur[0] < w.bbox[0] - 15 and cur[1] > w.bbox[2] + 15:
                        return True
                    cur = [a_, b_]
            return bool(cur and cur[0] < w.bbox[0] - 15 and cur[1] > w.bbox[2] + 15)
        _span_subs = [w for w in subs if _on_dim(w)]
        if _span_subs:
            v.evidence = dict(getattr(v, 'evidence', {}) or {}, **{'R-S12': 'span sub-title(s) ' + ', '.join(w.text.strip() for w in _span_subs) + ' kept as spans; view at the main title X'})
            subs = [w for w in subs if w not in _span_subs]
        xs = []
        for w in subs:
            for m in SUB.finditer(w.text):
                n_, sg_, of_ = int(m.group(1)), (1 if m.group(2) == '+' else -1), float(m.group(3))
                base = frame_space(n_) if callable(frame_space) else n_ * frame_space
                xs.append((base + sg_ * of_, 'FR.%d%s%g SEC.' % (n_, m.group(2), of_), w))
        if not xs:
            res.append(v)
            continue
        if v.n in REBASE:        # R-SS1: the whole view is the MAIN frame; the sub-title applies to its span only
            v.sub = [dict(X=X_, name=nm, word=w_) for X_, nm, w_ in xs]
            v.evidence = {'R-SS1': 'main frame X=%g; sub-title %s only for its span' % (v.X, ', '.join(nm for _, nm, _ in xs))}
            res.append(v)
            continue
        for X_, nm, _w in xs:
            import copy
            v2 = copy.copy(v)
            v2.X, v2.name = X_, nm + ('(S)' if v.side == 'S' else '')
            v2.notes = dict(v.notes)
            v2.evidence = {'subtitle_X': nm}
            v2.decks = {}
            res.append(v2)
    for v_ in res:
        v_._peers = res
    return res


def calibrate(page, v, scale, deck_z):
    v.k = 25.4 / 72.0 * scale
    x0, y0, x1, y1 = v.region
    hs = [s for s in page.segs if s.horizontal and s.length > 45 and not s.dash and x0 - 30 < min(s.a[0], s.b[0])
          and max(s.a[0], s.b[0]) < min(x1 + 160, v.xlab) and y0 < s.a[1] < y1]
    # R-S6b: a cambered deck is drawn as a slightly sloping line (< 3 %): it is a deck line too, read at its end nearest the label (right end)
    for s_ in page.segs:
        if s_.kind == 'l' and not s_.horizontal and not s_.dash and s_.length > 45 and x0 - 30 < min(s_.a[0], s_.b[0]) \
                and max(s_.a[0], s_.b[0]) < min(x1 + 160, v.xlab) and y0 < s_.a[1] < y1:
            dx, dy = abs(s_.a[0] - s_.b[0]), abs(s_.a[1] - s_.b[1])
            if dx > 0 and dy < 0.03 * dx:
                class _H:
                    pass
                h = _H()
                e = max((s_.a, s_.b), key=lambda p: p[0])
                h.a, h.b, h.length, h.sloped = (min(s_.a[0], s_.b[0]), e[1]), (e[0], e[1]), s_.length, True
                hs.append(h)
    labs = []
    for w in page.words:
        from . import decknames
        c = decknames.key(w.text)                          # R-DN1
        if c and x0 < w.cx < min(x1 + 160, v.xlab) and y0 < w.cy < y1 + 20 and not w.vertical:
            if c in deck_z:
                labs.append((c, w))
        elif x0 < w.cx < min(x1 + 160, v.xlab) and y0 < w.cy < y1 + 20 and not w.vertical:
            # R-V19: deck labels that carry the height ('37160 A/B') or the camber-scheme top ('COMP. ROOM TOP')
            m2 = re.match(r'^\s*(\d{5})\s*A/B\s*$', w.text)
            c = 'Z' + m2.group(1) if m2 else ('CRT' if re.match(r'^\s*COMP(?:\.|RESSOR)?\s*(?:ROOM\s*TOP)?\s*$', w.text) and
                                              (re.search(r'ROOM', w.text) or any(u.text.strip() == 'ROOM TOP' and abs(u.cx - w.cx) < 12 and 0 < u.cy - w.cy < 14 for u in page.words)) else None)
            if c and c in deck_z:
                labs.append((c, w))
    if len(labs) < 2:
        raise ValueError(f'{v.name}: fewer than two deck labels in the view')
    def _line_y(w):
        near = [s for s in hs if -6 < w.cy - (s.a[1] + s.b[1]) / 2 < 16 and max(s.a[0], s.b[0]) > w.bbox[0] - 130]
        if not near:
            return None
        yl = min(near, key=lambda s: abs(w.cy - 8 - (s.a[1] + s.b[1]) / 2))
        return (yl.a[1] + yl.b[1]) / 2
    # R-S6: only decks whose height is printed calibrate the view; a derived height (UPP. DECK = A - offset) is measured in the view
    printed = [(c, w) for c, w in labs if c not in DERIVED]
    use = printed if printed else labs
    ests = []
    for c, w in use:
        y = _line_y(w)
        if y is None:
            continue
        ests.append(y + deck_z[c] / v.k)
    if not ests:
        raise ValueError(f'{v.name}: deck labels without deck lines')
    best = None
    for e in ests:                      # robust: the estimate that most others agree with
        n = sum(1 for f in ests if abs(f - e) < 2.5)
        if best is None or n > best[0]:
            best = (n, e)
    v.yz0 = statistics.median([f for f in ests if abs(f - best[1]) < 2.5])
    ys = sorted({round((s.a[1] + s.b[1]) / 2, 1) for s in hs})
    _len = defaultdict(float)
    for s_ in hs:
        _len[round((s_.a[1] + s_.b[1]) / 2, 1)] += s_.length
    _lab_len = []
    for c, w in labs:
        y_ = _line_y(w)
        if y_ is not None:
            _lab_len.append(sum(L for yy, L in _len.items() if abs(yy - y_) < 2.5))
    _min_len = 0.5 * statistics.median(_lab_len) if _lab_len else 0.0
    _lab_codes = {c for c, _ in labs}
    _has_z = any(c.startswith('Z') for c in _lab_codes)      # views that label decks by height: only the decks printed in THIS view exist in it
    for code in deck_z:
        if _has_z and code not in _lab_codes:
            continue      # R-V19b: a deck known only from its height (other sheets / decks 62 mm apart) counts in THIS view only if its label is printed here
        py = v.yz0 - deck_z[code] / v.k
        near = [yy for yy in ys if abs(yy - py) < 2.5]
        if near and code not in _lab_codes and len(_lab_codes) < 3 and sum(_len[yy] for yy in near) < _min_len:
            v.evidence.setdefault('short_lines_not_decks', []).append(code)      # R-S6c: in a part view (< 3 decks named) a short unnamed line at a deck height is not that deck
            near = []
        if near:
            v.decks[code] = float(statistics.median(near))
        elif any(c == code and abs(w.cy - py) < 14 for c, w in labs):
            v.decks[code] = float(py)          # R-S2b: a labelled deck drawn as a curve (camber / sheer) -> use the label's height
        elif code in DERIVED and len(_lab_codes) >= 3:
            # R-S6d (Rule 5: UPP-A tier missing in every full section): a derived deck (UPP, height = A - written DECK HEIGHT) without a
            # label in the view is the long near-horizontal line (slope < 3 %, >= 40 % of the view width) within 14 pt of its height;
            # its Z is measured there (camber), never assumed
            x0r, _, x1r, _ = v.region
            cand = []
            rows_ = defaultdict(float)
            for q in page.segs:          # collinear pieces (a deck line broken by hatching / brackets) count together
                dx, dy = abs(q.b[0] - q.a[0]), abs(q.b[1] - q.a[1])
                if q.dash or dx < 2 or dy > 0.03 * dx or not (x0r - 50 < min(q.a[0], q.b[0]) and max(q.a[0], q.b[0]) < x1r + 50):
                    continue
                ym = (q.a[1] + q.b[1]) / 2
                if abs(ym - py) < 14:
                    rows_[round(ym)] += dx
            for yk, L_ in rows_.items():
                if L_ >= 0.4 * (x1r - x0r) and all(abs(yk - y2) > 3 for c2, y2 in v.decks.items() if c2 != code):
                    cand.append((abs(yk - py), float(yk)))
            if cand:
                ym = min(cand)[1]
                v.decks[code] = float(ym)
                v.zov[code] = round((v.yz0 - ym) * v.k)
                v.evidence.setdefault('measured_decks', {})[code] = v.zov[code]
            v.evidence.setdefault('curved_decks', []).append(code)
    if printed:
        for c, w in labs:
            if c in DERIVED:
                y = _line_y(w)
                if y is not None:
                    v.decks[c] = float(y)
                    v.zov[c] = round((v.yz0 - y) * v.k)
                    v.evidence.setdefault('measured_decks', {})[c] = v.zov[c]
    v.evidence['decks'] = sorted(v.decks)
    v.evidence['deck_labels_agree'] = best[0]
    if len(v.decks) < 2:
        raise ValueError(f'{v.name}: fewer than two deck lines located')
    return v


def _tiers(v, deck_z):
    """consecutive located decks (by height) with no known deck between them"""
    z_ = lambda c: v.zov.get(c, deck_z[c])
    codes = sorted(v.decks, key=z_)
    allz = sorted(deck_z.values())
    out = []
    for lo, hi in zip(codes, codes[1:]):
        if 1200 < z_(hi) - z_(lo) < TIER_MAX:
            out.append((lo, hi, v.decks[lo], v.decks[hi]))
    return out


def _cl_from_dims(page, v, tiers):
    """R-S3b: the dimension row 'nnnn OFF C.L' under a symmetric full-width section: equal values left and right of the centre line are
    mirror images, so the centre line is the mean x of such pairs (the labels sit between the extension lines, not on the walls)."""
    x0, y0, x1, y1 = v.region
    ybot = max(t[2] for t in tiers)
    labs = []
    for w in page.words:
        if w.vertical or not re.fullmatch(r'\d{3,5}', w.text.strip()) or not (x0 < w.cx < x1 and ybot < w.cy < ybot + 260):
            continue
        if any(u.text.strip().upper().startswith('OFF') and abs(u.cx - w.cx) < 25 and 3 < u.cy - w.cy < 22 for u in page.words):
            labs.append((w.cx, float(w.text), round(w.cy / 4)))
    if not labs:
        return None
    row = Counter(l[2] for l in labs).most_common(1)[0][0]
    labs = [(a, b) for a, b, c in labs if abs(c - row) <= 1]
    by = defaultdict(list)
    for xx, val in labs:
        by[val].append(xx)
    mids = []
    for val, xs in by.items():
        xs = sorted(xs)
        if len(xs) == 2 and xs[1] - xs[0] > 30:
            mids.append((xs[0] + xs[1]) / 2)
    if len(mids) < 2:
        return None
    mids.sort()
    med = mids[len(mids) // 2]
    ok = [m for m in mids if abs(m - med) < 4.0]
    if len(ok) < 2 or len(ok) < 0.7 * len(mids):
        return None
    return sum(ok) / len(ok), len(ok)


def _no_cl(page, v):
    """no centre-line mark (the C.L symbol / 'C.L' text) inside the view window = a part view"""
    x0, y0, x1, y1 = v.region
    return not any(re.fullmatch(r'\s*(C\.?\s*L\.?|\u2104)\s*', w.text) and x0 < w.cx < x1 and y0 < w.cy < y1 for w in page.words)


def locate_cl(page, v, tiers, wall_ys):
    """R-S3. Returns the verticals per tier and sets v.xcl / v.s."""
    x0, y0, x1, y1 = v.region
    gathered = {}
    allx = []
    dim = None if v.side else _cl_from_dims(page, v, tiers)
    for lo, hi, yb, yt in tiers:
        H = yb - yt
        vs = [s for s in page.segs if s.vertical and not s.dash and s.length > 1.0 and x0 < s.a[0] < x1
              and yt - 14 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < yb + 14]
        for s in page.segs:      # R-S15 (= R-E8 for sections, found by Rule 5 on FR.19+1/2): a wall line drawn through several tiers is cut per tier
            if s.vertical and not s.dash and s.length > 1.0 and x0 < s.a[0] < x1:
                ya_, yb_ = min(s.a[1], s.b[1]), max(s.a[1], s.b[1])
                if (ya_ < yt - 14 or yb_ > yb + 14) and ya_ < yb - 0.5 * H and yb_ > yt + 0.5 * H:
                    c = copy.copy(s)
                    c.a, c.b = (s.a[0], max(ya_, yt)), (s.b[0], min(yb_, yb))
                    vs.append(c)
        lines = []
        for x, ya, yb2, w in _merge_vertical(vs):
            if ya > yt + 0.9 * H or yb2 < yb - 0.9 * H or (yb2 - ya) < 0.2 * H:
                continue
            lines.append({'x': x, 'y0': ya, 'y1': yb2, 'w': w, 'full': (yb2 - ya) >= 0.7 * H and ya <= yt + 0.25 * H})
        gathered[(lo, hi)] = lines
        allx += [l['x'] for l in lines if l['full']]
    if dim:
        # refine: shift the dimension-row centre (+-4 pt) so that most heavy full-height lines fall on known OFF C.L values (R-S3)
        wsl = sorted(set(list(wall_ys)))
        xs = sorted(set(round(x, 1) for x in allx))
        BIAS = 2.1                      # the label pairs sit about 2 pt (70 mm) off the true centre line on every 1005 section
        best = (-1, 0.0)
        for i in range(-12, 13):
            d_ = BIAS + i * 0.25
            hit = sum(1 for x in xs if wsl and min(abs(abs((x - dim[0] - d_) * v.k) - w) for w in wsl) < 30)
            key = (hit, -abs(d_ - BIAS))
            if key > (best[0], -abs(best[1] - BIAS)):
                best = (hit, d_)
        v.xcl, v.s = dim[0] + best[1], -1
        v.evidence['cl_hits'] = f'dimension row ({dim[1]} symmetric pairs), refined {best[1]:+.2f} pt ({best[0]} wall lines)'
        return gathered
    # R-V23: lines labelled by their own dimension ('2665 OFF C.L', '18665 OFF C.L' printed above the section, the text sits up to ~30 pt left of
    # its line) fix the centre line directly: choose the line pair whose spacing equals the dimension difference
    x0_, y0_, x1_, y1_ = v.region
    labv = []
    for w_ in page.words:
        if w_.vertical or not re.fullmatch(r'\d{3,5}', w_.text.strip()) or not (x0_ < w_.cx < x1_ and y0_ < w_.cy < y0_ + 90):
            continue
        if any(u.text.replace(' ', '').upper().startswith('OFFC') and abs(u.cx - w_.cx) < 25 and 3 < u.cy - w_.cy < 22 for u in page.words):
            labv.append((float(w_.text), w_.cx))
    labv.sort()
    if len(labv) >= 2:
        (va, ca), (vb, cb) = labv[0], labv[-1]
        sgn = -1 if v.side != 'P' else 1
        cand_a = [x for x in allx if -40 < x - ca < 40]
        cand_b = [x for x in allx if -40 < x - cb < 40]
        best_ = None
        for xa in cand_a:
            for xb in cand_b:
                err = abs(abs(xb - xa) - (vb - va) / v.k)
                if err < 4.0 and (best_ is None or err < best_[0]):
                    best_ = (err, xa, xb)
        if not best_:      # R-V23b: the labelled walls may be drawn dashed (hidden) in a deck-top frame view
            _yt = min(t[3] for t in tiers)
            _yb = max(t[2] for t in tiers)
            dx = sorted({round(sg.a[0], 1) for sg in page.segs if sg.vertical and sg.dash and sg.length > 1.0 and x0_ < sg.a[0] < x1_
                         and _yt - 14 < min(sg.a[1], sg.b[1]) and max(sg.a[1], sg.b[1]) < _yb + 14})
            for xa in [x for x in dx if -40 < x - ca < 40]:
                for xb in [x for x in dx if -40 < x - cb < 40]:
                    err = abs(abs(xb - xa) - (vb - va) / v.k)
                    if err < 4.0 and (best_ is None or err < best_[0]):
                        best_ = (err, xa, xb)
        if best_:
            _, xa, xb = best_
            s_ = int(sgn * (1 if xb > xa else -1))
            v.xcl, v.s = xa - sgn * va / (s_ * v.k), s_
            v.evidence['cl_hits'] = 'labelled OFF C.L lines %g / %g at x %.1f / %.1f' % (va, vb, xa, xb)
            v.span = (va, vb)      # R-FW1: a partial-width frame view (8525 .. 18665): the web plate spans exactly the labelled pair
            return gathered
    if dim is None:
        # R-S10: a part view (no centre line drawn, e.g. one room at the ship side) is placed by its own OFF C.L dimension row under it:
        # each value stands at its extension line; two values give the scale check and the centre line. All sections are drawn looking
        # forward (port on the left): |Y| falling to the right = port side, rising to the right = starboard side.
        ybot = max(t[2] for t in tiers)
        pts = []
        for w_ in page.words:
            if w_.vertical or not re.fullmatch(r'\d{3,5}', w_.text.strip()) or not (x0_ < w_.cx < min(x1_ + 160, v.xlab) and ybot < w_.cy < ybot + 120):
                continue
            if not any(u.text.replace(' ', '').upper().startswith('OFFC') and abs(u.cx - w_.cx) < 25 and 3 < u.cy - w_.cy < 22 for u in page.words):
                continue
            ext = [sg.a[0] for sg in page.segs if sg.vertical and not sg.dash and min(sg.a[1], sg.b[1]) - 2 < w_.cy < max(sg.a[1], sg.b[1]) + 2
                   and w_.bbox[0] - 30 < sg.a[0] < w_.bbox[2] + 30]
            if ext:
                pts.append((float(w_.text), min(ext, key=lambda x: abs(x - w_.bbox[0]))))
        pts = sorted(set(pts), key=lambda q: q[1])
        if len(pts) >= 2 and pts[0][0] != pts[-1][0]:
            (va, xa), (vb, xb) = pts[0], pts[-1]
            rate = (vb - va) / (xb - xa)
            sd_ = 'P' if rate < 0 else 'S'
            mono = all(abs((q2[0] - q1[0]) / (q2[1] - q1[1]) - rate) < 0.06 * v.k for q1, q2 in zip(pts, pts[1:]) if q2[1] - q1[1] > 5)
            if abs(abs(rate) - v.k) < 0.06 * v.k and mono and v.side in ('', sd_) and _no_cl(page, v):
                v.s = -1
                v.xcl = xa + va / v.k if sd_ == 'P' else xa - va / v.k
                v.side = sd_
                v.part = True              # the panel runs between the inner and outer full-height wall lines of the view
                v.evidence['cl_hits'] = f'R-S10 part view placed by its OFF C.L row {va:g} / {vb:g} at x {xa:.1f} / {xb:.1f} ({sd_} side, looking forward)'
                return gathered
            elif abs(abs(rate) - v.k) >= 0.06 * v.k:
                v.evidence['R-S10'] = f'OFF C.L row {va:g}/{vb:g} does not fit the sheet scale ({abs(rate):.2f} vs {v.k:.2f} mm/pt)'
    if len(allx) < 2:
        raise ValueError(f'{v.name}: too few full-height vertical lines to locate the centre line')
    ws = sorted(set(list(wall_ys) + [0.0]))
    allx = sorted(set(round(x, 1) for x in allx))
    best = None
    side = v.side
    for s in (-1, 1):
        for xi in allx:
            for wy in ws:
                for sg in ((1, -1) if wy else (1,)):
                    xcl = xi - s * (sg * wy) / v.k     # xi has Y = sg*wy
                    ys = [s * (x - xcl) * v.k for x in allx]
                    if side == 'P' and sum(1 for y in ys if y < -150) > 0.15 * len(ys):
                        continue
                    if side == 'S' and sum(1 for y in ys if y > 150) > 0.15 * len(ys):
                        continue
                    if not side and not (min(allx) < xcl < max(allx)):
                        continue        # R-S14 (found by Rule 5: FR.21 placed 33 m off): a full section has its centre line between its outer lines
                    hit = sum(1 for y in ys if min(abs(abs(y) - w) for w in ws) < 40)
                    sym = sum(1 for y in ys if any(abs(y + y2) < 40 for y2 in ys)) if not side else 0
                    # prefer the standard orientation (port left), mirrored pairs (both sides drawn) for full views
                    key = (hit + sym, s == -1)
                    if best is None or key > best[0]:
                        best = (key, xcl, s)
    if best is None:
        raise ValueError(f'{v.name}: no centre line between the outer lines fits the known OFF C.L values')
    (hit, _), v.xcl, v.s = best
    v.evidence['cl_hits'] = f'{hit}/{len(allx)} (incl. mirrored pairs)'
    if hit < min(3, len(allx)):
        raise ValueError(f'{v.name}: wall lines do not fit the known OFF C.L values ({hit} hits)')
    return gathered


def _slanted(page, v, yt, yb, x0, x1):
    """R-S7 (owner Q5): a slanted outer wall is an oblique line spanning the tier; its ends at the two deck lines give the
    wall's Y at the lower and upper deck (distance deck to deck).  Returns [(x_at_top, x_at_bottom)] in page x."""
    H = yb - yt
    out = []
    for sg in page.segs:
        (xa, ya), (xb, yb2) = sg.a, sg.b
        if abs(yb2 - ya) < 0.8 * H or not (x0 < min(xa, xb) and max(xa, xb) < x1):
            continue
        slope = abs(xb - xa) / abs(yb2 - ya)
        if not (0.015 < slope < 0.5):
            continue
        if min(ya, yb2) > yt + 0.25 * H or max(ya, yb2) < yb - 0.25 * H:
            continue
        t = (yt - ya) / (yb2 - ya)
        b = (yb - ya) / (yb2 - ya)
        out.append((xa + t * (xb - xa), xa + b * (xb - xa)))
    return out


def _bmark(page, l, v):
    """R-B1 on sections: 'B' printed within 14 pt of the stiffener's lower / upper end"""
    out = {'lo': False, 'hi': False}
    for w in page.words:
        if w.text.strip() == 'B' and w.size < 12 and not w.vertical and abs(w.cx - l['x']) < 14:
            if abs(w.cy - l['y1']) < 14:
                out['lo'] = True
                out['size_lo'] = callout_near(page, w)
            elif abs(w.cy - l['y0']) < 14:
                out['hi'] = True
                out['size_hi'] = callout_near(page, w)
    for c, tip, W, T in callout_tips(page):          # R-B4: a callout leader whose tip lands on the upper end = bracket (size from the callout)
        if abs(tip[0] - l['x']) < 26 and abs(tip[1] - l['y0']) < 30 and not out.get('size_hi'):
            out['hi'] = True
            out['size_hi'] = (W, T)
    for e in ('hi', 'lo'):      # R-DT (sections): no callout -> typical size of the page's bracket table / views, else flagged UNKNOWN (never a silent default)
        if out[e]:
            if out.get('size_' + e):
                out['src_' + e] = 'callout'
            else:
                from . import details as _dt
                ty = _dt.page_typical(page)
                if ty:
                    out['size_' + e] = ty
                    out['src_' + e] = 'typical mark on page'
                else:
                    out['src_' + e] = 'size UNKNOWN, default'
    return out


def Y(v, px):
    return v.s * (px - v.xcl) * v.k


def Z(v, py):
    return (v.yz0 - py) * v.k


_VSEC = re.compile(r'^\s*\d{2,4}\s*X\s*\d{2,3}(?:\s*X\s*\d+(?:\s*/\s*\d+)?)?\s*[A-Z]\.?\s*[A-Z]?\.?\s*$', re.I)


def _auto_dashed(page, v):
    """R-S5c: a frame section whose stiffeners are drawn DASHED (members on the far side, EC FR.19+800 SEC.) is recognised by its vertical size labels
    ('200X90X10/14 I.A') each running along a dashed vertical line: >= 3 such labels switch the dashed-vertical reading on for this view."""
    x0, y0, x1, y1 = v.region
    dv = [q for q in page.segs if q.vertical and q.dash and q.length > 8 and x0 < q.a[0] < x1 and y0 < min(q.a[1], q.b[1]) and max(q.a[1], q.b[1]) < y1]
    n = 0
    for w in page.words:
        if w.vertical and _VSEC.match(w.text) and x0 < w.cx < x1 and y0 < w.cy < y1:
            if any(abs(q.a[0] - w.cx) < 14 and min(q.a[1], q.b[1]) - 5 < w.cy < max(q.a[1], q.b[1]) + 5 for q in dv):
                n += 1
    if n >= 3:
        v.evidence['dashed_stiffeners'] = f'auto: {n} vertical size labels along dashed verticals (R-S5c)'
    return n >= 3


def extract(page, v, deck_z, settings, wall_ys, sheet=None):
    sheet = sheet if sheet is not None else members.sheet_sizes(page)
    aliases = settings.get('section_aliases', {})
    notes_sec = members.parse_section(v.notes.get('stiff', '')) if v.notes.get('stiff') else None
    default_t = float(v.notes['plate']) if v.notes.get('plate') else None
    tiers = _tiers(v, deck_z)
    if not tiers:
        raise ValueError(f'{v.name}: no consecutive deck pair')
    gathered = locate_cl(page, v, tiers, wall_ys)
    x0, y0, x1, y1 = v.region
    small_all = [s for s in page.segs if s.length < 9 and x0 < s.a[0] < x1 and y0 < s.a[1] < y1]
    ws = sorted(set(list(wall_ys) + [0.0]))
    panels = []
    _dashed = settings.get('section_dashed_stiffeners', False) or _auto_dashed(page, v)      # R-S5c
    for lo, hi, yb, yt in tiers:
        H = yb - yt
        Zb, Zt = v.zov.get(lo, deck_z[lo]), v.zov.get(hi, deck_z[hi])
        lines = gathered[(lo, hi)]
        if _dashed:     # R-S5b: a dashed vertical = member on the FAR side (web forward, +X)
            dv = [s for s in page.segs if s.vertical and s.dash and s.length > 1.0 and x0 < s.a[0] < x1
                  and yt - 14 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < yb + 14]
            for s in page.segs:       # R-S15: a dashed stiffener drawn through several tiers is cut per tier
                if s.vertical and s.dash and s.length > 1.0 and x0 < s.a[0] < x1:
                    ya_, yb_ = min(s.a[1], s.b[1]), max(s.a[1], s.b[1])
                    if (ya_ < yt - 14 or yb_ > yb + 14) and ya_ < yb - 0.5 * H and yb_ > yt + 0.5 * H:
                        c_ = copy.copy(s)
                        c_.a, c_.b = (s.a[0], max(ya_, yt)), (s.b[0], min(yb_, yb))
                        c_.through = (ya_, yb_)          # the whole drawn line: its end markers / labels count for every tier
                        dv.append(c_)
            thr = {round(q.a[0], 1): q.through for q in dv if getattr(q, 'through', None)}
            for x, ya, yb2, w in _merge_vertical(dv, gap=7.0):
                if (yb2 - ya) < 0.2 * H or any(abs(x - l['x']) < 1.2 and l['y0'] - 2 <= ya and yb2 <= l['y1'] + 2 for l in lines):
                    continue
                th = next((t for k_, t in thr.items() if abs(k_ - x) < 0.8), None)
                lines.append({'x': x, 'y0': ya, 'y1': yb2, 'w': w, 'full': (yb2 - ya) >= 0.7 * H and ya <= yt + 0.25 * H,
                              'far': True, 'through': th})
        for l in lines:
            l['m'] = _marker_count(small_all, l['x'], l['y0'], l['y1'])
            if l.get('through'):              # R-S15b: a dashed stiffener running through several decks: markers of the whole line count
                l['m'] = max(l['m'], _marker_count(small_all, l['x'], l['through'][0], l['through'][1]))
            l['Y'] = Y(v, l['x'])
        for sd in ('P', 'S'):
            if v.side and v.side != sd:
                continue
            sg = 1 if sd == 'P' else -1
            side_l = [l for l in lines if sg * l['Y'] > CL_GAP - 40]
            full = [l for l in side_l if l['full'] and sg * l['Y'] < max(ws) + 40]
            slant = None
            sl = [(Y(v, xt), Y(v, xbm)) for xt, xbm in _slanted(page, v, yt, yb, x0, x1)]
            sl = [q for q in sl if sg * q[0] > 1000 and sg * q[1] > 1000]
            if sl:
                slant = max(sl, key=lambda q: abs(q[0]) + abs(q[1]))
            _span = getattr(v, 'span', None)
            if _span and _span[0] > 1000 and v.side == sd:
                side_l = [l for l in lines if _span[0] - 60 < sg * l['Y'] < _span[1] + 60]
                slant = None
                full = [l for l in side_l if l['full']]
                ext = _span[1]
            else:
                _span = None
            if not full and not slant and _span is None:
                continue
            if _span is None:
                ext = max(sg * l['Y'] for l in full) if full else max(sg * slant[0], sg * slant[1])
            if _span is None and slant and (not full or max(abs(slant[0]), abs(slant[1])) > ext + 40):
                ext = max(sg * slant[0], sg * slant[1])
            else:
                slant = None
            if ext < 1000:
                continue
            ext = min(ws, key=lambda w: abs(w - ext)) if min(abs(w - ext) for w in ws) < 40 else round(ext / 5) * 5
            st = []
            for l in side_l:
                if sg * l['Y'] > ext + 40:
                    continue
                lab = _label_for(page.words, l['x'], l['y0'], l['y1'])
                if l['m'] < MARK_MIN and not l['full']:
                    continue
                if l['full'] and l['m'] < STIFF_MARKERS:
                    # R-S17 (Rule 5: near-side stiffeners drawn SOLID through several decks were taken as walls): a full-height solid line
                    # inside the bulkhead is a stiffener when it carries stiffener evidence (a size / carling label beside it, or end marks)
                    # and no OFF C.L elevation / deck plan / wall arrangement shows a wall standing at that Y.
                    from . import crossverify as _xv
                    inner = sg * l['Y'] < ext - 40
                    evid = bool(lab) or l['m'] >= 1 or any(w.text.strip() in ('B',) or re.fullmatch(r'#\d', w.text.strip())
                                                         for w in page.words if abs(w.cx - l['x']) < 10 and l['y0'] < w.cy < l['y1'])
                    wl = _xv.wall_at('x', l['Y'], deck_z[lo], deck_z[hi], X=v.X, codes=(lo, hi))
                    if not (inner and evid and wl is False):
                        continue
                    l['_rs17'] = True
                if lab and re.fullmatch(r'#\d', lab.text.strip()):
                    # R-TB2: carling mark '#1' / '#3' in a section = the sheet's carling table entry (own page first, then the sheet note 6)
                    sec = (members.carling_table(page) or {}).get(lab.text.strip()) or members.GLOBAL_CARL.get(lab.text.strip())
                    src = 'carling mark ' + lab.text.strip() + (' -> %s' % (sec,) if sec else ' (not in any carling table)')
                elif lab:
                    mm = members.SEC.search(lab.text)
                    sec = members.parse_section(lab.text, aliases)
                    src = 'label ' + lab.text.strip()
                    if sec is None and mm:
                        sec, src2 = _resolve_short(int(mm.group('h')), mm.group('k'), notes_sec, aliases, sheet)
                        src += ' -> ' + src2
                else:
                    sec, src = notes_sec, 'title default'
                    _tn = _tier_note(page, v, lo, hi, aliases)
                    if _tn:
                        sec, src = _tn
                    # R-ST1: a stiffener mark beside the line ('$4', vertical or horizontal text) -> the drawing's mark table
                    _tab = members.mark_table(getattr(page, 'src', ''))
                    _mk = [w for w in page.words if _tab and members.MARK_TOKEN.match(w.text) and abs(w.cx - l['x']) < 10
                           and l['y0'] - 3 < w.cy < l['y1'] + 3 and members.MARK_TOKEN.match(w.text).group(1) in _tab]
                    if _mk:
                        _k = members.MARK_TOKEN.match(min(_mk, key=lambda w: abs(w.cx - l['x'])).text).group(1)
                        sec, src = _tab[_k][0], f'mark {_k} beside the line -> table {_tab[_k][1]} (R-ST1)'
                if sec is None and lab and re.fullmatch(r'#\d', lab.text.strip()):
                    _tab = members.mark_table(getattr(page, 'src', ''))
                    if lab.text.strip() in _tab:
                        sec, src = _tab[lab.text.strip()][0], src + f'; mark table {_tab[lab.text.strip()][1]} (R-ST1)'
                partial = not l['full']
                a_z, b_z = (Z(v, l['y1']), Z(v, l['y0'])) if partial else (Zb, Zt)
                a_z, b_z = max(Zb, min(Zt, a_z)), max(Zb, min(Zt, b_z))
                if abs(b_z - a_z) < 300:
                    continue
                st.append({'u': _snap(l['Y'], 5.0, 2.5), 'a_z': a_z, 'b_z': b_z, 'section': sec, 'far': bool(l.get('far')),
                           '_x': l['x'],
                           'bmark': _bmark(page, l, v),
                           'evidence': src + (' (partial)' if partial else '') + (' [dashed: far side]' if l.get('far') else '')
                           + (' [R-S17 solid through-deck line, no wall at this Y in any elevation / plan]' if l.get('_rs17') else '')})
            ts = []
            ahs = set()
            for w in page.words:
                m = THK.match(w.text.strip())
                if m and x0 < w.cx < x1 and yt < w.cy < yb and sg * Y(v, w.cx) > 0 and not w.vertical:
                    tab = [u for u in page.words if u is not w and abs(u.cx - w.cx) < 25 and 0 < u.cy - w.cy < 14
                           and re.search(r'FL\.|F\.B', u.text)]
                    if not tab:
                        ts.append(float(m.group(1)))
                        if m.group(2):
                            ahs.add(float(m.group(1)))
            if default_t and settings.get('section_title_default', True):
                t, tsrc = default_t, 'title default'
            elif ts:
                t, tsrc = Counter(ts).most_common(1)[0][0], 'note inside bulkhead'
            else:                                     # owner Q1: plate only where a thickness is printed
                t, tsrc = None, 'none'
            a, b = (CL_GAP, ext) if sd == 'P' else (-ext, -CL_GAP)
            if getattr(v, 'part', False) and full:      # R-S10: part view - between its inner and outer full-height wall lines
                inner = min(sg * l['Y'] for l in full)
                inner = min(ws, key=lambda w: abs(w - inner)) if min(abs(w - inner) for w in ws) < 40 else round(inner / 5) * 5
                if inner < ext - 300:
                    a, b = (inner, ext) if sd == 'P' else (-ext, -inner)
                    st = [q for q in st if inner - 40 <= sg * q['u'] <= ext + 40]
            if _span:
                a, b = (_span[0], _span[1]) if sd == 'P' else (-_span[1], -_span[0])
            if slant:        # outer edge slanted: its Y at the lower deck and at the upper deck
                ob = round(sg * slant[1] / 5) * 5 * sg
                ot = round(sg * slant[0] / 5) * 5 * sg
                poly = [(a, Zb), (ob, Zb), (ot, Zt), (a, Zt)] if sd == 'P' else [(ob, Zb), (b, Zb), (b, Zt), (ot, Zt)]
            else:
                poly = [(a, Zb), (b, Zb), (b, Zt), (a, Zt)]
            sub_ = getattr(v, 'sub', None)
            girders = []
            if sub_:
                # R-SS1: the girder inside the sub-title span (dimension line under the sub-title) belongs to the sub-title frame.
                # Its section is the horizontal 'F.B(T)' label of the view; it hangs under the deck (web top = deck, Zt) - R-CN5 members stop ON it.
                for sb in sub_:
                    w0 = sb['word']
                    dl = [g for g in page.segs if abs(g.a[1] - g.b[1]) < 1.5 and abs(g.b[0] - g.a[0]) > 30 and abs(g.a[1] - w0.cy) < 22
                          and x0 < min(g.a[0], g.b[0]) and max(g.a[0], g.b[0]) < x1 + 60]
                    gl = [w for w in page.words if not w.vertical and re.search(r'\d+X\d+\s*\+\s*\d+X\d+\s*F\.B\(T\)', w.text) and x0 < w.cx < x1 and yt - 220 < w.cy < yt + 80]
                    dl = [g for g in dl if min(g.a[0], g.b[0]) - 2 <= w0.cx <= max(g.a[0], g.b[0]) + 2]      # the dimension line that carries the sub-title text
                    if dl and gl:
                        dl = [max(dl, key=lambda g: abs(g.b[0] - g.a[0]))]
                        xa_ = min(min(g.a[0], g.b[0]) for g in dl); xb_ = max(max(g.a[0], g.b[0]) for g in dl)
                        ya_, yb_ = Y(v, xa_), Y(v, xb_)
                        ya_ = min(ws, key=lambda q: abs(sg * q - ya_)) * sg if min(abs(sg * q - ya_) for q in ws) < 120 else ya_
                        yb_ = 5185.0 * sg if abs(sg * 5185.0 - yb_) < 300 else yb_      # '6L' = NO.6 = 5185 OFF C.L (plan table 5185 / 8525 / 11825 / 15175 / 18665)
                        sec_g = members.parse_section(gl[0].text.replace('TYP.', '').strip(), aliases)
                        if sec_g:
                            from . import connect as _cn
                            _g = _cn.girder_at(sb['X'], ya_, yb_)
                            girders.append({'exists': _g,'x': sb['X'], 'y0': max(ya_, yb_), 'y1': min(ya_, yb_), 'section': sec_g, 'z_top': Zt,
                                            'name': sb['name'], 'evidence': 'R-SS1 girder in the span of %s: %s' % (sb['name'], gl[0].text.strip())})
            if sub_ and st:       # R-SS2: 'SLANTED' written along a wall: that member's TOP end is at the sub-title frame, its lower end at the main frame
                for w_ in page.words:
                    if w_.text.strip().upper() == 'SLANTED' and x0 < w_.cx < x1 and yt < w_.cy < yb and sg * Y(v, w_.cx) > 0:
                        Yw = Y(v, w_.cx)
                        c_ = min(st, key=lambda q: abs(q['u'] - Yw))
                        if abs(c_['u'] - Yw) < 1500 and c_['section']:
                            c_['slanted'] = {'x_top': sub_[0]['X'], 'name': sub_[0]['name']}
                            gg = [g for g in girders if min(g['y0'], g['y1']) - 60 <= c_['u'] <= max(g['y0'], g['y1']) + 60]
                            if gg:      # R-CN5: the slanted member STOPS ON the girder (flange face), not on the deck
                                gsec = gg[0]['section']
                                c_['b_z'] = gg[0]['exists']['z0'] if gg[0].get('exists') else (Zt - gsec[1] - gsec[4] / 2.0)
                                c_['a_z'] = min(c_['a_z'], c_['b_z'])
                                if gg[0].get('exists') and gg[0]['exists'].get('plane'):
                                    c_['slanted']['plane'] = gg[0]['exists']['plane']          # R-CN6: end cut follows the girder underside
                                c_['evidence'] += ' [R-CN5 top end stops on the girder flange face Z=%g, not on the deck]' % c_['b_z']
                            c_['evidence'] += ' [R-SS2 SLANTED: top end at %s X=%g, lower end at main frame X=%g]' % (sub_[0]['name'], sub_[0]['X'], v.X)
            # R-S16 (found by Rule 5 on FR.19+1/2): openings of the bulkhead = closed thin rounded / circular rings inside this side of the tier
            holes = []
            pxa, pxb = sorted((v.xcl + a / (v.s * v.k), v.xcl + b / (v.s * v.k)))
            rings = [q for q in page.segs if not q.dash and all(pxa - 1 < pt[0] < pxb + 1 and yt - 1 < pt[1] < yb + 1 for pt in (q.a, q.b))]
            tw = thin_weight(rings)
            from .deckplan import _circular
            for _, hp in closed_paths(rings, max_width=tw * 1.5 if tw else None):
                a_mm = hp.area * v.k * v.k
                if not (0.05e6 < a_mm < 0.6 * abs(b - a) * (Zt - Zb)):
                    continue
                if _circular(hp) or _rounded(hp):
                    holes.append([(_snap(Y(v, x), 50.0, 15.0), _snap(Z(v, y), 50.0, 15.0)) for x, y in list(hp.exterior.coords)[:-1]])
            panels.append({'name': f'{v.name}|{lo}-{hi}|{sd}', 'x': v.X, 'tier': (lo, hi), 'side': sd,
                           'poly': poly, 'grade': 'AH' if t in ahs else 'A', 't': t, 't_source': tsrc + ('; slanted wall (deck-to-deck)' if slant else ''),
                           'stiffeners': sorted(st, key=lambda s: s['u']), 'openings': holes, 'girders': girders})
    # R-S20: horizontal stiffeners of a horizontally stiffened bulkhead / web, named by a row-label column at the view edge
    if settings.get('section_row_stiffeners', True) and panels:
        _row_stiffeners(page, v, panels, notes_sec)
    # R-B4 (section): a bracket callout 'WxT' with a leader = a bracket at the leader tip (position from the drawing, size from the text)
    if settings.get('section_callout_brackets', False) and panels:    # off: only 7 of 19 matched the 1005 reference (typical details repeat across frames)
        for c, tip, W, T in callout_tips(page):
            if not (x0 < tip[0] < x1 and y0 < tip[1] < y1):
                continue
            Yt, Zt_ = Y(v, tip[0]), Z(v, tip[1])
            sd = 'P' if Yt > 0 else 'S'
            cand = [q for q in panels if q['side'] == sd and q['poly'][0][1] - 50 <= Zt_ <= max(pz[1] for pz in q['poly']) + 50]
            if cand:
                cand[0].setdefault('free_brackets', []).append({'u': Yt, 'z': Zt_, 'leg': W, 't': T, 'txt': c.text.strip()})
    return panels



TIER_NOTE = re.compile(r'^\s*STIFF\.?\s*:?\s*(.+?)\s*$', re.I)


def _tier_note(page, v, lo, hi, aliases):
    """R-ST2 [DRAWING] (1001 FR.19 / FR.28 sections): a vertical note 'STIFF. : 125X75X7 U.A' printed at the edge of the view, beside the band
    between two deck lines, gives the stiffener size of THAT tier; it replaces the title's 'STIFF. SIZE : 100X75X7 U.A (EXC. AS SHOWN)'
    for the members of the tier that carry no own label. Returns (section, evidence) or None."""
    try:
        ya, yb = sorted((v.decks[lo], v.decks[hi]))
    except Exception:
        return None
    x0, y0, x1, y1 = v.region
    best = None
    for w in page.words:
        if not w.vertical or not (x0 - 260 < w.cx < x1 + 260):
            continue
        m = TIER_NOTE.match(w.text)
        if not m or 'STIFF' not in w.text.upper():
            continue
        if not (ya - 5 < w.cy < yb + 5):
            continue
        sec = members.parse_section(m.group(1), aliases)
        if sec is None:
            continue
        d = 0.0 if x0 <= w.cx <= x1 else min(abs(w.cx - x0), abs(w.cx - x1))
        # the note belongs to the view whose region is nearest in x (neighbour views of the same band)
        if any(u is not v and u.region and ((0.0 if u.region[0] <= w.cx <= u.region[2] else min(abs(w.cx - u.region[0]), abs(w.cx - u.region[2]))) < d)
               and u.region[1] - 5 < w.cy < u.region[3] + 5 for u in getattr(v, '_peers', [])):
            continue
        if best is None or d < best[0]:
            best = (d, sec, w.text.strip())
    if best is None:
        return None
    return best[1], f'tier note "{best[2]}" beside the {lo}-{hi} band (R-ST2)'


ROWNUM = re.compile(r'^\s*(?:NO\.?\s*)?(\d{1,2})(?:-\d)?\s*(?:LONGL\.?)?\s*$')


def _row_stiffeners(page, v, panels, notes_sec):
    """R-S20 [DRAWING]: a column of longitudinal row numbers at the left or right edge of a section ('57', '56', '55' ... or
    'NO.57 LONGL.'), at least 3 numbers, decreasing downward, each at the end of a horizontal line, names horizontal stiffeners: every
    such line is a stiffener at its Z on each panel it crosses (>= 50 % of the panel width drawn at that height); section = a size
    label on the line, else the title default ('STIFF. : 150X11 F.B EXC. AS SHOWN'); dashed line = far side."""
    x0, y0, x1, y1 = v.region
    cand = [w for w in page.words if not w.vertical and w.size < 10 and ROWNUM.match(w.text) and y0 < w.cy < y1
            and (x0 - 120 < w.cx < x0 + 0.25 * (x1 - x0) or x1 - 0.25 * (x1 - x0) < w.cx < x1 + 160)]
    cols = defaultdict(list)
    for w in cand:
        cols[round(w.cx / 15)].append(w)
    labs = []
    for ws in cols.values():
        ws = sorted(ws, key=lambda w: w.cy)
        nums = [int(ROWNUM.match(w.text).group(1)) for w in ws]
        if len(ws) >= 3 and sum(1 for a_, b_ in zip(nums, nums[1:]) if b_ <= a_) >= 0.8 * (len(nums) - 1):
            labs += ws
    if not labs:
        return
    v.evidence['row_labels'] = len(labs)
    for w in labs:
        hs = [q for q in page.segs if q.horizontal and abs(q.a[1] - w.cy) < 4.0 and q.length > 1.0]
        if not hs:
            continue
        yv = statistics.median(q.a[1] for q in hs)
        hs = [q for q in hs if abs(q.a[1] - yv) < 1.0]
        z = Z(v, yv)
        for p in panels:
            zs = [pz for _, pz in p['poly']]
            if not (min(zs) + 50 < z < max(zs) - 50):
                continue
            us = [pu for pu, _ in p['poly']]
            ua, ub = min(us), max(us)
            pxa, pxb = sorted((v.xcl + ua / (v.s * v.k), v.xcl + ub / (v.s * v.k)))
            iv = sorted((max(pxa, min(q.a[0], q.b[0])), min(pxb, max(q.a[0], q.b[0])), q.dash) for q in hs)
            iv = [t_ for t_ in iv if t_[1] > t_[0]]
            cov = sum(b_ - a_ for a_, b_, _ in iv)
            if cov < 0.5 * (pxb - pxa):
                continue
            far = sum(b_ - a_ for a_, b_, d_ in iv if d_) > 0.5 * cov
            if any(abs(h['z'] - z) < 60 for h in p.get('hstiff', [])):
                continue
            sec_, src_ = _mark_on_line(page, yv, pxa, pxb)
            if sec_ is None:
                sec_, src_ = notes_sec, 'section title default'
            p.setdefault('hstiff', []).append({'z': round(z), 'u0': ua, 'u1': ub, 'section': sec_, 'far': far,
                                               'evidence': f'R-S20 row label "{w.text.strip()}" at the line end; {src_}'})


def _mark_on_line(page, yv, xa, xb):
    """R-ST1: a stiffener mark ('$3', '#6 "AH"') written on / just above a horizontal line between xa and xb -> (section, evidence)
    from the drawing's mark table; the most frequent mark on the line wins. (None, '') when none."""
    tab = members.mark_table(getattr(page, 'src', ''))
    if not tab:
        return None, ''
    ms = Counter()
    for w in page.words:
        m = members.MARK_TOKEN.match(w.text)
        if m and not w.vertical and xa < w.cx < xb and -2 < yv - w.bbox[3] < 6 and m.group(1) in tab:
            ms[m.group(1)] += 1
    if not ms:
        return None, ''
    mk = ms.most_common(1)[0][0]
    return tab[mk][0], f'mark {mk} on the line -> table {tab[mk][1]} (p{tab[mk][2]}, R-ST1)'


def _write_slanted(ship, blk, pid, n, p, s):
    """R-SS2: member on the OFF C.L wall (plane Y = u) running from the main frame X at its lower end to the sub-title frame X at its top end.
    Web perpendicular to the wall plane, 450 deep toward the centre of the room (-Y at the 2665 wall) = the band the section draws (T web reading to be confirmed by the owner)."""
    import xml.etree.ElementTree as ET
    from .export import _trace, _xyz, _f, bar_id, BAR_TYPE, _crossection, add_web_flange
    bid, tag, attrs = bar_id(s['section'])
    if not any(b.get('BarSectionId') == bid for b in ship.findall('BarSection')):
        bsx = ET.Element('BarSection', BarSectionId=bid); ET.SubElement(bsx, tag, **attrs); ship.insert(1, bsx)
    u = s['u']
    wp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-SLANT{n}', Tightness='NonTight')
    cs = ET.SubElement(wp, 'CoordSys')
    _xyz(cs, 'Origin', 0, u, 0); _xyz(cs, 'Waxis', 0, -1, 0); _xyz(cs, 'Uaxis', 1, 0, 0)
    sg = ET.SubElement(wp, 'StiffenerGroup', GroupId='1', BendType='Straight')
    mat = ET.SubElement(sg, 'Material', Grade='A')
    bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
    ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in s['section'][1:])
    _crossection(bs, tag, attrs)
    lo, hi = sorted((s['a_z'], s['b_z']))
    xb, xt = p['x'], s['slanted']['x_top']
    pl_ = s['slanted'].get('plane')
    if pl_:                                         # R-CN6: top end stops exactly ON the surface (no gap): trace end on the plane at the member line
        n_ = pl_[0]; hi = (pl_[1] - n_[0] * xt - n_[1] * u) / n_[2]
    st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}-SLANT{n}/S1', Kind='frame stiffener (slanted)', Evidence=s['evidence'][:300])
    _trace(st, (xb, lo), (xt, hi))
    inc = ET.SubElement(st, 'Inclination')
    wsign = 1.0 if u < 0 else -1.0          # web toward the room: -Y at the 2665 wall (u<0), +Y at +Y walls
    for _ in range(2):
        ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(wsign))
    add_web_flange(st, (xb, u, lo), (xt, u, hi), (0.0, -wsign, 0.0), s['section'], end_plane=pl_)


def write(path, panels, settings):
    import xml.etree.ElementTree as ET
    from .export import _contour, _trace, _xyz, _f, bar_id, BAR_TYPE, _crossection, add_web_flange
    ship = ET.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine',
                      Source='deckrules frame sections (PDF drawing only)')
    ET.SubElement(ship, 'Material', Grade='A')
    used = {}
    for p in panels:
        for s in p['stiffeners'] + p.get('hstiff', []):
            if s['section']:
                bid, tag, attrs = bar_id(s['section'])
                used[bid] = (tag, attrs)
    for bid, (tag, attrs) in sorted(used.items()):
        bs = ET.SubElement(ship, 'BarSection', BarSectionId=bid)
        ET.SubElement(bs, tag, **attrs)
    blocks = {}
    seen = Counter()
    for p in panels:
        bname = f"PDF-FR{int(round(p['x']))}"
        blk = blocks.get(bname) or blocks.setdefault(bname, ET.SubElement(ship, 'Block', ObjId=bname))
        seen[(bname, p['tier'], p['side'])] += 1
        pid = f"{bname}-{p['tier'][0]}{p['tier'][1]}{p['side']}{seen[(bname, p['tier'], p['side'])]}"
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=pid, Tightness='NonTight')
        cs = ET.SubElement(pp, 'CoordSys')
        _xyz(cs, 'Origin', p['x'], 0, 0)
        _xyz(cs, 'Waxis', 1, 0, 0)
        _xyz(cs, 'Uaxis', 0, 1, 0)
        bd = ET.SubElement(pp, 'Boundary')
        _contour(bd, 'SimpleContour', p['poly'])
        gid = 1
        if p['t']:        # R-S6 (owner, Q1): a plate exists only where a thickness is printed; else stiffeners only
            pg = ET.SubElement(pp, 'PlateGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(pg, 'Material', Grade=p.get('grade', 'A'))
            ET.SubElement(mat, 'Thickness').text = f"{p['t']:g}"
            pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{pid}-P1', Source=p['t_source'])
            _contour(pl, 'SimpleContour', p['poly'])
        else:
            pp.set('Note', 'stiffeners only (no thickness printed)')
        if p.get('openings'):
            hg = ET.SubElement(pp, 'HoleGroup', GroupId=str(gid))
            gid += 1
            for j, h in enumerate(p['openings'], 1):
                hh = ET.SubElement(hg, 'Hole', CompId=str(j))
                _contour(hh, 'Contour', h)
        n = 0
        for s in p.get('hstiff', []):            # R-S20 horizontal stiffeners
            _pu = [pu for pu, _ in p['poly']]
            s['u0'], s['u1'] = max(s['u0'], min(_pu)), min(s['u1'], max(_pu))      # the panel may have been cut back (R-XV4b)
            if s['u1'] - s['u0'] < 100:
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
            st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/H{n}', Kind='frame horizontal stiffener', Evidence=s['evidence'][:300])
            _trace(st, (s['u0'], s['z']), (s['u1'], s['z']))
            w = 1.0 if s.get('far') else -1.0
            inc = ET.SubElement(st, 'Inclination')
            for _ in range(2):
                ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(w))
            add_web_flange(st, (p['x'], s['u0'], s['z']), (p['x'], s['u1'], s['z']), (w, 0, 0), s['section'])
        for s in p['stiffeners']:
            if not s['section']:
                continue
            n += 1
            if s.get('slanted'):          # R-SS2: slanted member in the OFF C.L wall plane, top at the sub-title frame, lower end at the main frame
                _write_slanted(ship, blk, pid, n, p, s)
                continue
            bid, tag, attrs = bar_id(s['section'])
            sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight')
            gid += 1
            mat = ET.SubElement(sg, 'Material', Grade='A')
            bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
            ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in s['section'][1:])
            _crossection(bs, tag, attrs)
            st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/S{n}', Kind='frame stiffener',
                               Evidence=s['evidence'][:300])
            lo, hi = sorted((s['a_z'], s['b_z']))
            from . import connect                     # R-CN1: stand at the Y of the deck longitudinal that crosses this frame, up to its deck
            _cn = connect.frame_y(p['x'], s['u'], hi) if connect.TABLE['beams'] else None
            if _cn is not None:
                s['u'] = _cn[0]
                hi = _cn[1] if abs(_cn[2] - hi) <= 150 else hi
                s['_conn'] = True
            _trace(st, (s['u'], lo), (s['u'], hi))
            w = 1.0 if s.get('far') else -1.0   # R-S5b (owner Q2, old visibility rule): solid = near side = web toward the viewer (aft, -X); dashed = far side (+X)
            inc = ET.SubElement(st, 'Inclination')
            for _ in range(2):
                ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(w))
            add_web_flange(st, (p['x'], s['u'], lo), (p['x'], s['u'], hi), (w, 0, 0), s['section'])
            bm = s.get('bmark') or {}
            if settings.get('section_brackets', True) and bm.get('hi') and not s.get('_conn'):      # R-B2/B3 (section): bracket at the upper end, in the frame plane
                sz = bm.get('size_hi')
                src = bm.get('src_hi', 'size UNKNOWN, default')
                leg, bt = (sz[0], sz[1]) if sz else (float(settings.get('bracket_leg_mm', 200.0)), float(settings.get('bracket_thk_mm', 8.0)))
                if hi - lo >= 2 * leg * 0.6:
                    drop = float(settings.get('bracket_drop_mm', 250.0))
                    bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
                    gid += 1
                    mat = ET.SubElement(bg, 'Material', Grade='A')
                    ET.SubElement(mat, 'Thickness').text = f"{bt:g}"
                    br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{pid}/B{n}', Source='B mark at frame stiffener upper end' + (f' + {src} {sz[0]:g}X{sz[1]:g}' if sz else ' + ' + src))
                    cs = ET.SubElement(br, 'CoordSys')
                    _xyz(cs, 'Origin', p['x'], s['u'], hi - drop)
                    _xyz(cs, 'Waxis', 0, -w, 0)       # R-B7 (owner 2026-10-23): the bracket stands in the stiffener WEB plane (Y-normal), legs along the stiffener and along its web side
                    _xyz(cs, 'Uaxis', 0, 0, -1)
                    _contour(br, 'SimpleContour', [(0, 0), (leg, 0), (0, leg)])   # owner: simple right triangle, no toe / chamfer
                    ET.SubElement(br, 'End1')
                    e2 = ET.SubElement(br, 'End2')
                    ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=pid, CompType='Stiffener', CompId='1')
        for k_, g in enumerate(p.get('girders', []), 1):          # R-SS1 girder (web in the frame plane of the SUB-TITLE frame + flange plate panel at the web edge)
            sec = g['section']; H, tw, wf, tf = sec[1], sec[2], sec[3], sec[4]
            zt = g['z_top']; za = zt - H
            gx = g['x']
            gp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-GIRDER{k_}', Tightness='NonTight')
            cs = ET.SubElement(gp, 'CoordSys'); _xyz(cs, 'Origin', gx, 0, 0); _xyz(cs, 'Waxis', 1, 0, 0); _xyz(cs, 'Uaxis', 0, 1, 0)
            poly_g = [(g['y0'], za), (g['y1'], za), (g['y1'], zt), (g['y0'], zt)]
            _contour(ET.SubElement(gp, 'Boundary'), 'SimpleContour', poly_g)
            if g.get('exists'):
                gp.set('Note', 'bracket carrier only: the girder is the deck builder\'s %s (R-G1 no duplicate)' % g['exists']['name'])
                za = g['exists']['z0'] + tf / 2.0          # bracket top = underside of the existing flange (tf/2 added back, subtracted below)
            else:
                pgx = ET.SubElement(gp, 'PlateGroup', GroupId='1'); mt = ET.SubElement(pgx, 'Material', Grade='A'); ET.SubElement(mt, 'Thickness').text = f'{tw:g}'
                plx = ET.SubElement(pgx, 'Plate', CompId='1', Name=f'{pid}-GIRDER{k_}-WEB', Source=g['evidence'][:200])
                _contour(plx, 'SimpleContour', poly_g)
                fp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-GIRDER{k_}-FLANGE', Tightness='NonTight')
                cs = ET.SubElement(fp, 'CoordSys'); _xyz(cs, 'Origin', 0, 0, za); _xyz(cs, 'Waxis', 0, 0, 1); _xyz(cs, 'Uaxis', 1, 0, 0)
                pgf = ET.SubElement(fp, 'PlateGroup', GroupId='1'); mt = ET.SubElement(pgf, 'Material', Grade='A'); ET.SubElement(mt, 'Thickness').text = f'{tf:g}'
                plf = ET.SubElement(pgf, 'Plate', CompId='1', Name=f'{pid}-GIRDER{k_}-FLANGE-P1', Source='flange %gX%g of ' % (wf, tf) + g['evidence'][:150])
                _contour(plf, 'SimpleContour', [(gx - wf / 2, g['y0']), (gx + wf / 2, g['y0']), (gx + wf / 2, g['y1']), (gx - wf / 2, g['y1'])])
            # R-SS3: the B bracket of a SLANTED member that stops on this girder lies in the girder / frame plane (X = sub-title frame), right angle at the inner
            # corner between the member's web outer edge and the girder flange face, legs along the girder (toward the room) and down along the member
            for n_s, s_ in enumerate(p['stiffeners'], 1):
                sl = s_.get('slanted')
                bm = s_.get('bmark') or {}
                if not sl or not bm.get('hi') or not (min(g['y0'], g['y1']) - 60 <= s_['u'] <= max(g['y0'], g['y1']) + 60):
                    continue
                sz = bm.get('size_hi') or (500.0, 15.0)
                leg, bt = sz[0], sz[1]
                ysg = -1.0 if s_['u'] < 0 else 1.0
                yv = s_['u'] + ysg * (s_['section'][1] + s_['section'][4])    # outer face of the T flange at the web band's free edge (450 + flange thickness 15)
                bg = ET.SubElement(gp, 'BracketGroup', GroupId='2')
                mt = ET.SubElement(bg, 'Material', Grade='A'); ET.SubElement(mt, 'Thickness').text = f'{bt:g}'
                br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{pid}-GIRDER{k_}-SLANT-B{n_s}', Source='R-SS3 B bracket %gX%g of the slanted member at the girder (section label %s)' % (leg, bt, bm.get('src_hi', 'B50')))
                cs = ET.SubElement(br, 'CoordSys')
                _pl = (g.get('exists') or {}).get('plane')
                zo, dz = za - tf / 2.0, 0.0
                if _pl:        # R-CN6: the bracket's top edge lies ON the inclined girder underside (no gap along its length)
                    _zp = lambda y_: (_pl[1] - _pl[0][0] * gx - _pl[0][1] * y_) / _pl[0][2]
                    zo = _zp(yv); dz = _zp(yv + ysg * leg) - zo          # V of this bracket points DOWN: a rising underside = negative V
                _xyz(cs, 'Origin', gx, yv, zo)
                _xyz(cs, 'Waxis', 1, 0, 0); _xyz(cs, 'Uaxis', 0, ysg, 0)
                _contour(br, 'SimpleContour', [(0, 0), (leg, -dz), (0, leg)])
                ET.SubElement(br, 'End1')
                e2 = ET.SubElement(br, 'End2')
                ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=f'{pid}-SLANT{n_s}', CompType='Stiffener', CompId='1')
        for k_, fb in enumerate(p.get('free_brackets', []), 1):
            bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(bg, 'Material', Grade='A')
            ET.SubElement(mat, 'Thickness').text = f"{fb['t']:g}"
            br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{pid}/CB{k_}', Source=f"callout {fb['txt']} (leader tip)")
            cs = ET.SubElement(br, 'CoordSys')
            leg = fb['leg']
            _xyz(cs, 'Origin', p['x'], fb['u'], fb['z'])
            _xyz(cs, 'Waxis', -1.0 if fb['u'] > 0 else 1.0, 0, 0)
            _xyz(cs, 'Uaxis', 0, 0, -1)
            _contour(br, 'SimpleContour', [(0, 0), (leg, 0), (0, leg)])   # owner: simple right triangle, no toe / chamfer
            ET.SubElement(br, 'End1')
            ET.SubElement(br, 'End2')
    ET.indent(ship, space='  ')
    ET.ElementTree(ship).write(path, encoding='utf-8', xml_declaration=True)
