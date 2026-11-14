"""
2D drawings from plain words, with ezdxf: the model turns the user's description into the `parts` below, this module draws
a properly layered DXF (and a PNG preview) and checks drafting quality.

Parts (all lengths in mm; x, y measured from the lower-left corner of the part):
  plate    {length, width, thickness, corner_radius, holes: [{x, y, d}], hole_grid: {x0, y0, nx, ny, dx, dy, d},
            slots: [{x, y, length, width}], label}
  panel    {length, width, thickness, stiffeners: {spacing, profile, direction: "x"|"y", first}, frames: {spacing, profile, first},
            label}                      stiffened ship panel in plan: plate outline, stiffener lines at the spacing, frames
  flange   {od, id, thickness, bolt_circle, n_bolts, bolt_d, label}
  shapes   {lines: [{x1,y1,x2,y2}], circles: [{x,y,d}], rects: [{x,y,w,h}], texts: [{x,y,text}], polylines: [{points, closed}]}
Drawing: title, sheet (A4 ... A0), scale (e.g. 20 for 1:20; automatic if omitted), notes [text], dims (true: overall sizes, hole
diameters and positions, spacing chains "n @ s = total").
Layers: OUTLINE, HOLES, STIFFENER, FRAME, CENTER, HIDDEN, DIM, TEXT, TITLE. Text and arrows are 2.5 mm at plot scale.
"""
import math, os, re, time

LAYERS = {'OUTLINE': (7, 'Continuous', 50), 'HOLES': (7, 'Continuous', 35), 'STIFFENER': (3, 'Continuous', 35),
          'FRAME': (5, 'DASHDOT', 25), 'CENTER': (1, 'CENTER', 18), 'HIDDEN': (8, 'DASHED', 25), 'DIM': (2, 'Continuous', 18),
          'TEXT': (7, 'Continuous', 18), 'TITLE': (7, 'Continuous', 35)}
SHEETS = {'A4': (297, 210), 'A3': (420, 297), 'A2': (594, 420), 'A1': (841, 594), 'A0': (1189, 841)}
SCALES = [1, 2, 5, 10, 20, 25, 50, 75, 100, 150, 200, 250, 500, 1000]


def _new(scale):
    import ezdxf
    doc = ezdxf.new('R2018', setup=True)
    doc.header['$INSUNITS'] = 4                                 # millimetres
    doc.header['$MEASUREMENT'] = 1
    for n, (col, lt, lw) in LAYERS.items():
        doc.layers.add(n, color=col, linetype=lt, lineweight=lw)
    h = 2.5 * scale
    ds = doc.dimstyles.new('SB', dxfattribs={'dimtxt': h, 'dimasz': h, 'dimexe': 0.5 * h, 'dimexo': 0.5 * h, 'dimgap': 0.4 * h,
                                             'dimdec': 0 if scale >= 10 else 1, 'dimclrd': 2, 'dimclre': 2, 'dimclrt': 2})
    return doc


def _fmt(v):
    return f'{v:g}' if abs(v - round(v)) > 1e-9 else f'{int(round(v))}'


class Sheet:
    def __init__(self, doc, scale):
        self.doc, self.msp, self.k = doc, doc.modelspace(), scale
        self.h = 2.5 * scale
        self.counts = {}
        self.dims = 0

    def _c(self, layer):
        self.counts[layer] = self.counts.get(layer, 0) + 1

    def line(self, a, b, layer='OUTLINE'):
        self.msp.add_line(a, b, dxfattribs={'layer': layer})
        self._c(layer)

    def poly(self, pts, closed=True, layer='OUTLINE'):
        self.msp.add_lwpolyline(pts, close=closed, dxfattribs={'layer': layer})
        self._c(layer)

    def circle(self, c, d, layer='HOLES'):
        self.msp.add_circle(c, d / 2, dxfattribs={'layer': layer})
        self._c(layer)

    def text(self, p, s, h=None, layer='TEXT', rot=0, align='MIDDLE_CENTER'):
        t = self.msp.add_text(s, height=h or self.h, rotation=rot, dxfattribs={'layer': layer})
        t.set_placement(p, align=getattr(__import__('ezdxf').enums.TextEntityAlignment, align))
        self._c(layer)

    def cross(self, c, d):
        r = d / 2 + 2 * self.h
        self.line((c[0] - r, c[1]), (c[0] + r, c[1]), 'CENTER')
        self.line((c[0], c[1] - r), (c[0], c[1] + r), 'CENTER')

    def dim(self, p1, p2, off, text=None, angle=None):
        """linear dimension; off = distance of the dimension line from p1-p2 (side by sign)"""
        horiz = abs(p2[1] - p1[1]) < abs(p2[0] - p1[0]) if angle is None else angle == 0
        base = (p1[0], p1[1] + off) if horiz else (p1[0] + off, p1[1])
        d = self.msp.add_linear_dim(base=base, p1=p1, p2=p2, angle=0 if horiz else 90, dimstyle='SB', text=text or '<>',
                                    dxfattribs={'layer': 'DIM'})
        d.render()
        self.dims += 1

    def diam(self, c, d, ang=45, label=None):
        a = math.radians(ang)
        p = (c[0] + d / 2 * math.cos(a), c[1] + d / 2 * math.sin(a))
        dm = self.msp.add_diameter_dim(center=c, radius=d / 2, angle=ang, dimstyle='SB', text=label or '<>', dxfattribs={'layer': 'DIM'})
        dm.render()
        self.dims += 1


# ====================================================================== parts
def _outline(sh, x0, y0, L, W, r=0.0):
    if r and r < min(L, W) / 2:
        b = math.tan(math.radians(90) / 4)
        pts = [(x0 + r, y0, 0), (x0 + L - r, y0, b), (x0 + L, y0 + r, 0), (x0 + L, y0 + W - r, b), (x0 + L - r, y0 + W, 0),
               (x0 + r, y0 + W, b), (x0, y0 + W - r, 0), (x0, y0 + r, b)]
        sh.msp.add_lwpolyline(pts, format='xyb', close=True, dxfattribs={'layer': 'OUTLINE'})
        sh._c('OUTLINE')
    else:
        sh.poly([(x0, y0), (x0 + L, y0), (x0 + L, y0 + W), (x0, y0 + W)], True, 'OUTLINE')


def part_plate(sh, p, ox, oy, dims):
    L, W = float(p['length']), float(p['width'])
    _outline(sh, ox, oy, L, W, float(p.get('corner_radius') or 0))
    holes = [dict(h) for h in (p.get('holes') or [])]
    g = p.get('hole_grid')
    if g:
        for i in range(int(g['nx'])):
            for j in range(int(g['ny'])):
                holes.append({'x': g['x0'] + i * g['dx'], 'y': g['y0'] + j * g['dy'], 'd': g['d']})
    for h in holes:
        c = (ox + float(h['x']), oy + float(h['y']))
        sh.circle(c, float(h['d']))
        sh.cross(c, float(h['d']))
    for s in (p.get('slots') or []):
        sl, sw = float(s['length']), float(s['width'])
        cx, cy = ox + float(s['x']), oy + float(s['y'])
        r = sw / 2
        sh.msp.add_lwpolyline([(cx - sl / 2 + r, cy - r, 0), (cx + sl / 2 - r, cy - r, 1), (cx + sl / 2 - r, cy + r, 0),
                               (cx - sl / 2 + r, cy + r, 1)], format='xyb', close=True, dxfattribs={'layer': 'HOLES'})
        sh._c('HOLES')
    lab = p.get('label') or (f"PL {_fmt(p['thickness'])}" if p.get('thickness') else None)
    if lab:
        sh.text((ox + L / 2, oy + W + 1.6 * sh.h), lab + (f"  {_fmt(L)} x {_fmt(W)}" if p.get('thickness') else ''), layer='TEXT')
    if dims:
        sh.dim((ox, oy), (ox + L, oy), -4 * sh.h)
        sh.dim((ox, oy), (ox, oy + W), -4 * sh.h)
        seen = set()
        for h in holes:
            if h['d'] not in seen and len(seen) < 3:
                seen.add(h['d'])
                sh.diam((ox + h['x'], oy + h['y']), float(h['d']), 40 + 30 * len(seen))
        if holes:
            xs = sorted({round(h['x'], 3) for h in holes})
            ys = sorted({round(h['y'], 3) for h in holes})
            if len(xs) <= 8:
                prev = 0.0
                for x in xs:
                    if x - prev > 1e-6:
                        sh.dim((ox + prev, oy), (ox + x, oy), -8 * sh.h)
                    prev = x
            if len(ys) <= 8:
                prev = 0.0
                for y in ys:
                    if y - prev > 1e-6:
                        sh.dim((ox, oy + prev), (ox, oy + y), -8 * sh.h)
                    prev = y
    return L, W


def part_panel(sh, p, ox, oy, dims):
    L, W = float(p['length']), float(p['width'])
    _outline(sh, ox, oy, L, W)
    st, fr = p.get('stiffeners') or {}, p.get('frames') or {}
    along_x = str(st.get('direction', 'x')).lower() != 'y'
    if st.get('spacing'):
        s = float(st['spacing'])
        span = W if along_x else L
        first = float(st.get('first', s))
        pos = []
        v = first
        while v < span - 1e-6:
            pos.append(v)
            v += s
        for v in pos:
            a, b = ((ox, oy + v), (ox + L, oy + v)) if along_x else ((ox + v, oy), (ox + v, oy + W))
            sh.line(a, b, 'STIFFENER')
        lab = st.get('profile')
        if lab and pos:
            v = pos[len(pos) // 2]
            pt = (ox + L * 0.5, oy + v + 1.5 * sh.h) if along_x else (ox + v + 1.5 * sh.h, oy + W * 0.5)
            sh.text(pt, str(lab), layer='TEXT', rot=0 if along_x else 90)
        if dims and pos:
            full = (len(pos) + 1) if abs(pos[-1] + s - span) < 1e-6 else None
            pts = [0.0] + pos + [span]
            for a, b in zip(pts, pts[1:]):
                if along_x:
                    sh.dim((ox, oy + a), (ox, oy + b), -5 * sh.h)
                else:
                    sh.dim((ox + a, oy), (ox + b, oy), -5 * sh.h)
            txt = f"{len(pos) + 1} @ {_fmt(s)} = {_fmt(span)}" if full else f"{len(pos)} stiffeners at {_fmt(s)}"
            if along_x:
                sh.text((ox - 9 * sh.h, oy + span / 2), txt, layer='TEXT', rot=90)
            else:
                sh.text((ox + span / 2, oy - 9 * sh.h), txt, layer='TEXT')
    if fr.get('spacing'):
        s = float(fr['spacing'])
        span = L if along_x else W
        first = float(fr.get('first', s))
        v = first
        pos = []
        while v < span - 1e-6:
            pos.append(v)
            v += s
        for k, v in enumerate(pos, 1):
            a, b = ((ox + v, oy), (ox + v, oy + W)) if along_x else ((ox, oy + v), (ox + L, oy + v))
            sh.line(a, b, 'FRAME')
            sh.text((ox + v, oy - 1.6 * sh.h) if along_x else (ox - 2.2 * sh.h, oy + v), f"FR{k}", layer='TEXT')
        if dims and pos:
            pts = [0.0] + pos + [span]
            for a, b in zip(pts, pts[1:]):
                if along_x:
                    sh.dim((ox + a, oy), (ox + b, oy), -6 * sh.h)
                else:
                    sh.dim((ox, oy + a), (ox, oy + b), -6 * sh.h)
    if dims:
        sh.dim((ox, oy + W), (ox + L, oy + W), 4 * sh.h)
        sh.dim((ox + L, oy), (ox + L, oy + W), 4 * sh.h)
    lab = p.get('label') or (f"PL {_fmt(p['thickness'])}" if p.get('thickness') else None)
    if lab:
        sh.text((ox + L / 2, oy + W + 7 * sh.h), lab)
    return L, W


def part_flange(sh, p, ox, oy, dims):
    od, idia = float(p['od']), float(p.get('id') or 0)
    c = (ox + od / 2, oy + od / 2)
    sh.circle(c, od, 'OUTLINE')
    if idia:
        sh.circle(c, idia, 'OUTLINE')
    sh.cross(c, od)
    if p.get('bolt_circle') and p.get('n_bolts') and p.get('bolt_d'):
        R, n, bd = float(p['bolt_circle']) / 2, int(p['n_bolts']), float(p['bolt_d'])
        sh.circle(c, 2 * R, 'CENTER')
        for k in range(n):
            a = 2 * math.pi * k / n + math.pi / 2
            b = (c[0] + R * math.cos(a), c[1] + R * math.sin(a))
            sh.circle(b, bd)
            sh.cross(b, bd)
        if dims:
            sh.diam((c[0] + R * math.cos(math.pi / 2 + 2 * math.pi / n), c[1] + R * math.sin(math.pi / 2 + 2 * math.pi / n)), bd, 30,
                    f"{n} x <> ")
    if dims:
        sh.diam(c, od, 225)
        if idia:
            sh.diam(c, idia, 315)
    lab = p.get('label') or (f"FLANGE t={_fmt(p['thickness'])}" if p.get('thickness') else None)
    if lab:
        sh.text((c[0], oy + od + 2.5 * sh.h), lab)
    return od, od


def part_shapes(sh, p, ox, oy, dims):
    xs, ys = [0.0], [0.0]
    for l in p.get('lines') or []:
        sh.line((ox + l['x1'], oy + l['y1']), (ox + l['x2'], oy + l['y2']), l.get('layer', 'OUTLINE'))
        xs += [l['x1'], l['x2']]
        ys += [l['y1'], l['y2']]
    for c in p.get('circles') or []:
        sh.circle((ox + c['x'], oy + c['y']), float(c['d']), c.get('layer', 'HOLES'))
        xs += [c['x'] + c['d'] / 2]
        ys += [c['y'] + c['d'] / 2]
    for r in p.get('rects') or []:
        sh.poly([(ox + r['x'], oy + r['y']), (ox + r['x'] + r['w'], oy + r['y']), (ox + r['x'] + r['w'], oy + r['y'] + r['h']),
                 (ox + r['x'], oy + r['y'] + r['h'])], True, r.get('layer', 'OUTLINE'))
        xs += [r['x'] + r['w']]
        ys += [r['y'] + r['h']]
    for q in p.get('polylines') or []:
        sh.poly([(ox + a, oy + b) for a, b in q['points']], bool(q.get('closed', False)), q.get('layer', 'OUTLINE'))
        xs += [a for a, _ in q['points']]
        ys += [b for _, b in q['points']]
    for t in p.get('texts') or []:
        sh.text((ox + t['x'], oy + t['y']), str(t['text']), t.get('height'))
    return max(xs) - min(xs), max(ys) - min(ys)


PARTS = {'plate': part_plate, 'panel': part_panel, 'flange': part_flange, 'shapes': part_shapes}


def _extent(p, kind):
    if kind == 'flange':
        return float(p['od']), float(p['od'])
    if kind == 'shapes':
        xs, ys = [0.0], [0.0]
        for l in p.get('lines') or []:
            xs += [l['x1'], l['x2']]
            ys += [l['y1'], l['y2']]
        for c in p.get('circles') or []:
            xs.append(c['x'] + c['d'] / 2)
            ys.append(c['y'] + c['d'] / 2)
        for r in p.get('rects') or []:
            xs.append(r['x'] + r['w'])
            ys.append(r['y'] + r['h'])
        for q in p.get('polylines') or []:
            xs += [a for a, _ in q['points']]
            ys += [b for _, b in q['points']]
        return max(xs), max(ys)
    return float(p['length']), float(p['width'])


def _need(p, kind):
    req = {'plate': ('length', 'width'), 'panel': ('length', 'width'), 'flange': ('od',)}.get(kind, ())
    miss = [k for k in req if not p.get(k)]
    if miss:
        raise ValueError(f"{kind}: missing {', '.join(miss)} - ask the user for it")
    if kind == 'plate':
        L, W = float(p['length']), float(p['width'])
        for h in list(p.get('holes') or []):
            if not (0 <= h['x'] <= L and 0 <= h['y'] <= W):
                raise ValueError(f"a hole at ({h['x']:g}, {h['y']:g}) lies outside the {L:g} x {W:g} plate")
            if h['d'] >= min(L, W):
                raise ValueError(f"a hole of diameter {h['d']:g} does not fit in the {L:g} x {W:g} plate")
    if kind == 'flange' and p.get('id') and float(p['id']) >= float(p['od']):
        raise ValueError('flange: the bore (id) must be smaller than the outside diameter (od)')


def draw(parts, out, title=None, sheet=None, scale=None, notes=None, dims=True, png=True, drawn_by='ShipBrain'):
    """parts: [{"type": "plate"|"panel"|"flange"|"shapes", ...}] -> DXF at `out` (+ out.png); returns a report"""
    if not parts:
        raise ValueError('nothing to draw: give at least one part')
    kinds = []
    for p in parts:
        k = str(p.get('type', '')).lower()
        if k not in PARTS:
            raise ValueError(f"unknown part type {p.get('type')}; known: {', '.join(PARTS)}")
        _need(p, k)
        kinds.append(k)
    sizes = [_extent(p, k) for p, k in zip(parts, kinds)]
    total_w = sum(w for w, _ in sizes)
    total_h = max(h for _, h in sizes)
    shw, shh = SHEETS.get(str(sheet).upper(), SHEETS['A3'])
    if scale:
        k = float(scale)
    else:                                   # the smallest standard scale at which parts + dimension lines fit the sheet
        usable_w = shw - 30
        usable_h = shh - 20 - (40 if sheet else 0)
        k = next((s for s in SCALES if total_w / s + 55 * len(parts) <= usable_w and total_h / s + 55 <= usable_h), SCALES[-1])
    doc = _new(k)
    sh = Sheet(doc, k)
    gap = 14 * sh.h + 0.0
    x = 0.0
    for p, kd, (w, h) in zip(parts, kinds, sizes):
        PARTS[kd](sh, p, x, 0.0, bool(dims))
        x += w + max(gap, 0.12 * w)
    # sheet border + title block (model space, in mm at plot scale)
    if sheet:
        bw, bh = shw * k, shh * k
        m = 10 * k
        tbh_ = 36 * k
        cx, cy = (x - max(gap, 0.12 * sizes[-1][0])) / 2, total_h / 2
        x0 = cx - bw / 2                                           # the drawing sits in the free area above the title block
        y0 = cy - (m + tbh_ + (bh - 2 * m - tbh_) / 2)
        sh.poly([(x0, y0), (x0 + bw, y0), (x0 + bw, y0 + bh), (x0, y0 + bh)], True, 'TITLE')
        sh.poly([(x0 + m, y0 + m), (x0 + bw - m, y0 + m), (x0 + bw - m, y0 + bh - m), (x0 + m, y0 + bh - m)], True, 'TITLE')
        tbw, tbh = 180 * k, 36 * k
        tx, ty = x0 + bw - m - tbw, y0 + m
        sh.poly([(tx, ty), (tx + tbw, ty), (tx + tbw, ty + tbh), (tx, ty + tbh)], True, 'TITLE')
        sh.line((tx, ty + tbh / 2), (tx + tbw, ty + tbh / 2), 'TITLE')
        sh.line((tx + tbw * 0.6, ty), (tx + tbw * 0.6, ty + tbh / 2), 'TITLE')
        sh.text((tx + 4 * k, ty + tbh * 0.75), title or 'DRAWING', 5 * k, 'TITLE', align='MIDDLE_LEFT')
        sh.text((tx + 4 * k, ty + tbh * 0.25), f"Scale 1:{_fmt(k)}   Units mm   {time.strftime('%Y-%m-%d')}", sh.h, 'TITLE', align='MIDDLE_LEFT')
        sh.text((tx + tbw * 0.6 + 4 * k, ty + tbh * 0.25), f"Drawn: {drawn_by}", sh.h, 'TITLE', align='MIDDLE_LEFT')
    elif title:
        sh.text((0, total_h + 10 * sh.h), title, 4 * sh.h, 'TITLE', align='MIDDLE_LEFT')
    for i, n in enumerate(notes or []):
        sh.text((0, -14 * sh.h - i * 2.2 * sh.h), str(n), layer='TEXT', align='MIDDLE_LEFT')
    doc.saveas(out)
    rep = {'file': out, 'scale': f'1:{_fmt(k)}', 'sheet': str(sheet).upper() if sheet else None, 'parts': kinds,
           'entities_by_layer': dict(sorted(sh.counts.items())), 'dimensions': sh.dims, 'text_height_mm': round(sh.h, 2)}
    if png:
        rep['png'] = _preview(doc, os.path.splitext(out)[0] + '.png')
    rep['plain_english'] = (
        f"Drew {', '.join(kinds)} to a DXF ({os.path.basename(out)}) at scale 1:{_fmt(k)}"
        + (f" on a {str(sheet).upper()} sheet with border and title block" if sheet else '') +
        f": {sum(sh.counts.values())} entities on layers {', '.join(sh.counts)}"
        + (f", {sh.dims} dimensions" if sh.dims else ', no dimensions') +
        f". Text and arrows are {sh.h:g} mm in the model, i.e. 2.5 mm on paper at 1:{_fmt(k)}. Open it in LibreCAD, QCAD or AutoCAD.")
    return rep


def _preview(doc, png):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from ezdxf.addons.drawing import RenderContext, Frontend
    from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
    from ezdxf.addons.drawing.config import Configuration, BackgroundPolicy, ColorPolicy
    fig = plt.figure(figsize=(11, 7.5), dpi=130)
    ax = fig.add_axes([0.01, 0.01, 0.98, 0.98])
    ax.set_facecolor('white')
    cfg = Configuration(background_policy=BackgroundPolicy.WHITE, color_policy=ColorPolicy.BLACK)
    Frontend(RenderContext(doc), MatplotlibBackend(ax), config=cfg).draw_layout(doc.modelspace(), finalize=True)
    fig.savefig(png, facecolor='white')
    plt.close(fig)
    return png


# ====================================================================== drafting check
def check(path, tol=None):
    """drafting-quality check of a DXF: units, layers, linetypes, zero-length / duplicate entities, gaps in outlines, 3D leftovers,
    dimension texts that were typed over the measured value, stray entities far from the drawing"""
    import ezdxf
    from ezdxf import recover
    try:
        doc, auditor = recover.readfile(path)
    except Exception as e:
        raise ValueError(f'cannot read {os.path.basename(path)} as DXF: {e}')
    msp = doc.modelspace()
    ents = list(msp)
    issues = []

    def add(level, what, n=1, ex=None):
        issues.append({'level': level, 'what': what, 'count': n, **({'example': ex} if ex else {})})
    if auditor.has_errors:
        add('error', 'the DXF structure has errors (ezdxf audit)', len(auditor.errors), str(auditor.errors[0].message)[:100] if auditor.errors else None)
    if not doc.header.get('$INSUNITS', 0):
        add('warn', 'no drawing units set ($INSUNITS): programs may read it in the wrong unit')
    layers = {}
    for e in ents:
        layers[e.dxf.layer] = layers.get(e.dxf.layer, 0) + 1
    if len(ents) and set(layers) <= {'0'}:
        add('warn', 'everything is on layer 0: separate outline, dimensions, text and centre lines into layers', len(ents))
    lts = {l.dxf.name.lower() for l in doc.linetypes}
    bad_lt = sorted({e.dxf.linetype for e in ents if e.dxf.hasattr('linetype') and e.dxf.linetype.lower() not in lts | {'bylayer', 'byblock'}})
    if bad_lt:
        add('error', 'entities use linetypes that are not defined: ' + ', '.join(bad_lt), len(bad_lt))
    pts, zero, dup, z3d, small = [], 0, 0, 0, 0
    seen = {}
    centers = []
    ends = []
    for e in ents:
        t = e.dxftype()
        try:
            if t == 'LINE':
                a, b = e.dxf.start, e.dxf.end
                if (a - b).magnitude < 1e-9:
                    zero += 1
                key = (t, e.dxf.layer) + tuple(sorted([tuple(round(c, 4) for c in a), tuple(round(c, 4) for c in b)]))
                if key in seen:
                    dup += 1
                seen[key] = 1
                z3d += int(abs(a.z) > 1e-9 or abs(b.z) > 1e-9)
                ends += [(a.x, a.y), (b.x, b.y)]
                centers.append(((a.x + b.x) / 2, (a.y + b.y) / 2))
            elif t == 'LWPOLYLINE':
                p = [(q[0], q[1]) for q in e.get_points()]
                if len(p) >= 2:
                    ends += ([p[0], p[-1]] if not e.closed else [])
                    centers.append((sum(q[0] for q in p) / len(p), sum(q[1] for q in p) / len(p)))
                    if e.closed is False and len(p) > 2 and math.dist(p[0], p[-1]) < 1e-6:
                        add('warn', 'a polyline ends where it starts but is not marked closed', 1, e.dxf.handle)
            elif t in ('CIRCLE', 'ARC'):
                c = e.dxf.center
                z3d += int(abs(c.z) > 1e-9)
                centers.append((c.x, c.y))
                if e.dxf.radius <= 0:
                    zero += 1
                key = (t, e.dxf.layer, round(c.x, 4), round(c.y, 4), round(e.dxf.radius, 4))
                if key in seen:
                    dup += 1
                seen[key] = 1
            elif t in ('TEXT', 'MTEXT'):
                h = e.dxf.height if t == 'TEXT' else e.dxf.char_height
                if not h or h <= 0:
                    add('warn', 'text with zero height', 1, e.dxf.handle)
                p = e.dxf.insert
                centers.append((p.x, p.y))
        except Exception:
            continue
    if zero:
        add('warn', 'zero-length lines or zero-radius circles', zero)
    if dup:
        add('warn', 'duplicate entities on top of each other (they plot twice and confuse quantity take-offs)', dup)
    if z3d:
        add('warn', 'entities with a Z coordinate in a 2D drawing', z3d)
    # the size of the MAIN drawing: entity positions further than 12 median deviations from the median are strays
    if centers:
        def keep_axis(v):
            sv = sorted(v)
            med = sv[len(sv) // 2]
            mad = sorted(abs(a - med) for a in v)[len(v) // 2]
            return med, (12 * mad if mad > 0 else float('inf'))
        (mx, lx), (my, ly) = keep_axis([c[0] for c in centers]), keep_axis([c[1] for c in centers])
        main = [c for c in centers if abs(c[0] - mx) <= lx and abs(c[1] - my) <= ly] or centers
        far = [c for c in centers if c not in main]
        ext = max(max(c[0] for c in main) - min(c[0] for c in main), max(c[1] for c in main) - min(c[1] for c in main), 1e-9)
        med = (mx, my)
        if far and len(centers) > 8:
            add('warn', f'{len(far)} entity(ies) far away from the main drawing (about {math.dist(far[0], med):.0f} units): stray objects?', len(far))
        tol = tol or ext * 0.01                                       # line ends closer than 1 % of the drawing but not touching
        grid = {}
        for q in ends:
            grid.setdefault((round(q[0] / tol), round(q[1] / tol)), []).append(q)
        gaps = 0
        for q in ends:
            key = (round(q[0] / tol), round(q[1] / tol))
            cand = [r for dx in (-1, 0, 1) for dy in (-1, 0, 1) for r in grid.get((key[0] + dx, key[1] + dy), [])]
            if any(math.dist(q, r) < 1e-9 for r in cand if r is not q) and sum(math.dist(q, r) < 1e-9 for r in cand) >= 2:
                continue                                               # this end already meets another exactly
            gaps += any(1e-9 < math.dist(q, r) < tol for r in cand)
        if gaps:
            n = max(1, gaps // 2)
            add('warn', f'{n} place(s) where line ends nearly meet but do not touch (gap smaller than {tol:.3g}): an outline that looks closed may not be', n)
    # dimensions
    dims = [e for e in ents if e.dxftype() == 'DIMENSION']
    mism = []
    for d in dims:
        txt = d.dxf.text
        if txt and '<>' not in txt:
            try:
                m = float(d.get_measurement())
                v = [float(x) for x in re.findall(r'-?\d+(?:\.\d+)?', txt)]
                if v and not any(abs(x - m) <= max(0.5, 0.005 * abs(m)) for x in v):
                    mism.append(f'dimension text "{txt}" but it measures {m:.1f}')
            except Exception:
                pass
    if mism:
        add('error', 'dimension text typed over the measured value does not match the geometry', len(mism), mism[0])
    if len(ents) > 4 and not dims:
        add('info', 'no dimensions in the drawing')
    tx = [e for e in ents if e.dxftype() in ('TEXT', 'MTEXT')]
    hs = sorted({round(e.dxf.height if e.dxftype() == 'TEXT' else e.dxf.char_height, 2) for e in tx if (e.dxf.height if e.dxftype() == 'TEXT' else e.dxf.char_height)})
    errs = sum(i['level'] == 'error' for i in issues)
    warns = sum(i['level'] == 'warn' for i in issues)
    pe = (f"{os.path.basename(path)}: {len(ents)} entities on {len(layers)} layer(s), {len(dims)} dimension(s), "
          + ('no drafting problems found.' if not errs and not warns else f"{errs} error(s) and {warns} warning(s): " +
             '; '.join(f"{i['what']}" + (f" ({i['count']})" if i['count'] > 1 else '') for i in issues if i['level'] != 'info') + '.'))
    return {'entities': len(ents), 'layers': layers, 'dimensions': len(dims), 'text_heights': hs[:8], 'issues': issues,
            'plain_english': pe}
