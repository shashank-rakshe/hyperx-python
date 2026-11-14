# Prompt: web frame plate 3200 long 800 high 10 thick with 4 slots 40 wide 170 deep at the top edge for 160 mm stiffeners at 800 spacing
# Tags: web frame cutout slot scallop stiffener passing plate
import cadquery as cq
L, H, t, s, w, d = 3200, 800, 10, 800, 40, 170
result = cq.Workplane("XZ").rect(L, H, centered=(False, False)).extrude(-t)
for k in range(1, 5):
    x = k * s - s / 2
    cut = cq.Workplane("XY").box(w, 3 * t, d, centered=(True, True, False)).translate((x, 0, H - d))
    result = result.cut(cut)
