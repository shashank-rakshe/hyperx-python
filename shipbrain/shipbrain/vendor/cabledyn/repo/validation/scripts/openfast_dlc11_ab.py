#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""L4-1b DLC-1.1 coupled A/B: CableDyn (CompMooring=5) vs stock MoorDyn (=3).

Both runs are the SAME operating IEA-15MW VolturnUS-S UMaine case under a realistic
DLC-1.1 environment -- IEC normal turbulence model (NTM) turbulent wind at 6 m/s (a
600 s TurbSim Kaimal box, periodic, tiled by InflowWind) plus a normal sea state
(JONSWAP Hs 2.5 m / Tp 10 s irregular waves) -- with the full aero-servo-elastic-hydro
model running (ElastoDyn + AeroDyn + ServoDyn + HydroDyn/SeaState). The two runs differ
ONLY in the mooring module (CompMooring 5 vs 3) and the referenced mooring file, so the
=5-vs-=3 comparison isolates the mooring model inside a fully coupled floating-wind
simulation. Stock MoorDyn is the independent reference.

Unlike the quiescent settled-statics A/B, this is a DYNAMIC case: the irregular waves and
turbulent wind drive the platform, so the mooring shapes both the mean offset and the
dynamic response. We therefore score BOTH the windowed mean (equilibrium) and the standard
deviation (motion amplitude) of each ElastoDyn platform DOF, over the steady window AFTER
the initial transient (default: drop the first 600 s of a 4200 s run -> score the last
3600 s = a 1-hour steady realization, the FOWT-standard window for wave statistics).

Usage:
    python validation/scripts/openfast_dlc11_ab.py <cd5.out> <md3.out> [t_start_s] [mean_tol] [std_tol] [min_window_s]

Defaults: t_start = 600 s, mean_tol = 0.03 (3%), std_tol = 0.05 (5%), min_window = 600 s.
Channel names are matched case-insensitively (MoorDyn-F emits UPPERCASE, CableDyn
mixed-case). Exit 0 iff the in-plane platform DOFs (surge, heave, pitch) agree within
tolerance on both mean and std over a steady window of at least min_window seconds — a
truncated run whose data barely clears t_start is a hard failure, never a
near-zero-window PASS. The report-only out-of-plane channels never gate the exit status.
"""

from __future__ import annotations

import math
import sys

# ElastoDyn platform DOFs. Surge/heave/pitch are the in-plane response driven by the
# aligned (0 deg) wind+waves -- the GATED DOFs. Sway/roll/yaw are near-zero out-of-plane
# for the aligned environment and are reported (with an absolute floor) but not %-gated.
GATED = ["PtfmSurge", "PtfmHeave", "PtfmPitch"]
REPORTED = ["PtfmSway", "PtfmRoll", "PtfmYaw"]
_ANGLE = {"PtfmRoll", "PtfmPitch", "PtfmYaw"}
# Absolute floors below which a relative % is meaningless (sub-cm / sub-0.01 deg motion).
FLOOR = {True: 0.01, False: 0.005}  # keyed by is-angle: 0.01 deg / 0.005 m


def load(path: str) -> tuple[list[str], list[list[float]]]:
    """Parse an OpenFAST .out into (header tokens, numeric rows); ([], []) if malformed."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [ln.rstrip("\n") for ln in fh]
    hi = next((i for i, ln in enumerate(lines) if ln.split()[:1] == ["Time"]), -1)
    if hi < 0:
        return [], []
    header = lines[hi].split()
    rows: list[list[float]] = []
    for ln in lines[hi + 2 :]:  # skip the units line
        parts = ln.split()
        if len(parts) != len(header):
            continue
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    return header, rows


def col(header: list[str], name: str) -> int:
    """Case-insensitive column index, or -1."""
    low = name.lower()
    return next((i for i, h in enumerate(header) if h.lower() == low), -1)


def stats(
    header: list[str], rows: list[list[float]], name: str, t_start: float
) -> tuple[float, float, float, float] | None:
    """(mean, std, min, max) of channel `name` over t >= t_start, or None if absent/empty."""
    c = col(header, name)
    t = col(header, "Time")
    if c < 0 or t < 0:
        return None
    vals = [r[c] for r in rows if r[t] >= t_start]
    if not vals or not all(math.isfinite(v) for v in vals):
        return None
    n = len(vals)
    mean = sum(vals) / n
    var = sum((v - mean) ** 2 for v in vals) / n
    return mean, math.sqrt(max(var, 0.0)), min(vals), max(vals)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    t_start = float(sys.argv[3]) if len(sys.argv) > 3 else 600.0
    mean_tol = float(sys.argv[4]) if len(sys.argv) > 4 else 0.03
    std_tol = float(sys.argv[5]) if len(sys.argv) > 5 else 0.05
    min_window = float(sys.argv[6]) if len(sys.argv) > 6 else 600.0
    h5, r5 = load(sys.argv[1])
    h3, r3 = load(sys.argv[2])
    t5, t3 = col(h5, "Time"), col(h3, "Time")
    if not r5 or not r3 or t5 < 0 or t3 < 0:
        which = "CableDyn(=5)" if (not r5 or t5 < 0) else "MoorDyn(=3)"
        print(f"ERROR: no Time-indexed data parsed from the {which} .out (empty or malformed).")
        return 1
    # The runs must share a time grid (same deck except CompMooring); a truncated run makes a
    # misaligned, non-comparable A/B. Require matching end times and row counts.
    dt_est = (r5[-1][t5] - r5[0][t5]) / max(len(r5) - 1, 1)
    if abs(r5[-1][t5] - r3[-1][t3]) > 2.0 * dt_est or len(r5) != len(r3):
        print(
            f"ERROR: the two runs do not share a time grid ({len(r5)} rows to {r5[-1][t5]:.1f} s "
            f"vs {len(r3)} rows to {r3[-1][t3]:.1f} s); the A/B is not comparable."
        )
        return 1
    if r5[-1][t5] < t_start + min_window:
        # A truncated run whose data barely clears t_start would otherwise "pass" on a
        # near-zero-length window with meaningless statistics; require the full window.
        print(
            f"ERROR: run end {r5[-1][t5]:.1f} s < t_start {t_start:.1f} s + min_window "
            f"{min_window:.1f} s; the steady window is missing or too short to score."
        )
        return 1
    print(
        f"DLC-1.1 coupled A/B (NTM 6 m/s wind + JONSWAP Hs2.5/Tp10 waves, aero-servo-elastic-hydro)\n"
        f"CableDyn(=5) vs stock MoorDyn(=3): {len(r5)} rows to {r5[-1][t5]:.0f} s; "
        f"steady window [{t_start:.0f}, {r5[-1][t5]:.0f}] s ({r5[-1][t5]-t_start:.0f} s)\n"
        f"gates: in-plane DOF mean within {mean_tol*100:.0f}%, std within {std_tol*100:.0f}%\n"
    )
    hdr = f"{'DOF':10} {'unit':4} {'mean=5':>10} {'mean=3':>10} {'d_mean%':>8} " \
          f"{'std=5':>9} {'std=3':>9} {'d_std%':>8}  gate"
    print(hdr)
    bad: list[str] = []
    for ch in GATED + REPORTED:
        gated = ch in GATED
        s5 = stats(h5, r5, ch, t_start)
        s3 = stats(h3, r3, ch, t_start)
        if s5 is None or s3 is None:
            where = "CableDyn(=5)" if s5 is None else "MoorDyn(=3)"
            # Only a GATED channel's absence fails the comparison; a missing report-only
            # out-of-plane channel is noted but never gates the exit status.
            print(f"{ch:10} MISSING/non-finite in {where}" + ("" if gated else "  (report-only, not gated)"))
            if gated:
                bad.append(ch)
            continue
        m5, sd5, _, _ = s5
        m3, sd3, _, _ = s3
        is_ang = ch in _ANGLE
        unit = "deg" if is_ang else "m"
        floor = FLOOR[is_ang]
        mscale = max(abs(m3), floor)
        sscale = max(sd3, floor)
        dmean = abs(m5 - m3) / mscale
        dstd = abs(sd5 - sd3) / sscale
        ok = (dmean <= mean_tol and dstd <= std_tol) if gated else True
        tag = ("PASS" if ok else "FAIL") if gated else "(report)"
        if gated and not ok:
            bad.append(ch)
        print(
            f"{ch:10} {unit:4} {m5:10.4f} {m3:10.4f} {dmean*100:7.2f}% "
            f"{sd5:9.4f} {sd3:9.4f} {dstd*100:7.2f}%  {tag}"
        )
    if bad:
        print(
            f"\nFAIL: {len(bad)} gated DOF(s) outside tolerance or missing ({', '.join(bad)})."
        )
        return 1
    print("\nPASS: CableDyn and stock MoorDyn agree on the coupled platform response.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
