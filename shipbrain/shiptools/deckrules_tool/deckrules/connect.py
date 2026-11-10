"""R-CN1 (owner 2026-10-23, taught with section 1B2-4): deck member <-> OFF C.L wall / frame member connection.
A wall stiffener and a deck beam are one connection: the stiffener stands at the X of the deck beam that ends on that wall, runs up to the
deck (moulded line, no gap) and the ONE bracket sits at the intersection (it is written by the deck builder with the beam end).
Frame sections: a frame stiffener stands at the Y of the deck longitudinal (beam / carling) that crosses that frame at the same deck.
The table is filled by build_ship from the deck XMLs (TABLE) before the wall / frame builders run."""
from lxml import etree

TABLE = {'beams': [], 'brackets': [], 'links': [], 'girders': [], 'n_snapped': 0, 'log': []}
TOL = 120.0            # largest move of a stiffener onto a deck member (mm); bigger gaps are not connections (labels come first)
END_TOL = 90.0         # a beam 'ends on the wall' when its end is within this of the wall plane
ZTOL = 150.0           # deck level that closes the upper end of the stiffener


def load(files, kinds=('beam', 'carling', 'girder')):
    """deck members in WORLD coordinates (flat and cambered / tilted deck panels): {p1, p2, name}"""
    beams, brs = [], []
    for f in files:
        try:
            r = etree.parse(f).getroot()
        except Exception:
            continue
        for pp in r.iter('PlanePanel'):
            cs = pp.find('CoordSys')
            if cs is None:
                continue
            g = lambda t: [float(cs.find(t).get(k)) for k in 'XYZ']
            o, w, u = g('Origin'), g('Waxis'), g('Uaxis')
            if abs(w[2]) < 0.5:
                continue                                           # vertical panels (walls, frames, girder webs) are not decks
            v = [w[1] * u[2] - w[2] * u[1], w[2] * u[0] - w[0] * u[2], w[0] * u[1] - w[1] * u[0]]
            to3 = lambda uu, vv: [o[i] + u[i] * uu + v[i] * vv for i in range(3)]
            for br in pp.iter('Bracket'):                          # the deck builder's bracket at a beam end (R-B1)
                bc = br.find('CoordSys')
                if bc is None:
                    continue
                bo = [float(bc.find('Origin').get(k)) for k in 'XYZ']
                leg = max([abs(float(n.get('V'))) for n in br.iterfind('SimpleContour/Segment2d/Node2d')] + [abs(float(n.get('U'))) for n in br.iterfind('SimpleContour/Segment2d/Node2d')] + [0.0])
                brs.append({'o': bo, 'leg': leg, 'name': br.get('Name')})
            for st in pp.iter('Stiffener'):
                k = (st.get('Kind') or '').lower()
                if not any(k.startswith(x) for x in kinds):
                    continue
                a = st.find('Trace/StartPoint2d'); b = st.find('Trace/Segment2d/Node2d')
                if a is None or b is None:
                    continue
                p1 = to3(float(a.get('U')), float(a.get('V'))); p2 = to3(float(b.get('U')), float(b.get('V')))
                par = (st.getparent().find('Material/BarShape/Parameters').text or '').split() if st.getparent() is not None and st.getparent().find('Material/BarShape/Parameters') is not None else []
                tf = float(par[-1]) if par else 0.0
                try:
                    hh = float(par[0]) if par else 0.0
                except ValueError:
                    hh = 0.0
                beams.append({'p1': p1, 'p2': p2, 'name': st.get('Name'), 'tf': tf, 'h': hh})
    TABLE['girders'] = _girders(files)
    TABLE['beams'] = beams
    TABLE['brackets'] = brs
    TABLE['links'] = []
    TABLE['n_snapped'] = 0
    TABLE['log'] = []
    return len(beams)



def _girders(files):
    """R-CN5: deep girders already built by the deck builder (face plate panels '...DEEPn-FLANGE'): world box of each flange plate."""
    import numpy as np
    from . import overlap
    out = []
    for f in files:
        try:
            r = etree.parse(f).getroot()
        except Exception:
            continue
        for pp in r.iter('PlanePanel'):
            oid = pp.get('ObjId') or ''
            if 'DEEP' not in oid or 'FLANGE' not in oid:
                continue
            cs = pp.find('CoordSys')
            for pl in pp.iter('Plate'):
                th = float(pl.getparent().findtext('Material/Thickness') or 0)
                ct = pl.find('SimpleContour')
                if th > 0 and ct is not None:
                    c, A, h = overlap._box(cs, ct, th, 'Centre')
                    P = np.array([c + A[0] * h[0] * sx + A[1] * h[1] * sy + A[2] * h[2] * sz for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
                    i_ = int(np.argmax(np.abs(A[:, 2]))); n_ = A[i_] if A[i_][2] > 0 else -A[i_]
                    plane = (tuple(float(x) for x in n_), float(n_ @ c - h[i_]))          # underside face n.p = d (R-CN6: members stop ON this surface)
                    out.append({'plane': plane, 'name': pl.get('Name'), 'x0': float(P[:, 0].min()), 'x1': float(P[:, 0].max()), 'y0': float(P[:, 1].min()), 'y1': float(P[:, 1].max()),
                                'z0': float(P[:, 2].min()), 'z1': float(P[:, 2].max())})
    return out


def girder_at(x, y0, y1):
    """deck deep girder whose flange plate covers frame X and the Y span (R-CN5 stopping / no duplicate)"""
    lo, hi = min(y0, y1), max(y0, y1)
    c = [g for g in TABLE.get('girders', []) if g['x0'] - 5 <= x <= g['x1'] + 5 and g['y0'] <= lo + 120 and g['y1'] >= hi - 120]
    return c[0] if c else None

def _z_at(b, t):
    return b['p1'][2] + (b['p2'][2] - b['p1'][2]) * t


def wall_x(y_wall, x, z_hi, tol=TOL):
    """(X, Z) of the deck beam running along Y that ends on the wall plane |Y| = |y_wall| at the deck closing z_hi (nearest to x), else None."""
    best = None
    far = None
    for b in TABLE['beams']:
        p1, p2 = b['p1'], b['p2']
        if abs(p1[0] - p2[0]) > 2:
            continue
        for e in (p1, p2):
            if abs(abs(e[1]) - abs(y_wall)) <= END_TOL and abs(e[2] - z_hi) <= ZTOL:
                d = abs(e[0] - x)
                if d <= tol and (best is None or d < best[0]):
                    best = (d, e[0], b['name'], e[2], b.get('tf', 0.0), b.get('h', 0.0))
                elif d <= 600:
                    far = min(far, (d, e[0], b['name']), key=lambda t: t[0]) if far else (d, e[0], b['name'])
    if best:
        TABLE['n_snapped'] += 1
        zst = best[3]
        if best[5] > 0:
            # R-CN7 (owner 2026-10-25 Q2a: 'the member from the frame stops on the deck member exactly'; EC FR.22+800 SEC.: the side
            # wall 200 I.A stops under the 300 I.A deck web): the wall stiffener ends on the underside of the deck member it meets
            zst = best[3] - best[5]
        for br in ([] if best[5] > 0 else TABLE['brackets']):                      # the wall stiffener ends on the deck member (beam underside); the deck bracket is at that intersection
            if abs(br['o'][0] - best[1]) < 3 and abs(abs(br['o'][1]) - abs(y_wall)) <= END_TOL and abs(br['o'][2] - best[3]) <= ZTOL:
                zst = br['o'][2] - best[4]                              # = underside of the beam: the wall stiffener ENDS ON the deck member, the bracket stands at that corner
                break
        TABLE['links'].append({'x': best[1], 'wall': abs(y_wall), 'z': best[3], 'tf': best[4]})
        TABLE['log'].append(f'wall Y={y_wall:.0f}: stiffener X {x:.0f} -> {best[1]:.0f}, top Z {zst:.0f} (deck beam {best[2]} at Z {best[3]:.0f}, bracket at the intersection)')
        return best[1], zst
    if far:
        TABLE['log'].append(f'NOT CONNECTED wall Y={y_wall:.0f}: stiffener X {x:.0f}, nearest deck beam {far[2]} at X {far[1]:.0f} ({far[0]:.0f} mm away) - owner to decide which is right')
    return None


def frame_y(x_frame, y, z_hi, tol=TOL):
    """(Y, Z) of the deck longitudinal (running along X) that crosses the frame plane X = x_frame at the deck closing z_hi, else None."""
    best = None
    far = None
    for b in TABLE['beams']:
        p1, p2 = b['p1'], b['p2']
        if abs(p1[1] - p2[1]) > 2 or abs(p1[0] - p2[0]) < 1:
            continue
        t = (x_frame - p1[0]) / (p2[0] - p1[0])
        if not (-0.02 <= t <= 1.02):
            continue
        z = _z_at(b, min(max(t, 0), 1))
        if abs(z - z_hi) > ZTOL:
            continue
        d = abs(p1[1] - y)
        if d <= tol and (best is None or d < best[0]):
            best = (d, p1[1], b['name'], z - b.get('h', 0.0), z)       # R-CN7: ends on the underside of the deck member
        elif d <= 600:
            far = min(far, (d, p1[1], b['name']), key=lambda t: t[0]) if far else (d, p1[1], b['name'])
    if best:
        TABLE['n_snapped'] += 1
        TABLE['log'].append(f'frame X={x_frame:.0f}: stiffener Y {y:.0f} -> {best[1]:.0f} (deck member {best[2]}, Z {best[3]:.0f})')
        return best[1], best[3], best[4]
    if far:
        TABLE['log'].append(f'NOT CONNECTED frame X={x_frame:.0f}: stiffener Y {y:.0f}, nearest deck member {far[2]} at Y {far[1]:.0f} ({far[0]:.0f} mm away) - owner to decide which is right')
    return None


def move_brackets(xml_path, web_h):
    """R-CN3 (owner 2026-10-23): the bracket of a connection stands at the free edge of the stiffener web, i.e. it is moved along its own V
    (into the room) by the web height of the wall stiffener, and down by the thickness of the beam flange (bracket top = flange underside)."""
    t = etree.parse(xml_path)
    n = 0
    for br in t.getroot().iter('Bracket'):
        c = br.find('CoordSys')
        if c is None:
            continue
        o, w = c.find('Origin'), c.find('Waxis')
        x, y, z = float(o.get('X')), float(o.get('Y')), float(o.get('Z'))
        for lk in TABLE['links']:
            if abs(x - lk['x']) < 3 and abs(abs(y) - lk['wall']) < 3 and abs(z - lk['z']) < 200 and br.get('Source') != 'moved':
                wx = float(w.get('X'))
                o.set('Y', f'{y + (1.0 if wx > 0 else -1.0) * web_h:.10E}')
                o.set('Z', f'{z - lk["tf"]:.10E}')
                br.set('Evidence', (br.get('Evidence') or '') + f' R-CN3 moved {web_h:g} in Y (web height) and {lk["tf"]:g} down (beam flange)')
                n += 1
                break
    t.write(xml_path, xml_declaration=True, encoding='utf-8', pretty_print=True)
    return n


def orient_flanges(xml_path, want=(1.0, 0.0, 0.0)):
    """R-FL1 (owner 2026-10-23): the L-section symbol on the OFF C.L elevations (8525 NO.10 LONGL. ELEV, 18665 OFF C.L ELEV) shows the
    flange of every vertical wall stiffener on the +X side (toward FR.48) of its web.  Deck beams that meet those stiffeners
    (41460 deck, VFD room) take the same flange side.  The flange side is flipped (Waxis negated) where the model has it the other way."""
    from lxml import etree
    t = etree.parse(xml_path)
    n = 0
    for blk in t.getroot().iter('Block'):
        oid = blk.get('ObjId', '')
        for st in blk.iter('Stiffener'):
            nm = st.get('Name', '')
            wall = oid == 'PDF-VFDROOM' and 'OFFCL' in nm
            beam = oid == 'PDF-Z41460' and st.get('Kind') == 'beam'
            if not (wall or beam):
                continue
            w = st.find('Web/CoordSys'); fl = st.find('Flange1/CoordSys')
            if w is None or fl is None:
                continue
            ua = [float(w.find('Uaxis').get(k)) for k in 'XYZ']
            if wall and abs(ua[2]) < 0.9:      # only the vertical wall members
                continue
            if beam and abs(ua[1]) < 0.9:      # only deck beams running in Y
                continue
            if beam:
                ox = float(w.find('Origin').get('X'))
                if not (96000 < ox < 100000):
                    continue
            W = [float(fl.find('Waxis').get(k)) for k in 'XYZ']
            U = [float(fl.find('Uaxis').get(k)) for k in 'XYZ']
            V = [W[1] * U[2] - W[2] * U[1], W[2] * U[0] - W[0] * U[2], W[0] * U[1] - W[1] * U[0]]
            if sum(a * b for a, b in zip(V, want)) < 0:
                for k, v in zip('XYZ', W):
                    fl.find('Waxis').set(k, '%.10E' % (-v if v else 0.0))
                wb = st.find('Web')                     # the web thickness goes to the flange side too, so the L stays one piece
                wb.set('MaterialDirection', 'Negative' if wb.get('MaterialDirection') == 'Positive' else 'Positive')
                n += 1
    t.write(xml_path, xml_declaration=True, encoding='UTF-8')
    return n


def clear_brackets(xml_path, max_shift=600.0, step=2.0):
    """R-G5 fix (owner 2026-10-23): a bracket never overlaps a member.  A bracket that penetrates a web / flange / flange plate is slid IN ITS OWN PLANE,
    along its leg directions, by the smallest distance that clears every member (first along the leg that is perpendicular to its stiffener, i.e. away
    from the web it stands beside; then the other leg; then the negatives).  Result: the bracket stands at the free edge of the web / flange it meets."""
    import numpy as np
    from . import overlap
    t = etree.parse(xml_path)
    parts = overlap.collect(xml_path)
    boxes = []
    for b, p, n, tag, (c, A, h) in parts:
        ext = np.abs(A * h[:, None]).sum(0); boxes.append((c - ext, c + ext, (c, A, h)))

    def hits(Pv, Pe, Pn, near=None):
        lo, hi = Pv.min(0), Pv.max(0)
        return [1 for blo, bhi, bx in (near if near is not None else boxes)
                if not (np.any(blo > hi - overlap.TOL) or np.any(lo > bhi - overlap.TOL)) and overlap._sat_depth(Pv, Pe, Pn, bx) > overlap.TOL]
    brs = {br.get('Name'): br for br in t.getroot().iter('Bracket')}
    fixed, left = [], []
    for name, nm_br in list(brs.items()):
        pass
    for blk, pid, name, Pv, Pe, Pn, host in overlap.collect_brackets(xml_path):
        if not hits(Pv, Pe, Pn):
            continue
        _lo, _hi = Pv.min(0) - max_shift - 5, Pv.max(0) + max_shift + 5
        near = [b_ for b_ in boxes if not (np.any(b_[0] > _hi) or np.any(b_[1] < _lo))]
        br = brs[name]; cs = br.find('CoordSys')
        if (br.get('Source') or '').startswith(('R-VF2', 'R-BT1', 'R-SS3')):          # R-PX1: a bracket at a position the drawing gives never moves; report it instead
            left.append(name); continue
        U = np.array([float(cs.find('Uaxis').get(k)) for k in 'XYZ']); W = np.array([float(cs.find('Waxis').get(k)) for k in 'XYZ'])
        U = U / np.linalg.norm(U); W = W / np.linalg.norm(W); V = np.cross(W, U)
        # direction of the stiffener the bracket belongs to (web U axis of the host)
        tdir = None
        for b, p, n, tag, (c, A, h) in parts:
            if p == host and tag == 'Web':
                tdir = A[0]; break
        # R-G5 (owner 2026-10-24): a bracket is moved only by the WEB DISTANCE of the member it stands beside (its flange width / web depth), never further,
        # and after the move it must still TOUCH that member (connection kept).  Otherwise it is reported, not moved.
        hostb = [(c, A, h) for b, p, n, tag, (c, A, h) in parts if p == host]
        web_dist = 100.0
        for c_, A_, h_ in hostb:
            dd = sorted(2 * h_)
            web_dist = max(web_dist, dd[1])
        order = [U, V, -U, -V]
        if tdir is not None:
            order.sort(key=lambda d: (abs(float(d @ tdir)) > 0.5))          # perpendicular legs first (stable)
        ok = None
        for d in order:                                 # smallest slide over the four in-plane directions (ties: perpendicular leg first)
            s = step
            while s <= min(max_shift, web_dist) and (ok is None or s < ok[1]):
                if not hits(Pv + d * s, Pe, Pn, near):
                    if any(overlap._sat_depth(Pv + d * s, Pe, Pn, (c_, A_, h_ + 4.0)) > 0 for c_, A_, h_ in hostb):
                        ok = (d, s)
                    break
                s += step
        if ok:
            d, s = ok
            o = cs.find('Origin')
            for k, dv in zip('XYZ', d):
                o.set(k, '%.10E' % (float(o.get(k)) + dv * s))
            br.set('Evidence', (br.get('Evidence') or '') + f' R-G5 slid {s:g} mm in its plane to clear the members')
            fixed.append((name, s))
        else:
            left.append(name)
    t.write(xml_path, xml_declaration=True, encoding='utf-8', pretty_print=True)
    return fixed, left
