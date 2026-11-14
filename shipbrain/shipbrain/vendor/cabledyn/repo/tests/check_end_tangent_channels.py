# SPDX-License-Identifier: Apache-2.0
"""The tangent outputs of a finite-EI line clamped at End A, through the standalone driver
(driver_end_tangent_channels in CMakeLists.txt).

A cable is clamped at End A (END CONNECTIONS Rigid) along a set direction, swept over
declinations of 120 to 180 deg and azimuths of 0 and 20 deg, and pinned at End B. Every output
of the end tangent must equal the clamp's angles to round-off (1e-6 deg, the printed digits
allowing): the FairDecl, FairIncl, L1N1Dec and L1N1Azi channels, the first row of
the static profile (Declination, Inclination, Azimuth), the range graph's DeclinationMin and
DeclinationMax at node 1 over a short held march, and the ``line tangent`` line of the
initialisation report. The line bends within its first element at the clamp, where a
difference of node positions reads several degrees off. The same deck with an EI = 0 chain
beside the cable runs on the mixed route, whose fairlead report must give the clamp too.

Usage: check_end_tangent_channels.py <cabledyn executable>
"""

import math
import pathlib
import re
import subprocess
import sys
import tempfile

DECLINATIONS = (180.0, 165.0, 150.0, 135.0, 120.0)
AZIMUTHS = (0.0, 20.0)
TOL = 1.0e-6
CHANNELS = ("FairDecl1", "FairIncl1", "L1N1Dec", "L1N1Azi")


def deck(dec: float, azi: float, mixed: bool) -> str:
    d, a = math.radians(dec), math.radians(azi)
    ez = (math.sin(d) * math.cos(a), math.sin(d) * math.sin(a), math.cos(d))
    types = "cable 0.2 60.0 1.0e8 -1.0 1.0e4 1.2 0.008 1.0 0.0\n"
    points = "1 Coupled 0.0 0.0 -10.0 0 0 0 0\n2 Fixed 80.0 0.0 -80.0 0 0 0 0\n"
    lines = "1 1 2 r\n"
    sections = "1 cable 125.0 100\n"
    if mixed:
        types += "chain 0.1 20.0 5.0e8 -1.0 0.0 1.2 0.4 1.0 0.0\n"
        points += "3 Coupled 0.0 50.0 -10.0 0 0 0 0\n4 Fixed 80.0 50.0 -80.0 0 0 0 0\n"
        lines = "1 1 2 -\n2 3 4 -\n"
        sections += "2 chain 125.0 40\n"
    outputs = "".join(f'"{c}"\n' for c in CHANNELS)
    return f"""--------------------- CableDyn Input File ------------------------------------
tangent outputs of a cable clamped at End A
--------------------- LINE TYPES ---------------------------------------------
TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)
{types}--------------------- POINTS -------------------------------------------------
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)
{points}--------------------- LINES --------------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
{lines}--------------------- SECTIONS -----------------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
{sections}--------------------- END CONNECTIONS ----------------------------------------
LineID End Stiffness EzX EzY EzZ
(-) (-) (N-m/rad) (-) (-) (-)
1 A Rigid {ez[0]:.17g} {ez[1]:.17g} {ez[2]:.17g}
--------------------- OPTIONS ------------------------------------------------
9.80665 g
1025.0 rhoW
0.05 dtM
{0.0 if mixed else 0.1} TMax
--------------------- OUTPUTS ------------------------------------------------
{outputs}END
"""


def table(path: pathlib.Path, skip: int) -> tuple[list[str], list[list[float]]]:
    rows = path.read_text().splitlines()
    names = [n.split("(")[0] for n in rows[1].split()]
    return names, [[float(v) for v in r.split()] for r in rows[skip:] if r.strip()]


def main() -> int:
    exe = sys.argv[1]
    failures = []

    def check(ok: bool, what: str, got: float, want: float) -> None:
        print(("ok   " if ok else "FAIL ") + f"{what}: {got:.9f} deg (clamp {want:.9f})")
        if not ok:
            failures.append(what)

    with tempfile.TemporaryDirectory() as folder:
        tmp = pathlib.Path(folder)
        for dec in DECLINATIONS:
            for azi in AZIMUTHS if dec < 180.0 else (0.0,):
                tag = f"d{dec:g}_a{azi:g}"
                want = {"FairDecl1": dec, "FairIncl1": dec - 90.0, "L1N1Dec": dec,
                        "L1N1Azi": azi}
                for mixed in (False, True):
                    name = tag + ("_mixed" if mixed else "")
                    (tmp / f"{name}.dat").write_text(deck(dec, azi, mixed))
                    proc = subprocess.run([exe, f"{name}.dat", name], cwd=tmp, capture_output=True, text=True)
                    if proc.returncode != 0:
                        failures.append(f"{name}: the driver failed")
                        print(f"FAIL {name}: the driver failed:\n{(proc.stdout + proc.stderr)[-1500:]}")
                        continue
                    log = proc.stdout + proc.stderr
                    if mixed:
                        match = re.search(r"Line 1: FairTen=\s*\S+ N, tangent inclination=\s*(\S+) deg", log)
                        got = float(match.group(1)) if match else math.nan
                        check(abs(got - (dec - 90.0)) <= 1.0e-3, f"{name} mixed report inclination", got, dec - 90.0)
                        continue
                    names, rows = table(tmp / f"{name}.out", 2)
                    for ch in CHANNELS:
                        if ch == "L1N1Azi" and dec == 180.0:
                            continue
                        got = rows[0][names.index(ch)]
                        check(abs(got - want[ch]) <= TOL, f"{name} {ch} at t = 0", got, want[ch])
                    names, rows = table(tmp / f"{name}.static.out", 3)
                    first = rows[0]
                    check(abs(first[names.index("Declination")] - dec) <= TOL, f"{name} static Declination",
                          first[names.index("Declination")], dec)
                    check(abs(first[names.index("Inclination")] - (dec - 90.0)) <= TOL,
                          f"{name} static Inclination", first[names.index("Inclination")], dec - 90.0)
                    if dec < 180.0:
                        check(abs(first[names.index("Azimuth")] - azi) <= TOL, f"{name} static Azimuth",
                              first[names.index("Azimuth")], azi)
                    names, rows = table(tmp / f"{name}.Line1.range.out", 3)
                    for col in ("DeclinationMin", "DeclinationMax"):
                        got = rows[0][names.index(col)]
                        check(abs(got - dec) <= TOL, f"{name} range {col}", got, dec)
                    match = re.search(r"line tangent: inclination=\s*(\S+) deg, declination=\s*(\S+) deg", log)
                    got = float(match.group(2)) if match else math.nan
                    check(abs(got - dec) <= 1.0e-3, f"{name} report declination", got, dec)
    print("PASS" if not failures else f"FAIL: {len(failures)} check(s)")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
