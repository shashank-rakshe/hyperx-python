# Prompt: plate 150 x 80 x 10 mm with four 8 mm through bores 15 mm in from each corner
# Tags: plate corner holes bores bolt four
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/88-plate-four-bores)
# Expect: {"bbox": [150, 80, 10], "volume": 117989.38, "n_solids": 1, "tol": 0.002}
import cadquery as cq
pts = [(15, 15), (135, 15), (15, 65), (135, 65)]
plate = cq.Workplane("XY").box(150, 80, 10, centered=False)
result = plate.cut(cq.Workplane("XY").pushPoints(pts).circle(4).extrude(10))
