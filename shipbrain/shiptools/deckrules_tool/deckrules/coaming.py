"""R-CO1: 'COAMING : WxT F.B' label + a thin-line rectangle (plan) + the SEC named on the plan ("1A3-1": plate thickness, drop).
Reading (confirmed by the owner's request 2026-10-23, section 1A3-1): a plate #1 (thickness from the section) slopes from the deck level at the
inner edge of the rectangle down by the section's vertical dimension (650) at the outer edge (the wall at the OFF C.L); the coaming flat bar
stands on the inner edge. Geometry read from the drawing, evidence kept per object."""
import re
from . import details

LAB = re.compile(r'COAMING\s*:\s*(\d+)\s*X\s*(\d+)\s*F\.B')


def _rect_near(page, tip, R=90.0):
    vs, hs = [], []
    for s in page.segs:
        if s.width > 0.5 or s.dash:
            continue
        (x1, y1), (x2, y2) = s.a, s.b
        if min(abs(x1 - tip[0]), abs(x2 - tip[0])) > R or min(abs(y1 - tip[1]), abs(y2 - tip[1])) > R:
            continue
        if abs(x1 - x2) < 0.3 and abs(y1 - y2) > 20:
            vs.append((round(x1, 1), min(y1, y2), max(y1, y2)))
        elif abs(y1 - y2) < 0.3 and abs(x1 - x2) > 20:
            hs.append((round(y1, 1), min(x1, x2), max(x1, x2)))
    best = None
    for i, a in enumerate(vs):
        for b in vs[i + 1:]:
            if abs(a[1] - b[1]) < 1 and abs(a[2] - b[2]) < 1 and abs(a[0] - b[0]) > 20:
                xl, xr = sorted((a[0], b[0]))
                top = [h for h in hs if abs(h[0] - a[1]) < 1 and h[1] <= xl + 1 and h[2] >= xr - 1]
                bot = [h for h in hs if abs(h[0] - a[2]) < 1 and h[1] <= xl + 1 and h[2] >= xr - 1]
                if top and bot:
                    area = (xr - xl) * (a[2] - a[1])
                    if best is None or area > best[0]:
                        best = (area, xl, a[1], xr, a[2])
    return best


def find(page, v):
    from .deckplan import leader_tip
    out = []
    for w in page.words:
        m = LAB.search(w.text)
        if not m:
            continue
        r0 = v.region
        if not (r0[0] <= w.cx <= r0[2] and r0[1] <= w.cy <= r0[3]):      # only the label that belongs to this plan
            continue
        tip = leader_tip(w, page.segs) or (w.cx, w.cy)
        r = _rect_near(page, tip)
        if not r:
            continue
        _, xl, yt, xr, yb = r
        X0, X1 = sorted((v.X(xl), v.X(xr)))
        Ya, Yb = v.Y(yt), v.Y(yb)
        # section named on the plan next to the rectangle ("1A3-1")
        ttl = None
        for u in page.words:
            q = re.fullmatch(r'"(\d[A-Z]\d-\d)"', u.text.strip())
            if q and xl - 40 < u.cx < xr + 40 and yt - 40 < u.cy < yb + 10:
                ttl = q.group(1)
                break
        t, drop = 11.0, 650.0
        if ttl:
            for vw in details.index(page):
                if vw['title'].startswith('"%s"' % ttl):
                    t = vw.get('plate_thk') or t
                    drop = vw.get('drop') or drop
        if ttl:
            details.USED.add('"%s" SEC.' % ttl)
        out.append({'x0': X0, 'x1': X1, 'y_in': Ya, 'y_out': Yb, 't': t, 'drop': drop, 'bar': (float(m.group(1)), float(m.group(2))), 'sec': ttl,
                    'src': 'R-CO1 label %s + rectangle + section %s' % (w.text.strip(), ttl)})
    # inner edge = the one with the smaller |Y|
    for c in out:
        if abs(c['y_in']) > abs(c['y_out']):
            c['y_in'], c['y_out'] = c['y_out'], c['y_in']
    return out
