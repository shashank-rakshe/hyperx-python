# Prompt: sheet-metal plate 100 x 60 mm, 2.5 mm thick, with a 20 mm flange bent up 90 degrees on the y = 0 edge, inner bend radius 2.5
# Tags: flange bend sheet metal flanged plate knuckle
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/68-sm-edge-flange)
# Expect: {"bbox": [100.0, 60.0, 20.0], "volume": 18972.62, "n_solids": 1, "tol": 0.002}
import cadquery as cq
t, R = 2.5, 2.5
c = R + t
k = 0.7071067811865476
section = (cq.Workplane("YZ").moveTo(60, 0).lineTo(c, 0)
           .threePointArc((c - c * k, c - c * k), (0, c)).lineTo(0, 20).lineTo(t, 20).lineTo(t, c)
           .threePointArc((c - R * k, c - R * k), (c, t)).lineTo(60, t).close())
result = section.extrude(100)
