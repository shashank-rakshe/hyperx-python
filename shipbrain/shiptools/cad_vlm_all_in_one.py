"""
ALL-IN-ONE: CAD + FEA dataset generation, QLoRA training, GGUF export, test.
Tasks the model learns: (1) drawing -> CadQuery script, (2) beam drawing -> FEA script,
(3) FEA result -> design review + suggested change,
(4) scanned drawing -> JSON data extraction, (5) drawing -> engineering interpretation (+ shell/solid advice),
(6) shell-candidate check, (7) plate/flange -> CadQuery + midsurface extraction script,
(9) BASIC 2D->3D: 17 part families drawn as 3-view orthographic drawings (needs cad3d_basics.py) -> CadQuery,
    checked by bounding box AND volume,
(10) RULE LOOP at run time (solve_drawing): read spec -> check rules -> write code with relevant rules -> run + check solid -> retry,
(8) ship XML work (needs ship_xml_kit.py + ship_src/): rule-book Q&A, scanned sheet notes -> JSON,
    member-table review against the deckrules rules (closed outline, unique ids, no gap, inside outline).
Images are randomly "scanned" (noise, skew, blur, JPEG, shading) so the model sees realistic inputs.
(Colab T4: !pip install unsloth cadquery matplotlib, then !python cad_vlm_all_in_one.py)

Part 1 below = dataset generator: drawing image + instruction -> CadQuery script.

Each sample:
  1. random parametric part (5 templates)
  2. CadQuery script written from a template (always correct by construction)
  3. 2-view dimensioned drawing rendered with matplotlib
  4. script is EXECUTED and its bounding box checked against the drawing
     (samples that fail are discarded)

Usage:
  pip install cadquery matplotlib
  python make_dataset.py --n 1000 --out cad_data
  python make_dataset.py --n 20 --out test --no-validate   # without cadquery
"""
import argparse, inspect, json, os, random, sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Circle, Polygon

PROMPTS = [
    "Write CadQuery code for the part in this drawing. Assign the final solid to `result`.",
    "Read this engineering drawing and produce a CadQuery script that models it. The final solid must be named `result`.",
    "Model the part shown using CadQuery. Match every dimension. Final solid variable: `result`.",
]


# ---------------------------------------------------------------- templates
# Each returns: dict(name, code, bbox=(x,y,z), views=[...])
# view = dict(title, shapes) ; shape tuples:
#   ("rect", x, y, w, h) ("circle", cx, cy, r)
#   ("hdim", x0, x1, y, text) ("vdim", y0, y1, x, text) ("text", x, y, s)

def plate(r):
    L = r.choice(range(60, 241, 10)); W = r.choice(range(40, 161, 10))
    T = r.choice([3, 4, 5, 6, 8, 10, 12]); m = r.choice([8, 10, 12, 15])
    d = r.choice([4, 5, 6, 8, 10]); fr = r.choice([0, 0, 3, 5, 8])
    fil = f"    .edges(\"|Z\").fillet({fr})\n" if fr else ""
    code = (
        "import cadquery as cq\n\n"
        f"L, W, T = {L}, {W}, {T}\n"
        f"result = (\n    cq.Workplane(\"XY\").box(L, W, T)\n{fil}"
        "    .faces(\">Z\").workplane()\n"
        f"    .rect(L - {2*m}, W - {2*m}, forConstruction=True).vertices()\n"
        f"    .hole({d})\n)\n"
    )
    pts = [(m, m), (L - m, m), (m, W - m), (L - m, W - m)]
    top = [("rect", 0, 0, L, W)] + [("circle", x, y, d / 2) for x, y in pts]
    top += [("hdim", 0, L, -12, f"{L}"), ("vdim", 0, W, -12, f"{W}"),
            ("text", m, W / 2, f"4x dia {d}  ({m} from edges)")]
    if fr: top.append(("text", L / 2, W + 8, f"corner R{fr}"))
    side = [("rect", 0, 0, L, T), ("vdim", 0, T, L + 10, f"{T}"), ("text", L / 2, T + 6, f"thickness {T}")]
    return dict(name="plate", code=code, bbox=(L, W, T), thickness=T,
                info={"holes": {"count": 4, "diameter_mm": d, "edge_distance_mm": m}, "corner_fillet_radius_mm": fr},
                views=[dict(title="TOP", shapes=top), dict(title="FRONT", shapes=side)])


def flange(r):
    OD = r.choice(range(60, 181, 10)); T = r.choice([6, 8, 10, 12, 15])
    ID = r.choice([i for i in range(10, OD // 2, 5)])
    n = r.choice([3, 4, 6, 8]); bd = r.choice([5, 6, 8, 10])
    PCD = r.choice([p for p in range(ID + 20, OD - 10, 5)] or [OD - 15])
    code = (
        "import cadquery as cq\n\n"
        f"OD, ID, T, PCD, N, BD = {OD}, {ID}, {T}, {PCD}, {n}, {bd}\n"
        "result = (\n    cq.Workplane(\"XY\").circle(OD / 2).extrude(T)\n"
        "    .faces(\">Z\").workplane().hole(ID)\n"
        "    .faces(\">Z\").workplane().polarArray(PCD / 2, 0, 360, N).hole(BD)\n)\n"
    )
    import math
    c = OD / 2
    top = [("circle", c, c, OD / 2), ("circle", c, c, ID / 2)]
    for i in range(n):
        a = 2 * math.pi * i / n
        top.append(("circle", c + PCD / 2 * math.cos(a), c + PCD / 2 * math.sin(a), bd / 2))
    top += [("hdim", 0, OD, -12, f"dia {OD}"),
            ("text", c, c, f"bore dia {ID}"),
            ("text", c, OD + 8, f"{n}x dia {bd} on PCD {PCD}")]
    side = [("rect", 0, 0, OD, T), ("vdim", 0, T, OD + 10, f"{T}"), ("text", OD / 2, T + 6, f"thickness {T}")]
    return dict(name="flange", code=code, bbox=(OD, OD, T), thickness=T,
                info={"outer_diameter_mm": OD, "bore_diameter_mm": ID, "thickness_mm": T,
                      "bolt_holes": {"count": n, "diameter_mm": bd, "pcd_mm": PCD}},
                views=[dict(title="TOP", shapes=top), dict(title="FRONT", shapes=side)])


def l_bracket(r):
    L = r.choice(range(40, 121, 10)); W = r.choice(range(20, 81, 10))
    H = r.choice(range(30, 101, 10)); T = r.choice([3, 4, 5, 6, 8])
    d = r.choice([5, 6, 8])
    hx = T + (L - T) / 2
    code = (
        "import cadquery as cq\n\n"
        f"L, W, H, T, D = {L}, {W}, {H}, {T}, {d}\n"
        "base = cq.Workplane(\"XY\").box(L, W, T, centered=(False, True, False))\n"
        "leg = cq.Workplane(\"XY\").box(T, W, H, centered=(False, True, False))\n"
        "hole = cq.Workplane(\"XY\").center(T + (L - T) / 2, 0).circle(D / 2).extrude(T)\n"
        "result = base.union(leg).cut(hole)\n"
    )
    front = [("rect", 0, 0, L, T), ("rect", 0, 0, T, H),
             ("hdim", 0, L, -12, f"{L}"), ("vdim", 0, H, -12, f"{H}"),
             ("text", L / 2, H / 2, f"thickness {T}")]
    top = [("rect", 0, 0, L, W), ("circle", hx, W / 2, d / 2),
           ("vdim", 0, W, L + 10, f"{W}"), ("text", hx, W + 6, f"hole dia {d}")]
    return dict(name="l_bracket", code=code, bbox=(L, W, H), thickness=T,
                info={"base_length_mm": L, "width_mm": W, "height_mm": H, "thickness_mm": T,
                      "hole": {"count": 1, "diameter_mm": d}},
                views=[dict(title="FRONT", shapes=front), dict(title="TOP", shapes=top)])


def shaft(r):
    d1 = r.choice(range(20, 61, 5)); d2 = r.choice([d for d in range(8, d1, 2)])
    l1 = r.choice(range(20, 81, 10)); l2 = r.choice(range(20, 101, 10))
    code = (
        "import cadquery as cq\n\n"
        f"D1, L1, D2, L2 = {d1}, {l1}, {d2}, {l2}\n"
        "result = (\n    cq.Workplane(\"XY\").circle(D1 / 2).extrude(L1)\n"
        "    .faces(\">Z\").workplane().circle(D2 / 2).extrude(L2)\n)\n"
    )
    cx = d1 / 2
    front = [("rect", 0, 0, d1, l1), ("rect", cx - d2 / 2, l1, d2, l2),
             ("hdim", 0, d1, -10, f"dia {d1}"), ("hdim", cx - d2 / 2, cx + d2 / 2, l1 + l2 + 8, f"dia {d2}"),
             ("vdim", 0, l1, d1 + 10, f"{l1}"), ("vdim", l1, l1 + l2, d1 + 10, f"{l2}")]
    top = [("circle", cx, cx, d1 / 2), ("circle", cx, cx, d2 / 2)]
    return dict(name="shaft", code=code, bbox=(d1, d1, l1 + l2), thickness=None,
                info={"step1": {"diameter_mm": d1, "length_mm": l1}, "step2": {"diameter_mm": d2, "length_mm": l2}},
                views=[dict(title="FRONT", shapes=front), dict(title="TOP", shapes=top)])


def pocket_block(r):
    L = r.choice(range(40, 161, 10)); W = r.choice(range(30, 121, 10))
    H = r.choice(range(15, 61, 5))
    pl = r.choice(range(10, L - 10, 10)); pw = r.choice(range(10, W - 10, 10))
    pd = r.choice([p for p in range(3, H, 2)])
    code = (
        "import cadquery as cq\n\n"
        f"L, W, H = {L}, {W}, {H}\n"
        f"PL, PW, PD = {pl}, {pw}, {pd}\n"
        "result = (\n    cq.Workplane(\"XY\").box(L, W, H)\n"
        "    .faces(\">Z\").workplane()\n"
        "    .rect(PL, PW).cutBlind(-PD)\n)\n"
    )
    top = [("rect", 0, 0, L, W), ("rect", (L - pl) / 2, (W - pw) / 2, pl, pw),
           ("hdim", 0, L, -12, f"{L}"), ("vdim", 0, W, -12, f"{W}"),
           ("hdim", (L - pl) / 2, (L + pl) / 2, W / 2, f"{pl}"),
           ("text", L / 2, W / 2 - 22, f"pocket {pl}x{pw}, depth {pd}")]
    side = [("rect", 0, 0, L, H), ("vdim", 0, H, L + 10, f"{H}"), ("text", L / 2, H + 6, f"height {H}")]
    return dict(name="pocket_block", code=code, bbox=(L, W, H), thickness=None,
                info={"length_mm": L, "width_mm": W, "height_mm": H,
                      "pocket": {"length_mm": pl, "width_mm": pw, "depth_mm": pd}},
                views=[dict(title="TOP", shapes=top), dict(title="FRONT", shapes=side)])


TEMPLATES = [plate, flange, l_bracket, shaft, pocket_block]


# ---------------------------------------------------------------- rendering
def render(views, path, ratios=None, tb=None):
    fig, axes = plt.subplots(1, len(views), figsize=(7.2, 3.6), dpi=100,
                             gridspec_kw={"width_ratios": ratios} if ratios else None)
    axes = [axes] if len(views) == 1 else list(axes)
    for ax, v in zip(axes, views):
        for s in v["shapes"]:
            k = s[0]
            if k == "rect":
                ax.add_patch(Rectangle((s[1], s[2]), s[3], s[4], fill=False, lw=1.6))
            elif k == "circle":
                ax.add_patch(Circle((s[1], s[2]), s[3], fill=False, lw=1.4))
            elif k == "hdim":
                ax.annotate("", (s[1], s[3]), (s[2], s[3]), arrowprops=dict(arrowstyle="<->", lw=0.9, color="tab:blue"))
                ax.text((s[1] + s[2]) / 2, s[3] - 3, s[4], ha="center", va="top", fontsize=7, color="tab:blue")
            elif k == "vdim":
                ax.annotate("", (s[3], s[1]), (s[3], s[2]), arrowprops=dict(arrowstyle="<->", lw=0.9, color="tab:blue"))
                ax.text(s[3] - 2, (s[1] + s[2]) / 2, s[4], ha="right", va="center", fontsize=7, color="tab:blue", rotation=90)
            elif k == "text":
                ax.text(s[1], s[2], s[3], ha="center", fontsize=6.5, color="black")
            elif k == "arrow":
                ax.annotate("", (s[3], s[4]), (s[1], s[2]), arrowprops=dict(arrowstyle="->", lw=1.2, color="tab:red"))
                if len(s) > 5 and s[5]:
                    ax.text(s[1], s[2], s[5], ha="center", va="bottom", fontsize=7, color="tab:red")
            elif k == "poly":
                ax.add_patch(Polygon(s[1], fill=False, lw=1.4))
        ax.set_title(v["title"], fontsize=8)
        ax.autoscale_view(); ax.relim()
        ax.set_aspect("equal", adjustable="datalim")
        ax.margins(0.18); ax.axis("off")
    if tb:
        fig.tight_layout(rect=(0, 0.24, 1, 1))
        axt = fig.add_axes([0.40, 0.015, 0.58, 0.21]); axt.axis("off")
        axt.add_patch(Rectangle((0, 0), 1, 1, fill=False, lw=1.2, transform=axt.transAxes))
        for i, line in enumerate(tb):
            axt.text(0.03, 0.88 - i * 0.22, line, fontsize=7, va="top", transform=axt.transAxes)
    else:
        fig.tight_layout()
    fig.savefig(path); plt.close(fig)


# --------------------------------------------------------------- validation
def validate(code, bbox, tol=0.05):
    import cadquery as cq  # noqa
    ns = {}
    exec(code, ns)
    res = ns["result"]
    solid = res.val()
    if not solid.isValid() or solid.Volume() <= 0:
        return False
    b = solid.BoundingBox()
    got = (b.xlen, b.ylen, b.zlen)
    return all(abs(g - e) <= tol for g, e in zip(got, bbox))


# ---------------------------------------------------------------- FEA part
# beam_fea is the "solver" the model calls. The model never does numerics itself.
def beam_fea(L, b, h, E, support="cantilever", load="tip", magnitude=1.0, n=40):
    """Euler-Bernoulli beam FEM. Units: mm, N, MPa. Rectangular section b x h
    (h = height in load direction). support: 'cantilever' | 'simple'.
    load: 'tip' (cantilever end, N) | 'center' (simply supported midspan, N) | 'udl' (N/mm).
    Returns {'max_deflection': mm, 'max_stress': MPa}."""
    import numpy as np
    I = b * h ** 3 / 12.0
    EI = E * I
    le = L / n
    ndof = 2 * (n + 1)
    K = np.zeros((ndof, ndof)); F = np.zeros(ndof)
    k = EI / le ** 3 * np.array([[12, 6 * le, -12, 6 * le],
                                 [6 * le, 4 * le ** 2, -6 * le, 2 * le ** 2],
                                 [-12, -6 * le, 12, -6 * le],
                                 [6 * le, 2 * le ** 2, -6 * le, 4 * le ** 2]])
    fe = np.zeros(4)
    if load == "udl":
        fe = magnitude * le / 2 * np.array([1, le / 6, 1, -le / 6])
    for e in range(n):
        d = slice(2 * e, 2 * e + 4)
        K[d, d] += k
        F[d] += fe
    if load == "tip":
        F[2 * n] += magnitude
    elif load == "center":
        F[2 * (n // 2)] += magnitude
    fixed = [0, 1] if support == "cantilever" else [0, 2 * n]
    free = [i for i in range(ndof) if i not in fixed]
    u = np.zeros(ndof)
    u[free] = np.linalg.solve(K[np.ix_(free, free)], F[free])
    max_m = 0.0
    for e in range(n):
        d = slice(2 * e, 2 * e + 4)
        f = k @ u[d] - fe
        max_m = max(max_m, abs(f[1]), abs(f[3]))
    return {"max_deflection": float(np.max(np.abs(u[0::2]))),
            "max_stress": float(max_m * (h / 2) / I)}


def _add_kit_path():
    try:
        d = os.path.dirname(os.path.abspath(__file__))
    except NameError:
        d = os.getcwd()
    for q in (d, os.getcwd()):
        if q not in sys.path:
            sys.path.insert(0, q)


def write_fea_tools():
    """Writes fea_tools.py next to this script so generated scripts can import it."""
    with open("fea_tools.py", "w") as f:
        f.write('"""FEA helper used by model-written scripts."""\n\n' + inspect.getsource(beam_fea))
    if os.getcwd() not in sys.path:
        sys.path.insert(0, os.getcwd())


def analytic(L, b, h, E, support, load, mag):
    I = b * h ** 3 / 12.0
    if support == "cantilever" and load == "tip":
        return mag * L ** 3 / (3 * E * I), mag * L * (h / 2) / I
    if support == "cantilever" and load == "udl":
        return mag * L ** 4 / (8 * E * I), mag * L ** 2 / 2 * (h / 2) / I
    if support == "simple" and load == "center":
        return mag * L ** 3 / (48 * E * I), mag * L / 4 * (h / 2) / I
    return 5 * mag * L ** 4 / (384 * E * I), mag * L ** 2 / 8 * (h / 2) / I


MATERIALS = {"steel": (210000, 250), "aluminum": (70000, 240), "stainless steel": (193000, 215)}
CASES = [("cantilever", "tip"), ("cantilever", "udl"), ("simple", "center"), ("simple", "udl")]
FEA_PROMPTS = [
    "Write a Python FEA script for the beam in this drawing using fea_tools.beam_fea. Print max deflection, max stress and safety factor.",
    "Set up and run the FEA for this beam with fea_tools.beam_fea, then print deflection, stress and safety factor.",
]


def fea_case(r):
    support, load = r.choice(CASES)
    mat = r.choice(list(MATERIALS))
    E, Y = MATERIALS[mat]
    mag = r.choice([50, 100, 200, 300, 500, 1000, 2000]) if load != "udl" else r.choice([0.5, 1, 2, 3, 5])
    return dict(L=r.choice(range(200, 1001, 50)), b=r.choice([10, 15, 20, 25, 30, 40]),
                h=r.choice([6, 8, 10, 12, 15, 20, 25, 30]), mat=mat, E=E, Y=Y,
                support=support, load=load, mag=mag)


def fea_script(c):
    unit = "N/mm" if c["load"] == "udl" else "N"
    return (
        "from fea_tools import beam_fea\n\n"
        f"L, B, H = {c['L']}, {c['b']}, {c['h']}    # mm (H = section height in load direction)\n"
        f"E, YIELD = {c['E']}, {c['Y']}    # MPa ({c['mat']})\n"
        f"LOAD = {c['mag']}    # {unit}\n"
        f"res = beam_fea(L, B, H, E, support=\"{c['support']}\", load=\"{c['load']}\", magnitude=LOAD)\n"
        "sf = YIELD / res[\"max_stress\"]\n"
        "print(f\"max deflection {res['max_deflection']:.2f} mm, "
        "max stress {res['max_stress']:.1f} MPa, safety factor {sf:.2f}\")\n")


def fea_views(c):
    L, b, h, mag = c["L"], c["b"], c["h"], c["mag"]
    hd = max(h, L * 0.05)  # drawn height (true value in the label)
    s = L * 0.025
    sh = []
    sh.append(("rect", 0, 0, L, hd))
    if c["support"] == "cantilever":
        sh.append(("rect", -s, -hd * 0.5, s, hd * 2))
        sh.append(("text", -s, hd * 2.0, "FIXED"))
    else:
        sh.append(("poly", [(0, 0), (-s, -s * 1.5), (s, -s * 1.5)]))
        sh.append(("poly", [(L, 0), (L - s, -s * 1.5), (L + s, -s * 1.5)]))
    top = hd + L * 0.15
    if c["load"] == "tip":
        sh.append(("arrow", L, top, L, hd, f"P = {mag} N"))
    elif c["load"] == "center":
        sh.append(("arrow", L / 2, top, L / 2, hd, f"P = {mag} N"))
    else:
        for i in range(9):
            sh.append(("arrow", L * i / 8, top, L * i / 8, hd, ""))
        sh.append(("text", L / 2, top + L * 0.02, f"w = {mag} N/mm"))
    sh += [("hdim", 0, L, -L * 0.14, f"L = {L}"),
           ("text", L / 2, hd + L * 0.27, f"{c['mat']}, E = {c['E']} MPa")]
    sec = [("rect", 0, 0, b, h), ("hdim", 0, b, -h * 0.3, f"B={b}"), ("vdim", 0, h, -b * 0.3, f"H={h}"),
           ("text", b / 2, h * 1.15, "SECTION")]
    return [dict(title="BEAM (side view)", shapes=sh), dict(title="CROSS-SECTION", shapes=sec)]


def review_text(c, res):
    sf = c["Y"] / res["max_stress"]
    lim = c["L"] / 250.0
    d = res["max_deflection"]
    prompt = (f"Beam in the drawing. Simulation result: max deflection {d:.2f} mm, max stress "
              f"{res['max_stress']:.1f} MPa, safety factor {sf:.2f} (yield {c['Y']} MPa). "
              "Requirements: safety factor >= 2.0 and deflection <= L/250. Is the design OK? "
              "If not, give the smallest integer section height H (mm) that fixes it.")
    if sf >= 2.0 and d <= lim:
        return prompt, (f"OK: safety factor {sf:.2f} >= 2.0 and deflection {d:.2f} mm <= {lim:.2f} mm (L/250). "
                        "No change needed.")
    fails = []
    if sf < 2.0: fails.append(f"safety factor {sf:.2f} < 2.0")
    if d > lim: fails.append(f"deflection {d:.2f} mm > {lim:.2f} mm (L/250)")
    for hn in range(c["h"] + 1, 201):
        rn = beam_fea(c["L"], c["b"], hn, c["E"], c["support"], c["load"], c["mag"])
        if c["Y"] / rn["max_stress"] >= 2.0 and rn["max_deflection"] <= lim:
            return prompt, (f"Not OK: {' and '.join(fails)}. Increase H from {c['h']} to {hn} mm "
                            f"(new safety factor {c['Y'] / rn['max_stress']:.2f}, deflection "
                            f"{rn['max_deflection']:.2f} mm). Update: H = {hn}")
    return None, None


def make_fea_samples(n, r, out, scan_p=0.0):
    kept = reviews = tries = 0
    with open(out / "dataset.jsonl", "a") as f:
        while kept < n and tries < n * 20:
            tries += 1
            c = fea_case(r)
            code = fea_script(c)
            ns = {}
            try:
                exec(code, ns)
                res = ns["res"]
                da, sa = analytic(c["L"], c["b"], c["h"], c["E"], c["support"], c["load"], c["mag"])
                good = abs(res["max_deflection"] - da) <= 0.01 * da and abs(res["max_stress"] - sa) <= 0.01 * sa
            except Exception as e:
                print("fea exec error:", e); good = False
            sf = c["Y"] / res["max_stress"] if good else 0
            if not good or not (0.2 <= sf <= 30):
                continue
            img = f"images/f{kept:05d}.png"
            render(fea_views(c), out / img, ratios=[3, 1])
            maybe_scan(out / img, r, scan_p)
            f.write(json.dumps({"image": img, "part": "fea_script", "messages": [
                {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": r.choice(FEA_PROMPTS)}]},
                {"role": "assistant", "content": [{"type": "text", "text": code}]}]}) + "\n")
            if r.random() < 0.6:
                q, a = review_text(c, res)
                if q:
                    f.write(json.dumps({"image": img, "part": "fea_review", "messages": [
                        {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": q}]},
                        {"role": "assistant", "content": [{"type": "text", "text": a}]}]}) + "\n")
                    reviews += 1
            kept += 1
    print(f"FEA: {kept} script samples + {reviews} review samples")


# ------------------------------------------------------- scan augmentation
def scanify(path, r):
    """Make a clean drawing look like a scan: shrink/blur, skew, noise, paper tint, shading, JPEG."""
    import io
    import numpy as np
    from PIL import Image, ImageFilter
    rng = np.random.default_rng(r.randint(0, 2 ** 31))
    img = Image.open(path).convert("RGB")
    w, h = img.size
    f = r.uniform(0.45, 0.9)
    img = img.resize((int(w * f), int(h * f)), Image.BILINEAR).resize((w, h), Image.BILINEAR)
    img = img.rotate(r.uniform(-3, 3), resample=Image.BICUBIC, fillcolor=(255, 255, 255))
    if r.random() < 0.6:
        img = img.filter(ImageFilter.GaussianBlur(r.uniform(0.4, 1.2)))
    a = np.asarray(img).astype(np.float32)
    if r.random() < 0.5:                                   # grayscale scan
        a[:] = a.mean(axis=2, keepdims=True)
    tint = np.array([255, r.uniform(244, 255), r.uniform(225, 255)]) / 255.0
    a *= tint                                              # yellowish paper
    grad = np.linspace(0, 1, w)[None, :, None] if r.random() < 0.5 else np.linspace(0, 1, h)[:, None, None]
    a *= 1 - r.uniform(0.0, 0.25) * grad                   # shading from the scanner lid
    a = (a - 128) * r.uniform(0.7, 1.1) + 128 + r.uniform(-15, 10)   # contrast / brightness
    a += rng.normal(0, r.uniform(3, 14), a.shape)          # sensor noise
    img = Image.fromarray(np.clip(a, 0, 255).astype("uint8"))
    buf = io.BytesIO(); img.save(buf, "JPEG", quality=r.randint(35, 85)); buf.seek(0)
    Image.open(buf).convert("RGB").save(path)


def maybe_scan(path, r, p):
    if p > 0 and r.random() < p:
        scanify(path, r)


# ----------------------------------------------------- midsurface "tool"
# The model never computes geometry; it calls this tool. Handles constant-thickness
# prismatic plates (plates, flanges, sheet-metal-like parts). Complex parts need a
# commercial tool (Abaqus / SpaceClaim / HyperMesh) - the model can script those too.
def extract_midsurface(shape, max_ratio=0.1, tol=0.01):
    """Midsurface of a thin constant-thickness part. Returns dict(midsurface, thickness,
    area, normal_axis, span_to_thickness). Raises ValueError if not suitable."""
    import cadquery as cq
    solid = shape.val() if hasattr(shape, "val") else shape
    bb = solid.BoundingBox()
    dims = [bb.xlen, bb.ylen, bb.zlen]
    ax = dims.index(min(dims))
    axis = [cq.Vector(1, 0, 0), cq.Vector(0, 1, 0), cq.Vector(0, 0, 1)][ax]
    t, span = dims[ax], max(dims)
    if t > max_ratio * span + 1e-9:
        raise ValueError(f"not thin: thickness {t:.2f} mm vs span {span:.2f} mm")
    planar = [f for f in solid.Faces()
              if f.geomType() == "PLANE" and abs(f.normalAt().dot(axis)) > 0.999]
    if len(planar) < 2:
        raise ValueError("no pair of parallel planar faces found")
    coord = lambda f: f.Center().dot(axis)
    lo, hi = min(coord(f) for f in planar), max(coord(f) for f in planar)
    eps = 1e-4 * max(1.0, span)
    low = [f for f in planar if abs(coord(f) - lo) < eps]
    high = [f for f in planar if abs(coord(f) - hi) < eps]
    a_low, a_high = sum(f.Area() for f in low), sum(f.Area() for f in high)
    if abs(a_low - a_high) > tol * a_low or abs(solid.Volume() - a_low * t) > tol * solid.Volume():
        raise ValueError("thickness not constant: use a full midsurface tool")
    mids = [f.translate(axis.multiply(t / 2.0)) for f in low]
    mid = mids[0] if len(mids) == 1 else cq.Compound.makeCompound(mids)
    return {"midsurface": mid, "thickness": t, "area": a_low,
            "normal_axis": "XYZ"[ax], "span_to_thickness": span / t}


def export_midsurface(mid, path="midsurface.step"):
    import cadquery as cq
    cq.exporters.export(cq.Workplane("XY").newObject([mid["midsurface"]]), path)
    return path


def write_midsurface_tool():
    with open("midsurface_tool.py", "w") as f:
        f.write('"""Midsurface helper used by model-written scripts."""\n\n'
                + inspect.getsource(extract_midsurface) + "\n\n" + inspect.getsource(export_midsurface))
    if os.getcwd() not in sys.path:
        sys.path.insert(0, os.getcwd())


def validate_mid(code, t):
    ns = {}
    exec(code, ns)
    m = ns["mid"]
    vol = ns["result"].val().Volume()
    return abs(m["thickness"] - t) < 0.01 and abs(m["area"] - vol / t) < 0.01 * m["area"]


# ------------------------------------------- drawing data / interpretation tasks
TITLES = {"plate": "PLATE", "flange": "FLANGE", "l_bracket": "L-BRACKET",
          "shaft": "STEPPED SHAFT", "pocket_block": "POCKETED BLOCK"}
MATS = ["S235 steel", "AISI 304", "Aluminium 6061-T6", "Brass CW614N"]
TOLS = ["+/-0.1", "+/-0.2", "ISO 2768-m"]
EXTRACT_PROMPTS = [
    "Extract all data from this drawing as JSON: part type, material, general tolerance, overall size and features.",
    "Read this (possibly scanned) engineering drawing and return the title block and dimensions as JSON.",
]
INTERP_PROMPTS = [
    "Interpret this drawing for an engineer: summarize the part and say how to model it for FEA (shell or solid).",
    "Explain what this drawing shows and flag anything relevant for FEA modelling.",
]
SHELL_PROMPTS = [
    "Is this part a candidate for midsurface extraction and shell FEA? Answer with JSON.",
    "Check whether this part can be modelled with shell elements at its midsurface. Return JSON.",
]
MID_PROMPT = ("Write CadQuery code for this part, then extract its midsurface with "
              "midsurface_tool.extract_midsurface for a shell FEA model.")


def describe(name, i):
    if name == "plate":
        h = i["holes"]
        s = f"rectangular plate with 4 holes dia {h['diameter_mm']} mm, {h['edge_distance_mm']} mm from the edges"
        return s + (f", corners rounded R{i['corner_fillet_radius_mm']}" if i["corner_fillet_radius_mm"] else "")
    if name == "flange":
        b = i["bolt_holes"]
        return (f"round flange OD {i['outer_diameter_mm']} mm, bore dia {i['bore_diameter_mm']} mm, "
                f"thickness {i['thickness_mm']} mm, {b['count']} bolt holes dia {b['diameter_mm']} mm on PCD {b['pcd_mm']} mm")
    if name == "l_bracket":
        return (f"L-bracket: base {i['base_length_mm']} mm, height {i['height_mm']} mm, width {i['width_mm']} mm, "
                f"thickness {i['thickness_mm']} mm, one hole dia {i['hole']['diameter_mm']} mm in the base")
    if name == "shaft":
        a, b = i["step1"], i["step2"]
        return (f"stepped shaft: dia {a['diameter_mm']} x {a['length_mm']} mm, then dia {b['diameter_mm']} x {b['length_mm']} mm")
    p = i["pocket"]
    return (f"solid block {i['length_mm']} x {i['width_mm']} x {i['height_mm']} mm with a pocket "
            f"{p['length_mm']} x {p['width_mm']} mm, depth {p['depth_mm']} mm")


def shell_info(p):
    t = p["thickness"]
    span = max(p["bbox"])
    if t is None:
        why = ("solid of revolution, not a plate" if p["name"] == "shaft"
               else "thickness is not constant (pocketed block)")
        return False, {"shell_candidate": False, "reason": why,
                       "recommendation": "Use solid elements."}, None
    ratio = span / t
    if span >= 10 * t:
        return True, {"shell_candidate": True, "thickness_mm": t, "max_span_mm": span,
                      "span_to_thickness": round(ratio, 1),
                      "recommendation": f"Extract the midsurface and use shell elements with thickness {t} mm."}, ratio
    return False, {"shell_candidate": False, "thickness_mm": t, "span_to_thickness": round(ratio, 1),
                   "reason": "span/thickness below 10, part is too thick for a shell model",
                   "recommendation": "Use solid elements."}, ratio


def make_doc_samples(n, r, out, scan_p, validate_cad):
    kept = skipped = 0
    counts = {}
    with open(out / "dataset.jsonl", "a") as f:
        def rec(kind, img, prompt, answer):
            f.write(json.dumps({"image": img, "part": kind, "messages": [
                {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]},
                {"role": "assistant", "content": [{"type": "text", "text": answer}]}]}) + "\n")
            counts[kind] = counts.get(kind, 0) + 1
        while kept < n and skipped < n * 10:
            p = r.choice(TEMPLATES)(r)
            if validate_cad:
                try:
                    ok = validate(p["code"], p["bbox"])
                except Exception:
                    ok = False
                if not ok:
                    skipped += 1
                    continue
            name = p["name"]
            dwg, mat, tol = f"DWG-{r.randint(1000, 9999)}", r.choice(MATS), r.choice(TOLS)
            tb = [f"PART: {TITLES[name]}", f"DWG NO: {dwg}    SCALE: 1:1",
                  f"MATERIAL: {mat}", f"GENERAL TOL: {tol}    UNITS: mm"]
            img = f"images/d{kept:05d}.png"
            render(p["views"], out / img, tb=tb)
            maybe_scan(out / img, r, scan_p)
            x, y, z = p["bbox"]
            data = {"part_type": TITLES[name].lower(), "drawing_no": dwg, "material": mat,
                    "general_tolerance": tol, "units": "mm",
                    "overall_size_mm": {"x": x, "y": y, "z": z}, "features": p["info"]}
            rec("doc_extract", img, r.choice(EXTRACT_PROMPTS), json.dumps(data))
            cand, sj, ratio = shell_info(p)
            fea = (f"FEA: thin part (span/thickness {ratio:.1f}); extract the midsurface and use shell "
                   f"elements with thickness {p['thickness']} mm." if cand else
                   "FEA: not a thin constant-thickness plate; use solid elements.")
            text = (f"{TITLES[name].capitalize()} ({dwg}), {mat}, units mm. Overall size {x} x {y} x {z} mm. "
                    f"It is a {describe(name, p['info'])}. General tolerance {tol} mm. {fea}")
            rec("doc_interpret", img, r.choice(INTERP_PROMPTS), text)
            rec("shell_check", img, r.choice(SHELL_PROMPTS), json.dumps(sj))
            if cand and name in ("plate", "flange"):
                code = (p["code"] + "\nfrom midsurface_tool import extract_midsurface\n"
                        "mid = extract_midsurface(result)\n"
                        "print(f\"midsurface thickness {mid['thickness']:.2f} mm, area {mid['area']:.1f} mm2, "
                        "normal axis {mid['normal_axis']}\")\n")
                good = True
                if validate_cad:
                    try:
                        good = validate_mid(code, p["thickness"])
                    except Exception as e:
                        print("midsurface check failed:", e); good = False
                if good:
                    rec("midsurface_script", img, MID_PROMPT, code)
            kept += 1
    print(f"Docs: {kept} drawings -> {counts}")


# --------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1000)
    ap.add_argument("--out", default="cad_data")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-validate", action="store_true")
    ap.add_argument("--fea", type=int, default=0, help="number of FEA beam cases")
    ap.add_argument("--docs", type=int, default=0, help="number of drawings with title block (extraction/interpretation/midsurface tasks)")
    ap.add_argument("--scan", type=float, default=0.4, help="fraction of images turned into fake scans")
    ap.add_argument("--basics", type=int, default=0, help="number of basic 3-view 2D->3D samples (needs cad3d_basics.py)")
    ap.add_argument("--ship", type=int, default=0, help="samples per ship task (needs ship_xml_kit.py and --ship-src)")
    ap.add_argument("--ship-src", default="ship_src", help="folder with RULES.md, ONLINE_METHOD_RULES.md (or the deckrules zip) and the reference XMLs")
    a = ap.parse_args(argv)

    write_fea_tools()
    write_midsurface_tool()
    if not a.no_validate:
        try:
            import cadquery  # noqa
        except ImportError:
            sys.exit("cadquery not installed. pip install cadquery, or use --no-validate")

    r = random.Random(a.seed)
    out = Path(a.out); (out / "images").mkdir(parents=True, exist_ok=True)
    kept = failed = 0
    seen = set()
    with open(out / "dataset.jsonl", "w") as f:
        while kept < a.n:
            p = r.choice(TEMPLATES)(r)
            if p["code"] in seen:
                continue  # skip duplicates
            if not a.no_validate:
                try:
                    ok = validate(p["code"], p["bbox"])
                except Exception as e:
                    ok = False
                    print("exec error:", p["name"], e)
                if not ok:
                    failed += 1
                    continue
            seen.add(p["code"])
            img = f"images/{kept:05d}.png"
            render(p["views"], out / img)
            maybe_scan(out / img, r, a.scan)
            rec = {
                "image": img,
                "part": p["name"],
                "messages": [
                    {"role": "user", "content": [
                        {"type": "image"},
                        {"type": "text", "text": r.choice(PROMPTS)}]},
                    {"role": "assistant", "content": [
                        {"type": "text", "text": p["code"]}]},
                ],
            }
            f.write(json.dumps(rec) + "\n")
            kept += 1
            if kept % 100 == 0:
                print(f"{kept}/{a.n} kept, {failed} discarded")
    if a.fea:
        make_fea_samples(a.fea, r, out, a.scan)
    if a.docs:
        make_doc_samples(a.docs, r, out, a.scan, not a.no_validate)
    if a.basics:
        _add_kit_path()
        from cad3d_basics import make_basics_samples
        make_basics_samples(a.basics, r, out, maybe_scan, a.scan, check=not a.no_validate)
    if a.ship:
        if not os.path.isdir(a.ship_src):
            print(f"WARNING: {a.ship_src} not found - ship tasks skipped")
        else:
            _add_kit_path()
            from ship_xml_kit import make_ship_samples
            make_ship_samples(a.ship_src, out, r, a.ship, maybe_scan, a.scan)
    print(f"Done: {kept} CAD samples in {out}/dataset.jsonl ({failed} discarded)")



# =====================================================================
# PART 2: TRAIN (QLoRA) -> TEST -> EXPORT GGUF
# =====================================================================
MOBILE = os.environ.get("MOBILE", "0") == "1"   # small model that runs on a CPU / phone (no GPU) after training
MODEL = os.environ.get("MODEL", "unsloth/Qwen3-VL-2B-Instruct" if MOBILE else "unsloth/Qwen3-VL-4B-Instruct")   # use ...-2B-Instruct for a ~2 GB limit
DATA_DIR = "cad_data"
N_SAMPLES = int(os.environ.get("N_SAMPLES", 1000))      # CAD samples
N_DOCS = int(os.environ.get("N_DOCS", 400))          # drawings with title block: each gives 3-4 samples (extract, interpret, shell check, midsurface)
N_BASICS = int(os.environ.get("N_BASICS", 600))        # basic 3-view 2D->3D samples (17 part families, validated by bbox + volume)
N_SHIP = int(os.environ.get("N_SHIP", 300))          # ship samples PER TASK (rule Q&A: every rule x2; notes; review; online method: OCR fix, R2.1, labels, joints, steps, member JSON, review+)
SHIP_SRC = os.environ.get("SHIP_SRC", "ship_src") # folder with RULES.md, ONLINE_METHOD_RULES.md (or the zip) and the reference XMLs
N_FEA = int(os.environ.get("N_FEA", 600))           # FEA beam cases (each gives a script sample + ~60% review samples)
EPOCHS = int(os.environ.get("EPOCHS", 2))
QUANT = os.environ.get("QUANT", "q4_k_m" if MOBILE else "q6_k")                            # ~3.5 GB for 4B; use q4_k_m for ~2.5 GB


def load_samples(data_dir):
    from PIL import Image
    rows = []
    for line in open(Path(data_dir) / "dataset.jsonl"):
        d = json.loads(line)
        # text-only samples (ship rules / review) get a tiny blank image so every batch has the same structure
        img = (Image.open(Path(data_dir) / d["image"]).convert("RGB") if d.get("image")
               else Image.new("RGB", (56, 56), "white"))
        msgs = json.loads(json.dumps(d["messages"]))
        if not any(c["type"] == "image" for c in msgs[0]["content"]):
            msgs[0]["content"].insert(0, {"type": "image"})
        for c in msgs[0]["content"]:
            if c["type"] == "image":
                c["image"] = img
        rows.append({"messages": msgs})
    return rows


def train():
    from unsloth import FastVisionModel, is_bf16_supported
    from unsloth.trainer import UnslothVisionDataCollator
    from trl import SFTTrainer, SFTConfig

    model, tok = FastVisionModel.from_pretrained(MODEL, load_in_4bit=True)
    model = FastVisionModel.get_peft_model(
        model, finetune_vision_layers=True, finetune_language_layers=True,
        finetune_attention_modules=True, finetune_mlp_modules=True,
        r=16, lora_alpha=16, lora_dropout=0, bias="none", random_state=3407)

    data = load_samples(DATA_DIR)
    FastVisionModel.for_training(model)
    trainer = SFTTrainer(
        model=model, tokenizer=tok,
        data_collator=UnslothVisionDataCollator(model, tok),
        train_dataset=data,
        args=SFTConfig(
            per_device_train_batch_size=1, gradient_accumulation_steps=8,
            warmup_steps=5, num_train_epochs=EPOCHS, learning_rate=2e-4,
            fp16=not is_bf16_supported(), bf16=is_bf16_supported(),
            logging_steps=10, optim="adamw_8bit", weight_decay=0.01,
            lr_scheduler_type="linear", seed=3407, output_dir="outputs",
            report_to="none", remove_unused_columns=False,
            dataset_text_field="", dataset_kwargs={"skip_prepare_dataset": True},
            max_length=2048))
    trainer.train()
    model.save_pretrained("cad_lora"); tok.save_pretrained("cad_lora")
    return model, tok


def ask(model, tok, image_path, prompt=PROMPTS[0]):
    from PIL import Image
    from unsloth import FastVisionModel
    FastVisionModel.for_inference(model)
    img = Image.open(image_path).convert("RGB") if image_path else Image.new("RGB", (56, 56), "white")
    msgs = [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]}]
    text = tok.apply_chat_template(msgs, add_generation_prompt=True)
    inputs = tok(img, text, add_special_tokens=False, return_tensors="pt").to("cuda")
    out = model.generate(**inputs, max_new_tokens=700, temperature=0.2, do_sample=True)
    return tok.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)


def ask_with_rules(model, tok, question, image_path=None, k=4, src=SHIP_SRC):
    """RAG at run time: the k best matching rules from the rule book are put in front of the question."""
    _add_kit_path()
    from ship_xml_kit import RuleIndex, parse_rules, _read_sources
    idx = RuleIndex(parse_rules(_read_sources(src)))
    ents = idx.e
    ctx = "\n".join(f"- {e['id']}: {e['text'][:500]}" for e in idx.search(question, k))
    try:
        from ship_online import core_rules
        core = core_rules(ents) + "\n\n"
    except ImportError:
        core = ""
    return ask(model, tok, image_path, f"{core}Relevant rules:\n{ctx}\n\nQuestion: {question}")


def solve_ship(model, tok, image_path, src=SHIP_SRC, tries=3):
    """Online method with the model: deck plan image -> member JSON -> rule checks (C3-C6, PN1, PN4) -> errors back -> retry.
    The XML itself is written by code (ship_xml_kit.members_to_xml), never by the model."""
    _add_kit_path()
    from ship_xml_kit import parse_rules, _read_sources
    from ship_online import solve_ship_panel
    return solve_ship_panel(lambda img, p: ask(model, tok, img, p), image_path, parse_rules(_read_sources(src)), tries)


def _json_in(text):
    i, j = text.find("{"), text.rfind("}")
    try:
        return json.loads(text[i:j + 1])
    except Exception:
        return None


def solve_drawing(model, tok, image_path, tries=3):
    """Rule-guided 2D drawing -> 3D model. 1) read the spec (named dimensions) 2) check it with the rules
    3) write code from the checked spec + the 3 most relevant rules 4) run it, check bbox/volume/one solid, send errors back."""
    _add_kit_path()
    from cad3d_basics import SPEC_PROMPT, CODE_FROM_SPEC, CAD_RULES, FAMILY_HINT, check_spec, run_checked
    from ship_xml_kit import RuleIndex
    spec = _json_in(ask(model, tok, image_path, SPEC_PROMPT))
    if not spec:
        return {"ok": False, "stage": "spec", "errors": ["could not read a JSON spec from the drawing"]}
    issues = check_spec(spec)
    if issues:
        return {"ok": False, "stage": "spec", "spec": spec, "errors": [f"{c}: {m}" for c, m in issues],
                "hint": "ask the user to confirm the dimensions before building"}
    idx = RuleIndex(CAD_RULES)
    ctx = "\n".join(f"- {e['id']}: {e['text']}" for e in idx.search(FAMILY_HINT.get(spec["family"], "") + " " + spec["family"].replace("_", " ") + " " + " ".join(spec.get("notes", [])), 3))
    feedback, out, res = "", "", {"errors": []}
    for t in range(tries):
        out = ask(model, tok, image_path, f"Relevant rules:\n{ctx}\n\n" + CODE_FROM_SPEC.format(spec=json.dumps(spec)) + feedback)
        res = run_checked(out, spec)
        if res["ok"]:
            return {"ok": True, "spec": spec, "code": out, "tries": t + 1}
        feedback = "\n\nYour previous script failed these checks: " + "; ".join(res["errors"]) + ". Fix them."
    return {"ok": False, "stage": "code", "spec": spec, "errors": res["errors"], "code": out}


def run_generated(code):
    """Execute model output. CAD scripts -> bbox; FEA scripts -> solver results."""
    code = code.replace("```python", "").replace("```", "")
    ns = {}
    try:
        exec(code, ns)
        if "res" in ns:
            return {"ok": True, "fea": ns["res"]}
        if "mid" in ns:
            return {"ok": True, "midsurface": {"thickness": ns["mid"]["thickness"], "area": ns["mid"]["area"]}}
        b = ns["result"].val().BoundingBox()
        return {"ok": True, "bbox": (round(b.xlen, 2), round(b.ylen, 2), round(b.zlen, 2))}
    except Exception as e:
        return {"ok": False, "error": str(e)}


SHIP_ONLY = os.environ.get("SHIP_ONLY", "0") == "1"   # train only the ship-rule tasks (text, ~1 h on a T4) - fastest way to make the rules stronger
EVAL_BASE = os.environ.get("EVAL_BASE", "1") == "1"   # score the untrained model first, so the gain is measured
EVAL_PER_KIND = int(os.environ.get("EVAL_PER_KIND", 20))


def _ship_eval(model, tok, label):
    _add_kit_path()
    from unsloth import FastVisionModel
    from ship_eval import evaluate
    FastVisionModel.for_inference(model)
    print(f"===== ship rule test: {label} =====")
    tab = evaluate(lambda img, p: ask(model, tok, img, p), "ship_test", EVAL_PER_KIND, train_dir=DATA_DIR)
    json.dump(tab, open(f"ship_eval_{label}.json", "w"), indent=1)
    return tab


def run_ship_only():
    """data (ship tasks only) -> score base model -> QLoRA -> score again -> GGUF"""
    main(["--n", "0", "--out", DATA_DIR, "--no-validate", "--ship", str(N_SHIP), "--ship-src", SHIP_SRC])
    main(["--n", "0", "--out", "ship_test", "--seed", "999", "--no-validate", "--ship", "40", "--ship-src", SHIP_SRC])
    if EVAL_BASE:
        from unsloth import FastVisionModel
        import gc, torch
        base, btok = FastVisionModel.from_pretrained(MODEL, load_in_4bit=True)
        before = _ship_eval(base, btok, "before")
        del base; gc.collect(); torch.cuda.empty_cache()
    model, tok = train()
    after = _ship_eval(model, tok, "after")
    if EVAL_BASE:
        print("kind                    before   after")
        for k in after:
            if k != "_new":
                print(f"{k:22s} {before.get(k, 0):6.1%} {after[k]:7.1%}")
    model.save_pretrained_gguf("cad_gguf", tok, quantization_method=QUANT)
    print("Done. LoRA in ./cad_lora, GGUF in ./cad_gguf, scores in ship_eval_before.json / ship_eval_after.json")


if __name__ == "__main__" and SHIP_ONLY:
    run_ship_only()
    sys.exit(0)

if __name__ == "__main__":
    # 1) data (CAD + FEA + scanned-drawing extraction + midsurface + ship XML rules)
    main(["--n", str(N_SAMPLES), "--out", DATA_DIR, "--fea", str(N_FEA), "--docs", str(N_DOCS),
          "--basics", str(N_BASICS), "--ship", str(N_SHIP), "--ship-src", SHIP_SRC])
    # 2) train
    model, tok = train()
    # 3) test on fresh samples (different seed): 3 CAD, 2 FEA script, 2 FEA review
    main(["--n", "3", "--out", "cad_test", "--seed", "999", "--no-validate", "--fea", "6", "--docs", "6",
          "--basics", "6", "--ship", "3", "--ship-src", SHIP_SRC])
    CAD = {"plate", "flange", "l_bracket", "shaft", "pocket_block"}
    shown = {}
    for line in open("cad_test/dataset.jsonl"):
        d = json.loads(line)
        kind = "basic3d" if d["part"].startswith("basic3d_") else ("cad" if d["part"] in CAD else d["part"])
        if shown.get(kind, 0) >= (3 if kind == "cad" else 2 if kind == "basic3d" else 1):
            continue
        shown[kind] = shown.get(kind, 0) + 1
        prompt = d["messages"][0]["content"][1]["text"]
        out = ask(model, tok, f"cad_test/{d['image']}" if d.get("image") else None, prompt)
        print(f"--- {d['part']} ---\n{out}")
        print("expected:", d["messages"][1]["content"][0]["text"][:300]) if kind.startswith("ship_") else None
        if kind in ("cad", "basic3d", "spec_code", "fea_script", "midsurface_script"):
            print(run_generated(out))
    # 3b) rule loop on one basics drawing (reads spec -> rules -> code -> checks -> retry)
    for line in open("cad_test/dataset.jsonl"):
        d = json.loads(line)
        if d["part"].startswith("basic3d_"):
            res = solve_drawing(model, tok, f"cad_test/{d['image']}")
            print("--- solve_drawing ---", {k: v for k, v in res.items() if k != "code"})
            break
    # 3c) ship rule score of the trained model (held-out seed 999 ship tasks)
    if N_SHIP:
        main(["--n", "0", "--out", "ship_test", "--seed", "999", "--no-validate", "--ship", "40", "--ship-src", SHIP_SRC])
        _ship_eval(model, tok, "after")
    # 4) export GGUF (also writes the vision projector file)
    model.save_pretrained_gguf("cad_gguf", tok, quantization_method=QUANT)
    print("Done. GGUF in ./cad_gguf  (download it and run with llama.cpp / Ollama).")
    print("At run time keep fea_tools.py and midsurface_tool.py next to your runner so model scripts can import them.")
