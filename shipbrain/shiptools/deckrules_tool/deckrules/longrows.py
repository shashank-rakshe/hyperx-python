"""R-LG  longitudinal deck stiffeners from the end-on markers in the frame sections.

In a frame section every deck is a horizontal line. A longitudinal deck stiffener cuts that line, and the drawing
marks it with a small triangle (two ~5 pt bases at +-4 pt either side of the line, apex on the line). The centre of
the triangle = the stiffener's Y position. Rows found in one or more sections give, per deck, the list of
longitudinal stiffener rows; the X extent comes from the deck plan (plated area along the row).
"""
from collections import defaultdict
from . import section

BASE_MIN, BASE_MAX = 4.4, 5.6      # triangle base length (pt)
OFF_MIN, OFF_MAX = 3.3, 5.2        # distance of the base from the deck line (pt)
SECS = defaultdict(set)          # deck code -> X of every frame section that shows the deck
BIAS_MM = 0.0                      # measured against the 1005 reference: set in project settings if needed


def scan_view(page, v):
    """{deck code: [(Y_mm, n_bases), ...]} for one calibrated + centre-line-located section view"""
    x0, y0, x1, y1 = v.region
    out = {}
    for code, yy in v.decks.items():
        cand = [s for s in page.segs if BASE_MIN <= s.length <= BASE_MAX and abs(s.a[1] - s.b[1]) < 0.05
                and x0 < s.a[0] < x1 and OFF_MIN <= abs(s.a[1] - yy) <= OFF_MAX]
        cand.sort(key=lambda s: (s.a[0] + s.b[0]) / 2)
        cl = []
        for s in cand:
            x = (s.a[0] + s.b[0]) / 2
            if cl and abs(x - cl[-1][-1]) < 1.2:
                cl[-1].append(x)
            else:
                cl.append([x])
        rows = []
        for c in cl:
            x = sum(c) / len(c)
            rows.append((section.Y(v, x), len(c)))
        if rows:
            out[code] = rows
    return out


def collect(pdf, pages, settings, deck_z, wall_ys, sp):
    """aggregate over all sections: {code: {Y: [X frames]}}"""
    from . import pdfsrc, view as dview
    agg = defaultdict(lambda: defaultdict(list))
    SECS.clear()
    for pn in pages:
        page = pdfsrc.load_page(pdf, pn - 1)
        scale = dview.sheet_scale(page) or 100
        for v in section.find_views(page, sp):
            try:
                section.calibrate(page, v, scale, deck_z)
                tiers = section._tiers(v, deck_z)
                if not tiers:
                    continue
                section.locate_cl(page, v, tiers, wall_ys)
            except Exception:
                continue
            for code in v.decks:
                SECS[code].add(v.X)
            for code, rows in scan_view(page, v).items():
                for Y, n in rows:
                    agg[code][Y].append(v.X)
    return agg


def merge_rows(agg, tol=25.0):
    """merge nearly equal Y of different sections -> {code: [(Y, [X...]), ...]}"""
    res = {}
    for code, d in agg.items():
        items = sorted(d.items())
        grp = []
        for Y, xs in items:
            if grp and Y - grp[-1][-1][0] < tol:
                grp[-1].append((Y, xs))
            else:
                grp.append([(Y, xs)])
        res[code] = []
        for g in grp:
            ys = [y for y, _ in g for _ in range(1)]
            xs = sorted({x for _, l in g for x in l})
            res[code].append((sum(ys) / len(ys), xs))
    return res


def rows_for(pdf, settings, pages=None, cache=None):
    """rows of one drawing, cached in a json file: {code: [[Y, [X frames]], ...]}"""
    import json, os
    if cache and os.path.exists(cache):
        return json.load(open(cache))
    try:
        import pymupdf
        from . import run_elev, run_sec
        from .run import frame_x_fn
        n = len(pymupdf.open(pdf))
        sp0 = settings.get('frame_spacing_mm') or 800

        class _V:
            frame_space = sp0
        sp = frame_x_fn(settings, _V)
        deck_z = run_elev.deck_heights(pdf, n)
        wys = run_sec.wall_ys(pdf, range(1, n + 1))
        rows = merge_rows(collect(pdf, pages or range(1, n + 1), settings, deck_z, wys, sp))
    except Exception:
        rows = {}
    rows = {k: [[y, xs] for y, xs in v] for k, v in rows.items()}
    rows['__sections__'] = {k: sorted(v) for k, v in SECS.items()}
    if cache:
        json.dump(rows, open(cache, 'w'))
    return rows


def build_members(code, rows, footprint, openings, existing, section_, settings, bay=800.0):
    """longitudinal deck stiffeners (R-LG): one full-length stiffener per marker row, over the plated deck (footprint minus
    openings), minus what a drawn member already covers. Zero end clearance (owner rule): the piece runs to the opening /
    deck-edge moulded line."""
    from shapely.geometry import LineString
    from shapely.ops import unary_union
    min_len = float(settings.get('deck_long_min_len_mm', 500.0))
    minx, miny, maxx, maxy = footprint.bounds
    holes = unary_union([o['poly'] for o in openings]) if openings else None
    cover = [LineString([m['a'], m['b']]).buffer(30.0) for m in existing
             if abs(m['a'][1] - m['b'][1]) < 30 and abs(m['a'][0] - m['b'][0]) > 300]
    cov = unary_union(cover) if cover else None
    out = []
    for Y, xs in sorted(rows.get(code, [])):
        if code == '__sections__':
            continue
        if not (miny + 30 < Y < maxy - 30):
            continue
        ln = LineString([(minx - 10, Y), (maxx + 10, Y)]).intersection(footprint.buffer(-0.5))
        if ln.is_empty:
            continue
        mode = settings.get('deck_long_mode', 'span')
        if mode in ('span', 'bay', 'adj') and xs:
            xs_ = sorted(xs)
            secs = sorted(set(rows.get('__sections__', {}).get(code, [])) | set(xs_))
            if mode == 'adj' and len(secs) > 1:   # extent: from the marker section to the neighbouring frame sections (1005: 71% recall of the reference rows)
                segs_ = []
                for x in xs_:
                    i = secs.index(x)
                    if i > 0:
                        segs_.append(LineString([(secs[i - 1], Y), (x, Y)]))
                    if i < len(secs) - 1:
                        segs_.append(LineString([(x, Y), (secs[i + 1], Y)]))
            elif mode == 'span':      # extent: between consecutive frame sections that BOTH show the row (1005: 28% / 50% length precision/recall)
                segs_ = [LineString([(a, Y), (b, Y)]) for a, b in zip(xs_, xs_[1:])]
            else:                   # a bay either side of every section (1005: 21% / 17%)
                segs_ = [LineString([(x - bay, Y), (x + bay, Y)]) for x in xs_]
            if not segs_:
                continue
            ln = ln.intersection(unary_union(segs_))
            if ln.is_empty:
                continue
        if holes is not None:
            ln = ln.difference(holes.buffer(1.0))
        if cov is not None and not ln.is_empty:
            ln = ln.difference(cov)
        parts = [g for g in (ln.geoms if hasattr(ln, 'geoms') else [ln]) if g.geom_type == 'LineString']
        for g in parts:
            if g.length < min_len:
                continue
            (xa, ya), (xb, yb) = g.coords[0], g.coords[-1]
            out.append({'a': (round(xa, 1), round(Y, 1)), 'b': (round(xb, 1), round(Y, 1)), 'kind': 'beam',
                        'section': section_, 'o': 'H', 'thick_chain': False, 'line': LineString([(xa, Y), (xb, Y)]),
                        'evidence': [f"R-LG: end-on triangle marker on the {code} deck line in {len(xs)} frame section(s) "
                                     f"(X {', '.join(f'{x:g}' for x in xs[:4])}{'...' if len(xs) > 4 else ''}), row Y={Y:.0f}; "
                                     f"size = header DECK BEAM; "
                                     + {'adj': "extent ASSUMED = from the marker section to the neighbouring frame sections (confirm)",
                                        'span': "extent ASSUMED = between the frame sections that both show the row (confirm)",
                                        'bay': "extent ASSUMED = one frame bay either side of the section (confirm)"}.get(
                                            settings.get('deck_long_mode', 'span'), "extent = full plated length (confirm)")]})
    return out
