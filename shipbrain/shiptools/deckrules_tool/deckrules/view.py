"""Find deck plan views, read their header notes and calibrate page -> ship.

Rules (all from the drawing, no reference XML):
  * A deck plan is titled  '<NAME> PLAN (<Z> A/B)'; Z is the moulded deck
    height at centre in mm.
  * Header notes directly under the title give defaults:
    DECK PLATE, DECK BEAM, GIR. & WEB, DEEP GIR. & WEB, FRAME SPACE.
  * Scale: sheet title-block '1/n' unless a '(S : 1/n)' note is inside the view.
  * Ship X: boxed 'FR.n' labels of the view; X = frame_table(n).
    Page x of frame lines is fitted with the fixed print scale.
  * Ship Y: every 'NNNN OFF C.L' label points at a longitudinal line;
    voting  y_line +/- NNNN/k  over all labels gives the centre-line row.
    Plans look downward with bow to the right, so page-up is PORT (+Y).
"""
import math
SINGLE_LABEL = False     # R-V24 experiment (OFF): one frame label + sheet scale gave a wrong size on H1008 41830 A/B (2156 x 4813 vs the printed 4688 x 2665)
import re
import statistics
from collections import Counter

PT_MM = 25.4 / 72.0

# R-V1b: '<NAME> PLAN (<Z> A/B)' - name may hold digits, '/', '&', 'BTM.'; spaces inside the brackets and
# a missing space before the bracket are normal ('COMP.-DECK PLAN(62078 A/B)', 'A - DECK PLAN( 35512 A/B )')
TITLE = re.compile(r'^\s*(?P<name>[A-Z0-9][A-Z0-9./&\-]*(?:\s+[A-Z0-9./&\-]+)*?)\s*PLAN\s*\(\s*(?P<z>[\d,]+)\s*A/B\s*\)')
# plans titled without a height ('UPPER DECK PLAN'): the height is not printed in the title -> settings plan_heights_mm
TITLE_NOZ = re.compile(r'^\s*(?P<name>[A-Z][A-Z0-9./&\-]*(?:\s+[A-Z0-9./&\-]+)*?\s+DECK)\s*PLAN\s*$')
PLAN_HEIGHTS = {}
FRAME_ROW_NEAREST = False   # settings frame_row_nearest (R-V17); off for the older drawings (1005 weather shield relied on the old median)
_CAMBER = {}
ASK = []
DETAILS = []          # questions the tool cannot answer from the drawing (shown in the build report)
# H1008 family: '39945 A/B PLAN(S)' (height only) and 'COMPRESSOR ROOM TOP PLAN(S)' (name only, height from the SCHEME OF DECK CAMBER)
TITLE_Z = re.compile(r'^\s*(?P<z>\d{4,6})\s*A/B\s*PLAN\s*(?:\((?P<s>[PS])\))?\s*$')
TITLE_N = re.compile(r'^\s*(?P<name>[A-Z][A-Z0-9./&\- ]*?)\s*PLAN\s*\((?P<s>[PS])\)\s*$')
LOCAL_SCALE = re.compile(r'\(\s*[PS]?\s*:\s*1\s*/\s*(\d+)\s*\)')


def camber_scheme(page):
    """R-V13: 'SCHEME OF DECK CAMBER' prints the deck height at named OFF C.L offsets ('2665 OFF C.L' -> 42961 A/B,
    '18665 OFF C.L' -> 42811 A/B). Returns {'heights': [(offcl, z)], 'top': highest z} or None."""
    t = [w for w in page.words if 'SCHEME OF DECK CAMBER' in w.text]
    if not t:
        return None
    x0, y0, x1, y1 = t[0].bbox
    zs = []
    for w in page.words:
        m = re.fullmatch(r'\(?\s*(\d{4,6})\s*A/B\s*\)?', w.text.strip())
        if m and x0 - 250 < w.cx < x1 + 350 and y0 < w.cy < y1 + 220:
            zs.append((w.cx, w.cy, int(m.group(1))))
    if not zs:
        return None
    offs = []
    for w in page.words:
        m = re.fullmatch(r'(\d{3,5})\s*OFF C\.L', w.text.strip())
        if m and x0 - 250 < w.cx < x1 + 350 and y0 < w.cy < y1 + 220:
            offs.append((w.cx, w.cy, int(m.group(1))))
    pairs = []
    for ox, oy, ov in offs:
        if zs:
            z = min(zs, key=lambda q: abs(q[0] - ox) + abs(q[1] - oy) * 0.5)
            pairs.append((ov, z[2]))
    return {'heights': sorted(set(pairs)), 'top': max(z for _, _, z in zs)}
NOTE = {
    'plate': re.compile(r'(?:DECK )?PLATE(?:\s*THK\.?)?\s*:\s*([\d.]+)'),
    'beam': re.compile(r'(?:DECK (?:BEAM|LONGL\.?)|STIFF\.)\s*:\s*([0-9X/.]+\s*[A-Z.]+)'),
    'girder': re.compile(r'^(?:DECK\s+)?GIR\.\s*&\s*WEB\s*:\s*([0-9X/]+(?:\s?[0-9X/]+)*\s*[A-Z.]+)'),
    'deep': re.compile(r'(?:DEEP GIR\.\s*&\s*WEB|(?:DECK\s+)?GIR\.\s*&\s*TRANSV?\.)\s*:\s*([0-9X+./ ]+\s*[A-Z.()]+)'),
    'frame_space': re.compile(r'FRAME SPACE\s*:\s*(\d[\d,]*)'),
    'height': re.compile(r'DECK HEIGHT\s*:\s*(\d+)'),
}


class DeckView:
    def __init__(self, name, z, title_bbox):
        self.name = ' '.join(name.split())
        self.z = z
        self.title = title_bbox
        self.notes = {}
        self.region = None
        self.k = None          # mm per page point
        self.x0 = None         # page x of frame 0
        self.cl_y = None       # page y of centre line
        self.frame_space = 800
        self.frame_fn = None
        self.ybounds = None
        self._others = []
        self.evidence = {}
        self.height_only = False
        self.half = None
        self.z_source = 'plan title'

    # page -> ship
    def X(self, x):
        return (x - self.x0) * self.k

    def Y(self, y):
        return (self.cl_y - y) * self.k

    def px(self, X):
        return self.x0 + X / self.k

    def py(self, Y):
        return self.cl_y - Y / self.k

    def to_dict(self):
        return {'name': self.name, 'z_mm': self.z, 'notes': self.notes,
                'region_page': self.region, 'mm_per_pt': self.k,
                'frame0_page_x': self.x0, 'centre_line_page_y': self.cl_y,
                'evidence': self.evidence}


def deck_height_written(page, name):
    """R-V28 (2026-10-26, 1004 ERM 'UPPER DECK PLAN'): a plan title without height takes the height written beside the same deck
    name elsewhere on the sheet: 'UPPER DECK' with '(27900 A/B)' right under / beside it (camber details, sections). The value
    written most often wins. -> (z, evidence) or None"""
    from . import decknames
    k = decknames.key(name)
    if not k:
        return None
    ab = [(u, int(re.search(r'(\d{4,6})\s*A/B', u.text).group(1))) for u in page.words if re.search(r'\d{4,6}\s*A/B', u.text)]
    votes = Counter()
    for w in page.words:
        if decknames.key(w.text) != k or w.size > 18:
            continue
        for u, z in ab:
            if u is w:
                continue
            below = 0 < u.cy - w.cy < 22 and abs(u.bbox[0] - w.bbox[0]) < 30
            beside = abs(u.cy - w.cy) < 6 and 0 < u.bbox[0] - w.bbox[2] < 30
            if below or beside:
                votes[z] += 1
    if not votes:
        return None
    z, n = votes.most_common(1)[0]
    return z, f'"{name}" with ({z} A/B) written {n}x on the sheet'


def camber_line(page):
    """R-CB5 (2026-10-26, 1004 ERM): a 'SCHEME OF DECK CAMBER' that gives ONE deck height at the side ('27900 A/B' at the SIDE SHELL,
    '25500 OFF C.L') and one camber value at the centre line ('300') = straight-line camber: Z(Y) = z_side + c * (1 - |Y| / B/2),
    for the deck named in the scheme. -> {'deck': key, 'z_side', 'half_b', 'c'} or None"""
    from . import decknames
    t = [w for w in page.words if 'SCHEME OF DECK CAMBER' in w.text]
    if not t:
        return None
    x0, y0, x1, y1 = t[0].bbox
    box = [w for w in page.words if x0 - 150 < w.cx < x1 + 120 and y1 < w.cy < y1 + 140]
    zs = [int(re.search(r'(\d{4,6})\s*A/B', w.text).group(1)) for w in box if re.search(r'\d{4,6}\s*A/B', w.text)]
    offs = [int(re.search(r'(\d{4,5})', w.text).group(1)) for w in box if re.fullmatch(r'\d{4,5}', w.text.strip()) and
            any(u.text.strip().startswith('OFF C') and abs(u.cx - w.cx) < 15 and 0 < u.cy - w.cy < 16 for u in box)]
    cs = [int(w.text) for w in box if re.fullmatch(r'\d{2,4}', w.text.strip()) and int(w.text) not in offs]
    names = [decknames.key(w.text) for w in box if decknames.key(w.text)]
    if len(set(zs)) != 1 or len(set(offs)) != 1 or len(set(cs)) != 1 or not names:
        return None
    return {'deck': names[0], 'z_side': float(zs[0]), 'half_b': float(offs[0]), 'c': float(cs[0])}


def find_deck_plans(page):
    out = []
    _CAMBER.clear()
    cs = camber_scheme(page)
    if cs:
        _CAMBER.update(cs)
    for w in page.words:
        _pt = re.match(r'^\s*([A-Z][A-Z0-9. ]*?-?\s*DECK)\s*PLAN\s*\(\s*\d{1,2}[.,]\d{0,2}\s*$', w.text)
        if _pt and w.size > 9:
            # R-OC3 (1007 scan): the OCR cut the title in two boxes ('D - DECK PLAN(46,' + 'AN(46.840 A/B)'): the rest of the height stands
            # in the box right after it on the same row -> joined, nothing asked
            _tail = [u for u in page.words if u is not w and abs(u.cy - w.cy) < 0.8 * w.size and -0.5 * (w.bbox[2] - w.bbox[0]) < u.bbox[0] - w.bbox[2] < 3 * w.size and u.bbox[2] > w.bbox[2]
                     and re.search(r'(\d{1,2})[.,]?(\d{3})\s*A\s*/\s*B\s*\)', u.text)]
            if _tail:
                mz_ = re.search(r'(\d{1,2})[.,]?(\d{3})\s*A\s*/\s*B', _tail[0].text)
                out.append(DeckView(_pt.group(1).strip(), int(mz_.group(1) + mz_.group(2)), (w.bbox[0], min(w.bbox[1], _tail[0].bbox[1]), _tail[0].bbox[2], max(w.bbox[3], _tail[0].bbox[3]))))
                continue
            ASK.append(f'R-OC2: the title "{w.text.strip()}" at ({round(w.cx)},{round(w.cy)}) is cut by the OCR: the deck height (mm) is not readable - ASK the owner "{_pt.group(1)}" height')
        m = TITLE.match(w.text)
        if m and w.size > (9 if getattr(page, 'raster', False) else 12):     # R-OC3: OCR box heights of a scan are estimates -> the full 'PLAN(z A/B)' pattern is enough
            out.append(DeckView(m.group('name'), int(m.group('z').replace(',', '')), w.bbox))
            continue
        mz = TITLE_Z.match(w.text)
        if mz and w.size > 12:
            x0_, y0_, x1_, y1_ = w.bbox
            loc = [u for u in page.words if LOCAL_SCALE.search(u.text) and x0_ - 60 < u.cx < x1_ + 60 and y0_ < u.cy < y1_ + 40]
            if loc:                       # R-V14: '( S : 1/50 )' under the title = a local detail sketch, not a deck plan
                DETAILS.append(f"{mz.group('z')} A/B PLAN at ({round(w.cx)},{round(w.cy)}) is a local detail sketch ({loc[0].text.strip()}) - not built")
                continue
            dv = DeckView(mz.group('z') + ' A/B', int(mz.group('z')), w.bbox)
            dv.height_only = True
            dv.half = mz.group('s')
            out.append(dv)
            continue
        mn = TITLE_N.match(w.text)
        if mn and w.size > 12 and not TITLE.match(w.text):
            nm = mn.group('name').strip()
            zt = PLAN_HEIGHTS.get(nm)
            if zt is None and 'ROOM TOP' in nm and _CAMBER.get('top'):
                zt = _CAMBER['top']                       # R-V13: the highest top plan = the deck-camber scheme height
            if zt is not None:
                dv = DeckView(nm, int(zt), w.bbox)
                dv.half = mn.group('s')
                dv.z_source = 'plan_heights_mm setting' if nm in PLAN_HEIGHTS else 'SCHEME OF DECK CAMBER (highest height)'
                out.append(dv)
            else:
                ASK.append(f'height of plan "{nm}" is not printed in its title and not in the deck-camber scheme: ASK the owner')
            continue
        m = TITLE_NOZ.match(w.text)
        if m and w.size > 18:
            nm = m.group('name').strip()
            if nm in PLAN_HEIGHTS:
                out.append(DeckView(nm, int(PLAN_HEIGHTS[nm]), w.bbox))
            else:
                zt = deck_height_written(page, nm)
                if zt:
                    dv = DeckView(nm, int(zt[0]), w.bbox)
                    dv.z_source = f'R-V28 height written beside the deck name on the sheet: {zt[1]}'
                    out.append(dv)
                else:
                    ASK.append(f'height of plan "{nm}" is not printed in its title nor beside the deck name on the sheet: ASK the owner')
    # R-OC2: OCR can drop an underlined 'A -' prefix -> title 'DECK PLAN (22,900 A/B)'. Infer the letter from the other titles'
    # letters ordered by height (the unnamed plan takes the free letter next to its neighbour in height).
    known = sorted((v.z, v.name[0]) for v in out if re.fullmatch(r'[A-F] ?- ?DECK', v.name))
    for v in out:
        if v.name.strip() == 'DECK' and known:
            lower = [k for k in known if k[0] < v.z]
            upper = [k for k in known if k[0] > v.z]
            if upper and not lower:
                L = chr(ord(upper[0][1]) - 1)
            elif lower:
                L = chr(ord(lower[-1][1]) + 1)
            else:
                continue
            if 'A' <= L <= 'F':
                v.name = f'{L} - DECK'
                known = sorted(known + [(v.z, L)])
    for v in out:
        v._others = out
        x0, y0, x1, y1 = v.title
        for w in page.words:
            if abs(w.bbox[0] - x0) < 15 and y0 + 10 < w.bbox[1] < y1 + 130 and not w.vertical:
                # R-GR1 (2026-10-26, 1004 ERM): a steel grade mark inside a size ('200X90X10/14 "AH" I.A', '700X14 "AH" + 250X25 "AH"
                # F.B (T)') is the grade, not part of the size: removed before the size is read, kept as the plan's grade note
                txt_ = w.text
                gm = re.findall(r'"\s*([A-Z]{1,2}\d{0,2})\s*"', txt_)
                txt_ = re.sub(r'"\s*[A-Z]{1,2}\d{0,2}\s*"', ' ', txt_)
                txt_ = re.sub(r'F\.B\s+\(T\)', 'F.B(T)', txt_)
                for key, rx in NOTE.items():
                    m = rx.search(txt_)
                    if m and key not in v.notes:
                        v.notes[key] = ' '.join(m.group(1).split())
                        if gm:
                            v.notes[key + '_grade'] = gm[0]
                        if key == 'deep' and 'TRANS' in w.text:
                            v.notes['deep_gt'] = '1'      # R-DG2: 'GIR. & TRANSV. : 450X12+150X20 F.B(T)' = the dark chain lines are girders / transverses
        if 'frame_space' in v.notes:
            v.frame_space = int(v.notes['frame_space'].replace(',', ''))
    return out


def sheet_scale(page):
    for w in page.words:
        if w.text.strip() == 'SCALE':
            best = None
            for u in page.words:
                m = re.fullmatch(r'\s*1\s*/\s*(\d+)\s*', u.text)
                if m:
                    d = abs(u.cx - w.cx) + abs(u.cy - w.cy)
                    if d < 80 and (best is None or d < best[0]):
                        best = (d, int(m.group(1)))
            if best:
                return best[1]
    return None


FRL = re.compile(r'FR\.\s*(\d+)\s*(?:([+-])\s*(?:(\d+)\s*/\s*(\d+)|(\d+)))?')


def parse_frame_label(text):
    """'FR.84' -> (84, 0, 0) ; 'FR.84+1/2' -> (84, 0.5 frame) ; 'FR.12+2100' -> (12, +2100 mm)."""
    m = FRL.fullmatch(text.strip())
    if not m:
        return None
    n = int(m.group(1))
    if not m.group(2):
        return n, 0.0, 0.0
    sg = 1 if m.group(2) == '+' else -1
    if m.group(3):
        return n, sg * int(m.group(3)) / int(m.group(4)), 0.0
    return n, 0.0, sg * int(m.group(5))


def _frame_labels(page, v):
    """boxed 'FR.n' labels of the plan (R-V2). The window reaches far below the title because on some
    drawings the plan body sits far under its title/notes."""
    x0, y0, x1, y1 = v.title
    below = [u.title[1] for u in getattr(v, '_others', []) if u.title[1] > y1 + 5 and abs(u.title[0] - x0) < 500]
    reach = max(1300.0, 0.7 * (page.rect[3] - page.rect[1])) if getattr(page, 'raster', False) else 1300.0      # R-V31 (1007 scan): tall plans (labels 1466 pt under the title on a 2384 pt sheet)
    ylim = min(below) if below else y1 + reach
    labs = []
    for w in page.words:
        pr = parse_frame_label(w.text)
        if pr and x0 - 260 < w.cx < x0 + 700 and y1 < w.cy < min(y1 + reach, ylim):
            labs.append((pr, w))
    # R-V31b: the frame labels of ONE plan stand on one row. When the window also catches labels of another view (1007: 'FR.20-200',
    # 'FR.21' of a section beside the A-DECK plan, 270 pt higher) the row with the most horizontal labels is the plan's row.
    hz = [l for l in labs if not l[1].vertical]
    if len(hz) >= 4 and getattr(page, 'raster', False):
        rows = {}
        for l in hz:
            rows.setdefault(round(l[1].cy / 15.0), []).append(l)
        merged = {}
        for key in sorted(rows):
            tgt = key - 1 if key - 1 in merged else key
            merged.setdefault(tgt, []).extend(rows[key])
        best = max(merged.values(), key=len)
        if len(best) >= 3 and len(best) < len(hz):
            labs = best + [l for l in labs if l[1].vertical]
    return labs


def _digit_row(page, v, sp, k):
    """R-V7: a row of printed frame numbers ('79 80 81 ...') under/over the plan. Returns [(n, cx)] of the
    nearest qualifying row, or []. Rows from small elevations (about half the spacing) are rejected."""
    x0, y0, x1, y1 = v.title
    rows = {}
    for w in page.words:
        if re.fullmatch(r'-?\d{1,3}', w.text.strip()) and not w.vertical and w.size < 12 and w.cy > y1 + 100:
            rows.setdefault(round(w.cy / 4), []).append(w)
    best = None
    for key, ws in rows.items():
        ws.sort(key=lambda w: w.cx)
        # chain words whose x-gap / frame-number-gap equals one frame (rows may print every 2nd/3rd frame)
        chains = []
        for i in range(len(ws)):
            ch = [ws[i]]
            for w in ws[i + 1:]:
                a = ch[-1]
                dn = int(w.text) - int(a.text)
                if 1 <= dn <= 6 and abs((w.cx - a.cx) / dn - sp / k) < 0.12 * sp / k:
                    ch.append(w)
            if len(ch) >= 3:
                chains.append(ch)
        grp = []
        for w in ws:
            if grp and w.cx - grp[-1].cx > 2.6 * sp / k:
                if len(grp) >= 5:
                    best = _consider(best, grp, v, sp, k)
                grp = []
            grp.append(w)
        if len(grp) >= 5:
            best = _consider(best, grp, v, sp, k)
        for ch in chains:
            if len(ch) < 5:
                best = _consider(best, ch, v, sp, k, minfull=2)
    return best[2] if best else []


def _chain_row(page, v, ft0, k):
    """v2.106: printed frame numbers whose X the frame chain knows; they must agree on ONE sheet position of X = 0 (non-uniform spacing allowed).
    -> [(n, cx)] of the row nearest below the title with >= 2 consistent labels, or []."""
    x0_, y0_, x1_, y1_ = v.title
    rows = {}
    _ol = _outline_x(page, x0_ - 200, x1_ + 300, y1_ + 5, y1_ + 1500)
    _lo, _hi = ((_ol[0] - 100, _ol[1] + 100) if _ol else (x0_ - 250, x1_ + 450))
    if _ol and (_ol[1] < x0_ or _ol[0] > x1_):
        # the long vertical lines found lie beside the title (a plan whose aft edge is the curved shell has one straight edge only):
        # the plan reaches over its title too
        _lo, _hi = min(_lo, x0_ - 100), max(_hi, x1_ + 100)
    for w in page.words:
        if re.fullmatch(r'-?\d{1,3}', w.text.strip()) and not w.vertical and w.size < 12 and w.cy > y1_ + 40 and ft0.known(int(w.text)) \
                and _lo < w.cx < _hi and w.cy < y1_ + 1500:      # R-V26: the row lies over / under THIS plan's outline, not beside it
            rows.setdefault(round(w.cy / 4), []).append(w)
    # R-E3g (plans): a frame row printed at two heights (labels of the long-tick frames lifted) is one row: rows within 30 pt join
    _m = []
    for key in sorted(rows):
        if _m and key * 4 - _m[-1][0] * 4 < 30:
            _m[-1][1].extend(rows[key])
        else:
            _m.append([key, list(rows[key])])
    rows = {k_: ws_ for k_, ws_ in _m}
    best = best2 = None
    for key, ws in sorted(rows.items()):
        ws.sort(key=lambda w: w.cx)
        est = [w.cx - ft0(int(w.text)) / k for w in ws]
        cl = max(([i for i, e2 in enumerate(est) if abs(e2 - e) * k <= 90] for e in est), key=len)
        keep = [(int(ws[i].text), ws[i].cx) for i in cl]
        keep = sorted({n: c for n, c in keep}.items(), key=lambda t: t[1])
        if any(b[0] <= a[0] for a, b in zip(keep, keep[1:])):
            continue
        if len(keep) >= 3 and best is None:
            best = keep
        if len(keep) >= 2 and best2 is None:
            best2 = keep
    if True:
        # R-V7d (ERM NO.3 STR.): the frame numbers may be written along a CURVED edge (the shell line), each at another height. All the
        # numbers of the band (the occurrence nearest the title for each number) that agree on one sheet position of X = 0 (90 mm)
        # and increase left to right form the row
        allw = [w for ws in rows.values() for w in ws]
        first = {}
        for w in sorted(allw, key=lambda w: w.cy):
            first.setdefault(int(w.text), w)
        ws = sorted(first.values(), key=lambda w: w.cx)
        if len(ws) >= 3:
            est = [w.cx - ft0(int(w.text)) / k for w in ws]
            cl = max(([i for i, e2 in enumerate(est) if abs(e2 - e) * k <= 90] for e in est), key=len)
            keep = sorted(((int(ws[i].text), ws[i].cx) for i in cl), key=lambda t: t[1])
            if len(keep) >= 3 and all(b[0] > a[0] for a, b in zip(keep, keep[1:])) and len(keep) > max(len(best2 or []), len(best or []) + 1):
                best = keep
    return best or best2 or []      # the nearest row with 3+ consistent labels; a 2-label row only when no row has 3


def _consider(best, grp, v, sp, k, minfull=3):
    x0, y0, x1, y1 = v.title
    ns = [int(w.text) for w in grp]
    if any(b <= a for a, b in zip(ns, ns[1:])):
        return best
    xs = [w.cx for w in grp]
    if xs[-1] < x0 - 150 or xs[0] > x1 + 450:
        return best
    steps = [(xb - xa) / max(nb - na, 1) for (xa, na), (xb, nb) in zip(zip(xs, ns), zip(xs[1:], ns[1:]))]
    full = [s for s in steps if abs(s - sp / k) < 0.12 * sp / k]
    if len(full) < minfull:
        return best
    dist = abs(grp[0].cy - y1)
    if best is None or dist < best[0]:
        return (dist, 0, [(n, w.cx) for n, w in zip(ns, grp)])
    return best


def _table_from_row(row, sp, k, base=None):
    """X(n) from a printed row: uniform frames n*sp, shorter bays (half frames) measured."""
    tab = {}
    # anchor: first frame whose following bay is a full frame
    anchor = None
    for (na, xa), (nb, xb) in zip(row, row[1:]):
        if abs((xb - xa) * k / (nb - na) - sp) < 0.12 * sp:
            anchor = na
            break
    if anchor is None:
        return tab
    tab[anchor] = base(anchor) if (base is not None and hasattr(base, 'anchor')) else anchor * sp   # owner frame anchor (R-F2) wins over n*spacing
    for i, (n, x) in enumerate(row):
        if n > anchor:
            prev_n, prev_x = row[i - 1]
            tab[n] = tab[prev_n] + (x - prev_x) * k
    for i in range(len(row) - 1, -1, -1):
        n, x = row[i]
        if n < anchor:
            nxt_n, nxt_x = row[i + 1]
            tab[n] = tab[nxt_n] - (nxt_x - x) * k
    return tab


def _outline_x(page, x0, x1, y0, y1):
    """page-x of the aft and fwd edge of a plan: the outermost long solid vertical lines (>= 40 % of the longest) in the window"""
    vs = [s for s in page.segs if s.vertical and not s.dash and x0 < s.a[0] < x1 and y0 < min(s.a[1], s.b[1]) and max(s.a[1], s.b[1]) < y1]
    if not vs:
        return None
    L = max(s.length for s in vs)
    lg = [s.a[0] for s in vs if s.length > 0.4 * L]
    return (min(lg), max(lg), L) if len(lg) >= 2 else None


def _sibling_frames(page, v, ft0):
    """R-XV5 (2026-10-25): a deck plan with NO frame label takes X from another plan of the SAME deck on the sheet that has its
    frame-number row (e.g. "ARRG'T OF STEEL WALL ON B. - DECK" for "B - DECK PLAN"): both outlines must have the same length in mm
    (each at its own scale, within 3 %); the aft edge X of the sibling then places this plan. Returns pseudo frame labels or []."""
    from . import framedrawn, pdfsrc as _ps
    key = re.sub(r'[^A-Z0-9]', '', v.name.upper())
    if len(key) < 4:
        return []
    tb = v.title
    me = _outline_x(page, tb[0] - 200, tb[2] + 300, tb[3] + 5, tb[3] + 1500)
    if not me:
        return []
    rows = framedrawn._rows(page)
    for w in page.words:
        t = re.sub(r'[^A-Z0-9]', '', w.text.upper())
        if w.size < 12 or w.bbox == tuple(tb) or not t.endswith(key) or t == key + 'PLAN' or t.startswith(key):
            continue
        cand = [r for r in rows if w.bbox[3] < r[0][1] * 0 + _row_y(page, r) < w.bbox[3] + 1300 and abs(statistics.mean(x for _, x in r) - w.cx) < 400]
        if not cand:
            continue
        r = min(cand, key=lambda r: _row_y(page, r))
        pairs = [((ft0(b[0]) - ft0(a[0])) / (b[1] - a[1])) for a, b in zip(r, r[1:]) if b[1] > a[1]]
        if not pairs:
            continue
        ks = statistics.median(pairs)
        x0s = statistics.median(x - ft0(n) / ks for n, x in r)
        sib = _outline_x(page, r[0][1] - 150, r[-1][1] + 150, w.bbox[3] + 5, _row_y(page, r) - 3)
        if not sib:
            continue
        Xa, Xf = (sib[0] - x0s) * ks, (sib[1] - x0s) * ks
        Lme = (me[1] - me[0]) * v.k
        if not (abs(Lme / (Xf - Xa) - 1) < 0.03):
            v.evidence.setdefault('sibling_rejected', []).append(f'{w.text.strip()}: length {Xf - Xa:.0f} mm vs this plan {Lme:.0f} mm')
            continue
        # R-XV5b: the sibling is read at its own (often smaller) scale - 1 pt there is 50+ mm. The aft edge snaps to the nearest
        # quarter-bay point of the frame chain when within 150 mm (deck edges stand on frames / half frames); else kept as measured.
        grid = []
        for n in range(-10, 400):
            a_, b_ = ft0(n), ft0(n + 1)
            if isinstance(a_, (int, float)) and isinstance(b_, (int, float)):
                grid += [a_ + q * (b_ - a_) / 4 for q in range(4)]
        g = min(grid, key=lambda X: abs(X - Xa)) if grid else Xa
        snap = abs(g - Xa) <= 150
        if snap:
            Xf, Xa = Xf + (g - Xa), g
        x0 = me[0] - Xa / v.k
        out = []
        for n in range(-10, 400):
            X = ft0(n)
            if isinstance(X, (int, float)) and Xa - 1 <= X <= Xf + 1:
                px = x0 + X / v.k
                out.append(((n, 0, 0), _ps.Word(str(n), (px - 3, tb[3] + 1, px + 3, tb[3] + 9), 7.0, False)))
        if len(out) >= 2:
            v.evidence['frame_source'] = (f"R-XV5: no frame label on this plan; X from the frame row of \"{w.text.strip()}\" (same deck): "
                                          f"outline {Xa:.0f}..{Xf:.0f} mm, lengths agree ({Lme:.0f} / {Xf - Xa:.0f} mm)" + (' (aft edge snapped to the frame grid, R-XV5b)' if snap else ''))
            return out
    return []


def _row_y(page, r):
    for w in page.words:
        if abs(w.cx - r[0][1]) < 0.01 and w.text.strip().endswith(str(r[0][0])):
            return w.cy
    return 0.0


def calibrate(page, v, frame_table=None):
    """frame_table: callable frame->X mm (project setting). Default n*space.

    Mode A (1005 style): boxed 'FR.n' labels over the plan, thin dashed frame lines refine x0.
    Mode B (R-V7): no usable boxed labels -> the printed frame-number row; the frame table
    (including half-frame bays) is measured from the row, anchored at n*FRAME SPACE (flagged)."""
    sp = v.frame_space
    n = sheet_scale(page) or 100
    v.k = PT_MM * n
    ft0 = frame_table or (lambda m: m * sp)
    labs_raw = _frame_labels(page, v)
    if hasattr(ft0, 'known'):
        labs_raw = [(pr, w) for pr, w in labs_raw if ft0.known(pr[0])]     # frame chain: a label whose frame the chain does not reach is not used
    # R-V15 (owner 2026-10-23): text first, scale second. When the printed frame labels give a different mm/pt than the sheet scale
    # (local sketches at 1/50 on a 1/100 sheet), the pitch of the labels wins.
    try:
        def _ftm(pr):
            n_, fr, mm = pr
            return ft0(n_) + fr * sp + mm
        lw = sorted(((_ftm(pr), w) for pr, w in labs_raw if not w.vertical), key=lambda q: q[0])
        ratios = []
        for (fa, wa), (fb, wb) in zip(lw, lw[1:]):
            if fb - fa > 1 and abs(wb.cx - wa.cx) > 5 and abs(wb.cy - wa.cy) < 40:
                ratios.append((fb - fa) / abs(wb.cx - wa.cx))
        if len(ratios) >= 2:
            kt = statistics.median(ratios)
            if 0.3 * v.k < kt < 3 * v.k and abs(kt / v.k - 1) > 0.03:
                v.evidence['scale_from_text'] = f'frame-label pitch gives {kt:.2f} mm/pt, sheet scale 1/{n} gives {v.k:.2f}: label pitch used'
                v.k = kt
    except Exception as _e:
        from . import openitems as _oi
        _oi.record('view R-V15 scale from frame-label pitch', _e)
    labs = [(pr, w) for pr, w in labs_raw]
    # R-V29 (ERM E/R 3RD DECK): 'FR.23+13', 'FR.27-91' written vertically inside the plan are POSITIONS of items (pillars), not the plan's
    # frame labels. When every FR. label of the window is vertical text with an offset and the plan prints its own frame-number row,
    # the row is used (mode B)
    if labs and all(w.vertical and (pr[1] or pr[2]) for pr, w in labs):
        _rw = _chain_row(page, v, ft0, v.k) if hasattr(ft0, 'known') else []
        if len(_rw) >= 2:
            v.evidence['item_position_labels_ignored'] = sorted({w.text.strip() for _, w in labs})
            labs = []
            labs_raw = []
    mode = 'A'
    row = []

    def _consistent(labs_):
        # R-V6b: boxed FR.n labels must agree on one x0 (note texts like 'FR.19' elsewhere on the sheet do not)
        def ftl(pr):
            n_, fr, mm = pr
            return ft0(n_) + fr * sp + mm
        keep = list(labs_)
        for _ in range(6):
            if len(keep) < 2:
                break
            est = [w.cx - ftl(pr) / v.k for pr, w in keep]
            med = statistics.median(est)
            bad = [i for i, e in enumerate(est) if abs(e - med) * v.k > 120]
            if not bad:
                break
            keep = [l for i, l in enumerate(keep) if i not in bad]
        ok = len({pr for pr, _ in keep}) >= 2
        return keep if ok else []

    _raw = list(labs)
    labs = _consistent(labs)
    if len(labs) < 2:
        _sib = _sibling_frames(page, v, ft0)
        if _sib:
            labs, _raw = _sib, list(_sib)
    if len(labs) < 2:
        # R-V24: a small plan with ONE frame label: scale from the sheet scale (v.k), x from that label (nearest to the plan title); flagged
        _one = sorted([(pr, w) for pr, w in _raw if not w.vertical], key=lambda t: math.hypot(t[1].cx - v.title[0], t[1].cy - v.title[1]))
        if SINGLE_LABEL and not _one and hasattr(ft0, 'anchor'):      # no boxed label: the plain frame number equal to the owner's anchor frame, nearest to the title
            _an = ft0.anchor[0]
            _c = sorted([w for w in page.words if w.text.strip() == str(_an) and not w.vertical and v.title[3] < w.cy < v.title[3] + 1500],
                        key=lambda w: math.hypot(w.cx - v.title[0], w.cy - v.title[1]))
            if _c:
                _one = [((_an, 0, 0), _c[0])]
        _raw = [pr_w for pr_w in _one] or _raw
        if SINGLE_LABEL and _one and v.k and len({pr for pr, _ in _raw}) == 1:
            labs = _one[:1]
            v.evidence['single_frame_label'] = 'x from the single frame label; scale from printed dimensions (labels/dimensions first, vector scale last)'
            # R-V25 (owner: labels first, then dimensions, then pixel/vector scale): mm/pt from the printed dimension numbers of THIS plan
            _rat = []
            for w_ in page.words:
                if re.fullmatch(r'\d{3,5}', w_.text.strip()) and not w_.vertical and abs(w_.cx - v.title[0]) < 900 and 0 < w_.cy - v.title[3] < 1700:
                    for s_ in page.segs:
                        if s_.horizontal and not s_.dash and s_.width < 0.5 and s_.length > 20 and abs(s_.a[1] - w_.cy) < 8 \
                                and min(s_.a[0], s_.b[0]) - 1 <= w_.cx <= max(s_.a[0], s_.b[0]) + 1:
                            r_ = int(w_.text) / s_.length
                            if 0.4 * v.k < r_ < 2.5 * v.k:
                                _rat.append(r_)
            if len(_rat) >= 2:
                _kd = statistics.median(_rat)
                v.evidence['scale_from_dimensions'] = f'{_kd:.2f} mm/pt from {len(_rat)} printed dimensions (sheet scale gives {v.k:.2f})'
                v.k = _kd
    if len(labs) < 2 and len(labs) != 1:
        row = _chain_row(page, v, ft0, v.k) if hasattr(ft0, 'known') else []
        chain_hit = len(row) >= 2
        if chain_hit:
            mode = 'B'
            v.evidence['frame_source'] = 'printed frame-number row measured against the frame chain of written spacings (v2.106)'
        else:
            row = _digit_row(page, v, sp, v.k)
        if chain_hit:
            pass
        elif len(row) >= 3:
            mode = 'B'
            _anch = hasattr(ft0, 'anchor')
            tab = _table_from_row(row, sp, v.k, ft0)
            if not tab:
                raise ValueError(f'{v.name}: frame-number row found but no full-frame bay to anchor it')

            def ft1(m, tab=tab, base=ft0):
                f = int(m) if float(m).is_integer() else None
                if f is not None and f in tab:
                    return tab[f]
                lo = int(m // 1)
                x_lo = tab.get(lo, base(lo))
                return x_lo + (m - lo) * sp
            ft0 = ft1
            v.evidence['frame_source'] = 'printed frame-number row (frame table measured; anchored at ' + ('the owner frame anchor' if _anch else 'n*FRAME SPACE - confirm with project frame table') + ')'
        else:
            raise ValueError(f'{v.name}: fewer than two frame labels')

    def ft(pr):
        if isinstance(pr, tuple):
            n_, fr, mm = pr
            base = ft0(n_)
            if isinstance(base, tuple):
                return base
            nxt = ft0(n_ + 1) if fr else None
            bay = (nxt - base) if isinstance(nxt, (int, float)) and nxt > base else sp      # R-FC2: '23+1/2' is half of THAT bay (800 when drawn so)
            return base + fr * bay + mm
        return ft0(pr)

    if mode == 'A':
        pts = [(ft(pr), w, pr) for pr, w in labs]
        boxed = [(f, w, pr) for f, w, pr in pts if not w.vertical] or pts
        est = [w.cx - f / v.k for f, w, pr in boxed]
        x0 = statistics.median(est)
        xmin = min(w.cx for _, w, _ in pts) - 30
        xmax = max(w.cx for _, w, _ in pts) + 30
        ylab = statistics.median(w.cy for _, w, _ in pts)
        if v.evidence.get('single_frame_label'):
            ylab = v.title[3]
            xmin, xmax = xmin - 400, xmax + 800      # one label only: search the whole plan width
        below = [u.title[1] for u in getattr(v, '_others', []) if u.title[1] > ylab and abs(u.title[0] - v.title[0]) < 500]
        v.ybounds = (ylab, min(ylab + 1300, min(below) if below else 1e9))
        if ylab - v.title[3] > 400 and not any(v.title[3] < u.title[1] < ylab and abs(u.title[0] - v.title[0]) < 500 for u in getattr(v, '_others', [])):
            # R-V7d (1006 deck house): the frame labels stand at the BOTTOM of the plan (the title is far above them, no other plan title in
            # between): the plan lies between the title and the label row, not below the labels
            v.ybounds = (v.title[3] + 5, ylab + 15)
            v.evidence['frame_row'] = 'below the plan (R-V7d: labelled row under the plan)'
        vert = [s for s in page.segs if s.vertical and s.length > 15 and s.dash
                and xmin < s.a[0] < xmax and v.ybounds[0] < min(s.a[1], s.b[1]) < v.ybounds[1]]
        resid = []
        for f, w, pr in boxed:
            px = x0 + f / v.k
            c = [s.a[0] - px for s in vert if abs(s.a[0] - px) < 3]
            if c:
                resid.append(statistics.median(c))
        # R-V27 (review 2026-10-26, 1005 NAV. deck 100 mm off): labels are text, the frame TICK is the drawn frame position. The
        # plain frame-number row of the plan has a short vertical tick at each frame; the ticks of that row (within a quarter bay) fix x0 - only when they agree (spread < 1 pt).
        qb = 0.25 * sp / v.k
        tres = []
        for w in page.words:
            t_ = w.text.strip()
            if not re.fullmatch(r'\d{1,3}', t_) or w.vertical or not (xmin - 200 < w.cx < xmax + 200) or not (v.ybounds[0] - 40 < w.cy < v.ybounds[1] + 60):
                continue
            try:
                px = x0 + ft((int(t_), 0, 0)) / v.k
            except Exception:
                continue
            if not isinstance(px, float) or abs(w.cx - px) > qb:
                continue
            tk = [q.a[0] for q in page.segs if q.vertical and not q.dash and q.length < 15 and abs(q.a[0] - px) < qb
                  and abs((q.a[1] + q.b[1]) / 2 - w.cy) < 15]
            if tk:
                tres.append(min(tk, key=lambda x_: abs(x_ - w.cx)) - px)
        if len(tres) >= 3 and max(tres) - min(tres) < 1.0:
            x0 += statistics.median(tres)
            v.evidence['frame_ticks'] = f'R-V27: x0 from {len(tres)} frame ticks of the number row ({statistics.median(tres) * v.k:+.0f} mm)'
        elif resid:
            x0 += statistics.median(resid)
        v.x0 = x0
        v.evidence['frame_labels'] = sorted({f"{pr[0]}{'+%g' % pr[1] if pr[1] else ''}{'%+d' % pr[2] if pr[2] else ''}" for _, _, pr in pts})
        v.evidence['frame_label_residual_mm'] = round(max(abs(w.cx - (x0 + f / v.k)) for f, w, pr in boxed) * v.k, 1)
    else:
        est = [x - ft0(m) / v.k for m, x in row]
        v.x0 = statistics.median(est)
        xmin, xmax = row[0][1] - 30, row[-1][1] + 30
        rowy = [w.cy for w in page.words if re.fullmatch(r'\d{1,3}', w.text.strip()) and not w.vertical
                and any(abs(w.cx - x) < 1.5 and str(m) == w.text.strip() for m, x in row)]
        # R-V28 (1005 sheet 2, weather shield / NO.n STR.): a plan whose title stands ABOVE it owns the frame-number row that lies below its
        # own title and above the next plan title; a row ABOVE the title belongs to the plan above (it must never be taken as this plan's row)
        _nxt = min([u.title[1] for u in getattr(v, '_others', []) if u.title[1] > v.title[3] and abs(u.title[0] - v.title[0]) < 500] or [1e9])
        _own = [y for y in rowy if v.title[3] < y < _nxt]
        if _own and len(_own) < len(rowy):
            v.evidence['row_own'] = f'R-V28: {len(rowy) - len(_own)} frame-number rows above this plan title ignored (they belong to the plan above)'
            rowy = _own
        # R-V17: the same frame numbers are printed in the rows of every plan on the sheet; the row of THIS plan is the first one below its title
        _below = [y for y in rowy if y > v.title[3] + 100]
        if _below and FRAME_ROW_NEAREST:
            _y0 = min(_below)
            rowy = [y for y in rowy if abs(y - _y0) < 12]
        # R-V7c: the same row printed ABOVE and BELOW the plan (no other plan title between): the plan lies between the two rows
        _cl = []
        for y_ in sorted(y for y in rowy if y > v.title[3]):
            if _cl and y_ - _cl[-1][-1] < 30:
                _cl[-1].append(y_)
            else:
                _cl.append([y_])
        _two = None
        if len(_cl) >= 2 and not FRAME_ROW_NEAREST:
            ya_, yb_ = statistics.median(_cl[0]), statistics.median(_cl[1])
            if ya_ - v.title[3] < 200 and yb_ - ya_ < 1700 and not any(ya_ < u.title[1] < yb_ and abs(u.title[0] - v.title[0]) < 500 for u in v._others):
                _two = (ya_, yb_)
        ycut = statistics.median(rowy) if rowy else v.title[3] + 900
        if _cl and not _two:
            ycut = statistics.median(_cl[0]) if (len(_cl) > 1 and statistics.median(_cl[0]) - v.title[3] < 200) else ycut
        below = [u.title[1] for u in v._others if u.title[1] > ycut and abs(u.title[0] - v.title[0]) < 500]
        if _two:
            v.ybounds = (_two[0] - 15, _two[1] + 15)
            v.evidence['frame_row'] = 'above and below the plan (R-V7c)'
        elif ycut - v.title[3] < 200:
            # R-V7b: the number row sits right under the title = top of the plan; the plan hangs below it
            v.ybounds = (ycut - 15, min(ycut + 1700, min(below) if below else 1e9))
            v.evidence['frame_row'] = 'above the plan'
        else:
            v.ybounds = (v.title[3] + 5, ycut + 15)
            v.evidence['frame_row'] = 'below the plan'
        v.evidence['frame_labels'] = [m for m, _ in row]
        v.evidence['frame_label_residual_mm'] = round(max(abs(x - (v.x0 + ft0(m) / v.k)) for m, x in row) * v.k, 1)
        v.frame_fn = ft0
    ylab = v.ybounds[0]
    yend = v.ybounds[1]
    v.evidence['scale'] = f'1/{n}'
    # centre line vote. R-V9: the OFF C.L labels sit at the plan edge, which can lie well outside the
    # span of the boxed frame labels; widen the window when the narrow one gives fewer than 3 labels.
    region_x = (xmin, xmax)
    _n = sum(1 for w in page.words if w.text.strip() == 'OFF C.L' and w.vertical
             and region_x[0] < w.cx < region_x[1] and ylab < w.cy < yend)
    if _n < 3:
        region_x = (xmin - 120, xmax + 300)
        v.evidence['centre_line_window'] = 'widened (R-V9)'
    def _vote(region_x):
        votes = Counter()
        labels = []
        offs = [w for w in page.words if w.text.strip() == 'OFF C.L' and w.vertical
                and region_x[0] < w.cx < region_x[1] and ylab < w.cy < yend]
        nums = [w for w in page.words if re.fullmatch(r'\d{3,5}', w.text.strip()) and w.vertical]
        hsegs = [s for s in page.segs if s.horizontal and s.length > 15
                 and region_x[0] < max(s.a[0], s.b[0]) and min(s.a[0], s.b[0]) < region_x[1]]
        for o in offs:
            cand = [u for u in nums if abs(u.cx - o.cx) < 12 and abs(u.cy - o.cy) < 30 and u is not o]
            if not cand:
                continue
            num = min(cand, key=lambda u: abs(u.cy - o.cy) + abs(u.cx - o.cx))
            val = int(num.text)
            bx0 = min(o.bbox[0], num.bbox[0]) - 4
            bx1 = max(o.bbox[2], num.bbox[2]) + 4
            ytop = min(o.bbox[1], num.bbox[1])
            ybot = max(o.bbox[3], num.bbox[3])
            near = [s for s in hsegs if min(s.a[0], s.b[0]) - 1 < (bx0 + bx1) / 2 < max(s.a[0], s.b[0]) + 1
                    and (ytop - 25 < s.a[1] < ybot + 25)]
            for s in near:
                for sg in (1, -1):
                    c = s.a[1] + sg * val / v.k
                    votes[round(c * 2) / 2] += 1
            labels.append(val)
        keys_ = sorted(votes)
        best_ = max(keys_, key=lambda c: sum(votes[k] for k in keys_ if abs(k - c) <= 0.75)) if votes else None
        n_ = sum(votes[k] for k in keys_ if abs(k - best_) <= 0.75) if votes else 0
        return votes, labels, n_

    votes, labels, _nv = _vote(region_x)
    if _nv < 3 and not v.evidence.get('centre_line_window'):
        # R-V9b: a window holding a few interior labels can still vote for a wrong line (1001 A-deck: 3 labels, 2 votes, CL 34 pt off).
        # A true centre line is voted by every label; fewer than 3 agreeing votes = widen to the plan edge columns and vote again.
        region_x = (xmin - 120, xmax + 300)
        v.evidence['centre_line_window'] = 'widened (R-V9b: < 3 agreeing votes)'
        votes, labels, _nv = _vote(region_x)
    if not votes:
        raise ValueError(f'{v.name}: no OFF C.L labels to locate the centre line')
    # accept the densest 1-pt window
    keys = sorted(votes)
    best = max(keys, key=lambda c: sum(votes[k] for k in keys if abs(k - c) <= 0.75))
    win = [k for k in keys if abs(k - best) <= 0.75 for _ in range(votes[k])]
    vote_cl = statistics.median(win)
    # centre line drawn as a chain (long-short dash) line: the row with the most
    # chain-line length across the plan is C.L.  Preferred over label votes.
    rows = Counter()
    for s in page.segs:
        if s.horizontal and s.dash.startswith('dash4') and region_x[0] < s.a[0] < region_x[1] \
                and ylab < s.a[1] < yend:
            rows[round(s.a[1] * 2) / 2] += s.length
    chain_cl = None
    if rows:
        y, L = rows.most_common(1)[0]
        if L > 0.25 * (region_x[1] - region_x[0]):
            chain_cl = y
    # candidates: label vote and the three longest chain rows; pick the one about
    # which the plan is most symmetric (drawing note: 'both sides symmetric
    # except as shown') - robust when a view has several chain lines.
    cands = {round(vote_cl * 2) / 2: 'OFF C.L label votes'}
    for y, L in rows.most_common(3):
        if L > 0.15 * (region_x[1] - region_x[0]):
            cands.setdefault(y, 'chain line')
    hs = [s for s in page.segs if s.horizontal and s.length > 20 and not s.dash
          and region_x[0] < s.a[0] < region_x[1] and ylab < s.a[1] < yend]

    def sym(c):
        ys = {}
        for s in hs:
            ys.setdefault(round(s.a[1] * 2) / 2, []).append(sorted((s.a[0], s.b[0])))
        n = 0
        for y, xs in ys.items():
            m = ys.get(round((2 * c - y) * 2) / 2)
            if not m or abs(y - c) < 1:
                continue
            for x0, x1 in xs:
                if any(min(x1, b1) - max(x0, b0) > 0.5 * (x1 - x0) for b0, b1 in m):
                    n += x1 - x0
        return n
    scores = {c: sym(c) for c in cands}
    best_c = max(scores, key=scores.get)
    v.cl_y = best_c
    v.evidence['centre_line_source'] = cands[best_c] + ' (best symmetry)'
    # R-V18 (owner: text first): a half model ('(S)') has no symmetry, so the symmetry vote can pick a chain line far from the printed OFF C.L
    # dimensions (COMPRESSOR ROOM TOP: 11.8 m). When the two differ by more than 3 m the printed OFF C.L labels win.
    if abs(vote_cl - best_c) * v.k > 3000 and len(win) >= 3:
        v.cl_y = vote_cl
        v.evidence['centre_line_source'] = f'OFF C.L label votes (chain line {best_c} was {abs(vote_cl - best_c) * v.k:.0f} mm away - text first)'
    v.evidence['centre_line_candidates'] = {f'{c}': round(sc) for c, sc in scores.items()}
    v.evidence['centre_line_votes'] = len(win)
    v.evidence['centre_line_label_vote_disagreement_mm'] = round(abs(vote_cl - v.cl_y) * v.k, 1)
    v.evidence['offcl_labels'] = len(labels)
    # generous window; the deck footprint (largest connected face set) trims it
    half = 470 if mode == 'A' else 800
    v.region = (xmin - 300, max(v.cl_y - half, ylab - 5) if mode == 'B' else v.cl_y - half, xmax + 300,
                min(v.cl_y + half, yend + 15) if mode == 'B' else v.cl_y + half)
    if mode == 'B':
        # R-V10: the plan outline can run past the label zone (1005 WEATHER SHIELD: top edge 50 pt above ylab); grow the window over
        # long solid horizontals that continue the plan upwards / downwards (gaps < 40 pt)
        lines_y = sorted({round(s.a[1], 1) for s in page.segs if s.horizontal and s.length > 60 and not s.dash
                          and v.region[0] < s.a[0] < v.region[2] and v.region[0] < s.b[0] < v.region[2]})
        y0, y1 = v.region[1], v.region[3]
        for y in reversed([y for y in lines_y if y < y0]):
            if y0 - y < 40 and y > v.cl_y - half:
                y0 = y - 3
        for y in [y for y in lines_y if y > y1]:
            if y - y1 < 40 and y < v.cl_y + half:
                y1 = y + 3
        v.region = (v.region[0], y0, v.region[2], y1)
    return v


def offcl_lines(page, v):
    """(printed value, ship Y of the line it labels) for every 'NNNN OFF C.L'."""
    out = []
    r = v.region
    offs = [w for w in page.words if w.text.strip() == 'OFF C.L' and w.vertical
            and r[0] < w.cx < r[2] and r[1] < w.cy < r[3]]
    nums = [w for w in page.words if re.fullmatch(r'\d{3,5}', w.text.strip()) and w.vertical]
    hsegs = [s for s in page.segs if s.horizontal and s.length > 15]
    for o in offs:
        cand = [u for u in nums if abs(u.cx - o.cx) < 12 and abs(u.cy - o.cy) < 30]
        if not cand:
            continue
        num = min(cand, key=lambda u: abs(u.cy - o.cy) + abs(u.cx - o.cx))
        val = int(num.text)
        xc = (min(o.bbox[0], num.bbox[0]) + max(o.bbox[2], num.bbox[2])) / 2
        ytop = min(o.bbox[1], num.bbox[1])
        ybot = max(o.bbox[3], num.bbox[3])
        near = [s for s in hsegs if min(s.a[0], s.b[0]) - 30 < xc < max(s.a[0], s.b[0]) + 1      # R-D6: the extension line may start a few pt right of the label
                and ytop - 25 < s.a[1] < ybot + 30]
        if not near:
            continue
        s = min(near, key=lambda s: abs(abs(v.Y(s.a[1])) - val))
        if abs(abs(v.Y(s.a[1])) - val) < 80:
            out.append((val, v.Y(s.a[1])))
    return out


NL_RX = re.compile(r'^NO\.?\s*(\d+)\s*L\.?$', re.I)


def nl_lines(page, v):
    """R-NL: 'NO. nL' labels printed at the plan edge, each standing on a horizontal underline that runs to a deck longitudinal.
    Returns [(n, ship Y of the underline)] for the labels inside the plan window (the underline is the line's own position)."""
    out = []
    r = v.region
    hs = [s for s in page.segs if s.horizontal and s.length > 20]
    for w in page.words:
        m = NL_RX.match(' '.join(w.text.split()))
        if not m or not (r[0] < w.cx < r[2] and r[1] < w.cy < r[3]) or w.vertical:
            continue
        near = [s for s in hs if min(s.a[0], s.b[0]) - 4 <= w.cx <= max(s.a[0], s.b[0]) + 4 and w.bbox[3] - 3 <= s.a[1] <= w.bbox[3] + 8]
        if not near:
            continue
        s = min(near, key=lambda q: abs(q.a[1] - w.bbox[3]))
        out.append((int(m.group(1)), round(v.Y(s.a[1]), 1), s.a[1], w.cx))
    out = sorted(set(out))
    # printed spacing chain ('880 880 880 840 ...' between the lines, first one from the centre line): a measured Y within 15 mm of the running sum is replaced by the printed value
    if out:
        ys = [(n, py) for n, _, py, _ in out]
        xr = max(cx for *_, cx in out)
        nums = [(u.cy, int(u.text), u.cx) for u in page.words if re.fullmatch(r'\d{3,4}', u.text.strip()) and xr + 5 < u.cx < xr + 200]
        if nums:      # the spacing numbers form the column nearest the labels (the 2640 / 5160 / 7680 OFF C.L totals stand in a second column)
            x1 = min(q[2] for q in nums)
            nums = [(a, b) for a, b, c in nums if abs(c - x1) < 8]
        cl = v.cl_y
        edges = [cl] + [py for _, py in sorted(ys, key=lambda q: abs(q[1] - cl))]
        tot, res = 0, []
        for (n, Ym, py, _), (a, b) in zip(sorted(out, key=lambda q: abs(q[2] - cl)), zip(edges, edges[1:])):
            cand = [val for cy, val in nums if min(a, b) - 3 <= cy <= max(a, b) + 3]
            if len(cand) != 1:
                res = None
                break
            tot += cand[0]
            res.append((n, float(tot) if abs(tot - abs(Ym)) <= 15 else Ym) if Ym > 0 else (n, -float(tot) if abs(tot - abs(Ym)) <= 15 else Ym))
        return sorted(res) if res else sorted((n, Ym) for n, Ym, _, _ in out)
    return []
