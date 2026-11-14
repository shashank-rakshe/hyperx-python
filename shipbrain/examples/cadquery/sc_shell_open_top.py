# Prompt: open-top box 50 x 40 x 30 mm, walls and bottom 2 mm thick (shelled inward)
# Tags: shell hollow tray open box wall
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/09-shell)
# Expect: {"bbox": [50.0, 40.0, 30.0], "volume": 13632.0, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = cq.Workplane("XY").box(50, 40, 30).faces(">Z").shell(-2)
