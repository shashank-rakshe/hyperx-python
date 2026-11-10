# Prompt: rectangular clamp block 70 x 34 x 28 mm with a 4 mm split slot along its length cut down to 8 mm above the bottom, and two 5.5 mm transverse screw holes at x = +/-20
# Tags: clamp block split slot screw holes
# Source: https://github.com/earthtojake/text-to-cad (MIT), ported to CadQuery (text-to-cad models/examples/src/clamp_block.py)
# Expect: {"bbox": [70, 34, 28], "n_solids": 1, "tol": 0.002}
import cadquery as cq
L, W, H = 70, 34, 28
blk = cq.Workplane("XY").box(L, W, H, centered=(True, True, False))
blk = blk.cut(cq.Workplane("XY").box(L, 4, H - 8, centered=(True, True, False)).translate((0, 0, 8)))
for x in (-20, 20):
    blk = blk.cut(cq.Workplane("XZ").workplane(offset=-W / 2).center(x, H / 2).circle(2.75).extrude(-W))
result = blk
