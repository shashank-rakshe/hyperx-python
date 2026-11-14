"""R-IN1: hatched circle with 'Ø D OUT DIA' = thick insert plate (pillar seat) in the deck, not a hole.
Thickness / grade from the section the plan names beside it ("1A3-5": 20.0 "AH" hatched band, 'XXXX MARKED: SEE DET. "1A2-1"' = full penetration weld).
The circle is fitted from the thick outline strokes round the leader tip; the insert replaces the deck plate inside the circle."""
import re, math
from shapely.geometry import Point
from . import details

LAB = re.compile(r'OUT\s*DIA')


def _fit(pts):
    n = len(pts)
    sx = sum(p[0] for p in pts); sy = sum(p[1] for p in pts)
    mx, my = sx / n, sy / n
    suu = suv = svv = suuu = svvv = suvv = svuu = 0.0
    for x, y in pts:
        u, w = x - mx, y - my
        suu += u * u; svv += w * w; suv += u * w
        suuu += u ** 3; svvv += w ** 3; suvv += u * w * w; svuu += w * u * u
    det = suu * svv - suv * suv
    if abs(det) < 1e-9:
        return None
    uc = (suuu + suvv) / 2.0
    vc = (svvv + svuu) / 2.0
    cu = (uc * svv - vc * suv) / det
    cv = (vc * suu - uc * suv) / det
    r = math.sqrt(cu * cu + cv * cv + (suu + svv) / n)
    return mx + cu, my + cv, r


def find(page, v):
    from .deckplan import leader_tip
    out = []
    for w in page.words:
        if not LAB.search(w.text):
            continue
        r0 = v.region
        if not (r0[0] <= w.cx <= r0[2] and r0[1] <= w.cy <= r0[3]):
            continue
        # diameter: the number printed just above the label
        dd = [u for u in page.words if re.fullmatch(r'\d{3,4}', u.text.strip()) and abs(u.cx - w.cx) < 25 and 0 < w.cy - u.cy < 14]
        if not dd:
            continue
        D = float(dd[0].text)
        R = D / v.k / 2.0
        tip = leader_tip(w, page.segs) or (w.cx, w.cy - 10)
        pts = []
        for s in page.segs:
            if s.width >= 0.5 and not s.dash and s.length < 25:
                for q in (s.a, s.b):
                    d = math.hypot(q[0] - tip[0], q[1] - tip[1])
                    if d < 2.2 * R:
                        pts.append(q)
        # keep points close to the expected circle radius around the best centre guess (leader tip is on the circle)
        best = None
        for gx, gy in [(tip[0] + R * math.cos(a / 8 * math.pi), tip[1] + R * math.sin(a / 8 * math.pi)) for a in range(16)]:
            sel = [p for p in pts if abs(math.hypot(p[0] - gx, p[1] - gy) - R) < 0.12 * R]
            if len(sel) > 12 and (best is None or len(sel) > len(best)):
                best = sel
        if not best:
            continue
        f = _fit(best)
        if not f or abs(f[2] - R) > 0.15 * R:
            continue
        cx, cy, r = f
        ttl = None
        for u in page.words:
            q = re.fullmatch(r'"(\d[A-Z]\d-\d)"', u.text.strip())
            if q and abs(u.cx - cx) < 3 * R and abs(u.cy - cy) < 3 * R and q.group(1) in ('1A3-4', '1A3-5'):
                ttl = q.group(1)
                break
        t, grade = 20.0, 'AH'
        if ttl:
            for vw in details.index(page):
                if vw['title'].startswith('"%s"' % ttl):
                    t = vw.get('ah_thk') or t
                    details.USED.add(vw['title'])
        out.append({'poly': Point(v.X(cx), v.Y(cy)).buffer(D / 2.0, 64), 't': t, 'grade': grade, 'D': D,
                    'source': 'R-IN1 hatched circle %s OUT DIA, section %s: %.1f AH insert (ASSUMED: confirm)' % (D, ttl, t)})
    return out
