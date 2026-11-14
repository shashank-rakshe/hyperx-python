"""Read one PDF page into display-oriented primitives (lines, arcs, words).

All coordinates are in display points (page rotation applied), so on a
plan view +x_page is ship forward and +y_page is towards starboard when the
plan is drawn 'looking downward' with bow to the right (checked later).
"""
from dataclasses import dataclass, field
import math
import re
import pymupdf


@dataclass
class Seg:
    a: tuple
    b: tuple
    width: float
    dash: str          # '' solid, else normalised dash signature
    pid: int           # drawing path index (provenance)
    kind: str = 'l'    # 'l' line, 'c' bezier chord

    # P5: length / horizontal / vertical are read tens of millions of times per run: computed once (segments are never moved)
    def __post_init__(self):
        L = math.dist(self.a, self.b)
        m = 0.05 * max(L, 1e-9)
        self.length = L
        self.horizontal = abs(self.a[1] - self.b[1]) < m
        self.vertical = abs(self.a[0] - self.b[0]) < m


@dataclass
class Word:
    text: str
    bbox: tuple        # display coords x0,y0,x1,y1
    size: float
    vertical: bool     # text runs along page y in display

    @property
    def cx(self):
        return (self.bbox[0] + self.bbox[2]) / 2

    @property
    def cy(self):
        return (self.bbox[1] + self.bbox[3]) / 2


@dataclass
class Page:
    segs: list = field(default_factory=list)
    words: list = field(default_factory=list)    # one entry per text line
    circles: list = field(default_factory=list)  # (cx, cy, r, pid, width, dash)
    clouds: list = field(default_factory=list)   # R-RV1: bbox of revision clouds that were left out of the line work
    rect: tuple = (0, 0, 0, 0)
    src: str = ''                                # pdf path (set by load_page)
    pno: int = None                              # 0-based page number (set by load_page)


def _dash_sig(d, f=1.0):
    d = (d or '').strip()
    if d in ('', '[] 0'):
        return ''
    nums = re.findall(r'[\d.]+', d.split(']')[0])
    return 'dash' + str(len(nums)) + ':' + ','.join(f'{float(n) * f:.1f}' for n in nums)


_PAGES = {}


def load_page(pdf_path, page_no):
    """P5: each page is read once per run (cache by path, page and file time); the returned Page must not be modified."""
    import os
    k = (os.path.abspath(pdf_path), page_no, os.path.getmtime(pdf_path))
    if k not in _PAGES:
        _PAGES[k] = _load_page(pdf_path, page_no)
        _PAGES[k].src = os.path.abspath(pdf_path)
        _PAGES[k].pno = page_no
    return _PAGES[k]


def _load_page(pdf_path, page_no):
    doc = pymupdf.open(pdf_path)
    p = doc[page_no]
    M = p.rotation_matrix
    # R-V11: a drawing printed on a smaller sheet (1003-AFT: A3 1191 pt wide) is the A0 drawing (3370 pt) reduced. Every tolerance of the rules
    # is in A0 points, so the page is read back at A0 size (geometry and text sizes x 3370/width; line widths and dash patterns are print weights and stay).
    wpt = max(p.rect.width, p.rect.height) if p.rotation in (0, 180) else max(p.rect.width, p.rect.height)
    f = 3370.0 / wpt if 600 < wpt < 3000 else 1.0
    if f != 1.0:
        M = M * pymupdf.Matrix(f, f)
    out = Page(rect=tuple(c * f for c in p.rect))
    ma, mb, mc, md, me, mf = M.a, M.b, M.c, M.d, M.e, M.f

    def T(q):                      # P5: plain affine transform (same as pymupdf Point * M, without object creation)
        return (q[0] * ma + q[1] * mc + me, q[0] * mb + q[1] * md + mf)
    for pid, dr in enumerate(p.get_drawings()):
        w = round(dr.get('width') or 0.0, 2)
        ds = _dash_sig(dr.get('dashes'))
        # R-RV1: a revision cloud (scalloped closed outline: a run of >= 8 arcs that make up most of one path, not a circle) marks WHERE the drawing was revised.  It is
        # not ship structure: it is left out of the line work (the real lines drawn inside it stay).
        _its = dr['items']
        _nc = sum(1 for it in _its if it[0] == 'c')
        if _nc >= 8 and _nc >= 0.7 * len(_its) and dr.get("rect") is not None:
            _r = dr['rect'] * M
            if max(_r.width, _r.height) > 30 and (abs(_r.width - _r.height) > 0.05 * max(_r.width, _r.height) or _nc >= 16):
                out.clouds.append((_r.x0, _r.y0, _r.x1, _r.y1))
                continue
        curves = []
        for it in dr['items']:
            if it[0] == 'l':
                out.segs.append(Seg(T(it[1]), T(it[2]), w, ds, pid))
            elif it[0] == 'c':
                pts = [pymupdf.Point(q) * M for q in it[1:5]]
                curves.append(pts)
                out.segs.append(Seg((pts[0].x, pts[0].y), (pts[3].x, pts[3].y), w, ds, pid, 'c'))
            elif it[0] == 're':
                r = it[1] * M
                c = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
                for i in range(4):
                    out.segs.append(Seg(c[i], c[(i + 1) % 4], w, ds, pid))
        if len(curves) >= 4 and all(it[0] == 'c' for it in dr['items']):
            xs = [q.x for c in curves for q in c]
            ys = [q.y for c in curves for q in c]
            rx = (max(xs) - min(xs)) / 2
            ry = (max(ys) - min(ys)) / 2
            if rx > 0 and abs(rx - ry) < 0.05 * rx:
                out.circles.append(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2,
                                    (rx + ry) / 2, pid, w, ds))
    # R-RV1 (universal): clouds written as chords / many small paths are found from their geometry (clouds.py), whatever way they were drawn
    try:
        from .clouds import find_clouds
        _cl = find_clouds(out.segs)
        if _cl:
            _drop = set()
            for _bb, _mem in _cl:
                out.clouds.append(_bb)
                _drop |= _mem
            out.segs = [s_ for i_, s_ in enumerate(out.segs) if i_ not in _drop]
    except Exception:
        pass
    for b in p.get_text('dict')['blocks']:
        for l in b.get('lines', []):
            s = ''.join(sp['text'] for sp in l['spans']).strip()
            if not s:
                continue
            r = pymupdf.Rect(l['bbox']) * M
            d = l.get('dir', (1, 0))
            vdisp = abs((pymupdf.Point(d) * M - pymupdf.Point(0, 0) * M).y) > 0.5
            m_ = re.fullmatch(r'(\d{3,5})\s*OFF\s*C\.L', s) if vdisp else None
            if m_:      # R-V16: 'NNNN OFF C.L' printed as ONE text line -> two words (number, 'OFF C.L'); text reads bottom to top
                n1 = len(m_.group(1))
                ym = r.y1 - (r.y1 - r.y0) * n1 / (n1 + 7.0)
                out.words.append(Word(m_.group(1), (r.x0, ym, r.x1, r.y1), l['spans'][0]['size'] * f, True))
                out.words.append(Word('OFF C.L', (r.x0, r.y0, r.x1, ym), l['spans'][0]['size'] * f, True))
                continue
            out.words.append(Word(s, (r.x0, r.y0, r.x1, r.y1), l['spans'][0]['size'] * f, vdisp))
    return out
