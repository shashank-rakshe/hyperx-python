"""
Structure (member) models: compare two versions member by member, and turn a structure model into plates + beams for
the mesher.

Input: a "structure JSON" - the dict a ship-XML reader returns (e.g. your private plugin's xml_to_members):
  {"sections": {sid: {"type": "FlatBar", "H", "t"} | {"type": "LBar", "H", "W", "tw", "tf"} | {"type": "TBar", "H", "t", "wf", "tf"}},
   "blocks": [{"id", "panels": [{"id", "cs": {"origin", "uaxis", "waxis"}, "plates": [{"name", "thk", "grade", "contour": [[u,v],..]}],
                                  "holes": [{"contour"}], "stiffeners": [{"name", "sec", "grade", "trace": [[u,v],[u,v]], "incl": [u,v,w]}],
                                  "brackets": [{"name", "thk", "cs", "contour"}]}]}]}
Panel coordinates: point = origin + u * U + v * V with V = W x U (W = panel normal).
XML files are read through a plugin function xml_to_members(path) (load your plugin with --plugin); JSON is read directly.
"""
import json
import numpy as np


# ====================================================================== geometry
def _frame(cs):
    o, u, w = (np.array(cs[k], float) for k in ('origin', 'uaxis', 'waxis'))
    u, w = u / np.linalg.norm(u), w / np.linalg.norm(w)
    return o, u, np.cross(w, u), w


def _to3(cs, pts):
    o, u, v, _ = _frame(cs)
    return [o + p[0] * u + p[1] * v for p in pts]


def _open(c):
    c = [list(p) for p in c]
    return c[:-1] if len(c) > 1 and np.allclose(c[0], c[-1]) else c


def profile_from_section(sec):
    t = sec.get('type')
    if t == 'FlatBar':
        return {'type': 'FlatBar', 'h': sec['H'], 't': sec['t']}
    if t == 'LBar':
        return {'type': 'LBar', 'h': sec['H'], 't': sec['tw'], 'bf': sec['W'], 'tf': sec['tf']}
    if t == 'TBar':
        return {'type': 'TBar', 'h': sec['H'], 't': sec['t'], 'bf': sec['wf'], 'tf': sec['tf']}
    p = [float(x) for x in (sec.get('params') or [100.0, 10.0])]
    if len(p) == 3:                                     # angle H x W x t (one thickness)
        return {'type': 'LBar', 'h': p[0], 't': p[2], 'bf': p[1], 'tf': p[2]}
    return {'type': 'FlatBar', 'h': p[0], 't': p[-1], 'approx': True}


def iter_items(model):
    """flat list of plates / stiffeners / brackets / holes with 3D geometry (for comparing)"""
    secs = model.get('sections', {})
    for b in model.get('blocks', []):
        for p in b.get('panels', []):
            cs = p['cs']
            for pl in p.get('plates', []):
                P = np.array(_to3(cs, _open(pl['contour'])))
                yield {'kind': 'plate', 'panel': p['id'], 'name': pl.get('name'), 'thk': pl.get('thk'), 'grade': pl.get('grade'),
                       'c': P.mean(0), 'area': _area3(P), 'pts': P}
            for h in p.get('holes', []):
                P = np.array(_to3(cs, _open(h['contour'])))
                yield {'kind': 'opening', 'panel': p['id'], 'name': h.get('rule') or 'opening', 'c': P.mean(0), 'area': _area3(P), 'pts': P}
            for s in p.get('stiffeners', []):
                a, bb = _to3(cs, s['trace'][:1] + s['trace'][-1:])
                yield {'kind': 'stiffener', 'panel': p['id'], 'name': s.get('name'), 'sec': s.get('sec'), 'grade': s.get('grade'),
                       'a': a, 'b': bb, 'c': (a + bb) / 2, 'len': float(np.linalg.norm(bb - a)), 'section': secs.get(s.get('sec'), {})}
            for br in p.get('brackets', []):
                P = np.array(_to3(br.get('cs') or cs, _open(br['contour'])))
                yield {'kind': 'bracket', 'panel': p['id'], 'name': br.get('name'), 'thk': br.get('thk'), 'grade': br.get('grade'),
                       'c': P.mean(0), 'area': _area3(P), 'pts': P}


def _area3(P):
    n = np.zeros(3)
    for i in range(len(P)):
        n += np.cross(P[i], P[(i + 1) % len(P)])
    return float(np.linalg.norm(n) / 2)


# ====================================================================== structure -> plates + beams
def to_plates(model, default_t=10.0):
    plates, beams, notes = [], [], []
    secs = model.get('sections', {})
    for b in model.get('blocks', []):
        for p in b.get('panels', []):
            cs = p['cs']
            _, _, _, w = _frame(cs)
            holes3 = [(_to3(cs, _open(h['contour'])), np.array(_open(h['contour'])).mean(0)) for h in p.get('holes', [])]
            for k, pl in enumerate(p.get('plates', [])):
                C = np.array(_open(pl['contour']))
                mine = [H for H, c2 in holes3 if _in2(c2, C)]
                plates.append({'id': f"{p['id']}/{pl.get('name') or k}", 'group': p['id'], 't': float(pl.get('thk') or default_t),
                               'outline': [list(map(float, x)) for x in _to3(cs, C)], 'holes': [[list(map(float, x)) for x in H] for H in mine]})
            if not p.get('plates') and p.get('boundary'):
                plates.append({'id': p['id'], 'group': p['id'], 't': default_t, 'outline': [list(map(float, x)) for x in _to3(cs, _open(p['boundary']))],
                               'holes': [[list(map(float, x)) for x in H] for H, _ in holes3]})
                notes.append(f"panel {p['id']}: no plates given, the boundary was used with t = {default_t:g} mm")
            for k, s in enumerate(p.get('stiffeners', [])):
                a, bb = _to3(cs, s['trace'][:1] + s['trace'][-1:])
                o, u, v, ww = _frame(cs)
                inc = s.get('incl') or [0, 0, 1]
                d = inc[0] * u + inc[1] * v + inc[2] * ww
                prof = profile_from_section(secs.get(s.get('sec'), {}))
                if prof.pop('approx', False):
                    notes.append(f"section {s.get('sec')}: unknown shape, modelled as a flat bar")
                beams.append({'id': f"{p['id']}/{s.get('name') or k}", 'a': list(map(float, a)), 'b': list(map(float, bb)),
                              'profile': prof, 'normal': list(map(float, d / (np.linalg.norm(d) or 1)))})
            for k, br in enumerate(p.get('brackets', [])):
                plates.append({'id': f"{p['id']}/BR{k}", 'group': 'BRACKETS', 't': float(br.get('thk') or default_t),
                               'outline': [list(map(float, x)) for x in _to3(br.get('cs') or cs, _open(br['contour']))]})
    return {'plates': plates, 'beams': beams, 'notes': sorted(set(notes))}


def _in2(pt, P):
    c = False
    for i in range(len(P)):
        (x0, y0), (x1, y1) = P[i - 1], P[i]
        if (y0 > pt[1]) != (y1 > pt[1]) and pt[0] < x0 + (pt[1] - y0) * (x1 - x0) / (y1 - y0):
            c = not c
    return c


# ====================================================================== compare two versions
def compare(A, B, tol=5.0, move_tol=300.0):
    """match members of version A and B; report added / removed / changed (thickness, section, grade) / moved"""
    ia, ib = list(iter_items(A)), list(iter_items(B))
    used_b = set()
    changes = {'removed': [], 'added': [], 'changed': [], 'moved': []}
    same = 0

    def key_match(x, y):
        if x['kind'] != y['kind']:
            return False
        if x['kind'] == 'stiffener':
            return (np.linalg.norm(x['a'] - y['a']) <= tol and np.linalg.norm(x['b'] - y['b']) <= tol) or \
                   (np.linalg.norm(x['a'] - y['b']) <= tol and np.linalg.norm(x['b'] - y['a']) <= tol)
        return np.linalg.norm(x['c'] - y['c']) <= tol and abs(x['area'] - y['area']) <= 0.02 * max(x['area'], 1)

    # spatial hash on centres for speed
    grid = {}
    cell = max(move_tol, tol) * 2
    for j, y in enumerate(ib):
        grid.setdefault(tuple(np.floor(y['c'] / cell).astype(int)), []).append(j)

    def near(x):
        k = np.floor(x['c'] / cell).astype(int)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    yield from grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ())

    left = []
    for x in ia:
        hit = next((j for j in near(x) if j not in used_b and key_match(x, ib[j])), None)
        if hit is None:
            left.append(x)
            continue
        used_b.add(hit)
        y = ib[hit]
        diff = []
        for f in ('thk', 'sec', 'grade'):
            if f in x and x.get(f) != y.get(f):
                diff.append(f"{f} {x.get(f)} -> {y.get(f)}")
        if diff:
            changes['changed'].append(_desc(x, '; '.join(diff)))
        else:
            same += 1
    for x in left:                                     # moved: same kind + size, centre within move_tol
        best = None
        for j in near(x):
            y = ib[j]
            if j in used_b or y['kind'] != x['kind']:
                continue
            size_ok = abs(x.get('len', x.get('area', 0)) - y.get('len', y.get('area', 0))) <= 0.02 * max(x.get('len', x.get('area', 1)), 1)
            d = float(np.linalg.norm(y['c'] - x['c']))
            if size_ok and d <= move_tol and (best is None or d < best[0]):
                best = (d, j)
        if best:
            used_b.add(best[1])
            y = ib[best[1]]
            dv = (y['c'] - x['c']).round(1)
            changes['moved'].append(_desc(x, f"moved by {dv.tolist()} mm" + (f"; section {x.get('sec')} -> {y.get('sec')}" if x.get('sec') != y.get('sec') else '')))
        else:
            changes['removed'].append(_desc(x, 'only in A'))
    for j, y in enumerate(ib):
        if j not in used_b:
            changes['added'].append(_desc(y, 'only in B'))
    cnt = {k: len(v) for k, v in changes.items()}
    total = len(ia)
    text = (f'Compared {len(ia)} members of A with {len(ib)} members of B: {same} are the same, '
            f"{cnt['changed']} changed (thickness / section / grade), {cnt['moved']} moved, {cnt['removed']} removed and {cnt['added']} added.")
    by_kind = {}
    for k, v in changes.items():
        for d in v:
            by_kind.setdefault(d['kind'], {}).setdefault(k, 0)
            by_kind[d['kind']][k] += 1
    if by_kind:
        text += ' By type: ' + '; '.join(f"{kind}s: " + ', '.join(f'{n} {k}' for k, n in v.items()) for kind, v in by_kind.items()) + '.'
    return {'same': same, 'counts': cnt, 'by_type': by_kind, 'details': {k: v[:200] for k, v in changes.items()},
            'match_ratio': round(same / max(1, total), 4), 'plain_english': text}


def _desc(x, what):
    d = {'kind': x['kind'], 'panel': x['panel'], 'name': x.get('name'), 'at_mm': np.round(x['c'], 0).tolist(), 'change': what}
    if x['kind'] == 'stiffener':
        d['section'] = x.get('sec')
    elif 'thk' in x:
        d['thk'] = x.get('thk')
    return d


def load(path, converters=None):
    """JSON structure file, or XML through a plugin converter xml_to_members(path)"""
    if path.lower().endswith('.json'):
        return json.load(open(path, encoding='utf-8'))
    for fn in (converters or []):
        return fn(path)
    raise ValueError('reading this XML needs your ship plugin (start the app with --plugin <folder with ship_xml_kit.py>)')
