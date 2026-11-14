#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A cylindrical bend stiffener is a section of the combined cable and sleeve.

The 80 m Gulf of Mexico lazy-wave cable (examples/lozon_gomex80_power_cable_motion.dat, bare
cable D 0.16 m, 36.7 kg/m, EI 1.99e4 N m^2) is clamped at its hang-off 5 deg off its static
tangent, so the root carries a moment, and driven 18 s by the 3 m, 12 s hang-off heave. Its first
2 m are sleeved in two ways:

* a STIFFENERS row: a cylinder of 0.30 m outer diameter bored to the cable's 0.16 m, E 50 MPa,
  1150 kg/m^3, over the bare cable;
* a 2 m SECTIONS row of a line type with the section's own values, worked out here from the
  manual's closed forms: EI = EI_c + E pi/64 (OD^4 - ID^4), mass m_c + rho_s pi/4 (OD^2 - ID^2)
  and the displaced diameter sqrt(d^2 + OD^2 - ID^2) (= OD), the drag and added-mass
  coefficients of the cable.

Both decks mesh the 2 m in 20 elements. Gates, in the static start and over the march: the end
tensions, the hang-off angle, the position of a node in the sag bend and the curvature at nodes
under the sleeve and past it agree within 1e-6 of each channel's scale; the root moment of the
section, BendMom1N1 of the section deck, is the sum of the cable's share and the sleeve's,
BendMom1N1 + StfMom1N1 of the stiffener deck, and the cable's share is EI_c/EI of it. The bare
cable clamped the same way carries the static root moment of a tensioned beam whose end is
turned by the angle a, M = a sqrt(EI T) (its bending boundary layer, sqrt(EI/T) = 1.4 m long,
is short against the 180 m bend radius of the catenary), within 2 %; the sleeve must matter:
the static root moment of the section exceeds it by more than 25 %.

usage: test_stiffener_section_equivalence.py --exe <cabledyn> --examples <examples> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from cabledyn import read_output  # noqa: E402

FAILURES: list[str] = []
RELATIVE = 1.0e-6
D, MASS, EA, EI = 0.160, 36.70, 4.69e8, 1.99e4
OD, ID, E_SLEEVE, RHO_SLEEVE, LENGTH = 0.30, 0.16, 5.0e7, 1150.0, 2.0
EI_SECTION = EI + E_SLEEVE * math.pi / 64.0 * (OD**4 - ID**4)
MASS_SECTION = MASS + RHO_SLEEVE * math.pi / 4.0 * (OD**2 - ID**2)
D_SECTION = math.sqrt(D**2 + OD**2 - ID**2)
TILT = math.radians(5.0)

DECK = """--------------------- CableDyn Input File ------------------------------------
stiffener against an equivalent section
--------------------- LINE TYPES ---------------------------------------------
TypeName  Diam   MassDenInAir  EA       BA   EI       Cd_n Cd_t Ca_n Ca_t
(-)       (m)    (kg/m)        (N)      (-)  (N-m2)   (-)  (-)  (-)  (-)
bare      0.160  36.70         4.69e8   0.0  1.99e4   1.2  0.1  1.0  0.0
buoy      0.290  59.53         4.69e8   0.0  1.99e4   1.2  0.1  1.0  0.0
sleeved   {d_sec:.15g}  {m_sec:.15g}  4.69e8   0.0  {ei_sec:.15g}  1.2  0.1  1.0  0.0
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
1       {first}  2.0      20
1       bare      66.114   33
1       buoy      50.000   25
1       bare      52.101   26
{stiffener}--------------------- END CONNECTIONS ---------------------------------------
LineID  End  Stiffness  EzX     EzY  EzZ
(-)     (-)  (N-m/rad)  (-)     (-)  (-)
1       A    Rigid      {ex:.15g}  0.0  {ez:.15g}
--------------------- OPTIONS -----------------------------------------------
9.80665  g
1025.0   rhoW
80.0     WtrDpth
1.0e5    kBot
1.0e4    cBot
0.05     dtM
18.0     TMax
gomex80_heave_3m_12s_dt005.txt motionFile
--------------------- OUTPUTS -----------------------------------------------
{outputs}
--------------------- need this line ----------------------------------------
"""
STIFFENER = """--------------------- STIFFENERS --------------------------------------------
LineID  End  Length  RootOD  TipOD  InnerD  E       Density
(-)     (-)  (m)     (m)     (m)    (m)     (Pa)    (kg/m^3)
1       A    2.0     0.30    0.30   0.16    5.0e7   1150
"""
SHARED = ("FairTen1", "AnchTen1", "FairIncl1", "L1N60px", "L1N60pz", "Curv1N11", "Curv1N30")


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def run(
    exe: Path, motion: Path, folder: Path, first: str, stiffener: str, outputs: tuple[str, ...]
):
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(motion, folder / motion.name)
    # the clamp turned 5 deg upward from the static hang-off tangent (81.6 deg below horizontal)
    angle = math.atan2(0.98922, 0.14641) - TILT
    text = DECK.format(
        d_sec=D_SECTION,
        m_sec=MASS_SECTION,
        ei_sec=EI_SECTION,
        first=f"{first:9s}",
        stiffener=stiffener,
        ex=math.cos(angle),
        ez=-math.sin(angle),
        outputs="\n".join(f'"{name}"' for name in outputs),
    )
    deck = folder / "deck.dat"
    deck.write_text(text, encoding="ascii", newline="\n")
    result = subprocess.run(
        [str(exe), deck.name, str(folder / "run")],
        cwd=folder,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        check(False, f"{folder.name}: driver exit {result.returncode}\n{result.stderr[-2000:]}")
        return {}
    history = read_output(folder / "run.out")
    return {name: history.column(name) for name in outputs}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--examples", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    exe = args.exe.resolve()
    out = args.output.resolve()
    motion = args.examples.resolve() / "data" / "lozon" / "gomex80_heave_3m_12s_dt005.txt"

    sleeve = run(
        exe, motion, out / "stiffener", "bare", STIFFENER, (*SHARED, "BendMom1N1", "StfMom1N1")
    )
    section = run(exe, motion, out / "section", "sleeved", "", (*SHARED, "BendMom1N1"))
    bare = run(exe, motion, out / "bare", "bare", "", ("BendMom1N1", "FairTen1"))
    if not (sleeve and section and bare):
        return 1

    for name in SHARED:
        a, b = sleeve[name], section[name]
        scale = max(float(np.max(np.abs(b))), 1.0e-12)
        start = abs(a[0] - b[0]) / scale
        march = float(np.max(np.abs(a - b))) / scale
        check(
            max(start, march) <= RELATIVE,
            f"{name}: the stiffener and the section agree (static {start:.2e}, march {march:.2e} "
            f"of {scale:.4g}, limit {RELATIVE:g})",
        )

    root = section["BendMom1N1"]
    scale = float(np.max(np.abs(root)))
    total = sleeve["BendMom1N1"] + sleeve["StfMom1N1"]
    worst = float(np.max(np.abs(total - root))) / scale
    check(
        worst <= RELATIVE,
        f"root moment: cable + sleeve shares are the section's moment ({worst:.2e} of {scale:.4g} N m)",
    )
    share = float(np.max(np.abs(sleeve["BendMom1N1"] - EI / EI_SECTION * root))) / scale
    check(
        share <= RELATIVE,
        f"root moment: the cable's share is EI_c/EI = {EI / EI_SECTION:.4f} of it ({share:.2e})",
    )
    # the bare clamp: a tensioned beam turned by TILT at its end, M = TILT sqrt(EI T)
    bare_root = float(bare["BendMom1N1"][0])
    expected = TILT * math.sqrt(EI * float(bare["FairTen1"][0]))
    check(
        abs(bare_root / expected - 1.0) < 0.02,
        f"bare clamp: static root moment {bare_root:.5g} N m is TILT sqrt(EI T) = {expected:.5g}",
    )
    check(
        root[0] > 1.25 * bare_root,
        f"the sleeve stiffens the root: static moment {root[0]:.5g} against {bare_root:.5g} N m",
    )
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
