# Prompt: T-bar web frame profile web 400x10 flange 150x15, 3200 long, hanging below z=0
# Tags: T bar tee profile web flange girder frame extrude
import cadquery as cq
L, hw, tw, bf, tf = 3200, 400, 10, 150, 15
web = cq.Workplane("XY").box(L, tw, hw - tf, centered=(False, True, False)).translate((0, 0, -(hw - tf)))
flange = cq.Workplane("XY").box(L, bf, tf, centered=(False, True, False)).translate((0, 0, -hw))
result = web.union(flange)
