"""
Deterministic FE meshers. The language model never writes mesh files: it writes a small JSON spec,
this code builds the mesh, checks it, and writes Nastran BDF / Abaqus-CalculiX INP.

1. stiffened_panel(spec)  - ship deck / bulkhead / shell panel: plate + longitudinal stiffeners + transverse frames
   (structured quad mesh, stiffeners as shell webs+flanges or as offset beams, nodes shared at every crossing).
2. platemesh.py / cadplates.py - any assembly of flat plates (JSON or STEP via CadQuery), own conforming mesher.

Coordinates: plate in the X-Y plane at z = 0 (moulded line), X = panel length (along longitudinals),
Y = panel width, stiffeners/frames hang below the plate (-Z). Units: mm, N, MPa (t, mm, s consistent set).
"""
import json, math, os

PROFILE_TYPES = ('FlatBar', 'TBar', 'LBar', 'HP')

DEFAULT_SPEC = {
    'name': 'panel',
    'length': 4800.0,            # X, mm
    'width': 3200.0,             # Y, mm
    'thickness': 12.0,           # plate, mm
    'stiffeners': {'direction': 'x', 'spacing': 800.0, 'profile': {'type': 'FlatBar', 'h': 150.0, 't': 12.0}},
    'frames': {'spacing': 2400.0, 'profile': {'type': 'TBar', 'h': 400.0, 't': 10.0, 'bf': 150.0, 'tf': 15.0}},
    'element_size': 100.0,
    'web_elements': 3,           # elements over the stiffener web height (shell model)
    'stiffener_model': 'shell',  # 'shell' (webs + flanges as CQUAD4) or 'beam' (CBAR/B31 with offsets)
    'material': {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9, 'name': 'STEEL'},
    'pressure': 0.05,            # MPa lateral pressure on the plate, pushing in -Z (0 = none)
    'boundary': 'simply',        # 'simply' | 'clamped' | 'free'
}


# ------------------------------------------------------------------ section properties
def profile_props(p):
    """area, centroid depth below the plate face (zc > 0 downwards), I about own horizontal centroid axis, I about vertical,
    J (thin-walled), for FlatBar / TBar / LBar / HP (HP treated as flat bar + bulb lump)."""
    typ = p.get('type', 'FlatBar')
    h, tw = float(p['h']), float(p['t'])
    parts = []                                    # (b, d, y_c, z_c) rectangles, z downwards from plate face
    if typ in ('TBar', 'LBar'):
        bf, tf = float(p.get('bf', 0)), float(p.get('tf', 0))
        hw = h - tf
        parts.append((tw, hw, 0.0, hw / 2))
        yc = 0.0 if typ == 'TBar' else (bf / 2 - tw / 2)
        parts.append((bf, tf, yc, hw + tf / 2))
    elif typ == 'HP':                              # bulb flat: bulb ~ extra 0.4*h*t area near the toe (approximation)
        parts.append((tw, h, 0.0, h / 2))
        bb = max(tw * 1.8, 0.12 * h)
        parts.append((bb, 0.12 * h, (bb - tw) / 2, h - 0.06 * h))
    else:
        parts.append((tw, h, 0.0, h / 2))
    A = sum(b * d for b, d, _, _ in parts)
    zc = sum(b * d * z for b, d, _, z in parts) / A
    yc = sum(b * d * y for b, d, y, _ in parts) / A
    Iy = sum(b * d ** 3 / 12 + b * d * (z - zc) ** 2 for b, d, _, z in parts)   # vertical bending (about horizontal axis)
    Iz = sum(d * b ** 3 / 12 + b * d * (y - yc) ** 2 for b, d, y, _ in parts)
    J = sum(max(b, d) * min(b, d) ** 3 / 3 for b, d, _, _ in parts)
    return {'A': A, 'zc': zc, 'yc': yc, 'I_vert': Iy, 'I_lat': Iz, 'J': J}


def with_plate(p, t, b_eff):
    """section modulus of stiffener + attached plating of effective breadth b_eff (plate above, z from plate mid-plane)"""
    s = profile_props(p)
    Ap = b_eff * t
    # plate centroid at z = -t/2 below its top... use plate mid-plane z=0, profile hangs from z = t/2 below the mid-plane
    z_prof = t / 2 + s['zc']
    A = Ap + s['A']
    zna = s['A'] * z_prof / A
    I = b_eff * t ** 3 / 12 + Ap * zna ** 2 + s['I_vert'] + s['A'] * (z_prof - zna) ** 2
    z_top = zna + t / 2
    z_bot = t / 2 + float(p['h']) - zna
    return {'A': A, 'z_na': zna, 'I': I, 'Z_plate': I / z_top, 'Z_toe': I / z_bot}


# ------------------------------------------------------------------ spec handling
def _merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = _merge(base[k], v) if isinstance(v, dict) and isinstance(base.get(k), dict) else v
    return out


def normalise_spec(spec):
    """fill defaults, accept a few synonyms, and validate. Raises ValueError with all problems at once."""
    if isinstance(spec, str):
        spec = json.loads(spec)
    spec = dict(spec or {})
    for a, b in (('L', 'length'), ('B', 'width'), ('t', 'thickness'), ('mesh_size', 'element_size'), ('bc', 'boundary')):
        if a in spec and b not in spec:
            spec[b] = spec.pop(a)
    for k in ('stiffeners', 'frames'):                       # explicit null / 0 = none
        if k in spec and not spec[k]:
            spec[k] = {'spacing': 0}
    s = _merge(DEFAULT_SPEC, spec)
    err = []
    for k in ('length', 'width', 'thickness', 'element_size'):
        try:
            s[k] = float(s[k])
            if s[k] <= 0:
                err.append(f'{k} must be > 0')
        except (TypeError, ValueError):
            err.append(f'{k} must be a number')
    for grp in ('stiffeners', 'frames'):
        g = s[grp]
        g['spacing'] = float(g.get('spacing') or 0)
        if g.get('count') and not g['spacing']:
            span = s['width'] if grp == 'stiffeners' else s['length']
            g['spacing'] = span / (int(g['count']) + 1)
        if g['spacing'] < 0:
            err.append(f'{grp}.spacing must be >= 0')
        p = g.get('profile') or {}
        if g['spacing']:
            if p.get('type', 'FlatBar') not in PROFILE_TYPES:
                err.append(f'{grp}.profile.type must be one of {PROFILE_TYPES}')
            if float(p.get('h', 0)) <= 0 or float(p.get('t', 0)) <= 0:
                err.append(f'{grp}.profile needs h > 0 and t > 0')
            if p.get('type') in ('TBar', 'LBar') and (float(p.get('bf', 0)) <= 0 or float(p.get('tf', 0)) <= 0):
                err.append(f'{grp}.profile {p.get("type")} needs bf > 0 and tf > 0')
    if s['stiffeners'].get('direction', 'x') not in ('x', 'y'):
        err.append("stiffeners.direction must be 'x' or 'y'")
    if s['stiffener_model'] not in ('shell', 'beam'):
        err.append("stiffener_model must be 'shell' or 'beam'")
    if s['boundary'] not in ('simply', 'clamped', 'free'):
        err.append("boundary must be 'simply', 'clamped' or 'free'")
    if not err and s['length'] / s['element_size'] * s['width'] / s['element_size'] > 400000:
        err.append('too many plate elements (> 400k): increase element_size')
    if err:
        raise ValueError('; '.join(err))
    return s


def _positions(span, spacing):
    """member positions strictly inside (0, span) at the given spacing, centred so both end bays are equal"""
    if not spacing or spacing >= span - 1e-6:
        return []
    n = int(math.ceil(span / spacing - 1e-9)) - 1
    off = (span - (n - 1) * spacing) / 2
    return [round(off + i * spacing, 6) for i in range(n)]


def _grid(span, keys, size):
    """1-D grid from 0 to span through every key position, no element longer than size"""
    pts = sorted(set([0.0, span] + list(keys)))
    out = [0.0]
    for a, b in zip(pts[:-1], pts[1:]):
        n = max(1, int(math.ceil((b - a) / size - 1e-9)))
        out += [a + (b - a) * i / n for i in range(1, n + 1)]
    return [round(v, 6) for v in out]


# ------------------------------------------------------------------ the panel mesher
class Mesh:
    def __init__(self):
        self.nodes = {}          # key -> id
        self.xyz = []            # id-1 -> (x, y, z)
        self.elems = []          # dict(id, type 'quad'|'bar', nodes, pid, group, [orient], [offset])
        self.props = {}          # pid -> dict
        self.groups = {}

    def node(self, x, y, z):
        k = (round(x, 3), round(y, 3), round(z, 3))
        if k not in self.nodes:
            self.xyz.append(k)
            self.nodes[k] = len(self.xyz)
        return self.nodes[k]

    def add(self, typ, nodes, pid, group, **kw):
        e = dict(id=len(self.elems) + 1, type=typ, nodes=nodes, pid=pid, group=group, **kw)
        self.elems.append(e)
        self.groups.setdefault(group, []).append(e['id'])
        return e


def stiffened_panel(spec):
    s = normalise_spec(spec)
    L, B, t, e = s['length'], s['width'], s['thickness'], s['element_size']
    st, fr = s['stiffeners'], s['frames']
    along_x = st.get('direction', 'x') == 'x'
    # stiffeners run along X at Y positions (or along Y at X positions); frames run across them
    st_pos = _positions(B if along_x else L, st['spacing'])
    fr_pos = _positions(L if along_x else B, fr['spacing'])
    xs_keys = fr_pos if along_x else st_pos
    ys_keys = st_pos if along_x else fr_pos
    xs, ys = _grid(L, xs_keys, e), _grid(B, ys_keys, e)
    m = Mesh()
    m.props[1] = {'kind': 'shell', 't': t, 'name': 'PLATE'}
    shell = s['stiffener_model'] == 'shell'
    # z levels shared by all webs, so stiffener and frame webs meet node to node
    depths = []
    for g in (st, fr):
        if g['spacing']:
            p = g['profile']
            depths.append(float(p['h']) - (float(p.get('tf', 0)) if p.get('type') in ('TBar', 'LBar') else 0.0))
    nweb = max(1, int(s.get('web_elements', 3)))
    zl = {0.0}
    for d in depths:
        zl.update(-d * i / nweb for i in range(1, nweb + 1))
    zlev = sorted(zl, reverse=True)

    # plate
    for j in range(len(ys) - 1):
        for i in range(len(xs) - 1):
            n = [m.node(xs[i], ys[j], 0), m.node(xs[i + 1], ys[j], 0), m.node(xs[i + 1], ys[j + 1], 0), m.node(xs[i], ys[j + 1], 0)]
            m.add('quad', n, 1, 'plate')

    def member(name, p, line_axis, at, grid_along, pid0):
        """one stiffener/frame: line along X (line_axis='x', at=y) or along Y (at=x)"""
        sp = profile_props(p)
        typ = p.get('type', 'FlatBar')
        hw = float(p['h']) - (float(p.get('tf', 0)) if typ in ('TBar', 'LBar') else 0.0)
        P = lambda u, v, z: (u, v, z) if line_axis == 'x' else (v, u, z)        # (along, across, z) -> xyz
        if shell:
            m.props[pid0] = {'kind': 'shell', 't': float(p['t']), 'name': name.rstrip('0123456789') + '_WEB'}
            z = [zz for zz in zlev if zz >= -hw - 1e-6]
            for i in range(len(grid_along) - 1):
                a, b = grid_along[i], grid_along[i + 1]
                for k in range(len(z) - 1):
                    n = [m.node(*P(a, at, z[k])), m.node(*P(b, at, z[k])), m.node(*P(b, at, z[k + 1])), m.node(*P(a, at, z[k + 1]))]
                    m.add('quad', n, pid0, name)
            if typ in ('TBar', 'LBar'):
                bf, tf = float(p['bf']), float(p['tf'])
                m.props[pid0 + 1] = {'kind': 'shell', 't': tf, 'name': name.rstrip('0123456789') + '_FLANGE'}
                zf = -hw
                sides = [(-bf / 2, 0.0), (0.0, bf / 2)] if typ == 'TBar' else [(0.0, bf - float(p['t']) / 2)]
                for i in range(len(grid_along) - 1):
                    a, b = grid_along[i], grid_along[i + 1]
                    for v0, v1 in sides:
                        n = [m.node(*P(a, at + v0, zf)), m.node(*P(b, at + v0, zf)), m.node(*P(b, at + v1, zf)), m.node(*P(a, at + v1, zf))]
                        m.add('quad', n, pid0 + 1, name)
            elif typ == 'HP':
                m.props[pid0] = {'kind': 'shell', 't': sp['A'] / hw, 'name': name + '_WEB(HP eq.)'}
        else:
            m.props[pid0] = {'kind': 'bar', 'A': sp['A'], 'I1': sp['I_vert'], 'I2': sp['I_lat'], 'J': sp['J'],
                             'offset': -(t / 2 + sp['zc']), 'name': name}
            for i in range(len(grid_along) - 1):
                n = [m.node(*P(grid_along[i], at, 0)), m.node(*P(grid_along[i + 1], at, 0))]
                m.add('bar', n, pid0, name, orient=(0.0, 0.0, 1.0), offset=(0.0, 0.0, -(t / 2 + sp['zc'])))

    pid = 10
    for k, at in enumerate(st_pos, 1):
        member(f'STIFF{k}', st['profile'], 'x' if along_x else 'y', at, xs if along_x else ys, pid)
    pid = 20
    for k, at in enumerate(fr_pos, 1):
        member(f'FRAME{k}', fr['profile'], 'y' if along_x else 'x', at, ys if along_x else xs, pid)

    # boundary conditions on the panel edges (plate edge nodes and member end nodes on the edge planes)
    edge = lambda x, y: abs(x) < 1e-6 or abs(x - L) < 1e-6 or abs(y) < 1e-6 or abs(y - B) < 1e-6
    m.spc = {}
    if s['boundary'] != 'free':
        dof = '123456' if s['boundary'] == 'clamped' else '3'
        for (x, y, z), nid in m.nodes.items():
            if edge(x, y):
                m.spc[nid] = dof if (s['boundary'] == 'clamped' or abs(z) < 1e-6) else '3'
        if s['boundary'] == 'simply':                   # stop rigid in-plane motion: pin two corners
            m.spc[m.node(0, 0, 0)] = '123'
            m.spc[m.node(L, 0, 0)] = '23'
    m.spec = s
    m.stiffener_positions, m.frame_positions = st_pos, fr_pos
    return m


# ------------------------------------------------------------------ quality + summary
def quality(m):
    worst_ar, bad = 1.0, 0
    for e in m.elems:
        if e['type'] != 'quad':
            continue
        p = [m.xyz[n - 1] for n in e['nodes']]
        sides = [math.dist(p[i], p[(i + 1) % 4]) for i in range(4)]
        if min(sides) < 1e-9:
            bad += 1
            continue
        ar = max(sides) / min(sides)
        worst_ar = max(worst_ar, ar)
        bad += ar > 5
    return {'max_aspect_ratio': round(worst_ar, 2), 'elements_aspect_gt_5': bad}


def summary(m):
    s = m.spec
    q = quality(m)
    n_quad = sum(e['type'] == 'quad' for e in m.elems)
    out = {'name': s['name'], 'nodes': len(m.xyz), 'elements': len(m.elems), 'quads': n_quad, 'bars': len(m.elems) - n_quad,
           'elements_by_part': {'plate': len(m.groups.get('plate', [])),
                                'stiffeners': sum(len(v) for g, v in m.groups.items() if g.startswith('STIFF')),
                                'frames': sum(len(v) for g, v in m.groups.items() if g.startswith('FRAME'))},
           'stiffeners_at_mm': m.stiffener_positions, 'frames_at_mm': m.frame_positions,
           'stiffener_model': s['stiffener_model'], 'boundary': s['boundary'], 'pressure_MPa': s['pressure'],
           'constrained_nodes': len(m.spc), 'quality': q,
           'checks': []}
    if q['elements_aspect_gt_5']:
        out['checks'].append(f"{q['elements_aspect_gt_5']} elements with aspect ratio > 5: lower element_size or change web_elements")
    if s['stiffeners']['spacing'] and s['stiffeners']['spacing'] < 3 * s['element_size']:
        out['checks'].append('fewer than 3 elements between stiffeners: plate bending between stiffeners is not captured')
    if s['stiffener_model'] == 'beam':
        out['checks'].append("beam model: the BDF carries the offsets (correct in Nastran); the INP cannot, so CalculiX/Abaqus results "
                             "are too flexible - use stiffener_model='shell' for CalculiX")
    if not out['checks']:
        out['checks'].append('ok')
    return out


# ------------------------------------------------------------------ writers
def _f8(v):
    """Nastran small-field real (8 chars)"""
    if isinstance(v, int):
        return f'{v:<8d}'
    v = float(v)
    if v == 0 or abs(v) < 1e-30:
        return '0.      '
    for fmt in ('{:.7g}', '{:.6g}', '{:.5g}', '{:.4g}', '{:.3g}'):
        s = fmt.format(v)
        if 'e' in s:
            mant, ex = s.split('e')
            s = mant + ('-' if ex.startswith('-') else '+') + ex.lstrip('+-').lstrip('0')
        if '.' not in s and 'e' not in s and '+' not in s[1:] and '-' not in s[1:]:
            s += '.'
        if len(s) <= 8:
            return f'{s:<8s}'
    for p in range(4, -1, -1):                       # small / large values: Nastran exponent form, e.g. -9.73-4
        mant, ex = f'{v:.{p}e}'.split('e')
        s = mant + ('-' if ex.startswith('-') else '+') + ex.lstrip('+-').lstrip('0')
        if len(s) <= 8:
            return f'{s:<8s}'
    raise ValueError(v)


def _card(*fields):
    out, line = [], ''
    for i, f in enumerate(fields):
        if i and i % 9 == 0:
            out.append(line)
            line = '        '
        line += f if isinstance(f, str) and len(f) == 8 else (f'{f:<8s}' if isinstance(f, str) else _f8(f))
    out.append(line.rstrip())
    return '\n'.join(out)


def _loads(m):
    """[(element ids, pressure MPa)]: panel = pressure on the plate; plate assemblies carry m.loads"""
    if getattr(m, 'loads', None) is not None:
        return [(ids, p) for ids, p in m.loads if p]
    return [(m.groups.get('plate', []), m.spec['pressure'])] if m.spec.get('pressure') else []


def write_bdf(m, path):
    s = m.spec
    mat = s['material']
    L = ['$ shipbrain stiffened panel: ' + s['name'], 'SOL 101', 'CEND', 'TITLE = ' + s['name'], 'ECHO = NONE',
         'SUBCASE 1', '  SPC = 1', '  LOAD = 1', '  DISPLACEMENT = ALL', '  STRESS = ALL', 'BEGIN BULK', 'PARAM   POST    -1']
    L.append(_card('MAT1', 1, mat['E'], '', mat['nu'], mat['rho']))
    for pid, p in sorted(m.props.items()):
        if pid in {e['pid'] for e in m.elems}:
            L.append(f"$ {p['name']}")
            if p['kind'] == 'shell':
                L.append(_card('PSHELL', pid, 1, p['t'], 1, '', 1))
            else:
                L.append(_card('PBAR', pid, 1, p['A'], p['I1'], p['I2'], p['J']))
    for i, (x, y, z) in enumerate(m.xyz, 1):
        L.append(_card('GRID', i, '', float(x), float(y), float(z)))
    for e in m.elems:
        if e['type'] == 'quad':
            L.append(_card('CQUAD4', e['id'], e['pid'], *e['nodes']))
        elif e['type'] == 'tri':
            L.append(_card('CTRIA3', e['id'], e['pid'], *e['nodes']))
        else:
            o, w = e['orient'], e['offset']
            L.append(_card('CBAR', e['id'], e['pid'], *e['nodes'], *o, '', '', '', *w, *w))
    by = {}
    for nid, d in m.spc.items():
        by.setdefault(d, []).append(nid)
    for d, ids in sorted(by.items()):
        for k in range(0, len(ids), 6):
            L.append(_card('SPC1', 1, d, *ids[k:k + 6]))
    for ids, p in _loads(m):
        for eid in ids:
            L.append(_card('PLOAD4', 1, eid, -float(p)))                     # PLOAD4 positive = along the normal; load pushes against it
    L.append('ENDDATA')
    open(path, 'w').write('\n'.join(L) + '\n')
    return path


def write_inp(m, path):
    """Abaqus / CalculiX input. Shell model: S4. Beam model: B31 with general section (no offset in CalculiX: warned)."""
    s = m.spec
    mat = s['material']
    L = ['** shipbrain stiffened panel: ' + s['name'], '*HEADING', s['name'], '*NODE']
    L += [f'{i}, {x:.4f}, {y:.4f}, {z:.4f}' for i, (x, y, z) in enumerate(m.xyz, 1)]
    pids = sorted({e['pid'] for e in m.elems})
    for pid in pids:
        p = m.props[pid]
        es = [e for e in m.elems if e['pid'] == pid]
        for typ, sel in (('S4', 'quad'), ('S3', 'tri'), ('B31', 'bar')):
            ee = [e for e in es if e['type'] == sel]
            if ee:
                L.append(f'*ELEMENT, TYPE={typ}, ELSET=P{pid}')
                L += [f"{e['id']}, " + ', '.join(map(str, e['nodes'])) for e in ee]
    L += [f"*MATERIAL, NAME={mat.get('name', 'STEEL')}", '*ELASTIC', f"{mat['E']}, {mat['nu']}", '*DENSITY', f"{mat['rho']}"]
    for pid in pids:
        p = m.props[pid]
        if p['kind'] == 'shell':
            L += [f"*SHELL SECTION, ELSET=P{pid}, MATERIAL={mat.get('name', 'STEEL')}", f"{p['t']}"]
        else:
            # CalculiX has no general beam section: equivalent rectangle with the same A and I1. The offset below the plate is
            # ignored, so the stiffener loses its composite action with the plate: results are too flexible -> use 'shell'.
            h = math.sqrt(12 * p['I1'] / p['A'])
            b = p['A'] / h
            L += [f"*BEAM SECTION, ELSET=P{pid}, MATERIAL={mat.get('name', 'STEEL')}, SECTION=RECT", f'{h:.4f}, {b:.4f}', '0., 0., 1.']
    for k, (ids, p) in enumerate(_loads(m), 1):
        L.append(f'*ELSET, ELSET=LOAD{k}')
        L += [', '.join(map(str, ids[j:j + 16])) for j in range(0, len(ids), 16)]
    L += ['*STEP', '*STATIC']
    if m.spc:
        L.append('*BOUNDARY')
        for nid, d in sorted(m.spc.items()):
            dd = sorted(int(c) for c in d)
            # write contiguous runs
            runs, st = [], dd[0]
            for a, b in zip(dd, dd[1:] + [None]):
                if b != a + 1:
                    runs.append((st, a))
                    st = b
            L += [f'{nid}, {a}, {b}' for a, b in runs]
    for k, (ids, p) in enumerate(_loads(m), 1):
        L += ['*DLOAD', f"LOAD{k}, P, {-float(p)}"]                                   # CalculiX: -P pushes against the element normal (checked)
    L += ['*NODE FILE', 'U', '*EL FILE', 'S', '*NODE PRINT, NSET=NALL', 'U', '*END STEP']
    txt = '\n'.join(L) + '\n'
    txt = txt.replace('*NODE PRINT, NSET=NALL\nU\n', '')                             # NALL exists in CalculiX only
    open(path, 'w').write(txt)
    return path


def viewer_data(m, max_edges=60000):
    """compact edges + coordinates for the GUI 3D preview"""
    edges, seen = [], set()
    horiz = {P.id: abs(P.n[2]) > 0.7 for P in getattr(m, 'plates', [])}       # assemblies: plating vs webs
    for e in m.elems:
        n = e['nodes']
        pairs = [(n[i], n[(i + 1) % len(n)]) for i in range(len(n))] if e['type'] == 'quad' else [(n[0], n[1])]
        if horiz:
            g = 0 if horiz.get(e['group']) else 1
        else:
            g = 0 if e['group'] == 'plate' else (1 if e['group'].startswith('STIFF') else 2)
        for a, b in pairs:
            k = (min(a, b), max(a, b))
            if k not in seen:
                seen.add(k)
                edges.append([a - 1, b - 1, g])
    return {'xyz': [list(p) for p in m.xyz], 'edges': edges[:max_edges]}


def build_panel(spec, out_dir='.', formats=('bdf', 'inp')):
    m = stiffened_panel(spec)
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, m.spec['name'])
    files = {}
    if 'bdf' in formats:
        files['bdf'] = write_bdf(m, base + '.bdf')
    if 'inp' in formats:
        files['inp'] = write_inp(m, base + '.inp')
    json.dump(m.spec, open(base + '.spec.json', 'w'), indent=1)
    files['spec'] = base + '.spec.json'
    return m, {**summary(m), 'files': files}


if __name__ == '__main__':
    import sys
    sp = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else {}
    _, info = build_panel(sp, sys.argv[2] if len(sys.argv) > 2 else '.')
    print(json.dumps(info, indent=1))
