# Prompt: flange ring OD 100, ID 30, 10 mm thick with 6 bolt holes of 10 mm on an 80 mm pitch circle
# Tags: flange ring annulus bolt circle polar pattern holes
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/11-circular-pattern-flange)
# Expect: {"bbox": [100.0, 100.0, 10.0], "volume": 66758.84, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = (cq.Workplane("XY").circle(50).circle(15).extrude(10)
          .faces(">Z").workplane().polarArray(40, 0, 360, 6).hole(10))
