# SPDX-License-Identifier: Apache-2.0
"""Curvature and section moment of a stretched finite-EI line (driver_curvature_stretch in
CMakeLists.txt).

The element energy is EI kappa^2/2 + EA e^2/2 per unstretched length, with kappa the curvature of
the stretched line. A soft cable (axial strain up to 1.2 %) is clamped at End A and pinned at End
B, and the driver's static profile is compared with an independent solution of the planar
elastica of that energy,

    x' = (1 + e) cos(theta),  z' = (1 + e) sin(theta),  theta' = (1 + e)^2 M / EI,
    M' = -(1 + e) (cos(theta) n_z - sin(theta) n_x),   n' = (0, w),
    EA e - (1 + e) M^2 / EI = n_x cos(theta) + n_z sin(theta),

where M is the moment that balances the forces and kappa = theta'/(1 + e) = (1 + e) M / EI. The
strain is swept with EA, and at every node, relative to the local value floored at 1 % of the
peak, Curvature must follow kappa and BendMoment must follow M within 0.1 % (the old definitions
were low by 2e and e: 2.3 % and 1.2 % at the root). The exact trace of OutputRecovery element must
agree with the recovered curvature to the mesh's second order, within 0.5 %. The channels must
keep CurvX^2 + CurvY^2 = Curv^2 and BendMom (1 + e) = EI Curv.

Usage: check_curvature_stretch.py <cabledyn executable>
Exit 77 (skipped) when scipy is not installed.
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

G = 9.80665
RHO_W = 1025.0
D_CABLE = 0.20
M_CABLE = 60.0
EI = 2.0e4
LENGTH = 60.0
END_B = (45.0, -30.0)
W = (M_CABLE - RHO_W * math.pi / 4.0 * D_CABLE**2) * G
SWEEP = (2.0e6, 1.0e7, 5.0e8)
ELEMENTS = 480
TOLERANCE = 1.0e-3
TRACE_TOLERANCE = 5.0e-3
IDENTITY_TOLERANCE = 2.0e-5
FLOOR = 1.0e-2
NODE = 10
MOMENT_SCALE = 1.0e3
FORCE_SCALE = 1.0e4


def deck(ea: float, recovery: str = "") -> str:
    return f"""--------------------- CableDyn Input File ------------------------------------
Curvature of a stretched cable: clamped at End A, static
--------------------- LINE TYPES ---------------------------------------------
TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)
cable {D_CABLE} {M_CABLE} {ea} -1.0 {EI} 1.2 0.0 1.0 0.0
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
1 cable {LENGTH} {ELEMENTS}
--------------------- END CONNECTIONS ----------------------------------------
LineID End Stiffness EzX EzY EzZ
(-) (-) (N-m/rad) (-) (-) (-)
1 A Rigid 1.0 0.0 0.0
--------------------- OPTIONS ------------------------------------------------
{recovery}9.80665 g
1025.0 rhoW
0.05 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------------
"Curv1N{NODE}"
"CurvX1N{NODE}"
"CurvY1N{NODE}"
"BendMom1N{NODE}"
"Ten1N{NODE}"
END
"""


def solve(exe: str, tmp: str, name: str, text: str) -> tuple[np.ndarray, dict[str, float]]:
    """The static profile (columns from ArcLength) and the output channels at t = 0."""
    path = pathlib.Path(tmp) / f"{name}.dat"
    path.write_text(text)
    root = pathlib.Path(tmp) / name
    run = subprocess.run([exe, str(path), str(root)], capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f"FAIL: the driver did not solve {name}:\n{(run.stdout + run.stderr)[-2000:]}")
    rows = pathlib.Path(f"{root}.static.out").read_text().splitlines()[3:]
    lines = pathlib.Path(f"{root}.out").read_text().splitlines()
    channels = dict(zip(lines[1].split(), (float(v) for v in lines[2].split())))
    return np.array([[float(v) for v in r.split()[2:9]] for r in rows if r.strip()]), channels


def stretch_of(y: np.ndarray, ea: float) -> np.ndarray:
    bending = (MOMENT_SCALE * y[3]) ** 2 / EI
    axial = FORCE_SCALE * (y[4] * np.cos(y[2]) + y[5] * np.sin(y[2]))
    return 1.0 + (axial + bending) / (ea - bending)


def reference(arc: np.ndarray, x_seed: np.ndarray, z_seed: np.ndarray, ea: float):
    """The elastica, y = (x, z, theta, M, n_x, n_z), the moment and force scaled, seeded by the
    driver's shape."""

    def rhs(s, y):
        stretch = stretch_of(y, ea)
        c, sn = np.cos(y[2]), np.sin(y[2])
        return np.vstack([stretch * c, stretch * sn, stretch**2 * MOMENT_SCALE * y[3] / EI,
                          -stretch * FORCE_SCALE / MOMENT_SCALE * (c * y[5] - sn * y[4]),
                          np.zeros_like(s), np.full_like(s, W / FORCE_SCALE)])

    def bc(ya, yb):
        return np.array([ya[0], ya[1], ya[2], yb[0] - END_B[0], yb[1] - END_B[1], yb[3]])

    mesh = np.linspace(0.0, LENGTH, 3001)
    xs, zs = np.interp(mesh, arc, x_seed), np.interp(mesh, arc, z_seed)
    th = np.unwrap(np.arctan2(np.gradient(zs, mesh), np.gradient(xs, mesh)))
    y0 = np.vstack([xs, zs, th, np.zeros_like(mesh), np.full_like(mesh, np.cos(th[-1])), np.sin(th)])
    sol = solve_bvp(rhs, bc, mesh, y0, tol=1.0e-7, max_nodes=400000)
    if not sol.success:
        raise SystemExit(f"FAIL: the reference elastica did not converge: {sol.message}")
    return sol


def check(exe: str, tmp: str, ea: float) -> bool:
    data, out = solve(exe, tmp, "stretch", deck(ea))
    element, _ = solve(exe, tmp, "trace", deck(ea, "element OutputRecovery\n"))
    arc = np.arange(ELEMENTS + 1) * (LENGTH / ELEMENTS)
    y = reference(arc, data[:, 1], data[:, 3] + 20.0, ea).sol(arc)
    stretch = stretch_of(y, ea)
    moment = np.abs(y[3]) * MOMENT_SCALE
    kappa = stretch * moment / EI
    scale = np.maximum(kappa, FLOOR * kappa.max())
    curvature_error = np.max(np.abs(data[:, 5] - kappa) / scale)
    moment_error = np.max(np.abs(data[:, 6] - moment) / (EI * scale))
    trace_error = np.max(np.abs(element[:, 5] - data[:, 5]) / scale)
    curvature = out[f"Curv1N{NODE}"]
    identity_error = max(
        abs(math.hypot(out[f"CurvX1N{NODE}"], out[f"CurvY1N{NODE}"]) / curvature - 1.0),
        abs(out[f"BendMom1N{NODE}"] * stretch[NODE - 1] / (EI * curvature) - 1.0))
    ok = (curvature_error <= TOLERANCE and moment_error <= TOLERANCE and trace_error <= TRACE_TOLERANCE
          and identity_error <= IDENTITY_TOLERANCE)
    print(f"{'ok  ' if ok else 'FAIL'} EA {ea:.1e} N, strain up to {100 * (stretch.max() - 1.0):.3f} %: "
          f"curvature within {100 * curvature_error:.3f} %, moment within {100 * moment_error:.3f} %, "
          f"exact trace within {100 * trace_error:.3f} %, identities within {identity_error:.1e}")
    return ok


def main() -> int:
    if solve_bvp is None:
        print("SKIP: scipy is not installed")
        return 77
    with tempfile.TemporaryDirectory() as tmp:
        ok = all([check(sys.argv[1], tmp, ea) for ea in SWEEP])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
