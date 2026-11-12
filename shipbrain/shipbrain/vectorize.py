"""
Scanned drawings -> vectors, with VTracer (https://github.com/visioncortex/vtracer, MIT, visioncortex; made for
high-resolution scans of historic blueprints). Used as written through its Python package (pip install
"vtracer==1.0.0a4"); the SVG it writes is turned into DXF by ShipBrain's own code.

  is_scan(path)         a raster picture (PNG / JPG / TIFF / BMP) or a PDF page without vector content
  trace(path, ...)      scan -> SVG (VTracer, black-and-white line-art preset, adaptive threshold for uneven
                        scans, speckle filter) -> DXF (closed polylines, layer TRACE), optional scale to mm
What comes out: every pen stroke as its OUTLINE (a thin closed shape), not a centre line - right for comparing two
revisions of a scanned drawing, for a clean vector copy and for overlaying on a model; dimensions are read from the
text (drawing_texts / OCR), not from the traced lines.
"""
import math, os, re
import numpy as np

RASTER = ('.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp', '.webp', '.gif')


def _lib():
    try:
        import vtracer
    except ImportError:
        raise RuntimeError('tracing scanned drawings needs VTracer (free, MIT): pip install "vtracer==1.0.0a4"')
    if not hasattr(vtracer, 'Config'):
        raise RuntimeError('this VTracer is too old: pip install "vtracer==1.0.0a4"')
    return vtracer


def is_scan(path):
    low = path.lower()
    if low.endswith(RASTER):
        return True
    if low.endswith('.pdf'):
        try:
            import pdfplumber
            with pdfplumber.open(path) as d:
                p = d.pages[0]
                return not (p.lines or p.curves or p.rects)
        except Exception:
            return False
    return False


def _page_png(pdf, page, dpi, out):
    import pypdfium2
    doc = pypdfium2.PdfDocument(pdf)
    try:
        doc[page].render(scale=dpi / 72).to_pil().convert('RGB').save(out)
    finally:
        doc.close()
    return out


# ====================================================================== SVG paths -> polylines (own code)
_TOK = re.compile(r'[MmLlHhVvCcSsQqTtZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')


def _bez(p0, p1, p2, p3, n=8):
    return [((1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0],
             (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1])
            for t in (k / n for k in range(1, n + 1))]


def path_polylines(d, dx=0.0, dy=0.0):
    """SVG path data -> list of point lists (each subpath; curves flattened)"""
    toks = _TOK.findall(d)
    out, cur, x, y, sx, sy, cmd, i = [], [], 0.0, 0.0, 0.0, 0.0, None, 0
    last_c = None

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v
    while i < len(toks):
        if re.match(r'[A-Za-z]', toks[i]):
            cmd = toks[i]
            i += 1
            if cmd in 'Zz':
                if cur:
                    out.append(cur + [cur[0]])
                cur, x, y = [], sx, sy
                continue
        rel = cmd.islower()
        c = cmd.upper()
        ox, oy = (x, y) if rel else (0.0, 0.0)
        if c == 'M':
            if cur:
                out.append(cur)
            x, y = ox + num(), oy + num()
            sx, sy, cur = x, y, [(x, y)]
            cmd = 'l' if rel else 'L'                         # following pairs are line-tos
        elif c == 'L':
            x, y = ox + num(), oy + num()
            cur.append((x, y))
        elif c == 'H':
            x = ox + num() if rel else num()
            cur.append((x, y))
        elif c == 'V':
            y = (y + num()) if rel else num()
            cur.append((x, y))
        elif c == 'C':
            p1 = (ox + num(), oy + num())
            p2 = (ox + num(), oy + num())
            p3 = (ox + num(), oy + num())
            cur += _bez((x, y), p1, p2, p3)
            x, y = p3
            last_c = p2
        elif c == 'S':
            p1 = (2 * x - last_c[0], 2 * y - last_c[1]) if last_c else (x, y)
            p2 = (ox + num(), oy + num())
            p3 = (ox + num(), oy + num())
            cur += _bez((x, y), p1, p2, p3)
            x, y = p3
            last_c = p2
        elif c == 'Q':
            q1 = (ox + num(), oy + num())
            q2 = (ox + num(), oy + num())
            cur += _bez((x, y), (x + 2 / 3 * (q1[0] - x), y + 2 / 3 * (q1[1] - y)),
                        (q2[0] + 2 / 3 * (q1[0] - q2[0]), q2[1] + 2 / 3 * (q1[1] - q2[1])), q2)
            x, y = q2
        else:                                                 # T and anything else: straight to the end point
            x, y = ox + num(), oy + num()
            cur.append((x, y))
    if cur:
        out.append(cur)
    return [[(px + dx, py + dy) for px, py in pl] for pl in out if len(pl) > 1]


def svg_polylines(svg_text):
    polys = []
    for m in re.finditer(r'<path\b[^>]*>', svg_text):
        tag = m.group(0)
        d = re.search(r'\bd="([^"]*)"', tag)
        if not d:
            continue
        tr = re.search(r'translate\(\s*([-\d.eE]+)[ ,]+([-\d.eE]+)\s*\)', tag)
        polys += path_polylines(d.group(1), *(map(float, tr.groups()) if tr else (0.0, 0.0)))
    h = re.search(r'<svg[^>]*\bheight="([\d.]+)', svg_text)
    return polys, float(h.group(1)) if h else None


def trace(path, out_base=None, page=0, dpi=200, scale=None, speckle=8, adaptive=True):
    """scan -> SVG + DXF. scale: drawing units per pixel (e.g. mm per px at the drawing's scale); default 1 px = 1 unit"""
    vt = _lib()
    out_base = out_base or os.path.splitext(path)[0] + '_traced'
    src = path
    if path.lower().endswith('.pdf'):
        src = _page_png(path, page, dpi, out_base + '_page.png')
    cfg = vt.Config.bw()
    cfg.mode = 'polygon'                                      # drawings: straight segments where the ink is straight
    cfg.filter_speckle = int(speckle)                         # dust / scan noise below this size (px) is dropped
    cfg.adaptive = bool(adaptive)                             # uneven lighting / yellowed paper
    svg = out_base + '.svg'
    cfg.convert_file(src, svg)
    polys, H = svg_polylines(open(svg, encoding='utf-8').read())
    k = float(scale or 1.0)
    import ezdxf
    doc = ezdxf.new('R2018')
    doc.layers.add('TRACE', color=7)
    msp = doc.modelspace()
    n_pts = 0
    for pl in polys:
        pts = [(x * k, ((H or 0) - y) * k) for x, y in pl]   # SVG y runs down, DXF y runs up
        closed = len(pts) > 2 and math.dist(pts[0], pts[-1]) < 1e-9
        msp.add_lwpolyline(pts[:-1] if closed else pts, close=closed, dxfattribs={'layer': 'TRACE'})
        n_pts += len(pts)
    dxf = out_base + '.dxf'
    doc.saveas(dxf)
    from PIL import Image
    w, h = Image.open(src).size
    unit = f'{k:g} drawing unit(s) per pixel' if scale else 'pixels'
    return {'svg': svg, 'dxf': dxf, 'shapes': len(polys), 'points': n_pts, 'image_px': [w, h], 'units': unit,
            'plain_english': (f"Traced {os.path.basename(path)} ({w} x {h} px) with VTracer: {len(polys)} outline shapes "
                              f"({n_pts} points) written to {os.path.basename(dxf)} (layer TRACE, in {unit}) and "
                              f"{os.path.basename(svg)}. Each pen stroke is traced as its outline; dust smaller than "
                              f"{speckle} px was dropped.")}


# ====================================================================== centre-line tracing (own code)
def _thin(img):
    """Zhang-Suen thinning of a boolean image (True = ink) to one-pixel-wide lines"""
    im = np.pad(img, 1).astype(np.uint8)
    while True:
        changed = False
        for step in (0, 1):
            P = [im[:-2, 1:-1], im[:-2, 2:], im[1:-1, 2:], im[2:, 2:], im[2:, 1:-1], im[2:, :-2], im[1:-1, :-2], im[:-2, :-2]]  # P2..P9
            c = im[1:-1, 1:-1]
            B = sum(p.astype(int) for p in P)
            A = sum(((P[i] == 0) & (P[(i + 1) % 8] == 1)).astype(int) for i in range(8))
            if step == 0:
                m = (P[0] * P[2] * P[4] == 0) & (P[2] * P[4] * P[6] == 0)
            else:
                m = (P[0] * P[2] * P[6] == 0) & (P[0] * P[4] * P[6] == 0)
            kill = (c == 1) & (B >= 2) & (B <= 6) & (A == 1) & m
            if kill.any():
                im[1:-1, 1:-1][kill] = 0
                changed = True
        if not changed:
            return im[1:-1, 1:-1].astype(bool)


def _despeckle(ink, min_px):
    """drop ink blobs smaller than min_px pixels (scan dust); 8-connected flood fill"""
    if min_px <= 1:
        return ink
    H, W = ink.shape
    lab = np.zeros(ink.shape, np.int32)
    out = ink.copy()
    ys, xs = np.nonzero(ink)
    k = 0
    for y0, x0 in zip(ys, xs):
        if lab[y0, x0]:
            continue
        k += 1
        stack, comp = [(y0, x0)], []
        lab[y0, x0] = k
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < H and 0 <= xx < W and ink[yy, xx] and not lab[yy, xx]:
                        lab[yy, xx] = k
                        stack.append((yy, xx))
        if len(comp) < min_px:
            for y, x in comp:
                out[y, x] = False
    return out


def _simplify(pts, tol):
    """Douglas-Peucker"""
    if len(pts) < 3:
        return pts
    a, b = np.array(pts[0], float), np.array(pts[-1], float)
    ab = b - a
    n = np.hypot(*ab)
    P = np.array(pts, float)
    d = np.hypot(*(P - a).T) if n < 1e-12 else np.abs(ab[0] * (P[:, 1] - a[1]) - ab[1] * (P[:, 0] - a[0])) / n
    i = int(np.argmax(d))
    if d[i] <= tol:
        return [pts[0], pts[-1]]
    return _simplify(pts[:i + 1], tol)[:-1] + _simplify(pts[i:], tol)


def skeleton_lines(skel, min_len=6, tol=1.2, spur=0):
    """skeleton pixels -> polylines (walk from line ends and junctions; closed loops handled last)"""
    H, W = skel.shape
    ys, xs = np.nonzero(skel)
    on = {(int(x), int(y)) for x, y in zip(xs, ys)}
    def redundant(p, q):                                      # a diagonal step that a two-step 4-connected path already covers
        if p[0] == q[0] or p[1] == q[1]:
            return False
        return (p[0], q[1]) in on or (q[0], p[1]) in on
    nb = lambda p: [(p[0] + dx, p[1] + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                    if (dx or dy) and (p[0] + dx, p[1] + dy) in on and not redundant(p, (p[0] + dx, p[1] + dy))]
    deg = {p: len(nb(p)) for p in on}
    nodes = {p for p, d in deg.items() if d != 2}
    seen, lines = set(), []

    def walk(start, nxt):
        line, prev, cur = [start], start, nxt
        seen.add(frozenset((start, nxt)))
        while True:
            line.append(cur)
            if cur in nodes and cur != start:
                break
            cand = [q for q in nb(cur) if q != prev and frozenset((cur, q)) not in seen]
            if not cand:
                break
            q = min(cand, key=lambda r: abs(r[0] - cur[0]) + abs(r[1] - cur[1]))   # prefer straight over diagonal steps
            seen.add(frozenset((cur, q)))
            prev, cur = cur, q
            if cur == start:
                line.append(cur)
                break
        return line
    for n in sorted(nodes):
        for q in nb(n):
            if frozenset((n, q)) not in seen:
                lines.append(walk(n, q))
    for p in sorted(on):                                      # closed loops with no end or junction
        for q in nb(p):
            if frozenset((p, q)) not in seen:
                lines.append(walk(p, q))
    ends = {}
    for l in lines:
        for e in (l[0], l[-1]):
            ends[e] = ends.get(e, 0) + 1
    out = []
    for l in lines:
        free = (ends[l[0]] == 1) + (ends[l[-1]] == 1)         # how many ends hang free
        n = len(l)
        if n < min_len and l[0] != l[-1]:
            continue                                         # dust
        if free == 1 and n < spur:
            continue                                         # short spur left by a rough pen edge
        out.append(_simplify(l, tol))
    return out


def trace_centerline(path, out_base=None, page=0, dpi=200, scale=None, threshold=None, min_len=6, tol=1.2, speckle=8):
    """thin-line drawing -> centre-lines (one line per pen stroke, not an outline) -> DXF layer CENTERLINE"""
    from PIL import Image
    out_base = out_base or os.path.splitext(path)[0] + '_centerline'
    src = path
    if path.lower().endswith('.pdf'):
        src = _page_png(path, page, dpi, out_base + '_page.png')
    g = np.asarray(Image.open(src).convert('L'), float)
    if threshold is None:
        lo, hi = np.percentile(g, 2), np.percentile(g, 60)
        threshold = (lo + hi) / 2 if hi - lo > 30 else 128    # halfway between ink and paper
    ink = g < threshold
    if ink.mean() > 0.5:                                     # light lines on a dark ground
        ink = ~ink
    ink = _despeckle(ink, int(speckle))
    skel = _thin(ink)
    width = ink.sum() / max(1, skel.sum())                   # average pen width in pixels
    lines = skeleton_lines(skel, min_len=int(min_len), tol=float(tol), spur=int(round(3 * width)) + 2)
    k = float(scale or 1.0)
    import ezdxf
    doc = ezdxf.new('R2018')
    doc.layers.add('CENTERLINE', color=7)
    msp = doc.modelspace()
    H = g.shape[0]
    for l in lines:
        pts = [(x * k, (H - y) * k) for x, y in l]
        msp.add_lwpolyline(pts, close=len(pts) > 3 and pts[0] == pts[-1], dxfattribs={'layer': 'CENTERLINE'})
    dxf = out_base + '.dxf'
    doc.saveas(dxf)
    w, h = g.shape[1], g.shape[0]
    unit = f'{k:g} drawing unit(s) per pixel' if scale else 'pixels'
    tot = sum(sum(math.dist(a, b) for a, b in zip(l, l[1:])) for l in lines) * k
    return {'dxf': dxf, 'lines': len(lines), 'total_length': round(tot, 1), 'image_px': [w, h], 'units': unit,
            'plain_english': (f"Centre-line traced {os.path.basename(path)} ({w} x {h} px): {len(lines)} lines, total length {tot:,.0f} ({unit}), "
                              f"written to {os.path.basename(dxf)} (layer CENTERLINE). Each pen stroke became ONE line along its middle "
                              f"(good for thin line drawings; use the outline mode for filled shapes).")}


def suggest_mode(path, page=0, dpi=200, thin_px=10):
    """"centerline" when the ink is thin pen strokes (typical line drawing), "outline" when it has filled areas / thick strokes"""
    from PIL import Image
    src = path
    if path.lower().endswith('.pdf'):
        import tempfile
        src = _page_png(path, page, dpi, os.path.join(tempfile.mkdtemp(), 'p.png'))
    g = np.asarray(Image.open(src).convert('L'), float)
    lo, hi = np.percentile(g, 2), np.percentile(g, 60)
    ink = g < ((lo + hi) / 2 if hi - lo > 30 else 128)
    if ink.mean() > 0.5:
        ink = ~ink
    meds = []
    for a in (ink, ink.T):
        d = np.diff(np.pad(a, ((0, 0), (1, 1))).astype(np.int8), axis=1)
        st, en = np.nonzero(d == 1), np.nonzero(d == -1)
        runs = en[1] - st[1] if len(st[0]) else np.array([0])
        meds.append(float(np.median(runs)))
    return 'centerline' if min(meds) <= thin_px else 'outline'
