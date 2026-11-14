"""
Design building blocks (the early-stage ship design method: the vessel as physical blocks of volume and area grouped by function and linked to requirements) - ShipBrain's own calculator, written
from the method's description; not derived from any particular editor.

  blocks        [{name, group, shape: box|cylinder|sphere|volume, size (m) or volume (m3), density (t/m3), cg [x, y, z] (m), fullness 0..1, requirement}]
  requirements  [{name, metric: weight|volume|area|total_weight|length|beam|height, direction: at_least|at_most, shall, should, blocks (names) or group}]

  result        weight and volume per block and per group, total weight and centre of gravity, the status of every requirement (red: shall not met, green: between shall and should,
                orange: beyond the should = an excess) and the weights (mass, cg) that ship_hydrostatics / gz_curve take.
"""
import math


def volume_of(b):
    if b.get('volume') is not None:
        return float(b['volume'])
    s = b.get('shape', 'box')
    z = b.get('size', [1, 1, 1])
    if s == 'box':
        return float(z[0] * z[1] * z[2])
    if s == 'cylinder':
        return float(math.pi * (z[0] / 2) ** 2 * z[2])                      # size = [diameter, diameter, length]
    if s == 'sphere':
        return float(4 / 3 * math.pi * (z[0] / 2) ** 3)
    raise ValueError(f"block {b.get('name')}: shape must be box, cylinder, sphere or give a volume")


def footprint(b):
    """plan area of the block (m2): box length x breadth, cylinder along x"""
    s = b.get('shape', 'box')
    z = b.get('size', [1, 1, 1])
    if b.get('volume') is not None and 'size' not in b:
        return 0.0
    return float(z[0] * z[1]) if s == 'box' else float(z[0] * z[2] if s == 'cylinder' else math.pi * (z[0] / 2) ** 2)


def analyse(blocks, requirements=(), hull=None):
    if not blocks:
        raise ValueError('give at least one block')
    rows = []
    for b in blocks:
        v = volume_of(b)
        dens = float(b.get('density', 0.0))
        fullness = float(b.get('fullness', 1.0))
        m = v * dens * fullness
        cg = [float(c) for c in b.get('cg', [0, 0, 0])]
        rows.append({'name': b['name'], 'group': b.get('group', 'ungrouped'), 'volume_m3': v, 'area_m2': footprint(b), 'weight_t': m, 'cg': cg})
    W = sum(r['weight_t'] for r in rows)
    if W <= 0:
        raise ValueError('the blocks have no weight: give a density (t/m3) for the blocks that carry weight')
    cg = [sum(r['weight_t'] * r['cg'][i] for r in rows) / W for i in range(3)]
    groups = {}
    for r in rows:
        g = groups.setdefault(r['group'], {'weight_t': 0.0, 'volume_m3': 0.0, 'area_m2': 0.0, 'mx': [0.0, 0.0, 0.0]})
        g['weight_t'] += r['weight_t']
        g['volume_m3'] += r['volume_m3']
        g['area_m2'] += r['area_m2']
        for i in range(3):
            g['mx'][i] += r['weight_t'] * r['cg'][i]
    for g in groups.values():
        g['cg'] = [round(m / g['weight_t'], 3) if g['weight_t'] else None for m in g.pop('mx')]
        g['weight_t'] = round(g['weight_t'], 3)
        g['volume_m3'] = round(g['volume_m3'], 3)
        g['area_m2'] = round(g['area_m2'], 3)
    reqs = []
    bx = [min(r['cg'][0] - 0 for r in rows), max(r['cg'][0] for r in rows)]
    for q in requirements:
        met = q['metric']
        sel = [r for r in rows if r['name'] in set(q.get('blocks', [])) or (q.get('group') and r['group'] == q['group'])]
        if met == 'weight':
            val = sum(r['weight_t'] for r in sel)
        elif met == 'volume':
            val = sum(r['volume_m3'] for r in sel)
        elif met == 'area':
            val = sum(r['area_m2'] for r in sel)
        elif met == 'total_weight':
            val = W
        elif met in ('length', 'beam', 'height'):
            if not hull:
                raise ValueError(f"requirement {q['name']}: {met} needs the hull dimensions (hull = {{L, B, D}})")
            val = float({'length': hull['L'], 'beam': hull['B'], 'height': hull['D']}[met])
        else:
            raise ValueError(f"requirement {q['name']}: unknown metric {met}")
        d = q.get('direction', 'at_least')
        shall = float(q['shall'])
        should = float(q['should']) if q.get('should') is not None else None
        ok = val >= shall if d == 'at_least' else val <= shall
        if not ok:
            st = 'red'                                                              # the shall is not met
        elif should is not None and ((d == 'at_least' and val > should) or (d == 'at_most' and val < should)):
            st = 'orange'                                                           # beyond the should: more than needed (an excess)
        else:
            st = 'green'                                                            # between shall and should
        reqs.append({'name': q['name'], 'metric': met, 'direction': d, 'shall': shall, 'should': should, 'value': round(val, 3), 'status': st, 'margin': round(val - shall if d == 'at_least' else shall - val, 3)})
    return {'blocks': rows, 'groups': groups, 'total_weight_t': round(W, 3), 'cg': [round(c, 3) for c in cg], 'requirements': reqs,
            'weights_for_hydrostatics': [{'name': r['name'], 'mass_t': r['weight_t'], 'cg': r['cg']} for r in rows if r['weight_t'] > 0]}
