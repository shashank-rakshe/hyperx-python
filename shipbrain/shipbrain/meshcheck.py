"""
Mesh checks for any shell mesh (ours, gmsh, ANSA, Patran...): read .bdf / .inp or take nodes + elements directly.

  free_nodes        nodes not used by any element
  duplicate_nodes   different node ids at the same place (elements that look connected but are not)
  parts             connected pieces of the mesh (1 = everything is connected; >1 = loose plates / free elements)
  free_edges        element edges used by one element only (OK on the real outer boundary, wrong inside a joint)
  t_joint_edges     edges shared by 3+ elements (normal at plate joints)
  quality           aspect ratio, min/max corner angle, warpage, inverted elements
"""
import math
import numpy as np


def read_bdf(path):
    nodes, elems, groups = {}, [], []
    def fields(line):
        if ',' in line:
            return [f.strip() for f in line.split(',')]
        return [line[i:i + 8].strip() for i in range(0, len(line.rstrip('\n')), 8)]
    def num(s):
        s = s.strip()
        if not s:
            return 0.0
        try:
            return float(s)
        except ValueError:
            for k in range(1, len(s)):
                if s[k] in '+-' and s[k - 1] not in 'eE':
                    return float(s[:k] + 'e' + s[k:])
            raise
    lines = open(path, errors='replace').read().splitlines()
    i = 0
    while i < len(lines):
        L = lines[i]
        f = fields(L)
        card = f[0].upper().rstrip('*') if f else ''
        if card == 'GRID':
            nodes[int(f[1])] = (num(f[3]), num(f[4]), num(f[5]) if len(f) > 5 else 0.0)
        elif card in ('CQUAD4', 'CTRIA3', 'CQUAD8', 'CTRIA6'):
            k = 4 if card.startswith('CQUAD') else 3
            elems.append([int(x) for x in f[3:3 + k]])
            groups.append(f[2])
        i += 1
    return nodes, elems, groups


def read_inp(path):
    nodes, elems, groups = {}, [], []
    mode, k, eset = None, 0, ''
    for L in open(path, errors='replace'):
        s = L.strip()
        if not s or s.startswith('**'):
            continue
        if s.startswith('*'):
            u = s.upper()
            mode = 'n' if u.startswith('*NODE') and not u.startswith('*NODE ') and 'FILE' not in u and 'PRINT' not in u else None
            if u.startswith('*ELEMENT'):
                t = u.split('TYPE=')[1].split(',')[0].strip() if 'TYPE=' in u else ''
                k = 4 if t.startswith(('S4', 'CPS4', 'M3D4')) else 3 if t.startswith(('S3', 'CPS3', 'M3D3', 'STRI')) else 0
                eset = u.split('ELSET=')[1].split(',')[0].strip() if 'ELSET=' in u else t
                mode = 'e' if k else None
            continue
        p = [x for x in s.split(',') if x.strip()]
        if mode == 'n':
            nodes[int(p[0])] = tuple(float(x) for x in (p[1:4] + ['0'] * 3)[:3])
        elif mode == 'e':
            elems.append([int(x) for x in p[1:1 + k]])
            groups.append(eset)
    return nodes, elems, groups


def check(xyz, elems, groups=None, tol=None):
    """xyz: list (node i+1) or dict id->xyz; elems: lists of node ids"""
    if isinstance(xyz, dict):
        ids = sorted(xyz)
        X = np.array([xyz[i] for i in ids], float)
        idx = {nid: k for k, nid in enumerate(ids)}
    else:
        X = np.array(xyz, float)
        ids = list(range(1, len(X) + 1))
        idx = {i: i - 1 for i in ids}
    E = [[idx[n] for n in e] for e in elems]
    size = float(np.ptp(X, 0).max()) if len(X) else 1.0
    tol = tol or 1e-4 * size
    used = np.zeros(len(X), bool)
    for e in E:
        used[e] = True
    # duplicates (spatial hash)
    dup, cell, grid = 0, tol * 4, {}
    rep = np.arange(len(X))
    for i, p in enumerate(X):
        k = tuple(np.floor(p / cell).astype(int))
        hit = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for j in grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ()):
                        if np.linalg.norm(X[j] - p) <= tol:
                            hit = j
        if hit is None:
            grid.setdefault(k, []).append(i)
        else:
            dup += 1
            rep[i] = hit
    # connectivity (union-find over elements, by node id - duplicates do NOT connect)
    parent = list(range(len(X)))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for e in E:
        r = find(e[0])
        for n in e[1:]:
            parent[find(n)] = r
    parts = {}
    for k, e in enumerate(E):
        parts.setdefault(find(e[0]), []).append(k)
    sizes = sorted((len(v) for v in parts.values()), reverse=True)
    # edges
    cnt = {}
    for e in E:
        if len(e) < 3:                                   # 1D elements: connectivity only
            continue
        for k in range(len(e)):
            key = tuple(sorted((e[k], e[(k + 1) % len(e)])))
            cnt[key] = cnt.get(key, 0) + 1
    free_e = [k for k, c in cnt.items() if c == 1]
    # free edges that sit on top of another edge's line through duplicate nodes = fake joints
    fake = sum(1 for a, b in free_e if rep[a] != a or rep[b] != b)
    # quality
    ar, amin, amax, warp, inv = [], 180.0, 0.0, 0.0, 0
    for e in E:
        if len(e) < 3:
            continue
        P = X[e]
        n = len(P)
        sides = [np.linalg.norm(P[(k + 1) % n] - P[k]) for k in range(n)]
        if min(sides) <= 0:
            inv += 1
            continue
        ar.append(max(sides) / min(sides))
        nrm = np.zeros(3)
        for k in range(n):
            nrm += np.cross(P[k] - P.mean(0), P[(k + 1) % n] - P.mean(0))
        nrm = nrm / (np.linalg.norm(nrm) or 1)
        for k in range(n):
            u, v = P[k - 1] - P[k], P[(k + 1) % n] - P[k]
            c = np.cross(v, u)
            if c @ nrm <= 0:
                inv += 1
                break
            ang = math.degrees(math.acos(max(-1, min(1, u @ v / (np.linalg.norm(u) * np.linalg.norm(v))))))
            amin, amax = min(amin, ang), max(amax, ang)
        if n == 4:
            d = abs((P - P.mean(0)) @ nrm).max()
            warp = max(warp, math.degrees(math.atan2(2 * d, min(sides))))
    out = {'nodes': len(X), 'elements': len(E), 'elements_1d': sum(len(e) == 2 for e in E), 'free_nodes': int((~used).sum()), 'duplicate_nodes': dup,
           'parts': len(parts), 'part_sizes': sizes[:10], 'free_edges': len(free_e), 'free_edges_on_duplicates': fake,
           't_joint_edges': sum(1 for c in cnt.values() if c >= 3),
           'quality': {'max_aspect': round(float(max(ar)), 2) if ar else None, 'aspect_gt_5': int(sum(a > 5 for a in ar)),
                       'min_angle': round(amin, 1), 'max_angle': round(amax, 1), 'max_warp_deg': round(warp, 2),
                       'inverted_or_degenerate': inv}}
    problems = []
    if out['free_nodes']:
        problems.append(f"{out['free_nodes']} free nodes")
    if dup:
        problems.append(f'{dup} duplicate nodes (parts look joined but are not)')
    if len(parts) > 1:
        problems.append(f'mesh is in {len(parts)} unconnected parts (sizes {sizes[:5]})')
    if inv:
        problems.append(f'{inv} inverted/degenerate elements')
    if out['quality']['min_angle'] < 20 or out['quality']['max_angle'] > 160:
        problems.append('poor corner angles (min %.0f, max %.0f deg)' % (amin, amax))
    out['verdict'] = 'ok' if not problems else '; '.join(problems)
    return out


def check_file(path):
    nodes, elems, groups = (read_bdf if path.lower().endswith(('.bdf', '.nas', '.dat', '.fem')) else read_inp)(path)
    if not elems:
        raise ValueError('no shell elements (CQUAD4/CTRIA3 or S4/S3) found in ' + path)
    return check(nodes, elems, groups)
