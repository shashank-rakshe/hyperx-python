"""R-W8 / R-W9 (2026-10-25, found in the 3D review of weather shield region 2): after the views are merged, one structural member
must exist once.
R-W8  two stiffeners (any panels) with the same section whose webs lie within one web height of each other and overlap over at least
      half of the shorter length are ONE member (EC: the side-wall stiffener at FR.22 was built by the side wall AND twice by the
      FR.22 section; two identical side-wall stiffeners at X 34400).
R-W9  the one kept: the stiffener standing on a plate of its own panel (a stiffener in a panel without plate there is an orphan of a
      section read), then the better evidence (printed label / mark > unmarked drawn > generated NO.nL / title default), then the first. References are moved to the kept one.
Offline: lxml + shapely only."""
from lxml import etree
from shapely.geometry import Polygon, Point


def _v(e):
    return [float(e.get('X')), float(e.get('Y')), float(e.get('Z'))]


def _cs(el):
    c = el.find('CoordSys')
    O, W, U = _v(c.find('Origin')), _v(c.find('Waxis')), _v(c.find('Uaxis'))
    V = [W[1] * U[2] - W[2] * U[1], W[2] * U[0] - W[0] * U[2], W[0] * U[1] - W[1] * U[0]]
    return O, U, V


def _cont(c):
    s = c.find('StartPoint2d')
    return [(float(s.get('U')), float(s.get('V')))] + [(float(n.get('U')), float(n.get('V'))) for n in c.iter('Node2d')]


def _web3d(st):
    w = st.find('Web')
    if w is None or w.find('CoordSys') is None or w.find('DetailedContour') is None:
        return None
    O, U, V = _cs(w)
    return [[O[i] + a * U[i] + b * V[i] for i in range(3)] for a, b in _cont(w.find('DetailedContour'))]


def clean(xml_path, tol_extra=10.0):
    tree = etree.parse(xml_path)
    root = tree.getroot()
    recs = []
    for pp in root.iter('PlanePanel'):
        plates = []
        for pl in pp.iter('Plate'):
            try:
                plates.append(Polygon(_cont(pl.find('SimpleContour'))).buffer(5))
            except Exception as _e:
                from . import openitems as _oi
                _oi.record('xmlclean plate outline', _e)
        for st in pp.iter('Stiffener'):
            w = _web3d(st)
            tr = st.find('Trace')
            if not w or tr is None:
                continue
            sec = st.getparent().find('.//BarShape')
            sid = sec.get('BarSectionId') if sec is not None else ''
            try:
                h = float(sid.split('Bar')[1].split('*')[0])
            except Exception:
                h = 150.0
            lo = [min(p[i] for p in w) for i in range(3)]
            hi = [max(p[i] for p in w) for i in range(3)]
            t = _cont(tr)
            on_plate = any(pl.contains(Point(t[0])) or pl.contains(Point(t[-1])) for pl in plates)
            ev = (st.get('Evidence') or '').lower()
            recs.append({'st': st, 'pp': pp, 'sid': sid, 'h': h, 'lo': lo, 'hi': hi, 'on_plate': on_plate,
                         'label': 0 if (ev.startswith('r-nl') or 'title default' in ev) else 1 if ev.startswith('unmarked') else 2})
    removed = []
    alive = [True] * len(recs)
    for i, a in enumerate(recs):
        if not alive[i]:
            continue
        ext = [a['hi'][k] - a['lo'][k] for k in range(3)]
        ax = max(range(3), key=lambda k: ext[k])
        for j in range(i + 1, len(recs)):
            b = recs[j]
            if not alive[j] or b['sid'] != a['sid']:
                continue
            eb = [b['hi'][k] - b['lo'][k] for k in range(3)]
            if max(range(3), key=lambda k: eb[k]) != ax:
                continue
            ov = min(a['hi'][ax], b['hi'][ax]) - max(a['lo'][ax], b['lo'][ax])
            if ov < 0.5 * min(ext[ax], eb[ax]):
                continue
            lim = 30.0 if a['pp'] is b['pp'] else a['h'] + tol_extra     # same panel: true copies only; across panels: the corner pair
            ok = all(abs((a['lo'][k] + a['hi'][k]) / 2 - (b['lo'][k] + b['hi'][k]) / 2) <= lim for k in range(3) if k != ax)
            if not ok:
                continue
            ra, rb = (a['on_plate'], a['label'], ext[ax]), (b['on_plate'], b['label'], eb[ax])
            keep, drop, di = (a, b, j) if ra >= rb else (b, a, i)
            if ov < 0.9 * (drop['hi'][ax] - drop['lo'][ax]):     # only a member lying (almost) wholly on the kept one is removed
                continue
            alive[di] = False
            removed.append((drop, keep))
            if di == i:
                break
    for drop, keep in removed:
        st, pp = drop['st'], drop['pp']
        for ref in root.iter('ModelRef'):
            if ref.get('ObjId') == pp.get('ObjId') and ref.get('CompType') == 'Stiffener' and ref.get('CompId') == st.get('CompId'):
                ref.set('ObjId', keep['pp'].get('ObjId'))
                ref.set('CompId', keep['st'].get('CompId'))
        g = st.getparent()
        g.remove(st)
        if not g.findall('Stiffener'):
            g.getparent().remove(g)
    tree.write(xml_path, xml_declaration=True, encoding='utf-8', pretty_print=True)
    return {'duplicates_removed': len(removed),
            'examples': [f"{d['pp'].get('ObjId')}/{d['st'].get('Name')} = {k['pp'].get('ObjId')}/{k['st'].get('Name')}" for d, k in removed]}
