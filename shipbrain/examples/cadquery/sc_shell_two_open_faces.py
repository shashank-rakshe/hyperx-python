# Prompt: box 50 x 40 x 30 mm shelled 3 mm inward with the top and front (y = 0) faces open
# Tags: shell open faces hollow wall tray
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/46-shell-two-open-faces)
# Expect: {"bbox": [50.0, 40.0, 30.0], "volume": 16044, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = cq.Workplane("XY").box(50, 40, 30, centered=False).faces(">Z or <Y").shell(-3)
