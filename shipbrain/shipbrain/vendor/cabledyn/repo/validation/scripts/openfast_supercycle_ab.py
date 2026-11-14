#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Supercycling A/B: coupled CableDyn runs at a coarser dtM against the same model at dtM = DT.

Twin OpenFAST runs of the SAME model and environment differ only in the CableDyn time step (and,
with dtM larger than DT, in how the coupled loads are served between CableDyn solves: deck
OPTIONS predictLoads True extrapolates them, False holds them). The reference is the run at
dtM = DT. Over the window t >= t_start, on the common grid of the coarsest committed CableDyn
samples (--grid, default 0.1 s), the script reports per channel:

  * platform DOFs (glue <root>.out): mean, std, max and the RMS of the time-series difference
    relative to the reference std;
  * fairlead and anchor tensions (CableDyn <root>.CD.out, committed samples): the same, plus the
    damage-equivalent load DEL = (sum n_i S_i^m / T)^(1/m) from a rainflow count (ASTM E1049,
    four-point method, residue counted as half cycles; a plateau of equal samples at the
    output precision counts as one turning point), slope m (--slope, default 3 for steel chain),
    1 Hz equivalent count, and its change against the reference DEL over the same samples.

Every statistic of a run is taken over the samples it shares with the reference; a run that
covers fewer of them (a shorter run, missing rows) is flagged in the report.

It also reports the reference DEL at its native sampling against the common grid, the part of
a DEL difference that is sampling alone. It reports; it does not gate.

Usage:
    python validation/scripts/openfast_supercycle_ab.py REF_ROOT LABEL=ROOT [LABEL=ROOT ...]
        [--t-start 200] [--grid 0.1] [--slope 3]
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

PLATFORM = ["PtfmSurge", "PtfmSway", "PtfmHeave", "PtfmRoll", "PtfmPitch", "PtfmYaw"]
TENSION_PREFIXES = ("FairTen", "AnchTen")


def read_table(path: Path) -> tuple[list[str], list[list[float]]]:
    """An OpenFAST or CableDyn text table: the header row starting with Time, the units row,
    then numeric rows (rows that do not parse to the header width are skipped)."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    hi = next((i for i, ln in enumerate(lines) if ln.split()[:1] == ["Time"]), -1)
    if hi < 0:
        raise ValueError(f"{path}: no Time header row")
    names = lines[hi].split()
    rows = []
    for ln in lines[hi + 2:]:
        parts = ln.split()
        if len(parts) != len(names):
            continue
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    return names, rows


def on_grid(rows: list[list[float]], step: float, t_start: float) -> dict[int, list[float]]:
    """The rows at whole multiples of step from t_start on, keyed by the multiple."""
    out = {}
    for row in rows:
        k = round(row[0] / step)
        if abs(row[0] - step * k) < 1e-6 and row[0] >= t_start - 1e-9:
            out[k] = row
    return out


def turning_points(x: list[float]) -> list[float]:
    """Peaks and valleys of x; a plateau of equal neighbours counts once."""
    y = [v for i, v in enumerate(x) if i == 0 or v != x[i - 1]]
    if len(y) < 3:
        return y
    out = [y[0]]
    for i in range(1, len(y) - 1):
        if (y[i] - y[i - 1]) * (y[i + 1] - y[i]) < 0.0:
            out.append(y[i])
    out.append(y[-1])
    return out


def rainflow(x: list[float]) -> list[tuple[float, float]]:
    """(range, count) pairs: full cycles by the four-point method, the residue as half cycles."""
    stack: list[float] = []
    out: list[tuple[float, float]] = []
    for v in turning_points(x):
        stack.append(v)
        while len(stack) >= 4:
            s0, s1, s2, s3 = stack[-4:]
            inner = abs(s2 - s1)
            if inner <= abs(s1 - s0) and inner <= abs(s3 - s2):
                out.append((inner, 1.0))
                del stack[-3:-1]
            else:
                break
    out.extend((abs(b - a), 0.5) for a, b in zip(stack[:-1], stack[1:]))
    return out


def damage_equivalent_load(x: list[float], duration: float, slope: float) -> float:
    """DEL at a 1 Hz equivalent count over duration seconds; zero for a history without cycles
    or without duration."""
    total = sum(n * r ** slope for r, n in rainflow(x))
    if total <= 0.0 or duration <= 0.0:
        return 0.0
    return (total / duration) ** (1.0 / slope)


def relative_change(value: float, reference: float) -> float:
    """100 (value/reference - 1); 0 when both are zero, NaN (undefined) when only the reference is."""
    if reference == 0.0:
        return 0.0 if value == 0.0 else math.nan
    return 100.0 * (value / reference - 1.0)


def mean_std(x: list[float]) -> tuple[float, float]:
    m = sum(x) / len(x)
    return m, math.sqrt(sum((v - m) ** 2 for v in x) / len(x))


def compare_channel(grid: dict[int, list[float]], j: int, ref_grid: dict[int, list[float]], jr: int,
                    step: float, slope: float | None) -> dict[str, float] | None:
    """One channel of a run against the reference over the samples BOTH have: mean, std and max of
    the run, the RMS of the difference over the reference std, and (slope given) the run's DEL and
    its change against the reference DEL over the same samples and duration (relative_change).
    covered is the fraction of the reference samples the run has; None when the two share fewer
    than two samples."""
    keys = sorted(set(grid) & set(ref_grid))
    if len(keys) < 2:
        return None
    x = [grid[k][j] for k in keys]
    xr = [ref_grid[k][jr] for k in keys]
    m, s = mean_std(x)
    _, sr = mean_std(xr)
    out = {"mean": m, "std": s, "max": max(x), "covered": len(keys) / len(ref_grid),
           "rel": math.sqrt(sum((p - q) ** 2 for p, q in zip(x, xr)) / len(x)) / max(sr, 1e-30)}
    if slope is not None:
        duration = (keys[-1] - keys[0]) * step
        out["del"] = damage_equivalent_load(x, duration, slope)
        out["ddel"] = relative_change(out["del"], damage_equivalent_load(xr, duration, slope))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref", help="root of the dtM = DT run (<root>.out and <root>.CD.out)")
    ap.add_argument("runs", nargs="+", help="LABEL=ROOT of a run to compare (split at the last =)")
    ap.add_argument("--t-start", type=float, default=200.0)
    ap.add_argument("--grid", type=float, default=0.1)
    ap.add_argument("--slope", type=float, default=3.0)
    a = ap.parse_args()

    runs = [("dtM = DT (reference)", a.ref)] + [tuple(r.rsplit("=", 1)) for r in a.runs]
    tables = {}
    for label, root in runs:
        of_names, of_rows = read_table(Path(root + ".out"))
        cd_names, cd_rows = read_table(Path(root + ".CD.out"))
        tables[label] = (of_names, on_grid(of_rows, a.grid, a.t_start), cd_names,
                         on_grid(cd_rows, a.grid, a.t_start), cd_rows)
    ref_label = runs[0][0]
    ref = tables[ref_label]
    tension = [n for n in ref[2] if n.startswith(TENSION_PREFIXES)]
    print(f"window t >= {a.t_start:g} s on the common {a.grid:g} s grid; DEL slope m = {a.slope:g}, "
          "1 Hz equivalent count")
    print(f"{'channel':<11} {'run':<28} {'mean':>12} {'std':>11} {'max':>12} {'RMSdiff/std':>11} "
          f"{'DEL':>11} {'dDEL':>8}")
    for ch, kind in [(c, 0) for c in PLATFORM] + [(c, 2) for c in tension]:
        rnames, rgrid = ref[kind], ref[kind + 1]
        if ch not in rnames:
            continue
        jr = rnames.index(ch)
        for label, tab in tables.items():
            names, grid = tab[kind], tab[kind + 1]
            if ch not in names:
                continue
            c = compare_channel(grid, names.index(ch), rgrid, jr, a.grid, a.slope if kind == 2 else None)
            if c is None:
                print(f"{ch:<11} {label:<28} no common samples with the reference")
                continue
            line = f"{ch:<11} {label:<28} {c['mean']:12.5e} {c['std']:11.4e} {c['max']:12.5e} {c['rel']:11.4f}"
            if kind == 2:
                change = "    n/a" if math.isnan(c["ddel"]) else f"{c['ddel']:7.2f}%"
                line += f" {c['del']:11.4e} {change}"
            if c["covered"] < 1.0:
                line += f"  (covers {100.0 * c['covered']:.1f} % of the reference samples; compared over those)"
            print(line)
        print()
    print("reference DEL at its native sampling against the common grid (sampling alone):")
    names, grid, rows = ref[2], ref[3], ref[4]
    window = [r for r in rows if r[0] >= a.t_start - 1e-9]
    if len(window) < 2 or len(grid) < 2:
        print("  (fewer than two reference samples in the window)")
        return 0
    for ch in tension:
        j = names.index(ch)
        native = damage_equivalent_load([r[j] for r in window], window[-1][0] - window[0][0], a.slope)
        keys = sorted(grid)
        coarse = damage_equivalent_load([grid[k][j] for k in keys], (keys[-1] - keys[0]) * a.grid, a.slope)
        print(f"  {ch:<9} native {native:.4e}  grid {coarse:.4e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
