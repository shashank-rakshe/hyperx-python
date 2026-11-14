"""R-DT: detail / section views printed around the plans ('"1A1-2" SEC.', '"1B1-2" ELEV.', ...).
Each view is indexed by its title; from it we read: the deck it belongs to (label 'COMP. ROOM TOP' / '41460 A/B'), the OFF C.L pair it spans,
the stiffener section ('150 U.A') and the bracket marks (B25 ...) at its ends.  Owner rule: the sections are the source of bracket sizes
(and of anything else drawn there); a plan bracket is sized from the section that spans the same OFF C.L pair."""
import re
from collections import Counter
from .elevation import BKT_TABLE, parse_bkt_table

TITLE = re.compile(r'^"\d[A-Z]\d-\d"\s*(SEC|ELEV|DET)')
MARK = re.compile(r'^B\d{2}$')
DECKLBL = re.compile(r'(COMP\.? ROOM TOP|TRUNK DECK|\d{5} A/B)')
_CACHE = {}
USED = set()          # titles of the views that were turned into geometry / sizes in this run
ALL = {}              # title -> view (every page processed)


def index(page):
    key = id(page)
    if key in _CACHE:
        return _CACHE[key]
    parse_bkt_table(page)
    tit = sorted([w for w in page.words if TITLE.match(w.text.strip())], key=lambda w: (w.bbox[0] // 150, w.bbox[1]))
    views = []
    for t in tit:
        nxt = [u.bbox[1] for u in tit if abs(u.bbox[0] - t.bbox[0]) < 40 and u.bbox[1] > t.bbox[3] + 5]
        y1 = min(min(nxt) if nxt else 1e9, t.bbox[3] + 135)
        ws = [w for w in page.words if t.bbox[0] - 15 < w.cx < t.bbox[0] + 330 and t.bbox[3] < w.cy < y1 and not TITLE.match(w.text.strip())]
        # OFF C.L values: number printed right above an 'OFF C.L' word
        offs = []
        for o in ws:
            if o.text.replace(' ', '').startswith('OFFC.L'):
                nn = [n for n in ws if re.fullmatch(r'\d{3,5}', n.text.strip()) and abs(n.cx - o.cx) < 14 and 0 < o.cy - n.cy < 16]
                if nn:
                    offs.append((int(nn[0].text), nn[0].cx))
        offs.sort(key=lambda a: a[1])
        marks = sorted([(w.cx, w.text.strip()) for w in ws if MARK.match(w.text.strip()) and w.text.strip() in BKT_TABLE])
        labels = sorted({m.group(1) for w in ws for m in [DECKLBL.search(w.text)] if m})
        secs = [w.text.strip() for w in ws if re.fullmatch(r'\d+ [UIL]\.A', w.text.strip())]
        pt = [re.search(r'PLATE\s+THK\.?\s*:\s*([\d.]+)', w.text) for w in page.words
              if t.bbox[0] - 15 < w.cx < t.bbox[0] + 330 and t.bbox[1] < w.cy < t.bbox[3] + 8]
        pt = [float(m.group(1)) for m in pt if m]
        # vertical drop: the 3-digit dimension printed beside a vertical dimension line (largest plain number that is not an OFF C.L value)
        plain = [int(w.text) for w in ws if re.fullmatch(r'\d{3}', w.text.strip()) and int(w.text) not in [o[0] for o in offs]]
        ah = [re.search(r'(\d+\.\d)\s*"AH"', w.text) for w in ws]
        ah = [float(m.group(1)) for m in ah if m]
        fr = []
        for w in ws:
            q = re.fullmatch(r'(\d{2,3})\s*([+-])\s*(\d{3,4})', w.text.strip())
            if q:
                fr.append((w.cx, int(q.group(1)), 1 if q.group(2) == '+' else -1, int(q.group(3))))
        fr.sort()
        views.append({'frames': fr, 'ah_thk': ah[0] if ah else None, 'plate_thk': ah[0] if ah else None, 'plate_thk': pt[0] if pt else None, 'drop': float(max(plain)) if plain else None, 'title': t.text.strip(), 'kind': TITLE.match(t.text.strip()).group(1), 'x': t.bbox[0], 'y': t.bbox[1],
                      'off_cl': [o[0] for o in offs], 'off_x': [o[1] for o in offs], 'marks': marks, 'deck': labels, 'sections': secs})
    for v_ in views:
        ALL.setdefault(v_['title'] + '@' + str(round(v_['x'])) + ',' + str(round(v_['y'])), v_)
    _CACHE.clear()
    _CACHE[key] = views
    return views


def deck_matches(view, deck_name):
    n = deck_name.upper()
    for l in view['deck']:
        if 'ROOM TOP' in l and 'ROOM TOP' in n:
            return True
        if 'TRUNK' in l and 'TRUNK' in n:
            return True
        d = re.match(r'(\d{5})', l)
        if d and d.group(1) in n:
            return True
    return False


def bracket_spans(page, deck_name):
    """[(ya, yb, size_a, size_b, title)] for the SEC views of this deck: beam between two OFF C.L girders with B marks at its ends"""
    out = []
    for v in index(page):
        if v['kind'] != 'SEC' or len(v['off_cl']) < 2 or not v['marks'] or not deck_matches(v, deck_name):
            continue
        a, b = v['off_cl'][0], v['off_cl'][-1]
        xa, xb = v['off_x'][0], v['off_x'][-1]
        sa = sb = None
        for cx, txt in v['marks']:
            if abs(cx - xa) < abs(cx - xb):
                sa = sa or BKT_TABLE[txt]
            else:
                sb = sb or BKT_TABLE[txt]
        out.append((a, b, sa, sb, v['title']))
    return out


def typical_size(page, deck_name):
    c = Counter()
    for v in index(page):
        if v['kind'] in ('SEC', 'ELEV') and deck_matches(v, deck_name):
            for _, t in v['marks']:
                c[BKT_TABLE[t]] += 1
    return c.most_common(1)[0][0] if c else None


def bracket_spans_x(page, deck_name, ft):
    """ELEV views: beam along X between two 'FR.n +/- offset' marks, bracket marks at its ends -> [(xa, xb, size_a, size_b, title)] (mm)"""
    out = []
    for v in index(page):
        if v['kind'] != 'ELEV' or len(v['frames']) < 2 or not v['marks'] or not deck_matches(v, deck_name):
            continue
        (xa_p, na, sa_, oa), (xb_p, nb, sb_, ob) = v['frames'][0], v['frames'][-1]
        xa, xb = ft(na) + sa_ * oa, ft(nb) + sb_ * ob
        sza = szb = None
        for cx, txt in v['marks']:
            if abs(cx - xa_p) < abs(cx - xb_p):
                sza = sza or BKT_TABLE[txt]
            else:
                szb = szb or BKT_TABLE[txt]
        out.append((xa, xb, sza, szb, v['title']))
    return out


def page_typical(page):
    """R-DT (sections): most common bracket mark size (B25/B30/..) printed on the page, any view -> (W, T) or None"""
    c = Counter()
    for v in index(page):
        for _, t in v['marks']:
            c[BKT_TABLE[t]] += 1
    return c.most_common(1)[0][0] if c else None
