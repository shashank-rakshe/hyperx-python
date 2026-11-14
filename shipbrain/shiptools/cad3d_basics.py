"""
cad3d_basics.py - "2D drawing -> 3D model" basics.

17 basic part families, each drawn as a real 3-view orthographic drawing (third angle):
    FRONT (X right, Z up)   TOP (X right, Y up, above front)   RIGHT (Y right, Z up, right of front)
with hidden lines (dashed), centre lines (dash-dot), overall dimensions and a notes block.
Every sample = drawing image + prompt -> CadQuery script. Each script is executed (if cadquery is installed) and
checked against the drawing: bounding box AND analytic volume. Samples that fail are discarded and counted per family.

  python cad3d_basics.py --n 200 --out basics_data            # needs cadquery for validation
  python cad3d_basics.py --n 40 --out basics_test --no-validate   # preview only

Families: block, cylinder, tube, plate_center_hole, plate_corner_holes, blind_hole_block, chamfer_block, rounded_block,
          stepped_block, angle_profile, channel_profile, tee_profile, slot_plate, csk_plate, flange, stepped_shaft, pocket_block
"""
import argparse, json, math, random, re
from pathlib import Path

PI = math.pi
PROMPTS = [
    "This drawing shows the front, top and right views (third angle). Build the 3D solid in CadQuery. Match every dimension. Final solid: `result`.",
    "Read the three views and write CadQuery code that creates this part in 3D. Assign the solid to `result`.",
    "2D drawing to 3D model: write the CadQuery script for the part shown in the front, top and right views. The solid must be named `result`.",
]


# ------------------------------------------------------------- drawing prims
def line(x0, y0, x1, y1, s="o"): return ("line", x0, y0, x1, y1, s)
def circ(cx, cy, r, s="o"): return ("circle", cx, cy, r, s)
def arc(cx, cy, r, t1, t2, s="o"): return ("arc", cx, cy, r, t1, t2, s)
def hd(x0, x1, y, t): return ("hdim", x0, x1, y, t)
def vd(y0, y1, x, t): return ("vdim", y0, y1, x, t)


def rect(x0, y0, x1, y1, s="o"):
    return [line(x0, y0, x1, y0, s), line(x1, y0, x1, y1, s), line(x1, y1, x0, y1, s), line(x0, y1, x0, y0, s)]


def poly(pts, s="o"):
    return [line(*pts[i], *pts[(i + 1) % len(pts)], s) for i in range(len(pts))]


def clv(x, y0, y1): return line(x, y0, x, y1, "c")
def clh(x0, x1, y): return line(x0, y, x1, y, "c")


def rrect(x0, y0, x1, y1, r):
    return [line(x0 + r, y0, x1 - r, y0), line(x1, y0 + r, x1, y1 - r), line(x1 - r, y1, x0 + r, y1), line(x0, y1 - r, x0, y0 + r),
            arc(x1 - r, y0 + r, r, 270, 360), arc(x1 - r, y1 - r, r, 0, 90), arc(x0 + r, y1 - r, r, 90, 180), arc(x0 + r, y0 + r, r, 180, 270)]


def off(*d): return 0.14 * max(d)


def std_dims(L, W, H):
    o = off(L, W, H)
    return [hd(0, L, -o, f"{L:g}"), vd(0, H, -o, f"{H:g}")], [vd(0, W, -o, f"{W:g}")], [hd(0, W, -o, f"{W:g}")]


def part(name, code, bbox, vol, front, top, right, notes=()):
    return dict(name=name, code=code, bbox=bbox, vol=vol, front=front, top=top, right=right, notes=list(notes))


def cx(r, a, b, step=1): return r.choice(list(range(a, b + 1, step)))


# ---------------------------------------------------------------- families
def f_block(r):
    L, W, H = cx(r, 30, 200, 10), cx(r, 20, 150, 10), cx(r, 10, 100, 5)
    code = f"import cadquery as cq\n\nL, W, H = {L}, {W}, {H}\nresult = cq.Workplane(\"XY\").box(L, W, H, centered=(True, True, False))\n"
    a, b, c = std_dims(L, W, H)
    return part("block", code, (L, W, H), L * W * H, rect(0, 0, L, H) + a, rect(0, 0, L, W) + b, rect(0, 0, W, H) + c)


def f_cylinder(r):
    D, H = cx(r, 10, 100, 5), cx(r, 10, 120, 5)
    code = f"import cadquery as cq\n\nD, H = {D}, {H}\nresult = cq.Workplane(\"XY\").circle(D / 2).extrude(H)\n"
    o = off(D, H); m = D / 2
    front = rect(0, 0, D, H) + [clv(m, -o / 2, H + o / 2), hd(0, D, -o, f"dia {D:g}"), vd(0, H, -o, f"{H:g}")]
    top = [circ(m, m, m), clh(-o / 2, D + o / 2, m), clv(m, -o / 2, D + o / 2)]
    right = rect(0, 0, D, H) + [clv(m, -o / 2, H + o / 2)]
    return part("cylinder", code, (D, D, H), PI / 4 * D * D * H, front, top, right)


def f_tube(r):
    OD, H = cx(r, 20, 100, 5), cx(r, 10, 120, 5)
    wall = r.choice([w for w in (3, 4, 5, 6, 8, 10) if OD - 2 * w >= 6])
    ID = OD - 2 * wall
    code = f"import cadquery as cq\n\nOD, ID, H = {OD}, {ID}, {H}\nresult = cq.Workplane(\"XY\").circle(OD / 2).circle(ID / 2).extrude(H)\n"
    o = off(OD, H); m = OD / 2
    hid = [line(m - ID / 2, 0, m - ID / 2, H, "h"), line(m + ID / 2, 0, m + ID / 2, H, "h"), clv(m, -o / 2, H + o / 2)]
    front = rect(0, 0, OD, H) + hid + [hd(0, OD, -o, f"dia {OD:g}"), vd(0, H, -o, f"{H:g}")]
    top = [circ(m, m, m), circ(m, m, ID / 2), clh(-o / 2, OD + o / 2, m), clv(m, -o / 2, OD + o / 2)]
    return part("tube", code, (OD, OD, H), PI / 4 * (OD ** 2 - ID ** 2) * H, front, top, rect(0, 0, OD, H) + hid, [f"bore dia {ID}"])


def f_plate_center_hole(r):
    L, W, T = cx(r, 60, 200, 10), cx(r, 40, 140, 10), r.choice([4, 5, 6, 8, 10, 12])
    d = r.choice([d for d in (6, 8, 10, 12, 16, 20, 25) if d < min(L, W) / 2])
    code = (f"import cadquery as cq\n\nL, W, T, D = {L}, {W}, {T}, {d}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, T, centered=(True, True, False))\n    .faces(\">Z\").workplane().hole(D)\n)\n")
    a, b, c = std_dims(L, W, T); o = off(L, W, T)
    front = rect(0, 0, L, T) + a + [line(L / 2 - d / 2, 0, L / 2 - d / 2, T, "h"), line(L / 2 + d / 2, 0, L / 2 + d / 2, T, "h"), clv(L / 2, -o / 2, T + o / 2)]
    top = rect(0, 0, L, W) + b + [circ(L / 2, W / 2, d / 2), clh(L / 2 - d, L / 2 + d, W / 2), clv(L / 2, W / 2 - d, W / 2 + d)]
    right = rect(0, 0, W, T) + c + [line(W / 2 - d / 2, 0, W / 2 - d / 2, T, "h"), line(W / 2 + d / 2, 0, W / 2 + d / 2, T, "h")]
    return part("plate_center_hole", code, (L, W, T), L * W * T - PI / 4 * d * d * T, front, top, right, [f"1x dia {d} THRU", f"thickness {T}"])


def f_plate_corner_holes(r):
    L, W, T = cx(r, 60, 200, 10), cx(r, 40, 140, 10), r.choice([4, 5, 6, 8, 10, 12])
    m, d = r.choice([8, 10, 12, 15]), r.choice([4, 5, 6, 8, 10])
    code = (f"import cadquery as cq\n\nL, W, T, M, D = {L}, {W}, {T}, {m}, {d}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, T, centered=(True, True, False))\n"
            "    .faces(\">Z\").workplane()\n    .rect(L - 2 * M, W - 2 * M, forConstruction=True).vertices()\n    .hole(D)\n)\n")
    a, b, c = std_dims(L, W, T)
    xs, ys = [m, L - m], [m, W - m]
    front = rect(0, 0, L, T) + a + [line(x + s * d / 2, 0, x + s * d / 2, T, "h") for x in xs for s in (-1, 1)]
    top = rect(0, 0, L, W) + b + [circ(x, y, d / 2) for x in xs for y in ys]
    right = rect(0, 0, W, T) + c + [line(y + s * d / 2, 0, y + s * d / 2, T, "h") for y in ys for s in (-1, 1)]
    return part("plate_corner_holes", code, (L, W, T), L * W * T - 4 * PI / 4 * d * d * T, front, top, right, [f"4x dia {d} THRU", f"holes {m} from edges", f"thickness {T}"])


def f_blind_hole_block(r):
    L, W, H = cx(r, 40, 150, 10), cx(r, 30, 120, 10), cx(r, 20, 80, 5)
    d = r.choice([d for d in (6, 8, 10, 12, 16, 20) if d < min(L, W) / 2])
    dep = r.choice([k for k in range(5, H, 5)])
    code = (f"import cadquery as cq\n\nL, W, H, D, DEPTH = {L}, {W}, {H}, {d}, {dep}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, H, centered=(True, True, False))\n    .faces(\">Z\").workplane().hole(D, DEPTH)\n)\n")
    a, b, c = std_dims(L, W, H)
    def hid(w): return [line(w / 2 - d / 2, H - dep, w / 2 - d / 2, H, "h"), line(w / 2 + d / 2, H - dep, w / 2 + d / 2, H, "h"), line(w / 2 - d / 2, H - dep, w / 2 + d / 2, H - dep, "h")]
    top = rect(0, 0, L, W) + b + [circ(L / 2, W / 2, d / 2), clh(L / 2 - d, L / 2 + d, W / 2), clv(L / 2, W / 2 - d, W / 2 + d)]
    return part("blind_hole_block", code, (L, W, H), L * W * H - PI / 4 * d * d * dep, rect(0, 0, L, H) + a + hid(L), top, rect(0, 0, W, H) + c + hid(W),
                [f"1x dia {d} x {dep} DEEP"])


def f_chamfer_block(r):
    L, W, H = cx(r, 40, 150, 10), cx(r, 30, 120, 10), cx(r, 20, 80, 5)
    c_ = r.choice([2, 3, 4, 5, 6])
    code = (f"import cadquery as cq\n\nL, W, H, C = {L}, {W}, {H}, {c_}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, H, centered=(True, True, False))\n    .faces(\">Z\").edges().chamfer(C)\n)\n")
    a, b, c = std_dims(L, W, H)
    def side(w): return poly([(0, 0), (w, 0), (w, H - c_), (w - c_, H), (c_, H), (0, H - c_)]) + [line(0, H - c_, w, H - c_)]
    top = rect(0, 0, L, W) + rect(c_, c_, L - c_, W - c_) + b
    return part("chamfer_block", code, (L, W, H), None, side(L) + a, top, side(W) + c, [f"top edges chamfer {c_}x{c_}"])


def f_rounded_block(r):
    L, W, H = cx(r, 40, 150, 10), cx(r, 30, 120, 10), cx(r, 10, 60, 5)
    rr = r.choice([3, 5, 8, 10])
    code = (f"import cadquery as cq\n\nL, W, H, R = {L}, {W}, {H}, {rr}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, H, centered=(True, True, False))\n    .edges(\"|Z\").fillet(R)\n)\n")
    a, b, c = std_dims(L, W, H)
    return part("rounded_block", code, (L, W, H), (L * W - (4 - PI) * rr * rr) * H, rect(0, 0, L, H) + a, rrect(0, 0, L, W, rr) + b, rect(0, 0, W, H) + c,
                [f"4 vertical corners R{rr}"])


def f_stepped_block(r):
    L1, W1, H1 = cx(r, 60, 160, 10), cx(r, 40, 120, 10), cx(r, 10, 40, 5)
    L2, W2, H2 = cx(r, 20, L1 - 20, 10), cx(r, 20, W1 - 20, 10), cx(r, 10, 50, 5)
    xo, yo = (L1 - L2) / 2, (W1 - W2) / 2
    code = (f"import cadquery as cq\n\nL1, W1, H1 = {L1}, {W1}, {H1}\nL2, W2, H2 = {L2}, {W2}, {H2}\n"
            "base = cq.Workplane(\"XY\").box(L1, W1, H1, centered=(True, True, False))\n"
            "top = cq.Workplane(\"XY\").workplane(offset=H1).box(L2, W2, H2, centered=(True, True, False))\n"
            "result = base.union(top)\n")
    H = H1 + H2; o = off(L1, W1, H)
    def prof(w, w2, ww): return poly([(0, 0), (w, 0), (w, H1), (ww + w2, H1), (ww + w2, H), (ww, H), (ww, H1), (0, H1)])
    front = prof(L1, L2, xo) + [hd(0, L1, -o, f"{L1:g}"), vd(0, H1, -o, f"{H1:g}"), vd(H1, H, L1 + o, f"{H2:g}")]
    top = rect(0, 0, L1, W1) + rect(xo, yo, xo + L2, yo + W2) + [vd(0, W1, -o, f"{W1:g}"), hd(xo, xo + L2, -o, f"{L2:g}")]
    right = prof(W1, W2, yo) + [hd(0, W1, -o, f"{W1:g}")]
    return part("stepped_block", code, (L1, W1, H), L1 * W1 * H1 + L2 * W2 * H2, front, top, right, [f"upper block {L2}x{W2}, centred"])


def f_angle_profile(r):
    A, B, T, W = cx(r, 30, 100, 10), cx(r, 30, 100, 10), r.choice([3, 4, 5, 6, 8]), cx(r, 30, 150, 10)
    code = (f"import cadquery as cq\n\nA, B, T, W = {A}, {B}, {T}, {W}\npts = [(0, 0), (A, 0), (A, T), (T, T), (T, B), (0, B)]\n"
            "result = cq.Workplane(\"XZ\").polyline(pts).close().extrude(W)\n")
    o = off(A, B, W)
    front = poly([(0, 0), (A, 0), (A, T), (T, T), (T, B), (0, B)]) + [hd(0, A, -o, f"{A:g}"), vd(0, B, -o, f"{B:g}"), hd(0, T, B + o / 2, f"{T:g}")]
    top = rect(0, 0, A, W) + [line(T, 0, T, W), vd(0, W, -o, f"{W:g}")]
    right = rect(0, 0, W, B) + [line(0, T, W, T), hd(0, W, -o, f"{W:g}")]
    return part("angle_profile", code, (A, W, B), T * (A + B - T) * W, front, top, right, [f"thickness {T}", f"length {W}"])


def f_channel_profile(r):
    B, H, T, W = cx(r, 30, 100, 10), cx(r, 30, 100, 10), r.choice([3, 4, 5, 6]), cx(r, 30, 150, 10)
    code = (f"import cadquery as cq\n\nB, H, T, W = {B}, {H}, {T}, {W}\n"
            "pts = [(0, 0), (B, 0), (B, H), (B - T, H), (B - T, T), (T, T), (T, H), (0, H)]\n"
            "result = cq.Workplane(\"XZ\").polyline(pts).close().extrude(W)\n")
    o = off(B, H, W)
    front = poly([(0, 0), (B, 0), (B, H), (B - T, H), (B - T, T), (T, T), (T, H), (0, H)]) + [hd(0, B, -o, f"{B:g}"), vd(0, H, -o, f"{H:g}")]
    top = rect(0, 0, B, W) + [line(T, 0, T, W), line(B - T, 0, B - T, W), vd(0, W, -o, f"{W:g}")]
    right = rect(0, 0, W, H) + [line(0, T, W, T, "h"), hd(0, W, -o, f"{W:g}")]
    return part("channel_profile", code, (B, W, H), T * (B + 2 * (H - T)) * W, front, top, right, [f"thickness {T}", f"length {W}"])


def f_tee_profile(r):
    B, H, tf, tw, W = cx(r, 40, 100, 20), cx(r, 40, 100, 10), r.choice([4, 5, 6, 8]), r.choice([4, 6, 8]), cx(r, 30, 150, 10)
    xw = (B - tw) / 2
    code = (f"import cadquery as cq\n\nB, H, TF, TW, W = {B}, {H}, {tf}, {tw}, {W}\nXW = (B - TW) / 2\n"
            "pts = [(XW, 0), (XW + TW, 0), (XW + TW, H - TF), (B, H - TF), (B, H), (0, H), (0, H - TF), (XW, H - TF)]\n"
            "result = cq.Workplane(\"XZ\").polyline(pts).close().extrude(W)\n")
    o = off(B, H, W)
    front = poly([(xw, 0), (xw + tw, 0), (xw + tw, H - tf), (B, H - tf), (B, H), (0, H), (0, H - tf), (xw, H - tf)]) + [hd(0, B, -o, f"{B:g}"), vd(0, H, -o, f"{H:g}"), hd(xw, xw + tw, -o * 2, f"{tw:g}")]
    top = rect(0, 0, B, W) + [line(xw, 0, xw, W, "h"), line(xw + tw, 0, xw + tw, W, "h"), vd(0, W, -o, f"{W:g}")]
    right = rect(0, 0, W, H) + [line(0, H - tf, W, H - tf), hd(0, W, -o, f"{W:g}")]
    return part("tee_profile", code, (B, W, H), (B * tf + tw * (H - tf)) * W, front, top, right, [f"flange thickness {tf}", f"web thickness {tw}"])


def f_slot_plate(r):
    L, W, T = cx(r, 80, 200, 10), cx(r, 40, 120, 10), r.choice([4, 5, 6, 8, 10])
    sw = r.choice([6, 8, 10, 12]); sl = r.choice([k for k in range(30, L - 30, 10) if k > sw + 10])
    code = (f"import cadquery as cq\n\nL, W, T, SL, SW = {L}, {W}, {T}, {sl}, {sw}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, T, centered=(True, True, False))\n    .faces(\">Z\").workplane().slot2D(SL, SW).cutThruAll()\n)\n")
    a, b, c = std_dims(L, W, T); cxm, cym = L / 2, W / 2; rr = sw / 2
    slot = [line(cxm - sl / 2 + rr, cym - rr, cxm + sl / 2 - rr, cym - rr), line(cxm - sl / 2 + rr, cym + rr, cxm + sl / 2 - rr, cym + rr),
            arc(cxm + sl / 2 - rr, cym, rr, -90, 90), arc(cxm - sl / 2 + rr, cym, rr, 90, 270), clh(cxm - sl / 2 - 5, cxm + sl / 2 + 5, cym)]
    front = rect(0, 0, L, T) + a + [line(cxm - sl / 2, 0, cxm - sl / 2, T, "h"), line(cxm + sl / 2, 0, cxm + sl / 2, T, "h")]
    right = rect(0, 0, W, T) + c + [line(cym - rr, 0, cym - rr, T, "h"), line(cym + rr, 0, cym + rr, T, "h")]
    return part("slot_plate", code, (L, W, T), L * W * T - T * (sw * (sl - sw) + PI * sw * sw / 4), front, rect(0, 0, L, W) + b + slot, right,
                [f"slot {sl} x {sw} THRU, centred (end to end {sl})", f"thickness {T}"])


def f_csk_plate(r):
    L, W = cx(r, 60, 160, 10), cx(r, 40, 120, 10)
    d = r.choice([5, 6, 8, 10]); dc = d * 2; cd = (dc - d) / 2
    T = int(cd) + r.choice([4, 6, 8])
    code = (f"import cadquery as cq\n\nL, W, T, D, DC = {L}, {W}, {T}, {d}, {dc}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, T, centered=(True, True, False))\n    .faces(\">Z\").workplane().cskHole(D, DC, 90)\n)\n")
    a, b, c = std_dims(L, W, T)
    def hid(w, m): return [line(m - d / 2, 0, m - d / 2, T - cd, "h"), line(m + d / 2, 0, m + d / 2, T - cd, "h"),
                           line(m - d / 2, T - cd, m - dc / 2, T, "h"), line(m + d / 2, T - cd, m + dc / 2, T, "h")]
    top = rect(0, 0, L, W) + b + [circ(L / 2, W / 2, d / 2), circ(L / 2, W / 2, dc / 2), clh(L / 2 - dc, L / 2 + dc, W / 2), clv(L / 2, W / 2 - dc, W / 2 + dc)]
    return part("csk_plate", code, (L, W, T), None, rect(0, 0, L, T) + a + hid(L, L / 2), top, rect(0, 0, W, T) + c + hid(W, W / 2),
                [f"1x dia {d} THRU, countersink dia {dc} x 90 deg", f"thickness {T}"])


def f_flange(r):
    OD, T = cx(r, 60, 180, 10), r.choice([6, 8, 10, 12, 15])
    ID = r.choice(list(range(10, OD // 2, 5)))
    n, bd = r.choice([3, 4, 6, 8]), r.choice([5, 6, 8, 10])
    PCD = r.choice([p for p in range(ID + 20, OD - 10, 5)] or [OD - 15])
    code = (f"import cadquery as cq\n\nOD, ID, T, PCD, N, BD = {OD}, {ID}, {T}, {PCD}, {n}, {bd}\n"
            "result = (\n    cq.Workplane(\"XY\").circle(OD / 2).extrude(T)\n    .faces(\">Z\").workplane().hole(ID)\n"
            "    .faces(\">Z\").workplane().polarArray(PCD / 2, 0, 360, N).hole(BD)\n)\n")
    c0 = OD / 2; o = off(OD, T)
    angs = [2 * PI * i / n for i in range(n)]
    front = rect(0, 0, OD, T) + [line(c0 - ID / 2, 0, c0 - ID / 2, T, "h"), line(c0 + ID / 2, 0, c0 + ID / 2, T, "h"), hd(0, OD, -o, f"dia {OD:g}"), vd(0, T, -o, f"{T:g}")]
    right = rect(0, 0, OD, T) + [line(c0 - ID / 2, 0, c0 - ID / 2, T, "h"), line(c0 + ID / 2, 0, c0 + ID / 2, T, "h")]
    for a in angs:
        for s in (-1, 1):
            front.append(line(c0 + PCD / 2 * math.cos(a) + s * bd / 2, 0, c0 + PCD / 2 * math.cos(a) + s * bd / 2, T, "h"))
            right.append(line(c0 + PCD / 2 * math.sin(a) + s * bd / 2, 0, c0 + PCD / 2 * math.sin(a) + s * bd / 2, T, "h"))
    top = [circ(c0, c0, OD / 2), circ(c0, c0, ID / 2), circ(c0, c0, PCD / 2, "c"), clh(-o / 2, OD + o / 2, c0), clv(c0, -o / 2, OD + o / 2)]
    top += [circ(c0 + PCD / 2 * math.cos(a), c0 + PCD / 2 * math.sin(a), bd / 2) for a in angs]
    return part("flange", code, (OD, OD, T), PI / 4 * (OD ** 2 - ID ** 2) * T - n * PI / 4 * bd * bd * T, front, top, right,
                [f"bore dia {ID}", f"thickness {T}", f"{n}x dia {bd} THRU on PCD {PCD}, first hole on +X axis"])


def f_stepped_shaft(r):
    d1 = cx(r, 20, 60, 5); d2 = r.choice(list(range(8, d1, 2))); l1, l2 = cx(r, 20, 80, 10), cx(r, 20, 100, 10)
    code = (f"import cadquery as cq\n\nD1, L1, D2, L2 = {d1}, {l1}, {d2}, {l2}\n"
            "result = (\n    cq.Workplane(\"XY\").circle(D1 / 2).extrude(L1)\n    .faces(\">Z\").workplane().circle(D2 / 2).extrude(L2)\n)\n")
    m = d1 / 2; o = off(d1, l1 + l2); H = l1 + l2
    prof = poly([(0, 0), (d1, 0), (d1, l1), (m + d2 / 2, l1), (m + d2 / 2, H), (m - d2 / 2, H), (m - d2 / 2, l1), (0, l1)]) + [clv(m, -o / 2, H + o / 2)]
    front = prof + [hd(0, d1, -o, f"dia {d1:g}"), vd(0, l1, -o, f"{l1:g}"), vd(l1, H, d1 + o, f"{l2:g}"), hd(m - d2 / 2, m + d2 / 2, H + o / 2, f"dia {d2:g}")]
    top = [circ(m, m, d1 / 2), circ(m, m, d2 / 2), clh(-o / 2, d1 + o / 2, m), clv(m, -o / 2, d1 + o / 2)]
    return part("stepped_shaft", code, (d1, d1, H), PI / 4 * (d1 * d1 * l1 + d2 * d2 * l2), front, top, list(prof))


def f_pocket_block(r):
    L, W, H = cx(r, 50, 160, 10), cx(r, 40, 120, 10), cx(r, 20, 60, 5)
    pl, pw = cx(r, 10, L - 20, 10), cx(r, 10, W - 20, 10); pd = r.choice([k for k in range(3, H, 2)])
    code = (f"import cadquery as cq\n\nL, W, H = {L}, {W}, {H}\nPL, PW, PD = {pl}, {pw}, {pd}\n"
            "result = (\n    cq.Workplane(\"XY\").box(L, W, H, centered=(True, True, False))\n    .faces(\">Z\").workplane().rect(PL, PW).cutBlind(-PD)\n)\n")
    a, b, c = std_dims(L, W, H)
    def hid(w, p): return [line(w / 2 - p / 2, H - pd, w / 2 - p / 2, H, "h"), line(w / 2 + p / 2, H - pd, w / 2 + p / 2, H, "h"), line(w / 2 - p / 2, H - pd, w / 2 + p / 2, H - pd, "h")]
    top = rect(0, 0, L, W) + rect((L - pl) / 2, (W - pw) / 2, (L + pl) / 2, (W + pw) / 2) + b
    return part("pocket_block", code, (L, W, H), L * W * H - pl * pw * pd, rect(0, 0, L, H) + a + hid(L, pl), top, rect(0, 0, W, H) + c + hid(W, pw),
                [f"pocket {pl} x {pw}, depth {pd}, centred"])


FAMILIES = [f_block, f_cylinder, f_tube, f_plate_center_hole, f_plate_corner_holes, f_blind_hole_block, f_chamfer_block, f_rounded_block,
            f_stepped_block, f_angle_profile, f_channel_profile, f_tee_profile, f_slot_plate, f_csk_plate, f_flange, f_stepped_shaft, f_pocket_block]


# ============================================================ RULES + SPECS
# Rule-based accuracy: (1) the model first reads a SPEC (named dimensions), (2) the spec is checked with the rules below,
# (3) the model writes code from the checked spec plus the relevant rules, (4) the solid is checked against the spec
# (valid, one solid, bounding box, volume) and errors are sent back to the model for a retry.
CAD_RULES = [
    {"id": "CR-D1", "section": "Drawing reading", "text": "Third-angle projection: the TOP view is drawn above the FRONT view and the RIGHT view to the right of the front view. FRONT shows X (horizontal) and Z (vertical), TOP shows X and Y, RIGHT shows Y and Z."},
    {"id": "CR-D2", "section": "Drawing reading", "text": "Line types: thick continuous = visible edges; dashed = hidden edges; dash-dot = centre lines and axes of holes and cylinders; thin continuous with arrows = dimension lines."},
    {"id": "CR-D3", "section": "Drawing reading", "text": "A circle in one view together with two parallel dashed lines in the other views is a hole (or cylinder) whose axis is perpendicular to the view that shows the circle. The dashed lines are its silhouette."},
    {"id": "CR-D4", "section": "Drawing reading", "text": "Hole depth: dashed lines running the full thickness mean a THRU hole. If they stop short of the opposite face the hole is blind, and its depth is measured from the face where it starts to the end of the dashed lines."},
    {"id": "CR-D5", "section": "Drawing reading", "text": "A note 'Nx dia D' means N identical holes of diameter D. THRU means through all material."},
    {"id": "CR-D6", "section": "Drawing reading", "text": "'dia' is the full diameter and 'R' is a radius. In CadQuery hole(D) takes a diameter, while circle(r) and fillet(r) take a radius."},
    {"id": "CR-D7", "section": "Drawing reading", "text": "Dimension text always wins over the drawn size. Never scale dimensions from the picture. All linear dimensions are millimetres unless the drawing states otherwise."},
    {"id": "CR-D8", "section": "Drawing reading", "text": "Countersink callout: hole diameter, countersink diameter at the surface and included angle (normally 90 deg). Use cskHole(D, DC, angle)."},
    {"id": "CR-D9", "section": "Drawing reading", "text": "A note 'chamfer CxC' is a 45 degree chamfer with both legs equal to C. A note 'R' on a corner or edge is a fillet radius."},
    {"id": "CR-D10", "section": "Drawing reading", "text": "A slot callout 'slot L x W' gives overall end-to-end length L and width W. CadQuery slot2D(length, diameter) takes the end-to-end length."},
    {"id": "CR-D11", "section": "Drawing reading", "text": "A centre line through the middle of a view means the feature is centred on the part. A position given from an edge overrides the centre line."},
    {"id": "CR-D12", "section": "Drawing reading", "text": "Do not add features that are not on the drawing and do not leave out features that appear in any of the three views. If a dimension cannot be read, name the unreadable dimension instead of guessing."},
    {"id": "CR-D13", "section": "Drawing reading", "text": "Cross-check between views: a hole circle in the TOP view must match the dashed hidden lines in the FRONT and RIGHT views in size and position."},
    {"id": "CR-D14", "section": "Drawing reading", "text": "A note in the notes block (thickness, hole callouts, corner radii) applies to the whole part unless it names a location."},
    {"id": "CR-M1", "section": "CadQuery modelling", "text": "Start every script with `import cadquery as cq`, put all dimensions in named variables at the top, and assign the final solid to `result`."},
    {"id": "CR-M2", "section": "CadQuery modelling", "text": "Build blocks and plates with box(L, W, H, centered=(True, True, False)) so the base sits on z=0 and the part is centred in X and Y."},
    {"id": "CR-M3", "section": "CadQuery modelling", "text": "Holes and pockets on the top face: faces(\">Z\").workplane() then hole(), cutBlind(-depth) or cutThruAll(). On a centred box this workplane origin is the centre of the top face."},
    {"id": "CR-M4", "section": "CadQuery modelling", "text": "Several holes at once: rect(w, h, forConstruction=True).vertices().hole(D) for corner patterns; polarArray(radius, 0, 360, N).hole(D) for a bolt circle (first hole on +X)."},
    {"id": "CR-M5", "section": "CadQuery modelling", "text": "Fillets on vertical edges: edges(\"|Z\").fillet(R). Chamfers on top edges: faces(\">Z\").edges().chamfer(C). Apply fillets and chamfers to the plain solid before cutting holes unless the drawing says otherwise."},
    {"id": "CR-M6", "section": "CadQuery modelling", "text": "Profile parts (angle, channel, tee): draw the cross-section with polyline(points).close() on the \"XZ\" workplane and extrude(length). The XZ workplane points to -Y, so the extrusion runs to -Y; the size is unchanged."},
    {"id": "CR-M7", "section": "CadQuery modelling", "text": "Stepped round parts: stack circles with extrude() using faces(\">Z\").workplane(); all axes run along Z."},
    {"id": "CR-M8", "section": "CadQuery modelling", "text": "Join stacked bodies with union(). Place the second body with workplane(offset=height of the first body)."},
    {"id": "CR-M9", "section": "CadQuery modelling", "text": "The result must be one valid solid whose bounding box equals the overall dimensions on the drawing and whose volume is smaller than the bounding-box volume (if it has cut features)."},
    {"id": "CR-M10", "section": "CadQuery modelling", "text": "Do not do geometry arithmetic by hand when CadQuery can do it: use the dimensions as parameters and let the kernel compute positions and volumes."},
]

PARAMS = {
    "block": ["L", "W", "H"], "cylinder": ["D", "H"], "tube": ["OD", "ID", "H"], "plate_center_hole": ["L", "W", "T", "D"],
    "plate_corner_holes": ["L", "W", "T", "M", "D"], "blind_hole_block": ["L", "W", "H", "D", "DEPTH"], "chamfer_block": ["L", "W", "H", "C"],
    "rounded_block": ["L", "W", "H", "R"], "stepped_block": ["L1", "W1", "H1", "L2", "W2", "H2"], "angle_profile": ["A", "B", "T", "W"],
    "channel_profile": ["B", "H", "T", "W"], "tee_profile": ["B", "H", "TF", "TW", "W"], "slot_plate": ["L", "W", "T", "SL", "SW"],
    "csk_plate": ["L", "W", "T", "D", "DC"], "flange": ["OD", "ID", "T", "PCD", "N", "BD"], "stepped_shaft": ["D1", "L1", "D2", "L2"],
    "pocket_block": ["L", "W", "H", "PL", "PW", "PD"],
}
BBOX = {
    "block": lambda p: (p["L"], p["W"], p["H"]), "cylinder": lambda p: (p["D"], p["D"], p["H"]), "tube": lambda p: (p["OD"], p["OD"], p["H"]),
    "plate_center_hole": lambda p: (p["L"], p["W"], p["T"]), "plate_corner_holes": lambda p: (p["L"], p["W"], p["T"]),
    "blind_hole_block": lambda p: (p["L"], p["W"], p["H"]), "chamfer_block": lambda p: (p["L"], p["W"], p["H"]),
    "rounded_block": lambda p: (p["L"], p["W"], p["H"]), "stepped_block": lambda p: (p["L1"], p["W1"], p["H1"] + p["H2"]),
    "angle_profile": lambda p: (p["A"], p["W"], p["B"]), "channel_profile": lambda p: (p["B"], p["W"], p["H"]),
    "tee_profile": lambda p: (p["B"], p["W"], p["H"]), "slot_plate": lambda p: (p["L"], p["W"], p["T"]),
    "csk_plate": lambda p: (p["L"], p["W"], p["T"]), "flange": lambda p: (p["OD"], p["OD"], p["T"]),
    "stepped_shaft": lambda p: (p["D1"], p["D1"], p["L1"] + p["L2"]), "pocket_block": lambda p: (p["L"], p["W"], p["H"]),
}
VOL = {
    "block": lambda p: p["L"] * p["W"] * p["H"], "cylinder": lambda p: PI / 4 * p["D"] ** 2 * p["H"],
    "tube": lambda p: PI / 4 * (p["OD"] ** 2 - p["ID"] ** 2) * p["H"],
    "plate_center_hole": lambda p: p["L"] * p["W"] * p["T"] - PI / 4 * p["D"] ** 2 * p["T"],
    "plate_corner_holes": lambda p: p["L"] * p["W"] * p["T"] - PI * p["D"] ** 2 * p["T"],
    "blind_hole_block": lambda p: p["L"] * p["W"] * p["H"] - PI / 4 * p["D"] ** 2 * p["DEPTH"], "chamfer_block": None,
    "rounded_block": lambda p: (p["L"] * p["W"] - (4 - PI) * p["R"] ** 2) * p["H"],
    "stepped_block": lambda p: p["L1"] * p["W1"] * p["H1"] + p["L2"] * p["W2"] * p["H2"],
    "angle_profile": lambda p: p["T"] * (p["A"] + p["B"] - p["T"]) * p["W"],
    "channel_profile": lambda p: p["T"] * (p["B"] + 2 * (p["H"] - p["T"])) * p["W"],
    "tee_profile": lambda p: (p["B"] * p["TF"] + p["TW"] * (p["H"] - p["TF"])) * p["W"],
    "slot_plate": lambda p: p["L"] * p["W"] * p["T"] - p["T"] * (p["SW"] * (p["SL"] - p["SW"]) + PI * p["SW"] ** 2 / 4), "csk_plate": None,
    "flange": lambda p: PI / 4 * (p["OD"] ** 2 - p["ID"] ** 2) * p["T"] - p["N"] * PI / 4 * p["BD"] ** 2 * p["T"],
    "stepped_shaft": lambda p: PI / 4 * (p["D1"] ** 2 * p["L1"] + p["D2"] ** 2 * p["L2"]),
    "pocket_block": lambda p: p["L"] * p["W"] * p["H"] - p["PL"] * p["PW"] * p["PD"],
}
SPEC_RULES = {   # family -> [(text, predicate on params)]
    "plate_center_hole": [("hole diameter D must be smaller than the plate width", lambda p: p["D"] < min(p["L"], p["W"]))],
    "plate_corner_holes": [("edge distance M must be larger than D/2 so the hole stays inside the plate", lambda p: p["M"] > p["D"] / 2),
                           ("holes must not overlap: L - 2M and W - 2M must be larger than D", lambda p: p["L"] - 2 * p["M"] > p["D"] and p["W"] - 2 * p["M"] > p["D"])],
    "blind_hole_block": [("blind depth must be smaller than the block height H", lambda p: p["DEPTH"] < p["H"]),
                         ("hole diameter must be smaller than the block width", lambda p: p["D"] < min(p["L"], p["W"]))],
    "tube": [("bore ID must be smaller than OD", lambda p: p["ID"] < p["OD"])],
    "chamfer_block": [("chamfer C must be smaller than half of the smallest block dimension", lambda p: p["C"] < min(p["L"], p["W"], p["H"]) / 2)],
    "rounded_block": [("corner radius R must not exceed half of the smaller plan dimension", lambda p: p["R"] <= min(p["L"], p["W"]) / 2)],
    "stepped_block": [("the upper block must sit inside the lower block (L2 < L1 and W2 < W1)", lambda p: p["L2"] < p["L1"] and p["W2"] < p["W1"])],
    "angle_profile": [("thickness T must be smaller than both legs A and B", lambda p: p["T"] < min(p["A"], p["B"]))],
    "channel_profile": [("two flanges must fit: 2T < B and T < H", lambda p: 2 * p["T"] < p["B"] and p["T"] < p["H"])],
    "tee_profile": [("web thickness TW must be smaller than flange width B and flange thickness TF smaller than height H", lambda p: p["TW"] < p["B"] and p["TF"] < p["H"])],
    "slot_plate": [("slot width must be smaller than the plate width", lambda p: p["SW"] < p["W"]),
                   ("slot length must be smaller than the plate length and larger than its width", lambda p: p["SW"] < p["SL"] < p["L"])],
    "csk_plate": [("countersink diameter DC must be larger than the hole diameter D", lambda p: p["DC"] > p["D"]),
                  ("countersink depth (DC - D)/2 must be smaller than the thickness T", lambda p: (p["DC"] - p["D"]) / 2 < p["T"])],
    "flange": [("bore ID must be smaller than the outer diameter OD", lambda p: p["ID"] < p["OD"]),
               ("bore must be smaller than the bolt circle: PCD - BD must be larger than ID", lambda p: p["PCD"] - p["BD"] > p["ID"]),
               ("bolt holes must stay inside the flange: PCD + BD must be smaller than OD", lambda p: p["PCD"] + p["BD"] < p["OD"])],
    "stepped_shaft": [("the second step must be thinner: D2 < D1", lambda p: p["D2"] < p["D1"])],
    "pocket_block": [("pocket must be smaller than the block (PL < L, PW < W, PD < H)", lambda p: p["PL"] < p["L"] and p["PW"] < p["W"] and p["PD"] < p["H"])],
}
FAMILY_HINT = {   # extra words so the rule search finds the right CadQuery recipe for each family
    "plate_corner_holes": "holes pattern rect forConstruction vertices hole faces workplane", "plate_center_hole": "hole faces workplane top face",
    "blind_hole_block": "blind hole depth faces workplane", "flange": "bolt circle polarArray hole PCD", "slot_plate": "slot2D end to end cutThruAll",
    "csk_plate": "countersink cskHole angle", "chamfer_block": "chamfer top edges", "rounded_block": "fillet vertical edges",
    "angle_profile": "profile polyline XZ workplane extrude", "channel_profile": "profile polyline XZ workplane extrude",
    "tee_profile": "profile polyline XZ workplane extrude", "stepped_block": "union stacked workplane offset", "stepped_shaft": "stepped round extrude circles",
    "pocket_block": "pocket cutBlind faces workplane", "tube": "circle bore extrude", "cylinder": "circle extrude", "block": "box centered base z=0",
}
SPEC_PROMPT = "Read this 3-view drawing and return JSON: the part family, its named dimensions (params) and the notes. Only what is on the drawing."
CODE_FROM_SPEC = "Drawing plus dimensions already read as JSON: {spec}\nWrite the CadQuery script for the part. Use exactly these parameter names. Final solid: `result`."
RULE_Q = ["What does modelling/drawing rule {id} say?", "Explain rule {id} for reading 2D drawings and building 3D models.", "Rule {id}: what is the requirement?"]
SPEC_REVIEW_Q = "Check these dimensions against the modelling rules (positive values, features fit inside the part, bore/hole/slot limits). List the violations.\n"


def parse_params(code):
    out = {}
    for line in code.splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*(?:, [A-Z][A-Z0-9_]*)*) = (-?[\d.]+(?:, -?[\d.]+)*)$", line)
        if m:
            names, vals = m.group(1).split(", "), [float(x) if "." in x else int(x) for x in m.group(2).split(", ")]
            if len(names) == len(vals):
                out.update(zip(names, vals))
    return out


def check_spec(spec):
    """Rule check on a spec {"family", "params"}. Returns [(rule_id, message)]."""
    fam, p = spec.get("family"), spec.get("params") or {}
    if fam not in PARAMS:
        return [("CR-G0", f"unknown part family '{fam}'")]
    out = []
    miss = [k for k in PARAMS[fam] if k not in p]
    if miss:
        return [("CR-G2", f"missing dimension(s): {', '.join(miss)}")]
    bad = [k for k in PARAMS[fam] if not isinstance(p[k], (int, float)) or not p[k] > 0]
    if bad:
        out.append(("CR-G1", f"dimension(s) must be positive numbers: {', '.join(bad)}"))
        return out
    for i, (txt, fn) in enumerate(SPEC_RULES.get(fam, []), 1):
        try:
            if not fn(p):
                out.append((f"CR-{fam}-{i}", txt))
        except Exception:
            out.append((f"CR-{fam}-{i}", txt))
    return out


def run_checked(code, spec, tol=0.05, tol_vol=0.005):
    """Runs the model's script and checks it against the spec. Returns {"ok": bool, "errors": [...]}."""
    code = code.replace("```python", "").replace("```", "")
    fam, p = spec["family"], spec["params"]
    ns, errs = {}, []
    try:
        exec(code, ns)
    except Exception as e:
        return {"ok": False, "errors": [f"script error: {e}"]}
    res = ns.get("result")
    if res is None:
        return {"ok": False, "errors": ["the script does not define `result`"]}
    shape = res.val() if hasattr(res, "val") else res
    if not shape.isValid():
        errs.append("solid is not valid")
    try:
        n = len(res.solids().vals())
        if n != 1:
            errs.append(f"{n} separate solids, expected 1")
    except Exception:
        pass
    b = shape.BoundingBox()
    exp = BBOX[fam](p)
    got = (b.xlen, b.ylen, b.zlen)
    if any(abs(g - e) > tol for g, e in zip(got, exp)):
        errs.append(f"bounding box {tuple(round(x, 2) for x in got)} but the drawing needs {tuple(round(x, 2) for x in exp)}")
    if VOL[fam] is not None:
        ev = VOL[fam](p)
        if abs(shape.Volume() - ev) > tol_vol * ev:
            errs.append(f"volume {shape.Volume():.0f} but expected {ev:.0f}")
    return {"ok": not errs, "errors": errs}


def selftest(r, per=6):
    """Formulas used at run time must equal what the generators produce (no CadQuery needed)."""
    for fam in FAMILIES:
        for _ in range(per):
            p = fam(r)
            prm = parse_params(p["code"])
            name = p["name"]
            assert all(k in prm for k in PARAMS[name]), f"{name}: params {prm} do not cover {PARAMS[name]}"
            assert all(abs(a - b) < 1e-9 for a, b in zip(BBOX[name](prm), p["bbox"])), f"{name}: bbox formula mismatch"
            if p["vol"] is not None:
                assert abs(VOL[name](prm) - p["vol"]) < 1e-6 * p["vol"], f"{name}: volume formula mismatch"
            assert not check_spec({"family": name, "params": prm}), f"{name}: generator violates its own rules {check_spec({'family': name, 'params': prm})}"
    return True


def review_answer(issues):
    return "No violations: all dimensions are positive and every feature fits inside the part." if not issues else "\n".join(f"{c}: {m}" for c, m in issues)


# ---------------------------------------------------------------- rendering
def render_3view(p, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Arc
    L, W, H = p["bbox"]
    # views: front (X,Z)=(L,H) ; top (X,Y)=(L,W) ; right (Y,Z)=(W,H). bbox axes: x,y,z
    m = max(L, W, H); o = 0.14 * m; gap = 0.5 * m
    offs = {"front": (0, 0), "top": (0, H + gap), "right": (L + gap, 0)}
    fig, ax = plt.subplots(figsize=(7.2, 5.4), dpi=100)
    st = {"o": dict(color="black", lw=1.7), "h": dict(color="0.25", lw=1.0, ls=(0, (4, 3))), "c": dict(color="0.35", lw=0.8, ls=(0, (8, 2, 1.5, 2)))}
    for vn, shapes in (("front", p["front"]), ("top", p["top"]), ("right", p["right"])):
        ox, oy = offs[vn]
        for s in shapes:
            k = s[0]
            if k == "line":
                ax.plot([s[1] + ox, s[3] + ox], [s[2] + oy, s[4] + oy], **st[s[5]])
            elif k == "circle":
                ax.add_patch(plt.Circle((s[1] + ox, s[2] + oy), s[3], fill=False, **st[s[4]]))
            elif k == "arc":
                ax.add_patch(Arc((s[1] + ox, s[2] + oy), 2 * s[3], 2 * s[3], theta1=s[4], theta2=s[5], **st[s[6]]))
            elif k == "hdim":
                ax.annotate("", (s[1] + ox, s[3] + oy), (s[2] + ox, s[3] + oy), arrowprops=dict(arrowstyle="<->", lw=0.9, color="tab:blue"))
                ax.text((s[1] + s[2]) / 2 + ox, s[3] + oy - 0.15 * o, s[4], ha="center", va="top", fontsize=7, color="tab:blue")
            elif k == "vdim":
                ax.annotate("", (s[3] + ox, s[1] + oy), (s[3] + ox, s[2] + oy), arrowprops=dict(arrowstyle="<->", lw=0.9, color="tab:blue"))
                ax.text(s[3] + ox - 0.15 * o, (s[1] + s[2]) / 2 + oy, s[4], ha="right", va="center", fontsize=7, color="tab:blue", rotation=90)
    ax.text(L / 2, -2.3 * o, "FRONT", ha="center", fontsize=8, weight="bold")
    ax.text(L / 2, H + gap - 1.0 * o, "TOP", ha="center", fontsize=8, weight="bold")
    ax.text(L + gap + W / 2, -2.3 * o, "RIGHT", ha="center", fontsize=8, weight="bold")
    x0, x1, y0, y1 = -3.2 * o, L + gap + W + 1.5 * o, -3.2 * o, H + gap + W + 1.5 * o
    ax.set_xlim(x0, x1); ax.set_ylim(y0, y1); ax.set_aspect("equal", adjustable="box"); ax.axis("off")
    fx = (L + gap - x0) / (x1 - x0)
    for i, n in enumerate(p["notes"]):
        ax.text(fx, 0.97 - i * 0.05, n, transform=ax.transAxes, fontsize=7.5, va="top", ha="left")
    fig.tight_layout(pad=0.3); fig.savefig(path); plt.close(fig)


# --------------------------------------------------------------- validation
def validate(code, bbox, vol, tol_len=0.05, tol_vol=0.005):
    import cadquery as cq  # noqa
    ns = {}
    exec(code, ns)
    s = ns["result"].val()
    if not s.isValid() or s.Volume() <= 0:
        return False, "invalid solid"
    b = s.BoundingBox()
    if any(abs(g - e) > tol_len for g, e in zip((b.xlen, b.ylen, b.zlen), bbox)):
        return False, f"bbox {(round(b.xlen, 2), round(b.ylen, 2), round(b.zlen, 2))} != {bbox}"
    if vol is not None and abs(s.Volume() - vol) > tol_vol * vol:
        return False, f"volume {s.Volume():.1f} != {vol:.1f}"
    return True, ""


def make_basics_samples(n, r, out, scan_fn=None, scan_p=0.4, check=True):
    out = Path(out); (out / "images").mkdir(parents=True, exist_ok=True)
    selftest(random.Random(r.randint(0, 10 ** 9)))
    kept, seen, stats, fails = 0, set(), {}, {}
    extra = {"spec_read": 0, "spec_code": 0, "spec_review": 0, "cad_rule_lookup": 0}
    pool = []
    with open(out / "dataset.jsonl", "a") as f:
        def rec(kind, img, prompt, ans):
            content = ([{"type": "image"}] if img else []) + [{"type": "text", "text": prompt}]
            f.write(json.dumps({"image": img, "part": kind, "messages": [
                {"role": "user", "content": content},
                {"role": "assistant", "content": [{"type": "text", "text": ans}]}]}) + "\n")
        tries = 0
        while kept < n and tries < n * 30:
            tries += 1
            fam = FAMILIES[kept % len(FAMILIES)] if tries < n * 3 else r.choice(FAMILIES)   # round-robin so every family is covered
            p = fam(r)
            if p["code"] in seen:
                continue
            if check:
                try:
                    ok, why = validate(p["code"], p["bbox"], p["vol"])
                except Exception as e:
                    ok, why = False, f"exec error: {e}"
                if not ok:
                    fails[p["name"]] = fails.get(p["name"], 0) + 1
                    if fails[p["name"]] <= 2:
                        print(f"discarded {p['name']}: {why}")
                    continue
            seen.add(p["code"])
            img = f"images/b{kept:05d}.png"
            render_3view(p, out / img)
            if scan_fn:
                scan_fn(out / img, r, scan_p)
            prm = parse_params(p["code"])
            spec = {"family": p["name"], "params": prm, "notes": p["notes"]}
            pool.append(spec)
            rec("basic3d_" + p["name"], img, r.choice(PROMPTS), p["code"])                      # drawing -> code
            rec("spec_read", img, SPEC_PROMPT, json.dumps(spec)); extra["spec_read"] += 1       # drawing -> named dimensions
            if r.random() < 0.5:                                                                # drawing + spec -> code
                rec("spec_code", img, CODE_FROM_SPEC.format(spec=json.dumps(spec)), p["code"]); extra["spec_code"] += 1
            stats[p["name"]] = stats.get(p["name"], 0) + 1
            kept += 1
        # rule book Q&A (text only)
        rules = CAD_RULES * 2
        r.shuffle(rules)
        for e in rules[:max(0, min(len(rules), n))]:
            rec("cad_rule_lookup", None, r.choice(RULE_Q).format(id=e["id"]), f"{e['id']} ({e['section']}): {e['text']}"); extra["cad_rule_lookup"] += 1
        # spec rule review (text only): labels come from check_spec
        tries = made = 0
        while pool and made < max(1, n // 3) and tries < n * 30:
            tries += 1
            base = r.choice(pool)
            if r.random() < 0.7:                                  # make a real violation (retry until a rule actually fires)
                cands = [x for x in pool if x["family"] in SPEC_RULES]
                base = r.choice(cands) if cands else base
                for _ in range(25):
                    prm = dict(base["params"])
                    prm[r.choice(PARAMS[base["family"]])] = r.choice([1, 2, 5, 10, 30, 60, 120, 250, 300])
                    if r.random() < 0.08: prm[r.choice(PARAMS[base["family"]])] = 0
                    if check_spec({"family": base["family"], "params": prm}): break
            else:
                prm = dict(base["params"])
            fam = base["family"]
            sp = {"family": fam, "params": prm}
            rec("spec_review", None, SPEC_REVIEW_Q + json.dumps(sp), review_answer(check_spec(sp))); extra["spec_review"] += 1
            made += 1
    print(f"Basics 2D->3D: {kept} drawings {stats}" + (f"  discarded per family: {fails}" if fails else ""))
    print(f"  rule-based extras: {extra}")
    return stats


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--out", default="basics_data")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-validate", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        print("selftest ok" if selftest(random.Random(a.seed), 50) else "selftest FAILED"); raise SystemExit
    Path(a.out).mkdir(parents=True, exist_ok=True)
    open(Path(a.out) / "dataset.jsonl", "w").close()
    make_basics_samples(a.n, random.Random(a.seed), a.out, check=not a.no_validate)
