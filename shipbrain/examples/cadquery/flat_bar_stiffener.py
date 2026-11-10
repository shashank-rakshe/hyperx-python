# Prompt: flat bar stiffener 150x12, 2400 long, standing on the XY plane
# Tags: stiffener flat bar FB profile extrude
import cadquery as cq
L, h, t = 2400, 150, 12
result = cq.Workplane("YZ").rect(t, h, centered=(True, False)).extrude(L)
