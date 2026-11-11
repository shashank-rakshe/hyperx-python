# SPDX-License-Identifier: Apache-2.0
"""Node tension at touchdown on a coarse mesh (driver_touchdown_recovery in CMakeLists.txt).

A lazy-wave cable in 200 m of water is solved statically on a coarse mesh (10 m elements along
the grounded run) and on a reference mesh four times finer. The node tensions of the coarse
mesh, recovered from nodal equilibrium, must follow the reference within 3.5 % at every node
within 30 m of touchdown. The touchdown element is on the floor at one end only; spreading the
floor reaction of its grounded node over it understated the tension of the last suspended node
by 5.3 % (the rest of the profile is within 1.5 %).

Usage: check_touchdown_recovery.py <cabledyn executable>
"""

import pathlib
import subprocess
import sys
import tempfile

TOLERANCE = 0.035
WINDOW = 30.0
FLOOR_Z = -200.0

DECK = """--------------------- CableDyn Input File ------------------------------------
Touchdown recovery check: lazy-wave cable, static
--------------------- LINE TYPES ---------------------------------------------
Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)
bare 0.16 36.70 4.69e8 0.0 1.99e4 1.0e8 1.5e4 1.0 1.0 1.2 0.1 1.0 0.0
buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.0e8 1.5e4 1.0 1.0 1.2 0.1 1.0 0.0
--------------------- POINTS -------------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
7 Coupled 30.0 0.0 -20.0
8 Fixed 500.0 0.0 -200.0
--------------------- LINES --------------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
4 7 8 -
--------------------- SECTIONS -----------------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
4 bare 80.0 {n1}
4 buoy 100.0 {n2}
4 bare 420.0 {n3}
--------------------- END CONNECTIONS ----------------------------------------
LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist
(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)
4 A Rigid 0.1058 0 -0.9944 Free 0 1 0 0
4 B Rigid 1 0 0 Free 0 1 0 0
--------------------- OPTIONS ------------------------------------------------
9.80665 g
1025.0 rhoW
3.0e6 kBot
3.0e5 cBot
200.0 WtrDpth
0.025 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------------
FairTen4
--------------------- END ----------------------------------------------------
"""


def static_profile(exe, work, name, segments):
    """Arc length, z and node tension of every node of the static configuration."""
    deck = work / f"{name}.dat"
    n1, n2, n3 = segments
    deck.write_text(DECK.format(n1=n1, n2=n2, n3=n3), encoding="utf-8")
    run = subprocess.run([exe, str(deck), str(work / name)], capture_output=True, text=True, check=False)
    if run.returncode != 0:
        raise SystemExit(f"FAIL: the {name} deck did not solve (exit {run.returncode}):\n{run.stdout}{run.stderr}")
    rows = []
    for line in (work / f"{name}.static.out").read_text(encoding="utf-8").splitlines():
        fields = line.split()
        try:
            values = [float(x) for x in fields]
        except ValueError:
            continue
        rows.append(values)
    # columns: LineID Node ArcLength X Y Z Tension ...
    return [(r[2], r[5], r[6]) for r in rows]


def interpolate(arcs, values, s):
    for k in range(1, len(arcs)):
        if arcs[k] >= s:
            f = (s - arcs[k - 1]) / (arcs[k] - arcs[k - 1])
            return values[k - 1] + f * (values[k] - values[k - 1])
    return values[-1]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    exe = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        coarse = static_profile(exe, work, "coarse", (20, 25, 42))
        fine = static_profile(exe, work, "fine", (80, 100, 168))
    touchdown = next(s for s, z, _ in fine if z <= FLOOR_Z + 0.01)
    arcs = [s for s, _, _ in fine]
    tensions = [t for _, _, t in fine]
    worst = 0.0
    failures = []
    for s, z, t in coarse:
        if abs(s - touchdown) > WINDOW:
            continue
        ref = interpolate(arcs, tensions, s)
        err = (t - ref) / ref
        worst = max(worst, abs(err))
        print(f"  s = {s:7.1f} m  z = {z:8.2f} m  T = {t:8.1f} N  reference {ref:8.1f} N  {100 * err:+6.2f} %")
        if abs(err) > TOLERANCE:
            failures.append(f"s = {s:.1f} m: {100 * err:+.2f} %")
    print(f"touchdown at s = {touchdown:.1f} m; largest deviation {100 * worst:.2f} % (limit {100 * TOLERANCE:.1f} %)")
    if failures:
        raise SystemExit("FAIL: coarse-mesh node tension near touchdown off the reference: " + "; ".join(failures))
    print("PASS: coarse-mesh node tension follows the reference through touchdown")


if __name__ == "__main__":
    main()
