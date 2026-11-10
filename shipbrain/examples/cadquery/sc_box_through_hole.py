# Prompt: block 60 x 40 x 20 mm with a 12 mm through hole in the centre of the top face
# Tags: block hole through centre bore
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/03-box-through-hole)
# Expect: {"bbox": [60.0, 40.0, 20.0], "volume": 45738.05, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = (cq.Workplane("XY").box(60, 40, 20, centered=False)
          .faces(">Z").workplane(centerOption="CenterOfBoundBox").hole(12))
