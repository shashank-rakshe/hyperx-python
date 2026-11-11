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
