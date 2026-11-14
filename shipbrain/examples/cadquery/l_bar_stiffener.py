# Prompt: L angle stiffener 250x90 web 10 flange 12, 2000 long, profile drawn as a polyline and extruded
# Tags: L bar angle profile polyline extrude
import cadquery as cq
L, h, b, tw, tf = 2000, 250, 90, 10, 12
pts = [(0, 0), (tw, 0), (tw, -(h - tf)), (b, -(h - tf)), (b, -h), (0, -h)]
result = cq.Workplane("YZ").polyline(pts).close().extrude(L)
