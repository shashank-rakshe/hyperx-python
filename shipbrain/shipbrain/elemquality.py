"""
Pre-processor skills of the kind HyperMesh (Altair, paid) is known for, written here in ShipBrain's own code:

  element quality   per shell element, with pass / warn / fail limits from a criteria table (editable, like a
                    pre-processor's "criteria file"): aspect ratio, warpage, skew, taper, Jacobian ratio, min / max
                    corner angle (quad and tria separately), smallest edge, share of triangles; the failing element
                    ids per check, so they can be fixed or shown.
  model check       what a solver would stop on or silently get wrong: elements without a property, properties
                    without a material, zero / negative thickness, duplicate elements (same nodes), unused
                    properties and materials, loads on missing nodes / elements, no constraints, 1D/2D/3D mix.
  failed sets       writes the failing elements as named sets (*ELSET in an .inp file, SET cards in a .bdf
                    include) so any pre-processor (HyperMesh, ANSA, PrePoMax, Salome ...) shows them after import.

Definitions (standard ones from the FE literature, written out here):
  aspect    longest edge / shortest edge
  warpage   quad only: the larger angle between the normals of the two triangles on each diagonal (deg)
  skew      90 deg minus the smallest angle between the lines that join opposite edge mid-points (quad), or between
            each median and the line through the other two edge mid-points (tria)
  taper     quad only: 1 - (smallest of the four corner triangles) / (their mean)
  jacobian  quad only: smallest / largest determinant of the bilinear map at the 4 corners (1 = parallelogram)
Default limits are typical ship-structure FE practice (coarse cargo-hold and fine-mesh models); class rules and
company guidelines set their own - give yours as `criteria`.
"""
import json, math, os
import numpy as np

CRITERIA = {      # name: (warn above / below, fail above / below, 'max' = bigger is worse | 'min' = smaller is worse)
    'aspect': (3.0, 5.0, 'max'),
    'warpage': (5.0, 10.0, 'max'),
    'skew': (45.0, 60.0, 'max'),
    'taper': (0.5, 0.8, 'max'),
    'jacobian': (0.6, 0.3, 'min'),
    'quad_min_angle': (45.0, 30.0, 'min'),
    'quad_max_angle': (135.0, 150.0, 'max'),
    'tria_min_angle': (30.0, 15.0, 'min'),
    'tria_max_angle': (120.0, 140.0, 'max'),
    'min_edge': (None, None, 'min'),               # mm; set from the target mesh size (e.g. 0.3 x size)
    'trias_percent': (5.0, 10.0, 'max'),           # whole model
}


def _ang(u, v):
    nu, nv = np.linalg.norm(u), np.linalg.norm(v)
    if nu == 0 or nv == 0:
        return 0.0
    return math.degrees(math.acos(max(-1.0, min(1.0, float(u @ v) / (nu * nv)))))


def _normal(a, b, c):
    n = np.cross(b - a, c - a)
    L = np.linalg.norm(n)
    return n / L if L else n


def element(P):
    """quality values of one shell element (3 or 4 corner points, in order)"""
    P = np.asarray(P, float)
    n = len(P)
    sides = [float(np.linalg.norm(P[(k + 1) % n] - P[k])) for k in range(n)]
    q = {'min_edge': min(sides), 'aspect': max(sides) / min(sides) if min(sides) > 0 else float('inf')}
    angles = [_ang(P[k - 1] - P[k], P[(k + 1) % n] - P[k]) for k in range(n)]
    pre = 'quad' if n == 4 else 'tria'
    q[pre + '_min_angle'], q[pre + '_max_angle'] = min(angles), max(angles)
    mid = [(P[k] + P[(k + 1) % n]) / 2 for k in range(n)]
    if n == 4:
        a = _ang(mid[2] - mid[0], mid[3] - mid[1])
        q['skew'] = 90.0 - min(a, 180.0 - a)
        w1 = _ang(_normal(P[0], P[1], P[2]), _normal(P[0], P[2], P[3]))
        w2 = _ang(_normal(P[1], P[2], P[3]), _normal(P[1], P[3], P[0]))
        q['warpage'] = max(w1, w2)
        tri = [np.linalg.norm(np.cross(P[(k + 1) % 4] - P[k], P[k - 1] - P[k])) / 2 for k in range(4)]
        mean = sum(tri) / 4
        q['taper'] = float(1.0 - min(tri) / mean) if mean > 0 else 1.0
        # Jacobian of the bilinear map, in the element's own mean plane
        c = P.mean(0)
        nrm = sum((np.cross(P[k] - c, P[(k + 1) % 4] - c) for k in range(4)), np.zeros(3))
        nrm = nrm / (np.linalg.norm(nrm) or 1.0)
        e1 = P[1] - P[0] - ((P[1] - P[0]) @ nrm) * nrm
        e1 = e1 / (np.linalg.norm(e1) or 1.0)
        e2 = np.cross(nrm, e1)
        X = np.array([[(p - c) @ e1, (p - c) @ e2] for p in P])
        dets = []
        for xi, eta in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            dN = 0.25 * np.array([[-(1 - eta), (1 - eta), (1 + eta), -(1 + eta)],
                                  [-(1 - xi), -(1 + xi), (1 + xi), (1 - xi)]])
            dets.append(float(np.linalg.det(dN @ X)))
        q['jacobian'] = min(dets) / max(dets) if max(dets) > 0 else -1.0
    else:
        sk = []
        for k in range(3):
            med = mid[(k + 1) % 3] - P[k]                    # vertex k to the mid-point of the opposite edge
            other = mid[(k + 2) % 3] - mid[k]                # through the other two mid-points
            a = _ang(med, other)
            sk.append(min(a, 180.0 - a))
        q['skew'] = 90.0 - min(sk)
    return q


def _level(v, warn, fail, sense):
    if warn is None and fail is None:
        return 'ok'
    worse = (lambda a, b: a > b) if sense == 'max' else (lambda a, b: a < b)
    if fail is not None and worse(v, fail):
        return 'fail'
    if warn is not None and worse(v, warn):
        return 'warn'
    return 'ok'


def quality(model, criteria=None, mesh_size=None, worst=5):
    """element quality of every shell element of an FEModel against the criteria table"""
    crit = dict(CRITERIA)
    if mesh_size:
        crit['min_edge'] = (0.5 * mesh_size, 0.2 * mesh_size, 'min')
    for k, v in (criteria or {}).items():
        if k not in crit:
            raise ValueError(f'unknown check {k}; known: {", ".join(crit)}')
        base = crit[k]
        if isinstance(v, dict):
            crit[k] = (v.get('warn', base[0]), v.get('fail', base[1]), base[2])
        elif isinstance(v, (list, tuple)):
            crit[k] = (v[0], v[1] if len(v) > 1 else v[0], base[2])
        else:
            crit[k] = (v, v, base[2])
    shells = {eid: e for eid, e in model.elems.items() if e['type'] in ('tria', 'quad')}
    vals, n_tria = {}, 0
    for eid, e in shells.items():
        try:
            q = element([model.nodes[n] for n in e['nodes']])
        except KeyError:
            continue
        n_tria += e['type'] == 'tria'
        for k, v in q.items():
            vals.setdefault(k, []).append((eid, v))
    checks, failed = {}, {}
    for k, (warn, fail, sense) in crit.items():
        if k == 'trias_percent':
            pct = 100.0 * n_tria / len(shells) if shells else 0.0
            checks[k] = {'value': round(pct, 2), 'warn': warn, 'fail': fail, 'result': _level(pct, warn, fail, sense)}
            continue
        rows = vals.get(k, [])
        if not rows:
            continue
        lev = [(eid, v, _level(v, warn, fail, sense)) for eid, v in rows]
        bad = sorted((r for r in lev if r[2] != 'ok'), key=lambda r: -r[1] if sense == 'max' else r[1])
        vs = [v for _, v, _ in lev if math.isfinite(v)]
        checks[k] = {'worst': round(max(vs) if sense == 'max' else min(vs), 3) if vs else None, 'warn': warn, 'fail': fail,
                     'n_warn': sum(r[2] == 'warn' for r in lev), 'n_fail': sum(r[2] == 'fail' for r in lev),
                     'worst_elements': [[eid, round(v, 3)] for eid, v, _ in bad[:worst]]}
        f = [eid for eid, _, l in lev if l == 'fail']
        if f:
            failed[k] = f
    n_fail_el = len({e for ids in failed.values() for e in ids})
    out = {'shell_elements': len(shells), 'quads': len(shells) - n_tria, 'trias': n_tria, 'checks': checks,
           'failed_elements': n_fail_el, 'failed_ids': failed}
    names = {'aspect': 'aspect ratio', 'warpage': 'warpage', 'skew': 'skew', 'taper': 'taper', 'jacobian': 'Jacobian ratio',
             'quad_min_angle': 'quad smallest angle', 'quad_max_angle': 'quad largest angle',
             'tria_min_angle': 'triangle smallest angle', 'tria_max_angle': 'triangle largest angle',
             'min_edge': 'shortest edge', 'trias_percent': 'share of triangles'}
    if not shells:
        out['plain_english'] = 'The model has no shell elements, so there is nothing to grade (solids: use mesh_check).'
        return out
    bad = [f"{names[k]} ({c['n_fail']} fail, {c['n_warn']} warn, worst {c['worst']:g})" for k, c in checks.items()
           if c.get('n_fail') or c.get('n_warn')]
    tp = checks.get('trias_percent', {})
    pe = (f"{len(shells)} shell elements ({out['quads']} quads, {n_tria} triangles = {tp.get('value', 0):g} %). ")
    if n_fail_el:
        pe += f"{n_fail_el} elements fail at least one limit: " + '; '.join(bad) + '.'
    elif bad:
        pe += 'No element fails, but some are near the limits (warnings): ' + '; '.join(bad) + '.'
    else:
        pe += 'Every element passes every limit.'
    if tp.get('result') in ('warn', 'fail'):
        pe += f" The share of triangles is above {tp['warn']:g} %: use more quads in stress areas."
    out['plain_english'] = pe
    return out


def model_check(model):
    """problems a solver stops on or silently gets wrong"""
    issues = []
    used_p = {e['pid'] for e in model.elems.values()}
    no_prop = [eid for eid, e in model.elems.items() if e['pid'] not in model.props]
    if no_prop:
        issues.append(('error', f'{len(no_prop)} elements point to a property that does not exist', no_prop[:20]))
    no_mat = [pid for pid, p in model.props.items() if pid in used_p and p.get('mid', 1) not in model.mats]
    if no_mat:
        issues.append(('error', f'properties {no_mat[:10]} point to a material that does not exist', no_mat))
    thin = [pid for pid, p in model.props.items() if p.get('kind') == 'shell' and not (float(p.get('t') or 0) > 0)]
    if thin:
        issues.append(('error', f'shell properties {thin[:10]} have zero or negative thickness', thin))
    for pid, p in model.props.items():
        if p.get('kind') == 'bar' and not (float(p.get('A') or 0) > 0):
            issues.append(('error', f'beam property {pid} has no cross-section area', [pid]))
    for mid, m in model.mats.items():
        if not (float(m.get('E') or 0) > 0) or not (-1 < float(m.get('nu') or 0) < 0.5):
            issues.append(('error', f'material {mid} has an impossible E or Poisson ratio', [mid]))
        if not float(m.get('rho') or 0):
            issues.append(('warn', f'material {mid} has no density (no self weight, no modal mass)', [mid]))
    seen, dup = {}, []
    for eid, e in model.elems.items():
        k = (e['type'], tuple(sorted(e['nodes'])))
        if k in seen:
            dup.append(eid)
        seen.setdefault(k, eid)
    if dup:
        issues.append(('error', f'{len(dup)} duplicate elements (same nodes as another element)', dup[:20]))
    missing = sorted({n for e in model.elems.values() for n in e['nodes'] if n not in model.nodes})
    if missing:
        issues.append(('error', f'{len(missing)} element nodes are not defined', missing[:20]))
    unused_p = sorted(set(model.props) - used_p)
    if unused_p:
        issues.append(('info', f'{len(unused_p)} properties are not used by any element', unused_p[:20]))
    used_m = {p.get('mid', 1) for pid, p in model.props.items() if pid in used_p}
    unused_m = sorted(set(model.mats) - used_m)
    if unused_m:
        issues.append(('info', f'{len(unused_m)} materials are not used', unused_m))
    bad_spc = [n for n in model.spc if n not in model.nodes]
    if bad_spc:
        issues.append(('error', f'{len(bad_spc)} constraints are on nodes that do not exist', bad_spc[:20]))
    for ld in model.loads:
        if ld['type'] == 'force' and ld['node'] not in model.nodes:
            issues.append(('error', f"a force is on node {ld['node']}, which does not exist", [ld['node']]))
        if ld['type'] == 'pressure':
            gone = [e for e in ld['elems'] if e not in model.elems]
            if gone:
                issues.append(('error', f'a pressure load lists {len(gone)} elements that do not exist', gone[:20]))
    if model.elems and not model.spc:
        issues.append(('warn', 'no constraints: a static run will stop on a singular stiffness (fine for free-free modes)', []))
    if model.elems and not model.loads:
        issues.append(('info', 'no loads defined', []))
    out = {'errors': sum(i[0] == 'error' for i in issues), 'warnings': sum(i[0] == 'warn' for i in issues),
           'issues': [{'level': l, 'what': w, 'ids': ids} for l, w, ids in issues]}
    out['plain_english'] = ('The model is complete: every element has a property, every property a material, and loads and '
                            'constraints point to real nodes.' if not out['errors'] and not out['warnings'] else
                            f"{out['errors']} errors and {out['warnings']} warnings: "
                            + '; '.join(w for l, w, _ in issues if l != 'info') + '.')
    return out


def write_sets(failed, path):
    """the failing elements as named sets: .inp -> *ELSET (Abaqus/CalculiX syntax), else Nastran SET cards (case control)"""
    lines = []
    inp = path.lower().endswith('.inp')
    for k, (name, ids) in enumerate(sorted(failed.items()), 1):
        ids = sorted(ids)
        if inp:
            lines.append(f'*ELSET, ELSET=FAIL_{name.upper()}')
            lines += [', '.join(map(str, ids[j:j + 16])) for j in range(0, len(ids), 16)]
        else:
            lines.append(f'$ elements failing {name}')
            chunks = [', '.join(map(str, ids[j:j + 10])) for j in range(0, len(ids), 10)]
            lines.append(f'SET {900 + k} = ' + ',\n    '.join(chunks))
    open(path, 'w').write('\n'.join(lines) + '\n')
    return path


def check_file(path, criteria=None, mesh_size=None, sets=True):
    from .femodel import FEModel
    m = FEModel.read(path)
    q = quality(m, criteria, mesh_size)
    mc = model_check(m)
    out = {'quality': q, 'model': mc}
    if sets and q['failed_ids']:
        base, ext = os.path.splitext(path)
        out['failed_sets_file'] = write_sets(q['failed_ids'], base + '_failed' + ('.inp' if ext.lower() == '.inp' else '.sets'))
    out['plain_english'] = q['plain_english'] + ' ' + mc['plain_english'] + (
        f" The failing elements are saved as named sets in {os.path.basename(out['failed_sets_file'])}."
        if out.get('failed_sets_file') else '')
    return out


if __name__ == '__main__':
    import sys
    print(json.dumps(check_file(sys.argv[1]), indent=1, default=str))
