#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""FAST.Farm shared-mooring A/B: CableDyn (Mod_SharedMooring = 5) vs stock MoorDyn (= 3).

Twin runs of OpenFAST's r-test case ``glue-codes/fast-farm/MD_Shared`` (two IEA-15 MW UMaine
turbines, three shared lines through two clumps, four anchor legs, steady 8 m/s wind, polar
wake, JONSWAP waves), identical except for the shared-mooring module. CableDyn reads the stock
MoorDyn deck ``SharedMooring2.dat`` unchanged.

``prepare`` copies the r-test folder twice and edits, identically in both copies except for
``Mod_SharedMooring``: ``TMax``, ``WrMooringVis False``, turbine ``WrVTK 0``, and the
anchor-leg anchor tensions ``AnchTen5``-``AnchTen7`` (the r-test deck writes ``AnchTen1``-
``AnchTen4`` only) and the clump position channels ``Point2p*``/``Point3p*`` added to the
deck's OUTPUTS. Run ``FAST.Farm.exe
FAST.Farm.fstf`` in each copy (one OpenMP thread), then ``compare``.

Channel pairing. MoorDyn writes ``FairTen<L>`` at the line's last node (deck ``AttachB``) and
``AnchTen<L>`` at its first (``AttachA``) for every line. CableDyn writes ``FairTen<L>`` at its
End A and ``AnchTen<L>`` at its End B, and swaps a stock line's ends only when ``AttachA`` is a
Fixed anchor. On the anchor legs 4-7 the names therefore agree; on the shared lines 1-3, which
have no Fixed end, the same physical end carries the opposite name, and ``compare`` pairs them
by end (both pairings are printed for the record).

Usage:
    python -I validation/scripts/fastfarm_shared_ab.py prepare --rtest <MD_Shared dir> \\
        --out <dir> [--tmax 600]
    python -I validation/scripts/fastfarm_shared_ab.py compare --md <md run dir> \\
        --cd <cd run dir> [--t-start 100] [--csv <file>]

Outputs compared (window t >= t-start): shared-line and anchor-leg tensions, clump positions,
and both turbines' platform motions; mean, std, min, max as (CD - MD)/|MD| and the RMS of the
difference over the MoorDyn std.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

import numpy as np

TURBINE_FILES = ("IEA-15-240-RWT-UMaineSemi_T1.fst", "IEA-15-240-RWT-UMaineSemi_T2.fst")


def die(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def set_value(text: str, key: str, value: str, what: str) -> str:
    """Replace the value field (first word) of the line whose key is `key`."""
    pat = re.compile(r"^(\s*)(\S+)(\s+" + re.escape(key) + r"\b)", re.M)
    new, n = pat.subn(lambda m: m.group(1) + value + m.group(3), text, count=1)
    if n != 1:
        die(f"{what}: key {key} not found")
    return new


def prepare(rtest: Path, out: Path, tmax: float) -> None:
    if not (rtest / "FAST.Farm.fstf").is_file():
        die(f"{rtest} is not the MD_Shared r-test folder (no FAST.Farm.fstf)")
    for tag, mod in (("md", 3), ("cd", 5)):
        run = out / tag
        if run.exists():
            die(f"{run} exists; choose an empty --out")
        shutil.copytree(rtest, run, ignore=shutil.ignore_patterns("*.out", "*.outb", "*.vtp"))
        fstf = run / "FAST.Farm.fstf"
        t = fstf.read_text()
        t = set_value(t, "TMax", f"{tmax:.1f}", fstf.name)
        t = set_value(t, "Mod_SharedMooring", str(mod), fstf.name)
        t = set_value(t, "WrMooringVis", "False", fstf.name)
        fstf.write_text(t)
        for name in TURBINE_FILES:
            f = run / name
            f.write_text(set_value(f.read_text(), "WrVTK", "0", name))
        deck = run / "SharedMooring2.dat"
        t = deck.read_text()
        marker = "FairTen7\n"
        if marker not in t:
            die("SharedMooring2.dat: OUTPUTS marker FairTen7 not found")
        extra = "".join(f"AnchTen{line}\n" for line in (5, 6, 7))
        extra += "".join(f"Point{p}p{c}\n" for p in (2, 3) for c in "xyz")
        deck.write_text(t.replace(marker, marker + extra, 1))
        print(f"prepared {run} (Mod_SharedMooring = {mod}, TMax = {tmax:g} s)")


def read_table(path: Path) -> dict[str, np.ndarray]:
    """A FAST-style or CableDyn table: a 'Time' header row, a units row, then numbers."""
    if not path.is_file():
        die(f"missing output {path}")
    lines = path.read_text().splitlines()
    try:
        i = next(k for k, line in enumerate(lines) if line.split() and line.split()[0] == "Time")
    except StopIteration:
        die(f"{path}: no 'Time' header")
    names = lines[i].split()
    data = np.array([line.split() for line in lines[i + 2 :] if line.strip()], dtype=float)
    if data.ndim != 2 or data.shape[1] != len(names) or not np.all(np.isfinite(data)):
        die(f"{path}: malformed or non-finite table")
    return {n.upper(): data[:, j] for j, n in enumerate(names)}


def run_tmax(run: Path) -> float:
    """TMax of a prepared run folder, from its FAST.Farm.fstf."""
    fstf = run / "FAST.Farm.fstf"
    if not fstf.is_file():
        die(f"missing {fstf}")
    m = re.search(r"^\s*(\S+)\s+TMax\b", fstf.read_text(), re.M)
    if not m:
        die(f"{fstf}: no TMax")
    return float(m.group(1))


def require_complete(table: dict, tmax: float, what: str) -> None:
    """A run that stopped early would leave a shorter shared window: refuse it by name. A
    complete table ends within one output interval of TMax (FAST.Farm's MoorDyn output omits
    the last row)."""
    t = table["TIME"]
    if t.size < 2:
        die(f"{what} has fewer than two rows")
    t_end = float(t[-1])
    dt_out = float(np.median(np.diff(t)))
    if t_end < tmax - 1.5 * dt_out:
        die(f"{what} ends at t = {t_end:g} s, before TMax = {tmax:g} s (incomplete run)")


def align(a: dict, b: dict, t0: float, cadence_ms: int = 50) -> tuple[np.ndarray, np.ndarray]:
    """Indices of the samples both tables share on a 1 ms grid, every cadence_ms, from t0."""
    ta = np.round(a["TIME"] * 1000).astype(np.int64)
    tb = np.round(b["TIME"] * 1000).astype(np.int64)
    common, ia, ib = np.intersect1d(ta, tb, return_indices=True)
    keep = (common >= round(t0 * 1000)) & (common % cadence_ms == 0)
    if not np.any(keep):
        die("the two runs share no samples in the window")
    return ia[keep], ib[keep]


def row(label: str, xm: np.ndarray, xc: np.ndarray) -> dict:
    sm = np.array([xm.mean(), xm.std(), xm.min(), xm.max()])
    sc = np.array([xc.mean(), xc.std(), xc.min(), xc.max()])
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.where(np.abs(sm) > 0, (sc - sm) / np.abs(sm), np.nan)
    rms = float(np.sqrt(np.mean((xc - xm) ** 2)))
    return {"channel": label, "md": sm, "cd": sc, "rel": rel,
            "rms_over_std": rms / sm[1] if sm[1] > 0 else np.nan}


def compare(md_dir: Path, cd_dir: Path, t0: float, csv: Path | None) -> None:
    tmax = run_tmax(md_dir)
    if abs(run_tmax(cd_dir) - tmax) > 1.0e-9 * max(1.0, tmax):
        die("the two runs have different TMax")
    md = read_table(md_dir / "FAST.Farm.FarmMD.MD.out")
    cd = read_table(cd_dir / "FAST.Farm.FarmCD.out")
    require_complete(md, tmax, "MoorDyn mooring output")
    require_complete(cd, tmax, "CableDyn mooring output")
    ia, ib = align(md, cd, t0)
    pairs = []
    ends = {1: ("T1 fairlead", "clump 2"), 2: ("clump 2", "clump 3"), 3: ("clump 3", "T2 fairlead")}
    for line, (a, b) in ends.items():
        pairs.append((f"L{line} end A, {a} [MD AnchTen{line} / CD FairTen{line}]",
                      f"ANCHTEN{line}", f"FAIRTEN{line}"))
        pairs.append((f"L{line} end B, {b} [MD FairTen{line} / CD AnchTen{line}]",
                      f"FAIRTEN{line}", f"ANCHTEN{line}"))
    for line in (4, 5, 6, 7):
        pairs.append((f"L{line} anchor [AnchTen{line}]", f"ANCHTEN{line}", f"ANCHTEN{line}"))
        pairs.append((f"L{line} fairlead [FairTen{line}]", f"FAIRTEN{line}", f"FAIRTEN{line}"))
    for p in (2, 3):
        for c in "XYZ":
            pairs.append((f"Point{p}p{c.lower()} (clump)", f"POINT{p}P{c}", f"POINT{p}P{c}"))
    rows = []
    for label, km, kc in pairs:
        if km not in md or kc not in cd:
            die(f"channel {km} / {kc} missing (run 'prepare' first)")
        rows.append(row(label, md[km][ia], cd[kc][ib]))
    same = [row(f"same name {k}{line}", md[f"{k}{line}"][ia], cd[f"{k}{line}"][ib])
            for line in (1, 2, 3) for k in ("FAIRTEN", "ANCHTEN")]
    for tw in ("T1", "T2"):
        a = read_table(md_dir / f"FAST.Farm.{tw}.out")
        b = read_table(cd_dir / f"FAST.Farm.{tw}.out")
        require_complete(a, tmax, f"MoorDyn run {tw} output")
        require_complete(b, tmax, f"CableDyn run {tw} output")
        ja, jb = align(a, b, t0)
        for ch in ("PtfmSurge", "PtfmSway", "PtfmHeave", "PtfmRoll", "PtfmPitch", "PtfmYaw"):
            rows.append(row(f"{tw} {ch}", a[ch.upper()][ja], b[ch.upper()][jb]))
    print(f"window t >= {t0:g} s; % = (CD - MD)/|MD|; rms/std = RMS(CD - MD)/std(MD)")
    print(f"{'channel':54s} {'MD mean':>11s} {'mean%':>8s} {'std%':>8s} {'min%':>8s} {'max%':>8s} {'rms/std':>8s}")
    lines = ["channel,MD_mean,CD_mean,MD_std,CD_std,MD_min,CD_min,MD_max,CD_max,"
             "rel_mean,rel_std,rel_min,rel_max,rms_over_std"]
    for r in rows + same:
        m, c, rel = r["md"], r["cd"], 100 * r["rel"]
        print(f"{r['channel']:54s} {m[0]:11.5g} {rel[0]:8.3f} {rel[1]:8.2f} {rel[2]:8.3f} "
              f"{rel[3]:8.3f} {r['rms_over_std']:8.3f}")
        vals = [m[0], c[0], m[1], c[1], m[2], c[2], m[3], c[3], *r["rel"], r["rms_over_std"]]
        lines.append(",".join([f'"{r["channel"]}"'] + [f"{v:.8g}" for v in vals]))
    if csv:
        csv.write_text("\n".join(lines) + "\n")
        print(f"wrote {csv}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare", help="copy and edit the r-test case for both modules")
    p.add_argument("--rtest", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--tmax", type=float, default=600.0)
    c = sub.add_parser("compare", help="compare the MoorDyn and CableDyn runs")
    c.add_argument("--md", type=Path, required=True)
    c.add_argument("--cd", type=Path, required=True)
    c.add_argument("--t-start", type=float, default=100.0)
    c.add_argument("--csv", type=Path)
    args = ap.parse_args()
    if args.cmd == "prepare":
        prepare(args.rtest, args.out, args.tmax)
    else:
        compare(args.md, args.cd, args.t_start, args.csv)


if __name__ == "__main__":
    main()
