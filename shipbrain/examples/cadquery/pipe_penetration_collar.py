# Prompt: bulkhead plate 1000x1000x10 with a 219 mm pipe penetration and a collar ring 20 thick 80 wide welded around it
# Tags: penetration pipe hole collar ring bulkhead circle
import cadquery as cq
plate = cq.Workplane("XY").rect(1000, 1000).extrude(10).faces(">Z").workplane().hole(219)
collar = cq.Workplane("XY").workplane(offset=10).circle(109.5 + 80).circle(109.5).extrude(20)
result = plate.union(collar)
