"""
Standard-part lookup from BOLTS (https://github.com/boltsparts/BOLTS_archive; parser GPL-3, data LGPL 2.1+): dimensions of bolts,
screws, nuts, washers, rolled steel sections (IPE, HEA, HEB, HEM, angles, channels, hollow sections), pipes and flanges, straight from
the standards' tables. Nothing is calculated or guessed: a value is either in the table or the answer is "not in the table".

    parts.find('hex bolt ISO 4017')              the classes that match (standard, name, group, free parameters, size range)
    parts.get('ISO 4017', 'M20', l=60)           one row: every dimension of the table as a plain dict (mm)
    parts.sizes('IPE')                           all sizes of a family
    parts.section_properties(row)                area and second moments of an I-section from its table dimensions (labelled approximate)
"""
import math, os, re, sys, warnings

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'bolts')
_repo = None
_index = None


def repo():
    global _repo
    if _repo is None:
        if ROOT not in sys.path:
            sys.path.insert(0, ROOT)
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            from bolttools.blt import Repository
            _repo = Repository(ROOT)
    return _repo


def _links(links, c):
    return links.get_dsts(c) if links.contains_src(c) else []


def _norm(s):
    return re.sub(r'[^a-z0-9.]', '', str(s).lower())


def index():
    """one entry per BOLTS class: id, collection, standards, names, description, table kind and keys"""
    global _index
    if _index is not None:
        return _index
    r = repo()
    coll_of = {}
    for cid, col in r.collections.items():
        for c in _links(r.collection_classes, col):
            coll_of[c.id] = cid
    out = []
    for cid, c in r.classes.items():
        stds = [s.standard.nice for s in _links(r.class_standards, c)]
        names = [n.name.nice for n in _links(r.class_names, c)]
        desc = [s.description for s in _links(r.class_standards, c)] + [n.description for n in _links(r.class_names, c)]
        p = c.parameters
        tab = p.tables[0] if p.tables else None
        t2 = p.tables2d[0] if p.tables2d else None
        keys = list(tab.data.keys()) if tab is not None else (list(t2.data.keys()) if t2 is not None else [])
        out.append({'id': cid, 'collection': coll_of.get(cid, ''), 'standards': stds, 'names': names, 'description': ' | '.join(sorted(set(desc))),
                    'free': list(p.free), 'table_key': tab.index if tab is not None else (t2.rowindex if t2 is not None else None),
                    'columns': list(tab.columns) if tab is not None else [], 'keys': keys,
                    'blob': _norm(' '.join([cid, coll_of.get(cid, '')] + stds + names + desc))})
    _index = out
    return out


def _tokens(q):
    return [t for t in re.split(r'[\s,;]+', q.strip()) if t]


def find(query, limit=8):
    """classes whose standard / name / description match the words of the query (best first)"""
    q = str(query).strip()
    ql = q.lower()
    scored = []
    toks = _tokens(ql)
    # a standard like "DIN 933" or "ISO 4017" is two tokens: also try joined pairs
    pairs = [_norm(a + b) for a, b in zip(toks, toks[1:])]
    synonyms = {'bolt': 'screw', 'bolts': 'screw', 'screws': 'screw', 'nuts': 'nut', 'washers': 'washer', 'hexagon': 'hex', 'rhs': 'hollow',
                'shs': 'hollow', 'chs': 'hollow', 'upn': 'channel', 'angle': 'lbeam', 'beam': 'ibeam', 'flanges': 'flange'}
    for e in index():
        s = 0.0
        for st in e['standards']:
            ns = _norm(st)
            if ns and any(p == ns or p in ns and len(p) >= 6 for p in pairs) or ns and _norm(ql) == ns:
                s += 10
        for t in toks:
            t = synonyms.get(t, t)
            nt = _norm(t)
            if len(nt) < 2:
                continue
            if nt in e['blob']:
                s += 2 if nt.isdigit() or len(nt) > 3 else 1
        if e['keys']:                                      # size named in the query ("IPE300", "M20")
            for k in e['keys']:
                if _norm(k) in [_norm(t) for t in toks] + pairs:
                    s += 6
                    break
        if s:
            scored.append((s, e))
    scored.sort(key=lambda x: (-x[0], x[1]['id']))
    res = []
    for s, e in scored[:limit]:
        res.append({'class': e['id'], 'collection': e['collection'], 'standards': e['standards'], 'name': e['names'][0] if e['names'] else '',
                    'description': e['description'], 'size_key': e['table_key'], 'other_parameters': [p for p in e['free'] if p != e['table_key']],
                    'sizes': (e['keys'][0] + ' ... ' + e['keys'][-1] + f" ({len(e['keys'])})") if e['keys'] else '', 'score': s})
    return res


def _class(ref):
    """a class by its BOLTS id, a standard (DIN 933) or - when that is unique - a name"""
    r = repo()
    if ref in r.classes:
        return r.classes[ref]
    n = _norm(ref)
    hits = [e for e in index() if any(_norm(s) == n for s in e['standards'])]
    if not hits:
        hits = [e for e in index() if any(_norm(s).replace('en', '').replace('din', '').replace('iso', '') == n.replace('en', '').replace('din', '').replace('iso', '')
                                          for s in e['standards']) or any(_norm(x) == n for x in e['names'])]
    if len({h['id'] for h in hits}) == 1:
        return r.classes[hits[0]['id']]
    if len({h['id'] for h in hits}) > 1:
        raise ValueError(f'"{ref}" matches several classes: ' + ', '.join(sorted({h['id'] for h in hits})))
    raise KeyError(f'no standard part "{ref}" in BOLTS (try find())')


def get(ref, key=None, **params):
    """the table row of one size as a dict. key = size in the table (M20, IPE300), params = other parameters of the class (l=60,
    thread_type='coarse'). Values are mm unless the class says otherwise (see 'units')."""
    c = _class(ref)
    p = c.parameters
    r = repo()
    stds = [s.standard.nice for s in _links(r.class_standards, c)]
    row = {'class': c.id, 'standards': stds}
    tab = p.tables[0] if p.tables else None
    t2 = p.tables2d[0] if p.tables2d else None
    idx = tab.index if tab is not None else (t2.rowindex if t2 is not None else None)
    keys = list(tab.data.keys()) if tab is not None else (list(t2.data.keys()) if t2 is not None else [])
    if idx and key is not None:
        nk = _norm(key)
        hit = [k for k in keys if _norm(k) == nk]
        if not hit:
            raise KeyError(f'size "{key}" is not in the table of {c.id}; sizes: {keys[0]} ... {keys[-1]} ({len(keys)} sizes)')
        key = hit[0]
    elif idx:
        raise KeyError(f'give the size ({idx}) of {c.id}; sizes: {", ".join(keys[:6])} ... {keys[-1]}')
    if idx:
        row[idx] = key
    if tab is not None:
        for col, v in zip(tab.columns, tab.data[key]):
            row[col] = v
    if t2 is not None:
        col = params.pop(t2.colindex, None) or p.defaults.get(t2.colindex)
        cols = list(t2.columns)
        hit = [x for x in cols if _norm(x) == _norm(col)] if col is not None else []
        if not hit:
            raise KeyError(f'{t2.colindex} "{col}" not in {cols}')
        row[t2.colindex] = hit[0]
        row[t2.result] = t2.data[key][cols.index(hit[0])]
    for pr, v in params.items():
        if pr in p.free and pr != idx:
            row[pr] = v
    coll = next((e['collection'] for e in index() if e['id'] == c.id), '')
    if 'l' in p.free and 'l' not in row and not (coll.startswith('profile') or coll in ('pipes', 'extrusions')):
        row['l'] = p.defaults.get('l')
    row = {k: (round(v, 6) if isinstance(v, float) else v) for k, v in row.items() if v is not None}
    unit = {k: (re.search(r'\((\w+)\)', str(p.types.get(k, ''))) or [None, None])[1] for k in row}
    inch = sorted(k for k, u in unit.items() if u == 'in')
    for k in inch:                                         # imperial classes (ASME): keep the table value and add the mm value
        row[k + '_mm'] = round(row[k] * 25.4, 3)
    row['units'] = 'inch (as in the standard), with *_mm in millimetres' if inch else 'mm'
    return row


def sizes(ref):
    c = _class(ref)
    p = c.parameters
    if p.tables:
        return list(p.tables[0].data.keys())
    if p.tables2d:
        return list(p.tables2d[0].data.keys())
    return []


def section_properties(row):
    """area, second moments and elastic moduli of an I / H section from h, b, tw, tf, r (parallel-flange, root fillets included)"""
    h, b, tw, tf, r = (float(row[k]) for k in ('h', 'b', 'tw', 'tf', 'r'))
    hw = h - 2 * tf
    A = 2 * b * tf + hw * tw + (4 - math.pi) * r * r
    Iy = (b * h ** 3 - (b - tw) * hw ** 3) / 12 + (4 - math.pi) * r * r * (hw / 2 - r * 0.2234) ** 2
    Iz = (2 * tf * b ** 3 + hw * tw ** 3) / 12 + (4 - math.pi) * r * r * (tw / 2 + r * 0.2234) ** 2
    return {'A_mm2': round(A, 1), 'Iy_mm4': round(Iy), 'Iz_mm4': round(Iz), 'Wel_y_mm3': round(Iy / (h / 2)), 'Wel_z_mm3': round(Iz / (b / 2)),
            'mass_kg_per_m': round(A * 7850e-6, 2), 'note': 'computed from the table dimensions (root fillets included, toe radii ignored): within about 1 % of the catalogue'}
