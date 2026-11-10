"""
Repair / clean-up of uploaded geometry for FEA (defeaturing), driven by the user's words through the model:
"remove holes smaller than 50 mm", "remove fillets below R10 and chamfers below 5", "remove tiny faces", "sew and fix".

  holes_below     diameter, mm  - through or blind round holes (full cylindrical faces, material outside) are filled
  fillets_below   radius, mm    - rounds / fillets (partial cylinders and tori) become sharp edges
  chamfers_below  width, mm     - narrow flat strips between two faces (chamfers, slivers) are removed
  faces_below     area, mm2     - any small face is removed
  bosses_below    diameter, mm  - small round bosses / pins (full cylinders, material inside) are removed
Sizes count up to and including the limit ("holes dia 22" also removes 22 mm holes).
Removal uses OpenCascade's defeaturing (the neighbour faces are extended to close the gap), one feature class at a time;
the result must stay a valid solid, otherwise that step is undone and reported. Then sewing / ShapeFix / face merging.
"""
import math, re
import numpy as np


def _cyl_info(f):
    """(radius, full_circle, hole) for a cylindrical face; hole = material lies outside the cylinder"""
    ad = f._geomAdaptor()
    c = ad.Cylinder()
    r = c.Radius()
    u0, u1, v0, v1 = f._uvBounds()
    full = (u1 - u0) > 2 * math.pi - 1e-3
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    from OCP.BRepLProp import BRepLProp_SLProps
    from OCP.TopAbs import TopAbs_REVERSED
    props = BRepLProp_SLProps(BRepAdaptor_Surface(f.wrapped), (u0 + u1) / 2, (v0 + v1) / 2, 1, 1e-6)
    nv = props.Normal()
    if f.wrapped.Orientation() == TopAbs_REVERSED:
        nv.Reverse()
    pt = props.Value()
    ax = c.Axis()
    loc = ax.Location()
    d = np.array([ax.Direction().X(), ax.Direction().Y(), ax.Direction().Z()])
    o = np.array([loc.X(), loc.Y(), loc.Z()])
    pc = np.array([pt.X(), pt.Y(), pt.Z()])
    radial = (pc - o) - ((pc - o) @ d) * d
    n = np.array([nv.X(), nv.Y(), nv.Z()])
    hole = float(radial @ n) < 0            # face normal (outward from material) points to the axis -> material outside
    return r, full, hole


def _strip_width(f):
    per = sum(e.Length() for e in f.Edges())
    return 2 * f.Area() / per if per else 0.0


def find_features(shape, holes_below=None, fillets_below=None, chamfers_below=None, faces_below=None, bosses_below=None):
    found = {'holes': [], 'fillets': [], 'chamfers': [], 'small_faces': [], 'bosses': []}
    for f in shape.Faces():
        t = f.geomType()
        if t == 'CYLINDER':
            r, full, hole = _cyl_info(f)
            if full and hole and holes_below and 2 * r <= holes_below + 1e-6:
                found['holes'].append((f, 2 * r))
            elif full and not hole and bosses_below and 2 * r <= bosses_below + 1e-6:
                found['bosses'].append((f, 2 * r))
            elif not full and fillets_below and r <= fillets_below + 1e-6:
                found['fillets'].append((f, r))
        elif t == 'TORUS' and fillets_below:
            minor = f._geomAdaptor().Torus().MinorRadius()
            if minor <= fillets_below + 1e-6:
                found['fillets'].append((f, minor))
        elif t == 'PLANE' and chamfers_below and _strip_width(f) <= chamfers_below + 1e-6 and len(f.Edges()) == 4:
            found['chamfers'].append((f, _strip_width(f)))
        if faces_below and f.Area() <= faces_below + 1e-6:
            found['small_faces'].append((f, f.Area()))
    return found


def _remove(shape, faces):
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Defeaturing
    import cadquery as cq
    d = BRepAlgoAPI_Defeaturing()
    d.SetShape(shape.wrapped)
    for f in faces:
        d.AddFaceToRemove(f.wrapped)
    d.SetRunParallel(False)
    d.Build()
    if not d.IsDone():
        return None
    out = cq.Shape.cast(d.Shape())
    return out if out.isValid() and out.Volume() > 0 else None


def _neighbours(shape, face, kinds=('CONE', 'TORUS', 'CYLINDER', 'BSPLINE', 'SPHERE')):
    """faces sharing an edge with face whose surface type is in kinds (chamfer cones / rounds at a hole's edge)"""
    edges = face.Edges()
    out = []
    for g in shape.Faces():
        if g.isSame(face) or g.geomType() not in kinds:
            continue
        if any(e.isSame(x) for e in g.Edges() for x in edges):
            out.append(g)
    return out


def _caps(shape, face):
    """planar faces bounded only by edges of face (the flat top of a boss / pin)"""
    edges = face.Edges()
    return [g for g in _neighbours(shape, face, ('PLANE',))
            if all(any(e.isSame(x) for x in edges) for e in g.Edges())]


def _group(shape, key, face):
    """the faces that must go together with face so the gap can be closed"""
    if key == 'holes':
        return [face] + _neighbours(shape, face)                        # chamfer cones / rounds at the hole's edge
    if key == 'bosses':
        return [face] + _caps(shape, face) + _neighbours(shape, face, ('CONE', 'TORUS'))
    if key == 'chamfers':
        return [face] + _neighbours(shape, face, ('CONE', 'TORUS'))     # corner pieces where a chamfer meets a round
    return [face]


def _count(shape, key, lim):
    return len(find_features(shape, **{_ARG[key]: lim})[key])


_ARG = {'fillets': 'fillets_below', 'chamfers': 'chamfers_below', 'holes': 'holes_below', 'bosses': 'bosses_below',
        'small_faces': 'faces_below'}


def repair(shape, holes_below=None, fillets_below=None, chamfers_below=None, faces_below=None, bosses_below=None, sew=True):
    """-> (shape, actions in plain English, summary)"""
    from .geoclean import clean_shape
    actions = []
    v0, n0 = shape.Volume(), len(shape.Faces())
    order = [('fillets', 'fillet / round', 'R', fillets_below), ('chamfers', 'chamfer / narrow strip', 'width ', chamfers_below),
             ('holes', 'hole', 'dia. ', holes_below), ('bosses', 'boss / pin', 'dia. ', bosses_below),
             ('small_faces', 'small face', 'area ', faces_below)]
    for key, word, lab, lim in order:
        if not lim:
            continue
        feats = find_features(shape, **{_ARG[key]: lim})[key]
        if not feats:
            actions.append(f'No {word}s below {lim:g} found.')
            continue
        before = len(feats)
        groups = [_group(shape, key, f) for f, _ in feats]
        new = _remove(shape, [g for grp in groups for g in grp])
        if new is not None and _count(new, key, lim) < before:
            shape = new
        else:                                        # all at once did not work: one feature at a time
            for grp in groups:
                cur = find_features(shape, **{_ARG[key]: lim})[key]
                tgt = [f for f, _ in cur if any(f.isSame(g) or abs(f.Area() - g.Area()) < 1e-6 and
                                               np.allclose(f.Center().toTuple(), g.Center().toTuple()) for g in grp)]
                if not tgt:
                    continue
                cand = _remove(shape, _group(shape, key, tgt[0]))
                if cand is not None and _count(cand, key, lim) < len(cur):
                    shape = cand
        left = _count(shape, key, lim)                 # verified on the new shape, never assumed
        done = before - left
        sizes = sorted({round(x, 1) for _, x in feats})
        actions.append(f"Removed {done} of {before} {word}(s) below {lim:g} ({lab}{', '.join(f'{x:g}' for x in sizes[:6])}"
                       + (' ...' if len(sizes) > 6 else '') + ')'
                       + (f'; {left} could not be removed cleanly and were kept.' if left else '.'))
    if sew:
        shape, a2 = clean_shape(shape)
        actions += a2
    v1 = shape.Volume()
    summary = {'faces_before': n0, 'faces_after': len(shape.Faces()), 'volume_change_pct': round(100 * (v1 / v0 - 1), 3) if v0 else 0.0,
               'valid': bool(shape.isValid()), 'solids': len(shape.Solids())}
    return shape, actions, summary


# ====================================================================== plain-English request -> repair settings
_NUM = r'(?:r\s*|ø\s*|dia\.?\s*|d\s*=?\s*)?(\d+(?:\.\d+)?)\s*(mm2|mm²|mm\^2|mm|cm|m)?\b'
_WORDS = [('holes_below', r'holes?|bores?|openings?|drill'), ('fillets_below', r'fillets?|rounds?|radi[iu]s?|blends?'),
          ('chamfers_below', r'chamfers?|bevels?|slivers?|narrow strips?'), ('faces_below', r'(?:small|tiny|short)?\s*faces?|patches'),
          ('bosses_below', r'boss(?:es)?|pins?|studs?|pegs?')]
_DEFAULT = {'holes_below': 20.0, 'fillets_below': 10.0, 'chamfers_below': 5.0, 'faces_below': 25.0, 'bosses_below': 20.0}
_SCALE = {'cm': 10.0, 'm': 1000.0}


def args_from_text(text):
    """'remove holes smaller than 50 mm and fillets below R10, then sew' -> {'holes_below': 50, 'fillets_below': 10, 'sew': True}.
    A feature named without a size gets a sensible default (listed in 'assumed')."""
    t = text.lower().replace(',', ' , ')
    out, assumed = {}, []
    spans = []
    for key, rx in _WORDS:
        for m in re.finditer(r'\b(?:' + rx + r')\b', t):
            spans.append((m.start(), m.end(), key))
    spans.sort()
    spans = [s for i, s in enumerate(spans) if not (s[2] == 'faces_below' and any(o[2] != 'faces_below' and o[0] <= s[0] < o[1] + 2
                                                                                   for o in spans[:i] + spans[i + 1:]))]
    for i, (a, b, key) in enumerate(spans):
        if key in out:
            continue
        stop = spans[i + 1][0] if i + 1 < len(spans) else len(t)
        seg = t[b:stop]
        m = re.search(_NUM, seg) if not re.match(r'\s*(?:and|,|&|\+)\s', seg) or len(seg) > 40 else None
        if m is None:                                                   # 'holes and fillets below 10': share the next size
            nxt = re.search(_NUM, t[b:])
            m = nxt if nxt and ('and' in t[b:b + nxt.start()] or ',' in t[b:b + nxt.start()]) and key != 'faces_below' else None
        if m:
            v = float(m.group(1)) * _SCALE.get(m.group(2) or '', 1.0)
            if key == 'faces_below' and (m.group(2) or '') == 'm':
                v = float(m.group(1)) * 1e6
            out[key] = v
        else:
            out[key] = _DEFAULT[key]
            assumed.append(f'{key.split("_")[0]} below {_DEFAULT[key]:g}')
    if re.search(r'\b(no|without|don.?t|do not) sew', t):
        out['sew'] = False
    return out, assumed
