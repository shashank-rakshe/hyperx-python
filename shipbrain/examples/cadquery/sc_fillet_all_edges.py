# Prompt: box 40 x 30 x 20 mm with all 12 edges rounded R3
# Tags: fillet round edges box
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/07-fillet-all-edges)
# Expect: {"bbox": [40.0, 30.0, 20.0], "volume": 23340.85, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = cq.Workplane("XY").box(40, 30, 20).edges().fillet(3)
