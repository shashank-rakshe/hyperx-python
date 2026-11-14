# Prompt: plate 60 x 40 x 10 mm with R5 rounded vertical corners and two 8 mm holes at (+/-15, 20)
# Tags: plate rounded corners fillet holes mirror symmetric bracket
# Source: https://github.com/tangency-labs/solidcraft (MIT OR Apache-2.0), ported to CadQuery (solidcraft tests/oracle/54-mirror-body-fillets)
# Expect: {"bbox": [60.0, 40.0, 10.0], "volume": 22780.09, "n_solids": 1, "tol": 0.002}
import cadquery as cq
plate = cq.Workplane("XY").box(60, 40, 10, centered=(True, False, False)).edges("|Z").fillet(5)
result = plate.cut(cq.Workplane("XY").pushPoints([(-15, 20), (15, 20)]).circle(4).extrude(10))
