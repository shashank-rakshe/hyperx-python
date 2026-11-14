"""Independent offline check of an exported deck XML (reads ONLY the XML).

  python -m deckrules.validate_xml A_DECK_moulded.xml

Checks the project conventions:
  C1 GeometryConvention="MouldedLine"
  C2 no <MaterialSide> element anywhere (owner 2026-10-22: material side not needed; clean, no gap)
  C3 every contour closed, finite numbers, >= 3 points
  C4 unique plate / stiffener names
  C5 NO GAP: every stiffener end touches (<= 1 mm) a plate edge, cut-out edge,
     another stiffener trace or a SupportLine written in the same file
  C7 trace direction: longitudinals towards -U, transverse towards +V (reference convention)
  C6 every stiffener lies inside the deck footprint (> 2 mm outside = fail)
Exit code 0 = all hard checks passed.  Unsupported ends are listed, not hidden.
"""
import math
import sys
import xml.etree.ElementTree as ET
from shapely.geometry import LineString, Point, Polygon
from shapely.ops import unary_union


def _uv(e):
    return float(e.get('U')), float(e.get('V'))


def _pts(c):
    pts = [_uv(c.find('StartPoint2d'))] + [_uv(s.find('Node2d')) for s in c.findall('Segment2d')]
    return pts


def check(path, tol=1.0):
    root = ET.parse(path).getroot()
    res = {'file': path, 'hard': [], 'ends': {}, 'unsupported_ends': [], 'panels': 0}
    if root.get('GeometryConvention') != 'MouldedLine':
        res['hard'].append('C1 GeometryConvention is not MouldedLine')
    if any(True for _ in root.iter('MaterialSide')):
        res['hard'].append('C2 MaterialSide element present')
    names = set()
    bad = touching = unsup = outside = 0
    wrongdir = []
    nowebs, badweb = [], []
    for pp in root.iter('PlanePanel'):        # every deck panel is checked on its own (R-AS: whole-ship files)
        if pp.get('Kind'):           # deep web panels use their own local frame
            continue
        res['panels'] += 1
        lines, supports, edges = [], [], []
        fpc = pp.find('Boundary/SimpleContour')
        fp = None
        if fpc is not None:
            edges.append(Polygon(_pts(fpc)).exterior)
            fp = Polygon(_pts(fpc)).buffer(tol)
        for c in list(pp.iter('SimpleContour')) + list(pp.iter('Contour')):
            p = _pts(c)
            if len(p) < 4 or math.dist(p[0], p[-1]) > 1e-6 or not all(math.isfinite(x) for q in p for x in q):
                bad += 1
        for h in pp.iter('Hole'):
            edges.append(Polygon(_pts(h.find('Contour'))).exterior)
        for pl in pp.iter('Plate'):
            if pl.get('Name') in names:
                res['hard'].append(f"C4 duplicate name {pl.get('Name')}")
            names.add(pl.get('Name'))
            edges.append(Polygon(_pts(pl.find('SimpleContour'))).exterior)
        for st in pp.iter('Stiffener'):
            n = st.get('Name')
            if n in names:
                res['hard'].append(f'C4 duplicate name {n}')
            names.add(n)
            t = _pts(st.find('Trace'))
            lines.append((n, LineString([t[0], t[-1]])))
            bs = st.getparent().find('.//BarShape') if hasattr(st, 'getparent') else None
            web = st.find('Web')
            sec_id = None
            for e in pp.iter('StiffenerGroup'):
                if st in list(e):
                    b = e.find('.//BarShape')
                    sec_id = b.get('BarSectionId') if b is not None else None
            if sec_id and not sec_id.startswith(('Round', 'Square')) and not st.get('Kind', '').startswith('face'):
                if web is None:
                    nowebs.append(n)
                else:
                    cs = web.find('CoordSys')
                    U = [float(cs.find('Uaxis').get(k)) for k in 'XYZ']
                    W = [float(cs.find('Waxis').get(k)) for k in 'XYZ']
                    inc = [float(st.find('Inclination/Vector3d').get(k)) for k in 'UVW']
                    tt = (t[-1][0] - t[0][0], t[-1][1] - t[0][1])
                    ln = math.hypot(*tt) or 1.0
                    # world tangent of the trace: du*Upanel + dv*Vpanel (Vpanel = Wpanel x Upanel), any panel plane
                    pcs = pp.find('CoordSys')
                    Pu = [float(pcs.find('Uaxis').get(k)) for k in 'XYZ']
                    Pw = [float(pcs.find('Waxis').get(k)) for k in 'XYZ']
                    Pv = [Pw[1]*Pu[2]-Pw[2]*Pu[1], Pw[2]*Pu[0]-Pw[0]*Pu[2], Pw[0]*Pu[1]-Pw[1]*Pu[0]]
                    wt = [(tt[0]*Pu[i] + tt[1]*Pv[i]) / ln for i in range(3)]
                    if max(abs(U[i] - wt[i]) for i in range(3)) > 1e-6:
                        badweb.append(n)
            du, dv = t[-1][0] - t[0][0], t[-1][1] - t[0][1]
            wrong = (du > 0) if abs(du) >= abs(dv) else (dv < 0)
            if wrong and not st.get('Kind', '').startswith('face'):
                wrongdir.append(n)
        for sl in pp.iter('SupportLine'):
            supports.append(LineString([(float(sl.get('U1')), float(sl.get('V1'))), (float(sl.get('U2')), float(sl.get('V2')))]))
        sup_all = unary_union(edges + supports) if (edges or supports) else None
        for i, (n, l) in enumerate(lines):
            if fp is not None and l.difference(fp).length > 2.0:      # > 2 mm beyond the deck edge
                outside += 1
            others = unary_union([sup_all] + [m for j, (_, m) in enumerate(lines) if j != i])
            if others.is_empty:              # a lone member panel (e.g. a slanted wall member) has nothing to touch inside its own panel
                continue
            for end in (l.coords[0], l.coords[-1]):
                if others.distance(Point(end)) <= tol:
                    touching += 1
                else:
                    unsup += 1
                    res['unsupported_ends'].append({'stiffener': n, 'end': [round(end[0]), round(end[1])],
                                                    'gap_mm': round(others.distance(Point(end)))})
    if bad:
        res['hard'].append(f'C3 {bad} contours open / non-finite')
    res['ends'] = {'total': touching + unsup, 'touching_support': touching, 'unsupported': unsup}
    if nowebs:
        res['hard'].append(f'C8 {len(nowebs)} angle/flat-bar members without explicit Web geometry')
    if badweb:
        res['hard'].append(f'C8 {len(badweb)} members whose Web axes disagree with Trace/Inclination')
    if wrongdir:
        res['hard'].append(f'C7 {len(wrongdir)} members run against the reference direction')
    if outside:
        res['hard'].append(f'C6 {outside} stiffeners leave the deck footprint')
    res['ok'] = not res['hard']
    return res


if __name__ == '__main__':
    import json
    r = check(sys.argv[1])
    print(json.dumps({k: v for k, v in r.items() if k != 'unsupported_ends'}, indent=1), f"unsupported ends listed: {len(r['unsupported_ends'])}")
    sys.exit(0 if r['ok'] else 1)
