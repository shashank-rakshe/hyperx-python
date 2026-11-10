"""R-CN6 gap audit (owner 2026-10-24): every member END (web ends of every stiffener / girder web) must TOUCH the member it stops on.
For each end the nearest other member is found (webs, flanges, flange plates, deck / frame / wall plates, brackets) and the gap measured as the true
distance between the end face and that member.  Result per end:  CONNECTED (gap <= TOUCH), GAP (TOUCH < gap <= RADIUS, listed with the member it should stop on),
FREE (nothing within RADIUS: a genuinely free end, or the end of a member lying on its own plate - listed for the owner, never moved).
Offline, deterministic; no end is moved here - the audit only reports (R-P1: ask the owner when the drawing does not say)."""
import numpy as np
from lxml import etree
from scipy.optimize import minimize
from shapely.geometry import Polygon, Point
from . import overlap

TOUCH = 3.0          # mm: a connection (thickness / tolerance); anything above is a gap
RADIUS = 150.0       # mm: nearest member searched within this distance


def _box_dist(b1, b2):
    (c1, A1, h1), (c2, A2, h2) = b1, b2
    cons = []

    def mk(c, A, h, off):
        for i in range(3):
            for s in (1, -1):
                cons.append({'type': 'ineq', 'fun': (lambda z, c=c, A=A, h=h, i=i, s=s, off=off: h[i] - s * (A[i] @ (z[off:off + 3] - c)))})
    mk(c1, A1, h1, 0); mk(c2, A2, h2, 3)
    z0 = np.r_[c1, c2]
    r = minimize(lambda z: np.sum((z[:3] - z[3:]) ** 2), z0, constraints=cons, method='SLSQP', options={'maxiter': 60, 'ftol': 1e-6})
    return float(np.sqrt(max(r.fun, 0.0)))


def _plates(xml_path):
    """every plate (frame / wall / deck / flange panels) as (panel, name, O, U, V, W, polygon, thickness, centre offset)"""
    out = []
    r = etree.parse(xml_path).getroot()
    for pp in r.iter('PlanePanel'):
        cs = pp.find('CoordSys')
        if cs is None:
            continue
        O = overlap._v(cs.find('Origin')); W = overlap._v(cs.find('Waxis')); U = overlap._v(cs.find('Uaxis'))
        W = W / np.linalg.norm(W); U = U / np.linalg.norm(U); V = np.cross(W, U)
        for pg in pp.findall('PlateGroup'):
            th = float(pg.findtext('Material/Thickness') or 0)
            for pl in pg.findall('Plate'):
                ct = pl.find('SimpleContour')
                if th <= 0 or ct is None:
                    continue
                pts = [(float(ct.find('StartPoint2d').get('U')), float(ct.find('StartPoint2d').get('V')))]
                pts += [(float(n.get('U')), float(n.get('V'))) for n in ct.iter('Node2d')]
                try:
                    poly = Polygon(pts)
                    if not poly.is_valid:
                        poly = poly.buffer(0)
                except Exception:
                    continue
                if poly.is_empty:
                    continue
                inw = pl.get('Inward'); off = 0.0
                if inw:
                    iv = np.array([float(x) for x in inw.split()]); off = th / 2 if W.dot(iv) > 0 else -th / 2
                b2 = poly.bounds; pts3 = np.array([O + U * x_ + V * y_ + W * (off + sw) for x_ in (b2[0], b2[2]) for y_ in (b2[1], b2[3]) for sw in (-th / 2, th / 2)])
                out.append({'lo': pts3.min(0), 'hi': pts3.max(0), 'panel': pp.get('ObjId'), 'name': pl.get('Name'), 'O': O, 'U': U, 'V': V, 'W': W, 'poly': poly, 't': th, 'off': off})
    return out


def _pt_plate(p, pl):
    d = p - pl['O']
    u, v, w = d @ pl['U'], d @ pl['V'], d @ pl['W']
    dw = max(0.0, abs(w - pl['off']) - pl['t'] / 2)
    di = pl['poly'].distance(Point(u, v))
    return float(np.hypot(dw, di))


def _slab_pts(box):
    c, A, h = box
    pts = [c + A[0] * h[0] * sx + A[1] * h[1] * sy + A[2] * h[2] * sz for sx in (-1, 0, 1) for sy in (-1, 0, 1) for sz in (-1, 1)]
    return np.array(pts)


def audit(xml_path):
    parts = overlap.collect(xml_path)
    plates = _plates(xml_path)
    brs = overlap.collect_brackets(xml_path)
    ext = [np.abs(b[4][1] * b[4][2][:, None]).sum(0) for b in parts]
    lo = np.array([b[4][0] - e for b, e in zip(parts, ext)]); hi = np.array([b[4][0] + e for b, e in zip(parts, ext)])
    ends = {}
    for i, (blk, pp, name, tag, box) in enumerate(parts):
        if tag != 'Web':
            continue
        c, A, h = box
        for side, sg in (('a', -1), ('b', 1)):
            sc = c + sg * A[0] * (h[0] - 0.5)
            slab = (sc, A, np.array([0.5, h[1], h[2]]))
            ends.setdefault((pp, name, side), []).append((i, slab))
    res = []
    for (pp, name, side), slabs in ends.items():
        best = (1e9, None)
        for i0, slab in slabs:
            sc, A, hs = slab
            e = np.abs(A * hs[:, None]).sum(0); slo, shi = sc - e - RADIUS, sc + e + RADIUS
            near = np.nonzero(~(np.any(lo > shi, axis=1) | np.any(hi < slo, axis=1)))[0]
            for j in near:
                blk, pj, nj, tj, bj = parts[j]
                if nj == name or overlap._same_member(parts[i0], parts[j]) or (tj == 'Plate' and pj == pp):
                    continue
                d = _box_dist(slab, bj)
                if d < best[0]:
                    best = (d, f'{nj} [{tj}]')
            sp = _slab_pts(slab)
            for pl in plates:
                if pl['panel'] == pp or np.any(pl['hi'] < slo) or np.any(pl['lo'] > shi):
                    continue
                d = min(_pt_plate(p, pl) for p in sp)
                if d < best[0]:
                    best = (d, f"{pl['name']} [plate]")
            for blk, pb, nb, Pv, Pe, Pn, host in brs:
                if host == name or np.any(Pv.max(0) < slo) or np.any(Pv.min(0) > shi):
                    continue
                # a bracket whose vertices touch the end slab = connected through the bracket
                d = min(float(np.linalg.norm(np.clip(np.abs(A @ (v - sc)) - hs, 0, None))) for v in Pv)
                if d < best[0]:
                    best = (d, f'{nb} [bracket]')
        d, who = best
        state = 'CONNECTED' if d <= TOUCH else ('GAP' if d <= RADIUS else 'FREE')
        res.append({'panel': pp, 'member': name, 'end': side, 'state': state, 'gap': round(d, 1) if d < 1e8 else None, 'nearest': who})
    return res


def report(res):
    from collections import Counter
    c = Counter(r['state'] for r in res)
    lines = [f"# Member-end gap audit (R-CN6)\n\n{len(res)} member ends: {c.get('CONNECTED', 0)} connected, {c.get('GAP', 0)} GAP, {c.get('FREE', 0)} free.\n"]
    lines.append('\n## GAP - end stops short of a member within %g mm (should touch)\n\n| member | end | gap mm | nearest member |\n|---|---|---|---|' % RADIUS)
    for r in sorted((r for r in res if r['state'] == 'GAP'), key=lambda r: -r['gap']):
        lines.append(f"| {r['member']} | {r['end']} | {r['gap']} | {r['nearest']} |")
    lines.append('\n## FREE - nothing within %g mm\n' % RADIUS)
    lines.append(', '.join(f"{r['member']}:{r['end']}" for r in res if r['state'] == 'FREE'))
    return '\n'.join(lines)
