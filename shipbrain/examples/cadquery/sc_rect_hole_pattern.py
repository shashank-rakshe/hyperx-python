# Prompt: plate 90 x 70 x 5 mm with 12 holes of 6 mm diameter in a 4 x 3 grid at 20 mm pitch, first hole at (15, 15)
# Tags: plate hole pattern grid array rectangular
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/10-rect-pattern-holes)
# Expect: {"bbox": [90.0, 70.0, 5.0], "volume": 29803.54, "n_solids": 1, "tol": 0.002}
import cadquery as cq
pts = [(15 + 20 * i, 15 + 20 * j) for i in range(4) for j in range(3)]
plate = cq.Workplane("XY").box(90, 70, 5, centered=False)
holes = cq.Workplane("XY").pushPoints(pts).circle(3).extrude(5)
result = plate.cut(holes)
