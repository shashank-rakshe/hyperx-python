# Prompt: trapezoid plate, bottom 60 mm, top 30 mm, 25 mm high, 5 mm thick, two 6 mm holes at (+/-18, 8)
# Tags: trapezoid polyline plate holes symmetric
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/27-sketch-trapezoid)
# Expect: {"bbox": [60.0, 25.0, 5.0], "volume": 5342.26, "n_solids": 1, "tol": 0.002}
import cadquery as cq
outline = [(-30, 0), (30, 0), (15, 25), (-15, 25)]
plate = cq.Workplane("XY").polyline(outline).close().extrude(5)
result = plate.cut(cq.Workplane("XY").pushPoints([(-18, 8), (18, 8)]).circle(3).extrude(5))
