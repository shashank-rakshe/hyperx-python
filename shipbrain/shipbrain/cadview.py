"""
Check a 3D CAD model against a 2D drawing view (idea from agent3dify, MIT; own implementation, CPU only):

  1. project the model's edges onto the view plane (front = look along -Y, top = along -Z, side = along +X)
  2. crop the drawing view and the projection to their ink, scale both to the same size (keeping proportions)
  3. line overlap both ways (a few pixels tolerance), pixel IoU and proportion match
     PASS: >= 95 % of the lines match BOTH ways and proportions within 3 %; WARN: >= 80 % / 10 %; else FAIL; an overlay image shows drawing lines only (red), model lines only (blue), both (grey)

A text-only model gets numbers back, not pictures, so even a small model can fix the CAD script from the result.
"""
import math, os
import numpy as np

VIEWS = {  # (u axis, v axis) of the drawing plane, in model coordinates
    'front': ((1, 0, 0), (0, 0, 1)),
    'top': ((1, 0, 0), (0, 1, 0)),
    'side': ((0, 1, 0), (0, 0, 1)),
    'right': ((0, 1, 0), (0, 0, 1)),
    'left': ((0, -1, 0), (0, 0, 1)),
    'back': ((-1, 0, 0), (0, 0, 1)),
    'bottom': ((1, 0, 0), (0, -1, 0)),
}


def model_segments(shape, view='front', n_curve=24):
    """2D line pieces of all model edges seen in a view (hidden edges included, like a wire-frame)"""
    import cadquery as cq
    if isinstance(shape, str):
        from .cadplates import import_cad
        shape = import_cad(shape)
    if isinstance(shape, cq.Workplane):
        shape = cq.Compound.makeCompound([v for v in shape.vals() if isinstance(v, cq.Shape)])
    u, v = (np.array(a, float) for a in VIEWS[view])
    segs = []
    for e in shape.Edges():
        if e.geomType() == 'LINE':
            P = [np.array(e.startPoint().toTuple()), np.array(e.endPoint().toTuple())]
        else:
            P = [np.array(e.positionAt(t).toTuple()) for t in np.linspace(0, 1, n_curve + 1)]
        Q = [(p @ u, p @ v) for p in P]
        segs += [(a, b) for a, b in zip(Q, Q[1:]) if math.dist(a, b) > 1e-9]
    return segs


def _ink_crop(gray, thr=160, pad=2):
    ink = gray < thr
    ys, xs = np.where(ink)
    if not len(xs):
        raise ValueError('the image has no lines')
    return ink[max(0, ys.min() - pad): ys.max() + pad + 1, max(0, xs.min() - pad): xs.max() + pad + 1]


def _fit(mask, W, H):
    from PIL import Image
    h, w = mask.shape
    s = min(W / w, H / h)
    im = Image.fromarray((mask * 255).astype(np.uint8)).resize((max(1, int(w * s)), max(1, int(h * s))), Image.NEAREST)
    out = np.zeros((H, W), bool)
    a = np.asarray(im) > 0
    oy, ox = (H - a.shape[0]) // 2, (W - a.shape[1]) // 2
    out[oy: oy + a.shape[0], ox: ox + a.shape[1]] = a
    return out


def compare_view(shape, drawing, view='front', page=0, crop=None, out_png=None, size=600, tol_px=3):
    """drawing: PDF / PNG / JPG / DXF file (or a grayscale array). crop = [x0, y0, x1, y1] pixel box of the view on the sheet."""
    from .drawings import load_image, render_lines, _dilate, _save_rgb
    segs = model_segments(shape, view)
    P = np.array([p for s in segs for p in s])
    lo, hi = P.min(0), P.max(0)
    span = np.maximum(hi - lo, 1e-6)
    box = (lo[0] - 0.02 * span.max(), hi[0] + 0.02 * span.max(), lo[1] - 0.02 * span.max(), hi[1] + 0.02 * span.max())
    W = 1200
    H = max(50, int(W * (box[3] - box[2]) / (box[1] - box[0])))
    model_img = render_lines(segs, box, (H, W), width=2)
    img = drawing if isinstance(drawing, np.ndarray) else load_image(drawing, page)
    if crop:
        x0, y0, x1, y1 = (int(c) for c in crop)
        img = img[y0:y1, x0:x1]
    M, D = _ink_crop(model_img), _ink_crop(img)
    ar_m, ar_d = M.shape[1] / M.shape[0], D.shape[1] / D.shape[0]
    ratio = min(ar_m, ar_d) / max(ar_m, ar_d)
    Mf, Df = _fit(M, size, size), _fit(D, size, size)
    dM, dD = _dilate(Mf, tol_px), _dilate(Df, tol_px)
    m_on_d = float((Mf & dD).sum() / max(1, Mf.sum()))        # model lines that the drawing also has
    d_on_m = float((Df & dM).sum() / max(1, Df.sum()))        # drawing lines that the model also has
    iou = float((dM & dD).sum() / max(1, (dM | dD).sum()))
    score = 0.6 * min(m_on_d, d_on_m) + 0.25 * iou + 0.15 * ratio
    worst = min(m_on_d, d_on_m)                # a missing or extra feature must not be averaged away
    verdict = 'PASS' if worst >= 0.95 and ratio >= 0.97 else ('WARN' if worst >= 0.8 and ratio >= 0.9 else 'FAIL')
    if out_png:
        rgb = np.full((size, size, 3), 255.0)
        rgb[Df & ~dM] = (220, 30, 30)
        rgb[Mf & ~dD] = (30, 80, 220)
        rgb[(Df & dM) | (Mf & dD)] = (140, 140, 140)
        _save_rgb(out_png, rgb)
    hints = []
    if ratio < 0.95:
        hints.append(f'proportions differ: model width/height {ar_m:.2f}, drawing {ar_d:.2f} - check the overall sizes')
    if d_on_m < 0.85:
        hints.append(f'{(1 - d_on_m) * 100:.0f} % of the drawing lines are missing in the model (red): a hole, slot, step or edge is missing or misplaced')
    if m_on_d < 0.85:
        hints.append(f'{(1 - m_on_d) * 100:.0f} % of the model lines are not in the drawing (blue): an extra feature, or a feature in the wrong place')
    text = (f'{view} view: {verdict} (score {score:.2f}). Drawing lines found in the model: {d_on_m * 100:.0f} %, '
            f'model lines found in the drawing: {m_on_d * 100:.0f} %, proportions match {ratio * 100:.0f} %.'
            + (' ' + ' '.join(hints) + '.' if hints else ''))
    return {'view': view, 'verdict': verdict, 'score': round(score, 3), 'drawing_in_model': round(d_on_m, 3),
            'model_in_drawing': round(m_on_d, 3), 'iou': round(iou, 3), 'proportion_match': round(ratio, 3),
            'hints': hints, 'overlay': out_png, 'plain_english': text}
