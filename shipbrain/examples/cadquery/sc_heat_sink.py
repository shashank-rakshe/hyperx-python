# Prompt: heat sink: base 60 x 50 x 5 mm with 15 fins 1.5 mm thick, 25 mm tall, 50 mm long at x = 2 + 4k
# Tags: fins heat sink rib pattern array base plate
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/62-heat-sink)
# Expect: {"bbox": [60.0, 50.0, 30.0], "volume": 43125.0, "n_solids": 1, "tol": 0.002}
import cadquery as cq
base = cq.Workplane("XY").box(60, 50, 5, centered=False)
fins = [cq.Workplane("XY").box(1.5, 50, 25, centered=False).translate((2 + 4 * k, 0, 5)) for k in range(15)]
result = base
for f in fins:
    result = result.union(f)
