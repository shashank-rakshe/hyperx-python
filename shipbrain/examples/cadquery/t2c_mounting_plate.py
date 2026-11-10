# Prompt: mounting plate 100 x 70 x 8 mm with R5 corners, a 28 mm central cut-out, a 30 x 8 mm slot along Y at x = 32 and four 5.5 mm corner holes
# Tags: mounting plate cutout slot corner holes rounded
# Source: https://github.com/earthtojake/text-to-cad (MIT), ported to CadQuery (text-to-cad models/examples/src/mounting_plate.py)
# Expect: {"bbox": [100, 70, 8], "n_solids": 1, "tol": 0.002}
import cadquery as cq
L, W, t = 100, 70, 8
plate = cq.Workplane("XY").box(L, W, t, centered=(True, True, False)).edges("|Z").fillet(5)
cut = cq.Workplane("XY").circle(14).extrude(t)
cut = cut.union(cq.Workplane("XY").center(32, 0).slot2D(30, 8, angle=90).extrude(t))
pts = [(x, y) for x in (-38, 38) for y in (-24, 24)]
cut = cut.union(cq.Workplane("XY").pushPoints(pts).circle(2.75).extrude(t))
result = plate.cut(cut)
