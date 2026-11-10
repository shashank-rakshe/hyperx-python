# Prompt: plate 80 x 50 x 10 mm with 6 counterbored through holes (5.5 mm hole, counterbore 10 mm x 5.5 deep) at x 15/40/65, y 15/35
# Tags: counterbore cbore holes plate bolt pattern
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/57-hole-pattern-sketch-points)
# Expect: {"bbox": [80.0, 50.0, 10.0], "volume": 36766.71, "n_solids": 1, "tol": 0.002}
import cadquery as cq
pts = [(x, y) for x in (15, 40, 65) for y in (15, 35)]
result = (cq.Workplane("XY").box(80, 50, 10, centered=False)
          .faces(">Z").workplane(origin=(0, 0, 10)).pushPoints(pts).cboreHole(5.5, 10, 5.5))
