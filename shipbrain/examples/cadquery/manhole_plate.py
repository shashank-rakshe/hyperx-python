# Prompt: tank top plate 2000x1500x14 with an elliptical manhole 600x400 in the centre and a 50 thick coaming ring 100 high
# Tags: manhole ellipse opening coaming plate tank top
import cadquery as cq
L, B, t = 2000, 1500, 14
plate = cq.Workplane("XY").rect(L, B).extrude(t).faces(">Z").workplane().ellipse(300, 200).cutThruAll()
ring = cq.Workplane("XY").workplane(offset=t).ellipse(350, 250).ellipse(300, 200).extrude(100)
result = plate.union(ring)
