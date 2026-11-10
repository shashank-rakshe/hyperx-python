# Prompt: deck panel 4800x3200x12 with HP-like flat bars 160x10 every 800 mm underneath, running along X
# Tags: stiffened panel deck plate stiffeners array union
import cadquery as cq
L, B, t, s, h, tw = 4800, 3200, 12, 800, 160, 10
result = cq.Workplane("XY").box(L, B, t, centered=(False, False, False))
y = s
while y < B - 1:
    bar = cq.Workplane("XY").box(L, tw, h, centered=(False, True, False)).translate((0, y, -h))
    result = result.union(bar)
    y += s
