"""Command line: deck plan(s) in a PDF -> moulded-line ship XML + review + report.

  python -m deckrules.run DRAWING.pdf --page 1 --deck "B - DECK" --out out_dir
  python -m deckrules.run DRAWING.pdf --page 1 --deck all --out out_dir \
         --settings project_settings.json --reference SAMPLE.xml   (scoring only)

The reference XML, when given, is used ONLY to score the result afterwards.
"""
from shapely.geometry import box, Polygon
import argparse
import json
import os
import re
import sys

from . import pdfsrc, view, deckplan, members, snap, export, supports, plot


def deck_code(name):
    if re.match(r'^\d{4,6}\s*A/B', name):          # height-only plan title '39945 A/B' -> code Z39945
        return 'Z' + re.match(r'^(\d+)', name).group(1)
    head = name.split('-')[0].strip().rstrip('.')
    code = re.sub(r'[^A-Z]', '', head)
    if code in ('NOSTR',):                      # 'NO.1 STR.' .. 'NO.3 STR.' must stay distinct
        code += re.sub(r'[^0-9]', '', head)
    return code


def load_settings(path):
    s = {'frame_spacing_mm': None, 'frame0_x_mm': 0.0, 'frame_table': {}, 'section_aliases': {},
         'reference_deck_codes': {}}
    if path:
        with open(path, encoding='utf-8') as f:
            s.update(json.load(f))
    # R-YC (review 2026-10-26): yard conventions (owner-confirmed aliases, answers) are kept per yard and reused for every drawing of
    # that yard; per-project owner answers carry their source. Settings themselves hold only project data.
    base0 = os.path.dirname(os.path.abspath(path)) if path else '.'
    s['_answer_sources'] = {}
    if s.get('yard'):
        yp = os.path.join(base0, 'yards', s['yard'] + '.json')
        if os.path.exists(yp):
            with open(yp, encoding='utf-8') as f:
                yd = json.load(f)
            for k_, v_ in yd.get('section_aliases', {}).items():
                s['section_aliases'].setdefault(k_, v_)
            for a_ in yd.get('answers', []):
                s.setdefault(a_['key'], a_['value']); s['_answer_sources'][a_['key']] = 'yard: ' + a_.get('source', '')
            if yd.get('pipe_table_csv') and not s.get('pipe_table_csv'):       # the yard's pipe standard (owner-supplied)
                s['pipe_table_csv'] = os.path.join(base0, 'yards', yd['pipe_table_csv'])
                s['_answer_sources']['pipe_table_csv'] = 'yard: ' + yd.get('pipe_table_source', '')
    if s.get('owner_answers'):
        ap_ = s['owner_answers'] if os.path.isabs(s['owner_answers']) else os.path.join(base0, s['owner_answers'])
        with open(ap_, encoding='utf-8') as f:
            for a_ in json.load(f).get('answers', []):
                s[a_['key']] = a_['value']; s['_answer_sources'][a_['key']] = a_.get('source', '')
    if s.get('frame_table_csv'):          # R-F1: frame table supplied as CSV 'frame,x_mm' (GA plan / frame table export)
        import csv
        base = os.path.dirname(os.path.abspath(path)) if path else '.'
        p = s['frame_table_csv']
        p = p if os.path.isabs(p) else os.path.join(base, p)
        with open(p, encoding='utf-8-sig') as f:
            for row in csv.reader(f):
                try:
                    s['frame_table'][str(int(float(row[0])))] = float(row[1])
                except (ValueError, IndexError):
                    continue
    view.FRAME_ROW_NEAREST = bool(s.get('frame_row_nearest', False))
    view.PLAN_HEIGHTS.clear(); view.PLAN_HEIGHTS.update(s.get('plan_heights_mm', {}))
    from . import pipes as _pipes
    base_ = os.path.dirname(os.path.abspath(path)) if path else '.'
    s['pipe_table'] = _pipes.load_table(s.get('pipe_table_csv'), base_)       # owner's pipe schedule (OD / thickness); empty -> pipes pending
    return s


def frame_x_fn(settings, v):
    table = {int(k): float(x) for k, x in settings.get('frame_table', {}).items()}
    sp = settings.get('frame_spacing_mm') or v.frame_space
    x0 = settings.get('frame0_x_mm', 0.0)
    anc = settings.get('frame_anchor')        # R-F2: {'frame': n, 'x_mm': X} = the start point of this drawing
    if anc:
        na, xa = int(anc['frame']), float(anc['x_mm'])
        f = lambda n: table.get(n, xa + (n - na) * sp)
        f.anchor = (na, xa)
        if settings.get('frame_table_source'):
            f.known = lambda n: int(n) in table
        return f
    f = lambda n: table.get(n, x0 + n * sp)
    if settings.get('frame_table_source'):       # v2.106: the table is the FRAME CHAIN of written spacings - a frame outside it is unknown, never n x spacing
        f.known = lambda n: int(n) in table
    return f


def mark_y(page, v, piece):
    """page y of the row of dimension numbers just above the box"""
    import statistics as _st
    ys = [w.cy for w in page.words if re.fullmatch(r'#\d', w.text.strip()) and abs(v.X(w.cx) - (piece.bounds[0] + piece.bounds[2]) / 2) < 1500 and abs(v.Y(w.cy) - (piece.bounds[1] + piece.bounds[3]) / 2) < 1500]
    return (_st.median(ys) - 8.4) if ys else 0.0


def _extension_deck(page, v, D, piece, members_, slog, settings):
    """R-EP1 extension platform: a box attached beyond the labelled frame limit, whose section marker ("1B1-3") names an ELEV view that
    lists the other deck ('41522 A/B') and its 'PLATE THK. : 11.0'. Built as its own deck block at that height."""
    import math as _mm
    b = piece.bounds
    cx_s, cy_s = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    mark = None
    for w in page.words:
        m = re.fullmatch(r'"(\w+-\d+)"', w.text.strip())
        if m and w.vertical and abs(v.X(w.cx) - cx_s) < 2500 and abs(v.Y(w.cy) - cy_s) < 2500:
            mark = m.group(1)
            break
    if not mark:
        return None
    title = next((w for w in page.words if w.text.strip() == f'"{mark}" ELEV.'), None)
    if not title:
        return None
    z2 = None
    t2 = None
    for w in page.words:
        m2 = re.fullmatch(r'(\d{5}) A/B', w.text.strip())
        if m2 and abs(w.cy - title.cy) < 90 and abs(w.cx - title.cx) < 450 and int(m2.group(1)) != int(v.z):
            z2 = float(m2.group(1))
        m3 = re.search(r'PLATE\s+THK\.\s*:\s*([\d.]+)', w.text)
        if m3 and abs(w.cy - title.cy) < 40 and abs(w.cx - title.cx) < 450:
            t2 = float(m3.group(1))
    if not z2:
        return None
    # R-DX4: the numbers printed above the box ('600' over '#3', '35' over '#1') are the carling offsets from the box edge (labels first)
    _wd = [int(w.text) for w in page.words if re.fullmatch(r'\d{3,4}', w.text.strip()) and not w.vertical and abs(int(w.text) - (b[2] - b[0])) < 150
           and abs(v.X(w.cx) - cx_s) < 1500 and abs(v.Y(w.cy) - cy_s) < 2500]
    _rt = D.near('X', b[2], 60.0)
    left = ((_rt[1] if _rt else b[2]) - min(_wd, key=lambda n: abs(n - (b[2] - b[0])))) if _wd else b[0]      # box edge = its printed width (1200) from the frame line
    exp_x = []
    for w in page.words:
        if re.fullmatch(r'\d{2,4}', w.text.strip()) and not w.vertical and abs(v.X(w.cx) - cx_s) < 1500 and abs(w.cy - mark_y(page, v, piece)) < 25:
            mk = [u for u in page.words if re.fullmatch(r'#\d', u.text.strip()) and abs(u.cx - w.cx) < 8 and 0 < u.cy - w.cy < 14]
            if mk and int(w.text) < 1200:
                exp_x.append((left + float(w.text), mk[0].text.strip()))
    if os.environ.get('FPDBG'): print('EXPX', left, exp_x, [m['a'] for m in members_])
    for m in members_:
        if abs(m['a'][0] - m['b'][0]) < 1.0 and exp_x:
            e = min(exp_x, key=lambda t: abs(t[0] - m['a'][0]))
            if abs(e[0] - m['a'][0]) < 80:
                m['a'] = (e[0], m['a'][1])
                m['b'] = (e[0], m['b'][1])
                m.setdefault('evidence', []).append(f'R-DX4 offset {e[0] - left:.0f} from the box edge (printed, {e[1]})')
    name = f'{int(z2)} A/B'
    poly = snap.snap_polygon(D, piece, slog)
    if poly.geom_type != 'Polygon':
        poly = max(poly.geoms, key=lambda g: g.area)
    # the box is a rectangle: left edge = printed width from the frame line, Y edges = printed OFF C.L / dimension datums (no drawing slivers)
    _ylo = D.near('Y', piece.bounds[1], 60.0)
    _yhi = D.near('Y', piece.bounds[3], 60.0)
    poly = box(left, _ylo[1] if _ylo else piece.bounds[1], (D.near('X', b[2], 60.0) or (0, b[2]))[1], _yhi[1] if _yhi else piece.bounds[3])
    for m in members_:      # a stiffener of the platform runs edge to edge (no gap to its supports)
        if abs(m['a'][0] - m['b'][0]) < 1.0:
            ya, yb = (poly.bounds[3], poly.bounds[1]) if m['a'][1] > m['b'][1] else (poly.bounds[1], poly.bounds[3])
            m['a'], m['b'] = (m['a'][0], ya), (m['b'][0], yb)
    deck2 = {'name': name, 'code': deck_code(name), 'z': z2, 'zones': [{'poly': poly, 't': t2 or v.notes.get('plate') or 11.0, 'source': f'extension platform of {v.name} named by "{mark}" ELEV.', 'grade': 'A'}],
             'openings': [], 'footprint': poly, 'members': members_, 'deep': [], 'coamings': []}
    return deck2


_LONGI_CACHE = {}


def _circle_by_labels(page, v, D, o, slog):
    """R-HO1 (owner: labels first, then dimensions, then vector): a circular opening keeps its true round shape.
    diameter = printed number near it (e.g. 330, 420) when it matches the traced one; centre Y = OFF C.L datum, centre X = datum -/+ a printed
    dimension number next to it (200 from a beam line, 630 from FR.47); otherwise the traced centre. Vertices are NOT snapped (it distorted the circle)."""
    import math as _mm
    from shapely.geometry import Point
    c_pg = o.centroid
    r_tr = _mm.sqrt(o.area / _mm.pi) * v.k
    poly = deckplan.to_ship(v, o)
    cx, cy = poly.centroid.x, poly.centroid.y
    nums = []
    for w in page.words:
        t = w.text.strip().replace('\u00d8', '')
        if re.fullmatch(r'\d{2,4}', t) and not w.vertical and _mm.hypot(w.cx - c_pg.x, w.cy - c_pg.y) < 130:
            nums.append((int(t), _mm.hypot(w.cx - c_pg.x, w.cy - c_pg.y)))
    dia = None
    for n, d_ in sorted(nums, key=lambda t: t[1]):
        if abs(n - 2 * r_tr) < 0.08 * n:
            dia = n
            break
    r = dia / 2.0 if dia else r_tr
    # R-HO2 (2026-10-25): a dimension number gives the centre only through ITS OWN dimension line: the line at the number, drawn length =
    # printed value (+-3 %), one end on this circle's centre line, the other end = datum. Centre X = datum +- printed value.
    # EC weather shield: '1500' from the FR.19+1/2 wall -> X 32700; the nearest-datum guess gave 32790 and the hole cut its carling.
    r_pg = r_tr / v.k
    for w in sorted(page.words, key=lambda w: _mm.hypot(w.cx - c_pg.x, w.cy - c_pg.y)):
        t = w.text.strip()
        if w.vertical or not re.fullmatch(r'\d{3,5}', t) or _mm.hypot(w.cx - c_pg.x, w.cy - c_pg.y) > 130 or int(t) == dia:
            continue
        n = int(t)
        for sg in page.segs:
            if not sg.horizontal or abs(sg.length * v.k - n) > 0.03 * n or abs(sg.a[1] - w.cy) > 10:
                continue
            lo, hi = sorted((sg.a[0], sg.b[0]))
            if not lo - 2 < w.cx < hi + 2:
                continue
            for e_c, e_d in ((lo, hi), (hi, lo)):
                if abs(e_c - c_pg.x) < 0.25 * r_pg:
                    xd = deckplan.to_ship(v, Point(e_d, c_pg.y)).x
                    xc = deckplan.to_ship(v, Point(e_c, c_pg.y)).x
                    hit = D.near('X', xd, 40.0)
                    if hit:
                        xd = hit[1]
                    cx = xd + (n if xc > xd else -n)
                    slog['circle_x_from_dimension_line'] = slog.get('circle_x_from_dimension_line', 0) + 1
                    hy = D.near('Y', cy, 40.0)
                    return Point(cx, hy[1] if hy else cy).buffer(r, 32), 'dimension line'
    best = None
    for n, d_ in sorted(nums, key=lambda t: t[1]):      # nearest printed number first (the dimension of THIS circle), then farther ones
        if n == dia or n < 100:      # < 100 = frame number / mark, not a dimension
            continue
        cand = [(abs(x_d + sg * n - cx), x_d + sg * n, f'{src} {"+" if sg > 0 else "-"} printed {n}')
                for x_d, src in D.d["X"].items() for sg in (-1, 1) if abs(x_d + sg * n - cx) < 40]   # R-HO4: a printed number only refines the traced centre (<= 40 mm, 1 pt)
        if cand:
            best = min(cand)
            break
    if os.environ.get('FPDBG'): print('HOLE', round(cx), round(cy), dia, sorted(nums, key=lambda t: t[1])[:6], best)
    if best:
        cx = best[1]
        slog['circle_x_from_dimension'] = slog.get('circle_x_from_dimension', 0) + 1
    hy = D.near('Y', cy, 40.0)
    if hy:
        cy = hy[1]
    return Point(cx, cy).buffer(r, 32), ('nearest datum' if best else 'traced')


_SEC_TITLES = {}


def section_title_datums(pdf, fx):
    if pdf not in _SEC_TITLES:
        import pymupdf
        out = []
        for pn in range(len(pymupdf.open(pdf))):
            for w in pdfsrc.load_page(pdf, pn).words:
                for m in re.finditer(r'FR\.?\s*(\d{1,3})\s*(?:([+-])\s*(\d{2,5}))?\s*SEC\b', w.text.upper()):
                    n, sg, d = int(m.group(1)), m.group(2), int(m.group(3) or 0)
                    out.append((n, sg or '', d, m.group(0).replace(' ', '')))
        _SEC_TITLES[pdf] = sorted(set(out))
    return [(fx(n) + (d if sg == '+' else -d if sg == '-' else 0), lab) for n, sg, d, lab in _SEC_TITLES[pdf]]


def process_deck(page, v, settings):
    fx = frame_x_fn(settings, v)
    if settings.get('frame_spacing_mm'):   # R-V6c: project spacing overrides drawing notes (notes can be web-frame pitch: 1540/4200)
        v.frame_space = int(settings['frame_spacing_mm'])
    view.calibrate(page, v, fx)
    fx = v.frame_fn or fx
    pz = deckplan.plate_zones_and_openings(page, v)
    fp = pz['footprint']
    mem, carl = members.extract(page, v, fp, dict(settings, frame_x=fx))
    D, dinfo = snap.build(page, v, fx, view.offcl_lines(page, v))
    # R-D7 (2026-10-25): every section title 'FR.n+d SEC.' / 'FR.n SEC.' on ANY sheet is a wall / web plane at that X, so it is an X
    # datum of every plan (EC: the weather shield forward edge stayed at the traced 38392..38406 instead of FR.24+800 = 38400)
    if settings.get('_pdf'):
        try:
            for xd, lab in section_title_datums(settings['_pdf'], fx):
                D.add('X', xd, lab)
        except Exception as _e:
            from . import openitems as _oi
            _oi.record('run R-D7 section-title datums', _e)
    slog = {'printed': 0, 'traced': 0}
    zones = []
    for z in pz['zones']:
        zp = snap.snap_polygon(D, deckplan.to_ship(v, z['poly']), slog)
        if zp.is_empty or zp.area < 2e4:          # < 0.02 m2 slivers between double lines
            continue
        zones.append({'poly': zp, 't': z['t'], 'source': z['source'], 'grade': z.get('grade', 'A')})
    if os.environ.get('FPDBG'): print('PZ', len(pz['zones']), len(zones))
    from . import insert as _in
    for ins in (_in.find(page, v) if settings.get('build_hatched', False) else []):   # R-HT1: hatched = NOT built (owner 2026-10-23); R-IN1: thick insert plate (hatched circle OUT DIA) replaces the deck plate inside the circle
        for z in zones:
            z['poly'] = z['poly'].difference(ins['poly'])
        zones.append({'poly': ins['poly'], 't': ins['t'], 'source': ins['source'], 'grade': ins['grade']})
    openings = []
    for o, why in pz['openings']:
        src = None
        if why == 'circle':
            op, src = _circle_by_labels(page, v, D, o, slog)      # R-HO1: circle = centre by label/dimension + printed diameter; vertices are never snapped
        else:
            op = snap.snap_polygon(D, deckplan.to_ship(v, o), slog)
        if not op.is_empty:
            openings.append({'poly': op, 'why': why, 'xsrc': src, 'tx': deckplan.to_ship(v, o.centroid).x})
    # R-HO3 (2026-10-25): circles on one common centre line (traced centres within 30 mm in X) share the X of the one that is dimensioned
    for a in openings:
        if a.get('xsrc') == 'dimension line':
            for b in openings:
                if b is not a and b.get('xsrc') not in (None, 'dimension line') and abs(b['tx'] - a['tx']) < 30:
                    c, r_ = b['poly'].centroid, (b['poly'].bounds[2] - b['poly'].bounds[0]) / 2.0
                    from shapely.geometry import Point as _P
                    b['poly'] = _P(a['poly'].centroid.x, c.y).buffer(r_, 32)
                    b['xsrc'] = 'common centre line'
                    slog['circle_x_common_line'] = slog.get('circle_x_common_line', 0) + 1
    for a in openings:
        a.pop('xsrc', None); a.pop('tx', None)
    footprint = snap.snap_polygon(D, deckplan.to_ship(v, fp), slog)
    if footprint.geom_type != 'Polygon':      # R-FP3: snapping noise on scans can split the outline; keep the main body
        footprint = max(footprint.geoms, key=lambda g: g.area)
    footprint = Polygon(footprint.exterior)
    # R-DM2: thin protrusions (< 2*DM_OPEN mm wide/high, e.g. dimension extension lines + section-marker brackets closed into the outline) are not deck
    _op = float(settings.get('outline_open_mm', 350))
    if _op > 0:
        _o = footprint.buffer(-_op, join_style=2).buffer(_op, join_style=2)
        if _o.geom_type == 'MultiPolygon':
            _o = max(_o.geoms, key=lambda g: g.area)
        if (not _o.is_empty) and _o.area > 0.995 * footprint.area:
            slog['outline_stub_removed_m2'] = round((footprint.area - _o.area) / 1e6, 4)
            footprint = Polygon(_o.exterior)
    _ext_piece = None
    _lim_x = None
    # R-DM3: a plan row that prints 'FRn - d' ... 'FRn' (e.g. '47- 4000' ... '47') bounds the deck in X; box details / wall strips beyond it are not deck
    try:
        _lim = []
        for w in page.words:
            m_ = re.fullmatch(r'(\d{1,3})\s*([+-])\s*(\d{3,5})', w.text.strip())
            if not m_ or w.vertical or not (v.region[0] < w.cx < v.region[2] and v.region[1] < w.cy < v.region[3]):
                continue
            xl = fx(int(m_.group(1))) + (1 if m_.group(2) == '+' else -1) * int(m_.group(3))
            part = [u for u in page.words if re.fullmatch(r'\d{1,3}', u.text.strip()) and not u.vertical and abs(u.cy - w.cy) < 6 and u.cx > w.cx + 20
                    and abs(fx(int(u.text)) - (v.X(u.cx))) < 60]
            if part:
                u = min(part, key=lambda u: u.cx)
                _lim.append((xl, fx(int(u.text)), abs(w.cy - v.ybounds[1])))
        if os.environ.get('FPDBG'): print('LIM', _lim)
        if _lim:
            xa_, xb_, _ = min(_lim, key=lambda t: t[2])
            if xb_ > xa_:
                _c = footprint.intersection(box(xa_ - 0.5, -1e9, xb_ + 0.5, 1e9))
                _c = _c.buffer(-3, join_style=2).buffer(3, join_style=2)      # drop zero-width spikes left by wall lines
                if _c.geom_type == 'MultiPolygon':
                    _c = max(_c.geoms, key=lambda g: g.area)
                if (not _c.is_empty) and _c.area > 0.85 * footprint.area:
                    slog['x_limited_to'] = (xa_, xb_)
                    _gone = footprint.difference(box(xa_ - 0.5, -1e9, xb_ + 0.5, 1e9))
                    _gone = [g for g in getattr(_gone, 'geoms', [_gone]) if g.geom_type == 'Polygon' and g.area > 5e5
                             and (g.bounds[2] - g.bounds[0]) > 800 and (g.bounds[3] - g.bounds[1]) > 600]
                    if _gone:
                        _ext_piece = max(_gone, key=lambda g: g.area)       # R-EP1: a real box beyond the labelled frame limit = an extension platform
                    _lim_x = (xa_, xb_)
                    footprint = Polygon(_c.exterior)
    except Exception as _e:
        import traceback; traceback.print_exc()
    # R-DM1 (owner 2026-10-23): dimension rows / section markers outside the outline ("1195" extension lines + '1A1-1' bracket) must never become plates:
    # every plate zone is clipped to the deck outline; what lies outside is dropped
    _zc = []
    for z in zones:
        zp_ = z['poly'].intersection(footprint.buffer(1.0))
        if zp_.is_empty or zp_.area < 2e4 or zp_.buffer(-10.0).is_empty:      # also: a strip < 20 mm wide is a wall / double line, not a plate
            slog['outside_outline_dropped'] = slog.get('outside_outline_dropped', 0) + 1
            if os.environ.get('FPDBG'): print('DROP', [round(a) for a in z['poly'].bounds], round(z['poly'].area/1e6,2), 'clipped' if not zp_.is_empty else 'empty', round(zp_.area/1e6,2))
            continue
        z['poly'] = zp_
        _zc.append(z)
    zones = _zc
    if os.environ.get('FPDBG'): print('ZN', len(_zc))
    deep = [m for m in mem if m['kind'] == 'deep']
    rest = [m for m in mem if m['kind'] != 'deep']
    _ext_members = []
    if _ext_piece is not None:
        from shapely.geometry import LineString as _L2
        _eb = _ext_piece.buffer(40.0)
        _ext_members = [m for m in rest if _eb.contains(_L2([m['a'], m['b']]))]
        rest = [m for m in rest if m not in _ext_members]
    if _lim_x and v.notes.get('deep') and not settings.get('no_frame_line_webs'):
        # R-TR1: the labelled deck limits (FR.47-4000 and FR.47) are frame lines; the transverse of the note 'GIR. & TRANSV.' stands on each,
        # across the whole deck breadth, below the deck (owner 2026-10-23: build FR.47-4000 and FR.47 both)
        for _xx in _lim_x:
            deep.append({'kind': 'deep', 'a': (round(_xx), footprint.bounds[3]), 'b': (round(_xx), footprint.bounds[1]), 'section': None,
                         'evidence': [f'R-TR1 transverse on the frame line X={_xx:.0f}; section from the note GIR. & TRANSV. {v.notes.get("deep")} - CONFIRM against the FR section view']})
    mlog = snap.snap_members(D, mem)
    import math as _m                          # R-AN1: a corner-to-corner diagonal across the whole plan is an annotation (stiffening scheme cross), not a member
    _b = footprint.bounds
    _dg = _m.hypot(_b[2] - _b[0], _b[3] - _b[1])
    _ann = [m for m in rest if abs(m['a'][0] - m['b'][0]) > 0.1 * _dg and abs(m['a'][1] - m['b'][1]) > 0.1 * _dg
            and _m.dist(m['a'], m['b']) > 0.5 * _dg]
    if _ann:
        rest = [m for m in rest if m not in _ann]
        mlog['annotation_diagonals_dropped'] = len(_ann)
    # R-AN2 (owner 2026-10-23): tank / void notation = two diagonals crossing each other in a rectangle (+ a leader label such as 'GLYCOL STORAGE TANK',
    # 'VOID SPACE', 'COMPRESSOR ROOM'). It is an annotation, never built: drop every pair of crossing diagonal members.
    from shapely.geometry import LineString as _LS
    _dg2 = [m for m in rest if abs(m['a'][0] - m['b'][0]) > 0.1 * _m.dist(m['a'], m['b']) and abs(m['a'][1] - m['b'][1]) > 0.1 * _m.dist(m['a'], m['b'])]
    _x = set()
    for i, m1 in enumerate(_dg2):
        for m2 in _dg2[i + 1:]:
            p = _LS([m1['a'], m1['b']]).intersection(_LS([m2['a'], m2['b']]))
            if not p.is_empty and p.geom_type == 'Point':
                _x.add(id(m1)); _x.add(id(m2))
    if _x:
        rest = [m for m in rest if id(m) not in _x]
        mlog['tank_cross_dropped'] = len(_x)
    lrows = settings.get('_long_rows')
    if lrows:                                   # R-LG: longitudinal deck stiffeners from the section markers
        from . import longrows
        bsec = members.parse_section(v.notes['beam'], settings.get('section_aliases', {})) if v.notes.get('beam') else None
        lm = longrows.build_members(deck_code(v.name), lrows, footprint, openings, mem, bsec, settings, bay=float(v.frame_space or 800))
        # R-LG is CHECK-ONLY (review 2026-10-26 P1, principle 1 'only build what a view draws'): an end-on marker seen in sections
        # never creates a member along the deck. The candidate lines go to the question list; members come only from drawn lines.
        mlog['long_rows_questions'] = [f"section markers suggest a longitudinal at Y={m_['a'][1]:.0f} (X {min(m_['a'][0], m_['b'][0]):.0f}.."
                                       f"{max(m_['a'][0], m_['b'][0]):.0f}); the plan draws no line there - is it a member? size / length?" for m_ in lm][:60]
    nl = view.nl_lines(page, v) if settings.get('deck_nl_beams', True) else []
    if nl:                                      # R-NL (owner 2026-10-24): 'NO. nL' labels = deck longitudinals (beams) at those OFF C.L lines, full plated length
        from . import longrows
        bsec_ = members.parse_section(v.notes['beam'], settings.get('section_aliases', {})) if v.notes.get('beam') else None
        if bsec_:
            sides = settings.get('deck_nl_sides', 'labelled')          # 'labelled' = only the side the NO.nL labels stand on; 'both' = mirrored to the other side
            ys = [(n, Y) for n, Y in nl] + ([(n, -Y) for n, Y in nl] if sides == 'both' else [])
            nlm = longrows.build_members('NL', {'NL': [[Y, []] for n, Y in ys]}, footprint, openings, rest + mem, bsec_, settings)
            lab = dict((round(Y, 1), n) for n, Y in ys)
            for b_ in nlm:
                n_ = lab.get(round(b_['a'][1], 1))
                b_['evidence'] = [f"R-NL: 'NO. {n_}L' label at {abs(b_['a'][1]):.0f} OFF C.L = deck longitudinal; size = header {v.notes.get('beam')}; "
                                  f"full plated length minus openings (owner rule 2026-10-24)"]
            # R-NL is CHECK-ONLY (owner 2026-10-25 'no member there'; review P1): a NO.nL label is a reference line. Members come only
            # from drawn lines; the label lines without a drawn member are reported as questions.
            mlog['nl_questions'] = sorted({f"NO.{lab.get(round(b_['a'][1], 1))}L at {b_['a'][1]:.0f} OFF C.L: no drawn line - not built" for b_ in nlm})
            mlog['nl_beams_added'] = 0
        else:
            mlog['nl_beams_added'] = 'no beam size in the plan header: NO.nL lines not built (ask)'
    for m in deep:
        m['depth'], m['web_t'] = 435.0, 10.0
        txt = v.notes.get('deep', '')
        g = re.match(r'(\d+)X(\d+)', txt)
        if g:
            m['depth'], m['web_t'] = float(g.group(1)), float(g.group(2))
        f2 = re.search(r'\+\s*(\d+)X(\d+)', txt)       # face plate 'wxt' of 'WxT+wxt F.B(T)'
        m['face'] = (float(f2.group(1)), float(f2.group(2))) if f2 else (150.0, 12.0)
    deck = {'name': v.name, 'code': deck_code(v.name), 'z': v.z, 'zones': zones, 'openings': openings,
            'footprint': footprint, 'members': rest, 'deep': deep}
    # R-LG2: girders / edge longitudinals take their section from the 'NO.n LONGL. ELEV.' view of their longitudinal number (n from the
    # table of 'OFF C.L' values), the text printed inside this deck's frame span; bracket marks of that view are noted.
    if settings.get('_pdf') and not settings.get('no_longi_sections'):
        try:
            from . import longi as _lg
            _tab = _lg.table(page)
            _key = ('longi', settings['_pdf'], id(fx))
            if _key not in _LONGI_CACHE:
                _LONGI_CACHE[_key] = _lg.scan(settings['_pdf'], fx)
            _secs = _LONGI_CACHE[_key]
            _x0, _x1 = footprint.bounds[0], footprint.bounds[2]
            from collections import Counter as _C
            _have = set()
            for m in deep:
                val = round(abs(m['a'][1]))
                n_ = next((nn for vv, nn in _tab.items() if abs(vv - val) <= 8), None)
                if n_ is None:
                    continue
                _have.add(n_)
                hits = _lg.section_at(_secs, n_, _x0, _x1)
                if hits:
                    txt = _C(h[1].replace(' ', '') for h in hits).most_common(1)[0][0]
                    h = next(h for h in hits if h[1].replace(' ', '') == txt)
                    m['depth'], m['web_t'] = h[2][0], h[2][1]
                    m['face'] = (h[2][2], h[2][3])
                    m['longi'] = n_
                    m.setdefault('evidence', []).append(f'R-LG2 NO.{n_} LONGL. ELEV.: {h[1]} printed inside FR span')
                    mlog['longi_sections'] = mlog.get('longi_sections', 0) + 1
            # edge longitudinals (deck outline edge = a longitudinal of the table) that have no girder yet
            for val, n_ in sorted(_tab.items()):
                if n_ in _have or not (4 <= n_ <= 40):
                    continue
                for sgn in (-1, 1):
                    yb = footprint.bounds[1] if sgn < 0 else footprint.bounds[3]
                    if abs(abs(yb) - val) <= 30 and (n_ in _secs):
                        edge = [h for h in _secs[n_] if h[2]]
                        near = min(edge, key=lambda h: min(abs(h[0] - _x0), abs(h[0] - _x1))) if edge else None
                        if near and min(abs(near[0] - _x0), abs(near[0] - _x1)) < 2500:
                            deep.append({'kind': 'deep', 'a': (_x1, (-val if yb < 0 else val)), 'b': (_x0, (-val if yb < 0 else val)), 'depth': near[2][0], 'web_t': near[2][1],
                                         'face': (near[2][2], near[2][3]), 'longi': n_,
                                         'evidence': [f'R-LG2 edge longitudinal NO.{n_} at {val} OFF C.L; section {near[1]} taken from the nearest printed text of its elevation (X={near[0]:.0f}) - CONFIRM']})
                            mlog['edge_longi_added'] = mlog.get('edge_longi_added', 0) + 1
                    elif abs(abs(yb) - val) <= 30:
                        mlog.setdefault('open_edge_longi', []).append(f'NO.{n_} at {val} OFF C.L is a deck-edge longitudinal but has no NO.{n_} LONGL. ELEV. view in the drawing: section UNKNOWN, not built')
        except Exception:
            import traceback; traceback.print_exc()
    if settings.get('vfd_room_walls') and abs(float(v.z) - 41460.0) < 5:
        # R-RW3 (owner 2026-10-23: 'at that location you built web and flange'): the VFD-room box walls at 8525 / 18665 replace the deck-edge girders there
        _gone = [m for m in deep if min(abs(abs(m['a'][1]) - 8525), abs(abs(m['a'][1]) - 18665)) < 60 and abs(m['a'][1] - m['b'][1]) < 1
                 and max(m['a'][0], m['b'][0]) <= 100600 and min(m['a'][0], m['b'][0]) >= 95400]
        if _gone:
            deep = [m for m in deep if m not in _gone]
            settings.setdefault('_notes', []).append(f'R-RW3 {len(_gone)} deck-edge girder(s) at 8525/18665 dropped (VFD-room walls built instead)')
    _xlim = (round(footprint.bounds[0]), round(footprint.bounds[2]))
    _dd = {'footprint': footprint, 'members': deep}
    supports.clip_to_footprint(_dd, tol=1.5)         # R-DM4: girders also end on the deck edge, never past it
    for _m2 in _dd['members']:      # ends exactly on the outline X limits (labels first)
        _m2['a'] = (min(max(_m2['a'][0], _xlim[0]), _xlim[1]), _m2['a'][1])
        _m2['b'] = (min(max(_m2['b'][0], _xlim[0]), _xlim[1]), _m2['b'][1])
    deck['deep'] = _dd['members']
    deck['_ext'] = None
    if _ext_piece is not None:
        try:
            deck['_ext'] = _extension_deck(page, v, D, _ext_piece, _ext_members, slog, settings)
        except Exception:
            import traceback; traceback.print_exc()
    from . import coaming as _co
    deck['coamings'] = _co.find(page, v)
    if settings.get('sheer', True):
        from . import sheer as shr
        fb = deck['footprint'].bounds
        deck["sheer"] = shr.find(page, v, fb)
    if settings.get('camber', True):
        from . import camber as cmb
        ymin, ymax = footprint.bounds[1], footprint.bounds[3]
        deck['camber'] = cmb.find(page, v, (ymin, ymax))
        keep = []
        for st in deck['camber']:        # R-CB2: a camber strip must reach the deck edge (outer edge = footprint edge)
            edge = ymax if st['side'] == 'P' else -ymin
            if abs(st['outer'] - edge) < 150:
                keep.append(st)
            else:
                st['rejected'] = f"outer {st['outer']:.0f} is not the deck edge {edge:.0f}"
        deck['camber_rejected'] = [s for s in deck['camber'] if s.get('rejected')]
        deck['camber'] = keep
    _cl = view.camber_line(page) if settings.get('camber', True) else None
    from . import decknames as _dn
    if _cl and _dn.key(v.name) == _cl['deck'] and abs(float(v.z) - _cl['z_side']) < 1:
        # R-CB5: straight-line camber from the side (z_side at half_b OFF C.L) to the centre line (z_side + c)
        deck['camber'] = [{'side': sd_, 'n': _cl['c'], 'inner': 0.0, 'outer': _cl['half_b'], 'L': _cl['half_b'], 'knuckle': 0.0, 'cover_all': True,
                           'src': f"SCHEME OF DECK CAMBER: {_cl['z_side']:g} A/B at {_cl['half_b']:g} OFF C.L, camber {_cl['c']:g} at C.L (straight line)"}
                          for sd_ in ('P', 'S')]
        deck['z'] = _cl['z_side'] + _cl['c']
        deck['camber_rejected'] = []
    elif getattr(v, 'z_source', '').startswith('SCHEME') and view._CAMBER.get('heights') and len(view._CAMBER['heights']) >= 2:
        # R-CB4 (owner 2026-10-23): the SCHEME OF DECK CAMBER of the drawing gives the deck height at two OFF C.L lines (2665 -> 42961, 18665 -> 42811):
        # the deck is ONE surface sloping 150 mm over 16000 mm (not flat). Z = z(2665) - 150/16000 * (|Y| - 2665), the drawn side (S) only.
        hs = sorted(view._CAMBER['heights'])
        (o1, z1), (o2, z2) = hs[0], hs[-1]
        sd = 'S' if getattr(v, 'half', 'S') == 'S' else 'P'
        ex = [c for c in deck.get('camber', []) if c.get('side') == sd]
        deck['camber'] = [{'side': sd, 'n': float(z1 - z2), 'inner': float(o1), 'outer': float(o2), 'L': float(o2 - o1), 'knuckle': float(o1), 'cover_all': True,
                           'src': f'SCHEME OF DECK CAMBER: {o1} OFF C.L at {z1}, {o2} OFF C.L at {z2} (one sloping surface)'}]
        deck['z'] = float(z1)
        deck['camber_rejected'] = []
    if settings.get('_pdf') and settings.get('cross_verify', True):
        # R-XV / R-SY2 (owner 2026-10-25): deck members are cross-verified with the OFF C.L elevations and frame sections while they are made
        try:
            from . import crossverify as _xv
            _ops = [o['poly'] if isinstance(o, dict) and 'poly' in o else o for o in openings]
            _ops = [o for o in _ops if hasattr(o, 'intersection')]
            _cm0 = (deck.get('camber') or [None])[0]
            _xv.DECKS[round(float(v.z))] = {'name': v.name, 'footprint': footprint, 'camber': _cm0, 'z_flat': float(deck['z']),
                                            'walls': [tuple(c for pt in l.coords for c in pt) for l in supports.wall_lines(page, v)],
                                            'members': [m for m in list(deck.get('deep', [])) + list(deck['members']) if m['kind'] in ('deep', 'girder')]}
            from shapely.geometry import Point as _Pb
            deck['b_marks'] = [(q.x, q.y) for q in (deckplan.to_ship(v, _Pb(w.cx, w.cy)) for w in page.words if w.text.strip() == 'B')
                               if footprint.buffer(600).contains(q)]          # R-B9: plan 'B' marks (note 4.3 bracket connection)
            # R-B10 (2026-10-25, NO.5 STR. / weather shield): a plan 'B' beside a short SOLID stroke that starts on the deck edge (a wall)
            # and ends without a member = the bracket of the wall stiffener there, lying in the stroke's vertical plane, corner at the
            # deck / wall line. Size from the OFF C.L view of that line (R-B9), else asked. Not a deck member.
            deck['wall_brackets'] = []
            try:
                from shapely.geometry import LineString as _LSb
                _edge = footprint.exterior
                _bw = [deckplan.to_ship(v, _Pb(w.cx, w.cy)) for w in page.words if w.text.strip() == 'B']
                _seen = set()
                import math
                for q in page.segs:
                    if q.dash or not (q.horizontal or q.vertical) or q.width < 0.3:
                        continue
                    a_ = deckplan.to_ship(v, _Pb(*q.a)); b_ = deckplan.to_ship(v, _Pb(*q.b))
                    L_ = a_.distance(b_)
                    if not (120 < L_ < 900):
                        continue
                    for e_, o_ in ((a_, b_), (b_, a_)):
                        if _edge.distance(e_) < 40 and _edge.distance(o_) > 100 and footprint.contains(o_):
                            if not any(bw.distance(_LSb([e_, o_])) < 350 for bw in _bw):
                                continue
                            ux_, uy_ = (o_.x - e_.x) / L_, (o_.y - e_.y) / L_
                            P_ = _edge.interpolate(_edge.project(e_))
                            px_, py_ = P_.x, P_.y
                            if abs(ux_) > 0.5:                   # stroke along X: its Y is the line; snap to the printed datum
                                h_ = D.near('Y', py_, 40.0) or D.near('Y', -py_, 40.0)
                                py_ = (h_[1] if abs(h_[1] - py_) < 41 else -h_[1]) if h_ else py_
                            else:
                                h_ = D.near('X', px_, 40.0); px_ = h_[1] if h_ else px_
                            if any(math.dist((px_, py_), q_) < 60 for q_ in _seen):
                                continue
                            # a deck member ending here already carries this end's bracket (R-B2 / R-B9)
                            if any(math.dist((px_, py_), m_[e2]) < 60 for m_ in deck['members'] for e2 in ('a', 'b')
                                   if not str((m_.get('evidence') or [''])[0]).startswith('R-NL')):
                                continue
                            _seen.add((px_, py_))
                            deck['wall_brackets'].append({'p': (px_, py_), 'd': (round(ux_), round(uy_)),
                                                          'size': None, 'evidence': ["R-B10 'B' + solid stroke from the deck edge = wall-stiffener bracket"]})
                            break
            except Exception:
                import traceback; traceback.print_exc()
            mlog['cross_verify'] = _xv.verify(deck, _xv.collect(settings['_pdf'], settings), settings['_pdf'], settings, footprint, _ops,
                                               supports.drawn_lines(page, v), notes=v.notes)
        except Exception:
            import traceback; traceback.print_exc()
    nclip = supports.clip_to_footprint(deck)
    mlog['beam_carling_cuts_at_girders'] = supports.split_at_crossings(deck, penetrate=bool(settings.get('penetrate_members', os.environ.get('DR_PENETRATE', '1') == '1')))          # R-G1b
    mlog['nl_pieces_at_openings_dropped'] = supports.drop_generated_at_openings(deck)  # R-NL3
    gaprep = supports.close_gaps(deck, supports.wall_lines(page, v), max_gap=settings.get('max_end_gap_to_close_mm', 45.0),
                                  drawn=supports.drawn_lines(page, v))
    mlog['end_on_web_face'] = supports.end_on_web_face(deck)          # R-CN8
    deck['supports'] = supports.used_walls(deck, supports.wall_lines(page, v))
    mlog['evidence_gate_questions'] = supports.evidence_gate(deck, supports.drawn_lines(page, v))      # R-EV
    for _m2 in deck['deep']:      # gap closing must not push girders past the labelled deck limits
        _m2['a'] = (min(max(_m2['a'][0], _xlim[0]), _xlim[1]), _m2['a'][1])
        _m2['b'] = (min(max(_m2['b'][0], _xlim[0]), _xlim[1]), _m2['b'][1])
    info = {'view': v.to_dict(), 'carling_table': {k: list(x) for k, x in carl.items()},
            'plates': {'zones': len(zones), 'openings': len(openings), 'seams': len(pz['seams']),
                       'thickness_marks': pz['thickness_marks']},
            'members': {k: sum(1 for m in mem if m['kind'] == k) for k in sorted({m['kind'] for m in mem})},
            'printed_datums': dinfo,
            'coordinate_sources': {'members': mlog, 'plates_openings': slog},
            'clipped_to_deck_edge': nclip,
            'no_gap': {k: (gaprep[k] if k != 'closed_gap_mm' else {'n': len(gaprep[k]), 'max': max(gaprep[k], default=0)})
                       for k in ('ends', 'touching', 'closed', 'closed_gap_mm')} | {'left_open': len(gaprep['left_open'])},
            'open_items': open_items(mem, openings) + [dict(g, kind='gap') for g in gaprep['left_open']]}
    return deck, info


def open_items(mem, openings):
    items = []
    for m in mem:
        if any('confirm' in e for e in m['evidence']):
            items.append({'member': [round(c) for c in m['a'] + m['b']], 'issue': m['evidence'][-1]})
        if m['section'] is None:
            items.append({'member': [round(c) for c in m['a'] + m['b']], 'issue': 'no section resolved'})
    items.append({'all members': 'flange side of angles not resolved from the plan view (needs section views)'})
    return items


def load_any(path, page_no, a):
    """vector PDF page -> pdfsrc;  scan / image / forced -> OCR + raster front end."""
    vector = False
    if path.lower().endswith('.pdf') and not a.raster:
        page = pdfsrc.load_page(path, page_no)
        vector = len(page.segs) > 500 and len(page.words) > 20
        if vector:
            return page
        print(f'page has {len(page.segs)} vector segments and {len(page.words)} text lines: using the OCR / raster front end')
    from . import ocr as ocrmod, raster_front
    engine = ocrmod.OCR(a.ocr, a.ocr_models)
    print('OCR backend:', engine.backend)
    return raster_front.load_raster_page(path, page_no, zoom=a.zoom, ocr=engine, ocr_cache=a.ocr_cache)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf')
    ap.add_argument('--page', type=int, default=1, help='1-based page number')
    ap.add_argument('--deck', default='all', help="deck plan title, e.g. 'B - DECK', or 'all'")
    ap.add_argument('--settings')
    ap.add_argument('--reference', help='sample XML for scoring only (never used by the rules)')
    ap.add_argument('--out', default='deck_out')
    ap.add_argument('--raster', action='store_true', help='force the OCR / raster front end (scans, image files)')
    ap.add_argument('--ocr', default='auto', help='auto | paddle | rapid | tesseract')
    ap.add_argument('--ocr-models', help='folder with PP-OCRv5_mobile_det and en_PP-OCRv5_mobile_rec (paddle backend)')
    ap.add_argument('--ocr-cache', default='.ocr_cache', help='folder for cached OCR results (offline, keyed by image hash)')
    ap.add_argument('--zoom', type=float, default=3.0, help='raster pixels per page point (image files: dpi/72)')
    a = ap.parse_args(argv)
    try:                                    # R-B11: bracket marks from the drawing's DET. OF BRACKET table (same hull)
        from . import elevation as _el0
        _el0.load_bracket_marks(a.pdf)
    except Exception as _e:
        from . import openitems as _oi0
        _oi0.record('R-B11 bracket table', _e)
    os.makedirs(a.out, exist_ok=True)
    settings = load_settings(a.settings)
    settings['_pdf'] = a.pdf
    if settings.get('deck_longitudinal_questions', False) and not a.raster:       # R-LG is check-only (questions); off by default (51 s on 1005)
        from . import longrows
        cache = os.path.join(os.path.abspath(a.out), 'long_rows_' + os.path.splitext(os.path.basename(a.pdf))[0].replace(' ', '_') + '.json') if settings.get('_long_cache', True) else None
        settings['_long_rows'] = longrows.rows_for(a.pdf, settings, cache=cache)
    page = load_any(a.pdf, a.page - 1, a)
    views = view.find_deck_plans(page)
    if a.deck != 'all':
        views = [v for v in views if v.name.replace(' ', '') == a.deck.replace(' ', '')]
    skip = {x.replace(' ', '') for x in settings.get('skip_decks', [])}
    for v in views:
        if v.name.replace(' ', '') in skip:
            print(f"{v.name}: SKIPPED - listed in settings skip_decks (geometry not supported by the rules; see settings note)")
    views = [v for v in views if v.name.replace(' ', '') not in skip]
    if not views:
        sys.exit('no matching deck plan title on this page')
    ref_root = None
    if a.reference:
        from . import reference
        ref_root = reference.load(a.reference)
    summary = {}
    for v in views:
        try:
            deck, info = process_deck(page, v, settings)
        except Exception as e:                       # report and continue with other decks
            import traceback, os as _o
            if _o.environ.get("DECKRULES_DEBUG"): traceback.print_exc()
            summary[v.name] = {"error": str(e)}
            print(f'{v.name}: FAILED - {e}')
            continue
        code = deck['code']
        xml_path = os.path.join(a.out, f'{code}_DECK_moulded.xml')
        info['export'] = export.write(xml_path, deck, settings)
        _x = deck.pop('_ext', None)
        if _x:
            xp2 = os.path.join(a.out, f"{_x['code']}_DECK_moulded.xml")
            info['extension_platform'] = {'name': _x['name'], 'z': _x['z'], 'export': export.write(xp2, _x, settings)}
            print(f"{_x['name']}: extension platform of {v.name} built ({len(_x['members'])} members)")
        if ref_root is not None:
            from . import reference, evaluate
            rc = settings['reference_deck_codes'].get(code, code)
            ref = reference.extract_deck(ref_root, rc)
            for s in ref['stiffeners']:
                s['section_key'] = reference.section_key(s['section'])
            out = {'zones': deck['zones'], 'openings': deck['openings'],
                   'members': [dict(m, section_key=tuple(float(x) if not isinstance(x, str) else x for x in m['section'])
                                    if m['section'] else None) for m in deck['members']]}
            if ref['plates']:
                info['score_vs_sample_xml'] = {
                    'plates': evaluate.score_plates(out, ref),
                    'openings': evaluate.score_openings(out, ref),
                    'members': evaluate.score_members(out, ref),
                    'members_union': evaluate.score_members_union(out, ref),
                    'member_position_error': evaluate.member_position_error(out, ref)}
                plot.review(out, ref, os.path.join(a.out, f'{code}_DECK_review.png'), f'{v.name} - rule output vs sample XML')
        if 'score_vs_sample_xml' not in info:
            plot.single(dict(zones=deck['zones'], openings=deck['openings'], members=deck['members'],
                             footprint=deck['footprint']), os.path.join(a.out, f'{code}_DECK_review.png'), f'{v.name} - rule output (no answer key)')
        from . import openitems as _oi
        info['rule_errors'] = list(_oi.ERRORS)                     # P9: failed rules are open items, never silent
        with open(os.path.join(a.out, f'{code}_DECK_report.json'), 'w', encoding='utf-8') as f:
            json.dump(info, f, indent=2, default=str)
        summary[v.name] = {k: info.get(k) for k in ('plates', 'members')}
        sc = info.get('score_vs_sample_xml')
        if sc:
            summary[v.name]['score'] = {
                'footprint_iou': sc['plates']['footprint_iou'],
                'thickness_agreement': sc['plates']['thickness_agreement'],
                'openings_matched': f"{sc['openings']['matched_iou_0.6']}/{sc['openings']['ref_openings']}",
                'member_position_coverage': sc['members']['position_coverage'],
                'member_position_and_section': sc['members']['position_and_section_coverage'],
                **{'members_' + k: v for k, v in sc['members_union'].items()}}
        print(v.name, json.dumps(summary[v.name]))
    with open(os.path.join(a.out, 'summary.json'), 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=2, default=str)


if __name__ == '__main__':
    from . import runstate
    runstate.reset()          # P7: a stand-alone run starts clean
    main()
