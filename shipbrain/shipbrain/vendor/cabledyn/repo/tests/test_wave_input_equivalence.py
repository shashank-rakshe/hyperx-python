#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""One linear sea through three deck inputs: the line responds the same to each.

The studless chain of examples/dynamic_chain_waves.dat (410 m in 50 m), its fairlead held 5 m
below the still-water level, runs 40 s in the same sea written three ways, each read by its own
code path. (A node held at the waterline takes no kinematics while the surface is below it, so
its load switches with the sign of the elevation's last bit where a zero crossing falls on a
step: the representations then part by that switch.)

* the deck's own wave rows: ``airy H T dir waves``, or ``airy H T dir wavetrain`` rows for a sum,
  eta = (H/2) cos(k (x cos b + y sin b) - omega t);
* MoorDyn-C ``WaveKin 7``, ``wave_frequencies.txt`` rows ``omega Re Im beta``, each the component
  |c| sin(omega t - k d + arg c): the same wave is the row ``omega 0 H/2 b`` (c = i H/2);
* MoorDyn-C ``WaveKin 3``, the elevation record ``wave_elevation.txt`` at the origin,
  eta(t) = sum (H/2) cos(omega t), 200 s at dtWave 0.1 s: a whole number of periods of every
  component, so its Fourier reduction gives the components back exactly (waves along +X only).

Cases: a regular 2 m, 10 s wave along +X; a sum of 2 m at 10 s and 1 m at 8 s along +X; the
2 m, 10 s wave travelling at 30 deg to the line (the deck direction in degrees, MoorDyn-C's beta in
radians). Gates: every pair of inputs gives the same fairlead and anchor tensions and the same
node motion over the run, within 1e-6 of each channel's range (the record's Fourier reduction is
exact to round-off). The waves must load the line: each tension moves by more than 1 kN. A sign
error of the phase or the direction, a wrong amplitude convention or a lost component would put
the runs apart by the size of the response, and the gates can see it: the WaveKin 7 wave a
quarter period out of phase (c = H/2), and the oblique wave turned to +X, part from the deck
wave by more than 10 % of a tension range.

usage: test_wave_input_equivalence.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from cabledyn import read_output  # noqa: E402

FAILURES: list[str] = []
CHANNELS = ("FairTen1", "AnchTen1", "L1N6px", "L1N6pz", "L1N6py")
RELATIVE = 1.0e-6

DECK = """--------------------- CableDyn Input File ------------------------------------
wave input equivalence: held chain in one linear sea
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam    MassDenInAir   EA        BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)     (kg/m)         (N)       (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
chain      0.252   390.0          1.674e9   -1.0       0.0      1.37  0.64  1.0   0.0
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
1     Fixed     400.0    0.0    -50.0     0       0       0      0
2     Coupled   0.0      0.0    -5.0      0       0       0      0
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
1     2       1       -
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
1        chain      410.0    41
--------------------- OPTIONS ------------------------------------------
9.80665  g
1025.0   rhoW
50.0     WtrDpth
1.0e5    kBot
1.0e4    cBot
0.05     dtM
40.0     TMax
{options}
--------------------- OUTPUTS ------------------------------------------
{outputs}
--------------------- need this line -----------------------------------
"""


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def run(exe: Path, folder: Path, options: str, files: dict[str, str]) -> dict[str, np.ndarray]:
    """Run the deck with ``options`` and the kinematics ``files`` in ``folder``."""
    folder.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (folder / name).write_text(text, encoding="ascii", newline="\n")
    deck = folder / "deck.dat"
    text = DECK.format(options=options, outputs="\n".join(f'"{c}"' for c in CHANNELS))
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
    return {name: history.column(name) for name in CHANNELS}


def frequencies_file(components: list[tuple[float, float, float]]) -> str:
    """WaveKin 7 rows for components (H, T, direction in deg): the omega = 0 row first."""
    rows = ["0.0 0.0 0.0 0.0"]
    for height, period, direction in sorted(components, key=lambda c: c[1], reverse=True):
        omega = 2.0 * math.pi / period
        rows.append(f"{omega:.15g} 0.0 {0.5 * height:.15g} {math.radians(direction):.15g}")
    return "\n".join(rows) + "\n"


def elevation_file(components: list[tuple[float, float, float]]) -> str:
    """WaveKin 3 record at the origin: 2001 rows, 0 to 200 s at 0.1 s (waves along +X)."""
    rows = []
    for index in range(2001):
        t = 0.1 * index
        eta = sum(0.5 * h * math.cos(2.0 * math.pi * t / p) for h, p, _d in components)
        rows.append(f"{t:.1f} {eta:.15g}")
    return "\n".join(rows) + "\n"


def compare(case: str, runs: dict[str, dict[str, np.ndarray]]) -> None:
    names = list(runs)
    reference = runs[names[0]]
    if not reference:
        return
    for name in ("FairTen1", "AnchTen1"):
        span = float(np.ptp(reference[name]))
        check(span > 1.0e3, f"{case}: the waves load the line ({name} range {span:.4g} N)")
    for other in names[1:]:
        if not runs[other]:
            continue
        worst = 0.0
        for name in CHANNELS:
            a, b = reference[name], runs[other][name]
            scale = max(float(np.ptp(a)), 1.0e-3)
            worst = max(worst, float(np.max(np.abs(a - b))) / scale)
        check(
            worst <= RELATIVE,
            f"{case}: {names[0]} and {other} give the same response "
            f"(largest difference {worst:.3g} of a channel's range, limit {RELATIVE:g})",
        )


def differs(case: str, a: dict[str, np.ndarray], b: dict[str, np.ndarray]) -> None:
    """The gates resolve a wrong sea: the tensions of a and b part by more than 10 % of a range."""
    if not a or not b:
        return
    worst = max(
        float(np.max(np.abs(a[name] - b[name]))) / float(np.ptp(a[name]))
        for name in ("FairTen1", "AnchTen1")
    )
    check(worst > 0.1, f"{case} (largest difference {worst:.3g} of a tension range)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    exe = args.exe.resolve()
    out = args.output.resolve()
    common = "0 rampTime\n"

    # a regular wave along +X: the waves row, WaveKin 7 and WaveKin 3
    regular = [(2.0, 10.0, 0.0)]
    airy = run(exe, out / "regular_airy", common + "airy 2.0 10.0 0.0 waves", {})
    compare(
        "regular wave",
        {
            "airy waves": airy,
            "WaveKin 7": run(
                exe,
                out / "regular_wk7",
                common + "7 WaterKin",
                {"wave_frequencies.txt": frequencies_file(regular)},
            ),
            "WaveKin 3": run(
                exe,
                out / "regular_wk3",
                common + "3 WaterKin\n0.1 dtWave",
                {"wave_elevation.txt": elevation_file(regular)},
            ),
        },
    )

    # two components along +X: wavetrain rows, WaveKin 7 and WaveKin 3
    bimodal = [(2.0, 10.0, 0.0), (1.0, 8.0, 0.0)]
    trains = "\n".join(f"airy {h} {p} {d} wavetrain" for h, p, d in bimodal)
    compare(
        "two components",
        {
            "wavetrain rows": run(exe, out / "bimodal_trains", common + trains, {}),
            "WaveKin 7": run(
                exe,
                out / "bimodal_wk7",
                common + "7 WaterKin",
                {"wave_frequencies.txt": frequencies_file(bimodal)},
            ),
            "WaveKin 3": run(
                exe,
                out / "bimodal_wk3",
                common + "3 WaterKin\n0.1 dtWave",
                {"wave_elevation.txt": elevation_file(bimodal)},
            ),
        },
    )

    # a wave at 30 deg to the line: the deck direction against MoorDyn-C's beta
    oblique = [(2.0, 10.0, 30.0)]
    turned = run(exe, out / "oblique_airy", common + "airy 2.0 10.0 30.0 waves", {})
    compare(
        "oblique wave",
        {
            "airy waves": turned,
            "WaveKin 7": run(
                exe,
                out / "oblique_wk7",
                common + "7 WaterKin",
                {"wave_frequencies.txt": frequencies_file(oblique)},
            ),
        },
    )

    # the gates see a wrong phase and a wrong direction
    quadrature = "0.0 0.0 0.0 0.0\n0.628318530717959 1.0 0.0 0.0\n"
    shifted = run(
        exe, out / "quadrature_wk7", common + "7 WaterKin", {"wave_frequencies.txt": quadrature}
    )
    differs(
        "a WaveKin 7 wave a quarter period out of phase parts from the deck wave", airy, shifted
    )
    differs("the wave along +X parts from the oblique wave", turned, airy)

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
