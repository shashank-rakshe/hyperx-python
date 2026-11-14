"""
Ship-structure programs: a few named building blocks with a few numbers, turned into plates + 1D stiffeners by code.

Why (lesson of CAD2Program, Manycore 2025): a small model is far more reliable - and on a CPU far faster - writing a
short program of known primitives than long coordinate lists. One line per primitive, `name key=value ...`, `;` or new
lines between them. All sizes in mm; the deck lies at z, members hang below it (-Z) unless up=1.

  deck       L B t [x0 y0 z]                 deck plate from (x0, y0) to (x0+L, y0+B) at height z
  opening    x y w h                         rectangular opening in the deck (corner x, y; size w x h)
  girder     y h t [x0 x1]                   longitudinal web plate under the deck at Y = y (default full length)
  web        x h t [y0 y1]                   transverse web frame under the deck at X = x (default full breadth)
  bulkhead   x h t                           transverse bulkhead under the deck at X = x
  lbulkhead  y h t                           longitudinal bulkhead under the deck at Y = y
  stiffeners spacing profile [dir=x|y]       deck stiffeners (1D, sharing plate nodes) every `spacing`, e.g. FB150x12,
                                             HP200x10, T400x10/150x15, L250x90x10/12; cut at openings, none on girders
  bracket    x y size t [plane=xz|yz]        triangular knee bracket at (x, y) under the deck, legs `size`
  load       p [on=deck]                     pressure in MPa on the deck (or a member id)
  fix        x=0 | x=L | y=0 | y=B | edges   supports (clamped)
Example (54 tokens instead of ~600):
  deck L=6000 B=4000 t=12; girder y=1000 h=600 t=12; girder y=3000 h=600 t=12; web x=3000 h=800 t=10;
  opening x=4200 y=1600 w=1000 h=800; stiffeners spacing=500 profile=FB150x12; load p=0.05; fix x=0; fix x=L
"""
import re

PROFILE_RX = [
    (re.compile(r'^(?:FB|F\.B\.?)\s*(\d+(?:\.\d+)?)\s*[xX*]\s*(\d+(?:\.\d+)?)$', re.I), lambda m: {'type': 'FlatBar', 'h': float(m[1]), 't': float(m[2])}),
    (re.compile(r'^HP\s*(\d+(?:\.\d+)?)\s*[xX*]\s*(\d+(?:\.\d+)?)$', re.I), lambda m: {'type': 'HP', 'h': float(m[1]), 't': float(m[2])}),
    (re.compile(r'^T\s*(\d+(?:\.\d+)?)\s*[xX*]\s*(\d+(?:\.\d+)?)\s*[/+]\s*(\d+(?:\.\d+)?)\s*[xX*]\s*(\d+(?:\.\d+)?)$', re.I),
     lambda m: {'type': 'TBar', 'h': float(m[1]), 't': float(m[2]), 'bf': float(m[3]), 'tf': float(m[4])}),
    (re.compile(r'^L\s*(\d+(?:\.\d+)?)\s*[xX*]\s*(\d+(?:\.\d+)?)\s*[xX*]\s*(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$', re.I),
     lambda m: {'type': 'LBar', 'h': float(m[1]), 'bf': float(m[2]), 't': float(m[3]), 'tf': float(m[4])}),
]
KNOWN = {'deck', 'opening', 'girder', 'web', 'bulkhead', 'lbulkhead', 'stiffeners', 'bracket', 'load', 'fix'}


def parse_profile(s):
    if isinstance(s, dict):
        return s
    for rx, fn in PROFILE_RX:
        m = rx.match(str(s).strip())
        if m:
            return fn(m)
    raise ValueError(f"profile '{s}' not understood: use FB150x12, HP200x10, T400x10/150x15 or L250x90x10/12")


def parse(program):
    """text 'name k=v ...; name k=v' or a list of {name: {k: v}} -> [(name, {k: v})]"""
    if isinstance(program, list):
        out = []
        for item in program:
            (name, kv), = item.items()
            out.append((name.lower(), dict(kv)))
        return out
    out = []
    for i, line in enumerate(re.split(r'[;\n]+', str(program)), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        name, kv = parts[0].lower(), {}
        for p in parts[1:]:
            if '=' not in p:
                if name == 'fix' and p in ('edges', 'all'):
                    kv['edges'] = 1
                    continue
                raise ValueError(f"line {i} '{line}': expected key=value, got '{p}'")
            k, v = p.split('=', 1)
            try:
                kv[k.lower()] = float(v)
            except ValueError:
                kv[k.lower()] = v
        if name not in KNOWN:
            raise ValueError(f"line {i}: unknown building block '{name}'; known: {', '.join(sorted(KNOWN))}")
        out.append((name, kv))
    return out


def _need(kv, *keys, what=''):
    miss = [k for k in keys if k not in kv]
    if miss:
        raise ValueError(f"{what}: missing {', '.join(miss)}")


def build(program, name='structure', element_size=None):
    """-> spec for platemesh.build_plates (plates, beams, loads, fix) + a short description"""
    steps = parse(program)
    decks = [kv for n, kv in steps if n == 'deck']
    if len(decks) != 1:
        raise ValueError('a program needs exactly one deck line (deck L=... B=... t=...)')
    d = decks[0]
    _need(d, 'l', 'b', 't', what='deck')
    L, B, t = d['l'], d['b'], d['t']
    x0, y0, z = d.get('x0', 0.0), d.get('y0', 0.0), d.get('z', 0.0)
    resolve = lambda v, full, start: (start + full if str(v).upper() in ('L', 'B') else float(v))
    holes, plates, beams, loads, fix = [], [], [], [], []
    for n, kv in steps:
        if n == 'opening':
            _need(kv, 'x', 'y', 'w', 'h', what='opening')
            ox, oy, w, h = kv['x'], kv['y'], kv['w'], kv['h']
            if not (x0 <= ox and ox + w <= x0 + L and y0 <= oy and oy + h <= y0 + B):
                raise ValueError(f'opening at ({ox:g}, {oy:g}) size {w:g} x {h:g} is not inside the deck')
            holes.append((ox, oy, w, h))
    plates.append({'id': 'DECK', 't': t, 'outline': [[x0, y0, z], [x0 + L, y0, z], [x0 + L, y0 + B, z], [x0, y0 + B, z]],
                   'holes': [[[ox, oy, z], [ox + w, oy, z], [ox + w, oy + h, z], [ox, oy + h, z]] for ox, oy, w, h in holes]})
    girders_y, webs_x = [], []
    cnt = {}
    for n, kv in steps:
        cnt[n] = cnt.get(n, 0) + 1
        k = cnt[n]
        sgn = 1.0 if kv.get('up') else -1.0
        if n in ('girder', 'lbulkhead'):
            _need(kv, 'y', 'h', 't', what=n)
            y = resolve(kv['y'], B, y0)
            xa, xb = kv.get('x0', x0), kv.get('x1', x0 + L)
            plates.append({'id': f'{n.upper()}{k}', 't': kv['t'], 'outline': [[xa, y, z], [xb, y, z], [xb, y, z + sgn * kv['h']], [xa, y, z + sgn * kv['h']]]})
            girders_y.append(y)
        elif n in ('web', 'bulkhead'):
            _need(kv, 'x', 'h', 't', what=n)
            x = resolve(kv['x'], L, x0)
            ya, yb = kv.get('y0', y0), kv.get('y1', y0 + B)
            plates.append({'id': f'{n.upper()}{k}', 't': kv['t'], 'outline': [[x, ya, z], [x, yb, z], [x, yb, z + sgn * kv['h']], [x, ya, z + sgn * kv['h']]]})
            webs_x.append(x)
        elif n == 'bracket':
            _need(kv, 'x', 'y', 'size', 't', what='bracket')
            x, y, s = kv['x'], kv['y'], kv['size']
            if kv.get('plane', 'xz') == 'xz':
                outline = [[x, y, z], [x + s, y, z], [x, y, z - s]]
            else:
                outline = [[x, y, z], [x, y + s, z], [x, y, z - s]]
            plates.append({'id': f'BRACKET{k}', 't': kv['t'], 'outline': outline})
        elif n == 'load':
            _need(kv, 'p', what='load')
            on = str(kv.get('on', 'deck')).upper()
            loads.append({'plates': ['DECK' if on == 'DECK' else on], 'pressure': kv['p']})
        elif n == 'fix':
            if kv.get('edges'):
                fix += [{'x': x0}, {'x': x0 + L}, {'y': y0}, {'y': y0 + B}]
            for key, full, start in (('x', L, x0), ('y', B, y0)):
                if key in kv:
                    fix.append({key: resolve(kv[key], full, start)})
    for n, kv in steps:
        if n != 'stiffeners':
            continue
        _need(kv, 'spacing', 'profile', what='stiffeners')
        prof = parse_profile(kv['profile'])
        along_x = str(kv.get('dir', 'x')).lower() == 'x'
        span, start = (B, y0) if along_x else (L, x0)
        sp = kv['spacing']
        taken = girders_y if along_x else webs_x
        pos = [start + sp * i for i in range(1, int(span / sp + 1e-9) + 1) if sp * i < span - 1e-6]
        k = 0
        for c in pos:
            if any(abs(c - g) < sp / 4 for g in taken):              # a girder / web already stands there
                continue
            cuts = [(ox, ox + w) if along_x else (oy, oy + h) for ox, oy, w, h in holes
                    if (oy < c < oy + h if along_x else ox < c < ox + w)]
            a0, a1 = (x0, x0 + L) if along_x else (y0, y0 + B)
            pieces, cur = [], a0
            for s0, s1 in sorted(cuts):
                if s0 > cur:
                    pieces.append((cur, s0))
                cur = max(cur, s1)
            if cur < a1:
                pieces.append((cur, a1))
            for p0, p1 in pieces:
                k += 1
                a, b = ([p0, c, z], [p1, c, z]) if along_x else ([c, p0, z], [c, p1, z])
                beams.append({'id': f'STIFF{k}', 'a': a, 'b': b, 'profile': prof, 'normal': [0, 0, -1]})
    h = element_size or max(50.0, round(min(L, B) / 20 / 25) * 25)
    spec = {'name': name, 'element_size': h, 'plates': plates, 'beams': beams, 'loads': loads, 'fix': fix}
    desc = (f"deck {L:g} x {B:g} x {t:g} mm, {cnt.get('girder', 0)} girder(s), {cnt.get('web', 0)} web frame(s), "
            f"{cnt.get('bulkhead', 0) + cnt.get('lbulkhead', 0)} bulkhead(s), {len(holes)} opening(s), {len(beams)} stiffener piece(s), "
            f"{cnt.get('bracket', 0)} bracket(s)")
    return spec, desc
