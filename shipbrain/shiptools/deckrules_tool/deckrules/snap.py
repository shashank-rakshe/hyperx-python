"""Printed dimensions win over traced coordinates.

Traced vector positions are only ~ +/-10..40 mm accurate at 1/100 (line
weight, drafting tolerance, local non-scale details).  Every coordinate the
rules produce is therefore snapped to a PRINTED datum when one is close:

 R-D1  X datums: every frame  X = frame_x(n)  and every printed 'FR.n+d' / 'FR.n-d'.
 R-D2  Y datums: centre line 0 and every printed 'NNNN OFF C.L' (sign from its side).
 R-D3  Printed dimension chains: a dimension line (thin solid, parallel to its
       number, traced length within 12 % of the number) whose one end sits on a
       known datum fixes its other end at  datum +/- printed value.  Iterated, so
       chains like 730+730+... from C.L are resolved exactly.
 R-D4  A traced coordinate within SNAP_TOL of a datum takes the datum value;
       the source of every snapped value is recorded.  Coordinates with no
       datum nearby stay traced and are flagged 'traced'.
"""
import math
import re

SNAP_TOL = 40.0     # mm  (~1.1 pt at 1/100)
CHAIN_TOL = 20.0    # mm  end-on-datum tolerance when propagating a chain
FR_OFF = re.compile(r'FR\.\s*(\d+)\s*([+-])\s*(\d+)')
NUM = re.compile(r'^\d{2,5}$')


class Datums:
    def __init__(self):
        self.d = {'X': {}, 'Y': {}}     # value -> source

    def add(self, axis, val, src):
        val = round(val, 1)
        for k in self.d[axis]:
            if abs(k - val) < 0.6:
                return False
        self.d[axis][val] = src
        return True

    def near(self, axis, val, tol):
        best = None
        for k, s in self.d[axis].items():
            e = abs(k - val)
            if e <= tol and (best is None or e < best[0]):
                best = (e, k, s)
        return best

    def count(self):
        return {a: len(x) for a, x in self.d.items()}


def read_dimensions(page, v):
    """dimension lines whose traced length agrees with the printed number."""
    r = v.region
    nums = [w for w in page.words if NUM.match(w.text.strip())
            and r[0] < w.cx < r[2] and r[1] < w.cy < r[3]]
    segs = [s for s in page.segs if not s.dash and s.width < 0.5 and (s.horizontal or s.vertical)
            and r[0] < s.a[0] < r[2] and r[1] < s.a[1] < r[3]]
    dims = []
    for w in nums:
        val = int(w.text)
        best = None
        for s in segs:
            if not w.vertical and s.horizontal:
                if not (min(s.a[0], s.b[0]) - 1 <= w.cx <= max(s.a[0], s.b[0]) + 1):
                    continue
                d = abs(s.a[1] - w.cy)
            elif w.vertical and s.vertical:
                if not (min(s.a[1], s.b[1]) - 1 <= w.cy <= max(s.a[1], s.b[1]) + 1):
                    continue
                d = abs(s.a[0] - w.cx)
            else:
                continue
            L = s.length * v.k
            if d <= 7 and abs(L - val) <= max(0.12 * val, 40) and (best is None or d < best[0]):
                best = (d, s)
        if best:
            s = best[1]
            if s.horizontal:
                p1, p2 = sorted((v.X(s.a[0]), v.X(s.b[0])))
                dims.append({'axis': 'X', 'p1': p1, 'p2': p2, 'value': val, 'at': v.Y(s.a[1])})
            else:
                p1, p2 = sorted((v.Y(s.a[1]), v.Y(s.b[1])))
                dims.append({'axis': 'Y', 'p1': p1, 'p2': p2, 'value': val, 'at': v.X(s.a[0])})
    return dims


def build(page, v, frame_x, offcl_lines=()):
    D = Datums()
    xs = [v.X(v.region[0]), v.X(v.region[2])]
    for n in range(-50, 400):      # R-D1: any frame whose X lies in (or just outside) the plan - the frame table need not be n*space (owner anchor)
        fxn = frame_x(n)
        if min(xs) - 2 * v.frame_space < fxn < max(xs) + 2 * v.frame_space:
            D.add('X', fxn, f'FR.{n}')
    for w in page.words:
        if not (v.region[0] < w.cx < v.region[2] and v.region[1] < w.cy < v.region[3]):
            continue
        m = FR_OFF.search(w.text)
        if m:
            n, sg, d = int(m.group(1)), m.group(2), int(m.group(3))
            D.add('X', frame_x(n) + (d if sg == '+' else -d), m.group(0).replace(' ', ''))
    # R-D6 (2026-10-25): fractional frame labels 'FR.19+1/2' = X(n) + a/b of THAT bay (R-FC2) are datums too. Without it the deck edge
    # at FR.19+1/2 stayed at the traced wall line 31208 (8 mm short of 31200) and the members ended 31196..31200.
    import re as _re
    for w in page.words:
        if not (v.region[0] < w.cx < v.region[2] and v.region[1] < w.cy < v.region[3]):
            continue
        mf = _re.search(r'FR\.?\s*(\d{1,3})\s*([+-])\s*(\d)\s*/\s*(\d)\b', w.text)
        if mf:
            n, sg, a, b = int(mf.group(1)), mf.group(2), int(mf.group(3)), int(mf.group(4))
            if b and 0 < a < b:
                if sg == '+':
                    D.add('X', frame_x(n) + a / b * (frame_x(n + 1) - frame_x(n)), mf.group(0).replace(' ', ''))
                else:
                    D.add('X', frame_x(n) - a / b * (frame_x(n) - frame_x(n - 1)), mf.group(0).replace(' ', ''))
    # R-D5: bare frame-offset labels '47- 4000' / '47+1200' (superscript offset, no 'FR.') = X datum frame +/- offset
    for w in page.words:
        if not (v.region[0] < w.cx < v.region[2] and v.region[1] < w.cy < v.region[3]) or w.vertical:
            continue
        m = re.fullmatch(r'(\d{1,3})\s*([+-])\s*(\d{3,5})', w.text.strip())
        if m:
            n, sg, d = int(m.group(1)), m.group(2), int(m.group(3))
            D.add('X', frame_x(n) + (d if sg == '+' else -d), f'FR.{n}{sg}{d}')
    D.add('Y', 0.0, 'C.L')
    for val, y_ship in offcl_lines:
        sg = 1 if y_ship >= 0 else -1
        D.add('Y', sg * val, f'{val} OFF C.L ({"P" if sg > 0 else "S"})')
    dims = read_dimensions(page, v)
    added = 0
    changed = True
    while changed:
        changed = False
        for dm in dims:
            ax = dm['axis']
            for end, other, sg in (('p1', 'p2', 1), ('p2', 'p1', -1)):
                hit = D.near(ax, dm[end], CHAIN_TOL)
                if not hit:
                    continue
                new = hit[1] + sg * dm['value']
                if abs(new - dm[other]) <= max(25.0, 0.03 * dm["value"], 40.0 if dm["value"] <= 80 else 0.0):      # short dimensions (35): arrows make the traced length unreliable
                    if D.add(ax, new, f"{hit[2]} {'+' if sg > 0 else '-'} printed {dm['value']}"):
                        added += 1
                        changed = True
    return D, {'dimensions_read': len(dims), 'datums_from_dimensions': added, 'datums': D.count()}


def snap_value(D, axis, val, log):
    hit = D.near(axis, val, SNAP_TOL)
    if hit:
        log['printed'] += 1
        return hit[1], hit[2]
    log['traced'] += 1
    return val, 'traced'


def snap_members(D, members):
    log = {'printed': 0, 'traced': 0}
    for m in members:
        (ax, ay), (bx, by) = m['a'], m['b']
        o = 'H' if abs(by - ay) < 0.03 * abs(bx - ax) + 1 else 'V' if abs(bx - ax) < 0.03 * abs(by - ay) + 1 else 'D'
        src = {}
        if o == 'H':
            y, src['y'] = snap_value(D, 'Y', (ay + by) / 2, log)
            ax, src['x1'] = snap_value(D, 'X', ax, log)
            bx, src['x2'] = snap_value(D, 'X', bx, log)
            ay = by = y
        elif o == 'V':
            x, src['x'] = snap_value(D, 'X', (ax + bx) / 2, log)
            ay, src['y1'] = snap_value(D, 'Y', ay, log)
            by, src['y2'] = snap_value(D, 'Y', by, log)
            ax = bx = x
        else:
            ax, src['x1'] = snap_value(D, 'X', ax, log)
            ay, src['y1'] = snap_value(D, 'Y', ay, log)
            bx, src['x2'] = snap_value(D, 'X', bx, log)
            by, src['y2'] = snap_value(D, 'Y', by, log)
        m['a'], m['b'] = (ax, ay), (bx, by)
        m['coord_source'] = src
    return log


def snap_polygon(D, poly, log):
    from shapely.geometry import Polygon

    def ring(cs):
        out = []
        for x, y in cs:
            x2, _ = snap_value(D, 'X', x, log)
            y2, _ = snap_value(D, 'Y', y, log)
            out.append((x2, y2))
        return out
    p = Polygon(ring(poly.exterior.coords), [ring(i.coords) for i in poly.interiors])
    if not p.is_valid:
        p = p.buffer(0)
    return p
