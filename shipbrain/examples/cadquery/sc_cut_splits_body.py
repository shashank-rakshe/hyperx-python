# Prompt: bar 80 x 20 x 20 mm with a 10 mm wide slot cut right through at x = 35..45, leaving two separate pieces
# Tags: cut split two bodies solids slot
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/43-cut-splits-body)
# Expect: {"bbox": [80.0, 20.0, 20.0], "volume": 28000, "n_solids": 2, "tol": 0.002}
import cadquery as cq
bar = cq.Workplane("XY").box(80, 20, 20, centered=False)
result = bar.cut(cq.Workplane("XY").box(10, 30, 20, centered=False).translate((35, -5, 0)))
