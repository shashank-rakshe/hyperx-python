"""
CAD (STEP / BREP / CadQuery shape) -> plates for platemesh. Needs CadQuery (OCP); no gmsh.

- sheet bodies / faces: every planar face becomes a plate (thickness = default_t)
- thin solids (plates, webs, brackets modelled with thickness): mid-surface = the largest planar face moved half the
  thickness inwards, thickness = distance to the opposite parallel face. The mesher's gap closing then joins
  mid-surfaces that stop t/2 short of the plate they stand on.
- curved faces and solids that are not plate-like are reported (not meshed): hull shell meshing is a later step.
"""
import math
import numpy as np


def _wire_points(wire, face, h):
    from OCP.BRepTools import BRepTools_WireExplorer
    from OCP.BRepAdaptor import BRepAdaptor_Curve
    from OCP.GeomAbs import GeomAbs_Line
    from OCP.BRep import BRep_Tool
    from OCP.GCPnts import GCPnts_AbscissaPoint
    pts = []
    ex = BRepTools_WireExplorer(wire.wrapped, face.wrapped)
    while ex.More():
        e = ex.Current()
        c = BRepAdaptor_Curve(e)
        v = BRep_Tool.Pnt_s(ex.CurrentVertex())
        v = np.array([v.X(), v.Y(), v.Z()])
        if c.GetType() == GeomAbs_Line:
            P = [np.array(c.Value(c.FirstParameter()).Coord()), np.array(c.Value(c.LastParameter()).Coord())]
        else:
            L = GCPnts_AbscissaPoint.Length_s(c)
            n = max(8 if c.IsClosed() else 2, int(math.ceil(L / h)))
            P = [np.array(c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * k / n).Coord()) for k in range(n + 1)]
        if np.linalg.norm(P[0] - v) > np.linalg.norm(P[-1] - v):
            P = P[::-1]
        pts += P[:-1]
        ex.Next()
    out = []
    for p in pts:                                     # drop repeats
        if not out or np.linalg.norm(p - out[-1]) > 1e-6:
            out.append(p)
    if len(out) > 1 and np.linalg.norm(out[0] - out[-1]) < 1e-6:
        out.pop()
    return out


def _face_loops(f, h):
    outer = f.outerWire()
    loops = [_wire_points(outer, f, h)]
    for w in f.innerWires():
        loops.append(_wire_points(w, f, h))
    return loops


def _planar(f):
    return f.geomType() == 'PLANE'


def shape_to_plates(shape, h=100.0, default_t=10.0, max_ratio=0.25):
    """returns (plates, report). shape: cadquery Shape / Workplane / Compound"""
    import cadquery as cq
    if isinstance(shape, cq.Workplane):
        shape = cq.Compound.makeCompound([v for v in shape.vals() if isinstance(v, cq.Shape)])
    plates, rep = [], {'solids': 0, 'solids_to_plates': 0, 'faces_to_plates': 0, 'skipped': []}
    solids = shape.Solids()
    k = 0
    for si, s in enumerate(solids):
        rep['solids'] += 1
        faces = [f for f in s.Faces() if _planar(f)]
        if not faces:
            rep['skipped'].append(f'solid {si + 1}: no planar faces')
            continue
        f1 = max(faces, key=lambda f: f.Area())
        n1 = np.array(f1.normalAt().toTuple())
        c1 = np.array(f1.Center().toTuple())
        best = None
        for f2 in faces:
            n2 = np.array(f2.normalAt().toTuple())
            if f2 is f1 or n1 @ n2 > -0.999:
                continue
            d = abs((np.array(f2.Center().toTuple()) - c1) @ n1)
            if abs(f2.Area() - f1.Area()) < 0.2 * f1.Area() and d > 1e-6 and (best is None or d < best):
                best = d
        if best is None or best > max_ratio * math.sqrt(f1.Area()):
            bb = s.BoundingBox()
            rep['skipped'].append(f'solid {si + 1}: not plate-like ({bb.xlen:.0f} x {bb.ylen:.0f} x {bb.zlen:.0f} mm)')
            continue
        loops = [[p - n1 * best / 2 for p in L] for L in _face_loops(f1, h)]
        k += 1
        plates.append({'id': f'S{k}', 'group': f'S{k}', 't': round(best, 3), 'outline': [p.tolist() for p in loops[0]],
                       'holes': [[p.tolist() for p in L] for L in loops[1:]]})
        rep['solids_to_plates'] += 1
    # loose faces (sheet bodies / shells not in a solid)
    in_solid = set()
    for s in solids:
        for f in s.Faces():
            in_solid.add(f.hashCode())
    for f in shape.Faces():
        if f.hashCode() in in_solid:
            continue
        if not _planar(f):
            rep['skipped'].append('curved face (not meshed yet)')
            continue
        loops = _face_loops(f, h)
        k += 1
        plates.append({'id': f'F{k}', 'group': f'F{k}', 't': default_t, 'outline': [p.tolist() for p in loops[0]],
                       'holes': [[p.tolist() for p in L] for L in loops[1:]]})
        rep['faces_to_plates'] += 1
    return plates, rep


def import_cad(path):
    import cadquery as cq
    low = path.lower()
    if low.endswith(('.step', '.stp')):
        wp = cq.importers.importStep(path)
        vals = [v for v in wp.vals() if isinstance(v, cq.Shape)]
        return vals[0] if len(vals) == 1 else cq.Compound.makeCompound(vals)
    if low.endswith('.brep'):
        return cq.Shape.importBrep(path)
    if low.endswith('.stl'):                        # mesh -> exact solid with next.BREP.io's stl2step, then as a STEP
        from .brep import stl_to_step
        step, _ = stl_to_step(path)
        return import_cad(step)
    from . import cadmpeg
    if cadmpeg.is_native(path):                     # SolidWorks, CATIA, Inventor, Fusion, Rhino, FreeCAD, ACIS, IGES ...
        r = cadmpeg.to_step(path)                   # cadmpeg (Apache-2.0) reads the native file, writes STEP
        if r.get('geometry_transferred') is False:
            raise ValueError(r['plain_english'])
        return import_cad(r['file'])
    raise ValueError('CAD input must be STEP (.step/.stp), BREP, STL or a native CAD file cadmpeg reads '
                     '(.sldprt .CATPart .ipt .f3d .3dm .FCStd .sat .igs ...)')


def mesh_cad(path, element_size=100.0, default_t=10.0, out_dir='.', name=None, loads=None, fix=None, material=None, clean=True, beams=None):
    import os
    from .platemesh import build_plates
    from . import geoclean
    shape = import_cad(path)
    actions = []
    if clean:
        shape, actions = geoclean.clean_shape(shape)
    plates, rep = shape_to_plates(shape, float(element_size), float(default_t))
    if clean and plates:
        plates, a2 = geoclean.clean_plates(plates, merge_tol=max(1.0, float(element_size) / 50))
        actions += [a for a in a2 if not a.startswith('Geometry was already clean')]
    rep['cleaning'] = actions or ['nothing to clean']
    if not plates:
        raise ValueError('no plate-like geometry found: ' + '; '.join(rep['skipped'][:5]))
    spec = {'name': name or os.path.splitext(os.path.basename(path))[0], 'element_size': element_size, 'plates': plates,
            'loads': loads or [], 'fix': fix or [], 'beams': beams or []}
    if material:
        spec['material'] = material
    m, info = build_plates(spec, out_dir)
    info['cad'] = rep
    return m, info
