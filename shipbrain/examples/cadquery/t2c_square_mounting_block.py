# Prompt: square mounting block 48 x 48 x 28 mm with a 12 mm vertical through hole and two 5.5 mm side clearance holes at y = +/-14
# Tags: block mounting holes cross hole clearance
# Source: https://github.com/earthtojake/text-to-cad (MIT), ported to CadQuery (text-to-cad models/examples/src/square_mounting_block.py)
# Expect: {"bbox": [48, 48, 28], "n_solids": 1, "tol": 0.002}
import cadquery as cq
s, h = 48, 28
blk = cq.Workplane("XY").box(s, s, h, centered=(True, True, False))
blk = blk.cut(cq.Workplane("XY").circle(6).extrude(h))
for y in (-14, 14):
    blk = blk.cut(cq.Workplane("YZ").workplane(offset=-s / 2).center(y, h / 2).circle(2.75).extrude(s))
result = blk
