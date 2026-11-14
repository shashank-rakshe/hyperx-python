"""Deck sheer (R-SH): '(SHEER : n)' printed on a deck plan.

  Whole slanted plan  ('SLANTED' above the label, end heights 'Za A/B' ... 'Zb A/B' printed at the left and right of the
  plan, e.g. WEATHER SHIELD 40790 -> 40890): the whole deck is one plate tilted about Y, Z = Za at the aft edge, Zb at the
  forward edge.
  End strip (a 4-digit dimension printed just above the label, e.g. '1000' + 'REVERSE (SHEER : 50)'): a strip of that length
  at the deck's X edge nearest the label, tilted about Y; the end of the strip is n higher than the knuckle (learned from
  the 1005 reference COMP strip: 1000 long, 50 high, end higher).  The sign for other ships is an open item.
"""
import re

SHEER = re.compile(r'\(\s*SHEER\s*:\s*(\d+)\s*\)')
AB = re.compile(r'^(\d{5})\s*A/B$')


def find(page, v, bounds):
    xmin, ymin, xmax, ymax = bounds
    out = []
    others = getattr(v, '_others', None) or [v]
    for w in page.words:
        m = SHEER.search(w.text)
        if not m or w.vertical:
            continue
        cands = [o for o in others if o.title[3] < w.cy < o.title[3] + 1800 and abs((o.title[0] + o.title[2]) / 2 - w.cx) < 450]
        own = min(cands, key=lambda o: (w.cy - o.title[3]) + 2 * abs((o.title[0] + o.title[2]) / 2 - w.cx), default=v)
        if own is not v:
            continue
        n = float(m.group(1))
        near = [u for u in page.words if abs(u.cx - w.cx) < 90 and -45 < w.cy - u.cy < 0.1 or abs(u.cx - w.cx) < 90 and 0 < w.cy - u.cy < 45]
        slanted = any(u.text.upper().startswith('SLANTED') for u in near)
        row = [u for u in page.words if abs(u.cy - w.cy) < 30 and AB.match(u.text.strip())]
        if slanted and len(row) >= 2:
            row.sort(key=lambda u: u.cx)
            za, zb = float(AB.match(row[0].text.strip()).group(1)), float(AB.match(row[-1].text.strip()).group(1))
            if za != zb and v.X(row[-1].cx) > v.X(row[0].cx):
                slope = (zb - za) / (xmax - xmin)
                out.append({'mode': 'whole', 'n': n, 'x0': xmin - 1, 'x1': xmax + 1, 'xr': xmin, 'zr': za, 'slope': slope,
                            'src': f'label {w.text!r} + end heights {za:g}/{zb:g}'})
                continue
        dims = [u for u in page.words if re.fullmatch(r'\d{3,4}', u.text.strip()) and not u.vertical
                and abs(u.cx - w.cx) < 60 and 0 < w.cy - u.cy < 60]
        if not dims:
            continue
        d = min(dims, key=lambda u: abs(u.cx - w.cx) + abs(w.cy - u.cy))
        L = float(d.text)
        if not (300 <= L <= 3000):
            continue
        xl = v.X(w.cx)
        aft = abs(xl - xmin) < abs(xl - xmax)
        x0, x1 = (xmin, xmin + L) if aft else (xmax - L, xmax)
        xr, xe = (x1, xmin) if aft else (x0, xmax)        # knuckle edge / free end
        slope = n / L if not aft else -n / L
        out.append({'mode': 'strip', 'n': n, 'x0': x0 - 1, 'x1': x1 + 1, 'xr': xr, 'zr': None, 'slope': slope, 'L': L,
                    'src': f'label {w.text!r} + dimension {L:g} at the {"aft" if aft else "forward"} edge'})
    return out[0] if out else None
