# Prompt: box 40 x 30 x 20 mm with a 2 mm chamfer on the four top edges
# Tags: chamfer bevel top edges box
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/08-chamfer)
# Expect: {"bbox": [40.0, 30.0, 20.0], "volume": 23730.67, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = cq.Workplane("XY").box(40, 30, 20).faces(">Z").edges().chamfer(2)
