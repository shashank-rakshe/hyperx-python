# Prompt: floor plate 3000x1200x12 with three lightening holes 600x400 with R200 ends, evenly spaced
# Tags: plate lightening hole slot floor web opening rarray
import cadquery as cq
L, H, t = 3000, 1200, 12
result = (cq.Workplane("XZ").rect(L, H).extrude(t)
          .faces(">Y").workplane(centerOption="CenterOfBoundBox")
          .rarray(L / 3, 1, 3, 1).slot2D(600, 400).cutThruAll())
