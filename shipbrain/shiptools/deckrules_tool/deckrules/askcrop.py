"""R-ASK1 (owner 2026-10-25): when a rule gives no answer or the offline reading fails, the question goes to the owner WITH a crop of the
REAL drawing and the item that is not understood boxed in red (label = question number). No guessing, no default.
Offline: PyMuPDF + PIL only.
    from deckrules import askcrop
    askcrop.crop(pdf, page_index, rect_pt, [(rect_pt, 'Q1')], 'q1.png', zoom=10)
    askcrop.plan_rect(report_json_view, X0, X1, Y0, Y1)   -> page rect of a ship-mm box on that deck plan"""
import pymupdf
from PIL import Image, ImageDraw, ImageFont

try:
    _F = ImageFont.truetype('DejaVuSans-Bold.ttf', 30)
except OSError:
    _F = ImageFont.load_default()


def crop(pdf, pn, rect, marks, out, zoom=8):
    clip = pymupdf.Rect(*rect)
    pm = pymupdf.open(pdf)[pn].get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), clip=clip)
    im = Image.frombytes('RGB', (pm.width, pm.height), pm.samples)
    g = ImageDraw.Draw(im)
    for (x0, y0, x1, y1), lab in marks:
        b = [(x0 - clip.x0) * zoom, (y0 - clip.y0) * zoom, (x1 - clip.x0) * zoom, (y1 - clip.y0) * zoom]
        g.rectangle(b, outline=(220, 0, 0), width=5)
        if lab:
            tw = g.textlength(lab, font=_F)
            ty = b[1] - 40 if b[1] > 45 else b[3] + 6
            g.rectangle([b[0], ty, b[0] + tw + 12, ty + 38], fill=(220, 0, 0))
            g.text((b[0] + 6, ty + 2), lab, fill='white', font=_F)
    im.save(out)
    return out


def plan_rect(view, X0, X1, Y0, Y1):
    """view = the 'view' dict of a deck report (mm_per_pt, frame0_page_x, centre_line_page_y)"""
    k, x0, cl = view['mm_per_pt'], view['frame0_page_x'], view['centre_line_page_y']
    xs, ys = (x0 + X0 / k, x0 + X1 / k), (cl - Y0 / k, cl - Y1 / k)
    return (min(xs), min(ys), max(xs), max(ys))
