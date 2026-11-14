"""R-SY (side-symmetry rule, from the project rule library / drawing note): most views show the port side only, with
similar starboard geometry. A drawn target-side view always wins; only when the opposite side is NOT built for the same
tier / frame is the drawn side reflected across the centre line. Reflected items are tagged in Evidence."""
import copy


def mirror_walls(panels):
    from shapely.geometry import Polygon
    have = {(round(p['y']), p['tier']) for p in panels}
    out = []
    for p in panels:
        y = round(p['y'])
        if y == 0 or (-y, p['tier']) in have:
            continue
        # a panel of the other side already covering this one (read with its own tiers) is the drawn other side: no mirror copy
        P_ = Polygon(p['poly']) if len(p.get('poly') or []) >= 3 else None
        if P_ is not None and P_.area > 0 and sum(Polygon(o['poly']).intersection(P_).area for o in panels
                                                  if round(o['y']) == -y and len(o.get('poly') or []) >= 3) > 0.5 * P_.area:
            continue
        q = copy.deepcopy(p)
        q['y'] = -p['y']
        q['name'] = p['name'] + '|mirrored'
        for s in q['stiffeners'] + q.get('hstiff', []):
            s['evidence'] = ('mirrored (side symmetry) ' + s['evidence'])[:300]
        out.append(q)
        have.add((-y, p['tier']))
    return out


def mirror_sections(panels):
    have = {(round(p['x']), p['tier'], p['side']) for p in panels}
    out = []
    for p in panels:
        o = 'S' if p['side'] == 'P' else 'P'
        if (round(p['x']), p['tier'], o) in have:
            continue
        q = copy.deepcopy(p)
        q['side'] = o
        q['poly'] = [(-u, v) for u, v in reversed(p['poly'])]
        q['name'] = p['name'] + '|mirrored'
        for s in q['stiffeners']:
            s['u'] = -s['u']
            s['evidence'] = ('mirrored (side symmetry) ' + s['evidence'])[:300]
        for s in q.get('hstiff', []):
            s['u0'], s['u1'] = -s['u1'], -s['u0']
            s['evidence'] = ('mirrored (side symmetry) ' + s['evidence'])[:300]
        out.append(q)
        have.add((round(p['x']), p['tier'], o))
    return out
