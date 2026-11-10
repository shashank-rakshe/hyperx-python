"""Write the deck as moulded-line Ship XML in MOULDED-LINE convention.

  * <Ship GeometryConvention="MouldedLine">: every plate lies on its moulded
    plane and every member trace ends on the moulded line of its support.
    The ship importer's thickness-shift rules (4.4, 4.5, 5.2, 5.5, 5.6, 5.9,
    5.12, 5.14) must use zero offset in this mode.
  * No <MaterialSide> element is written at all and no end gap / clearance is applied:
    member ends touch the moulded line of their support (see supports.py).
  * Deep girders/webs ('DEEP GIR. & WEB : 435X10+150X12 F.B(T)') are written as a
    vertical web PlanePanel under the deck plus a FlatBar face plate on its
    lower edge.
"""
import math
import xml.etree.ElementTree as ET


def _f(x):
    return f'{x:.10E}'


def _xyz(parent, tag, x, y, z):
    ET.SubElement(parent, tag, X=_f(x), Y=_f(y), Z=_f(z))


def _contour(parent, tag, pts):
    c = ET.SubElement(parent, tag)
    ET.SubElement(c, 'StartPoint2d', U=_f(pts[0][0]), V=_f(pts[0][1]))
    for p in pts[1:] + [pts[0]]:
        s = ET.SubElement(c, 'Segment2d')
        ET.SubElement(s, 'Amplitude2d', U=_f(0), V=_f(0))
        ET.SubElement(s, 'Node2d', U=_f(p[0]), V=_f(p[1]))
    return c


def _trace(parent, a, b):
    t = ET.SubElement(parent, 'Trace')
    ET.SubElement(t, 'StartPoint2d', U=_f(a[0]), V=_f(a[1]))
    s = ET.SubElement(t, 'Segment2d')
    ET.SubElement(s, 'Amplitude2d', U=_f(0), V=_f(0))
    ET.SubElement(s, 'Node2d', U=_f(b[0]), V=_f(b[1]))


def bar_id(sec):
    k = sec[0]
    if k == 'L':
        return 'LBar' + '*'.join(f'{x:g}' for x in sec[1:]), 'LBar', dict(
            Height=f'{sec[1]:g}', Width=f'{sec[2]:g}', WebThickness=f'{sec[3]:g}', FlangeThickness=f'{sec[4]:g}')
    if k == 'TB':      # R-TB1: T section written as its web (flat bar H x tw) + explicit flange (see add_web_flange)
        return f'FlatBar{sec[1]:g}*{sec[2]:g}', 'FlatBar', dict(Height=f'{sec[1]:g}', Width=f'{sec[2]:g}')
    if k == 'F':
        return f'FlatBar{sec[1]:g}*{sec[2]:g}', 'FlatBar', dict(Height=f'{sec[1]:g}', Width=f'{sec[2]:g}')
    if k == 'R':
        return f'RoundBar{sec[1]:g}', 'RoundBar', dict(Height=f'{sec[1]:g}')
    return None, None, None


BAR_TYPE = {'LBar': '31', 'FlatBar': '10', 'RoundBar': '60'}


def _crossection(parent, tag, attrs):
    """Profile outline in the bar's own (U,V) frame, as the hull-builder reference writes it."""
    f = lambda k: float(attrs[k])
    if tag == 'LBar':
        H, W, tw, tf = f('Height'), f('Width'), f('WebThickness'), f('FlangeThickness')
        start, nodes = (0, 0), [(tw, 0), (tw, H - tf), (W, H - tf), (W, H), (0, H), (0, 0)]
    elif tag == 'FlatBar':
        H, W = f('Height'), f('Width')
        start, nodes = (0, 0), [(W, 0), (W, H), (0, H), (0, 0)]
    else:
        r = f('Height') / 2
        start, nodes = (0, -r), [(r, 0), (0, r), (-r, 0), (0, -r)]
    c = ET.SubElement(parent, 'Crossection')
    ET.SubElement(c, 'StartPoint2d', U=_f(start[0]), V=_f(start[1]))
    for u, v in nodes:
        sg = ET.SubElement(c, 'Segment2d')
        ET.SubElement(sg, 'Amplitude2d', U=_f(0), V=_f(0))
        ET.SubElement(sg, 'Node2d', U=_f(u), V=_f(v))


def orient(a, b, flange_dir=None):
    """Reference trace direction (R-DR): longitudinals run towards -U (aft to fore reversed as in the
    hull-builder file), transverse members towards +V. Same rule for every deck member.
    R-FL2: when the drawing gives the flange side (L symbol in the cutting view), the trace runs so that the flange (side
    tangent x Inclination, Inclination = -Z: (-Ty, Tx)) lies on that side."""
    du, dv = b[0] - a[0], b[1] - a[1]
    if flange_dir:
        L_ = math.hypot(du, dv) or 1.0
        tx, ty = du / L_, dv / L_
        return (a, b) if (-ty * flange_dir[0] + tx * flange_dir[1]) > 0 else (b, a)
    if abs(du) >= abs(dv):
        return (a, b) if du < 0 else (b, a)
    return (a, b) if dv > 0 else (b, a)


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _unit(a):
    n = math.sqrt(sum(x * x for x in a))
    return tuple(x / n for x in a)


def add_web_flange(stiff, a3, b3, incl3, section, fspan=None, end_plane=None):
    """Explicit <Web>/<Flange1> geometry, laid out exactly as the hull-builder reference XML does it
    (the importers build members from these, not from Trace + section alone):
      Web     origin = trace start on the moulded plane, Uaxis = trace tangent, V = Inclination,
              Waxis = U x V, contour L x H, MaterialDirection Positive.
      Flange1 (angles) origin = start + H * Inclination, Waxis = -Inclination, Uaxis = tangent,
              contour L x (tw .. Width), i.e. on the side  tangent x Inclination  of the web,
              MaterialDirection Negative.
    Flat bars have a web only; round/square bars carry no web."""
    k = section[0]
    if k not in ('L', 'F', 'TB'):
        return
    L = math.dist(a3, b3)
    if L < 1e-6:
        return
    f0, f1 = fspan if fspan else (0.0, L)      # R-CN4: the flange may end elsewhere than the web (web-to-web / flange-to-flange connections)
    T = _unit(_sub(b3, a3))
    V = _unit(incl3)
    Wn = _unit(_cross(T, V))
    # R-CB6: on a sloping trace the inclination must be perpendicular to the trace (inside the web plane), otherwise the web
    # (built from W x U) and the flange origin (start + H * V) disagree and the flange floats off the web edge
    d = V[0] * T[0] + V[1] * T[1] + V[2] * T[2]
    if abs(d) > 1e-9:
        V = _unit((V[0] - d * T[0], V[1] - d * T[1], V[2] - d * T[2]))
    H = section[1]
    def _lend(v, w):
        # R-CN6: length along the trace at which the member point (v along the inclination, w across) meets the surface n.p = d; no plane: the trace end
        if not end_plane:
            return L
        n, dd = end_plane
        Pp = [a3[i] + V[i] * v + Wn[i] * w for i in range(3)]
        den = sum(n[i] * T[i] for i in range(3))
        return (dd - sum(n[i] * Pp[i] for i in range(3))) / den if abs(den) > 1e-6 else L
    web = ET.SubElement(stiff, 'Web', MaterialDirection='Positive')
    cs = ET.SubElement(web, 'CoordSys')
    _xyz(cs, 'Origin', *a3)
    _xyz(cs, 'Waxis', *Wn)
    _xyz(cs, 'Uaxis', *T)
    _contour(web, 'DetailedContour', [(0, 0), (_lend(0, 0), 0), (_lend(H, 0), H), (0, H)])
    if k == 'TB':
        # R-TB1: flange centred on the web, surface at the web top (H), width w, thickness t (kept as metadata)
        wf, tf = section[3], section[4]
        fl = ET.SubElement(stiff, 'Flange1', MaterialDirection='Negative', Thickness=f'{tf:g}')
        cs = ET.SubElement(fl, 'CoordSys')
        _xyz(cs, 'Origin', a3[0] + V[0] * H, a3[1] + V[1] * H, a3[2] + V[2] * H)
        _xyz(cs, 'Waxis', -V[0], -V[1], -V[2])
        _xyz(cs, 'Uaxis', *T)
        _contour(fl, 'DetailedContour', [(f0, -wf / 2), (_lend(H + tf / 2, -wf / 2) if end_plane else f1, -wf / 2), (_lend(H + tf / 2, wf / 2) if end_plane else f1, wf / 2), (f0, wf / 2)])
    if k == 'L':
        Wd, tw = section[2], section[3]
        fl = ET.SubElement(stiff, 'Flange1', MaterialDirection='Negative')
        cs = ET.SubElement(fl, 'CoordSys')
        _xyz(cs, 'Origin', a3[0] + V[0] * H, a3[1] + V[1] * H, a3[2] + V[2] * H)
        _xyz(cs, 'Waxis', -V[0], -V[1], -V[2])
        _xyz(cs, 'Uaxis', *T)
        _contour(fl, 'DetailedContour', [(f0, tw), (f1, tw), (f1, Wd), (f0, Wd)])


def _coords(poly):
    if poly.geom_type != 'Polygon':
        poly = max(poly.geoms, key=lambda g: g.area)
    return [(x, y) for x, y in list(poly.exterior.coords)[:-1]]


def _split_camber(deck):
    """R-CB: cut zones / members at the camber knuckle; returns (main_zones, main_members, tilts)."""
    from shapely.geometry import box, LineString
    from shapely.ops import unary_union
    strips = deck.get('camber') or []
    if not strips:
        return deck['zones'], deck['members'], []
    tilts = []
    for st in strips:
        sg = 1.0 if st['side'] == 'P' else -1.0
        k0, k1 = st['knuckle'], st['outer']
        y0, y1 = sorted((sg * k0, sg * k1))
        if st.get('cover_all'):           # R-CB4: one sloping surface over the whole drawn deck, not only between the two OFF C.L lines
            fb_ = deck['footprint'].bounds
            y0, y1 = fb_[1] - 1.0, fb_[3] + 1.0
        tilts.append({'st': st, 'sg': sg, 'rect': box(-1e7, y0, 1e7, y1), 'zones': [], 'members': [], 'holes': []})
    allrect = unary_union([t['rect'] for t in tilts])
    zones = []
    main_open = []
    for o in deck.get('openings', []):          # R-CB5: an opening inside a camber strip is a hole of the TILTED panel's plates, not of the flat panel
        for t in tilts:
            inn = o['poly'].intersection(t['rect'])
            if not inn.is_empty and inn.area > 1e4:
                t['holes'].append(dict(o, poly=inn))
        rest_o = o['poly'].difference(allrect)
        if not rest_o.is_empty and rest_o.area > 1e4:
            main_open.append(dict(o, poly=rest_o))
    deck['_main_openings'] = main_open
    for z in deck['zones']:
        for t in tilts:
            inn = z['poly'].intersection(t['rect'])
            if not inn.is_empty and inn.area > 2e4:
                t['zones'].append(dict(z, poly=inn))
        rest = z['poly'].difference(allrect)
        if not rest.is_empty and rest.area > 2e4:
            zones.append(dict(z, poly=rest))
    members = []
    for m in deck['members']:
        ln = LineString([m['a'], m['b']])
        if ln.length < 1:
            members.append(m)
            continue
        hit = False
        for t in tilts:
            inn = ln.intersection(t['rect'])
            for g in getattr(inn, 'geoms', [inn]):
                if g.geom_type == 'LineString' and g.length > 150:
                    hit = True
                    c = list(g.coords)
                    a, b = c[0], c[-1]
                    if math.dist(a, m['a']) > math.dist(b, m['a']):
                        a, b = b, a
                    t['members'].append(dict(m, a=a, b=b, bracket_a=m.get('bracket_a') and math.dist(a, m['a']) < 2,
                                             bracket_b=m.get('bracket_b') and math.dist(b, m['b']) < 2))
        out = ln.difference(allrect)
        if not hit:
            members.append(m)
            continue
        for g in getattr(out, 'geoms', [out]):
            if g.geom_type == 'LineString' and g.length > 150:
                c = list(g.coords)
                a, b = c[0], c[-1]
                if math.dist(a, m['a']) > math.dist(b, m['a']):
                    a, b = b, a
                members.append(dict(m, a=a, b=b, bracket_a=m.get('bracket_a') and math.dist(a, m['a']) < 2,
                                    bracket_b=m.get('bracket_b') and math.dist(b, m['b']) < 2))
    return zones, members, tilts


def _split_sheer(deck, zones, members):
    """R-SH: cut zones / members at the sheer strip (or take the whole deck for a slanted plan)."""
    from shapely.geometry import box, LineString
    sh = deck.get('sheer')
    if sh and sh.get('zr') is None:
        sh = dict(sh, zr=deck['z'])
    if not sh:
        return zones, members, []
    rect = box(sh['x0'], -1e7, sh['x1'], 1e7)
    t = {'sheer': sh, 'rect': rect, 'zones': [], 'members': []}
    zo = []
    for z in zones:
        inn = z['poly'].intersection(rect)
        if not inn.is_empty and inn.area > 2e4:
            t['zones'].append(dict(z, poly=inn))
        rest = z['poly'].difference(rect)
        if not rest.is_empty and rest.area > 2e4:
            zo.append(dict(z, poly=rest))
    mo = []
    for m in members:
        ln = LineString([m['a'], m['b']])
        if ln.length < 1:
            mo.append(m)
            continue
        inn = ln.intersection(rect)
        hit = False
        for g in getattr(inn, 'geoms', [inn]):
            if g.geom_type == 'LineString' and g.length > 150:
                hit = True
                c = list(g.coords)
                a, b = c[0], c[-1]
                if math.dist(a, m['a']) > math.dist(b, m['a']):
                    a, b = b, a
                t['members'].append(dict(m, a=a, b=b, bracket_a=m.get('bracket_a') and math.dist(a, m['a']) < 2,
                                         bracket_b=m.get('bracket_b') and math.dist(b, m['b']) < 2))
        if not hit:
            mo.append(m)
            continue
        out = ln.difference(rect)
        for g in getattr(out, 'geoms', [out]):
            if g.geom_type == 'LineString' and g.length > 150:
                c = list(g.coords)
                a, b = c[0], c[-1]
                if math.dist(a, m['a']) > math.dist(b, m['a']):
                    a, b = b, a
                mo.append(dict(m, a=a, b=b, bracket_a=m.get('bracket_a') and math.dist(a, m['a']) < 2,
                               bracket_b=m.get('bracket_b') and math.dist(b, m['b']) < 2))
    return zo, mo, [t]


def _common_bracket(members, leg0, bt0):
    """R4.13 (online rule book v2.3): a 'B' without a printed size gets the MOST COMMON printed bracket size of the same deck / wall;
    the settings default is used only when the drawing prints none (flagged ASSUMED in Source)."""
    from collections import Counter
    c = Counter(tuple(m.get('bracket_size_' + e)) for m in members for e in 'ab' if m.get('bracket_' + e) and m.get('bracket_size_' + e))
    if c:
        (leg, bt), _ = c.most_common(1)[0]
        return float(leg), float(bt), True
    return leg0, bt0, False


def _write_tilt(blk, pid, deck, t, k, gid_start=1, settings=None):
    settings = settings or {}
    """tilted deck strip (camber) as its own PlanePanel: flat at the knuckle, dropping n at the outer edge"""
    if t.get('sheer'):                    # R-SH: plate tilted about the Y axis (deck rises / falls along X)
        sh = t['sheer']
        slope = sh['slope']
        nrm = math.sqrt(1 + slope * slope)
        tid = f"{pid}-SH{k}"
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=tid, Tightness='NonTight', Sheer=f"{sh['n']:g}")
        cs = ET.SubElement(pp, 'CoordSys')
        _xyz(cs, 'Origin', sh['xr'], 0, sh['zr'])
        _xyz(cs, 'Waxis', -slope / nrm, 0, 1 / nrm)
        _xyz(cs, 'Uaxis', 1 / nrm, 0, slope / nrm)
        to_uv = lambda x, y: ((x - sh['xr']) * nrm, y)
        zf = lambda x, y: sh['zr'] + slope * (x - sh['xr'])
        note = 'sheer'
    else:
        st, sg = t['st'], t['sg']
        n = st['n']
        slope = n / max(st['outer'] - st['knuckle'], 1.0)
        nrm = math.sqrt(1 + slope * slope)
        tid = f"{pid}-CB{st['side']}{k}"
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=tid, Tightness='NonTight', Camber=f"{n:g}")
        cs = ET.SubElement(pp, 'CoordSys')
        Y0 = sg * st['knuckle']
        _xyz(cs, 'Origin', 0, Y0, deck['z'])
        _xyz(cs, 'Waxis', 0, sg * slope / nrm, 1 / nrm)
        _xyz(cs, 'Uaxis', 1, 0, 0)
        to_uv = lambda x, y: (x, (y - Y0) * nrm)
        zf = lambda x, y: deck['z'] - slope * abs(y - Y0)
        note = 'camber'
    zs = [g for z in t['zones'] for g in getattr(z['poly'], 'geoms', [z['poly']]) if not g.is_empty]
    allp = unary_union_safe([g for g in zs])
    if allp is not None and not allp.is_empty:
        hull = allp.convex_hull
        bd = ET.SubElement(pp, 'Boundary')
        _contour(bd, 'SimpleContour', [to_uv(*c) for c in list(hull.exterior.coords)[:-1]])
    gid = gid_start
    for i, z in enumerate(t['zones'], 1):
        for g in getattr(z['poly'], 'geoms', [z['poly']]):
            if g.is_empty or g.area < 2e4:
                continue
            pg = ET.SubElement(pp, 'PlateGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(pg, 'Material', Grade=z.get('grade', 'A'))
            ET.SubElement(mat, 'Thickness').text = f"{z['t']:g}"
            pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{tid}-P{i}.{gid-1}', Source=z['source'] + '; ' + note + ' strip')
            _contour(pl, 'SimpleContour', [to_uv(*c) for c in list(g.exterior.coords)[:-1]])
    holes = t.get('holes') or []
    if holes:
        hg = ET.SubElement(pp, 'HoleGroup', GroupId=str(gid))
        gid += 1
        for i, o in enumerate(holes, 1):
            for g in getattr(o['poly'], 'geoms', [o['poly']]):
                if g.is_empty or g.area < 1e4 or g.geom_type != 'Polygon':
                    continue
                h = ET.SubElement(hg, 'Hole', CompId=str(i), Rule=o['why'])
                _contour(h, 'Contour', [to_uv(*c) for c in list(g.exterior.coords)[:-1]])
    nmem = 0
    for m in t['members']:
        if not m.get('section') or m['section'][0] not in ('L', 'F', 'R', 'TB'):
            continue
        nmem += 1
        bid, tag, attrs = bar_id(m['section'])
        sgp = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight')
        gid += 1
        mat = ET.SubElement(sgp, 'Material', Grade='A')
        bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
        ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in m['section'][1:])
        _crossection(bs, tag, attrs)
        sti = ET.SubElement(sgp, 'Stiffener', CompId='1', Name=f"{tid}/{m['kind'][0].upper()}{nmem}", Kind=m['kind'],
                            Evidence='; '.join(m['evidence'])[:300])
        a0, b0 = orient(m['a'], m['b'], m.get('flange_dir'))
        # R-CB8: the web of a stiffener on the sloping strip stands perpendicular to the strip, so at the knuckle its flange
        # end is H*tan(slope) (~1.4 mm for 150 U.A on 150 mm camber) away from the flange end of the flat part. The start is shifted
        # along the trace so that the two flange ends meet exactly (the web bottom then overlaps by that amount instead of leaving a gap)
        if not t.get('sheer') and m['section'][0] in 'LF':
            Hh = float(m['section'][1])
            for which in ('a', 'b'):
                pp_, qq_ = (a0, b0) if which == 'a' else (b0, a0)
                if abs(pp_[1] - Y0) < 2.0:
                    p3 = (pp_[0], pp_[1], zf(*pp_)); q3 = (qq_[0], qq_[1], zf(*qq_))
                    Tt = _unit(_sub(q3, p3))
                    Vv = _unit((0, 0, -1))
                    dd = sum(x * y for x, y in zip(Vv, Tt))
                    Vv = _unit(tuple(Vv[i] - dd * Tt[i] for i in range(3)))
                    if abs(Tt[1]) > 1e-6:
                        sh_ = (Y0 - p3[1] - Hh * Vv[1]) / Tt[1]
                        if abs(sh_) < 10.0:
                            newp = (pp_[0] + sh_ * Tt[0], pp_[1] + sh_ * Tt[1])
                            if which == 'a':
                                a0 = newp
                            else:
                                b0 = newp
        _trace(sti, to_uv(*a0), to_uv(*b0))
        inc = ET.SubElement(sti, 'Inclination')
        for _ in range(2):
            ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(-1))
        za = zf(*a0)
        zb = zf(*b0)
        add_web_flange(sti, (a0[0], a0[1], za), (b0[0], b0[1], zb), (0, 0, -1), m['section'])
    leg0 = float(settings.get('bracket_leg_mm', 200.0))
    bt0 = float(settings.get('bracket_thk_mm', 8.0))
    cleg, cbt, cprinted = _common_bracket(t['members'], leg0, bt0)
    nb = 0
    for m in t['members']:
        if not m.get('section') or m['section'][0] not in ('L', 'F', 'R', 'TB'):
            continue
        for end, oth in (('a', 'b'), ('b', 'a')):
            if not m.get('bracket_' + end):
                continue
            sz = m.get('bracket_size_' + end)            # R-B3: size printed in the bracket callout (WxT)
            leg, bt = (sz[0], sz[1]) if sz else (cleg, cbt)
            leg2 = float(m['section'][1]) if (sz and settings.get('one_leg_bracket_follows_member')) else leg   # R4.16 (pending owner): printed = one leg
            p, q = m[end], m[oth]
            L = math.dist(p, q)
            if L < 2 * leg * 0.6:
                continue
            dx, dy = (q[0] - p[0]) / L, (q[1] - p[1]) / L
            nb += 1
            bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(bg, 'Material', Grade='A')
            ET.SubElement(mat, 'Thickness').text = f'{bt:g}'
            br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f'{tid}-B{nb}', Source='B mark at stiffener end (' + note + ' strip)' + ((' - size not printed, most common printed size %gx%g of this deck (R4.13, ASSUMED)' if cprinted else ' - size UNKNOWN, default %gx%g') % (leg, bt) if not sz else ' - size %gx%g from drawing' % (leg, bt)))
            cs2 = ET.SubElement(br, 'CoordSys')
            _xyz(cs2, 'Origin', p[0], p[1], zf(*p) - float(m['section'][1]))
            _xyz(cs2, 'Waxis', dy, -dx, 0)
            _xyz(cs2, 'Uaxis', 0, 0, -1)
            _contour(br, 'SimpleContour', [(0, 0), (leg2, 0), (0, leg)])   # owner: simple right triangle, no toe / chamfer
            ET.SubElement(br, 'End1')
            e2 = ET.SubElement(br, 'End2')
            ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=tid, CompType='Stiffener', CompId='1')
    return gid


def unary_union_safe(gs):
    from shapely.ops import unary_union
    gs = [g for g in gs if g is not None and not g.is_empty]
    return unary_union(gs) if gs else None


def write(path, deck, settings):
    """deck: dict(name, code, z, zones, openings, footprint, members, deep)."""
    ship = ET.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine',
                      Source='deckrules (PDF drawing only)')
    ET.SubElement(ship, 'Material', Grade='A')
    used = {}
    main_zones, main_members, tilts = _split_camber(deck)
    main_zones, main_members, sh_t = _split_sheer(deck, main_zones, main_members)
    tilts = tilts + sh_t
    deck = dict(deck, zones=main_zones, members=main_members)
    if '_main_openings' in deck:
        deck['openings'] = deck['_main_openings']
    for m in deck['members'] + [mm for t in tilts for mm in t['members']]:
        if m.get('section') and m['section'][0] in ('L', 'F', 'R', 'TB'):
            bid, tag, attrs = bar_id(m['section'])
            used[bid] = (tag, attrs)
    for c_ in deck.get('coamings', []):
        b_, t_, a_ = bar_id(('F', c_['bar'][0], c_['bar'][1]))
        used[b_] = (t_, a_)
    if deck.get('deep'):
        for m_ in deck['deep']:
            fw, ft_ = m_.get('face', (150.0, 12.0))
            used[f'FlatBar{fw / 2:g}*{ft_:g}'] = ('FlatBar', {'Height': f'{fw / 2:g}', 'Width': f'{ft_:g}'})
    for bid, (tag, attrs) in sorted(used.items()):
        bs = ET.SubElement(ship, 'BarSection', BarSectionId=bid)
        ET.SubElement(bs, tag, **attrs)
    blk = ET.SubElement(ship, 'Block', ObjId=f"PDF-{deck['code']}")
    pid = f"PDF-{deck['code']}DK"
    pp = ET.SubElement(blk, 'PlanePanel', ObjId=pid, Tightness='NonTight')
    cs = ET.SubElement(pp, 'CoordSys')
    _xyz(cs, 'Origin', 0, 0, deck['z'])
    _xyz(cs, 'Waxis', 0, 0, 1)
    _xyz(cs, 'Uaxis', 1, 0, 0)
    bd = ET.SubElement(pp, 'Boundary')
    _contour(bd, 'SimpleContour', _coords(deck['footprint']))
    gid = 1
    for i, z in enumerate(deck['zones'], 1):
        for g in getattr(z['poly'], 'geoms', [z['poly']]):
            if g.is_empty or g.area < 2e4:
                continue
            pg = ET.SubElement(pp, 'PlateGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(pg, 'Material', Grade=z.get('grade', 'A'))
            ET.SubElement(mat, 'Thickness').text = f"{z['t']:g}"
            pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{pid}-P{i}' if not sum(1 for _ in getattr(z['poly'],'geoms',[z['poly']]))>1 else f'{pid}-P{i}.{gid-1}', Source=z['source'])
            _contour(pl, 'SimpleContour', _coords(g))
    if deck['openings']:
        hg = ET.SubElement(pp, 'HoleGroup', GroupId=str(gid))
        gid += 1
        for i, o in enumerate(deck['openings'], 1):
            h = ET.SubElement(hg, 'Hole', CompId=str(i), Rule=o['why'])
            _contour(h, 'Contour', _coords(o['poly']))
    n = 0
    for m in deck['members']:
        if not m.get('section') or m['section'][0] not in ('L', 'F', 'R', 'TB'):
            continue
        bid, _, _ = bar_id(m['section'])
        n += 1
        sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight')
        gid += 1
        mat = ET.SubElement(sg, 'Material', Grade='A')
        _, tag, attrs = bar_id(m['section'])
        bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
        ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in m['section'][1:])
        _crossection(bs, tag, attrs)
        st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f"{pid}/{m['kind'][0].upper()}{n}",
                           Kind=m['kind'], Evidence='; '.join(m['evidence'])[:300])
        a0, b0 = orient(m['a'], m['b'], m.get('flange_dir'))
        _trace(st, a0, b0)
        inc = ET.SubElement(st, 'Inclination')
        for _ in range(2):
            ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(-1))
        add_web_flange(st, (a0[0], a0[1], deck['z']), (b0[0], b0[1], deck['z']), (0, 0, -1), m['section'])
    # R-B2: bracket at every stiffener end that carries a 'B' mark (owner Q3). Learned from the reference brackets:
    # right triangle in the web plane, legs 200 x 200, 8 mm Grade A, 20 mm chamfer at the corner, tips rounded ~13.
    nb = 0
    leg0 = float(settings.get('bracket_leg_mm', 200.0))
    bt0 = float(settings.get('bracket_thk_mm', 8.0))
    cleg, cbt, cprinted = _common_bracket(deck['members'], leg0, bt0)
    for m in deck['members']:
        if not m.get('section') or m['section'][0] not in ('L', 'F', 'R', 'TB'):
            continue
        for end, oth in (('a', 'b'), ('b', 'a')):
            if not m.get('bracket_' + end):
                continue
            sz = m.get('bracket_size_' + end)            # R-B3: size printed in the bracket callout (WxT)
            leg, bt = (sz[0], sz[1]) if sz else (cleg, cbt)
            leg2 = float(m['section'][1]) if (sz and settings.get('one_leg_bracket_follows_member')) else leg   # R4.16 (pending owner): printed = one leg
            p, q = m[end], m[oth]
            L = math.dist(p, q)
            if L < 2 * leg * 0.6:
                continue
            dx, dy = (q[0] - p[0]) / L, (q[1] - p[1]) / L
            h = float(m['section'][1])
            nb += 1
            bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
            gid += 1
            mat = ET.SubElement(bg, 'Material', Grade='A')
            ET.SubElement(mat, 'Thickness').text = f'{bt:g}'
            br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f"{pid}-B{nb}", Source='B mark at stiffener end' + ((' - size not printed, most common printed size %gx%g of this deck (R4.13, ASSUMED)' if cprinted else ' - size UNKNOWN, default %gx%g') % (leg, bt) if not sz else ' - size %gx%g from drawing' % (leg, bt)))
            cs = ET.SubElement(br, 'CoordSys')
            _xyz(cs, 'Origin', p[0], p[1], deck['z'] - h)
            _xyz(cs, 'Waxis', dy, -dx, 0)
            _xyz(cs, 'Uaxis', 0, 0, -1)
            _contour(br, 'SimpleContour', [(0, 0), (leg2, 0), (0, leg)])   # owner: simple right triangle, no toe / chamfer
            e1 = ET.SubElement(br, 'End1')
            e2 = ET.SubElement(br, 'End2')
            ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=pid, CompType='Stiffener', CompId='1')
    for wb in deck.get('wall_brackets', []):          # R-B10: wall-stiffener bracket at the deck / wall corner, in the stroke's vertical plane
        (x, y), (dx, dy) = wb['p'], wb['d']
        leg, bt = wb['size'] if wb.get('size') else (leg0, bt0)
        nb += 1
        bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid))
        gid += 1
        mat = ET.SubElement(bg, 'Material', Grade='A')
        ET.SubElement(mat, 'Thickness').text = f'{bt:g}'
        br = ET.SubElement(bg, 'Bracket', CompId='1', Name=f"{pid}-WB{nb}", Source='B mark at wall stiffener' + (' - size UNKNOWN, default %gx%g' % (leg, bt) if not wb.get('size') else ' - size %gx%g from drawing' % (leg, bt)),
                           Evidence='; '.join(wb.get('evidence', []))[:300])
        cs = ET.SubElement(br, 'CoordSys')
        _xyz(cs, 'Origin', x, y, deck['z'])
        _xyz(cs, 'Waxis', dy, -dx, 0)
        _xyz(cs, 'Uaxis', 0, 0, -1)
        _contour(br, 'SimpleContour', [(0, 0), (leg, 0), (0, leg)])
        ET.SubElement(br, 'End1')
        ET.SubElement(br, 'End2')
    for k, t in enumerate(tilts, 1):
        gid = _write_tilt(blk, pid, deck, t, k, gid, settings)
    # support lines (walls / bulkheads of the tier below) that carry member ends: moulded lines, no offset
    sup = deck.get('supports', [])
    if sup:
        sl = ET.SubElement(pp, 'SupportLines')
        for w in sup:
            (x1, y1), (x2, y2) = list(w.coords)[0], list(w.coords)[-1]
            ET.SubElement(sl, 'SupportLine', Kind='wall', U1=_f(x1), V1=_f(y1), U2=_f(x2), V2=_f(y2))
    # deep girders / webs: vertical web panel + face plate
    cam0 = (deck.get('camber') or [None])[0]

    def zdeck(x, y):                          # R-CB7: girders on a cambered deck follow the sloping surface (strip of the member's own side)
        if not cam0:
            return deck['z']
        side = 'P' if y >= 0 else 'S'
        c = next((s for s in deck.get('camber') or [] if s.get('side') == side), None)
        if c is None:
            c = cam0 if len(deck.get('camber') or []) == 1 and not cam0.get('side') else None
        if c is None:
            return deck['z']
        sl = c['n'] / max(c['outer'] - c['inner'], 1.0)
        d = min(max(abs(y) - c['knuckle'], 0.0), c['outer'] - c['knuckle'])
        return deck['z'] - sl * d
    for j, m in enumerate(deck.get('deep', []), 1):
        a, b = m['a'], m['b']
        import os as _o
        if _o.environ.get('FPDBG'): print('EXPDEEP', j, a, b)
        L2 = math.dist(a, b)
        if L2 < 1:
            continue
        za_, zb_ = zdeck(*a), zdeck(*b)
        tx, ty, tz = b[0] - a[0], b[1] - a[1], zb_ - za_
        L = math.sqrt(tx * tx + ty * ty + tz * tz)
        ux, uy, uz = tx / L, ty / L, tz / L
        hh = math.hypot(ux, uy)
        web = ET.SubElement(blk, 'PlanePanel', ObjId=f"{pid}-DEEP{j}", Tightness='NonTight', Kind='deep web/girder')
        cs = ET.SubElement(web, 'CoordSys')
        _xyz(cs, 'Origin', a[0], a[1], za_)
        _xyz(cs, 'Waxis', -uy / hh, ux / hh, 0)
        _xyz(cs, 'Uaxis', ux, uy, uz)
        depth = m.get('depth', 435.0)
        pg = ET.SubElement(web, 'PlateGroup', GroupId='1')
        mat = ET.SubElement(pg, 'Material', Grade='A')
        ET.SubElement(mat, 'Thickness').text = f"{m.get('web_t', 10.0):g}"
        pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f"{pid}-DEEP{j}-WEB")
        _contour(pl, 'SimpleContour', [(0, 0), (L, 0), (L, depth), (0, depth)])   # R-DG3: deck girders hang BELOW the deck (V of this panel points down)
        # R-DG4b (owner 2026-10-23: 'section not built' - flat-bar face plates on the panel edge did not appear in his model tree):
        # the T flange is its own horizontal plate panel (width fw centred on the web, thickness ft) at the free edge of the web
        fw, ft_ = m.get('face', (150.0, 12.0))
        fl = ET.SubElement(blk, 'PlanePanel', ObjId=f"{pid}-DEEP{j}-FLANGE", Tightness='NonTight', Kind='girder flange')
        cs2 = ET.SubElement(fl, 'CoordSys')
        _wn = math.sqrt(max(1 - uz * uz, 1e-9))
        _wx, _wy, _wz = -ux * uz / _wn, -uy * uz / _wn, _wn
        # R-SD1: the face plate lies INSIDE the web depth (depth-ft .. depth): its centre is ft/2 above the web bottom edge
        _xyz(cs2, 'Origin', a[0], a[1], za_ - depth)      # R-SD3: surface at the web's free edge, material inward (up)
        _xyz(cs2, 'Waxis', _wx, _wy, _wz)
        _xyz(cs2, 'Uaxis', ux, uy, uz)
        pg2 = ET.SubElement(fl, 'PlateGroup', GroupId='1')
        mat2 = ET.SubElement(pg2, 'Material', Grade='A')
        ET.SubElement(mat2, 'Thickness').text = f'{ft_:g}'
        pl2 = ET.SubElement(pg2, 'Plate', CompId='1', Name=f"{pid}-DEEP{j}-FLANGE-P1")
        _contour(pl2, 'SimpleContour', [(0, -fw / 2), (L, -fw / 2), (L, fw / 2), (0, fw / 2)])
    # R-CO1 coamings: sloping plate #1 (inner edge at deck level -> 'drop' lower at the outer edge) + flat bar standing on the inner edge
    for j, c in enumerate(deck.get('coamings', []), 1):
        Lx = c['x1'] - c['x0']
        dy = c['y_out'] - c['y_in']
        dz = -c['drop']
        Ls = math.hypot(dy, dz)
        vy, vz = dy / Ls, dz / Ls
        wy, wz = -vz, vy                      # W = U x V, U = (1,0,0), V = (0,vy,vz)
        nW = math.hypot(wy, wz)
        wy, wz = wy / nW, wz / nW
        cp = ET.SubElement(blk, 'PlanePanel', ObjId=f"{pid}-COAM{j}", Tightness='NonTight', Kind='coaming plate #1', Evidence=c['src'] + ' - ASSUMED from section: confirm')
        cs = ET.SubElement(cp, 'CoordSys')
        _xyz(cs, 'Origin', c['x0'], c['y_in'], deck['z'])
        _xyz(cs, 'Waxis', 0, wy, wz)
        _xyz(cs, 'Uaxis', 1, 0, 0)
        pg = ET.SubElement(cp, 'PlateGroup', GroupId='1')
        mat = ET.SubElement(pg, 'Material', Grade='A')
        ET.SubElement(mat, 'Thickness').text = f"{c['t']:g}"
        pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f"{pid}-COAM{j}-P")
        _contour(pl, 'SimpleContour', [(0, 0), (Lx, 0), (Lx, Ls), (0, Ls)])
        bw, bt = c['bar']
        bid, tag, attrs = bar_id(('F', bw, bt))
        sgp = ET.SubElement(cp, 'StiffenerGroup', GroupId='2', BendType='Straight')
        mt = ET.SubElement(sgp, 'Material', Grade='A')
        bs = ET.SubElement(mt, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
        ET.SubElement(bs, 'Parameters').text = f'{bw:g} {bt:g}'
        _crossection(bs, tag, attrs)
        st = ET.SubElement(sgp, 'Stiffener', CompId='1', Name=f"{pid}-COAM{j}-FB", Kind='coaming', Evidence=c['src'])
        _trace(st, (0, 0), (Lx, 0))
        inc = ET.SubElement(st, 'Inclination')
        for _ in range(2):
            ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(vz * 1.0), W=_f(wz))   # global 'up' expressed in the panel axes
    ET.indent(ship)
    ET.ElementTree(ship).write(path, encoding='utf-8', xml_declaration=True)
    return {'plates': gid, 'stiffeners': n, 'deep': len(deck.get('deep', [])), 'brackets': nb}
