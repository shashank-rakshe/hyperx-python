"""R-B11 (owner 2026-10-26: "B25, B15, B40 and B45 are already given in the drawing table"): the bracket marks Bnn are defined in a
'DET. OF BRACKET' table (cells 'B25 / B25AH': thickness, (AH thickness), two legs, optional '100 FL.' flange). Same-hull drawings
share it (hull = first 4-digit number of the file name), so the table is read from the drawing itself or from any drawing of the same
hull in the same folder. A mark not in any table stays UNKNOWN and is asked. Offline: PDF text only."""
import os, re, glob

TITLE = re.compile(r'^B(\d{2,3})(?:\s*/\s*B\1\s*AH)?$')
_CACHE = {}


def hull_of(path):
    m = re.search(r'(\d{4})', os.path.basename(path))
    return m.group(1) if m else None


def read_pdf(pdf):
    from . import pdfsrc
    import pymupdf
    out = {}
    for pn in range(len(pymupdf.open(pdf))):
        page = pdfsrc.load_page(pdf, pn)
        if not any('BRACKET' in w.text.upper() for w in page.words):
            continue
        titles = [w for w in page.words if TITLE.match(w.text.strip()) and '/' in w.text]
        for t in titles:
            mk = 'B' + TITLE.match(t.text.strip()).group(1)
            below = [u.bbox[1] for u in titles if abs(u.cx - t.cx) < 20 and u.bbox[1] > t.bbox[3] + 5]
            y1 = min(below) if below else t.bbox[3] + 160
            cell = [w for w in page.words if t.bbox[0] - 12 < w.cx < t.bbox[2] + 12 and t.bbox[3] < w.cy < y1]
            weld = [w.cy for w in cell if 'WELD' in w.text.upper()]
            wy = max(weld) if weld else t.bbox[3]
            dec = [w for w in cell if re.fullmatch(r'\d{1,2}\.\d', w.text.strip()) and w.cy > wy + 12]
            ah = [w for w in cell if re.search(r'\((\d{1,2}\.\d)\s*"?AH"?\)', w.text)]
            legs = [int(w.text) for w in cell if re.fullmatch(r'\d{2,4}', w.text.strip())]
            fl = [w for w in cell if re.search(r'(\d{2,3})\s*FL', w.text.upper())]
            if not dec or not legs:
                continue
            nn = int(mk[1:]) * 10
            lg = [x for x in legs if abs(x - nn) < 1] or legs
            out[mk] = {'leg': float(max(lg)), 'leg2': float(min(lg)), 't': float(min(dec, key=lambda w: w.cy).text),
                       't_AH': float(re.search(r'(\d{1,2}\.\d)', ah[0].text).group(1)) if ah else None,
                       'flange': float(re.search(r'(\d{2,3})', fl[0].text).group(1)) if fl else None,
                       'source': f'{os.path.basename(pdf)} p{pn + 1} DET. OF BRACKET'}
    return out


EXTRA_FOLDERS = []          # folders with the other drawings of the same hull (set by the app when the PDF was copied elsewhere)


def table(pdf):
    """marks of the drawing itself first, then of every same-hull drawing in its folder (and in EXTRA_FOLDERS)"""
    key = os.path.abspath(pdf)
    if key in _CACHE:
        return _CACHE[key]
    res = dict(read_pdf(pdf))
    h = hull_of(pdf)
    if h:
        folders = [os.path.dirname(key)] + [os.path.abspath(f) for f in EXTRA_FOLDERS if f and os.path.isdir(f)]
        for f in sorted({g for d in folders for g in glob.glob(os.path.join(d, '*.pdf'))}):
            if os.path.abspath(f) == key or hull_of(f) != h:
                continue
            try:
                for k, v in read_pdf(f).items():
                    res.setdefault(k, v)
            except Exception as e:
                from . import openitems
                openitems.record(f'bkttable {os.path.basename(f)}', e)
    _CACHE[key] = res
    return res
