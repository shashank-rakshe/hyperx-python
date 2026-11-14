"""
Semantic comparison of two VECTOR drawings (PDF with real lines/text, or DXF): what changed in engineering terms,
not just which pixels differ.

Every item is classified first (generic drawing-reading practice):
  lines  -> style: solid / dashed, heavy / thin (stroke width), and length; DXF: layer + linetype
  text   -> number class: plate thickness, weld size (a weld size is never a plate thickness), section size (FB / HP /
            L / T / I), frame number, dimension, off-centre-line distance, elevation, mark/label, other text
Then items of A and B are matched by position (tolerance in drawing units) and the differences are reported:
  "line added / removed", "line style changed (solid -> dashed)", "text '12' -> '14' (plate thickness)", ...
Scanned PDFs have no vector content: use compare_drawings (image overlay) for those.

Like a CAD drawing-compare (ideas from AutoCAD's DWG Compare, own implementation), DXF / DWG also compare blocks and
their attribute values, dimension values, hatches, circles / arcs and layer settings; filters (ignore text, dimensions,
hatches, blocks, attributes, circles, layers...) and a tolerance; every change is numbered, changes near each other
share a revision cloud, and the result is written as
  <name>_changes.dxf  the new drawing + layers SB_REMOVED (red), SB_ADDED (green), SB_CHANGED (yellow), SB_CLOUDS
                      (magenta clouds with their numbers) - open it in AutoCAD next to the change list
  <name>_changes.csv  number, cloud, kind, what changed, location box
DWG files are turned into DXF first with the free ODA File Converter (shipbrain.dwg).
"""
import math, os, re

NUM_CLASSES = [
    ('weld size', re.compile(r'^(a|z|s)\s*=?\s*\d+(\.\d+)?$|^\d+(\.\d+)?\s*(a|z|fw|fillet)$|^\d+(\.\d+)?\s*typ\.?$', re.I)),
    ('section size', re.compile(r'^(fb|f\.b\.?|hp|hb|l|t|i|ip|ipe|hea|heb|ua|ia|bp)\s*[-\s]?\d+(\.\d+)?\s*[x*×]\s*\d+', re.I)),
    ('section size', re.compile(r'^\d+(\.\d+)?\s*[x*×]\s*\d+(\.\d+)?(\s*[x*×/+]\s*\d+(\.\d+)?)*\s*(fb|f\.b\.?|t|l|hp|bp)?$', re.I)),
    ('plate thickness', re.compile(r'^(t\s*=?\s*|pl\.?\s*|plate\s*)\d+(\.\d+)?(\s*(mm|ah|dh|eh|a|d))?$|^\d+(\.\d+)?\s*(t|pl|thk)$', re.I)),
    ('frame number', re.compile(r'^(fr|frame|#)\.?\s*-?\d+(\.\d+)?$', re.I)),
    ('off centre line', re.compile(r'(off\s*c\.?\s*l|from\s*c\.?\s*l)', re.I)),
    ('elevation', re.compile(r'^(el|abl|a/b|bl)\.?\s*[+-]?\d+', re.I)),
    ('dimension', re.compile(r'^\d{3,6}(\.\d+)?$')),
    ('small number', re.compile(r'^\d{1,2}(\.\d+)?$')),
]


def number_class(text):
    s = ' '.join(str(text).split())
    for name, rx in NUM_CLASSES:
        if rx.search(s):
            return name
    return 'label / other text'


# ------------------------------------------------------------------ extraction
def _pdf_items(path, page=0):
    import pdfplumber                                     # MIT (pdfminer.six)
    lines, texts = [], []
    with pdfplumber.open(path) as d:
        pg = d.pages[page]
        for o in pg.lines + pg.rects + pg.curves:
            w = round(float(o.get('linewidth') or 0.0), 2)
            dash = o.get('dash')
            dashed = bool(dash and dash[0])
            pts = o.get('pts') or []
            if o['object_type'] == 'rect':
                x0, x1, t, b = o['x0'], o['x1'], o['top'], o['bottom']
                pts = [(x0, t), (x1, t), (x1, b), (x0, b), (x0, t)]
            pts = [(float(x), float(y)) for x, y in pts]
            lines += [{'a': a_, 'b': b_, 'width': w, 'dashed': dashed, 'layer': ''} for a_, b_ in zip(pts, pts[1:])]
        for wd in pg.extract_words():
            texts.append({'text': wd['text'], 'at': ((wd['x0'] + wd['x1']) / 2, (wd['top'] + wd['bottom']) / 2), 'h': wd['bottom'] - wd['top']})
    return lines, texts, 'pt'


def _dxf_items(path):
    import ezdxf
    doc = ezdxf.readfile(path)
    lines, texts = [], []
    for e in doc.modelspace():
        t = e.dxftype()
        lt = (e.dxf.get('linetype') or 'BYLAYER').upper()
        if lt == 'BYLAYER':
            try:
                lt = doc.layers.get(e.dxf.layer).dxf.linetype.upper()
            except Exception:
                lt = 'CONTINUOUS'
        dashed = lt not in ('CONTINUOUS', 'BYBLOCK')
        w = e.dxf.get('lineweight', -1)
        if t == 'LINE':
            lines.append({'a': tuple(e.dxf.start)[:2], 'b': tuple(e.dxf.end)[:2], 'width': w, 'dashed': dashed, 'layer': e.dxf.layer})
        elif t == 'LWPOLYLINE':
            P = [tuple(p)[:2] for p in e.get_points('xy')]
            if e.closed:
                P.append(P[0])
            lines += [{'a': a, 'b': b, 'width': w, 'dashed': dashed, 'layer': e.dxf.layer} for a, b in zip(P, P[1:])]
        elif t in ('TEXT', 'MTEXT'):
            txt = e.dxf.text if t == 'TEXT' else e.plain_text()
            ins = e.dxf.insert
            texts.append({'text': txt, 'at': (ins[0], ins[1]), 'h': e.dxf.get('height', 1.0), 'layer': e.dxf.layer})
    return lines, texts, 'drawing units'


def items(path, page=0):
    from .dwg import drawing_file
    path = drawing_file(path)
    return _dxf_items(path) if path.lower().endswith('.dxf') else _pdf_items(path, page)


def _dxf_extra(path):
    """blocks (+ attribute values), dimensions (their values), hatches, circles / arcs, layer settings of a DXF"""
    import ezdxf
    doc = ezdxf.readfile(path)
    blocks, attribs, dims, hatches, circles = [], [], [], [], []
    for e in doc.modelspace():
        t = e.dxftype()
        lay = e.dxf.get('layer', '0')
        if t == 'INSERT':
            ins = e.dxf.insert
            blocks.append({'name': e.dxf.name, 'at': (ins[0], ins[1]), 'rot': round(e.dxf.get('rotation', 0.0), 3),
                           'scale': (round(e.dxf.get('xscale', 1.0), 6), round(e.dxf.get('yscale', 1.0), 6)), 'layer': lay})
            for a in getattr(e, 'attribs', []):
                p = a.dxf.get('insert', ins)
                attribs.append({'text': a.dxf.text, 'tag': a.dxf.tag, 'at': (p[0], p[1]), 'h': a.dxf.get('height', 1.0), 'block': e.dxf.name})
        elif t == 'DIMENSION':
            try:
                val = e.get_measurement()
                val = round(float(val if not hasattr(val, 'magnitude') else val.magnitude), 4)
            except Exception:
                val = None
            txt = e.dxf.get('text', '<>')
            shown = txt.replace('<>', f'{val:g}' if val is not None else '') if txt not in ('', ' ') else (f'{val:g}' if val is not None else '')
            p = e.dxf.get('text_midpoint', None) or e.dxf.get('defpoint', (0, 0, 0))
            dims.append({'text': shown or '?', 'value': val, 'at': (p[0], p[1]), 'h': 1.0, 'layer': lay})
        elif t == 'HATCH':
            try:
                pts = [v for path_ in e.paths for v in (path_.vertices if hasattr(path_, 'vertices') else
                                                        [ed.start for ed in getattr(path_, 'edges', []) if hasattr(ed, 'start')])]
            except Exception:
                pts = []
            if pts:
                xs, ys = [p[0] for p in pts], [p[1] for p in pts]
                hatches.append({'pattern': e.dxf.pattern_name, 'box': (min(xs), min(ys), max(xs), max(ys)), 'layer': lay})
        elif t in ('CIRCLE', 'ARC'):
            c = e.dxf.center
            circles.append({'c': (c[0], c[1]), 'r': e.dxf.radius, 'arc': (round(e.dxf.start_angle, 2), round(e.dxf.end_angle, 2)) if t == 'ARC' else None,
                            'layer': lay})
    layers = {}
    for l in doc.layers:
        layers[l.dxf.name] = {'color': l.dxf.get('color', 7), 'linetype': l.dxf.get('linetype', 'CONTINUOUS'),
                              'on': l.is_on(), 'frozen': l.is_frozen()}
    return {'blocks': blocks, 'attribs': attribs, 'dims': dims, 'hatches': hatches, 'circles': circles, 'layers': layers}


# ------------------------------------------------------------------ matching
def _style(l):
    heavy = (l['width'] or 0) >= 0.5 if isinstance(l['width'], float) else (l['width'] or 0) >= 50
    return ('dashed' if l['dashed'] else 'solid') + (', heavy' if heavy else ', thin') + (f", layer {l['layer']}" if l['layer'] else '')


def _key_line(l, tol):
    a, b = sorted([l['a'], l['b']])
    return a, b


def _near(p, q, tol):
    return abs(p[0] - q[0]) <= tol and abs(p[1] - q[1]) <= tol


def compare_vector(a, b, page_a=0, page_b=0, tol=None, max_list=60):
    la, ta, unit = items(a, page_a)
    lb, tb, _ = items(b, page_b)
    allp = [p for l in la + lb for p in (l['a'], l['b'])] or [(0, 0), (1, 1)]
    span = max(max(p[0] for p in allp) - min(p[0] for p in allp), max(p[1] for p in allp) - min(p[1] for p in allp))
    tol = tol or max(1e-6, span * 0.002)
    return {k: v for k, v in _compare_lists(la, ta, lb, tb, unit, tol, max_list).items() if not k.startswith('_')}


def _compare_lists(la, ta, lb, tb, unit, tol, max_list=60):
    # lines
    cell = tol * 4
    grid = {}
    for j, l in enumerate(lb):
        a_, b_ = _key_line(l, tol)
        grid.setdefault((round(a_[0] / cell), round(a_[1] / cell)), []).append(j)
    used, removed, restyled = set(), [], []
    for l in la:
        a_, b_ = _key_line(l, tol)
        hit = None
        cx, cy = round(a_[0] / cell), round(a_[1] / cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cx + dx, cy + dy), ()):
                    if j in used:
                        continue
                    a2, b2 = _key_line(lb[j], tol)
                    if _near(a_, a2, tol) and _near(b_, b2, tol):
                        hit = j
                        break
                if hit is not None:
                    break
            if hit is not None:
                break
        if hit is None:
            removed.append(l)
            continue
        used.add(hit)
        if _style(l) != _style(lb[hit]):
            restyled.append((l, lb[hit]))
    added = [l for j, l in enumerate(lb) if j not in used]
    # texts
    tused, tchanged, tremoved = set(), [], []
    ttol = tol * 3
    for t in ta:
        hit = next((j for j, u in enumerate(tb) if j not in tused and _near(t['at'], u['at'], ttol)), None)
        if hit is None:
            tremoved.append(t)
            continue
        tused.add(hit)
        if t['text'].strip() != tb[hit]['text'].strip():
            tchanged.append((t, tb[hit]))
    tadded = [u for j, u in enumerate(tb) if j not in tused]
    L = lambda l: math.dist(l['a'], l['b'])
    fmt = lambda p: f'({p[0]:.0f}, {p[1]:.0f})'
    details = ([f"line removed: {fmt(l['a'])}-{fmt(l['b'])}, {L(l):.0f} {unit} long, {_style(l)}" for l in removed[:max_list]]
               + [f"line added: {fmt(l['a'])}-{fmt(l['b'])}, {L(l):.0f} {unit} long, {_style(l)}" for l in added[:max_list]]
               + [f"line style changed at {fmt(x['a'])}-{fmt(x['b'])}: {_style(x)} -> {_style(y)}" for x, y in restyled[:max_list]]
               + [f"text changed at {fmt(x['at'])}: '{x['text']}' -> '{y['text']}' ({number_class(y['text'])})" for x, y in tchanged[:max_list]]
               + [f"text removed at {fmt(x['at'])}: '{x['text']}' ({number_class(x['text'])})" for x in tremoved[:max_list]]
               + [f"text added at {fmt(x['at'])}: '{x['text']}' ({number_class(x['text'])})" for x in tadded[:max_list]])
    by_class = {}
    for x, y in tchanged:
        c = number_class(y['text'])
        by_class[c] = by_class.get(c, 0) + 1
    text = (f'Vector comparison: {len(la)} lines and {len(ta)} texts in A, {len(lb)} lines and {len(tb)} texts in B. '
            f'{len(removed)} line(s) removed, {len(added)} added, {len(restyled)} changed style; '
            f'{len(tchanged)} text(s) changed' + (f" ({', '.join(f'{n} {c}' for c, n in by_class.items())})" if by_class else '')
            + f', {len(tremoved)} removed, {len(tadded)} added.')
    if not (removed or added or restyled or tchanged or tremoved or tadded):
        text += ' The drawings are the same.'
    return {'lines': {'removed': len(removed), 'added': len(added), 'style_changed': len(restyled)},
            'texts': {'changed': len(tchanged), 'removed': len(tremoved), 'added': len(tadded), 'changed_by_class': by_class},
            'details': details, 'tolerance': tol, 'plain_english': text,
            '_removed': removed, '_added': added, '_restyled': restyled, '_tchanged': tchanged, '_tremoved': tremoved, '_tadded': tadded}


# ====================================================================== full compare: filters, numbered changes, clouds, DXF / CSV
IGNORABLE = ('lines', 'text', 'dimensions', 'attributes', 'blocks', 'hatches', 'circles', 'layers')


def _layer_ok(layer, pats):
    import fnmatch
    return not any(fnmatch.fnmatch(str(layer or '').upper(), p.upper()) for p in pats or ())


def _match(xa, xb, tol, same):
    """pair items of A and B that sit within tol and pass same(x, y) -> (removed, added, pairs)"""
    used, removed, pairs = set(), [], []
    for x in xa:
        j = next((j for j, y in enumerate(xb) if j not in used and _near(x['at'], y['at'], tol) and same(x, y)), None)
        if j is None:
            removed.append(x)
        else:
            used.add(j)
            pairs.append((x, xb[j]))
    return removed, [y for j, y in enumerate(xb) if j not in used], pairs


def _cloud_path(box, arc):
    """closed revision-cloud polyline around a box: points + bulges (arcs bulge outwards)"""
    x0, y0, x1, y1 = box
    pts = []
    for (ax, ay), (bx, by) in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        n = max(2, int(math.ceil(math.hypot(bx - ax, by - ay) / arc)))
        pts += [(ax + (bx - ax) * k / n, ay + (by - ay) * k / n) for k in range(n)]
    return pts


def compare_full(a, b, page_a=0, page_b=0, tol=None, ignore=(), ignore_layers=(), out_base=None, max_list=60):
    """vector compare of two drawings (PDF / DXF / DWG) with filters, numbered changes, revision clouds, DXF + CSV result"""
    from .dwg import drawing_file
    A, B = drawing_file(a), drawing_file(b)
    names = {'lines': 'line', 'line': 'line', 'texts': 'text', 'text': 'text', 'dimensions': 'dimension', 'dimension': 'dimension',
             'dims': 'dimension', 'hatches': 'hatch', 'hatch': 'hatch', 'blocks': 'block', 'block': 'block', 'attributes': 'attribute',
             'attribute': 'attribute', 'attribs': 'attribute', 'circles': 'circle', 'circle': 'circle', 'arcs': 'circle',
             'layers': 'layer', 'layer': 'layer'}
    ign = {names.get(str(x).lower().strip(), str(x).lower().strip()) for x in (ignore or ())}
    la, ta, unit = items(A, page_a)
    lb, tb, _ = items(B, page_b)
    pdf = not A.lower().endswith('.dxf')
    keep = lambda xs: [x for x in xs if _layer_ok(x.get('layer'), ignore_layers)]
    la, lb, ta, tb = keep(la), keep(lb), keep(ta), keep(tb)
    if 'line' in ign:
        la, lb = [], []
    if 'text' in ign:
        ta, tb = [], []
    allp = [p for l in la + lb for p in (l['a'], l['b'])] + [t['at'] for t in ta + tb] or [(0, 0), (1, 1)]
    span = max(max(p[0] for p in allp) - min(p[0] for p in allp), max(p[1] for p in allp) - min(p[1] for p in allp), 1e-9)
    tol = tol or max(1e-6, span * 0.002)
    old = _compare_lists(la, ta, lb, tb, unit, tol, max_list)                  # lines + texts exactly as before
    changes = []

    def add(kind, what, pts, src=None):
        pts = [p for p in pts if p is not None]
        box = (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)) if pts else None
        changes.append({'kind': kind, 'what': what, 'box': box, 'src': src})
    for l in old['_removed']:
        add('line removed', f"line removed, {math.dist(l['a'], l['b']):.0f} {unit} long, {_style(l)}", [l['a'], l['b']], ('line', l, 'A'))
    for l in old['_added']:
        add('line added', f"line added, {math.dist(l['a'], l['b']):.0f} {unit} long, {_style(l)}", [l['a'], l['b']], ('line', l, 'B'))
    for x, y in old['_restyled']:
        add('line style', f"line style {_style(x)} -> {_style(y)}", [y['a'], y['b']], ('line', y, 'C'))
    for x, y in old['_tchanged']:
        add('text changed', f"text '{x['text']}' -> '{y['text']}' ({number_class(y['text'])})", [y['at']], ('text', y, 'C', x['text']))
    for x in old['_tremoved']:
        add('text removed', f"text removed '{x['text']}' ({number_class(x['text'])})", [x['at']], ('text', x, 'A'))
    for y in old['_tadded']:
        add('text added', f"text added '{y['text']}' ({number_class(y['text'])})", [y['at']], ('text', y, 'B'))
    if not pdf and B.lower().endswith('.dxf'):
        ea, eb = _dxf_extra(A), _dxf_extra(B)
        for k in ('blocks', 'attribs', 'dims', 'hatches', 'circles'):
            ea[k], eb[k] = keep(ea[k]), keep(eb[k])
        if 'dimension' not in ign:
            r_, a_, p_ = _match(ea['dims'], eb['dims'], tol * 3, lambda x, y: True)
            for x in list(r_):                     # a dimension whose value changed has moved its text: pair the near ones
                j = min(range(len(a_)), key=lambda j: math.dist(x['at'], a_[j]['at']), default=None)
                if j is not None and math.dist(x['at'], a_[j]['at']) < span * 0.05:
                    p_.append((x, a_.pop(j)))
                    r_.remove(x)
            for x, y in p_:
                if x['text'] != y['text']:
                    add('dimension changed', f"dimension {x['text']} -> {y['text']}", [y['at']], ('text', y, 'C', x['text']))
            for x in r_:
                add('dimension removed', f"dimension {x['text']} removed", [x['at']], ('text', x, 'A'))
            for y in a_:
                add('dimension added', f"dimension {y['text']} added", [y['at']], ('text', y, 'B'))
        if 'attribute' not in ign:
            r_, a_, p_ = _match(ea['attribs'], eb['attribs'], tol * 3, lambda x, y: x['tag'] == y['tag'])
            for x, y in p_:
                if x['text'] != y['text']:
                    add('attribute changed', f"{y['block']} {y['tag']}: '{x['text']}' -> '{y['text']}'", [y['at']], ('text', y, 'C', x['text']))
        if 'block' not in ign:
            r_, a_, p_ = _match(ea['blocks'], eb['blocks'], tol, lambda x, y: x['name'] == y['name'])
            moved = []
            for x in list(r_):                                 # same block nearby -> moved, not removed + added
                j = next((j for j, y in enumerate(a_) if y['name'] == x['name'] and math.dist(x['at'], y['at']) < span * 0.05), None)
                if j is not None:
                    moved.append((x, a_.pop(j)))
                    r_.remove(x)
            for x, y in moved:
                add('block moved', f"block {x['name']} moved {math.dist(x['at'], y['at']):.1f} {unit}", [x['at'], y['at']], ('block', y, 'C'))
            for x, y in p_:
                if x['rot'] != y['rot'] or x['scale'] != y['scale']:
                    add('block changed', f"block {x['name']}: rotation {x['rot']} -> {y['rot']}, scale {x['scale']} -> {y['scale']}",
                        [y['at']], ('block', y, 'C'))
            for x in r_:
                add('block removed', f"block {x['name']} removed", [x['at']], ('block', x, 'A'))
            for y in a_:
                add('block added', f"block {y['name']} added", [y['at']], ('block', y, 'B'))
        if 'circle' not in ign:
            ca = [dict(c, at=c['c']) for c in ea['circles']]
            cb = [dict(c, at=c['c']) for c in eb['circles']]
            r_, a_, p_ = _match(ca, cb, tol, lambda x, y: abs(x['r'] - y['r']) <= tol and x['arc'] == y['arc'])
            for x in r_:
                add('circle removed', f"{'arc' if x['arc'] else 'circle'} R{x['r']:g} removed",
                    [(x['c'][0] - x['r'], x['c'][1] - x['r']), (x['c'][0] + x['r'], x['c'][1] + x['r'])], ('circle', x, 'A'))
            for y in a_:
                add('circle added', f"{'arc' if y['arc'] else 'circle'} R{y['r']:g} added",
                    [(y['c'][0] - y['r'], y['c'][1] - y['r']), (y['c'][0] + y['r'], y['c'][1] + y['r'])], ('circle', y, 'B'))
        if 'hatch' not in ign:
            ha = [dict(h, at=h['box'][:2]) for h in ea['hatches']]
            hb = [dict(h, at=h['box'][:2]) for h in eb['hatches']]
            r_, a_, p_ = _match(ha, hb, tol, lambda x, y: _near(x['box'][2:], y['box'][2:], tol))
            for x, y in p_:
                if x['pattern'] != y['pattern']:
                    add('hatch changed', f"hatch {x['pattern']} -> {y['pattern']}", [y['box'][:2], y['box'][2:]], ('box', y['box'], 'C'))
            for x in r_:
                add('hatch removed', f"hatch {x['pattern']} removed", [x['box'][:2], x['box'][2:]], ('box', x['box'], 'A'))
            for y in a_:
                add('hatch added', f"hatch {y['pattern']} added", [y['box'][:2], y['box'][2:]], ('box', y['box'], 'B'))
        if 'layer' not in ign:
            for n in sorted(set(ea['layers']) | set(eb['layers'])):
                if not _layer_ok(n, ignore_layers):
                    continue
                x, y = ea['layers'].get(n), eb['layers'].get(n)
                if x is None:
                    add('layer added', f'layer {n} added', [])
                elif y is None:
                    add('layer removed', f'layer {n} removed', [])
                elif x != y:
                    diff = ', '.join(f'{k} {x[k]} -> {y[k]}' for k in x if x[k] != y.get(k))
                    add('layer changed', f'layer {n}: {diff}', [])
    # number the changes, group the near ones into revision clouds
    gap = span * 0.03
    boxed = [c for c in changes if c['box']]
    parent = list(range(len(boxed)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for i in range(len(boxed)):
        bi = boxed[i]['box']
        for j in range(i + 1, len(boxed)):
            bj = boxed[j]['box']
            if bi[0] - gap <= bj[2] and bj[0] - gap <= bi[2] and bi[1] - gap <= bj[3] and bj[1] - gap <= bi[3]:
                parent[find(j)] = find(i)
    groups = {}
    for i, c in enumerate(boxed):
        groups.setdefault(find(i), []).append(c)
    clouds = []
    for k, (_, cs) in enumerate(sorted(groups.items(), key=lambda kv: (-max(c['box'][3] for c in kv[1]), min(c['box'][0] for c in kv[1]))), 1):
        box = (min(c['box'][0] for c in cs), min(c['box'][1] for c in cs), max(c['box'][2] for c in cs), max(c['box'][3] for c in cs))
        for c in cs:
            c['cloud'] = k
        clouds.append({'cloud': k, 'box': [round(v, 3) for v in box], 'changes': len(cs)})
    changes.sort(key=lambda c: (c.get('cloud', 10 ** 6), c['kind']))
    for n, c in enumerate(changes, 1):
        c['n'] = n
    files = []
    if out_base and changes:
        files = _write_report(changes, clouds, B, pdf, span, out_base)
    by_kind = {}
    for c in changes:
        by_kind[c['kind']] = by_kind.get(c['kind'], 0) + 1
    res = {k: v for k, v in old.items() if not k.startswith('_')}
    extra = [f"{c['kind']}: {c['what']}" for c in changes if c['kind'].split()[0] in ('block', 'dimension', 'attribute', 'hatch', 'circle', 'layer')]
    if extra:
        res['details'] = res['details'] + extra[:max_list]
        res['plain_english'] += ' Also: ' + ', '.join(f'{n} {k}' for k, n in by_kind.items() if k.split()[0] in
                                                      ('block', 'dimension', 'attribute', 'hatch', 'circle', 'layer')) + '.'
    res.update(changes=[{'n': c['n'], 'cloud': c.get('cloud'), 'kind': c['kind'], 'what': c['what'],
                         'box': [round(v, 3) for v in c['box']] if c['box'] else None} for c in changes[:300]],
               clouds=clouds, by_kind=by_kind, files=files, ignored=sorted(ign), ignored_layers=list(ignore_layers or ()))
    if changes:
        res['plain_english'] += f' {len(changes)} change(s) numbered in {len(clouds)} revision cloud(s).'
    return res


def _write_report(changes, clouds, B, pdf, span, out_base):
    """the new drawing + coloured change layers + numbered revision clouds (DXF) and the change list (CSV)"""
    import csv
    import ezdxf
    fy = (lambda p: (p[0], -p[1])) if pdf else (lambda p: (p[0], p[1]))     # PDF y runs down
    doc = ezdxf.readfile(B) if not pdf and B.lower().endswith('.dxf') else ezdxf.new('R2018')
    for name, col in (('SB_REMOVED', 1), ('SB_ADDED', 3), ('SB_CHANGED', 2), ('SB_CLOUDS', 6)):
        if name not in doc.layers:
            doc.layers.add(name, color=col)
    msp = doc.modelspace()
    th = span * 0.012
    lay = {'A': 'SB_REMOVED', 'B': 'SB_ADDED', 'C': 'SB_CHANGED'}
    for c in changes:
        src = c.get('src')
        if not src:
            continue
        kind, obj, side = src[0], src[1], src[2]
        L = {'layer': lay[side]}
        if kind == 'line':
            msp.add_line(fy(obj['a']), fy(obj['b']), dxfattribs=L)
        elif kind == 'text':
            txt = (f"{src[3]} -> {obj['text']}" if side == 'C' else obj['text'])
            msp.add_text(txt, height=th * 0.8, dxfattribs=L).set_placement(fy(obj['at']))
        elif kind == 'block':
            x, y = fy(obj['at'])
            msp.add_lwpolyline([(x - th, y - th), (x + th, y - th), (x + th, y + th), (x - th, y + th)], close=True, dxfattribs=L)
        elif kind == 'circle':
            msp.add_circle(fy(obj['c']), obj['r'], dxfattribs=L)
        elif kind == 'box':
            x0, y0, x1, y1 = obj
            msp.add_lwpolyline([fy((x0, y0)), fy((x1, y0)), fy((x1, y1)), fy((x0, y1))], close=True, dxfattribs=L)
    for cl in clouds:
        x0, y0, x1, y1 = cl['box']
        m = max(th * 1.5, 0.15 * max(x1 - x0, y1 - y0))
        box = (x0 - m, y0 - m, x1 + m, y1 + m)
        p0, p1 = fy(box[:2]), fy(box[2:])
        box = (min(p0[0], p1[0]), min(p0[1], p1[1]), max(p0[0], p1[0]), max(p0[1], p1[1]))
        pts = _cloud_path(box, max(th * 2, min(box[2] - box[0], box[3] - box[1]) / 4))
        msp.add_lwpolyline([(x, y, 0, 0, 0.45) for x, y in pts], format='xyseb', close=True, dxfattribs={'layer': 'SB_CLOUDS'})
        msp.add_text(str(cl['cloud']), height=th * 1.6, dxfattribs={'layer': 'SB_CLOUDS'}).set_placement((box[0], box[3] + th * 0.5))
    dxf_path, csv_path = out_base + '_changes.dxf', out_base + '_changes.csv'
    doc.saveas(dxf_path)
    with open(csv_path, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['n', 'cloud', 'kind', 'what', 'x0', 'y0', 'x1', 'y1'])
        for c in changes:
            w.writerow([c['n'], c.get('cloud', ''), c['kind'], c['what']] + ([round(v, 3) for v in c['box']] if c['box'] else ['', '', '', '']))
    return [dxf_path, csv_path]


# ====================================================================== dimension arithmetic on a drawing
_EXPR = [
    # 24 x 101.6 = 2438.4   |   101.6P x 24 = 2438.4   |   6 * 800 = 4800
    (re.compile(r'(\d+(?:\.\d+)?)\s*P?\s*[xX×*]\s*(\d+(?:\.\d+)?)\s*P?\s*=\s*(\d+(?:\.\d+)?)'), lambda a, b: a * b, 'x'),
    # 6 @ 800 = 4800  (6 spaces at 800)
    (re.compile(r'(\d+(?:\.\d+)?)\s*@\s*(\d+(?:\.\d+)?)\s*=\s*(\d+(?:\.\d+)?)'), lambda a, b: a * b, '@'),
    # 1200 + 800 + 400 = 2400 (two or more terms)
    (re.compile(r'((?:\d+(?:\.\d+)?\s*\+\s*)+\d+(?:\.\d+)?)\s*=\s*(\d+(?:\.\d+)?)'), None, '+'),
]


def _join_rows(lines):
    """OCR boxes -> text rows: boxes whose vertical centres are within half a text height are one row, read left to right"""
    items = []
    for l in lines:
        try:
            xs, ys = [p[0] for p in l.box], [p[1] for p in l.box]
        except TypeError:
            x0, y0, x1, y1 = l.box
            xs, ys = [x0, x1], [y0, y1]
        items.append((min(xs), (min(ys) + max(ys)) / 2, max(ys) - min(ys), max(xs), l.text))
    items.sort(key=lambda t: (t[1], t[0]))
    rows = []
    for it in items:
        if rows and abs(rows[-1][-1][1] - it[1]) <= 0.5 * max(it[2], rows[-1][-1][2], 1):
            rows[-1].append(it)
        else:
            rows.append([it])
    out = []
    for r in rows:
        r.sort(key=lambda t: t[0])
        txt, last_x1 = [], None
        for x0, _, _, x1, t in r:
            if last_x1 is not None and x0 < last_x1 - 2:          # overlapping duplicate box from tiling
                continue
            txt.append(t)
            last_x1 = x1
        out.append(' '.join(txt))
    return out


def drawing_texts(path, page=0):
    """text lines of a drawing: DXF texts, PDF text layer, or OCR (only if Tesseract is installed) for scans"""
    low = path.lower()
    if low.endswith('.dxf'):
        return [t['text'] for t in _dxf_items(path)[1]], 'dxf'
    if low.endswith('.pdf'):
        import pdfplumber
        with pdfplumber.open(path) as d:
            txt = d.pages[page].extract_text() or ''
        if txt.strip():
            return txt.splitlines(), 'pdf text layer'
    from PIL import Image
    if low.endswith('.pdf'):
        import pypdfium2
        pdf = pypdfium2.PdfDocument(path)
        img = pdf[page].render(scale=300 / 72, grayscale=True).to_pil()
        pdf.close()
    else:
        img = Image.open(path).convert('L')
    try:                                              # 1st choice: the ship drawing reader's OCR (tiled, drawing-tuned)
        import sys, numpy as np
        dr = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'shiptools', 'deckrules_tool')
        if dr not in sys.path:
            sys.path.insert(0, dr)
        from deckrules.ocr import OCR
        eng = OCR('auto')
        lines = eng.read_tiled(np.asarray(img))
        return _join_rows(lines), f'OCR ({eng.backend}, ship drawing reader)'
    except Exception:
        pass
    try:                                              # fallback: plain Tesseract
        import pytesseract
        return pytesseract.image_to_string(img).splitlines(), 'OCR (Tesseract)'
    except Exception:
        return [], 'no text (scanned drawing; install rapidocr-onnxruntime or Tesseract for OCR)'


def check_dimensions(path, page=0, tol=0.5, fix=None):
    """find sums and products written on a drawing (24 x 101.6 = 2438.4, 6 @ 800 = 4800, 1200 + 800 = 2000) and check them;
    also count the numbers by class (plate thickness, weld size, section size, ...)"""
    lines, how = drawing_texts(path, page)
    if fix:                                           # e.g. the ship tools' OCR label repair
        fixed = []
        for ln in lines:
            try:
                fixed.append(fix(str(ln)) or ln)
            except Exception:
                fixed.append(ln)
        lines = fixed
    checked, wrong = [], []
    for ln in lines:
        s = ' '.join(str(ln).split())
        for rx, fn, kind in _EXPR:
            for m in rx.finditer(s):
                if kind == '+':
                    val = sum(float(x) for x in re.split(r'\s*\+\s*', m.group(1)))
                    stated = float(m.group(2))
                else:
                    val, stated = fn(float(m.group(1)), float(m.group(2))), float(m.group(3))
                ok = abs(val - stated) <= max(tol, 1e-3 * abs(stated))
                rec = {'text': m.group(0), 'computed': round(val, 3), 'stated': stated, 'ok': ok}
                checked.append(rec)
                if not ok:
                    wrong.append(rec)
    classes = {}
    for ln in lines:
        for w in str(ln).split():
            c = number_class(w)
            if c != 'label / other text':
                classes[c] = classes.get(c, 0) + 1
    if not lines:
        text = f'No text could be read from this drawing: {how}.'
    else:
        text = (f'Read {len(lines)} text lines ({how}). Found {len(checked)} written calculation(s); '
                + ('all are correct.' if checked and not wrong else
                   f'{len(wrong)} do not add up: ' + '; '.join(f"'{w['text']}' should be {w['computed']:g}" for w in wrong[:10]) + '.'
                   if wrong else 'nothing to check.'))
    return {'source': how, 'lines': len(lines), 'checked': checked[:100], 'wrong': wrong[:100], 'numbers_by_class': classes,
            'plain_english': text}
