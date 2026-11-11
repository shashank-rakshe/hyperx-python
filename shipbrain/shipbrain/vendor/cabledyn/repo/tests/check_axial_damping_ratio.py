# SPDX-License-Identifier: Apache-2.0
"""Axial damping of a negative BA under OPTION axialDampingRatio (driver_axial_damping_ratio in
CMakeLists.txt).

A vertical taut line (99.5 m between points 100 m apart, no axial drag or added mass) is excited in
its first axial mode by a smooth half-cosine lift of its top end, held afterwards, and the free
decay of the anchor tension is fitted with one damped sinusoid. On the uniform line (EA = 5e7 N,
50 kg/m) the lift lasts 3/4 of the mode-1 period, which leaves the second mode at rest; the third,
damped three times as much, has died out before the fitted window. The composite line puts a
stiffer, heavier lower half (EA = 2e8 N, 100 kg/m) under the same upper half.

* Default ``segment`` form, BA = -1 (BA = zeta L0 sqrt(EA m) of each element): the first axial
  mode of the uniform line is damped at zeta pi/(2N), halving as the mesh doubles (N = 50, 100,
  200), and the initialisation note gives that ratio for the line's mesh. On the composite line
  the ratio is the Rayleigh quotient of the axial chain with every element damped by its own EA
  and mass, worked out here independently.
* ``mode1 axialDampingRatio``, BA = -0.02: the first axial mode is damped at 2 % on every mesh,
  uniform and composite, on the EI = 0 route and on the finite-EI route, and no note is made.
  The finite-EI route also checks the segment form and its note on 100 elements. A viscoelastic
  section, whose first axial mode one BA does not set, is refused by name under mode1.

Every fitted ratio must lie within 3 % of its target.

Usage: check_axial_damping_ratio.py <cabledyn executable>
"""

import math
import pathlib
import re
import subprocess
import sys
import tempfile

import numpy as np

UPPER = ("rope", 5.0e7, 50.0)
LOWER = ("wire", 2.0e8, 100.0)
LENGTH = 99.5
SPAN = 100.0
TOP_Z = -10.0
LIFT = 0.05
OMEGA1 = math.pi / LENGTH * math.sqrt(UPPER[1] / UPPER[2])
PERIOD = 2.0 * math.pi / OMEGA1
DT = 0.002
RAMP = 0.75 * PERIOD
WINDOW = (1.5, 7.5)
TOLERANCE = 0.03
MESHES = (50, 100, 200)
ZETA_MODE1 = 0.02


def deck(n_elem: int, ba: float, ei: float, mode1: bool, composite: bool = False) -> str:
    option = "mode1 axialDampingRatio\n" if mode1 else ""
    types = "".join(f"{name} 0.1 {mass} {ea} {ba} {ei} 1.2 0.0 1.0 0.0\n" for name, ea, mass in (UPPER, LOWER))
    if composite:
        sections = f"1 rope {LENGTH / 2} {n_elem // 2}\n1 wire {LENGTH / 2} {n_elem // 2}\n"
    else:
        sections = f"1 rope {LENGTH} {n_elem}\n"
    return f"""--------------------- CableDyn Input File ------------------------------------
Free axial decay of a vertical taut line
--------------------- LINE TYPES ---------------------------------------------
TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)
{types}--------------------- POINTS -------------------------------------------------
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)
1 Coupled 0.0 0.0 {TOP_Z} 0 0 0 0
2 Fixed 0.0 0.0 {TOP_Z - SPAN} 0 0 0 0
--------------------- LINES --------------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
{sections}--------------------- OPTIONS ------------------------------------------------
{option}9.80665 g
1025.0 rhoW
1.0 rhoInf
{DT} dtM
{WINDOW[1]} TMax
motion.txt motionFile
--------------------- OUTPUTS ------------------------------------------------
"AnchTen1"
END
"""


def motion() -> str:
    rows = ["# time point x y z vx vy vz ax ay az"]
    for k in range(int(round(WINDOW[1] / DT)) + 2):
        t = k * DT
        if t < RAMP:
            arg = math.pi * t / RAMP
            z = 0.5 * LIFT * (1.0 - math.cos(arg))
            vz = 0.5 * LIFT * math.pi / RAMP * math.sin(arg)
            az = 0.5 * LIFT * (math.pi / RAMP) ** 2 * math.cos(arg)
        else:
            z, vz, az = LIFT, 0.0, 0.0
        rows.append(f"{t:.6f} 1 0 0 {TOP_Z + z:.12g} 0 0 {vz:.12g} 0 0 {az:.12g}")
    return "\n".join(rows) + "\n"


def run(exe: str, tmp: pathlib.Path, name: str, text: str) -> tuple[np.ndarray, np.ndarray, str]:
    folder = tmp / name
    folder.mkdir()
    (folder / "motion.txt").write_text(motion())
    (folder / "deck.dat").write_text(text)
    proc = subprocess.run([exe, "deck.dat", "run"], cwd=folder, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"FAIL: the driver did not run {name}:\n{(proc.stdout + proc.stderr)[-3000:]}")
    lines = (folder / "run.out").read_text().splitlines()
    names = [name.split("(")[0] for name in lines[1].split()]
    data = np.array([[float(v) for v in row.split()] for row in lines[2:] if row.strip()])
    return data[:, names.index("Time")], data[:, names.index("AnchTen1")], proc.stdout + proc.stderr


def fit_decay(t: np.ndarray, y: np.ndarray) -> float:
    """The damping ratio of y = c + exp(-s t) (a cos(w t) + b sin(w t)), by Gauss-Newton from a
    zero-crossing frequency and a log-decrement start."""
    keep = (t >= WINDOW[0]) & (t <= WINDOW[1])
    t, y = t[keep] - WINDOW[0], y[keep]
    yc = y - y.mean()
    crossings = t[np.nonzero(np.diff(np.signbit(yc)))[0]]
    w = math.pi * (len(crossings) - 1) / (crossings[-1] - crossings[0])
    half = len(t) // 2
    s = math.log(np.abs(yc[:half]).max() / np.abs(yc[half:]).max()) / (t[half] - t[0])
    p = np.array([y.mean(), yc[0], 0.0, s, w])
    for _ in range(100):
        c, a, b, s, w = p
        e = np.exp(-s * t)
        cs, sn = np.cos(w * t), np.sin(w * t)
        model = c + e * (a * cs + b * sn)
        jac = np.column_stack(
            [np.ones_like(t), e * cs, e * sn, -t * e * (a * cs + b * sn), t * e * (-a * sn + b * cs)]
        )
        step = np.linalg.lstsq(jac, y - model, rcond=None)[0]
        p = p + step
        if abs(step[3]) <= 1.0e-12 * abs(p[3]) and abs(step[4]) <= 1.0e-12 * abs(p[4]):
            break
    s, w = p[3], p[4]
    return s / math.hypot(s, w)


def chain_ratio(n_elem: int, zeta: float) -> float:
    """The first-mode damping ratio of the composite line's axial chain (both ends held, element
    stiffness EA/L0, damping zeta sqrt(EA m) = BA/L0 of each element itself, lumped masses)."""
    half = n_elem // 2
    h = LENGTH / n_elem
    ea = np.array([UPPER[1]] * half + [LOWER[1]] * half)
    mass = np.array([UPPER[2]] * half + [LOWER[2]] * half)
    k, c = ea / h, zeta * np.sqrt(ea * mass)
    stiff, damp = np.zeros((n_elem - 1, n_elem - 1)), np.zeros((n_elem - 1, n_elem - 1))
    for e in range(n_elem):
        for p, q, sign in ((e - 1, e - 1, 1), (e, e, 1), (e - 1, e, -1), (e, e - 1, -1)):
            if 0 <= p < n_elem - 1 and 0 <= q < n_elem - 1:
                stiff[p, q] += sign * k[e]
                damp[p, q] += sign * c[e]
    lumped = 0.5 * (mass[:-1] + mass[1:]) * h
    scale = 1.0 / np.sqrt(lumped)
    w2, vec = np.linalg.eigh(scale[:, None] * stiff * scale[None, :])
    u = scale * vec[:, 0]
    return float(u @ damp @ u / (2.0 * math.sqrt(w2[0]) * (u @ (lumped * u))))


def note_ratio(log: str) -> float | None:
    match = re.search(r"first axial mode of the line \(both ends held\) at ([0-9.Ee+-]+) % of critical", log)
    return None if match is None else float(match.group(1)) / 100.0


def check(label: str, zeta: float, target: float) -> bool:
    err = zeta / target - 1.0
    print(f"{label}: zeta_1 = {zeta:.5f}, target {target:.5f} ({err:+.2%})")
    if abs(err) > TOLERANCE:
        print(f"FAIL: {label} is not damped at its target ratio")
        return False
    return True


def main() -> int:
    exe = sys.argv[1]
    ok = True
    with tempfile.TemporaryDirectory() as folder:
        tmp = pathlib.Path(folder)
        print(f"first axial mode of the uniform line: {OMEGA1:.4f} rad/s, period {PERIOD:.4f} s")
        for n_elem, ei in [(n, 0.0) for n in MESHES] + [(100, 1.0)]:
            target = math.pi / (2.0 * n_elem)
            route = "finite-EI " if ei > 0.0 else ""
            t, y, log = run(exe, tmp, f"segment_{n_elem}_{ei}", deck(n_elem, -1.0, ei, False))
            ok = check(f"segment {route}N={n_elem}", fit_decay(t, y), target) and ok
            noted = note_ratio(log)
            print(f"  note: {noted}")
            if noted is None or abs(noted / target - 1.0) > TOLERANCE:
                print("FAIL: the note does not give the first-mode ratio of the segment form")
                ok = False
            if f"on its {n_elem} elements" not in log or "the axial damping depends on the mesh" not in log:
                print("FAIL: the note does not name the mesh")
                ok = False
        t, y, log = run(exe, tmp, "segment_composite", deck(50, -1.0, 0.0, False, composite=True))
        ok = check("segment composite N=50", fit_decay(t, y), chain_ratio(50, 1.0)) and ok
        cases = [(n, 0.0, False) for n in MESHES] + [(50, 0.0, True), (200, 0.0, True), (100, 1.0, False), (100, 1.0, True)]
        for n_elem, ei, composite in cases:
            label = f"mode1 {'finite-EI' if ei > 0.0 else 'EI=0'}{' composite' if composite else ''} N={n_elem}"
            t, y, log = run(exe, tmp, label.replace(" ", "_").replace("=", ""),
                            deck(n_elem, -ZETA_MODE1, ei, True, composite=composite))
            ok = check(label, fit_decay(t, y), ZETA_MODE1) and ok
            if "damping ratio per segment" in log:
                print("FAIL: a mode1 line is noted as damped per segment")
                ok = False
        # a viscoelastic section has no one EA to set its first mode by: refused by name
        text = deck(50, -ZETA_MODE1, 0.0, True).replace(f" {UPPER[1]} {-ZETA_MODE1} ", f" {UPPER[1]}|1.0e8 {-ZETA_MODE1}|0 ")
        folder_ve = tmp / "mode1_viscoelastic"
        folder_ve.mkdir()
        (folder_ve / "motion.txt").write_text(motion())
        (folder_ve / "deck.dat").write_text(text)
        proc = subprocess.run([exe, "deck.dat", "run"], cwd=folder_ve, capture_output=True, text=True)
        refused = "OPTION axialDampingRatio mode1: LINE 1 has a negative BA and the section type rope"
        print(f"mode1 viscoelastic: exit {proc.returncode}, refused by name: {refused in proc.stdout + proc.stderr}")
        if proc.returncode == 0 or refused not in proc.stdout + proc.stderr:
            print("FAIL: mode1 on a viscoelastic section is not refused by name")
            ok = False
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
