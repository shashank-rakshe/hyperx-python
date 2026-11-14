"""
ship_pairs.py - REAL drawing -> XML training pairs (the main skill: read a deck plan, write the members).

For every deck plan that the offline tool (deckrules) has calibrated, the drawing page is cut into tiles. Each tile image is paired
with the members of the REFERENCE XML (yard-made reference model, or the checked online XML) that lie in that tile:

  prompt : tile image + "this tile covers X a..b, Y c..d mm (ship), deck z, sheet notes ..." + core rules
  answer : JSON members {id, kind, sec, a:[X,Y], b:[X,Y]} rounded to 10 mm, clipped to the tile

So the model learns Step 2 (labelling) and Step 3 (alignment) from real drawings, never from guesses.
Inputs: views.json (one row per calibrated deck view: pdf, page, name, z_mm, x0 (page x of X=0), cl_y (page y of C.L), k (mm/pt),
        region (page bbox)) and the matching reference XML. make_views() builds views.json from deckrules *_report.json files.
Check: python ship_pairs.py --check  draws the reference members over a few tiles (PNG) - look at them before training.
"""
import json, math, os, re, glob, random

TILE_MM = 4800.0          # tile size (3 frame spaces of 1600 / 6 of 800)
ZOOM = 4.0                # px per pt (R1.1: >= 4 px/pt)
MAXM = 12                 # members per tile (keeps the answer < ~1000 tokens)


def make_views(report_glob, pdf, ref_xml):
    rows = []
    for f in sorted(glob.glob(report_glob)):
        v = json.load(open(f))['view']
        page = int(re.search(r'/p(\d+)/', f.replace('\\', '/')).group(1))
        rows.append({'pdf': pdf, 'page': page, 'name': v['name'], 'z_mm': v['z_mm'], 'x0': v['frame0_page_x'],
                     'cl_y': v['centre_line_page_y'], 'k': v['mm_per_pt'], 'region': v['region_page'], 'ref': ref_xml,
                     'notes': v.get('notes', {})})
    return rows


def deck_members(ref_xml, z, tol=400.0):
    """members of the reference XML on deck planes near height z, in ship X/Y (deck panels: normal Z)"""
    from ship_xml_kit import xml_to_members, _to_xyz, _unit
    M = xml_to_members(ref_xml)
    out = []
    for b in M['blocks']:
        for p in b['panels']:
            W = _unit(p['cs']['waxis'])
            nn = 0
            if abs(W[2]) < 0.9 or abs(p['cs']['origin'][2] - z) > tol + 1500:
                continue
            for s in p['stiffeners']:
                a = _to_xyz(p['cs'], *s['trace'][0]); bb = _to_xyz(p['cs'], *s['trace'][1])
                if abs((a[2] + bb[2]) / 2 - z) > tol:
                    continue
                nn += 1
                out.append({'id': (s['name'] or f"S{nn}").split('/')[-1], 'kind': s['kind'] or 'stiffener', 'sec': s['sec'],
                            'a': [a[0], a[1]], 'b': [bb[0], bb[1]]})
    return out


def _clip(a, b, x0, x1, y0, y1):
    """Liang-Barsky clip of segment a-b to the box -> (a', b') or None"""
    dx, dy = b[0] - a[0], b[1] - a[1]
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, a[0] - x0), (dx, x1 - a[0]), (-dy, a[1] - y0), (dy, y1 - a[1])):
        if p == 0:
            if q < 0:
                return None
        else:
            t = q / p
            if p < 0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
    if t0 > t1:
        return None
    return [a[0] + t0 * dx, a[1] + t0 * dy], [a[0] + t1 * dx, a[1] + t1 * dy]


def register(v, members, search_mm=250.0, z=2.0):
    """The calibration of a view can be off (frame-table anchor, scan). Find the shift (dX, dY) of the reference members that puts
    the most of their length on drawn ink, and report the hit ratio. Views below MIN_HIT are not used (labels would be wrong)."""
    import numpy as np, pymupdf, cv2
    rx0, ry0, rx1, ry1 = v['region']
    page = pymupdf.open(v['pdf'])[v['page'] - 1]
    pix = page.get_pixmap(matrix=pymupdf.Matrix(z, z), clip=pymupdf.Rect(rx0, ry0, rx1, ry1), colorspace=pymupdf.csGRAY)
    g = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width)
    ink = cv2.dilate((g < 140).astype(np.uint8), np.ones((3, 3), np.uint8))
    H, W = ink.shape
    pts = []
    for m in members:                                   # sample points every ~100 mm along each member
        L = math.dist(m['a'], m['b']); n = max(2, int(L / 100))
        for t in np.linspace(0.05, 0.95, n):
            pts.append((m['a'][0] + t * (m['b'][0] - m['a'][0]), m['a'][1] + t * (m['b'][1] - m['a'][1])))
    if len(pts) < 20:
        return 0.0, 0.0, 0.0
    P = np.array(pts)
    px = (v['x0'] + P[:, 0] / v['k'] - rx0) * z
    py = (v['cl_y'] - P[:, 1] / v['k'] - ry0) * z
    def hit(dx, dy):
        x = np.round(px + dx / v['k'] * z).astype(int); y = np.round(py - dy / v['k'] * z).astype(int)
        ok = (x >= 0) & (x < W) & (y >= 0) & (y < H)
        return float(ink[y[ok], x[ok]].sum()) / max(1, len(P))
    h0 = hit(0, 0)
    best = (h0, 0.0, 0.0)
    step = v['k'] / z                                       # one pixel in mm
    for stp in (4 * step, step):
        cx, cy = best[1], best[2]
        rng = search_mm if stp > step else 4 * step
        for dx in np.arange(cx - rng, cx + rng + 1e-6, stp):
            for dy in np.arange(cy - rng, cy + rng + 1e-6, stp):
                h = hit(dx, dy)
                if h > best[0]:
                    best = (h, float(dx), float(dy))
    if best[0] < h0 + 0.05:          # a shift must clearly help; small gains are aliasing on parallel lines (text, dimensions)
        return h0, 0.0, 0.0
    return best


MIN_HIT = 0.6         # below this the reference members do not sit on the drawn lines -> no training pairs from that view


def tiles_for_view(v, members, step=None):
    step = step or TILE_MM * 0.5          # half-tile stride: every member is seen in several tiles / positions
    rx0, ry0, rx1, ry1 = v['region']
    X0, X1 = (rx0 - v['x0']) * v['k'], (rx1 - v['x0']) * v['k']
    Y0, Y1 = (v['cl_y'] - ry1) * v['k'], (v['cl_y'] - ry0) * v['k']
    out = []
    x = X0
    while x < X1:
        y = Y0
        while y < Y1:
            box = (x, x + TILE_MM, y, y + TILE_MM)
            mm = []
            for m in members:
                c = _clip(m['a'], m['b'], *box)
                if c and math.dist(c[0], c[1]) >= 200:
                    r10 = lambda p: [int(round(p[0] / 10.0) * 10), int(round(p[1] / 10.0) * 10)]
                    mm.append({'id': m['id'], 'kind': m['kind'], 'sec': m['sec'], 'a': r10(c[0]), 'b': r10(c[1]),
                               'cut': [bool(math.dist(c[0], m['a']) > 5), bool(math.dist(c[1], m['b']) > 5)]})
            if 1 <= len(mm) <= MAXM:
                out.append((box, mm))
            y += step
        x += step
    return out


def render_tile(v, box, path):
    import pymupdf
    x0, x1, y0, y1 = box
    px0, px1 = v['x0'] + x0 / v['k'], v['x0'] + x1 / v['k']
    py0, py1 = v['cl_y'] - y1 / v['k'], v['cl_y'] - y0 / v['k']
    page = pymupdf.open(v['pdf'])[v['page'] - 1]
    # the tool's page coordinates are the displayed (rotated) page, the same space PyMuPDF uses for clip
    pix = page.get_pixmap(matrix=pymupdf.Matrix(ZOOM, ZOOM), clip=pymupdf.Rect(px0, py0, px1, py1), colorspace=pymupdf.csGRAY)
    pix.save(path)


def shifted(v, members, log=print):
    """registered copy of the view (x0 / cl_y moved by the best shift) or None when the reference does not sit on the drawing"""
    h, dx, dy = register(v, members)
    log(f"register {v['name']} ({os.path.basename(v['pdf'])}): {len(members)} members, hit {h:.2f} at dX {dx:+.0f} dY {dy:+.0f} mm" + ('' if h >= MIN_HIT else ' -> NOT USED'))
    if h < MIN_HIT:
        return None
    return dict(v, x0=v['x0'] - dx / v['k'], cl_y=v['cl_y'] + dy / v['k'], reg={'hit': round(h, 3), 'dX': round(dx), 'dY': round(dy)})


PAIR_Q = ("{core}\n\nThis image is one tile of the deck plan '{name}' (deck {z} A/B). The tile covers ship X {x0:.0f}..{x1:.0f} mm "
          "(X from the frame table, left -> right) and OFF C.L Y {y0:.0f}..{y1:.0f} mm (port up). Sheet notes: {notes}.\n"
          "Return ONLY JSON: {{\"members\": [{{\"id\",\"kind\",\"sec\",\"a\":[X,Y],\"b\":[X,Y],\"cut\":[a_cut,b_cut]}}]}} - "
          "every girder, web, beam, carling and stiffener drawn in the tile, ends clipped to the tile (cut = continues outside), mm rounded to 10.")


def load_views(src):
    """ship_src/views.json; pdf / ref names are relative to the ship_src folder"""
    p = os.path.join(src, 'views.json')
    if not os.path.exists(p):
        return []
    v = json.load(open(p))
    for x in v:
        x['pdf'] = os.path.join(src, os.path.basename(x['pdf'])); x['ref'] = os.path.join(src, os.path.basename(x['ref']))
    return [x for x in v if os.path.exists(x['pdf']) and os.path.exists(x['ref'])]


def make_pair_samples(rec, r, views, out_dir, n, core=''):
    """rec(kind, img, prompt, answer) from ship_xml_kit.make_ship_samples. Returns number written."""
    os.makedirs(os.path.join(out_dir, 'images'), exist_ok=True)
    pool = []
    cache = {}
    for v in views:
        key = (v['ref'], v['z_mm'])
        if key not in cache:
            cache[key] = deck_members(v['ref'], v['z_mm'])
        v = shifted(v, cache[key])
        if v is None:
            continue
        for box, mm in tiles_for_view(v, cache[key]):
            pool.append((v, box, mm))
    r.shuffle(pool)
    made = 0
    for i, (v, box, mm) in enumerate(pool[:n]):
        img = f'images/pair{i:05d}.png'
        try:
            render_tile(v, box, os.path.join(out_dir, img))
        except Exception as e:
            print('tile skipped', v['name'], e)
            continue
        q = PAIR_Q.format(core=core, name=v['name'], z=v['z_mm'], x0=box[0], x1=box[1], y0=box[2], y1=box[3],
                          notes=json.dumps(v.get('notes', {})))
        if rec('ship_drawing_pair', img, q, json.dumps({'members': mm}, separators=(',', ':'))):
            made += 1
    print(f'drawing pairs: {made} written ({len(pool)} tiles available)')
    return made


def check(views, out='pair_check', k=4, seed=0):
    """draw the reference members over k tiles (red) - alignment check before training"""
    from PIL import Image, ImageDraw
    os.makedirs(out, exist_ok=True)
    r = random.Random(seed)
    for i, v in enumerate(views):
        mem = deck_members(v['ref'], v['z_mm'])
        v = shifted(v, mem)
        if v is None:
            continue
        tl = tiles_for_view(v, mem)
        for j, (box, mm) in enumerate(r.sample(tl, min(k, len(tl)))):
            p = os.path.join(out, f"{i:02d}_{v['name'].replace(' ', '_').replace('.', '')}_{j}.png")
            render_tile(v, box, p)
            im = Image.open(p).convert('RGB'); d = ImageDraw.Draw(im)
            s = ZOOM / v['k']
            to = lambda P: ((P[0] - box[0]) * s, (box[3] - P[1]) * s)
            for m in mm:
                d.line([to(m['a']), to(m['b'])], fill=(255, 0, 0), width=3)
            im.save(p)
        print(v['name'], len(mem), 'members,', len(tl), 'tiles')


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--views', default='ship_src/views.json')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--out', default='pair_check')
    a = ap.parse_args()
    if a.check:
        check(load_views(os.path.dirname(a.views) or '.'), a.out)
