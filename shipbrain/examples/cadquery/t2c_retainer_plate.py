# Prompt: retainer plate 82 x 34 x 6 mm with a 36 x 10 mm slot in the middle and two 7 mm holes at x = +/-30
# Tags: plate slot holes retainer obround
# Source: https://github.com/earthtojake/text-to-cad (MIT), ported to CadQuery (text-to-cad models/examples/src/retainer_plate.py)
# Expect: {"bbox": [82, 34, 6], "n_solids": 1, "tol": 0.002}
import cadquery as cq
L, W, t = 82, 34, 6
plate = cq.Workplane("XY").box(L, W, t, centered=(True, True, False))
cut = cq.Workplane("XY").slot2D(36, 10).extrude(t)
cut = cut.union(cq.Workplane("XY").pushPoints([(-30, 0), (30, 0)]).circle(3.5).extrude(t))
result = plate.cut(cut)
