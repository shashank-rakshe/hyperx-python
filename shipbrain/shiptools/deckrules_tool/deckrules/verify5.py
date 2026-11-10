"""RULE 5 - VERIFIED (owner 2026-10-25): every view of the drawing is checked against the XML the tool produced.

  5.1 Inventory: every titled view of every sheet (PLAN / SEC. / ELEV. / VIEW / DET. / PROFILE ...) gets a status:
      built / failed (reason) / deck-cut / question / NOT READ (no builder recognised it) -> nothing is silently skipped.
  5.2 Overlay: the XML is projected back into each built view with the SAME transform the builder used
      (plan: X,Y -> page; OFF C.L elevation: X,Z; frame section: Y,Z) - plates, openings, members, walls, frame panels, the decks
      cut by the view and the deck members crossing it (stubs).
  5.3 Every straight drawn line of the view (horizontal / vertical, >= 6 pt) is matched with the projected XML (parallel, within
      2.5 pt, >= 60 % covered). Uncovered drawn lines >= 15 pt = MISSING candidates; projected XML lines with no drawn line = EXTRA
      candidates. Coverage % per view; an overlay picture per view (drawing grey, XML blue, missing red, extra orange).
  5.4 Report RULE5_VERIFY.md / rule5.json / rule5/*.png. The owner reviews the red lines; a confirmed miss becomes a new rule and the
      view is built again (re-run). Dimension / leader lines also show as red: they are listed, never built automatically.
Offline only (PyMuPDF, shapely, PIL)."""
import os, re, json, glob, math
from lxml import etree

L_MIN, L_MISS, TOL_PT, COVER = 6.0, 15.0, 2.5, 0.6
TITLE_RX = re.compile(r'(PLAN|SEC\.?|SECTION|ELEV\.?|ELEVATION|VIEW|DET\.?|DETAIL|PROFILE)\b', re.I)


def _contour(el):
    sp = el.find('StartPoint2d')
    if sp is None:
        return []
    pts = [(float(sp.get('U')), float(sp.get('V')))]
    for n in el.iter('Node2d'):
        pts.append((float(n.get('U')), float(n.get('V'))))
    return pts


def _segs(pts, close=False):
    out = [(pts[i], pts[i + 1]) for i in range(len(pts) - 1)]
    if close and len(pts) > 2:
        out.append((pts[-1], pts[0]))
    return out


def _w(cs, t):
    e = cs.find(t)
    return [float(e.get(k)) for k in 'XYZ']


def load_xml(path):
    """world geometry of the XML: decks (z, plate/hole segments in X,Y, members), vertical panels (3D segments)"""
    root = etree.parse(path).getroot()
    decks, vert = [], []
    for blk in root.iter('Block'):
        for pp in blk.findall('PlanePanel'):
            cs = pp.find('CoordSys')
            if cs is None:
                continue
            O, W, U = _w(cs, 'Origin'), _w(cs, 'Waxis'), _w(cs, 'Uaxis')
            V = [W[1] * U[2] - W[2] * U[1], W[2] * U[0] - W[0] * U[2], W[0] * U[1] - W[1] * U[0]]
            to3 = lambda u, v, O=O, U=U, V=V: tuple(O[i] + U[i] * u + V[i] * v for i in range(3))
            segs, mem = [], []
            for p in pp.iter('Plate'):
                c = p.find('SimpleContour')
                if c is not None:
                    segs += [(to3(*a), to3(*b), 'plate') for a, b in _segs(_contour(c), True)]
            for h in pp.iter('Hole'):
                c = h.find('Contour')
                if c is not None:
                    segs += [(to3(*a), to3(*b), 'hole') for a, b in _segs(_contour(c), True)]
            b_ = pp.find('Boundary/SimpleContour')
            if b_ is not None and not segs:
                segs += [(to3(*a), to3(*b), 'plate') for a, b in _segs(_contour(b_), True)]
            for sg in pp.iter('StiffenerGroup'):
                par = sg.find('.//Parameters')
                h = 150.0
                if par is not None and par.text:
                    try:
                        h = float(par.text.split()[0])
                    except ValueError:
                        pass
                for st in sg.findall('Stiffener'):
                    tr = st.find('Trace')
                    if tr is not None:
                        pts = _contour(tr)
                        mem.append({'pts': [to3(*q) for q in pts], 'kind': st.get('Kind') or '', 'h': h, 'name': st.get('Name', '')})
            rec = {'blk': blk.get('ObjId'), 'segs': segs, 'mem': mem, 'W': W}
            if abs(W[2]) > 0.5:
                rec['z'] = O[2]
                decks.append(rec)
            else:
                rec['kind'] = 'frame' if abs(W[0]) > 0.5 else 'wall'
                rec['pos'] = O[0] if rec['kind'] == 'frame' else O[1]
                vert.append(rec)
    return decks, vert


# ---------------------------------------------------------------- projections (world -> page) per view type
def _proj_plan(c):
    k, x0, cl = c['k'], c['x0'], c['cl']
    return lambda P: (x0 + P[0] / k, cl - P[1] / k)


def _proj_elev(c):
    k, x0, yu = c['k'], c['x0'], c['y_upp']
    return lambda P: (x0 + P[0] / k, yu - (P[2] - 19700.0) / k)


def _proj_sec(c):
    k, xcl, yz0, s = c['k'], c['xcl'], c['yz0'], c['s']
    return lambda P: (xcl + P[1] / (s * k), yz0 - P[2] / k)


def projected(view, decks, vert):
    """projected XML segments (page coords) for one view"""
    t, c = view['type'], view['calib']
    out = []
    if t == 'plan':
        f = _proj_plan(c)
        z = c['z']
        for d in decks:
            if abs(d['z'] - z) > 5:
                continue
            out += [(f(a), f(b), w) for a, b, w in d['segs']]
            for m in d['mem']:
                out += [(f(a), f(b), m['kind'] or 'member') for a, b in _segs(m['pts'])]
        for p in vert:                      # walls / frame panels standing on or under this deck: their line in the plan
            zs = [q[2] for s_ in p['segs'] for q in s_[:2]]
            if not zs or not (min(zs) - 50 <= z <= max(zs) + 50):
                continue
            pts = [q for s_ in p['segs'] for q in s_[:2]]
            if p['kind'] == 'wall':
                xs = [q[0] for q in pts]
                out.append((f((min(xs), p['pos'], z)), f((max(xs), p['pos'], z)), 'wall'))
            else:
                ys = [q[1] for q in pts]
                out.append((f((p['pos'], min(ys), z)), f((p['pos'], max(ys), z)), 'frame'))
        return out
    if t == 'elev':
        f = _proj_elev(c)
        Y = c['y']
        for p in vert:
            if p['kind'] == 'wall' and abs(p['pos'] - Y) < 5:
                out += [(f(a), f(b), w) for a, b, w in p['segs']]
                for m in p['mem']:
                    out += [(f(a), f(b), 'wall stiffener') for a, b in _segs(m['pts'])]
            elif p['kind'] == 'frame':
                pts = [q for s_ in p['segs'] for q in s_[:2]]
                ys, zs = [q[1] for q in pts], [q[2] for q in pts]
                if pts and min(ys) - 5 <= Y <= max(ys) + 5:
                    out.append((f((p['pos'], Y, min(zs))), f((p['pos'], Y, max(zs))), 'frame'))
                    xs_all = [q[0] for d in decks for s_ in d['segs'] for q in s_[:2]] or [p['pos']]
                    inb = 1 if p['pos'] < (min(xs_all) + max(xs_all)) / 2 else -1       # web towards the inside of the structure
                    for m in p['mem']:          # the frame's stiffeners standing at this OFF C.L, seen edge-on: their web edge
                        if m['pts'] and abs(m['pts'][0][1] - Y) < 60:
                            z_ = [q[2] for q in m['pts']]
                            xw = p['pos'] + inb * m['h']
                            out.append((f((xw, Y, min(z_))), f((xw, Y, max(z_))), 'frame stiffener edge-on'))
    else:
        f = _proj_sec(c)
        X = c['X']
        for p in vert:
            if p['kind'] == 'frame' and abs(p['pos'] - X) < 5:
                out += [(f(a), f(b), w) for a, b, w in p['segs']]
                for m in p['mem']:
                    out += [(f(a), f(b), 'frame stiffener') for a, b in _segs(m['pts'])]
            elif p['kind'] == 'wall':
                pts = [q for s_ in p['segs'] for q in s_[:2]]
                xs, zs = [q[0] for q in pts], [q[2] for q in pts]
                if pts and min(xs) - 5 <= X <= max(xs) + 5:
                    out.append((f((X, p['pos'], min(zs))), f((X, p['pos'], max(zs))), 'wall'))
                    sg = 1 if p['pos'] > 0 else -1
                    for m in p['mem']:          # the wall's stiffeners standing at this frame, seen edge-on: their web edge, h inboard
                        if m['pts'] and abs(m['pts'][0][0] - X) < 60:
                            z_ = [q[2] for q in m['pts']]
                            yw = p['pos'] - sg * m['h']
                            out.append((f((X, yw, min(z_))), f((X, yw, max(z_))), 'wall stiffener edge-on'))
    # decks cut by the elevation / section and their members crossing it
    ax = 1 if t == 'elev' else 0            # coordinate fixed by the view: Y for elevations, X for sections
    pos = c['y'] if t == 'elev' else c['X']
    for d in decks:
        z = d['z']
        cuts = []
        for a, b, w in d['segs']:
            if w != 'plate' or (a[ax] - pos) * (b[ax] - pos) > 0 or abs(a[ax] - b[ax]) < 1e-6:
                continue
            tt = (pos - a[ax]) / (b[ax] - a[ax])
            cuts.append(a[1 - ax] + tt * (b[1 - ax] - a[1 - ax]))
        if len(cuts) >= 2:
            lo, hi = min(cuts), max(cuts)
            P = lambda u: (u, pos, z) if t == 'elev' else (pos, u, z)
            out.append((f(P(lo)), f(P(hi)), 'deck'))
        for m in d['mem']:
            for a, b in _segs(m['pts']):
                if abs(a[ax] - b[ax]) < 1e-6:
                    if abs(a[ax] - pos) < 60:           # member lying in the view plane: seen side-on
                        out.append((f(a), f(b), m['kind']))
                        out.append((f((a[0], a[1], a[2] - m['h'])), f((b[0], b[1], b[2] - m['h'])), m['kind']))
                    continue
                if (a[ax] - pos) * (b[ax] - pos) > 0:
                    continue
                tt = (pos - a[ax]) / (b[ax] - a[ax])
                q = tuple(a[i] + tt * (b[i] - a[i]) for i in range(3))
                out.append((f(q), f((q[0], q[1], q[2] - m['h'])), m['kind'] + ' cut'))
    return out


# ---------------------------------------------------------------- matching
def _hv(a, b):
    if abs(a[1] - b[1]) < 0.3 and abs(a[0] - b[0]) >= 0.3:
        return 'h'
    if abs(a[0] - b[0]) < 0.3 and abs(a[1] - b[1]) >= 0.3:
        return 'v'
    return None


def _merge_lines(segs):
    """collinear drawn pieces -> lines: (o, c, lo, hi) o='h'|'v', c = fixed coordinate"""
    by = {}
    for a, b in segs:
        o = _hv(a, b)
        if not o:
            continue
        c = a[1] if o == 'h' else a[0]
        lo, hi = sorted((a[0], b[0]) if o == 'h' else (a[1], b[1]))
        by.setdefault((o, round(c / 0.7)), []).append((c, lo, hi))
    out = []
    for (o, _), iv in by.items():
        iv.sort(key=lambda t: t[1])
        cur = list(iv[0])
        for c, lo, hi in iv[1:]:
            if lo <= cur[2] + 3.0:
                cur[2] = max(cur[2], hi)
            else:
                out.append((o, cur[0], cur[1], cur[2]))
                cur = [c, lo, hi]
        out.append((o, cur[0], cur[1], cur[2]))
    return out


def _covered(line, other, tol=TOL_PT):
    o, c, lo, hi = line
    iv = []
    for o2, c2, lo2, hi2 in other:
        if o2 != o or abs(c2 - c) > tol:
            continue
        a, b = max(lo, lo2 - tol), min(hi, hi2 + tol)
        if b > a:
            iv.append((a, b))
    iv.sort()
    tot, cur = 0.0, None
    for a, b in iv:
        if cur and a <= cur[1]:
            cur[1] = max(cur[1], b)
        else:
            if cur:
                tot += cur[1] - cur[0]
            cur = [a, b]
    if cur:
        tot += cur[1] - cur[0]
    return tot / max(hi - lo, 1e-6)


NUM = re.compile(r'^\s*[\d.,]{2,6}\s*$')


def classify(page, D, P, r):
    """R5.5 (owner 2026-10-25 'still only 50 %'): a drawn line is ANNOTATION, not structure, when it is
       - 'outside': entirely outside the structure the view shows (the projected XML box + 4 pt) - notes, titles, dimension rows;
       - 'text': the underline / leader landing of a text (text standing on it, line not much longer than the text);
       - 'dim': a dimension line (a number centred on it within 8 pt) or an extension line ending on a dimension line;
       - 'dashdot': a centre / frame line (dash-dot pattern).
       Everything else is STRUCTURE; coverage and missing are counted on structure only."""
    if P:
        bx0 = min(min(l[2], l[3]) if l[0] == 'h' else l[1] for l in P) - 4
        bx1 = max(max(l[2], l[3]) if l[0] == 'h' else l[1] for l in P) + 4
        by0 = min(l[1] if l[0] == 'h' else l[2] for l in P) - 4
        by1 = max(l[1] if l[0] == 'h' else l[3] for l in P) + 4
    else:
        bx0, by0, bx1, by1 = r
    words = [w for w in page.words if r[0] - 20 <= w.cx <= r[2] + 20 and r[1] - 20 <= w.cy <= r[3] + 20]
    dd = [(s.a, s.b) for s in page.segs if s.dash and len(str(s.dash).split(',')) >= 3]
    DD = _merge_lines(dd)
    out = {}
    dims = []
    for l in D:
        o, c, lo, hi = l
        x0_, x1_, y0_, y1_ = ((lo, hi, c, c) if o == 'h' else (c, c, lo, hi))
        why = None
        if x1_ < bx0 or x0_ > bx1 or y1_ < by0 or y0_ > by1:
            why = 'outside'
        elif any(o2 == o and abs(c2 - c) < 0.7 and lo2 - 1 <= lo and hi <= hi2 + 1 for o2, c2, lo2, hi2 in DD):
            why = 'dashdot'
        else:
            for w in words:
                if o == 'h' and not w.vertical and -1 <= c - w.bbox[3] <= 4 and w.bbox[0] >= lo - 6 and w.bbox[2] <= hi + 6 \
                        and (hi - lo) <= (w.bbox[2] - w.bbox[0]) * 1.6 + 25:
                    why = 'text'
                elif o == 'v' and w.vertical and (-1 <= c - w.bbox[2] <= 4 or -1 <= w.bbox[0] - c <= 4) and w.bbox[1] >= lo - 6 and w.bbox[3] <= hi + 6 \
                        and (hi - lo) <= (w.bbox[3] - w.bbox[1]) * 1.6 + 25:
                    why = 'text'
                elif NUM.match(w.text) and ((o == 'h' and abs(w.cy - c) < 8 and lo < w.cx < hi) or (o == 'v' and abs(w.cx - c) < 8 and lo < w.cy < hi)):
                    why = 'dim'
                if why:
                    break
        if why == 'dim':
            dims.append(l)
        out[l] = why
    for l in D:                                  # extension lines: end on a dimension line
        if out[l]:
            continue
        o, c, lo, hi = l
        for o2, c2, lo2, hi2 in dims:
            if o2 != o and lo2 - 2 <= c <= hi2 + 2 and (abs(c2 - lo) < 3 or abs(c2 - hi) < 3):
                out[l] = 'dim'
                break
    return out


def check_view(page, view, decks, vert):
    r = view['region']
    inside = lambda p: r[0] <= p[0] <= r[2] and r[1] <= p[1] <= r[3]
    drawn = [(s.a, s.b) for s in page.segs if s.length >= L_MIN and inside(s.a) and inside(s.b)]
    D = [l for l in _merge_lines(drawn) if l[3] - l[2] >= L_MIN]
    proj = [(a, b, w) for a, b, w in projected(view, decks, vert)]
    P = _merge_lines([(a, b) for a, b, w in proj if inside(a) or inside(b)])
    cls = classify(page, D, P, r)
    S = [l for l in D if not cls[l]]
    tot = sum(l[3] - l[2] for l in S) or 1.0
    cov = sum((l[3] - l[2]) * min(1.0, _covered(l, P)) for l in S)
    tot_all = sum(l[3] - l[2] for l in D) or 1.0
    cov_all = sum((l[3] - l[2]) * min(1.0, _covered(l, P)) for l in D)
    miss = [l for l in S if l[3] - l[2] >= L_MISS and _covered(l, P) < COVER]
    extra = [l for l in P if l[3] - l[2] >= L_MISS and _covered(l, D) < COVER]
    from collections import Counter
    return {'coverage': cov / tot, 'coverage_all_lines': cov_all / tot_all, 'drawn_lines': len(D), 'structure_lines': len(S),
            'annotation': dict(Counter(v for v in cls.values() if v)), 'xml_lines': len(P), 'missing': miss, 'extra': extra, 'proj': proj,
            'annot_lines': [l for l in D if cls[l]]}


def _ship(view, o, c, lo, hi):
    """ship coordinates of a page line, for the report"""
    t, k = view['type'], view['calib']['k']
    pts = [((lo + hi) / 2, c)] if o == 'h' else [(c, (lo + hi) / 2)]
    px, py = pts[0]
    cal = view['calib']
    if t == 'plan':
        return f"X={(px - cal['x0']) * k:.0f} Y={(cal['cl'] - py) * k:.0f}"
    if t == 'elev':
        return f"X={(px - cal['x0']) * k:.0f} Z={19700 + (cal['y_upp'] - py) * k:.0f}"
    return f"Y={cal['s'] * (px - cal['xcl']) * k:.0f} Z={(cal['yz0'] - py) * k:.0f}"


def _picture(pdf, pno, view, res, path, zoom=2.0):
    import pymupdf
    from PIL import Image, ImageDraw
    r = view['region']
    doc = pymupdf.open(pdf)
    pm = doc[pno].get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), clip=pymupdf.Rect(*r), colorspace=pymupdf.csGRAY)
    im = Image.frombytes('L', (pm.width, pm.height), pm.samples).convert('RGB')
    im = Image.eval(im, lambda v: 150 + v * 105 // 255)          # drawing light grey
    g = ImageDraw.Draw(im)
    T = lambda p: ((p[0] - r[0]) * zoom, (p[1] - r[1]) * zoom)
    for a, b, w in res['proj']:
        g.line([T(a), T(b)], fill=(30, 90, 220), width=2)
    for o, c, lo, hi in res['extra']:
        a, b = ((lo, c), (hi, c)) if o == 'h' else ((c, lo), (c, hi))
        g.line([T(a), T(b)], fill=(240, 150, 0), width=3)
    for o, c, lo, hi in res['missing']:
        a, b = ((lo, c), (hi, c)) if o == 'h' else ((c, lo), (c, hi))
        g.line([T(a), T(b)], fill=(220, 20, 20), width=3)
    im.save(path)


# ---------------------------------------------------------------- views of the build
def views_of_build(out):
    views = []
    for f in sorted(glob.glob(os.path.join(out, 'decks', 'p*', '*_report.json'))):
        try:
            r = json.load(open(f))
        except Exception:
            continue
        v = r.get('view') or {}
        if not v.get('region_page') or v.get('frame0_page_x') is None:
            continue
        pno = int(re.search(r'[/\\]p(\d+)[/\\]', f).group(1)) - 1
        views.append({'name': v['name'], 'type': 'plan', 'page': pno, 'region': v['region_page'],
                      'calib': {'k': v['mm_per_pt'], 'x0': v['frame0_page_x'], 'cl': v['centre_line_page_y'], 'z': float(v['z_mm'])}})
    for stage, fn, typ in (('walls', 'WALLS_report.json', 'elev'), ('frames', 'FRAMES_report.json', 'sec')):
        try:
            r = json.load(open(os.path.join(out, stage, fn)))
        except Exception:
            continue
        for key, v in r['views'].items():
            c = v.get('calib')
            if v.get('status') != 'ok' or not c:
                continue
            if typ == 'elev':
                ys = list(c['decks'].values())
                reg = [c['xr'][0] - 10, min(ys + [c['ytop'] or 1e9]) - 20, c['xr'][1] + 10, max(ys) + 20]
            else:
                reg = c['region']
            views.append({'name': key, 'type': typ, 'page': c['page'] - 1, 'region': reg, 'calib': c})
    return views


def inventory(pdf, rep):
    """5.1 every titled view of the drawing with its status in this build"""
    from . import pdfsrc
    import pymupdf
    st = {}
    for e in rep.get('stages', {}).get('decks', []):
        m = re.match(r'^(.*?)(?::\s*FAILED\s*-\s*(.*)| \{)', e['line'])
        if m:
            st[('p%d' % e['page'], re.sub(r'\W', '', m.group(1).upper()))] = ('failed: ' + m.group(2)) if m.group(2) else 'built'
    for stage in ('walls', 'frames'):
        for k, v in (rep.get('stages', {}).get(stage) or {}).items():
            if not isinstance(v, dict):
                continue
            pg, nm = k.split(' ', 1)
            nm = re.sub(r'\s*X=.*$', '', nm)
            s_ = v.get('status')
            st[(pg, re.sub(r'\W', '', nm.upper()))] = 'built' if s_ == 'ok' else f"{s_}: {v.get('reason', '')}"
    out = []
    for pno in range(len(pymupdf.open(pdf))):
        page = pdfsrc.load_page(pdf, pno)
        seen = set()
        for w in page.words:
            t = w.text.strip()
            if w.size < 12 or not TITLE_RX.search(t) or t in seen or 'HISTORY' in t.upper():
                continue
            seen.add(t)
            key = re.sub(r'\W', '', t.upper())
            s_ = None
            for (pg, nm), v in st.items():
                if pg == 'p%d' % (pno + 1) and nm and (key.startswith(nm) or nm.startswith(key.replace('PLAN', '')) or nm in key):
                    s_ = v
                    break
            out.append({'page': pno + 1, 'title': t, 'status': s_ or 'NOT READ (no builder recognised it)'})
    return out


def run(pdf, out, xml_path, rep):
    from . import pdfsrc
    decks, vert = load_xml(xml_path)
    os.makedirs(os.path.join(out, 'rule5'), exist_ok=True)
    res_all = []
    pages = {}
    for v in views_of_build(out):
        page = pages.get(v['page']) or pdfsrc.load_page(pdf, v['page'])
        pages[v['page']] = page
        try:
            res = check_view(page, v, decks, vert)
        except Exception as e:
            res_all.append({'view': v['name'], 'type': v['type'], 'error': str(e)})
            continue
        png = os.path.join(out, 'rule5', re.sub(r'[^A-Za-z0-9]+', '_', f"{v['type']}_{v['name']}")[:80] + '.png')
        try:
            _picture(pdf, v['page'], v, res, png)
        except Exception as e:
            png = f'(picture failed: {e})'
        res_all.append({'view': v['name'], 'type': v['type'], 'page': v['page'] + 1, 'coverage': round(res['coverage'], 3),
                        'coverage_all_lines': round(res['coverage_all_lines'], 3), 'annotation': res['annotation'], 'structure_lines': res['structure_lines'],
                        'drawn_lines': res['drawn_lines'], 'xml_lines': res['xml_lines'],
                        'missing': [dict(len_pt=round(l[3] - l[2], 1), at=_ship(v, *l)) for l in sorted(res['missing'], key=lambda l: l[2] - l[3])],
                        'extra': [dict(len_pt=round(l[3] - l[2], 1), at=_ship(v, *l)) for l in sorted(res['extra'], key=lambda l: l[2] - l[3])],
                        'picture': os.path.relpath(png, out) if os.path.exists(png) else png})
    inv = inventory(pdf, rep)
    json.dump({'views': res_all, 'inventory': inv}, open(os.path.join(out, 'rule5.json'), 'w'), indent=1)
    L = ['# Rule 5 - verified: drawing vs produced XML', '',
         'Every titled view of the drawing (5.1) and, for every built view, the XML projected back on the drawing (5.2-5.3). '
         'Coverage = share of the drawn straight lines (length) that the XML reproduces. Red = drawn, not in the XML (missing candidate); '
         'orange = in the XML, not drawn (extra candidate). Dimension / leader lines are also red: review the picture.', '',
         '## 5.1 Inventory of the views', '', '| page | view | status |', '|---|---|---|']
    for i in inv:
        L.append(f"| {i['page']} | {i['title']} | {i['status']} |")
    L += ['', '## 5.2-5.3 Built views: coverage of the STRUCTURE lines (annotation lines - dimensions, text underlines, centre lines, notes outside the structure - are classified out, R5.5)', '',
          '| view | type | structure coverage | all lines | structure lines | annotation (outside/text/dim/dashdot) | missing | extra | picture |', '|---|---|---|---|---|---|---|---|---|']
    for r in sorted(res_all, key=lambda r: r.get('coverage', 0)):
        if 'error' in r:
            L.append(f"| {r['view']} | {r['type']} | error: {r['error']} | | | | |")
            continue
        an = r.get('annotation', {})
        L.append(f"| {r['view']} | {r['type']} | {r['coverage']:.0%} | {r['coverage_all_lines']:.0%} | {r['structure_lines']} | "
                 f"{an.get('outside', 0)}/{an.get('text', 0)}/{an.get('dim', 0)}/{an.get('dashdot', 0)} | {len(r['missing'])} | {len(r['extra'])} | {r['picture']} |")
    L += ['', '## Missing candidates (longest first, max 12 per view)', '']
    for r in res_all:
        if r.get('missing'):
            L.append(f"- **{r['view']}**: " + '; '.join(f"{m['at']} ({m['len_pt']} pt)" for m in r['missing'][:12]))
    open(os.path.join(out, 'RULE5_VERIFY.md'), 'w').write('\n'.join(L) + '\n')
    nr = sum(1 for i in inv if i['status'].startswith('NOT READ'))
    return {'views_checked': len(res_all), 'inventory': len(inv), 'not_read': nr,
            'mean_coverage': round(sum(r.get('coverage', 0) for r in res_all) / max(1, len(res_all)), 3)}
