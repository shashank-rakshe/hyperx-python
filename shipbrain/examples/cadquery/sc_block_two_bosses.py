# Prompt: block 60 x 30 x 10 mm centred on X with two 12 mm bosses 15 mm tall on top at x = +/-15 (mirrored)
# Tags: boss mirror symmetric block cylinder
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/12-mirror-feature)
# Expect: {"bbox": [60.0, 30.0, 25.0], "volume": 21392.92, "n_solids": 1, "tol": 0.002}
import cadquery as cq
block = cq.Workplane("XY").box(60, 30, 10, centered=(True, False, False))
bosses = cq.Workplane("XY").workplane(offset=10).pushPoints([(-15, 15), (15, 15)]).circle(6).extrude(15)
result = block.union(bosses)
