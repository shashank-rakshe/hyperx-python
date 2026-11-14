# SPDX-License-Identifier: Apache-2.0
"""Bend stiffener against the planar elastica (driver_bend_stiffener in CMakeLists.txt).

A power cable leaves a hang-off clamped horizontal at End A through a 5 m polyurethane bend
stiffener (a 0.5 m cylindrical root and a 4.5 m cone) and hangs to a fixed End B 52 m away and
30 m lower. The driver solves the static equilibrium with the stiffener given as a STIFFENERS
table. The reference is an independent solution of the planar extensible elastica of the energy
EI kappa^2/2 + EA e^2/2 per unstretched length, kappa the curvature of the stretched line,

    x' = (1 + e) cos(theta),  z' = (1 + e) sin(theta),  theta' = (1 + e)^2 M / EI(s),
    M' = -(1 + e) (cos(theta) n_z - sin(theta) n_x),   n' = (0, w(s)),
    EA e - (1 + e) M^2 / EI(s) = n_x cos(theta) + n_z sin(theta),

with EI(s) the cable's EI plus E pi/64 (OD(s)^4 - ID^4) of the sleeve and w(s) the submerged
weight of cable and sleeve per unstretched length, solved by collocation (scipy solve_bvp)
with the clamped direction and position at End A, and the position and zero moment of the
pinned End B. Over the stiffener and the 3 m beyond it the cable's own bend moment (the
static profile's BendMoment, EI_cable kappa) must follow the reference within 2 % of its root
value, and the node positions within 1 cm; at the root and 2 m along, the cable's and the
stiffener's moments (BendMom1N<J> + StfMom1N<J>) must add up to the reference section moment
within 2 % of the root moment; and FairDefl1, the angle between the end force and the clamp
axis, must follow the reference within 0.05 deg.

The nodal curvature and the cable's moment are also gated locally: at every node of the first
8 m they must follow the reference within a share of its value at that arc, not of the root
value: 0.5 % on elements of 0.1 and 0.05 m, 1 % on 0.2 and 0.15 m (the tip then inside an
element). The curvature changes sign near the tip, so the value is floored at 0.1 % of the root
curvature. The stiffness at a node is EI(s) there; at the tip the bare side's, the larger
curvature of a real step. The same gate holds under the stiffener, where a sleeve makes the
interpolation's curvature no section's, the node values of OutputRecovery element and the peak of
each element in .elements.out against the largest reference curvature over that element, read
through cabledyn.bend_check where the package imports.

The curvature over the same 8 m must also follow OrcaFlex 11.6d, with the stiffener given as a
line attachment (tests/data/orcaflex_bend_stiffener_curvature.csv), within 1.5 % of the root
curvature; this part needs no scipy.

At a node inside the cone Curv, CurvX, CurvY, BendMom and StfMom must agree: the components
compose the curvature, the moments are EI_cable and EI(s) - EI_cable times it. At real steps of
the section the side of the larger curvature must give the values: the bare tip, a step between
stiffener rows and a junction of two line types; a junction of two meshes of one line type
under the stiffener is no step. A deck node keeps the rule on a mesh the static solve refined.
A sleeve too soft for the recovered moment, where the moment's error is far above its elastic
moment, must keep its element peaks at the curvature of its nodes. These parts need no scipy
either.

The initialisation notes are checked too: none on this deck; the resolution note when the 5 m
stiffener spans 3 elements (2 m elements); the pinned-end note when End A has no END
CONNECTIONS row.

Usage: check_bend_stiffener.py <cabledyn executable>
Exit 77 (skipped) when scipy is not installed and the notes pass.
"""

import math
import pathlib
import subprocess
import sys
import tempfile

import numpy as np

try:
    from scipy.integrate import solve_bvp
except ImportError:  # pragma: no cover - environment dependent
    solve_bvp = None

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "python"))
try:
    from cabledyn import bend_check, read_output
except ImportError:  # pragma: no cover - environment dependent
    bend_check = read_output = None

MOMENT_TOLERANCE = 0.02
POSITION_TOLERANCE = 0.01
ANGLE_TOLERANCE = 0.05
ORCAFLEX_TOLERANCE = 0.015
IDENTITY_TOLERANCE = 1.0e-5
# elements over the first 8 m with their local curvature tolerance: 0.2, 0.15 (the stiffener tip
# inside an element), 0.1 and 0.05 m
MESH_SWEEP = ((40, 0.01), (54, 0.01), (80, 0.005), (160, 0.005))
LOCAL_FLOOR = 1.0e-3
ELEMENT_RECOVERY = ("9.80665 g\n", "element OutputRecovery\n9.80665 g\n")
ORCAFLEX_CSV = pathlib.Path(__file__).resolve().parent / "data" / "orcaflex_bend_stiffener_curvature.csv"
REFINED_DECK = pathlib.Path(__file__).resolve().parent / "data" / "lazy_wave_touchdown_planar_coarse.dat"
WINDOW = 8.0

G = 9.80665
RHO_W = 1025.0
D_CABLE = 0.20
M_CABLE = 60.0
EA = 5.0e8
EI_CABLE = 2.0e4
LENGTH = 60.0
END_B = (51.90, -30.0)
# root side arc, tip side arc, root OD, tip OD (outward from End A)
SEGMENTS = [(0.0, 0.5, 0.60, 0.60), (0.5, 5.0, 0.60, 0.22)]
ID_STF = 0.20
E_STF = 5.0e7
RHO_STF = 1150.0

DECK = f"""--------------------- CableDyn Input File ------------------------------------
Bend stiffener check: hang-off clamped horizontal, static
--------------------- LINE TYPES ---------------------------------------------
TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)
cable {D_CABLE} {M_CABLE} {EA} -1.0 {EI_CABLE} 1.2 0.0 1.0 0.0
--------------------- POINTS -------------------------------------------------
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)
1 Coupled 0.0 0.0 -20.0 0 0 0 0
2 Fixed {END_B[0]} 0.0 {-20.0 + END_B[1]} 0 0 0 0
--------------------- LINES --------------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 cable 8.0 160
1 cable 52.0 52
--------------------- STIFFENERS ---------------------------------------------
LineID End Length RootOD TipOD InnerD E Density
(-) (-) (m) (m) (m) (m) (Pa) (kg/m^3)
""" + "".join(
    f"1 A {s1 - s0} {od0} {od1} {ID_STF} {E_STF} {RHO_STF}\n" for s0, s1, od0, od1 in SEGMENTS
) + """--------------------- END CONNECTIONS ----------------------------------------
LineID End Stiffness EzX EzY EzZ
(-) (-) (N-m/rad) (-) (-) (-)
1 A Rigid 1.0 0.0 0.0
--------------------- OPTIONS ------------------------------------------------
9.80665 g
1025.0 rhoW
0.05 dtM
0.05 TMax
--------------------- OUTPUTS ------------------------------------------------
"FairTen1"
"FairDefl1"
"BendMom1N1"
"StfMom1N1"
"BendMom1N41"
"StfMom1N41"
"Curv1N41"
"CurvX1N41"
"CurvY1N41"
"Ten1N41"
END
"""


def outer_diameter(s: np.ndarray) -> np.ndarray:
    od = np.full_like(s, np.nan)
    for s0, s1, od0, od1 in SEGMENTS:
        inside = (s >= s0) & (s <= s1)
        od[inside] = od0 + (s[inside] - s0) / (s1 - s0) * (od1 - od0)
    return od


def section(s: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Bending stiffness and submerged weight per unstretched length at arc s from End A."""
    od = outer_diameter(s)
    sleeve = ~np.isnan(od)
    ei = np.full_like(s, EI_CABLE)
    w = np.full_like(s, (M_CABLE - RHO_W * math.pi / 4.0 * D_CABLE**2) * G)
    area = math.pi / 4.0 * (od[sleeve] ** 2 - ID_STF**2)
    ei[sleeve] += E_STF * math.pi / 64.0 * (od[sleeve] ** 4 - ID_STF**4)
    w[sleeve] += (RHO_STF - RHO_W) * area * G
    return ei, w


FORCE_SCALE = 1.0e5
MOMENT_SCALE = 1.0e4


def reference_stretch(y: np.ndarray, ei: np.ndarray) -> np.ndarray:
    """1 + e of the elastica state y = (x, z, theta, M, n_x, n_z), scaled as in reference()."""
    bending = (MOMENT_SCALE * y[3]) ** 2 / ei
    axial = FORCE_SCALE * (y[4] * np.cos(y[2]) + y[5] * np.sin(y[2]))
    return 1.0 + (axial + bending) / (EA - bending)


def reference(s_nodes: np.ndarray, x_seed: np.ndarray, z_seed: np.ndarray):
    """Planar extensible elastica along the unstretched arc, y = (x, z, theta, M, n_x, n_z), with
    the moment and the force scaled by MOMENT_SCALE and FORCE_SCALE. The seed is the shape only:
    the driver's node positions; moment zero and a tension of FORCE_SCALE along the line."""

    def rhs(s, y):
        x, z, th, m, nx, nz = y
        ei, w = section(s)
        c, sn = np.cos(th), np.sin(th)
        stretch = reference_stretch(y, ei)
        return np.vstack([stretch * c, stretch * sn, stretch**2 * MOMENT_SCALE * m / ei,
                          -stretch * FORCE_SCALE / MOMENT_SCALE * (c * nz - sn * nx),
                          np.zeros_like(s), w / FORCE_SCALE])

    def bc(ya, yb):
        return np.array([ya[0], ya[1], ya[2], yb[0] - END_B[0], yb[1] - END_B[1], yb[3]])

    # a dense start mesh: the collocation residual is met at 1e-4 without refinement, which
    # would split the mesh at the steps of the sleeve's weight and stiffness at its tip
    mesh = np.unique(np.round(np.concatenate([s_nodes, np.linspace(0.0, WINDOW, 1601),
                                              np.linspace(0.0, LENGTH, 1201)]), 9))
    xs = np.interp(mesh, s_nodes, x_seed)
    zs = np.interp(mesh, s_nodes, z_seed)
    th = np.unwrap(np.arctan2(np.gradient(zs, mesh), np.gradient(xs, mesh)))
    y0 = np.vstack([xs, zs, th, np.zeros_like(mesh), np.cos(th[-1]) * np.ones_like(mesh), np.sin(th)])
    sol = solve_bvp(rhs, bc, mesh, y0, tol=1.0e-4, max_nodes=50000)
    if not sol.success:
        raise RuntimeError(f"reference elastica did not converge: {sol.message}")
    return sol


RESOLUTION_NOTE = "stiffener at End A spans"
FALLBACK_NOTES = ("reached after a failed Newton solve", "stalled", "looser tolerance")
PINNED_NOTE = "the stiffener at End A sleeves a pinned end"


def solve(exe: str, tmp: str, name: str, deck_text: str):
    """Run the driver on a deck; return (exit code, stdout + stderr, static profile rows, the
    output channels at t = 0 by name)."""
    deck = pathlib.Path(tmp) / f"{name}.dat"
    deck.write_text(deck_text)
    root = str(pathlib.Path(tmp) / name)
    run = subprocess.run([exe, str(deck), root], capture_output=True, text=True)
    static = pathlib.Path(root + ".static.out")
    rows = static.read_text().splitlines()[3:] if static.exists() else []
    channels = {}
    series = pathlib.Path(root + ".out")
    if series.exists():
        lines = series.read_text().splitlines()
        channels = dict(zip(lines[1].split(), (float(v) for v in lines[2].split())))
    return run.returncode, run.stdout + run.stderr, rows, channels


def check_notes(exe: str, tmp: str, log: str) -> bool:
    ok = RESOLUTION_NOTE not in log and PINNED_NOTE not in log
    print(f"{'ok  ' if ok else 'FAIL'} no stiffener note on the resolved, clamped deck")
    coarse = DECK.replace("1 cable 8.0 160", "1 cable 8.0 4")
    rc, out, _, _ = solve(exe, tmp, "coarse", coarse)
    good = rc == 0 and RESOLUTION_NOTE in out and "spans 3 elements" in out
    print(f"{'ok  ' if good else 'FAIL'} resolution note with 2 m elements")
    ok = ok and good
    start = DECK.index("--------------------- END CONNECTIONS")
    pinned = DECK[:start] + DECK[DECK.index("--------------------- OPTIONS"):]
    # (the deflection angle needs a held end)
    rc, out, _, _ = solve(exe, tmp, "pinned", pinned.replace('"FairDefl1"\n', ""))
    good = rc == 0 and PINNED_NOTE in out
    print(f"{'ok  ' if good else 'FAIL'} pinned-end note without END CONNECTIONS")
    return ok and good


def check_orcaflex(arc: np.ndarray, curvature: np.ndarray) -> bool:
    """The curvature over the first WINDOW m against OrcaFlex 11.6d with its stiffener given as a
    line attachment (tests/data/orcaflex_bend_stiffener_curvature.csv, from
    validation/scripts/orcaflex_bend_stiffener.py), within ORCAFLEX_TOLERANCE of the root value."""
    table = np.loadtxt(ORCAFLEX_CSV, delimiter=",", comments="#", skiprows=2)
    window = arc <= WINDOW
    reference = np.interp(arc[window], table[:, 0], table[:, 1])
    error = np.max(np.abs(curvature[window] - reference)) / table[0, 1]
    ok = error <= ORCAFLEX_TOLERANCE
    print(f"{'ok  ' if ok else 'FAIL'} curvature against OrcaFlex 11.6d: largest difference "
          f"{100 * error:.2f} % of the root curvature {table[0, 1]:.4f} 1/m")
    return ok


def step_deck(sections: str, rows: list[tuple[float, float, float]], channels: list[str]) -> str:
    """The deck on 0.1 m elements with other first sections (the last 52 m stay) and stiffener
    rows (length, root OD, tip OD), writing the node channels asked for."""
    deck = DECK.replace("1 cable 8.0 160\n", sections)
    start = deck.index("1 A ")
    deck = deck[:start] + "".join(
        f"1 A {length} {od0} {od1} {ID_STF} {E_STF} {RHO_STF}\n" for length, od0, od1 in rows
    ) + deck[deck.index("--------------------- END CONNECTIONS"):]
    deck = deck.replace(
        f"cable {D_CABLE} {M_CABLE} {EA} -1.0 {EI_CABLE} 1.2 0.0 1.0 0.0\n",
        f"cable {D_CABLE} {M_CABLE} {EA} -1.0 {EI_CABLE} 1.2 0.0 1.0 0.0\n"
        f"stiff {D_CABLE} {M_CABLE} {EA} -1.0 {2 * EI_CABLE} 1.2 0.0 1.0 0.0\n")
    return deck[:deck.index('"FairTen1"')] + "".join(f'"{c}"\n' for c in channels) + "END\n"


def sleeve(od: float) -> float:
    return E_STF * math.pi / 64.0 * (od**4 - ID_STF**4)


def check_steps(exe: str, tmp: str) -> bool:
    """The section moment BendMom + StfMom over the softer side's stiffness at a real step, and
    over EI(s) at a node where only the mesh changes (node 31 at 3 m, node 21 at 2 m, node 51 at
    the 5 m tip)."""
    cone = [(0.5, 0.60, 0.60), (4.5, 0.60, 0.22)]
    od_3m = 0.60 + 2.5 / 4.5 * (0.22 - 0.60)
    # name, sections, stiffener rows, node, stiffness of the side of the curvature, cable stiffness of
    # the BendMom share (the larger share, on the side of the larger EI_cable)
    cases = [
        ("bare tip", "1 cable 8.0 80\n", cone, 51, EI_CABLE, EI_CABLE),
        ("step between rows", "1 cable 8.0 80\n", [(2.0, 0.60, 0.60), (3.0, 0.45, 0.22)], 21,
         EI_CABLE + sleeve(0.45), EI_CABLE),
        ("junction of two line types", "1 cable 3.0 30\n1 stiff 5.0 50\n", cone, 31,
         EI_CABLE + sleeve(od_3m), 2 * EI_CABLE),
        ("junction of two meshes", "1 cable 3.0 60\n1 cable 5.0 50\n", cone, 61,
         EI_CABLE + sleeve(od_3m), EI_CABLE),
    ]
    ok = True
    for name, sections, rows, node, ei, ei_cable in cases:
        channels = [f"{c}1N{node}" for c in ("Curv", "BendMom", "StfMom", "Ten")]
        rc, log, _, out = solve(exe, tmp, "step", step_deck(sections, rows, channels))
        if rc != 0:
            print(log[-3000:])
            print(f"FAIL {name}: the driver did not solve the deck")
            return False
        curvature, bend, stiffener, tension = (out[c] for c in channels)
        moment = bend + stiffener
        stretch = 1.0 + tension / EA
        full = ei_cable == ei
        if name == "junction of two line types":
            # the stiffer type's own share: EI_cable M / (EI_cable + sleeve)
            share = ei_cable * moment / (ei_cable + sleeve(od_3m))
        else:
            share = moment if full else ei_cable * curvature / stretch
        error = max(abs(curvature * ei / (stretch * moment) - 1.0), abs(bend / share - 1.0))
        good = error <= IDENTITY_TOLERANCE
        print(f"{'ok  ' if good else 'FAIL'} {name}: curvature {curvature:.5f} 1/m, "
              f"section moment {moment:.1f} N m, largest relative difference {error:.1e}")
        ok = ok and good
    return ok


def check_refined(exe: str, tmp: str) -> bool:
    """A stiffener on a line whose static solve refines the deck mesh, the coarse lazy wave with
    20 m elements under a 60 m cone: the stiffness at the deck node 40 m along, on the final mesh,
    gives its curvature."""
    deck = REFINED_DECK.read_text().replace("4 bare 80.0 20", "4 bare 80.0 4")
    length, od0, od1, bore = 60.0, 0.22, 0.17, 0.16
    deck = deck.replace("--------------------- OPTIONS", (
        "--------------------- STIFFENERS ---------------------------------------------\n"
        "LineID End Length RootOD TipOD InnerD E Density\n"
        "(-) (-) (m) (m) (m) (m) (Pa) (kg/m^3)\n"
        f"4 A {length} {od0} {od1} {bore} {E_STF} {RHO_STF}\n"
        "--------------------- OPTIONS"), 1)
    deck = deck.replace("FairTen4\n", "Curv4N3\nBendMom4N3\nStfMom4N3\nTen4N3\n")
    rc, log, rows, out = solve(exe, tmp, "refined", deck)
    if rc != 0 or "refined to" not in log:
        print(log[-3000:])
        print("FAIL: the driver did not solve and refine the coarse deck")
        return False
    od = od0 + 40.0 / length * (od1 - od0)
    ei = 1.99e4 + E_STF * math.pi / 64.0 * (od**4 - bore**4)
    stretch = 1.0 + out["Ten4N3"] / 4.69e8
    error = abs(out["Curv4N3"] * ei / (stretch * (out["BendMom4N3"] + out["StfMom4N3"])) - 1.0)
    ok = error <= IDENTITY_TOLERANCE
    print(f"{'ok  ' if ok else 'FAIL'} refined mesh of {len(rows) - 1} elements: curvature at the "
          f"deck node within {error:.1e} of the section moment over EI(s)")
    return ok


def check_soft_sleeve(exe: str, tmp: str) -> bool:
    """The coarse lazy wave with EI 100 N m^2 under a 100 m sleeve of 120 N m^2 at most, far below
    the stiffness that resolves the recovered moment, max(w L0^2)/12 of about 1300 N m^2 on its
    10 m elements: moment over stiffness would be noise there. The element peaks must stay with
    the curvature of their end nodes, which take the interpolation's."""
    length = 100.0
    deck = REFINED_DECK.read_text().replace(" 1.99e4 ", " 100.0 ")
    deck = deck.replace("--------------------- OPTIONS", (
        "--------------------- STIFFENERS ---------------------------------------------\n"
        "LineID End Length RootOD TipOD InnerD E Density\n"
        "(-) (-) (m) (m) (m) (m) (Pa) (kg/m^3)\n"
        f"4 A {length} 0.18 0.17 0.16 1.0e6 {RHO_STF}\n"
        "--------------------- OPTIONS"), 1)
    rc, log, rows, _ = solve(exe, tmp, "soft", deck)
    if rc != 0:
        print(log[-3000:])
        print("FAIL: the driver did not solve the deck with a soft sleeve")
        return False
    nodes = np.array([float(r.split()[7]) for r in rows if r.strip()])
    table = (pathlib.Path(tmp) / "soft.elements.out").read_text().splitlines()[3:]
    table = np.array([[float(v) for v in r.split()] for r in table if r.strip()])
    covered = int(np.sum(table[:, 3] <= length + 1.0e-9))
    ratio = np.max(table[:covered, 6] / np.maximum(nodes[:covered], nodes[1:covered + 1]))
    ok = ratio <= 1.02
    print(f"{'ok  ' if ok else 'FAIL'} soft sleeve: element peaks within a factor {ratio:.3f} of the "
          f"curvature at their end nodes")
    return ok


def check_identities(out: dict[str, float], name: str = "node 41", stretch: float | None = None) -> bool:
    """Curv, CurvX, CurvY, BendMom and StfMom of a node inside the cone (node 41, 2 m): the moments
    are the stiffnesses times the curvature over the stretch, 1 under OutputRecovery element."""
    curvature = out["Curv1N41"]
    ei = float(section(np.array([2.0]))[0][0])
    stretch = 1.0 + out["Ten1N41"] / EA if stretch is None else stretch
    error = max(abs(math.hypot(out["CurvX1N41"], out["CurvY1N41"]) / curvature - 1.0),
                abs(out["BendMom1N41"] * stretch / (EI_CABLE * curvature) - 1.0),
                abs(out["StfMom1N41"] * stretch / ((ei - EI_CABLE) * curvature) - 1.0))
    ok = error <= IDENTITY_TOLERANCE
    print(f"{'ok  ' if ok else 'FAIL'} {name}: curvature components and moment shares agree "
          f"within {error:.1e}")
    return ok


def element_peaks(path: pathlib.Path, n: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Arc start and end of the first n elements of a .elements.out, and their peak curvature,
    through bend_check where the package imports."""
    table = np.array([[float(v) for v in r.split()] for r in path.read_text().splitlines()[3:]])[:n]
    if bend_check is None:
        return table[:, 2], table[:, 3], table[:, 6]
    return table[:, 2], table[:, 3], bend_check(read_output(path), 1.0, condition="storage", line_id=1).curvature[:n]


def reference_curvature(sol, s: np.ndarray, ei: np.ndarray | None = None) -> np.ndarray:
    """Curvature of the stretched line, (1 + e) M / EI, at arc s."""
    ei = section(s)[0] if ei is None else ei
    y = sol.sol(s)
    return reference_stretch(y, ei) * np.abs(y[3]) * MOMENT_SCALE / ei


def check_local(exe: str, tmp: str, sol) -> bool:
    """Curvature and cable moment over the first WINDOW m against the elastica, each within the
    tolerance of MESH_SWEEP of the reference where it is reported, element size swept: at the
    nodes, and under the stiffener at the nodes of OutputRecovery element and the peak of each
    element."""
    ok = True
    root_curvature = float(reference_curvature(sol, np.array([0.0]))[0])
    tip = SEGMENTS[-1][1]
    for n, tolerance in MESH_SWEEP:
        deck = DECK.replace("1 cable 8.0 160", f"1 cable 8.0 {n}")
        s = np.arange(n + 1) * (WINDOW / n)
        ei = section(s)[0]
        ei[np.abs(s - tip) < 1.0e-9] = EI_CABLE
        curvature = reference_curvature(sol, s, ei)
        moment = np.abs(sol.sol(s)[3]) * MOMENT_SCALE / ei
        scale = np.maximum(curvature, LOCAL_FLOOR * root_curvature)
        for name, text in (("equilibrium nodes", deck), ("element nodes", deck.replace(*ELEMENT_RECOVERY))):
            rc, log, rows, _ = solve(exe, tmp, "local", text)
            if rc != 0:
                print(log[-3000:])
                print(f"FAIL: the driver did not solve the deck with {n} elements")
                return False
            if any(note in log for note in FALLBACK_NOTES):
                print(log[-3000:])
                print(f"FAIL: the static solve with {n} elements fell back")
                return False
            data = np.array([[float(v) for v in r.split()[2:9]] for r in rows[:n + 1]])
            # past the tip an element's own curvature is the section's, by definition
            covered = s < tip - 1.0e-9 if name == "element nodes" else s < np.inf
            error = np.where(covered, np.abs(data[:, 5] - curvature) / scale, 0.0)
            # the element definition of the bend moment is EI times the curvature
            shared = curvature if name == "element nodes" else moment
            moment_error = np.max(np.where(covered, np.abs(np.abs(data[:, 6]) / EI_CABLE - shared) / scale, 0.0))
            worst = int(np.argmax(error))
            good = max(error[worst], moment_error) <= tolerance
            print(f"{'ok  ' if good else 'FAIL'} {WINDOW / n:.3f} m elements, {name}: curvature within "
                  f"{100 * error[worst]:.3f} % locally (at {s[worst]:.3f} m), cable moment within "
                  f"{100 * moment_error:.3f} %, gate {100 * tolerance:.1f} %")
            ok = ok and good
        start, stop, peak = element_peaks(pathlib.Path(tmp) / "local.elements.out", n)
        # inside each element, so a tip on its end reads the element's own side
        inner = start[:, None] + (stop - start)[:, None] * np.linspace(1.0e-6, 1.0 - 1.0e-6, 33)
        reference = reference_curvature(sol, inner.ravel()).reshape(inner.shape).max(axis=1)
        error = np.abs(peak - reference) / np.maximum(reference, LOCAL_FLOOR * root_curvature)
        error[start >= tip - 1.0e-9] = 0.0
        worst = int(np.argmax(error))
        good = error[worst] <= tolerance
        print(f"{'ok  ' if good else 'FAIL'} {WINDOW / n:.3f} m elements, element peaks: within "
              f"{100 * error[worst]:.3f} % locally (element at {start[worst]:.3f} m), gate "
              f"{100 * tolerance:.1f} %")
        ok = ok and good
    return ok


def main() -> int:
    exe = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        rc, log, rows, out = solve(exe, tmp, "stiffener", DECK)
        if rc != 0:
            print(log[-3000:])
            print("FAIL: the driver did not solve the stiffener deck")
            return 1
        notes_ok = check_notes(exe, tmp, log)
        notes_ok = check_steps(exe, tmp) and notes_ok
        notes_ok = check_refined(exe, tmp) and notes_ok
        notes_ok = check_soft_sleeve(exe, tmp) and notes_ok
        data = np.array([[float(v) for v in r.split()[2:9]] for r in rows if r.strip()])
        notes_ok = check_identities(out) and notes_ok
        rc, log, _, element_out = solve(exe, tmp, "element", DECK.replace(*ELEMENT_RECOVERY))
        if rc != 0:
            print(log[-3000:])
            print("FAIL: the driver did not solve the deck under OutputRecovery element")
            return 1
        notes_ok = check_identities(element_out, "node 41, OutputRecovery element", 1.0) and notes_ok
        orcaflex_ok = check_orcaflex(data[:, 0], data[:, 5])
        if solve_bvp is None:
            print("SKIP: scipy is not installed (the elastica comparison needs solve_bvp)")
            return 77 if notes_ok and orcaflex_ok else 1
        arc, x, z, moment = data[:, 0], data[:, 1], data[:, 3] + 20.0, data[:, 6]
        s_nodes = np.cumsum(np.r_[0.0, np.full(160, 8.0 / 160), np.full(52, 1.0)])
        sol = reference(s_nodes, x, z)
        local_ok = check_local(exe, tmp, sol)
    ref = sol.sol(s_nodes)
    ref[3] *= MOMENT_SCALE
    section_moment = np.abs(ref[3])
    cable_moment = EI_CABLE * section_moment / section(s_nodes)[0]
    window = s_nodes <= WINDOW
    cable_error = np.max(np.abs(np.abs(moment[window]) - cable_moment[window])) / cable_moment[0]
    position_error = np.max(np.hypot(x - ref[0], z - ref[1]))
    print(f"root cable moment: driver {moment[0]:.1f} N m, elastica {cable_moment[0]:.1f} N m")
    print(f"largest cable-moment difference over the first {WINDOW} m: {100 * cable_error:.2f} % of the root value")
    print(f"largest node position difference: {1000 * position_error:.2f} mm")
    total_error = 0.0
    for node in (1, 41):
        total = out[f"BendMom1N{node}"] + out[f"StfMom1N{node}"]
        total_error = max(total_error, abs(total - section_moment[node - 1]) / section_moment[0])
        print(f"node {node}: cable + stiffener {total:.1f} N m, elastica section moment {section_moment[node - 1]:.1f} N m")
    end_force = sol.sol(np.array([0.0]))[4:6, 0]
    deflection = math.degrees(math.atan2(abs(end_force[1]), end_force[0]))
    angle_error = abs(out["FairDefl1"] - deflection)
    print(f"FairDefl1: driver {out['FairDefl1']:.4f} deg, elastica {deflection:.4f} deg")
    ok = (cable_error <= MOMENT_TOLERANCE and position_error <= POSITION_TOLERANCE and notes_ok
          and total_error <= MOMENT_TOLERANCE and angle_error <= ANGLE_TOLERANCE and orcaflex_ok
          and local_ok)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
