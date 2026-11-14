"""Offline deck viewer: the real drawing (zoomable) + the XML the tool produced, same coordinates.
python make_deck_viewer.py drawing.pdf page settings.json model.xml out.html "WEATHER SHIELD" "NO. 5 STR." ...
Only local libraries (PyMuPDF, shapely); no network."""
import sys, re, json, base64, io
import xml.etree.ElementTree as ET
sys.path.insert(0, '.')
from deckrules import view, run, pdfsrc

pdf, pg, setp, xmlp, outp = sys.argv[1:6]
names = sys.argv[6:]
settings = run.load_settings(setp)
page = pdfsrc.load_page(pdf, int(pg) - 1)
import fitz
doc = fitz.open(pdf)
fpage = doc[int(pg) - 1]
ZOOM = 3.0
root = ET.parse(xmlp).getroot()


def contour(el):
    sp = el.find('StartPoint2d')
    pts = [[float(sp.get('U')), float(sp.get('V'))]]
    for s in el.findall('Segment2d'):
        n = s.find('Node2d')
        pts.append([float(n.get('U')), float(n.get('V'))])
    return pts


decks = []
_pages = {}
for nm in names:
    _pg = int(pg)
    if re.match(r'^p\d+:', nm):                     # 'p1:B - DECK' = a deck plan of another sheet
        _pg, nm = int(nm.split(':', 1)[0][1:]), nm.split(':', 1)[1]
    if _pg not in _pages:
        _p = pdfsrc.load_page(pdf, _pg - 1)
        _pages[_pg] = (_p, doc[_pg - 1], view.find_deck_plans(_p))
    page, fpage, views = _pages[_pg]
    v = next((u for u in views if u.name.replace(' ', '') == nm.replace(' ', '')), None)
    if v is None:
        print('deck not found', nm)
        continue
    fx = run.frame_x_fn(settings, v)
    view.calibrate(page, v, fx)
    fx = v.frame_fn or fx
    r = v.region
    m = 25
    clip = fitz.Rect(r[0] - m, r[1] - m, r[2] + m, r[3] + m)
    pm = fpage.get_pixmap(matrix=fitz.Matrix(ZOOM, ZOOM), clip=clip, colorspace=fitz.csGRAY)
    img = 'data:image/png;base64,' + base64.b64encode(pm.tobytes('png')).decode()
    code = v.name.replace(' ', '').replace('.', '')
    _m = re.match(r'NO\.?\s*(\d+)\s*STR', v.name)
    if _m:
        code = 'NOSTR' + _m.group(1)
    blk = next((b for b in root.iter('Block') if b.get('ObjId') in ('PDF-' + code, 'PDF-' + run.deck_code(v.name))), None)
    d = {'zn': 0.0, 'name': v.name, 'z': v.notes.get('height') or '', 'img': img, 'w': pm.width, 'h': pm.height,
         'clip': [clip.x0, clip.y0], 'zoom': ZOOM, 'x0': v.x0, 'cl': v.cl_y, 'k': v.k,
         'plates': [], 'holes': [], 'mem': [], 'frames': [], 'offcl': [], 'brk': 0}
    if blk is not None:
        _pp = blk.find('PlanePanel')
        _o = _pp.find('CoordSys/Origin') if _pp is not None else None
        d['zn'] = float(_o.get('Z')) if _o is not None else 0.0
        z = None
        for p in blk.iter('Plate'):
            if 'DEEP' in (p.get('Name') or ''):      # deep girder web/flange are in their own local axes: not drawn in the plan
                continue
            d['plates'].append({'n': p.get('Name'), 'pts': contour(p.find('SimpleContour'))})
        for h in blk.iter('Hole'):
            d['holes'].append(contour(h.find('Contour')))
        for sg in blk.iter('StiffenerGroup'):
            par = sg.find('.//Parameters')
            for s in sg.findall('Stiffener'):
                tr = s.find('Trace')
                d['mem'].append({'n': s.get('Name').split('/')[-1], 'k': s.get('Kind'), 'sec': (par.text if par is not None else ''),
                                 'ev': (s.get('Evidence') or '')[:400], 'pts': contour(tr)})
        for pp in blk.iter('PlanePanel'):          # R-VW3: deep girder web lies in its own axes: draw its line (origin + U axis x web length)
            if 'deep' not in (pp.get('Kind') or ''):
                continue
            cs = pp.find('CoordSys')
            if cs is None or 'FLANGE' in (pp.get('ObjId') or ''):
                continue
            o = cs.find('Origin'); u = cs.find('Uaxis')
            ox, oy = float(o.get('X')), float(o.get('Y')); ux, uy = float(u.get('X')), float(u.get('Y'))
            pl = pp.find('.//Plate/SimpleContour')
            us = [q[0] for q in contour(pl)] if pl is not None else [0]
            d['mem'].append({'n': (pp.get('ObjId') or '').split('-')[-1], 'k': 'deep', 'sec': 'deep girder web', 'ev': 'web/flange stored in own axes; shown as its line',
                             'pts': [[ox + ux * min(us), oy + uy * min(us)], [ox + ux * max(us), oy + uy * max(us)]]})
        d['brk'] = len(list(blk.iter('Bracket')))
    # frame lines / OFF C.L lines limited to the deck itself (plate bounds) plus a margin
    allp = [p for pl in d['plates'] for p in pl['pts']] or [[v.X(r[0]), v.Y(r[3])], [v.X(r[2]), v.Y(r[1])]]
    bx0, bx1 = min(p[0] for p in allp), max(p[0] for p in allp)
    by0, by1 = min(p[1] for p in allp), max(p[1] for p in allp)
    tab = {int(k): float(x) for k, x in settings.get('frame_table', {}).items()}
    if not tab:                                     # R-XV1: no table -> the deck's own frame function (spacing written on the sheet)
        tab = {n: float(fx(n)) for n in range(-10, 400) if not isinstance(fx(n), tuple)}
    for n, X in sorted(tab.items()):
        if bx0 - 1 <= X <= bx1 + 1:
            d['frames'].append({'n': n, 'X': X})
    for lab in v.evidence.get('frame_labels', []):     # R-VW2: printed fractional labels ('19+0.5' = 1/2 of the gap spacing) get their own line
        mm_ = re.fullmatch(r'(-?\d+)\+(\d*\.?\d+)', str(lab))
        if mm_:
            n_, fr_ = int(mm_.group(1)), float(mm_.group(2))
            if n_ in tab and n_ + 1 in tab:
                X = tab[n_] + fr_ * (tab[n_ + 1] - tab[n_])
                from fractions import Fraction
                d['frames'].append({'n': f'{n_}+{Fraction(fr_).limit_denominator(12)}', 'X': X})
    d['frames'].sort(key=lambda f: f['X'])
    seen = set()
    for val, Y in view.offcl_lines(page, v):
        if (val, round(Y)) not in seen:
            seen.add((val, round(Y)))
            d['offcl'].append({'v': val, 'Y': Y})
    d['yrange'] = [by0 - 900, by1 + 900]
    d['xrange'] = [bx0 - 1500, bx1 + 1500]
    print(v.name, 'plates', len(d['plates']), 'members', len(d['mem']), 'frames', [f['n'] for f in d['frames']], 'offcl', [o['v'] for o in d['offcl']])
    decks.append(d)

# R-VW5: OFF C.L walls and frame sections of the same XML (vertical panels) for the iso view, in world coordinates: P = O + u*U + v*(W x U)
def _w(cs, t):
    e = cs.find(t)
    return [float(e.get(k)) for k in 'XYZ']


VERT = []
zs = [d['zn'] for d in decks]
zlo, zhi = (min(zs) - 3600, max(zs) + 1) if zs else (-1e9, 1e9)
for blk in root.iter('Block'):
    for pp in blk.findall('PlanePanel'):
        cs = pp.find('CoordSys')
        if cs is None:
            continue
        O, W, U = _w(cs, 'Origin'), _w(cs, 'Waxis'), _w(cs, 'Uaxis')
        if abs(W[2]) > 0.5:
            continue                                    # decks are drawn from their own blocks
        V = [W[1] * U[2] - W[2] * U[1], W[2] * U[0] - W[0] * U[2], W[0] * U[1] - W[1] * U[0]]
        to3 = lambda u, v: [O[i] + U[i] * u + V[i] * v for i in range(3)]
        kind = 'frame' if abs(W[0]) > 0.5 else 'wall'
        if 'deep' in (pp.get('Kind') or ''):
            continue
        b = pp.find('Boundary/SimpleContour')
        if b is None:
            continue
        pts = [to3(u, v) for u, v in contour(b)]
        if not (min(p[2] for p in pts) < zhi and max(p[2] for p in pts) > zlo):
            continue
        st = []
        for s_ in pp.iter('Stiffener'):
            tr = s_.find('Trace')
            if tr is not None:
                st.append({'pts': [to3(u, v) for u, v in contour(tr)], 'ev': (s_.get('Evidence') or '')[:300], 'n': s_.get('Name', '').split('/')[-1]})
        VERT.append({'k': kind, 'blk': blk.get('ObjId'), 'n': pp.get('ObjId') or '', 'pts': pts, 'st': st,
                     'plate': pp.find('.//Plate') is not None})
print('vertical panels for iso:', sum(1 for v_ in VERT if v_['k'] == 'wall'), 'walls,', sum(1 for v_ in VERT if v_['k'] == 'frame'), 'frame panels')
HTML = open('deck_viewer_template.html', encoding='utf-8').read()
HTML = HTML.replace('/*VERT*/null', json.dumps(VERT))
open(outp, 'w', encoding='utf-8').write(HTML.replace('/*DATA*/null', json.dumps(decks)))
print('wrote', outp)
