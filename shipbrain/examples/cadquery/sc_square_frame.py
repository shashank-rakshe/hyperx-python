# Prompt: square frame 42 x 42 mm outside, 34 x 34 mm inside, 10 mm tall
# Tags: frame ring thin wall square tube
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/82-thin-extrude-frame)
# Expect: {"bbox": [42.0, 42.0, 10.0], "volume": 6080.0, "n_solids": 1, "tol": 0.002}
import cadquery as cq
result = cq.Workplane("XY").rect(42, 42).rect(34, 34).extrude(10)
