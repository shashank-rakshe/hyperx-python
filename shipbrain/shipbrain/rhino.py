"""
Rhino .3dm import with McNeel's own open library rhino3dm (MIT, pip install rhino3dm) and OpenCascade - no Rhino needed.

Every object becomes exact OpenCascade geometry:
  Brep / polysurface   each face = its exact NURBS surface (weights kept, so circles stay circles) bounded by its
                       3D edge loops; OpenCascade computes the trims; faces are sewn; a closed one becomes a solid
  Extrusion            to a Brep first (Rhino's light-weight extrusion)
  Surface              one face (untrimmed)
  Mesh                 triangles sewn into a shell (a closed mesh becomes a solid, faceted)
  Curve / line / arc   edges (for stiffener lines, outlines)
Units are converted to mm from the file's model units. Layer, name and colour are kept per object.

    read(path)                    -> summary (objects per kind and layer, units, size)
    to_shape(path)                -> (OpenCascade compound, list of object records)
    to_step(path, out=None)       -> STEP file + plain-English summary
"""
import math, os

UNIT_MM = {'None': 1.0, 'Millimeters': 1.0, 'Centimeters': 10.0, 'Meters': 1000.0, 'Kilometers': 1e6, 'Inches': 25.4,
           'Feet': 304.8, 'Yards': 914.4, 'Miles': 1609344.0, 'Microns': 1e-3, 'Microinches': 2.54e-5, 'Mils': 0.0254}


def _lib():
    try:
        import rhino3dm
    except ImportError:
        raise RuntimeError('Rhino .3dm files need rhino3dm (free, MIT): pip install rhino3dm')
    return rhino3dm


def _knots(seq, order):
    """Rhino keeps n + order - 2 knots; OpenCascade wants distinct knots + multiplicities of the full vector"""
    full = [seq[0]] + list(seq) + [seq[len(seq) - 1]]
    vals, mults = [], []
    for k in full:
        if vals and abs(k - vals[-1]) <= 1e-12 * max(1.0, abs(k)):
            mults[-1] += 1
        else:
            vals.append(float(k))
            mults.append(1)
    return vals, mults


def _arr1(vals, kind):
    from OCP.TColStd import TColStd_Array1OfReal, TColStd_Array1OfInteger
    a = (TColStd_Array1OfReal if kind == 'r' else TColStd_Array1OfInteger)(1, len(vals))
    for i, v in enumerate(vals, 1):
        a.SetValue(i, float(v) if kind == 'r' else int(v))
    return a


def occ_curve(c, k=1.0):
    """rhino3dm curve -> OpenCascade Geom_BSplineCurve (exact, with weights), scaled by k"""
    from OCP.Geom import Geom_BSplineCurve
    from OCP.TColgp import TColgp_Array1OfPnt
    from OCP.gp import gp_Pnt
    n = c.ToNurbsCurve()
    P = n.Points
    cnt = len(P)
    pts, w = TColgp_Array1OfPnt(1, cnt), []
    for i in range(cnt):
        p = P[i]
        W = p.W or 1.0
        pts.SetValue(i + 1, gp_Pnt(p.X / W * k, p.Y / W * k, p.Z / W * k))
        w.append(W)
    vals, mults = _knots([n.Knots[i] for i in range(len(n.Knots))], n.Order)
    if n.IsRational:
        return Geom_BSplineCurve(pts, _arr1(w, 'r'), _arr1(vals, 'r'), _arr1(mults, 'i'), n.Order - 1)
    return Geom_BSplineCurve(pts, _arr1(vals, 'r'), _arr1(mults, 'i'), n.Order - 1)


def occ_surface(s, k=1.0):
    from OCP.Geom import Geom_BSplineSurface
    from OCP.TColgp import TColgp_Array2OfPnt
    from OCP.TColStd import TColStd_Array2OfReal
    from OCP.gp import gp_Pnt
    n = s.ToNurbsSurface()
    nu, nv = n.Points.CountU, n.Points.CountV
    pts, W = TColgp_Array2OfPnt(1, nu, 1, nv), TColStd_Array2OfReal(1, nu, 1, nv)
    for i in range(nu):
        for j in range(nv):
            p = n.Points[i, j]
            w = p.W or 1.0
            pts.SetValue(i + 1, j + 1, gp_Pnt(p.X / w * k, p.Y / w * k, p.Z / w * k))
            W.SetValue(i + 1, j + 1, w)
    uv, um = _knots([n.KnotsU[i] for i in range(len(n.KnotsU))], n.OrderU)
    vv, vm = _knots([n.KnotsV[i] for i in range(len(n.KnotsV))], n.OrderV)
    return Geom_BSplineSurface(pts, W, _arr1(uv, 'r'), _arr1(vv, 'r'), _arr1(um, 'i'), _arr1(vm, 'i'),
                               n.OrderU - 1, n.OrderV - 1, n.IsPeriodic(0) and False, n.IsPeriodic(1) and False)


def _edge(c, k):
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge
    g = occ_curve(c, k)
    return BRepBuilderAPI_MakeEdge(g, g.FirstParameter(), g.LastParameter()).Edge()


def _face(brep, face, k, tol):
    """one Brep face: exact surface bounded by its edge loops (outer first), trims computed by OpenCascade"""
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeWire
    from OCP.ShapeFix import ShapeFix_Face, ShapeFix_Wire
    from OCP.ShapeAnalysis import ShapeAnalysis_FreeBounds
    from OCP.TopTools import TopTools_HSequenceOfShape
    from OCP.TopoDS import TopoDS
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopAbs import TopAbs_WIRE
    surf = occ_surface(face.UnderlyingSurface(), k)
    loops = [face.Loops[i] for i in range(len(face.Loops))] if hasattr(face.Loops, '__len__') else []
    loops.sort(key=lambda L: 0 if str(L.LoopType).endswith('Outer') else 1)
    seam_only = len(loops) == 1 and _has_seam(loops[0])
    import cadquery as cq
    natural = BRepBuilderAPI_MakeFace(surf, tol).Face()
    if not loops or seam_only:                       # natural boundary of a closed surface (cylinder side, sphere): exact
        f = natural
    else:
        wires = []
        for L in loops:
            seq = TopTools_HSequenceOfShape()
            for t in [L.Trims[i] for i in range(L.TrimCount)]:
                if t.EdgeIndex >= 0:                 # -1 = singular trim (pole): no edge
                    seq.Append(_edge(brep.Edges[t.EdgeIndex], k))
            out = TopTools_HSequenceOfShape()
            if seq.Length():
                ShapeAnalysis_FreeBounds.ConnectEdgesToWires_s(seq, tol, False, out)
            wires += [TopoDS.Wire_s(out.Value(i)) for i in range(1, out.Length() + 1)]
        mf = BRepBuilderAPI_MakeFace(surf, wires[0], True)
        for w in wires[1:]:
            mf.Add(w)
        fix = ShapeFix_Face(mf.Face())
        fix.SetPrecision(tol)
        fix.FixOrientationMode = 1                   # outer loop counter-clockwise, holes clockwise
        fix.Perform()
        from OCP.ShapeFix import ShapeFix_Shape
        from OCP.TopAbs import TopAbs_FACE
        from OCP.TopExp import TopExp_Explorer
        sf = ShapeFix_Shape(fix.Face())                  # pcurves, edge / wire order, orientation
        sf.SetPrecision(tol)
        sf.Perform()
        ex = TopExp_Explorer(sf.Shape(), TopAbs_FACE)
        f = TopoDS.Face_s(ex.Current()) if ex.More() else fix.Face()
    if face.OrientationIsReversed:
        f = TopoDS.Face_s(f.Reversed())
    return f


def _has_seam(loop):
    idx = [loop.Trims[i].EdgeIndex for i in range(loop.TrimCount) if loop.Trims[i].EdgeIndex >= 0]
    return len(idx) != len(set(idx))


def _sew(faces, tol):
    from OCP.BRepBuilderAPI import BRepBuilderAPI_Sewing, BRepBuilderAPI_MakeSolid
    from OCP.ShapeFix import ShapeFix_Solid, ShapeFix_Shape
    from OCP.TopAbs import TopAbs_SHELL, TopAbs_FACE
    from OCP.TopoDS import TopoDS
    import cadquery as cq
    sew = BRepBuilderAPI_Sewing(tol)
    for f in faces:
        sew.Add(f)
    sew.Perform()
    sh = sew.SewedShape()
    s = cq.Shape.cast(sh)
    if sh.ShapeType() == TopAbs_FACE:                # one face closed on itself (sphere, torus): make it a shell
        from OCP.BRep import BRep_Builder
        from OCP.TopoDS import TopoDS_Shell
        shell, bld = TopoDS_Shell(), BRep_Builder()
        bld.MakeShell(shell)
        bld.Add(shell, sh)
        sh, s = shell, cq.Shape.cast(shell)
    shells = s.Shells() if sh.ShapeType() != TopAbs_SHELL else [s]
    if len(shells) == 1 and _closed(shells[0].wrapped):
        solid = ShapeFix_Solid().SolidFromShell(TopoDS.Shell_s(shells[0].wrapped))
        fx = ShapeFix_Shape(solid)
        fx.Perform()
        so = cq.Shape.cast(fx.Shape())
        if volume(so) < 0:
            so = cq.Shape.cast(so.wrapped.Reversed())
        return so, 'solid'
    return s, 'open surface'


def _closed(shell):
    """no free edges (a seam edge used twice by one face counts as closed)"""
    from OCP.ShapeAnalysis import ShapeAnalysis_FreeBounds
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopAbs import TopAbs_EDGE
    fb = ShapeAnalysis_FreeBounds(shell, 1e-3, False, False)
    ex = TopExp_Explorer(fb.GetClosedWires(), TopAbs_EDGE)
    ex2 = TopExp_Explorer(fb.GetOpenWires(), TopAbs_EDGE)
    return not ex.More() and not ex2.More()


def volume(shape):
    """precise volume (OpenCascade's default rule is up to ~1 % off on rational NURBS such as cylinders and spheres)"""
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    p = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape.wrapped, p, 1e-9, False, False)
    return p.Mass()


def _mesh_shape(mesh, k, tol):
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakePolygon, BRepBuilderAPI_MakeFace
    from OCP.gp import gp_Pnt
    V = mesh.Vertices
    faces = []
    for i in range(len(mesh.Faces)):
        q = mesh.Faces[i]
        idx = [q[0], q[1], q[2]] + ([q[3]] if q[3] != q[2] else [])
        for tri in ([idx] if len(idx) == 3 else [[idx[0], idx[1], idx[2]], [idx[0], idx[2], idx[3]]]):
            poly = BRepBuilderAPI_MakePolygon()
            for v in tri:
                p = V[v]
                poly.Add(gp_Pnt(p.X * k, p.Y * k, p.Z * k))
            poly.Close()
            mf = BRepBuilderAPI_MakeFace(poly.Wire(), True)
            if mf.IsDone():
                faces.append(mf.Face())
    return _sew(faces, tol)


def _records(path):
    r3 = _lib()
    m = r3.File3dm.Read(path)
    if m is None:
        raise ValueError(f'{os.path.basename(path)} is not a readable Rhino .3dm file')
    unit = str(m.Settings.ModelUnitSystem).split('.')[-1]
    k = UNIT_MM.get(unit, 1.0)
    layers = {i: m.Layers[i].FullPath if hasattr(m.Layers[i], 'FullPath') else m.Layers[i].Name for i in range(len(m.Layers))}
    return r3, m, unit, k, layers


def to_shape(path, tol=None):
    import cadquery as cq
    r3, m, unit, k, layers = _records(path)
    tol = tol or max(1e-3, (m.Settings.ModelAbsoluteTolerance or 0.001) * k)
    shapes, recs = [], []
    defs = {}
    for i in range(len(m.InstanceDefinitions)):
        d = m.InstanceDefinitions[i]
        defs[str(d.Id)] = (d.Name, [str(x) for x in d.GetObjectIds()])
    by_id = {str(o.Attributes.Id): o for o in m.Objects}
    in_def = {x for _, ids in defs.values() for x in ids}

    def items():
        """(geometry, attributes, block name) - block instances expanded with their transforms (nested too)"""
        def expand(ref, xf, depth, name):
            dn, ids = defs.get(str(ref.ParentIdefId), ('?', []))
            for x in ids:
                o = by_id.get(x)
                if o is None:
                    continue
                g = o.Geometry.Duplicate()
                t = xf * ref.Xform if xf is not None else ref.Xform
                if isinstance(g, r3.InstanceReference) and depth < 8:
                    yield from expand(g, t, depth + 1, dn)
                else:
                    g.Transform(t)
                    yield g, o.Attributes, dn
        for o in m.Objects:
            if str(o.Attributes.Id) in in_def:           # block definition content: only placed through instances
                continue
            if isinstance(o.Geometry, r3.InstanceReference):
                yield from expand(o.Geometry, None, 0, None)
            else:
                yield o.Geometry, o.Attributes, None

    for g, a, block in items():
        rec = {'kind': type(g).__name__, 'layer': layers.get(a.LayerIndex, ''), 'name': a.Name or ''}
        if block:
            rec['block'] = block
        try:
            if isinstance(g, (r3.Point, r3.PointCloud)) if hasattr(r3, 'PointCloud') else isinstance(g, r3.Point):
                rec['result'] = 'point (kept out of the solid model)'
                recs.append(rec)
                continue
            if type(g).__name__ == 'SubD':
                rec['result'] = 'not converted: SubD - in Rhino use ToNURBS (or Mesh) and save again'
                recs.append(rec)
                continue
            if isinstance(g, r3.Extrusion):
                g = g.ToBrep(True)
            if isinstance(g, r3.Brep):
                faces = [_face(g, g.Faces[i], k, tol) for i in range(len(g.Faces))]
                shp, what = _sew(faces, tol) if len(faces) > 1 or g.IsSolid else (cq.Shape.cast(faces[0]), 'surface')
            elif isinstance(g, r3.Surface):
                from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
                shp, what = cq.Shape.cast(BRepBuilderAPI_MakeFace(occ_surface(g, k), tol).Face()), 'surface'
            elif isinstance(g, r3.Mesh):
                shp, what = _mesh_shape(g, k, tol)
                what = 'mesh ' + what
            elif isinstance(g, r3.Curve):
                shp, what = cq.Shape.cast(_edge(g, k)), 'curve'
            else:
                rec['result'] = 'not geometry (skipped)'
                recs.append(rec)
                continue
        except Exception as e:                          # one bad object never stops the file
            rec['result'] = f'not converted: {type(e).__name__}: {e}'
            recs.append(rec)
            continue
        rec['result'] = what
        if what.endswith('solid'):
            rec['volume_mm3'] = round(volume(shp), 3)
        rec['valid'] = shp.isValid()
        shapes.append(shp)
        recs.append(rec)
    if not shapes:
        why = sorted({r['result'] for r in recs})
        raise ValueError(f'no geometry could be read from {os.path.basename(path)}: ' + '; '.join(why))
    return cq.Compound.makeCompound(shapes), recs, unit


def to_step(path, out=None):
    import cadquery as cq
    from collections import Counter
    comp, recs, unit = to_shape(path)
    out = out or os.path.splitext(path)[0] + '.step'
    cq.exporters.export(cq.Workplane().add(comp), out)
    res = Counter(r['result'].split(':')[0].split(' (')[0] for r in recs)
    bb = comp.BoundingBox()
    lay = Counter(r['layer'] for r in recs if r.get('layer'))
    bad = [r for r in recs if r['result'].startswith('not converted')]
    pe = (f"Read the Rhino file {os.path.basename(path)} (units {unit.lower()}, converted to mm) with rhino3dm and wrote "
          f"{os.path.basename(out)}: " + ', '.join(f'{v} {k}' for k, v in res.most_common()) +
          f"; overall {bb.xlen:.1f} x {bb.ylen:.1f} x {bb.zlen:.1f} mm.")
    vol = sum(r.get('volume_mm3', 0) for r in recs)
    if vol:
        pe += f" Solid volume {vol:,.1f} mm3."
    if lay:
        pe += ' Layers: ' + ', '.join(f'{k} ({v})' for k, v in lay.most_common(8)) + '.'
    if bad:
        pe += f" {len(bad)} object(s) could not be converted (listed in objects)."
    return {'file': out, 'objects': recs[:200], 'units': unit, 'size_mm': [round(bb.xlen, 3), round(bb.ylen, 3), round(bb.zlen, 3)],
            'plain_english': pe}
