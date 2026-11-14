#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Driver gates of the modal analysis (OPTION nModes) of finite-EI lines restrained in torsion.

1. A straight taut 10 m line (neutrally buoyant, no added mass), clamped (bending Rigid) and
   rigid in torsion at both ends, 40 elements: its four torsional modes among the 24 lowest
   (PolarShare > 0.5) are the lumped chain's 2 sqrt(GJ/Irn)/l0 sin(n pi/(2 NE)) and the
   continuum's n pi/L0 sqrt(GJ/Irn) within the chain's own error 1 - sin(x)/x,
   x = n pi/(2 NE); the first one's dTwist is sin(pi s/L0) with no translation; every other
   mode (bending, axial) has the frequency of the same deck with TorsStiffness Free and no
   twist. "Exact" comparisons allow 2e-8, the rounding of the table's nine digits. Turned 30
   degrees about +z, the line has the same frequencies, and the table its positions in the
   deck's axes.
2. tests/data/torsion_lazy_wave_modes.dat, the lazy wave twisted two turns, runs its modes:
   12 ascending, finite frequencies with PolarShare in [0, 1] and a dTwist column.
3. The straight line of 1 restrained in torsion at one end only, the other free to twist (End B
   free, then End A): its torsional modes are the clamped-free chain's
   2 sqrt(GJ/Irn)/l0 sin((2n - 1) pi/(4 NE)) (the free end's half polar mass is the mid-node of
   a clamped-clamped chain twice as long) and the continuum's quarter-wave (2n - 1) pi/(2 L0)
   sqrt(GJ/Irn) within the chain's own 1 - sin(x)/x, x = (2n - 1) pi/(4 NE); the first one's
   dTwist is sin(pi s/(2 L0)) from the restrained end, largest at the free end; the bending and
   axial modes are those of the TorsStiffness Free deck.
1 and 2 fail closed on a driver that refuses nModes with torsion, 3 on one that does not solve
the torsion of a line restrained at one end with nModes (no twist columns).
"""

from __future__ import annotations

import argparse
import math
import subprocess
from pathlib import Path

L0, NE, EA, EI, GJ, IRN, TENSION = 10.0, 40, 1.0e6, 100.0, 80.0, 0.04, 1000.0
RHO_W, DIAM = 1025.0, 0.1
N_MODES = 24
# the table writes nine significant digits
REL_EXACT = 2.0e-8


def straight_deck(torsion: str, heading_deg: float = 0.0, torsion_b: str | None = None) -> str:
    mass = RHO_W * math.pi * DIAM**2 / 4.0  # neutrally buoyant: the line stays straight
    span = L0 * (1.0 + TENSION / EA)
    c, s = math.cos(math.radians(heading_deg)), math.sin(math.radians(heading_deg))
    bar = "-" * 21
    return f"""{bar} CableDyn Input File {bar}
straight taut line clamped and restrained in torsion ({torsion}) at both ends
{bar} LINE TYPES {bar}
Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat
cab {DIAM!r} {mass!r} {EA!r} 0.0 {EI!r} 1.0e8 {GJ!r} 1.0 {IRN!r} 1.2 0.0 0.0 0.0
{bar} POINTS {bar}
ID Type X Y Z
1 Coupled 0.0 0.0 -100.0
2 Fixed {span * c!r} {span * s!r} -100.0
{bar} LINES {bar}
ID NodeA NodeB Outputs
1 1 2 -
{bar} SECTIONS {bar}
LineID LineType Length NumSegs
1 cab {L0!r} {NE}
{bar} END CONNECTIONS {bar}
LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist
1 A Rigid {c!r} {s!r} 0 {torsion} 0 0 1 0
1 B Rigid {c!r} {s!r} 0 {torsion if torsion_b is None else torsion_b} 0 0 1 0
{bar} OPTIONS {bar}
9.80665 g
{RHO_W!r} rhoW
500.0 WtrDpth
0.01 dtM
0.01 TMax
{N_MODES} nModes
{bar} OUTPUTS {bar}
FairTen1
{bar} need this line {bar}
"""


def read_modes(path: Path) -> tuple[list[str], list[list[float]], list[str], list[list[float]]]:
    """The frequency and mode-shape tables of a .modes.out file: (header, rows) for each."""
    lines = path.read_text(encoding="utf-8").splitlines()
    tables: list[tuple[list[str], list[list[float]]]] = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("# Natural frequencies") or lines[i].startswith("# Mode shapes"):
            header = lines[i + 1].split("\t")
            rows = []
            j = i + 3
            while j < len(lines) and not lines[j].startswith("#"):
                rows.append([float(x) for x in lines[j].split("\t")])
                j += 1
            tables.append((header, rows))
            i = j
        else:
            i += 1
    if len(tables) != 2:
        raise AssertionError(f"{path}: expected two tables, found {len(tables)}")
    return tables[0][0], tables[0][1], tables[1][0], tables[1][1]


def run(exe: str, deck: Path, root: Path) -> Path:
    proc = subprocess.run([exe, str(deck), str(root)], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise AssertionError(f"{deck.name}: driver exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
    return root.with_name(root.name + ".modes.out")


def check_straight(exe: str, out: Path) -> list[str]:
    failures: list[str] = []
    files = {}
    for torsion in ("Rigid", "Free"):
        deck = out / f"straight_{torsion.lower()}.dat"
        deck.write_text(straight_deck(torsion), encoding="utf-8")
        files[torsion] = run(exe, deck, out / f"straight_{torsion.lower()}")
    fh, freq, sh, shapes = read_modes(files["Rigid"])
    fh0, freq0, _, _ = read_modes(files["Free"])
    if fh[-1] != "PolarShare" or sh[-1] != "dTwist":
        failures.append(f"torsion deck: no PolarShare/dTwist columns ({fh}, {sh})")
        return failures
    if "PolarShare" in fh0:
        failures.append("the TorsStiffness Free deck writes twist columns")
    omega = [row[4] for row in freq]
    polar = [row[5] for row in freq]
    omega0 = [row[4] for row in freq0]
    l0 = L0 / NE
    n = 0
    other = []
    for j, (om, share) in enumerate(zip(omega, polar), start=1):
        if share > 0.5:
            n += 1
            x = n * math.pi / (2.0 * NE)
            chain = 2.0 * math.sqrt(GJ / IRN) / l0 * math.sin(x)
            cont = n * math.pi / L0 * math.sqrt(GJ / IRN)
            err_d, err_c = abs(om / chain - 1.0), abs(om / cont - 1.0)
            bound = 1.0 - math.sin(x) / x
            print(
                f"  torsional mode {n} (mode {j}): omega {om:.6f} rad/s, continuum {cont:.6f}, error "
                f"{err_c:.2e} (bound {1.01 * bound:.2e}), chain error {err_d:.2e}, polar share 1 - {1 - share:.1e}"
            )
            if err_d > REL_EXACT or err_c > 1.01 * bound + REL_EXACT or 1.0 - share > REL_EXACT:
                failures.append(f"torsional mode {n}: omega {om} against chain {chain}, continuum {cont}")
            if n == 1:
                rows = [r for r in shapes if int(r[1]) == j]
                twist = [r[9] for r in rows]
                trans = max(abs(v) for r in rows for v in r[6:9])
                ref = [math.sin(math.pi * k / NE) for k in range(NE + 1)]
                sign = 1.0 if twist[NE // 2] > 0.0 else -1.0
                err_s = max(abs(sign * t - r) for t, r in zip(twist, ref))
                print(f"  torsional mode 1 shape: dTwist against sin(pi s/L0) {err_s:.2e}, translations {trans:.1e}")
                if err_s > 1.0e-6 or trans > REL_EXACT:
                    failures.append(f"torsional mode 1 shape: {err_s}, translations {trans}")
        else:
            other.append((om, share))
    err_o = max(abs(om / om0 - 1.0) for (om, _), om0 in zip(other, omega0))
    mix = max(share for _, share in other)
    print(
        f"  {len(other)} bending/axial modes against TorsStiffness Free: {err_o:.2e}, largest polar share {mix:.1e}"
    )
    if n != 4:
        failures.append(f"expected 4 torsional modes among the {N_MODES} lowest, found {n}")
    if err_o > REL_EXACT or mix > REL_EXACT:
        failures.append(f"bending/axial modes differ from the Free deck by {err_o} (polar share {mix})")
    # the same line turned 30 degrees about +z: the same frequencies, positions in the deck's axes
    deck = out / "straight_heading.dat"
    deck.write_text(straight_deck("Rigid", 30.0), encoding="utf-8")
    _, freq_h, _, shapes_h = read_modes(run(exe, deck, out / "straight_heading"))
    err_h = max(abs(a[4] / b[4] - 1.0) for a, b in zip(freq_h, freq))
    c, s = math.cos(math.radians(30.0)), math.sin(math.radians(30.0))
    span = L0 * (1.0 + TENSION / EA)
    rows = [r for r in shapes_h if int(r[1]) == 1]
    err_x = max(
        abs(r[3] - span * c * k / NE) + abs(r[4] - span * s * k / NE) for k, r in enumerate(rows)
    )
    # the first mode is lateral: its translation is normal to the line's axis
    along = max(abs(r[6] * c + r[7] * s) for r in rows)
    print(f"  heading 30 deg: frequencies {err_h:.2e}, node positions {err_x:.1e} m, mode 1 axial "
          f"translation {along:.1e}")
    if err_h > REL_EXACT or err_x > 1.0e-6 or along > 1.0e-6:
        failures.append(f"heading 30 deg: frequencies {err_h}, positions {err_x}, axial {along}")
    return failures


def check_one_end(exe: str, out: Path) -> list[str]:
    failures: list[str] = []
    _, freq0, _, _ = read_modes(run_deck(exe, out, "straight_free", straight_deck("Free")))
    omega0 = [row[4] for row in freq0]
    l0 = L0 / NE
    for label, row_a, row_b in (("End B free", "Rigid", "Free"), ("End A free", "Free", "Rigid")):
        name = "one_end_" + label.split()[1].lower()
        fh, freq, sh, shapes = read_modes(run_deck(exe, out, name, straight_deck(row_a, torsion_b=row_b)))
        if fh[-1] != "PolarShare" or sh[-1] != "dTwist":
            failures.append(f"{label}: no PolarShare/dTwist columns ({fh}, {sh})")
            continue
        n = 0
        other = []
        for j, row in enumerate(freq, start=1):
            om, share = row[4], row[5]
            if share <= 0.5:
                other.append(om)
                continue
            n += 1
            x = (2 * n - 1) * math.pi / (4.0 * NE)
            chain = 2.0 * math.sqrt(GJ / IRN) / l0 * math.sin(x)
            cont = (2 * n - 1) * math.pi / (2.0 * L0) * math.sqrt(GJ / IRN)
            err_d, err_c = abs(om / chain - 1.0), abs(om / cont - 1.0)
            bound = 1.0 - math.sin(x) / x
            print(
                f"  {label}: torsional mode {n} (mode {j}): omega {om:.6f} rad/s, quarter-wave "
                f"{cont:.6f}, error {err_c:.2e} (bound {1.01 * bound:.2e}), clamped-free chain error "
                f"{err_d:.2e}, polar share 1 - {1 - share:.1e}"
            )
            if err_d > REL_EXACT or err_c > 1.01 * bound + REL_EXACT or 1.0 - share > REL_EXACT:
                failures.append(f"{label}: torsional mode {n}: omega {om}, chain {chain}, continuum {cont}")
            if n == 1:
                rows = [r for r in shapes if int(r[1]) == j]
                twist = [r[9] for r in rows]
                # the node index from End A; the restrained end is End A when End B is free
                ks = range(NE + 1) if row_a == "Rigid" else range(NE, -1, -1)
                ref = [math.sin(0.5 * math.pi * k / NE) for k in ks]
                sign = 1.0 if twist[NE // 2] * ref[NE // 2] > 0.0 else -1.0
                err_s = max(abs(sign * t - r) for t, r in zip(twist, ref))
                print(f"  {label}: torsional mode 1 shape against sin(pi s/(2 L0)) {err_s:.2e}")
                if err_s > 1.0e-6:
                    failures.append(f"{label}: torsional mode 1 shape {err_s}")
        err_o = max(abs(om / om0 - 1.0) for om, om0 in zip(other, omega0))
        print(f"  {label}: {n} torsional modes; {len(other)} others against TorsStiffness Free {err_o:.2e}")
        if n < 3:
            failures.append(f"{label}: expected at least 3 torsional modes among the {N_MODES} lowest, found {n}")
        if err_o > REL_EXACT:
            failures.append(f"{label}: bending/axial modes differ from the Free deck by {err_o}")
    return failures


def run_deck(exe: str, out: Path, name: str, text: str) -> Path:
    deck = out / f"{name}.dat"
    deck.write_text(text, encoding="utf-8")
    return run(exe, deck, out / name)


def check_lazy_wave(exe: str, source: Path, out: Path) -> list[str]:
    failures: list[str] = []
    path = run(exe, source / "tests" / "data" / "torsion_lazy_wave_modes.dat", out / "torsion_lazy_wave_modes")
    fh, freq, sh, shapes = read_modes(path)
    omega = [row[4] for row in freq]
    polar = [row[5] for row in freq]
    print(f"  twisted lazy wave: {len(omega)} modes, {omega[0]:.5f} to {omega[-1]:.5f} rad/s, polar share <= "
          f"{max(polar):.1e}")
    if fh[-1] != "PolarShare" or sh[-1] != "dTwist":
        failures.append("twisted lazy wave: no twist columns")
    if len(omega) != 12 or any(not math.isfinite(x) or x <= 0.0 for x in omega):
        failures.append(f"twisted lazy wave: frequencies {omega}")
    if any(b < a for a, b in zip(omega, omega[1:])):
        failures.append("twisted lazy wave: frequencies not ascending")
    if any(not 0.0 <= p <= 1.0 for p in polar):
        failures.append(f"twisted lazy wave: polar shares {polar}")
    if any(not math.isfinite(v) for r in shapes for v in r):
        failures.append("twisted lazy wave: non-finite mode shape")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    try:
        failures += check_straight(args.exe, args.output)
        failures += check_lazy_wave(args.exe, args.source, args.output)
        failures += check_one_end(args.exe, args.output)
    except AssertionError as exc:
        failures.append(str(exc))
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: modal analysis of decks with torsion")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
