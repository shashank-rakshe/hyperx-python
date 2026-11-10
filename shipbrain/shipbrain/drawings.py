"""
Drawings: load (PDF page / PNG / JPG / DXF), compare two drawings, compare an FE mesh with a drawing, and turn a
DXF structural plan into 3D plates (+ 1D stiffeners) for the mesher and a STEP model.

Compare two drawings (revision A vs B):
  ink of both is aligned (best shift by FFT phase correlation), then
  red = only in A (removed in B), green = only in B (added), grey = same.  Changed regions are listed with sizes.
FE mesh vs drawing (plan view at a deck height z):
  mesh feature lines at that height (plate joints = where webs/girders meet the deck, free edges, openings) are drawn
  onto the drawing with the given mm window; score = share of mesh line length lying on drawing ink, plus the share of
  drawing ink that has a mesh line nearby; the best shift (+-search) shows a calibration error.
DXF -> 3D (vector drawings): closed polylines on outline layers = plate outline, closed polylines on opening layers =
  holes, lines on web layers = vertical webs of given height, lines on stiffener layers = 1D stiffeners.
Scanned drawings need the vision model of the ship-rules project (or redraw the members as DXF lines).
"""
import math, os
import numpy as np


# ====================================================================== loading
def load_image(path, page=0, dpi=150, size=None):
    """grayscale float image 0..255 (white paper = 255)"""
    low = path.lower()
    if low.endswith('.pdf'):
        import pypdfium2                                  # Apache-2.0 / BSD (PDFium)
        pdf = pypdfium2.PdfDocument(path)
        img = np.asarray(pdf[page].render(scale=dpi / 72, grayscale=True).to_pil().convert('L'), float)
        pdf.close()
    elif low.endswith('.dxf'):
        img = render_dxf(path, size or 2000)[0]
    else:
        from PIL import Image
        img = np.asarray(Image.open(path).convert('L'), float)
    return img


def dxf_segments(path, layers=None):
    """all straight pieces of LINE / LWPOLYLINE / POLYLINE / ARC / CIRCLE (arcs as short lines): [(layer, (x0,y0), (x1,y1))]"""
    import ezdxf
    doc = ezdxf.readfile(path)
    out = []
    for e in doc.modelspace():
        lay = e.dxf.layer
        if layers and lay not in layers:
            continue
        t = e.dxftype()
        if t == 'LINE':
            out.append((lay, tuple(e.dxf.start)[:2], tuple(e.dxf.end)[:2]))
        elif t in ('LWPOLYLINE', 'POLYLINE'):
            pts = [tuple(p)[:2] for p in (e.get_points('xy') if t == 'LWPOLYLINE' else [v.dxf.location for v in e.vertices])]
            closed = e.closed if t == 'LWPOLYLINE' else e.is_closed
            for a, b in zip(pts, pts[1:] + (pts[:1] if closed else [])):
                out.append((lay, a, b))
        elif t in ('ARC', 'CIRCLE'):
            c, r = e.dxf.center, e.dxf.radius
            a0, a1 = (math.radians(e.dxf.start_angle), math.radians(e.dxf.end_angle)) if t == 'ARC' else (0, 2 * math.pi)
            if a1 <= a0:
                a1 += 2 * math.pi
            n = max(8, int((a1 - a0) / (math.pi / 18)))
            P = [(c[0] + r * math.cos(a0 + (a1 - a0) * k / n), c[1] + r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
            out += [(lay, P[k], P[k + 1]) for k in range(n)]
    return out


def render_lines(segs, box, shape, width=2):
    """draw (x0,y0)-(x1,y1) mm segments into an image of `shape` covering mm window box=(x0,x1,y0,y1); ink = 0"""
    from PIL import Image, ImageDraw
    H, W = shape
    im = Image.new('L', (W, H), 255)
    dr = ImageDraw.Draw(im)
    sx, sy = W / (box[1] - box[0]), H / (box[3] - box[2])
    for a, b in segs:
        dr.line([((a[0] - box[0]) * sx, (box[3] - a[1]) * sy), ((b[0] - box[0]) * sx, (box[3] - b[1]) * sy)], fill=0, width=width)
    return np.asarray(im, float)


def render_dxf(path, size=2000, layers=None):
    segs = dxf_segments(path, layers)
    P = np.array([p for _, a, b in segs for p in (a, b)])
    lo, hi = P.min(0), P.max(0)
    pad = 0.02 * (hi - lo).max()
    box = (lo[0] - pad, hi[0] + pad, lo[1] - pad, hi[1] + pad)
    W = size
    H = max(50, int(size * (box[3] - box[2]) / (box[1] - box[0])))
    return render_lines([(a, b) for _, a, b in segs], box, (H, W)), box


# ====================================================================== helpers
def _ink(img, thr=160):
    return img < thr


def _dilate(m, r):
    from scipy.ndimage import binary_dilation
    if r <= 0:
        return m
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return binary_dilation(m, structure=(x * x + y * y) <= r * r)


def _shift(a, b, max_frac=0.25):
    """translation (dy, dx) that moves b onto a, by phase correlation"""
    H, W = a.shape
    Fa, Fb = np.fft.fft2(a.astype(float)), np.fft.fft2(b.astype(float))
    R = Fa * np.conj(Fb)
    R /= np.abs(R) + 1e-9
    r = np.abs(np.fft.ifft2(R))
    dy, dx = np.unravel_index(np.argmax(r), r.shape)
    dy = dy - H if dy > H // 2 else dy
    dx = dx - W if dx > W // 2 else dx
    if abs(dy) > max_frac * H or abs(dx) > max_frac * W:
        return 0, 0
    return int(dy), int(dx)


def _roll(m, dy, dx):
    out = np.zeros_like(m)
    H, W = m.shape
    ys, yd = (slice(0, H - dy), slice(dy, H)) if dy >= 0 else (slice(-dy, H), slice(0, H + dy))
    xs, xd = (slice(0, W - dx), slice(dx, W)) if dx >= 0 else (slice(-dx, W), slice(0, W + dx))
    out[yd, xd] = m[ys, xs]
    return out


def _save_rgb(path, rgb):
    from PIL import Image
    Image.fromarray(rgb.astype(np.uint8)).save(path)
    return path


def _regions(mask, min_px=30, top=15):
    from scipy.ndimage import label, find_objects
    lab, n = label(_dilate(mask, 3))
    out = []
    for i, sl in enumerate(find_objects(lab), 1):
        size = int((mask[sl] & (lab[sl] == i)).sum())
        if size >= min_px:
            out.append({'x_px': [sl[1].start, sl[1].stop], 'y_px': [sl[0].start, sl[0].stop], 'ink_px': size})
    return sorted(out, key=lambda r: -r['ink_px'])[:top]


# ====================================================================== drawing vs drawing
def compare_drawings(a, b, out_png='compare.png', page_a=0, page_b=0, dpi=150, align=True, tol_px=2):
    A = load_image(a, page_a, dpi)
    B = load_image(b, page_b, dpi)
    if B.shape != A.shape:
        from PIL import Image
        B = np.asarray(Image.fromarray(B.astype(np.uint8)).resize((A.shape[1], A.shape[0])), float)
    ia, ib = _ink(A), _ink(B)
    dy, dx = _shift(ia, ib) if align else (0, 0)
    ib = _roll(ib, dy, dx)
    da, db = _dilate(ia, tol_px), _dilate(ib, tol_px)
    only_a, only_b, same = ia & ~db, ib & ~da, ia & db
    rgb = np.full(A.shape + (3,), 255.0)
    rgb[same] = (150, 150, 150)
    rgb[only_a] = (220, 30, 30)
    rgb[only_b] = (20, 160, 60)
    _save_rgb(out_png, rgb)
    na, nb = int(ia.sum()), int(ib.sum())
    sim = 1 - (only_a.sum() + only_b.sum()) / max(1, na + nb)
    ra, rb = _regions(only_a), _regions(only_b)
    text = (f'The two drawings are {sim * 100:.1f} % the same (line ink). '
            + (f'Drawing B was shifted by {dx} px across and {dy} px down to line up with A. ' if (dx or dy) else '')
            + f'{len(ra)} area(s) have lines only in A (removed in B, red) and {len(rb)} area(s) have lines only in B '
              f'(added in B, green). The overlay is saved as {os.path.basename(out_png)}.')
    return {'similarity': round(float(sim), 4), 'shift_px': [dx, dy], 'ink_px': [na, nb], 'only_in_A_px': int(only_a.sum()),
            'only_in_B_px': int(only_b.sum()), 'regions_only_in_A': ra, 'regions_only_in_B': rb, 'overlay': out_png,
            'plain_english': text}


# ====================================================================== FE mesh vs drawing
def mesh_feature_lines(model, axis='z', level=0.0, tol=1.0):
    """plan-view lines of an FEModel at `level`: plate joints, free edges and openings lying in that plane"""
    k = 'xyz'.index(axis)
    ij = [i for i in range(3) if i != k]
    cnt, grp, segs = {}, {}, []
    for e in model.elems.values():
        ns = e['nodes']
        if len(ns) == 2:                                   # 1D members (stiffeners) are drawn lines too
            pa, pb = model.nodes[ns[0]], model.nodes[ns[1]]
            if abs(pa[k] - level) <= tol and abs(pb[k] - level) <= tol:
                segs.append(((pa[ij[0]], pa[ij[1]]), (pb[ij[0]], pb[ij[1]])))
            continue
        if len(ns) < 3:
            continue
        for a in range(len(ns)):
            key = tuple(sorted((ns[a], ns[(a + 1) % len(ns)])))
            cnt[key] = cnt.get(key, 0) + 1
            grp.setdefault(key, set()).add(e.get('group'))
    for (a, b), c in cnt.items():
        pa, pb = model.nodes[a], model.nodes[b]
        if abs(pa[k] - level) > tol or abs(pb[k] - level) > tol:
            continue
        if c >= 3 or c == 1 or len(grp[(a, b)]) > 1:
            segs.append(((pa[ij[0]], pa[ij[1]]), (pb[ij[0]], pb[ij[1]])))
    return segs


def compare_mesh_drawing(model, drawing, box, level=0.0, axis='z', out_png='mesh_vs_drawing.png', page=0, dpi=150,
                         search_mm=250.0, ink_tol_px=4):
    """box = (x0, x1, y0, y1): the ship coordinates in mm that the drawing image (page) covers"""
    from .femodel import FEModel
    if isinstance(model, str):
        model = FEModel.read(model)
    img = load_image(drawing, page, dpi)
    segs = mesh_feature_lines(model, axis, level)
    if not segs:
        raise ValueError(f'no mesh lines at {axis} = {level:g}: check the level')
    M = _ink(render_lines(segs, box, img.shape, width=1))
    ink = _ink(img)
    D = _dilate(ink, ink_tol_px)
    hit0 = float((M & D).sum() / max(1, M.sum()))
    px_per_mm = img.shape[1] / (box[1] - box[0])
    r = int(search_mm * px_per_mm)
    best = (hit0, 0, 0)
    step = max(1, r // 25)
    for dy in range(-r, r + 1, step):
        for dx in range(-r, r + 1, step):
            h = float((_roll(M, dy, dx) & D).sum() / max(1, M.sum()))
            if h > best[0] + 1e-9:
                best = (h, dy, dx)
    h0, by, bx = best                                       # fine search around the coarse optimum
    for dy in range(by - step, by + step + 1):
        for dx in range(bx - step, bx + step + 1):
            h = float((_roll(M, dy, dx) & D).sum() / max(1, M.sum()))
            if h > best[0] + 1e-9:
                best = (h, dy, dx)
    cover = float((ink & _dilate(M, ink_tol_px)).sum() / max(1, ink.sum()))
    rgb = np.stack([img] * 3, -1) * 0.5 + 127
    on, off = M & D, M & ~D
    rgb[on] = (20, 160, 60)
    rgb[off] = (220, 30, 30)
    _save_rgb(out_png, rgb)
    sx, sy = best[2] / px_per_mm, -best[1] / px_per_mm
    ok = hit0 >= 0.6 and abs(sx) < 50 and abs(sy) < 50
    text = (f'{hit0 * 100:.0f} % of the FE mesh lines at {axis} = {level:g} mm lie on lines of the drawing '
            f'and {cover * 100:.0f} % of the drawing ink has a mesh line nearby. '
            + (f'Moving the mesh by {sx:+.0f} mm in x and {sy:+.0f} mm in y would raise the match to {best[0] * 100:.0f} % - '
               'the mesh or the drawing window (box) is offset by about that much. ' if (best[1] or best[2]) and best[0] > hit0 + 0.05 else '')
            + ('The mesh matches the drawing.' if ok else 'The mesh does NOT match the drawing well: check the red lines in the overlay.')
            + f' Green = mesh line on a drawn line, red = mesh line with no drawn line. Overlay: {os.path.basename(out_png)}.')
    return {'mesh_on_drawing': round(hit0, 3), 'drawing_covered_by_mesh': round(cover, 3), 'best_shift_mm': [round(sx), round(sy)],
            'best_match': round(best[0], 3), 'pass': ok, 'mesh_lines': len(segs), 'overlay': out_png, 'plain_english': text}


# ====================================================================== DXF -> 3D plates
DEFAULT_LAYERS = {
    'outline': ['DECK', 'PLATE', 'OUTLINE', 'BOUNDARY'],
    'opening': ['OPENING', 'HOLE', 'CUTOUT', 'MANHOLE'],
    'web': {'GIRDER': {'h': 600, 't': 12}, 'WEB': {'h': 800, 't': 10}, 'FRAME': {'h': 800, 't': 10}, 'BHD': {'h': 2500, 't': 10},
            'CARLING': {'h': 400, 't': 10}},
    'stiffener': {'STIFF': {'type': 'FlatBar', 'h': 150, 't': 12}, 'LONG': {'type': 'HP', 'h': 200, 't': 10}},
}


def _match(layer, names):
    u = layer.upper()
    return next((n for n in names if n in u), None)


def dxf_to_plates(path, z=0.0, t_plate=12.0, layers=None, scale=1.0, down=-1.0):
    """structural plan DXF (mm, or scale) -> {'plates', 'beams', 'report'} for plates_mesh / plates_to_step"""
    import ezdxf
    L = {**DEFAULT_LAYERS, **(layers or {})}
    doc = ezdxf.readfile(path)
    closed, lines = [], []
    for e in doc.modelspace():
        lay, t = e.dxf.layer, e.dxftype()
        if t == 'LWPOLYLINE' and e.closed:
            closed.append((lay, [(p[0] * scale, p[1] * scale) for p in e.get_points('xy')]))
        elif t == 'POLYLINE' and e.is_closed:
            closed.append((lay, [(v.dxf.location[0] * scale, v.dxf.location[1] * scale) for v in e.vertices]))
        elif t == 'CIRCLE' and _match(lay, L['opening']):
            c, r = e.dxf.center, e.dxf.radius
            closed.append((lay, [((c[0] + r * math.cos(a)) * scale, (c[1] + r * math.sin(a)) * scale) for a in np.linspace(0, 2 * math.pi, 24, endpoint=False)]))
        elif t == 'LINE':
            lines.append((lay, (e.dxf.start[0] * scale, e.dxf.start[1] * scale), (e.dxf.end[0] * scale, e.dxf.end[1] * scale)))
        elif t == 'LWPOLYLINE':
            P = [(p[0] * scale, p[1] * scale) for p in e.get_points('xy')]
            lines += [(lay, a, b) for a, b in zip(P, P[1:])]
    outs = [(lay, P) for lay, P in closed if _match(lay, L['outline'])]
    holes = [(lay, P) for lay, P in closed if _match(lay, L['opening'])]
    rep = {'outlines': len(outs), 'openings': len(holes), 'webs': 0, 'stiffeners': 0, 'ignored_layers': set()}
    plates, beams = [], []
    area = lambda P: abs(sum(P[i][0] * P[i - 1][1] - P[i - 1][0] * P[i][1] for i in range(len(P)))) / 2
    def inside(pt, P):
        c = False
        for i in range(len(P)):
            (x0, y0), (x1, y1) = P[i - 1], P[i]
            if (y0 > pt[1]) != (y1 > pt[1]) and pt[0] < x0 + (pt[1] - y0) * (x1 - x0) / (y1 - y0):
                c = not c
        return c
    for k, (lay, P) in enumerate(sorted(outs, key=lambda x: -area(x[1])), 1):
        hs = [H for _, H in holes if inside(H[0], P)]
        plates.append({'id': f'PL{k}', 'group': lay, 't': t_plate, 'outline': [[x, y, z] for x, y in P],
                       'holes': [[[x, y, z] for x, y in H] for H in hs]})
    for i, (lay, a, b) in enumerate(lines, 1):
        w = _match(lay, L['web'])
        s = _match(lay, L['stiffener'])
        if w:
            h, t = L['web'][w]['h'], L['web'][w]['t']
            plates.append({'id': f'{w}{i}', 'group': lay, 't': t,
                           'outline': [[a[0], a[1], z], [b[0], b[1], z], [b[0], b[1], z + down * h], [a[0], a[1], z + down * h]]})
            rep['webs'] += 1
        elif s:
            beams.append({'id': f'{s}{i}', 'a': [a[0], a[1], z], 'b': [b[0], b[1], z], 'profile': L['stiffener'][s], 'normal': [0, 0, down]})
            rep['stiffeners'] += 1
        elif not _match(lay, L['outline']) and not _match(lay, L['opening']):
            rep['ignored_layers'].add(lay)
    rep['ignored_layers'] = sorted(rep['ignored_layers'])
    rep['plain_english'] = (f"Read {rep['outlines']} plate outline(s), {rep['openings']} opening(s), {rep['webs']} web/girder line(s) "
                            f"made into vertical plates and {rep['stiffeners']} stiffener line(s) made into 1D beams, at z = {z:g} mm."
                            + (f" Lines on these layers were not used: {', '.join(rep['ignored_layers'])}." if rep['ignored_layers'] else ''))
    return {'plates': plates, 'beams': beams, 'report': rep}


def plates_to_step(plates, path, beams=None):
    """3D CAD model of a plate assembly: every plate as a thin solid (thickness about its mid-plane) -> STEP"""
    import cadquery as cq
    from .platemesh import Plate
    solids = []
    for d in plates:
        P = Plate(d, 1e-3)
        wire = lambda L: cq.Wire.makePolygon([cq.Vector(*p) for p in L], close=True)
        face = cq.Face.makeFromWires(wire(P.loops3[0]), [wire(h) for h in P.loops3[1:]])
        n = cq.Vector(*P.n)
        solid = cq.Solid.extrudeLinear(face.translate(n * (-P.t / 2)), n * P.t)
        solids.append(solid)
    from .mesh import profile_props
    for bm in beams or []:
        p = bm['profile']
        a, b = np.array(bm['a'], float), np.array(bm['b'], float)
        d = b - a
        nrm = np.array(bm.get('normal', [0, 0, -1]), float)
        side = np.cross(d / np.linalg.norm(d), nrm)
        h, t = float(p['h']), float(p['t'])
        web = [a - side * t / 2, a + side * t / 2, a + side * t / 2 + nrm * h, a - side * t / 2 + nrm * h]
        f = cq.Face.makeFromWires(cq.Wire.makePolygon([cq.Vector(*x) for x in web], close=True))
        solids.append(cq.Solid.extrudeLinear(f, cq.Vector(*d)))
    comp = cq.Compound.makeCompound(solids)
    cq.exporters.export(cq.Workplane().add(comp), path)
    return {'step': path, 'solids': len(solids)}
