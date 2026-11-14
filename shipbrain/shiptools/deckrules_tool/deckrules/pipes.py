"""Pipe members (R-PI): '150A SCH80' written vertically beside a pipe drawn as two solid lines with a dashed centre line.

  nominal size ('150A') + schedule ('80') -> outside diameter and wall thickness come ONLY from the pipe schedule table the owner
  supplies (CSV: nominal,schedule,od_mm,thickness_mm; setting pipe_table_csv).  No table / no row -> the pipe is reported as pending
  and nothing is written: sizes are never guessed.
  Position: X = the dashed centre line, Z = its ends (deck underside to the pad / lower deck); Y = the view's OFF C.L.
  A pipe is a pillar (PillarGroup, BarShape Tube{OD}*{t}, BarType 70) - not a wall: the narrow double line is not a plate.
"""
import csv
import os
import re

PIPE_LABEL = re.compile(r'^\s*(\d{2,3})\s*A\s*SCH\.?\s*(\d{2,3})\s*$', re.I)


def load_table(path, base=None):
    """{(nominal 'A' string, schedule string): (od, t)} from a CSV with header nominal,schedule,od_mm,thickness_mm"""
    tab = {}
    if not path:
        return tab
    if base and not os.path.isabs(path):
        path = os.path.join(base, path)
    if not os.path.exists(path):
        return tab
    with open(path, encoding='utf-8-sig') as f:
        for row in csv.reader(f):
            if len(row) < 4 or row[0].strip().startswith('#'):
                continue
            try:
                n = re.sub(r'\D', '', row[0])
                s = re.sub(r'\D', '', row[1])
                tab[(n, s)] = (float(row[2]), float(row[3]))
            except ValueError:
                continue
    return tab


def find(page, v, region):
    """pipes of one elevation view: [{'px','y0','y1','nominal','sch','label'}] (page coordinates)"""
    x0, y0, x1, y1 = region
    out = []
    for w in page.words:
        m = PIPE_LABEL.match(w.text)
        if not m or not w.vertical:
            continue
        if not (x0 - 20 < w.cx < x1 + 20 and y0 - 20 < w.cy < y1 + 60):
            continue
        cand = [s for s in page.segs if s.vertical and s.dash and s.length > 15 and w.bbox[0] - 6 < s.a[0] < w.bbox[2] + 30
                and abs((s.a[1] + s.b[1]) / 2 - w.cy) < 90]
        if not cand:
            continue
        # the dashed centre line nearest to the label
        x_near = min(cand, key=lambda s: abs(s.a[0] - w.bbox[2])).a[0]
        near = [s for s in cand if abs(s.a[0] - x_near) < 8]
        xc = (min(s.a[0] for s in near) + max(s.a[0] for s in near)) / 2.0      # centre of the dashed lines of this pipe
        grp = near
        ya, yb = min(min(s.a[1], s.b[1]) for s in grp), max(max(s.a[1], s.b[1]) for s in grp)
        out.append({'px': xc, 'y0': ya, 'y1': yb, 'nominal': m.group(1), 'sch': m.group(2), 'label': w.text.strip()})
    return out
