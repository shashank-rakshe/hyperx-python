"""Deck camber / sheer strips (R-CB).

  The plans print '(CAMBER : n)' + 'SLANTED' in a vertical label beside a dimension chain; the number printed with it is the
  width L of the slanted strip (e.g. 4440).  The strip lies outboard of an OFF C.L line; the reference models it as a plate
  tilted about the X axis: flat up to the knuckle, then dropping by n at the outer edge.  (Learned from 1005: knuckle =
  printed OFF C.L value + n, e.g. A deck 11690 + 100, B/C deck 11690 + 50; outer edge = OFF C.L + L, e.g. 16130.)
"""
import re
from .view import offcl_lines

CAMBER = re.compile(r'\(\s*CAMBER\s*:\s*(\d+)\s*\)')
CAMBER2 = re.compile(r'CAMBER\s*:?\s*(\d{2,3})\b', re.I)       # R3.6: '(CAMBER : 50)', 'CAMBER: 50', 'SLANTED CAMBER 50'
KL = re.compile(r'^\s*K\.?\s*L\.?\s*$')                         # knuckle line mark


def find(page, v, edges=None):
    r = v.region
    offs = offcl_lines(page, v)
    ys = sorted({y for _, y in offs})
    out = []
    def _owner(w):          # the plan whose title is horizontally nearest (labels sit beside their plan's dimension chain)
        cands = [o for o in (getattr(v, '_others', None) or [v]) if o.title[1] - 250 < w.cy < o.title[3] + 1500]
        return min(cands, key=lambda o: abs((o.title[0] + o.title[2]) / 2 - w.cx), default=v)
    labs = [w for w in page.words if CAMBER.search(w.text) and w.vertical and r[1] < w.cy < r[3] and _owner(w) is v]
    for w in labs:
        n = int(CAMBER.search(w.text).group(1))
        best = None
        for u in page.words:
            if u.vertical and re.fullmatch(r'\d{4}', u.text.strip()) and abs(u.cx - w.cx) < 60 and abs(u.cy - w.cy) < 45:
                L = int(u.text)
                if 1500 <= L <= 9000:
                    d = abs(u.cy - w.cy) + abs(u.cx - w.cx)
                    if best is None or d < best[0]:
                        best = (d, L, u)
        if not best:
            # R-CB3: no dimension beside the label -> the strip runs to the deck edge and the label sits at its middle
            if not edges:
                continue
            yc = v.Y(w.cy)
            sg = 1.0 if yc > 0 else -1.0
            edge = edges[1] if sg > 0 else -edges[0]
            L = 2.0 * (edge - abs(yc))
            if not (1000 <= L <= 9000):
                continue
            inner = abs(yc) - L / 2.0
            L = float(L)
            u = w
            src_extra = ' (edge-based, no dimension)'
        else:
            L, u = best[1], best[2]
            yc = v.Y(u.cy)
            sg = 1.0 if yc > 0 else -1.0
            inner = abs(yc) - L / 2.0
            src_extra = ''
        tol = 60 if not src_extra else 300          # edge-based inner is approximate -> snap harder to the printed chain
        near = [abs(y) for y in ys if y * sg > 0 and abs(abs(y) - inner) < tol]
        if src_extra and not near:
            continue                   # edge-based strip whose start is not on a printed OFF C.L line: not trusted
        inner = min(near, key=lambda a: abs(a - inner)) if near else round(inner / 10.0) * 10.0
        L = (edges[1] if sg > 0 else -edges[0]) - inner if src_extra else L
        out.append({'side': 'P' if sg > 0 else 'S', 'n': float(n), 'inner': inner, 'outer': inner + L, 'L': L,
                    'knuckle': inner + n, 'src': f'label {w.text!r} + dimension {L:g}' + src_extra})
    # R3.6 (online rule book v2.3, 1007 B-deck): a 'K.L' (knuckle line) mark beside an OFF C.L line + a 'SLANTED' / 'CAMBER : n' note in the
    # same view = the deck is flat inboard of the K.L and slopes down n mm from the K.L to the deck edge (parentheses optional, any text direction).
    if not out and edges:
        kls = [w for w in page.words if KL.search(w.text) and r[0] < w.cx < r[2] and r[1] < w.cy < r[3]]
        cn = [CAMBER2.search(w.text) for w in page.words if r[0] < w.cx < r[2] and r[1] < w.cy < r[3]]
        cn = [int(m.group(1)) for m in cn if m and 10 <= int(m.group(1)) <= 400]
        if kls and cn:
            n = max(set(cn), key=cn.count)
            for w in kls:
                yc = v.Y(w.cy)
                sg = 1.0 if yc > 0 else -1.0
                near = [abs(y) for y in ys if y * sg > 0]
                if not near:
                    continue
                kn = min(near, key=lambda a: abs(a - abs(yc)))
                if abs(kn - abs(yc)) > 1500:
                    continue
                edge = edges[1] if sg > 0 else -edges[0]
                if edge - kn < 300:
                    continue
                out.append({'side': 'P' if sg > 0 else 'S', 'n': float(n), 'inner': kn, 'outer': edge, 'L': edge - kn,
                            'knuckle': kn, 'src': f'R3.6 K.L at OFF C.L {kn:g} + CAMBER {n} to the deck edge'})
    # one strip per side: overlapping strips -> keep the one that starts closest to the centre line
    keep = []
    for st in sorted(out, key=lambda t: t['inner']):
        if not any(k['side'] == st['side'] for k in keep):
            keep.append(st)
    return keep
