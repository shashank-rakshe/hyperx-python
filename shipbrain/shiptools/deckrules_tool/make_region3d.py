"""Offline 3D page of a small region of the produced XML (only the XML; no drawing).
python make_region3d.py model.xml X0 X1 Y0 Y1 Z0 Z1 out_data.json
Writes the region's plates (clipped), holes, stiffener webs / flanges and brackets as polygons in ship mm. Offline: lxml + shapely."""
import sys, json
from lxml import etree
from shapely.geometry import Polygon, box

xmlp = sys.argv[1]
X0, X1, Y0, Y1, Z0, Z1 = map(float, sys.argv[2:8])
out = sys.argv[8]
root = etree.parse(xmlp).getroot()


def vec(e):
    return [float(e.get('X')), float(e.get('Y')), float(e.get('Z'))]


def cs_of(el):
    c = el.find('CoordSys')
    O, W, U = vec(c.find('Origin')), vec(c.find('Waxis')), vec(c.find('Uaxis'))
    V = [W[1] * U[2] - W[2] * U[1], W[2] * U[0] - W[0] * U[2], W[0] * U[1] - W[1] * U[0]]
    return O, U, V, W


def contour(c):
    s = c.find('StartPoint2d')
    p = [(float(s.get('U')), float(s.get('V')))]
    p += [(float(n.get('U')), float(n.get('V'))) for n in c.iter('Node2d')]
    return p


def to3(cs, u, v):
    O, U, V, _ = cs
    return [O[i] + u * U[i] + v * V[i] for i in range(3)]


def uv_box(cs):
    """the region box seen in the plane's own (u, v): only for axis-aligned planes; None when the plane misses the box"""
    O, U, V, W = cs
    ax = max(range(3), key=lambda i: abs(W[i]))
    lo, hi = (X0, Y0, Z0), (X1, Y1, Z1)
    if not (lo[ax] - 1 <= O[ax] <= hi[ax] + 1):
        return None
    au, av = max(range(3), key=lambda i: abs(U[i])), max(range(3), key=lambda i: abs(V[i]))
    us = sorted(((lo[au] - O[au]) / U[au], (hi[au] - O[au]) / U[au]))
    vs = sorted(((lo[av] - O[av]) / V[av], (hi[av] - O[av]) / V[av]))
    return box(us[0], vs[0], us[1], vs[1])


items = []


def add(kind, cs, poly_uv, holes=(), info=None):
    bx = uv_box(cs)
    if bx is None:
        return
    P = Polygon(poly_uv)
    if not P.is_valid:
        P = P.buffer(0)
    for h in holes:
        P = P.difference(Polygon(h))
    P = P.intersection(bx)
    if P.is_empty or P.area < 1:
        return
    geoms = getattr(P, 'geoms', [P])
    for g in geoms:
        if g.geom_type != 'Polygon' or g.area < 1:
            continue
        items.append({'k': kind, 'o': [to3(cs, *q) for q in list(g.exterior.coords)[:-1]],
                      'h': [[to3(cs, *q) for q in list(r.coords)[:-1]] for r in g.interiors], 'i': info or {}})


for pp in root.iter('PlanePanel'):
    cs = cs_of(pp)
    holes = [contour(h.find('Contour')) for h in pp.iter('Hole')]
    for pl in pp.iter('Plate'):
        th = pl.getparent().find('.//Thickness')
        add('plate', cs, contour(pl.find('SimpleContour')), holes,
            {'name': pl.get('Name'), 'panel': pp.get('ObjId'), 't': th.text if th is not None else ''})
    for st in pp.iter('Stiffener'):
        sec = st.getparent().find('.//BarShape')
        info = {'name': st.get('Name'), 'kind': st.get('Kind') or 'stiffener', 'section': sec.get('BarSectionId') if sec is not None else '',
                'evidence': (st.get('Evidence') or '')[:600], 'panel': pp.get('ObjId')}
        for part in st.iter():
            if part.tag in ('Web', 'Flange1') and part.find('CoordSys') is not None:
                dc = part.find('DetailedContour')
                if dc is not None:
                    add(('web' if part.tag == 'Web' else 'flange') + ':' + info['kind'], cs_of(part), contour(dc), (), info)
    for b in pp.iter('Bracket'):
        th = b.getparent().find('.//Thickness')
        src = (b.get('Source') or '') + ' ' + (b.get('Evidence') or '')
        add('bracket' + (':unknown' if 'UNKNOWN' in src.upper() else ''), cs_of(b), contour(b.find('SimpleContour')), (),
            {'name': b.get('Name'), 'kind': 'bracket', 'section': 't ' + (th.text if th is not None else '?'), 'evidence': src.strip()[:600],
             'panel': pp.get('ObjId')})
json.dump({'box': [X0, X1, Y0, Y1, Z0, Z1], 'items': items}, open(out, 'w'))
from collections import Counter
print(len(items), Counter(i['k'] for i in items))
