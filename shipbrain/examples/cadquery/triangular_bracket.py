# Prompt: triangular bracket 600x600 legs, 12 thick, with a 150 mm flange width free edge not modelled, corner snipe 30
# Tags: bracket knee triangle snipe plate polyline
import cadquery as cq
a, b, t, s = 600, 600, 12, 30
pts = [(s, 0), (a, 0), (0, b), (0, s)]
result = cq.Workplane("XZ").polyline(pts).close().extrude(t)
