# Prompt: square 40 x 40 mm extruded 30 mm with a 10 degree outward taper (frustum that grows upward)
# Tags: taper draft frustum extrude pyramid
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/05-taper-extrude)
# Expect: {"bbox": [50.5796, 50.5796, 30.0], "volume": 61814.83, "n_solids": 1, "tol": 0.002}
import cadquery as cq
import math
top = 40 + 2 * 30 * math.tan(math.radians(10))
result = cq.Workplane("XY").rect(40, 40).workplane(offset=30).rect(top, top).loft()
