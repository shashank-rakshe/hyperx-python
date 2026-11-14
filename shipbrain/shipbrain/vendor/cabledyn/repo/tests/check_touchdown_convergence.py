# SPDX-License-Identifier: Apache-2.0
"""Node tension at touchdown converges at the element's order (driver_touchdown_convergence).

A lazy-wave cable in a current is solved statically on three element sizes at touchdown
(about 1.6, 0.8 and 0.4 m), each on nine meshes that differ by a few elements in the section
that holds the touchdown point, so that the touchdown point falls at every position within its
element. A mesh 32 times finer than the 64-element base is the reference; nodes are compared at
the same unstretched arc length. The local error at touchdown is the largest departure of the
node tension error at the last suspended node, the first grounded node and the next node from
the error three nodes either side (the smooth discretisation error of the profile). Its largest
value over the nine meshes must fall at least by RATE when the elements are halved from 0.8 to
0.4 m, and stay below LIMIT on the 0.4 m meshes.

The floor reaction of the first grounded node used to be spread over its grounded half-element
alone, whatever the position of the touchdown point in the touchdown element: the local error
then fell at the first order (4.3, 1.9, 1.0 N on the three sizes, against a line tension of
about 270 N there).

Usage: check_touchdown_convergence.py <cabledyn executable>
"""

import bisect
import pathlib
import subprocess
import sys
import tempfile

FLOOR_Z = -80.0
LENGTHS = (68.114, 50.0, 52.101)
BASE = (28, 20, 16)  # elements per section of the 64-element base mesh
LEVELS = (2, 4, 8)  # multipliers of the base mesh
SHIFTS = range(-4, 5)  # elements added to the touchdown section of each level
REFERENCE = 32
RATE = 2.5
LIMIT = 0.35  # N, on the 0.4 m meshes

DECK = """--------------------- CableDyn Input File ------------------------------------
Touchdown convergence check: lazy-wave cable in a current, static
--------------------- LINE TYPES ---------------------------------------------
TypeName  Diam   MassDenInAir  EA       BA   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)       (m)    (kg/m)        (N)      (-)  (N-m2)   (-)   (-)   (-)   (-)
bare      0.160  36.70         4.69e8   0.0  1.99e4   1.2   0.1   1.0   0.0
buoy      0.290  0.0           4.69e8   0.0  1.99e4   1.2   0.1   1.0   0.0
--------------------- POINTS ------------------------------------------------
ID  Type     X       Y    Z
(-) (-)      (m)     (m)  (m)
1   Coupled  5.0     0.0  -14.0
2   Fixed    125.0   0.0  -80.0
--------------------- LINES -------------------------------------------------
ID  NodeA  NodeB  Outputs
(-) (-)    (-)    (-)
1   1      2      -
--------------------- SECTIONS ----------------------------------------------
LineID  LineType  Length   NumSegs
(-)     (-)       (m)      (-)
1       bare      68.114   {n1}
1       buoy      50.000   {n2}
1       bare      52.101   {n3}
--------------------- EQUIVALENT BUOYANCY -----------------------------------
LineType  Diam   SubmergedWeightNpm
(-)       (m)    (N/m)
buoy      0.290  -80.15
--------------------- OPTIONS -----------------------------------------------
9.80665  g
1025.0   rhoW
80.0     WtrDpth
1.0e5    kBot
1.0e4    cBot
0.05     dtM
0.0      TMax
uniform 0.5 0.0 0.0  current
--------------------- OUTPUTS -----------------------------------------------
"FairTen1"
--------------------- need this line ----------------------------------------
"""


def static_profile(exe, work, counts):
    """Unstretched arc length, height and node tension of every node of the static state."""
    name = "m_" + "_".join(str(n) for n in counts)
    deck = work / f"{name}.dat"
    deck.write_text(DECK.format(n1=counts[0], n2=counts[1], n3=counts[2]), encoding="utf-8")
    run = subprocess.run([exe, str(deck), str(work / name)], capture_output=True, text=True, check=False)
    if run.returncode != 0:
        raise SystemExit(f"FAIL: the {name} deck did not solve (exit {run.returncode}):\n{run.stdout}{run.stderr}")
    lines = (work / f"{name}.static.out").read_text(encoding="utf-8").splitlines()
    header = lines[1].split()
    if "DeckNode" in header:
        raise SystemExit(f"FAIL: the static solve refined the {name} mesh")
    iz, it = header.index("Z"), header.index("Tension")
    rows = [line.split() for line in lines[3:] if line.strip()]
    arc = [0.0]
    start = 0.0
    for length, n in zip(LENGTHS, counts):
        arc += [start + length * k / n for k in range(1, n + 1)]
        start += length
    if len(rows) != len(arc):
        raise SystemExit(f"FAIL: {len(rows)} rows in {name}.static.out, expected {len(arc)}")
    return arc, [float(r[iz]) for r in rows], [float(r[it]) for r in rows]


def interpolate(xs, ys, x):
    k = min(max(bisect.bisect_left(xs, x), 1), len(xs) - 1)
    f = (x - xs[k - 1]) / (xs[k] - xs[k - 1])
    return ys[k - 1] + f * (ys[k] - ys[k - 1])


def local_error(exe, work, counts, reference):
    """Largest local tension error at touchdown, and the element size there."""
    arc, z, t = static_profile(exe, work, counts)
    first = next(j for j in range(1, len(z)) if z[j] <= FLOOR_Z + 1e-6 and z[j - 1] > FLOOR_Z + 1e-6)
    err = [t[j] - interpolate(reference[0], reference[1], arc[j]) for j in range(len(arc))]
    background = 0.5 * (err[first - 3] + err[first + 3])
    return max(abs(err[j] - background) for j in range(first - 1, first + 2)), arc[first] - arc[first - 1]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    exe = sys.argv[1]
    worst = []
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        r_arc, _, r_t = static_profile(exe, work, tuple(REFERENCE * n for n in BASE))
        for m in LEVELS:
            values = []
            for shift in SHIFTS:
                counts = (BASE[0] * m, BASE[1] * m, BASE[2] * m + shift)
                e, h = local_error(exe, work, counts, (r_arc, r_t))
                values.append(e)
            worst.append(max(values))
            listed = " ".join(f"{v:.3f}" for v in values)
            print(f"  {BASE[2] * m + SHIFTS[0]}-{BASE[2] * m + SHIFTS[-1]} elements in the touchdown section "
                  f"(about {h:.2f} m): local error {listed} N; largest {worst[-1]:.3f} N")
    rate = worst[-2] / max(worst[-1], 1e-12)
    print(f"  largest local error {worst[-2]:.3f} N -> {worst[-1]:.3f} N when the elements are halved: "
          f"ratio {rate:.2f} (at least {RATE}; second order 4)")
    failures = []
    if rate < RATE:
        failures.append(f"the local error fell by {rate:.2f} per halving of the elements (at least {RATE})")
    if worst[-1] > LIMIT:
        failures.append(f"local error {worst[-1]:.3f} N on the 0.4 m meshes (limit {LIMIT} N)")
    if failures:
        raise SystemExit("FAIL: node tension at touchdown does not converge at second order: " + "; ".join(failures))
    print("PASS: node tension at touchdown converges at second order wherever the touchdown point falls")


if __name__ == "__main__":
    main()
