# Prompt: closed box girder 6000 long, 800 wide, 600 high, plates 12 thick (hollow rectangular section)
# Tags: box girder hollow section shell rect extrude
import cadquery as cq
L, B, H, t = 6000, 800, 600, 12
result = cq.Workplane("YZ").rect(B, H).rect(B - 2 * t, H - 2 * t).extrude(L)
