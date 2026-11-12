"""
OpenHCM (Hull Condition Model) XML reader - the open ship-structure file format of the OpenHCM Consortium (https://github.com/OpenHCMStandard; the viewer from Bureau Veritas, Apache-2.0, is in
the knowledge pack OpenHCMViewer and was the reference for the element names). ShipBrain's own Python reader (no viewer code): plates with outer / inner contours (or a triangle mesh), stiffeners
with their trace line, type, height, thickness, flanges, and the compartment names. It summarises the model and converts the plates and stiffeners that ShipBrain's plate mesher can use
(flat contour plates, straight stiffener segments) into a shell mesh for CalculiX.

Written from the element and attribute names the viewer reads (Plate id / thickness / OuterContour / InnerContour / Vertex x y z / Mesh / Triangle; Stiffener id / type / orientation / thickness / height /
offset / TraceLine / Orientations / Flanges; Compartment name). Checked on a model written to that description - no real OpenHCM file was available where this was built.
"""
import math
import xml.etree.ElementTree as ET

import numpy as np

STEEL = 7850.0


def _local(tag):
    return tag.rsplit('}', 1)[-1]


def _find_all(el, name):
    return [e for e in el.iter() if _local(e.tag) == name]


def _kids(el, name):
    return [e for e in el if _local(e.tag) == name]


def _verts(el):
    return [[float(v.get('x')), float(v.get('y')), float(v.get('z'))] for v in _find_all(el, 'Vertex')]


def read(path):
    root = ET.parse(path).getroot()
    plates, stiffeners = [], []
    for p in _find_all(root, 'Plate'):
        d = {'id': p.get('id'), 't': float(p.get('thickness', 0) or 0)}
        mesh = _kids(p, 'Mesh')
        if mesh:
            d['kind'] = 'mesh'
            d['vertices'] = _verts(mesh[0])
            d['triangles'] = [[int(t.get(k)) for k in ('v1', 'v2', 'v3')] if t.get('v1') is not None else [int(x) for x in (t.text or '').split()] for t in _find_all(mesh[0], 'Triangle')]
        else:
            outer = _kids(p, 'OuterContour')
            d['kind'] = 'contour'
            d['outline'] = _verts(outer[0]) if outer else []
            d['holes'] = [_verts(h) for h in _kids(p, 'InnerContour')]
        plates.append(d)
    for s in _find_all(root, 'Stiffener'):
        tl = _kids(s, 'TraceLine')
        stiffeners.append({'id': s.get('id'), 'type': (s.get('type') or '').strip(), 'orientation': s.get('orientation'), 't': float(s.get('thickness', 0) or 0), 'h': float(s.get('height', 0) or 0),
                           'offset': float(s.get('offset', 0) or 0), 'trace': _verts(tl[0]) if tl else [],
                           'flanges': [{'position': f.get('position'), 'b': float(f.get('breadth', 0) or 0), 't': float(f.get('thickness', 0) or 0)} for f in _find_all(s, 'Flange')]})
    comps = [c.get('name') for c in _find_all(root, 'Compartment')]
    return {'plates': plates, 'stiffeners': stiffeners, 'compartments': comps}


def _area(poly):
    P = np.array(poly, float)
    if len(P) < 3:
        return 0.0
    c = P.mean(axis=0)
    return float(0.5 * np.linalg.norm(sum(np.cross(P[i] - c, P[(i + 1) % len(P)] - c) for i in range(len(P)))))


def summary(m):
    n_c = [p for p in m['plates'] if p['kind'] == 'contour']
    area = sum(_area(p['outline']) - sum(_area(h) for h in p['holes']) for p in n_c)
    for p in m['plates']:
        if p['kind'] == 'mesh':
            V = np.array(p['vertices'])
            area += sum(0.5 * np.linalg.norm(np.cross(V[t[1]] - V[t[0]], V[t[2]] - V[t[0]])) for t in p['triangles'])
    mass_plate = sum((_area(p['outline']) - sum(_area(h) for h in p['holes'])) * p['t'] for p in n_c) * 1e-9 * STEEL if n_c else 0.0   # mm -> m3 x density
    length = sum(float(np.linalg.norm(np.diff(np.array(s['trace']), axis=0), axis=1).sum()) for s in m['stiffeners'] if len(s['trace']) > 1)
    pts = [v for p in m['plates'] for v in (p.get('outline') or p.get('vertices') or [])] + [v for s in m['stiffeners'] for v in s['trace']]
    box = (np.array(pts).min(0).tolist(), np.array(pts).max(0).tolist()) if pts else None
    th = sorted({p['t'] for p in m['plates']})
    return {'plates': len(m['plates']), 'plates_with_contour': len(n_c), 'plates_with_triangle_mesh': len(m['plates']) - len(n_c), 'stiffeners': len(m['stiffeners']), 'compartments': len(m['compartments']),
            'plate_area_m2_if_mm': round(float(area) * 1e-6, 3), 'plate_mass_t_if_mm': round(float(mass_plate) / 1000.0, 3), 'stiffener_length_m_if_mm': round(float(length) * 1e-3, 2), 'thicknesses': th[:30],
            'stiffener_types': sorted({s['type'] for s in m['stiffeners']}), 'bbox': box}


def _profile(s):
    t = s['type'].lower()
    fl = s['flanges'][0] if s['flanges'] else None
    if fl and ('t' in t.split() or t in ('t', 'tbar', 't-bar', 'tee') or 'tee' in t):
        return {'type': 'TBar', 'h': s['h'], 't': s['t'], 'bf': fl['b'], 'tf': fl['t']}
    if fl and (t in ('l', 'lbar', 'l-bar', 'angle') or 'angle' in t):
        return {'type': 'LBar', 'h': s['h'], 't': s['t'], 'bf': fl['b'], 'tf': fl['t']}
    if 'bulb' in t or t in ('hp', 'hp-profile'):
        return {'type': 'HP', 'h': s['h'], 't': s['t']}
    return {'type': 'FlatBar', 'h': s['h'], 't': s['t']}


def to_plate_spec(m, element_size=100.0, name='openhcm', planar_tol=1.0):
    """ShipBrain plate-mesher input from the contour plates that are flat (within planar_tol) and the stiffener segments; returns (spec, report)"""
    plates, skipped, beams = [], [], []
    for p in m['plates']:
        if p['kind'] != 'contour' or len(p['outline']) < 3:
            skipped.append(f"{p['id']}: " + ('triangle mesh plate' if p['kind'] == 'mesh' else 'no contour'))
            continue
        P = np.array(p['outline'], float)
        n = np.cross(P[1] - P[0], P[2] - P[0])
        if np.linalg.norm(n) < 1e-9:
            skipped.append(f"{p['id']}: degenerate contour")
            continue
        n = n / np.linalg.norm(n)
        if np.abs((P - P[0]) @ n).max() > planar_tol:
            skipped.append(f"{p['id']}: not flat")
            continue
        plates.append({'id': p['id'], 'group': p['id'], 't': p['t'] or 10.0, 'outline': p['outline'], 'holes': p['holes']})
    for s in m['stiffeners']:
        prof = _profile(s)
        for k in range(len(s['trace']) - 1):
            beams.append({'id': f"{s['id']}_{k}", 'a': s['trace'][k], 'b': s['trace'][k + 1], 'profile': prof, 'normal': [0, 0, -1]})
    return {'name': name, 'element_size': element_size, 'plates': plates, 'beams': beams}, {'plates_meshed': len(plates), 'plates_skipped': skipped[:20], 'stiffener_segments': len(beams)}
