# Prompt: bent U channel 80 mm long, 50 mm wide, 20 mm high flanges, 1.5 mm sheet, inner bend radius 3
# Tags: channel U bend sheet metal flange
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/71-sm-custom-rule)
# Expect: {"bbox": [80.0, 50.0, 20.0], "volume": 10053.72, "n_solids": 1, "tol": 0.002}
import cadquery as cq
t, R, W, H = 1.5, 3.0, 50.0, 20.0
c = R + t
k = 0.7071067811865476
section = (cq.Workplane("YZ").moveTo(0, H).lineTo(0, c)
           .threePointArc((c - c * k, c - c * k), (c, 0)).lineTo(W - c, 0)
           .threePointArc((W - c + c * k, c - c * k), (W, c)).lineTo(W, H).lineTo(W - t, H).lineTo(W - t, c)
           .threePointArc((W - c + R * k, c - R * k), (W - c, t)).lineTo(c, t)
           .threePointArc((c - R * k, c - R * k), (t, c)).lineTo(t, H).close())
result = section.extrude(80)
