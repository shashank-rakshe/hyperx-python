"""R-FV1 (owner 2026-10-23): members of the VFD room on the two frame sections FR.47-4000 (X 96000) and FR.47 (X 100000).
Read from 'FR.47-4000 SEC.(S)' and 'FR.47 SEC.(S)' (sheet 4/4); labels first, then printed dimensions, pixels only to place the rows.
 - 5 horizontal stiffeners 150X90X12 U.A (B marks, L symbols at the ends) across the room, Y -8525..-18665, Z 37500 + 800 k (k = 0..4);
   the rows come out at 37501 / 38296 / 39090 / 39885 / 40666 by pixel scale, i.e. the 800 pitch of the 18665 elevation chain.
 - T.B verticals (T-bar) at OFF C.L 11825 and 15175 (labelled 14L / 18L on FR.47): 450X12 web + 125X15 flange ('450X12 + 125X15 F.B(T)' printed beside
   the T.B mark), Z 37160..41460; flange as a separate plate panel (R-DG4b style).
 Side of the members: thin dashed lines = far side of the (S) view = +X (same side as the vertical T at FR.47, X 100000..100450).
NOT modelled: opening 860X1760 XR130 + #1 doublers (FR.47-4000), short B stubs under the deck, members below Z 37160 (void space, slanted bottom)."""
import xml.etree.ElementTree as ET
from .export import _contour, _trace, _xyz, _f, bar_id, BAR_TYPE, _crossection, add_web_flange

SEC = ('L', 150.0, 90.0, 12.0, 12.0)
ROWS = [37500.0 + 800.0 * k for k in range(5)]
YA, YB = -8525.0, -18665.0
TB_Y = (-11825.0, -15175.0)
ZB, ZT = 37160.0, 41460.0
OP = dict(yc=-17370.0, w=860.0, z0=37520.0, h=1760.0, r=130.0)     # 1295 from 18665 (centre), 360 above Z 37160, 860X1760 XR130
RING = dict(y0=OP['yc'] + OP['w'] / 2 + 100.0, y1=OP['yc'] - OP['w'] / 2 - 100.0, z0=OP['z0'] - 100.0, z1=OP['z0'] + OP['h'] + 100.0)   # #1 = 100X11 F.B at 100 from the opening edge
FB1 = ('F', 100.0, 11.0)
BR_LEG, BR_T = 250.0, 11.0      # B mark bracket: B25 (250X11) assumed - the bracket section for these marks is CONFIRM
TB_H, TB_TW, TB_FW, TB_FT = 450.0, 12.0, 125.0, 15.0
# R-VF1 (NO.14 / NO.18 LONGL. ELEV): the T.B ring members at OFF C.L 11825 / 15175: vertical at FR.47-4000 = 400X12 + 150X20 F.B(T), at FR.47 = 450X12 + 125X15 F.B(T)
TB_SEC = {96000.0: (400.0, 12.0, 150.0, 20.0), 100000.0: (450.0, 12.0, 125.0, 15.0)}
B50_LEG, B50_T = 500.0, 15.0           # B50 = 500X15 (bracket table of the drawing)
GIRDER_BOT = ZT - 400.0 - 10.0         # underside of the 400X12 + 150X20 girder under the 41460 deck (face plate 20 thick, centred on Z 41060)


def build(out_xml):
    ship = ET.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine', Source='deckrules VFD room frame members (PDF drawing only)')
    ET.SubElement(ship, 'Material', Grade='A')
    bid, tag, attrs = bar_id(SEC)
    bsx = ET.SubElement(ship, 'BarSection', BarSectionId=bid)
    ET.SubElement(bsx, tag, **attrs)
    bid2, tag2, attrs2 = bar_id(('F', TB_H, TB_TW))
    bsx = ET.SubElement(ship, 'BarSection', BarSectionId=bid2)
    ET.SubElement(bsx, tag2, **attrs2)
    bid3, tag3, attrs3 = bar_id(('F', 400.0, TB_TW))
    if bid3 != bid2:
        bsx = ET.SubElement(ship, 'BarSection', BarSectionId=bid3)
        ET.SubElement(bsx, tag3, **attrs3)
    blk = ET.SubElement(ship, 'Block', ObjId='PDF-VFDROOM-FRAMES')
    for fx, fname in ((96000.0, 'FR47-4000'), (100000.0, 'FR47')):
        pid = f'PDF-VFDROOM-{fname}'
        pp = ET.SubElement(blk, 'PlanePanel', ObjId=pid, Tightness='NonTight')
        cs = ET.SubElement(pp, 'CoordSys')
        _xyz(cs, 'Origin', fx, 0, 0); _xyz(cs, 'Waxis', 1, 0, 0); _xyz(cs, 'Uaxis', 0, 1, 0)
        bd = ET.SubElement(pp, 'Boundary'); _contour(bd, 'SimpleContour', [(YB, ZB), (YA, ZB), (YA, ZT), (YB, ZT)])
        gid = 1
        # horizontal stiffeners: trace toward -U (R-DR), web toward +X (far side of the (S) view)
        for n, z in enumerate(ROWS, 1):
            # R-G1 (two members never overlap): the rows stop at the T.B webs (12 thick) and at the opening of FR.47-4000
            cuts = []      # (web_hi, web_lo, flange_hi, flange_lo): R-CN4 the web ends on the crossing member's WEB plane, the flange on its flange edge / web plane
            ya_, yb_ = (YA - 165.0, YB + 165.0) if z == ROWS[0] else (YA, YB)     # Z 37500: the wall horizontal members (150 wide) occupy Y -8525..-8675 / -18665..-18515
            for y in TB_Y:
                cuts.append((y, y, y, y))
            if fx < 98000.0 and RING['z0'] <= z <= RING['z1']:      # opening: web to O1's web plane / O2's web plane; flange to O1's flange tip (90) / O2's web plane
                cuts.append((RING['y0'], RING['y1'], RING['y0'] + SEC[2], RING['y1']))
            cuts.sort(reverse=True)
            spans, cur = [], (ya_, ya_)
            for wh, wl, fh, fl_ in cuts:
                spans.append((cur[0], wh, cur[1], fh)); cur = (wl, fl_)
            spans.append((cur[0], yb_, cur[1], yb_))
            for k, (ya, yb, fa, fb) in enumerate(spans):
                sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight'); gid += 1
                mat = ET.SubElement(sg, 'Material', Grade='A')
                bs = ET.SubElement(mat, 'BarShape', BarSectionId=bid, BarType=BAR_TYPE[tag])
                ET.SubElement(bs, 'Parameters').text = ' '.join(f'{x:g}' for x in SEC[1:])
                _crossection(bs, tag, attrs)
                st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/H{n}' + 'abcd'[k], Kind='frame stiffener',
                                   Evidence=f'R-FV1 B-marked horizontal stiffener, Z {z:.0f} (800 pitch, pixel rows 37501/38296/39090/39885/40666 agree); web +X (dashed) - CONFIRM')
                _trace(st, (ya, z), (yb, z))
                inc = ET.SubElement(st, 'Inclination')
                for _ in range(2):
                    ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(1.0))
                add_web_flange(st, (fx, ya, z), (fx, yb, z), (1.0, 0.0, 0.0), SEC, fspan=(ya - fa, ya - fb))
                if fx < 98000.0:       # R-FV2: L symbols on the OFF C.L elevations at the 47-4000 line show the flange toward -Z; at FR.47 toward +Z
                    wa = st.find('Flange1/CoordSys/Waxis')
                    if wa is not None:
                        for kk in 'XYZ':
                            v = float(wa.get(kk)); wa.set(kk, '%.10E' % (-v if v else 0.0))
                        wb = st.find('Web')
                        wb.set('MaterialDirection', 'Negative' if wb.get('MaterialDirection') == 'Positive' else 'Positive')
        if fx < 98000.0:
            bidr, tagr, attrr = bar_id(FB1)
            bsx2 = ship.find(f"BarSection[@BarSectionId='{bidr}']")
            if bsx2 is None:
                bsx2 = ET.SubElement(ship, 'BarSection', BarSectionId=bidr); ET.SubElement(bsx2, tagr, **attrr)
                ship.remove(bsx2); ship.insert(2, bsx2)
            def _fb(name, a, b, evid, sec=None, fspan=None):
                nonlocal gid
                if sec is not None:
                    bidx, tagx, attrx = bar_id(sec)
                else:
                    bidx, tagx, attrx = bidr, tagr, attrr
                sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid)); gid += 1
                sg.set('BendType', 'Straight')
                mat = ET.SubElement(sg, 'Material', Grade='A')
                bs = ET.SubElement(mat, 'BarShape', BarSectionId=bidx, BarType=BAR_TYPE[tagx])
                ET.SubElement(bs, 'Parameters').text = (' '.join(f'{x:g}' for x in sec[1:]) if sec else f'{FB1[1]:g} {FB1[2]:g}')
                _crossection(bs, tagx, attrx)
                st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/{name}', Kind='opening member', Evidence=evid)
                _trace(st, a, b)
                inc = ET.SubElement(st, 'Inclination')
                for _ in range(2):
                    ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(1.0))
                add_web_flange(st, (fx, a[0], a[1]), (fx, b[0], b[1]), (1.0, 0.0, 0.0), sec or FB1, fspan=fspan)
            ev1 = 'R-FV3/G4 #1 = 100X11 F.B on the HORIZONTAL lines only (owner), 100 from the edge of the opening 860X1760 XR130'
            ev2 = 'R-G4b common detail 150X90X12 U.A for the vertical members at the opening (no #1 label on them); flange side CONFIRM'
            # drawing: the two dashed vertical lines run from the 37160 line up to the row at Z 39900 (they END ON that row: its flange (-Z) tip is the stop)
            zweb = ROWS[3]                      # web ends on the web of the row at Z 39900
            zfl = ROWS[3] - SEC[2]              # flange ends on that row's flange edge (flange-to-flange)
            _fb('O1', (RING['y0'], ZB), (RING['y0'], zweb), ev2, SEC, fspan=(0.0, zfl - ZB))
            _fb('O2', (RING['y1'], ZB), (RING['y1'], zweb), ev2, SEC, fspan=(0.0, zfl - ZB))
            _fb('O3', (RING['y0'], RING['z0']), (RING['y1'], RING['z0']), ev1)
            _fb('O4', (RING['y0'], RING['z1']), (RING['y1'], RING['z1']), ev1)
        # T.B verticals (R-VF1): web as a stiffener (flat bar), flange as a separate plate panel; section per frame (400X12+150X20 at FR.47-4000, 450X12+125X15 at FR.47)
        tbh, tbw, tbfw, tbft = TB_SEC[fx]
        bidx = bid3 if tbh == 400.0 else bid2
        for n, y in enumerate(TB_Y, 1):
            sg = ET.SubElement(pp, 'StiffenerGroup', GroupId=str(gid), BendType='Straight'); gid += 1
            mat = ET.SubElement(sg, 'Material', Grade='A')
            bs = ET.SubElement(mat, 'BarShape', BarSectionId=bidx, BarType=BAR_TYPE[tag2])
            ET.SubElement(bs, 'Parameters').text = f'{tbh:g} {tbw:g}'
            _crossection(bs, tag2, attrs3 if tbh == 400.0 else attrs2)
            st = ET.SubElement(sg, 'Stiffener', CompId='1', Name=f'{pid}/TB{n}', Kind='frame T-bar',
                               Evidence='R-VF1 T.B at OFF C.L %g: %gX12 + %gX%g F.B(T) (NO.14 / NO.18 LONGL. ELEV); web +X' % (-y, tbh, tbfw, tbft))
            _trace(st, (y, ZB), (y, ZT))
            inc = ET.SubElement(st, 'Inclination')
            for _ in range(2):
                ET.SubElement(inc, 'Vector3d', U=_f(0), V=_f(0), W=_f(1.0))
            add_web_flange(st, (fx, y, ZB), (fx, y, ZT), (1.0, 0.0, 0.0), ('F', tbh, tbw))
            fp = ET.SubElement(blk, 'PlanePanel', ObjId=f'{pid}-TB{n}-FLANGE', Tightness='NonTight')
            cs = ET.SubElement(fp, 'CoordSys')
            _xyz(cs, 'Origin', fx + tbh, 0, 0); _xyz(cs, 'Waxis', 1, 0, 0); _xyz(cs, 'Uaxis', 0, 1, 0)      # the flange surface is the web's top edge, contour carries absolute Y
            pg = ET.SubElement(fp, 'PlateGroup', GroupId='1')
            m = ET.SubElement(pg, 'Material', Grade='A'); ET.SubElement(m, 'Thickness').text = f'{tbft:g}'
            pl = ET.SubElement(pg, 'Plate', CompId='1', Name=f'{pid}-TB{n}-FLANGE-P1', Source='R-VF1 flange %gX%g of the T.B' % (tbfw, tbft))
            yc_ = y          # flange surface centred on the web surface
            _contour(pl, 'SimpleContour', [(yc_ - tbfw / 2, ZB), (yc_ + tbfw / 2, ZB), (yc_ + tbfw / 2, ZT), (yc_ - tbfw / 2, ZT)])
        # R-VF2 B50 (500X15) brackets of the 11825 / 15175 rings (NO.14 / NO.18): at the two TOP inner corners between the vertical T.B and the girder under the 41460 deck,
        # lying in the ring plane (Y = OFF C.L), right angle at the inner corner, legs 500 along the girder and 500 down along the vertical
        bg = ET.SubElement(pp, 'BracketGroup', GroupId=str(gid)); gid += 1
        mt = ET.SubElement(bg, 'Material', Grade='A'); ET.SubElement(mt, 'Thickness').text = f'{B50_T:g}'
        dx = 1.0 if fx < 98000.0 else -1.0
        xv = fx + tbh + tbft if fx < 98000.0 else fx                  # FR.47-4000: from the flange outer face; FR.47: the vertical lies outside the room, corner on the frame line
        for n, y in enumerate(TB_Y, 1):
            br = ET.SubElement(bg, 'Bracket', CompId=str(n), Name=f'{pid}-B50-{n}', Source="R-VF2 B50 500X15 at the top inner corner of the ring at OFF C.L %g (NO.14 / NO.18 LONGL. ELEV)" % -y)
            c2 = ET.SubElement(br, 'CoordSys')
            _xyz(c2, 'Origin', xv, y, GIRDER_BOT)
            _xyz(c2, 'Waxis', 0, dx, 0); _xyz(c2, 'Uaxis', dx, 0, 0)
            _contour(br, 'SimpleContour', [(0, 0), (B50_LEG, 0), (0, B50_LEG)])
            ET.SubElement(br, 'End1')
            e2 = ET.SubElement(br, 'End2')
            ET.SubElement(e2, 'ModelRef', ObjType='PlanePanel', ObjId=pid, CompType='Stiffener', CompId='1')
    ET.indent(ship)
    ET.ElementTree(ship).write(out_xml, xml_declaration=True, encoding='utf-8')



def finalize(xml_path):
    """R-FV2: FR.47-4000 has exactly the 5 B stiffeners; the 3 stock frame stiffeners (opening edges #1 and the corner stub) are removed and the
    opening 860X1760 XR130 is added to the lower frame panel."""
    import math
    from lxml import etree
    t = etree.parse(xml_path)
    removed = 0
    for blk in t.getroot().iter('Block'):
        if blk.get('ObjId') != 'PDF-FR96000':
            continue
        for pp in blk.iter('PlanePanel'):
            for sg in list(pp.findall('StiffenerGroup')):
                sg.getparent().remove(sg); removed += 1
            if pp.get('ObjId', '').endswith('Z37160Z39930S1'):
                ids = [int(g.get('GroupId')) for g in pp if g.get('GroupId') and g.get('GroupId').isdigit()]
                hg = etree.Element('HoleGroup', GroupId=str(max(ids) + 1))
                h = etree.SubElement(hg, 'Hole', CompId='1', Rule='radiused corners', Evidence='R-FV2 opening 860X1760 XR130 (1295 from 18665 OFF C.L, 360 above Z 37160) - position CONFIRM')
                c = etree.SubElement(h, 'Contour')
                y0, y1 = OP['yc'] + OP['w'] / 2, OP['yc'] - OP['w'] / 2      # U = Y (negative)
                z0, z1 = OP['z0'], OP['z0'] + OP['h']
                r = OP['r']
                pts = []
                for (cy, cz, a0) in ((y1 + r, z0 + r, 180), (y0 - r, z0 + r, 270), (y0 - r, z1 - r, 0), (y1 + r, z1 - r, 90)):
                    for k in range(7):
                        a = math.radians(a0 + 90.0 * k / 6)
                        pts.append((cy + r * math.cos(a), cz + r * math.sin(a)))
                sp = etree.SubElement(c, 'StartPoint2d', U='%.10E' % pts[0][0], V='%.10E' % pts[0][1])
                for u, v in pts[1:] + [pts[0]]:
                    sg_ = etree.SubElement(c, 'Segment2d')
                    etree.SubElement(sg_, 'Amplitude2d', U='0.0000000000E+00', V='0.0000000000E+00')
                    etree.SubElement(sg_, 'Node2d', U='%.10E' % u, V='%.10E' % v)
                first = pp.find('StiffenerGroup')
                if first is not None:
                    first.addprevious(hg)
                else:
                    pp.append(hg)
    # R-PX1 (owner 2026-10-24): FR.47 frame stiffeners are NOT given in the drawing; the stock builder had made 3 from the title default
    # ('title default (partial)') which then collided with the 15175 / 11825 ring brackets -> members without a drawing basis are dropped, a drawn bracket never moves
    for blk in t.getroot().iter('Block'):
        if blk.get('ObjId') != 'PDF-FR100000':
            continue
        for pp in blk.iter('PlanePanel'):
            for sg in list(pp.findall('StiffenerGroup')):
                if any('title default' in (st.get('Evidence') or '') for st in sg.findall('Stiffener')):
                    sg.getparent().remove(sg); removed += 1
            for bg in list(pp.findall('BracketGroup')):
                if all('frame stiffener' in (b.get('Source') or '') for b in bg.findall('Bracket')):
                    bg.getparent().remove(bg)
    t.write(xml_path, xml_declaration=True, encoding='UTF-8')
    return removed
