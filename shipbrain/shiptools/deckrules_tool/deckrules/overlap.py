"""R-G1 (owner 2026-10-23): two members never overlap.  Offline check of every web / flange (and T flange plate panel) as an oriented box
(contour rectangle x thickness along its W axis); boxes of different members that interpenetrate by more than TOL mm are reported."""
import itertools
import numpy as np
from lxml import etree

TOL = 1.5


def _v(e):
    return np.array([float(e.get(k)) for k in 'XYZ'])


def _box(cs, contour, t, direction):
    O = _v(cs.find('Origin')); W = _v(cs.find('Waxis')); U = _v(cs.find('Uaxis'))
    W = W / np.linalg.norm(W); U = U / np.linalg.norm(U); V = np.cross(W, U)
    pts = [(float(contour.find('StartPoint2d').get('U')), float(contour.find('StartPoint2d').get('V')))]
    pts += [(float(n.get('U')), float(n.get('V'))) for n in contour.iter('Node2d')]
    us = [p[0] for p in pts]; vs = [p[1] for p in pts]
    u0, u1, v0, v1 = min(us), max(us), min(vs), max(vs)
    s0, s1 = (0.0, t) if direction == 'Positive' else ((-t, 0.0) if direction == 'Negative' else (-t / 2, t / 2))
    c = O + U * (u0 + u1) / 2 + V * (v0 + v1) / 2 + W * (s0 + s1) / 2
    return c, np.array([U, V, W]), np.array([(u1 - u0) / 2, (v1 - v0) / 2, (s1 - s0) / 2])


def _slices(cs, contour, t, direction, n=8):
    """R-CN6: a contour whose end is cut obliquely (u0,v0)-(ua,v0)-(ub,v1)-(u0,v1) is checked as n slices along v, each as long as the SHORTEST end in its slice
    (conservative: no false overlap from the bounding box of the oblique cut)."""
    pts = [(float(contour.find('StartPoint2d').get('U')), float(contour.find('StartPoint2d').get('V')))]
    pts += [(float(q.get('U')), float(q.get('V'))) for q in contour.iter('Node2d')]
    if len(pts) == 5 and pts[0] == pts[4]:
        pts = pts[:4]
    if len(pts) == 4 and abs(pts[0][0] - pts[3][0]) < 1e-6 and abs(pts[0][1] - pts[1][1]) < 1e-6 and abs(pts[2][1] - pts[3][1]) < 1e-6 and abs(pts[1][0] - pts[2][0]) > 0.5:
        (u0, v0), (ua, _), (ub, v1) = pts[0], pts[1], pts[2]
        out = []
        for k in range(n):
            a, b = v0 + (v1 - v0) * k / n, v0 + (v1 - v0) * (k + 1) / n
            ue = min(ua + (ub - ua) * (a - v0) / (v1 - v0), ua + (ub - ua) * (b - v0) / (v1 - v0))
            sub = etree.Element('DetailedContour'); sp = etree.SubElement(sub, 'StartPoint2d', U=repr(u0), V=repr(a))
            for uu, vv in ((ue, a), (ue, b), (u0, b)):
                sg_ = etree.SubElement(sub, 'Segment2d'); etree.SubElement(sg_, 'Amplitude2d', U='0', V='0'); etree.SubElement(sg_, 'Node2d', U=repr(uu), V=repr(vv))
            out.append(_box(cs, sub, t, direction))
        return out
    return [_box(cs, contour, t, direction)]


def _depth(a, b):
    ca, Aa, ha = a; cb, Ab, hb = b
    d = cb - ca
    best = 1e18
    axes = [x for x in Aa] + [x for x in Ab]
    for i in range(3):
        for j in range(3):
            c = np.cross(Aa[i], Ab[j])
            n = np.linalg.norm(c)
            if n > 1e-6:
                axes.append(c / n)
    for ax in axes:
        ra = sum(ha[k] * abs(np.dot(Aa[k], ax)) for k in range(3))
        rb = sum(hb[k] * abs(np.dot(Ab[k], ax)) for k in range(3))
        ov = ra + rb - abs(np.dot(d, ax))
        if ov <= 0:
            return 0.0
        best = min(best, ov)
    return best


def collect(xml_path):
    r = etree.parse(xml_path).getroot()
    parts = []
    for blk in r.iter('Block'):
        for pp in blk.iter('PlanePanel'):
            for sg in pp.findall('StiffenerGroup'):
                prm = [float(x) for x in (sg.findtext('Material/BarShape/Parameters') or '').split()]
                kind = sg.find('Material/BarShape').get('BarSectionId', '')
                for st in sg.findall('Stiffener'):
                    for tag in ('Web', 'Flange1'):
                        p = st.find(tag)
                        if p is None or p.find('CoordSys') is None or p.find('DetailedContour') is None:
                            continue
                        if kind.startswith('LBar') and len(prm) >= 4:
                            t = prm[2] if tag == 'Web' else prm[3]
                        elif kind.startswith('FlatBar') and len(prm) >= 2:
                            t = prm[1] if tag == 'Web' else float(p.get('Thickness') or 0)
                        else:
                            continue
                        if t <= 0:
                            continue
                        for bx_ in _slices(p.find('CoordSys'), p.find('DetailedContour'), t, p.get('MaterialDirection')):
                            parts.append((blk.get('ObjId'), pp.get('ObjId'), st.get('Name'), tag, bx_))
            if 'FLANGE' in (pp.get('ObjId') or ''):
                for pl in pp.iter('Plate'):
                    th = float(pl.getparent().findtext('Material/Thickness') or 0)
                    cs = pp.find('CoordSys'); ct = pl.find('SimpleContour')
                    if th > 0 and ct is not None:
                        inw = pl.get('Inward')
                        dirn = 'Centre'
                        if inw:
                            Wv = np.array([float(cs.find('Waxis').get(k)) for k in 'XYZ']); iv = np.array([float(x) for x in inw.split()])
                            dirn = 'Positive' if Wv.dot(iv) > 0 else 'Negative'
                        parts.append((blk.get('ObjId'), pp.get('ObjId'), pl.get('Name'), 'Plate', _box(cs, ct, th, dirn)))
    return parts


def _same_member(a, b):
    """T member = web stiffener 'P/TBn' + its flange plate 'P-TBn-FLANGE-P1' (one member, two surfaces)."""
    for x, y in ((a, b), (b, a)):
        if x[3] == 'Web' and y[3] == 'Plate' and y[2].endswith('-FLANGE-P1'):
            if y[2][:-len('-FLANGE-P1')] == x[2].replace('/', '-'):
                return True
    return False


def check(xml_path, tol=TOL):
    parts = collect(xml_path)
    lo = [p[4][0] - np.abs(p[4][1] * p[4][2][:, None]).sum(0) for p in parts]
    hi = [p[4][0] + np.abs(p[4][1] * p[4][2][:, None]).sum(0) for p in parts]
    hits, connections = [], []
    for i, j in itertools.combinations(range(len(parts)), 2):
        if parts[i][2] == parts[j][2] or _same_member(parts[i], parts[j]):
            continue
        if np.any(lo[i] > hi[j] - tol) or np.any(lo[j] > hi[i] - tol):
            continue
        dpt = _depth(parts[i][4], parts[j][4])
        if dpt > tol:
            a, b = parts[i][4], parts[j][4]
            perp = abs(float(np.dot(a[1][2], b[1][2]))) < 0.2           # webs / flanges crossing at an angle
            thin = max(2 * a[2][2], 2 * b[2][2])
            if perp and dpt <= thin + 0.5:                              # R-CN4: surface connection - one member ends on the moulded plane of the other,
                connections.append((round(dpt, 1), parts[i][2], parts[i][3], parts[j][2], parts[j][3]))   # only the (not considered) thickness penetrates
                continue
            hits.append((round(dpt, 1), parts[i][2], parts[i][3], parts[j][2], parts[j][3]))
    hits.sort(reverse=True)
    check.connections = connections
    return len(parts), hits


def collect_brackets(xml_path):
    """R-G5: every bracket as a convex prism (triangle / polygon contour in its plane x thickness, centred on the plane)."""
    r = etree.parse(xml_path).getroot()
    out = []
    for blk in r.iter('Block'):
        for pp in blk.iter('PlanePanel'):
            for bg in pp.findall('BracketGroup'):
                t = float(bg.findtext('Material/Thickness') or 0)
                for br in bg.findall('Bracket'):
                    cs = br.find('CoordSys'); ct = br.find('SimpleContour')
                    if cs is None or ct is None or t <= 0:
                        continue
                    O = _v(cs.find('Origin')); W = _v(cs.find('Waxis')); U = _v(cs.find('Uaxis'))
                    W = W / np.linalg.norm(W); U = U / np.linalg.norm(U); V = np.cross(W, U)
                    pts = [(float(ct.find('StartPoint2d').get('U')), float(ct.find('StartPoint2d').get('V')))]
                    pts += [(float(n.get('U')), float(n.get('V'))) for n in ct.iter('Node2d')]
                    pts = pts[:-1] if len(pts) > 3 and pts[0] == pts[-1] else pts
                    base = [O + U * u + V * v for u, v in pts]
                    verts = np.array([b + W * s for b in base for s in (-t / 2, t / 2)])
                    edges = [base[(k + 1) % len(base)] - base[k] for k in range(len(base))] + [W]
                    host = br.find('End2/ModelRef')
                    out.append((blk.get('ObjId'), pp.get('ObjId'), br.get('Name'), verts, edges, W, host.get('ObjId') if host is not None else ''))
    return out


def _sat_depth(Pv, Pe, Pn, box):
    c, A, h = box
    Qv = np.array([c + A[0] * h[0] * sx + A[1] * h[1] * sy + A[2] * h[2] * sz for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
    axes = [Pn] + list(A) + [np.cross(e, a) for e in Pe for a in A]
    best = 1e18
    for ax in axes:
        n = np.linalg.norm(ax)
        if n < 1e-9:
            continue
        ax = ax / n
        p, q = Pv @ ax, Qv @ ax
        d = min(p.max() - q.min(), q.max() - p.min())
        if d <= 0:
            return 0.0
        best = min(best, d)
    return best


def check_brackets(xml_path, tol=TOL):
    """R-G5 (owner 2026-10-23): a bracket never overlaps a member (web / flange / plate).  Returns (n_brackets, hits); each hit = (depth, bracket, member, tag).
    Brackets lie in the web plane of their stiffener and touch it on an edge, so the penetration is measured with the same tolerance as R-G1."""
    parts = collect(xml_path)
    hits = []
    brs = collect_brackets(xml_path)
    for blk, pid, name, Pv, Pe, Pn, host in brs:
        lo, hi = Pv.min(0), Pv.max(0)
        for b, p, n, tag, box in parts:
            c, A, h = box
            ext = np.abs(A * h[:, None]).sum(0)
            if np.any(c - ext > hi - tol) or np.any(lo > c + ext - tol):
                continue
            d = _sat_depth(Pv, Pe, Pn, box)
            if d > tol:
                hits.append((round(d, 1), name, n, tag))
    hits.sort(reverse=True)
    return len(brs), hits
