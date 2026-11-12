"""
Hydrostatics and initial stability with Vessel.js (https://github.com/shiplab/vesseljs, MIT, NTNU Ship Design and Operation Lab; the library's ES modules are copied unchanged
into vendor/vesseljs and run in Node.js). ShipBrain makes the ship specification from plain numbers (box, Wigley or a table of half-breadths, plus weights with their centres of
gravity) or takes a Vessel.js specification the user uploaded, runs the library and reads the numbers back:

    analyse(L, B, D, hull='box', weights=[{'name', 'mass_t', 'cg': [x, y, z]}], ...)   draft, trim, heel, KB, BM, KG, GM, drafts forward / aft, hydrostatic table
    run(spec, drafts=None, mass_kg=None)                                               any Vessel.js specification

Needs Node.js (https://nodejs.org, free). Metres, tonnes; x from the aft end, y to port, z up from the keel.
"""
import json, math, os, shutil, subprocess

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'vesseljs')


def node():
    return shutil.which('node') or shutil.which('nodejs')


def run(spec, drafts=None, mass_kg=None, action='stability', rho=None, timeout=120):
    x = node()
    if not x:
        raise RuntimeError('Node.js is not installed: install it (free, https://nodejs.org) and ask again - Vessel.js runs in Node.')
    req = {'spec': spec, 'action': action}
    if drafts is not None:
        req['drafts'] = [float(d) for d in drafts]
    if mass_kg is not None:
        req['mass_kg'] = float(mass_kg)
    r = subprocess.run([x, os.path.join(ROOT, 'runner.mjs')], input=json.dumps(req), capture_output=True, text=True, timeout=timeout, cwd=ROOT)
    line = next((l for l in reversed(r.stdout.splitlines()) if l.startswith('{')), None)
    if not line:
        raise RuntimeError('Vessel.js did not answer: ' + (r.stderr or r.stdout)[-400:])
    out = json.loads(line)
    if 'error' in out:
        raise ValueError('Vessel.js: ' + out['error'])
    return out


# ====================================================================== hull tables
def hull_table(kind, L, B, D, T=None, n_st=21, n_wl=13):
    """Vessel.js half-breadth table: stations as fractions of LOA, waterlines as fractions of the depth, half-breadths as fractions of B / 2"""
    if kind == 'box':
        return {'waterlines': [0, 0, 1], 'stations': [0, 1], 'table': [[0, 0], [1, 1], [1, 1]]}
    if kind == 'wigley':
        T = T or 0.6 * D
        sts = np.linspace(0, 1, n_st)
        wls = np.unique(np.concatenate([np.linspace(0, T / D, n_wl), [1.0]]))
        tab = []
        for w in wls:
            z = min(w * D, T)                                              # above the design waterline the sides stay vertical
            u = z / T
            tab.append([max(0.0, (1 - (2 * s - 1) ** 2) * (1 - (1 - u) ** 2)) for s in sts])
        return {'waterlines': [round(float(w), 6) for w in wls], 'stations': [round(float(s), 6) for s in sts], 'table': [[round(float(v), 6) for v in r] for r in tab]}
    raise ValueError("hull must be 'box', 'wigley' or give a table")


def make_spec(L, B, D, hull='box', weights=(), T_design=None, table=None):
    """Vessel.js specification: the hull, and every weight as a point mass (mass in tonnes, cg [x, y, z] in m) - no structural weight is added by the library (K = 0)"""
    tab = table or hull_table(hull, L, B, D, T_design)
    base, derived = [], []
    for i, w in enumerate(weights):
        m, cg = float(w['mass_t']) * 1000.0, w.get('cg', [L / 2, 0, D / 2])
        base.append({'id': f'w{i}', 'affiliations': {}, 'boxDimensions': {'length': 0.1, 'breadth': 0.1, 'height': 0.1}, 'capabilities': {}, 'baseState': {'fullness': 0},
                     'weightInformation': {'contentDensity': 0, 'volumeCapacity': 0, 'lightweight': m, 'cg': [0, 0, 0]}})
        derived.append({'id': f'W{i}', 'baseObject': f'w{i}', 'affiliations': {'group': 'weights'}, 'referenceState': {'xCentre': cg[0], 'yCentre': cg[1], 'zBase': cg[2]}})
    return {'attributes': {}, 'designState': {'calculationParameters': {'LWL_design': L, 'BWL': B, 'Draft_design': T_design or D / 2, 'Cb_design': 0.7, 'speed': 0, 'crew': 0, 'K': 1e-12,
                                                                          'MCR': 0, 'SFC': 0, 'Co': 0, 'tripDuration': 0}, 'objectOverrides': {}},
            'structure': {'hull': {'attributes': {'LOA': L, 'BOA': B, 'Depth': D, 'APP': 0}, 'halfBreadths': tab, 'buttockHeights': {}, 'affiliations': {'SBSD': 'Hull', 'group': 'structure'}},
                          'decks': {}, 'bulkheads': {}},
            'baseObjects': base, 'derivedObjects': derived}


def analyse(L, B, D, hull='box', weights=(), T_design=None, table=None, drafts=None, rho=1025.0):
    """draft, trim, heel, KB, BM, KG, GM and a hydrostatic table for a hull and its weights"""
    if not weights:
        raise ValueError('give the weights: the lightship and everything on board as mass (t) and centre of gravity [x, y, z] (m)')
    # the library turns mass into volume with 1025 kg/m3; other water: scale all masses by 1025 / rho (same displaced volume, same centre of gravity)
    k = 1025.0 / rho
    spec = make_spec(L, B, D, hull, [dict(w, mass_t=float(w['mass_t']) * k) for w in weights], T_design, table)
    ds = drafts or [round(D * f, 4) for f in (0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)]
    out = run(spec, drafts=ds)
    st = out['stability']
    mass_t = st['mass_kg'] / 1000.0 / k
    hs = out['hydrostatics']
    for h in hs:
        h['displacement_t'] = h['Vs'] * rho / 1000.0
    out['summary'] = {'mass_t': round(mass_t, 3), 'draft_m': round(st['T'], 4), 'KB_m': round(st['KB'], 4), 'BMt_m': round(st['BMt'], 4), 'KG_m': round(st['KG'], 4), 'GMt_m': round(st['GMt'], 4),
                      'GMl_m': round(st['GMl'], 3), 'trim_deg': round(st['trim_deg'], 4), 'draft_fwd_m': st['draftfp'], 'draft_aft_m': st['draftap'], 'heel_offset_m': st['heel_m'],
                      'LCG_m': round(st['cg']['x'], 4), 'rho_kg_m3': rho}
    return out
