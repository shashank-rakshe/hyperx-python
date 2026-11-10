# Prompt: pulley 80 mm diameter, 40 mm wide, 10 mm bore, two trapezoidal V-grooves 7 mm deep (revolved profile)
# Tags: pulley revolve groove profile wheel
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/48-pulley)
# Expect: {"bbox": [80.0, 80.0, 40.0], "volume": 168510.84, "n_solids": 1, "tol": 0.002}
import cadquery as cq
pts = [(5, 0), (40, 0), (40, 3), (33, 8), (33, 12), (40, 17), (40, 23), (33, 28), (33, 32), (40, 37), (40, 40), (5, 40)]
result = cq.Workplane("XZ").polyline(pts).close().revolve(360, (0, 0, 0), (0, 1, 0))
