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
"""
import math, re

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
            texts.append({'text': txt, 'at': (ins[0], ins[1]), 'h': e.dxf.get('height', 1.0)})
    return lines, texts, 'drawing units'


def items(path, page=0):
    return _dxf_items(path) if path.lower().endswith('.dxf') else _pdf_items(path, page)


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
            'details': details, 'tolerance': tol, 'plain_english': text}


# ====================================================================== dimension arithmetic on a drawing
_EXPR = [
    # 24 x 101.6 = 2438.4   |   101.6P x 24 = 2438.4   |   6 * 800 = 4800
    (re.compile(r'(\d+(?:\.\d+)?)\s*P?\s*[xX×*]\s*(\d+(?:\.\d+)?)\s*P?\s*=\s*(\d+(?:\.\d+)?)'), lambda a, b: a * b, 'x'),
    # 6 @ 800 = 4800  (6 spaces at 800)
    (re.compile(r'(\d+(?:\.\d+)?)\s*@\s*(\d+(?:\.\d+)?)\s*=\s*(\d+(?:\.\d+)?)'), lambda a, b: a * b, '@'),
    # 1200 + 800 + 400 = 2400 (two or more terms)
    (re.compile(r'((?:\d+(?:\.\d+)?\s*\+\s*)+\d+(?:\.\d+)?)\s*=\s*(\d+(?:\.\d+)?)'), None, '+'),
]


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
    try:                                              # scan / image: optional OCR (Tesseract, Apache-2.0)
        import pytesseract
        from PIL import Image
        if low.endswith('.pdf'):
            import pypdfium2
            pdf = pypdfium2.PdfDocument(path)
            img = pdf[page].render(scale=300 / 72, grayscale=True).to_pil()
            pdf.close()
        else:
            img = Image.open(path)
        return pytesseract.image_to_string(img).splitlines(), 'OCR'
    except Exception:
        return [], 'no text (scanned drawing; install Tesseract + pytesseract for OCR)'


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
