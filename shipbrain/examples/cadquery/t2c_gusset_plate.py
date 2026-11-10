# Prompt: gusset plate: base 88 x 30 x 6 mm with an 8 mm thick triangular web 48 mm high and two 6 mm base holes at x = +/-28
# Tags: gusset bracket triangle web base holes knee
# Source: https://github.com/earthtojake/text-to-cad (MIT), ported to CadQuery (text-to-cad models/examples/src/gusset_plate.py)
# Expect: {"bbox": [88, 30, 54], "n_solids": 1, "tol": 0.002}
import cadquery as cq
base = cq.Workplane("XY").box(88, 30, 6, centered=(True, True, False))
web = (cq.Workplane("YZ").polyline([(-12, 6), (12, 6), (12, 54)]).close().extrude(4, both=True))
part = base.union(web)
result = part.cut(cq.Workplane("XY").pushPoints([(-28, -6), (28, -6)]).circle(3).extrude(6))
