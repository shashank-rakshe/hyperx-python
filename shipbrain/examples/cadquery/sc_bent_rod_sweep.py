# Prompt: rod of 6 mm diameter swept along a path: 30 mm up, R20 90 degree bend, 30 mm along +X
# Tags: sweep pipe bend rod path tube
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/16-sweep)
# Expect: {"bbox": [53.0, 6.0, 53.0], "volume": 2584.72, "n_solids": 1, "tol": 0.002}
import cadquery as cq
path = (cq.Workplane("XZ").lineTo(0, 30)
        .threePointArc((20 - 20 * 0.7071067811865476, 30 + 20 * 0.7071067811865476), (20, 50)).lineTo(50, 50))
result = cq.Workplane("XY").circle(3).sweep(path)
