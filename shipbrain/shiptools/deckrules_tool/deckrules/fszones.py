"""R-FS1 (2026-10-26, 1004 ERM): a frame-number row with 'F.S. : n' labels printed between two numbered frames gives the frame
space of every bay in that zone (F.S. 4200 between 17 and 18, F.S. 1600 between 19 and 21 = two bays of 1600 ...). The labels of
all rows of all sheets vote; a zone value is taken when the rows agree. The X of one frame (anchor) is NOT in the drawing: it comes
from the owner (answer / --anchor). Without an anchor the chain is reported and asked. Offline: PDF text only."""
import re
from collections import defaultdict, Counter

FS = re.compile(r'F\.\s*S\.?\s*:?\s*(\d{3,5})')
FSP = re.compile(r'FRAME\s*SPACE\s*:?\s*(\d{3,5})', re.I)   # R-FS2: 'FRAME SPACE : 1525' over a dimension line between two frame labels


def zones(pdf):
    from . import pdfsrc
    import pymupdf
    votes = defaultdict(Counter)
    for pn in range(len(pymupdf.open(pdf))):
        page = pdfsrc.load_page(pdf, pn)
        fs = [(w, int(v), False, k) for w in page.words if FS.search(w.text) and not w.vertical for k, v in enumerate(FS.findall(w.text))]   # a merged word 'F.S: 900 F.S: 800' = two zones (left to right)
        fs += [(w, int(FSP.search(w.text).group(1)), True, 0) for w in page.words if FSP.search(w.text) and not FS.search(w.text) and not w.vertical]
        if not fs:
            continue
        nums = [w for w in page.words if re.fullmatch(r'\d{1,3}', w.text.strip()) and not w.vertical]
        for w, val, need_dl, kth in fs:
            row = [n for n in nums if 0 < n.cy - w.cy < 25 or 0 < w.cy - n.cy < 25]
            if (not row or need_dl) and not (row and not need_dl):
                row = [n for n in nums if 0 < n.cy - w.cy < 100 or 0 < w.cy - n.cy < 25]       # R-FS2: the number row can stand 40-90 pt under the zone label
            # the frame row nearest to the label (just below or above it)
            if not row:
                continue
            ys = Counter(round(n.cy) for n in row)
            ry = max(ys, key=lambda y: (ys[y], -abs(y - w.cy)))       # the frame-number row = the row with the most numbers
            r_ = sorted([n for n in row if abs(n.cy - ry) < 2], key=lambda n: n.cx)
            # the dimension line under the label spans exactly its zone: its two ends stand on the frames of the zone
            nf = len(FS.findall(w.text))
            if nf > 1:        # merged label: its dimension lines are those under the word, ordered left to right
                dl = sorted([q for q in page.segs if q.horizontal and abs(q.a[1] - w.bbox[3]) < 4 and w.bbox[0] - 40 < min(q.a[0], q.b[0]) and max(q.a[0], q.b[0]) < w.bbox[2] + 40
                             and q.length < 1500], key=lambda q: min(q.a[0], q.b[0]))
                dl = [dl[kth]] if len(dl) >= nf else []
                if not dl:
                    continue
            else:
                dl = [q for q in page.segs if q.horizontal and abs(q.a[1] - w.bbox[3]) < 4 and min(q.a[0], q.b[0]) - 1 < w.cx < max(q.a[0], q.b[0]) + 1
                      and q.length < 1500]
            a = b = None
            if dl:
                q = min(dl, key=lambda q: q.length)
                x0_, x1_ = sorted((q.a[0], q.b[0]))
                la = [n for n in r_ if abs(n.cx - x0_) < 6]
                lb = [n for n in r_ if abs(n.cx - x1_) < 6]
                if not (la and lb):             # R-FS2: the number row may slope (arc) and the line end stand a little off its number: nearest number to each end (<= 20 pt, within 90 pt below/above)
                    yd = q.a[1]
                    def _near(xe):
                        c = [n for n in nums if abs(n.cx - xe) <= (20 if need_dl else 8) and abs(n.cy - yd) < 90 and len(n.text.strip()) <= 2]
                        return [min(c, key=lambda n: (abs(n.cx - xe), abs(n.cy - yd)))] if c else []
                    la, lb = _near(x0_), _near(x1_)
                if la and lb:
                    a, b = int(min(la, key=lambda n: abs(n.cx - x0_)).text), int(min(lb, key=lambda n: abs(n.cx - x1_)).text)
            if a is None and need_dl:
                continue                       # R-FS2: a written 'FRAME SPACE' is a zone only when its own dimension line stands on two frame labels (title notes are not)
            if a is None:
                left = [n for n in r_ if n.cx <= w.cx]
                right = [n for n in r_ if n.cx > w.cx]
                if not left or not right:
                    continue
                a, b = int(left[-1].text), int(right[0].text)
            if b <= a or b - a > 20:
                continue
            votes[(a, b)][val] += 1
    return {k: c.most_common(1)[0][0] for k, c in votes.items()}


def table(pdf, anchor):
    """frame -> X mm, from the F.S. zones and the owner's anchor (frame, X). None when the zones do not chain."""
    z = zones(pdf)
    if not z:
        return None, z
    bay = {}
    for (a, b), v in z.items():
        for n in range(a, b):
            bay.setdefault(n, v)
    ks = sorted(bay)
    for i in range(len(ks) - 1):          # R-FS2: unlabelled bays between two labelled bays of the SAME frame space take that space (the drawing writes the space once per run)
        if ks[i + 1] - ks[i] > 1 and bay[ks[i]] == bay[ks[i + 1]]:
            for n in range(ks[i] + 1, ks[i + 1]):
                bay.setdefault(n, bay[ks[i]])
    na, xa = int(anchor['frame']), float(anchor['x_mm'])
    tab = {na: xa}
    n = na
    while n in bay:
        tab[n + 1] = tab[n] + bay[n]; n += 1
    n = na
    while (n - 1) in bay:
        tab[n - 1] = tab[n] - bay[n - 1]; n -= 1
    return (tab if len(tab) > 1 else None), z
