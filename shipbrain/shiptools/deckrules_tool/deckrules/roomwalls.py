"""R-RW1 (owner 2026-10-23): VFD-room box walls at OFF C.L 8525 ('NO.10 LONGL. ELEV.(S)') and 18665 ('18665 OFF C.L ELEV.(S)').
Read from the two elevations (labels first: 47-4000, 47, 37160 A/B, 41522 A/B / 41461 A/B, STIFF. 150X90X12 U.A, PLATE THK. 11.0,
800 pitch; pixels only to place the B-marked members).
 - wall plate 11.0, X 96000..100000, Z 37160..top (41522 at 8525, 41461 at 18665)
 - 4 vertical B stiffeners at 800 pitch from FR.47-4000 (X 96800..99200), Z 37500..top-100
 - 4 short horizontal stiffeners at the FR.47-4000 end (800 long), 800 pitch down from the top
 - horizontal B member at Z 37500 over the full width
 - vertical T at FR.47: web 450X12 in the wall plane (X 100000..100450) + flange 125X15 centred on the web edge, Z 37160..42961
All stiffeners 150X90X12 U.A on the VFD-room side. B-mark detail ('1A2-1') and the R300 knee bracket are NOT modelled (CONFIRM)."""
import sys
import xml.etree.ElementTree as ET
from .export import _contour, _trace, _xyz, _f, bar_id, BAR_TYPE, _crossection, add_web_flange

SEC = ('L', 150.0, 90.0, 12.0, 12.0)
X0, X1, XT = 96000.0, 100000.0, 100450.0
ZB, ZCRT = 37160.0, 42961.0


def _stiff(pp, gid, pid, n, a, b, wsign, note, oc):
    bid, tag, attrs = bar_id(SEC)
    sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight')
    mat = ET.SubElement(sg, 'Material', Grade='A')
    bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
    ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in SEC[1:])
    _crossection(bs, tag, attrs)
    st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/S{n}', Kind='wall stiffener', Evidence=note)
    (u1, v1), (u2, v2) = a, b
    if abs(u2 - u1) >= abs(v2 - v1):           # R-DR: longitudinal members run towards -U, verticals towards +V
        if u2 > u1:
            (u1, v1), (u2, v2) = (u2, v2), (u1, v1)
    elif v2 < v1:
        (u1, v1), (u2, v2) = (u2, v2), (u1, v1)
    _trace(st, (u1, v1), (u2, v2))
    inc = ET.SubElement(st, 'Inclination')
    for _ in range(2):
        ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(wsign))
    add_web_flange(st, (u1, oc, v1), (u2, oc, v2), (0, -wsign, 0), SEC)


def beam_positions(files, ztop=41460.0, offcls=(8525.0, 18665.0)):
    """R-RW4 (owner 2026-10-23): the wall stiffener stands where the deck beam meets the wall - X of every deck beam of the 41460 deck that
    spans both OFF C.L walls (the deck builder has already put its bracket at that intersection)."""
    from lxml import etree
    cov = {}
    for f in files:
        try:
            r = etree.parse(f).getroot()
        except Exception:
            continue
        for pp in r.iter('PlanePanel'):
            o = pp.find('CoordSys/Origin')
            if o is None or abs(float(o.get('Z')) - ztop) > 1 or abs(float(o.get('X'))) > 1:
                continue
            for st in pp.iter('Stiffener'):
                if st.get('Kind') != 'beam':
                    continue
                a = st.find('Trace/StartPoint2d'); b = st.find('Trace/Segment2d/Node2d')
                u1, v1, u2, v2 = float(a.get('U')), float(a.get('V')), float(b.get('U')), float(b.get('V'))
                if abs(u1 - u2) < 2 and X0 < u1 < X1:
                    c = cov.setdefault(round(u1), [1e9, 0.0])
                    c[0] = min(c[0], abs(v1), abs(v2)); c[1] = max(c[1], abs(v1), abs(v2))
    xs = {x for x, (lo, hi) in cov.items() if lo <= offcls[0] + 60 and hi >= offcls[1] - 60}
    # beams split by a girder (B1 + B2 of the same X) join into one X
    return sorted(xs) or [96800.0 + 800 * k for k in range(4)]


def build(out_xml, beam_x=None):
    ship = ET.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine', Source='deckrules VFD room walls (PDF drawing only)')
    ET.SubElement(ship, 'Material', Grade='A')
    bid, tag, attrs = bar_id(SEC)
    bsx = ET.SubElement(ship, 'BarSection', BarSectionId=bid)
    ET.SubElement(bsx, tag, **attrs)
    blk = ET.SubElement(ship, 'Block', ObjId='PDF-VFDROOM')
    beam_x = list(beam_x) if beam_x else [96800.0 + 800 * k for k in range(4)]
    for oc, top, wsign in ((8525, 41460.0, 1.0), (18665, 41460.0, -1.0)):
        y = -float(oc)
        pid = f'PDF-VFDROOM-OFFCL{oc}'
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=pid, Tightness='NonTight')
        cs = ET.SubElement(pp, 'CoordSys')
        _xyz(cs, 'Origin', 0, y, 0); _xyz(cs, 'Waxis', 0, -1, 0); _xyz(cs, 'Uaxis', 1, 0, 0)
        poly = [(X0, ZB), (XT, ZB), (XT, ZCRT), (X1, ZCRT), (X1, top), (X0, top)]
        poly = [(X0, ZB), (X1, ZB), (X1, top), (X0, top)]
        bd = ET.SubElement(pp, 'Boundary'); _contour(bd, 'SimpleContour', poly)
        pg = ET.SubElement(pp, 'PlateGroup', GroupId='1')
        m = ET.SubElement(pg, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '11'
        pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{pid}-P1', Source='R-RW1 PLATE THK. 11.0 of the elevation')
        _contour(pl, 'SimpleContour', poly)
        # FR.47 vertical T: web (in the wall plane) 450X12
        pg2 = ET.SubElement(pp, 'PlateGroup', GroupId='2')
        m = ET.SubElement(pg2, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '12'
        wp = [(X1, ZB), (XT, ZB), (XT, ZCRT), (X1, ZCRT)]
        pl = ET.SubElement(pg2, 'Plate', CompId='1', Name=f'{pid}-FR47-T-WEB', Source='R-RW1 vertical T 450X12+125X15 F.B(T) at FR.47')
        _contour(pl, 'SimpleContour', wp)
        gid, n = 3, 0
        ev = 'R-RW1 STIFF. 150X90X12 U.A; position from the elevation (800 pitch) - B mark detail 1A2-1 CONFIRM'
        from . import connect
        for bx in beam_x:
            _cn = connect.wall_x(y, float(bx), top) if connect.TABLE['beams'] else None
            ztop = _cn[1] if _cn else top
            # R-G1: the vertical stands on the horizontal B member (Z 37500, web 12, flange +Z at 8525 / -Z at 18665) without overlapping it
            zb = 37500.0 + (90.0 if wsign > 0 else 0.0)
            n += 1; _stiff(pp, gid, pid, n, (float(bx), zb), (float(bx), ztop), wsign, ev + f' - ends on the deck beam underside (Z {ztop:.0f}); the deck bracket stands at this intersection', y); gid += 1
        # (the 4 short horizontal ticks at FR.47-4000 are horizontal wall bars of the X-plane wall: old rule 'do not add horizontal short bars' - not built)
        # the bracket at the intersection of the wall stiffener and the deck beam (B25 = 250X11) is written by the deck builder with the beam end (R-B1)
        n += 1; _stiff(pp, gid, pid, n, (X0, 37500.0), (X1, 37500.0), wsign, ev, y); gid += 1
        # R-BT1 (owner 2026-10-23, '2B2-1' PLAN): the bottom row (Z 37500) of each wall ends on the FR.47-4000 / FR.47 member at both ends with a
        # B25 (250X11) bracket lying in the WEB plane of the row (horizontal, Z 37500) - gusset between the free edges of the two webs.
        # 2B2-1 prints B25 at the 18665 corners; the 8525 elevation (NO.10) prints the same B marks at both ends of its bottom member.
        dy = -wsign                                    # room side of the wall (web side)
        bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid)); gid += 1
        mt = ET.SubElement(bg, 'Material', Grade='A'); ET.SubElement(mt, 'Thickness').text = '11'
        for k, (xc, dx) in enumerate(((X0 + 150.0, 1.0), (X1, -1.0)), 1):
            br = ET.SubElement(bg, 'Bracket', CompId=str(k), Name=f'{pid}-BOTTOM-B{k}', Source="R-BT1 B25 250X11 at the end of the bottom row, '2B2-1' PLAN / elevation B marks")
            cs = ET.SubElement(br, 'CoordSys')
            _xyz(cs, 'Origin', xc, y + dy * 150.0, 37500.0)
            _xyz(cs, 'Waxis', 0, 0, dx * dy); _xyz(cs, 'Uaxis', dx, 0, 0)
            _contour(br, 'SimpleContour', [(0, 0), (250, 0), (0, 250)])
            ET.SubElement(br, 'End1')
            e2 = ET.SubElement(br, 'End2')
            ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=pid, CompType='Stiffener', CompId='1')
        if oc == 18665:
            # R-RW5: the long dashed (inboard) horizontal member of the 18665 elevation, from the 2nd vertical stiffener to ~FR.47; Z read from pixels
            # (7.05 mm/px between the 37160 and 41460 edges) = 40330 +-30 - CONFIRM with the owner
            # R-G1: S6 is interrupted by the vertical stiffeners (web at X, flange to X+90)
            xs = [float(b) for b in beam_x[1:]]
            segs, xa = [], xs[0] + 90.0
            for xv in xs[1:]:
                segs.append((xa, xv)); xa = xv + 90.0
            segs.append((xa, 99900.0))
            for sa, sb in segs:
                n += 1; _stiff(pp, gid, pid, n, (sa, 40330.0), (sb, 40330.0), wsign,
                               'R-RW5 dashed horizontal member of the 18665 elevation; Z from pixel scale (no printed dimension) - CONFIRM', y); gid += 1
        # FR.47 T flange: plate in the plane X = 100450, 125 wide centred on the wall, 15 thick
        fp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-FR47-T-FLANGE', Tightness='NonTight')
        cs = ET.SubElement(fp, 'CoordSys')
        _xyz(cs, 'Origin', XT, y, 0); _xyz(cs, 'Waxis', 1, 0, 0); _xyz(cs, 'Uaxis', 0, 1, 0)      # R-SD3: surface at the web edge
        pg3 = ET.SubElement(fp, 'PlateGroup', GroupId='1')
        m = ET.SubElement(pg3, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '15'
        pl = ET.SubElement(pg3, 'Plate', CompId='1', Name=f'{pid}-FR47-T-FLANGE-P1', Source='R-RW1 flange 125X15 of the vertical T')
        _contour(pl, 'SimpleContour', [(-62.5, ZB), (62.5, ZB), (62.5, ZCRT), (-62.5, ZCRT)])
    _compressor(ship, blk)
    ET.indent(ship)
    ET.ElementTree(ship).write(out_xml, xml_declaration=True, encoding='utf-8')


def _compressor(ship, blk):
    """R-RW2: compressor-room walls FR.47..FR.55 (frame spacing 3545) at the same OFF C.L planes, Z 37160..COMP ROOM TOP (42961).
    8525 (NO.10 ELEV): plate 11.0, top girder 450X12+150X20 F.B(T) under COMP ROOM TOP, vertical T 450X12+125X15 at FR.55.
    18665 (18665 OFF C.L ELEV): plate 11.0 + horizontal stiffeners 150X90X12 U.A (dashed = inboard side) at the printed dimension chain
    700 / 762 / 765 / 800 / 800 / 800 below COMP ROOM TOP."""
    XA, XB = 100000.0, 100000.0 + 8 * 3545.0           # FR.47 .. FR.55
    chain, z = [], ZCRT
    for d in (700, 762, 765, 800, 800, 800):
        z -= d
        chain.append(z)
    for oc, wsign in ((8525, 1.0), (18665, -1.0)):
        y = -float(oc)
        pid = f'PDF-COMPROOM-OFFCL{oc}'
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=pid, Tightness='NonTight')
        cs = ET.SubElement(pp, 'CoordSys')
        _xyz(cs, 'Origin', 0, y, 0); _xyz(cs, 'Waxis', 0, -1, 0); _xyz(cs, 'Uaxis', 1, 0, 0)
        poly = [(XT, ZB), (XB, ZB), (XB, ZCRT), (XT, ZCRT)]
        bd = ET.SubElement(pp, 'Boundary'); _contour(bd, 'SimpleContour', poly)
        pg = ET.SubElement(pp, 'PlateGroup', GroupId='1')
        m = ET.SubElement(pg, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '11'
        pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{pid}-P1', Source='R-RW2 PLATE THK. 11.0 of the elevation, FR.47..FR.55')
        _contour(pl, 'SimpleContour', poly)
        gid = 2
        if oc == 8525:
            XT55 = XB - 450.0
            pg2 = ET.SubElement(pp, 'PlateGroup', GroupId=str(gid)); gid += 1
            m = ET.SubElement(pg2, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '12'
            _contour(ET.SubElement(pg2, 'Plate', CompId='1', Name=f'{pid}-FR55-T-WEB', Source='R-RW2 vertical T 450X12+125X15 at FR.55'),
                     'SimpleContour', [(XT55, ZB), (XB, ZB), (XB, ZCRT), (XT55, ZCRT)])
            _contour(ET.SubElement(pg2, 'Plate', CompId='2', Name=f'{pid}-TOP-GIRDER-WEB', Source='R-RW2 top girder 450X12+150X20 F.B(T)'),
                     'SimpleContour', [(XT + 8.0, ZCRT - 450.0), (XT55, ZCRT - 450.0), (XT55, ZCRT), (XT + 8.0, ZCRT)])
            fp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-FR55-T-FLANGE', Tightness='NonTight')
            cs = ET.SubElement(fp, 'CoordSys')
            _xyz(cs, 'Origin', XT55, y, 0); _xyz(cs, 'Waxis', 1, 0, 0); _xyz(cs, 'Uaxis', 0, 1, 0)
            g = ET.SubElement(fp, 'PlateGroup', GroupId='1')
            m = ET.SubElement(g, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '15'
            _contour(ET.SubElement(g, 'Plate', CompId='1', Name=f'{pid}-FR55-T-FLANGE-P1', Source='R-RW2 flange 125X15'),
                     'SimpleContour', [(-62.5, ZB), (62.5, ZB), (62.5, ZCRT), (-62.5, ZCRT)])
            tp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-TOP-GIRDER-FLANGE', Tightness='NonTight')
            cs = ET.SubElement(tp, 'CoordSys')
            _xyz(cs, 'Origin', 0, y, ZCRT - 450.0); _xyz(cs, 'Waxis', 0, 0, 1); _xyz(cs, 'Uaxis', 1, 0, 0)
            g = ET.SubElement(tp, 'PlateGroup', GroupId='1')
            m = ET.SubElement(g, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = '20'
            _contour(ET.SubElement(g, 'Plate', CompId='1', Name=f'{pid}-TOP-GIRDER-FLANGE-P1', Source='R-RW2 flange 150X20'),
                     'SimpleContour', [(XT + 8.0, -75.0), (XT55, -75.0), (XT55, 75.0), (XT + 8.0, 75.0)])
        else:
            n = 0
            for zz in chain:
                n += 1
                _stiff(pp, gid, pid, n, (XT + 8.0, zz), (XB - 450.0, zz), wsign, 'R-RW2 STIFF. 150X90X12 U.A, level from the printed dimension chain below COMP ROOM TOP', y)
                gid += 1


if __name__ == '__main__':
    build(sys.argv[1])
