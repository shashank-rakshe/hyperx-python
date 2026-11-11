#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""L4-1b settled-statics A/B: CableDyn (CompMooring=5) vs stock MoorDyn (=3).

Both runs are the SAME quiescent OpenFAST case -- identical platform, hydro, sea state, and
forcing (no wind/aero/servo, still water) -- differing ONLY in the mooring module. The =5-vs-=3
comparison therefore isolates the mooring-model difference in a full coupled floating-wind
simulation: the platform DOFs (ElastoDyn) should agree to within the mooring model's small
influence, while the fairlead tensions carry CableDyn's true Newton static + geometrically-exact
curvature vs MoorDyn's lumped-mass dynamic-relaxation static.

With no forcing, still water has little damping, so the slow surge mode is still decaying at the
end of a 600 s run; this is a *matched-quiescent* comparison, not a fully-relaxed static. The
reported per-channel means are taken over the last WINDOW seconds (>= one surge period) so the
decaying oscillation averages out, and both codes are averaged over the SAME window -- the
=5-vs-=3 difference is window-robust even though the absolute mean drifts (verify by re-running
with a different WINDOW). The peak |=5 - =3| over the whole aligned trajectory bounds the
instantaneous divergence.

Usage:
    python validation/scripts/openfast_settled_ab.py <cd5.out> <md3.out> [window_s]

Both .out files must be produced by the same OpenFAST binary from decks that differ only in
CompMooring (5 vs 3) and the referenced mooring file. Channel names are matched
case-insensitively (MoorDyn-F emits UPPERCASE names, CableDyn mixed-case).
"""

from __future__ import annotations

import math
import sys

# Platform DOFs (ElastoDyn) + fairlead/anchor tensions (the mooring module's own channels).
CHANNELS = [
    "PtfmSurge",
    "PtfmSway",
    "PtfmHeave",
    "PtfmRoll",
    "PtfmPitch",
    "PtfmYaw",
    "FairTen1",
    "FairTen2",
    "FairTen3",
    "AnchTen1",
    "AnchTen2",
    "AnchTen3",
]
_ANGLE = {"PtfmRoll", "PtfmPitch", "PtfmYaw"}


def load(path: str) -> tuple[list[str], list[list[float]]]:
    """Parse an OpenFAST .out file into (header tokens, data rows).

    Tokens are split on any run of whitespace, so both tab-delimited
    (``TabDelim=True``) and fixed-width / space-delimited output parse.
    """
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [ln.rstrip("\n") for ln in fh]
    # A run that aborts before writing the table (or any malformed .out) has no line whose first
    # token is "Time"; return empty so main()'s named guard fires instead of a StopIteration.
    hi = next((i for i, ln in enumerate(lines) if ln.split()[:1] == ["Time"]), -1)
    if hi < 0:
        return [], []
    header = lines[hi].split()
    rows: list[list[float]] = []
    for ln in lines[hi + 2 :]:  # skip the units line
        parts = ln.split()
        # Accept only full-width numeric rows: a ragged row (a partial last line from an abort
        # mid-write, or a trailing footer) is skipped, so channel indexing never runs off the end.
        if len(parts) != len(header):
            continue
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    return header, rows


def col(header: list[str], name: str) -> int:
    """Case-insensitive column index (MoorDyn-F emits UPPERCASE names), or -1."""
    low = name.lower()
    for i, h in enumerate(header):
        if h.lower() == low:
            return i
    return -1


def mean_last(
    header: list[str], rows: list[list[float]], name: str, window: float
) -> float | None:
    """Mean of channel `name` over the last `window` seconds, or None if absent."""
    c = col(header, name)
    if c < 0:
        return None
    t = col(header, "Time")
    t_end = rows[-1][t]
    vals = [r[c] for r in rows if r[t] >= t_end - window]
    return sum(vals) / len(vals) if vals else None


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    window = float(sys.argv[3]) if len(sys.argv) > 3 else 120.0
    h5, r5 = load(sys.argv[1])
    h3, r3 = load(sys.argv[2])
    t5, t3 = col(h5, "Time"), col(h3, "Time")
    if not r5 or not r3 or t5 < 0 or t3 < 0:
        which = "CableDyn(=5)" if (not r5 or t5 < 0) else "MoorDyn(=3)"
        print(
            f"ERROR: no Time-indexed data rows parsed from the {which} .out (empty or malformed)."
        )
        return 1
    print(
        f"CableDyn(=5) rows {len(r5)} (t_end {r5[-1][t5]:.1f} s)   "
        f"MoorDyn(=3) rows {len(r3)} (t_end {r3[-1][t3]:.1f} s)   window {window:.0f} s"
    )
    # The two runs are the same deck except CompMooring, so they must cover the same time grid.
    # If one .out is truncated (an early abort), each mean would be taken over that file's OWN
    # final window and the peak over only the common row prefix -- a misaligned, non-comparable
    # A/B silently reported as valid. Require matching end times (within ~2 output steps) and row
    # counts before scoring.
    dt_est = (r5[-1][t5] - r5[0][t5]) / max(len(r5) - 1, 1)
    if abs(r5[-1][t5] - r3[-1][t3]) > 2.0 * dt_est or len(r5) != len(r3):
        print(
            f"\nERROR: the two runs do not share a time grid "
            f"({len(r5)} rows to {r5[-1][t5]:.3f} s vs {len(r3)} rows to {r3[-1][t3]:.3f} s); "
            "one run may be truncated or use a different dt/TMax -- the A/B is not comparable."
        )
        return 1
    print(
        f"{'channel':10} {'CableDyn(=5)':>15} {'MoorDyn(=3)':>15} {'absdiff':>13} {'%diff':>9} {'peak|d5-d3|':>13}"
    )
    bad: list[str] = []
    for ch in CHANNELS:
        m5, m3 = mean_last(h5, r5, ch, window), mean_last(h3, r3, ch, window)
        if m5 is None or m3 is None:
            where = "CableDyn(=5)" if m5 is None else "MoorDyn(=3)"
            print(f"{ch:10} {'MISSING in ' + where:>15}")
            bad.append(ch)
            continue
        if not (math.isfinite(m5) and math.isfinite(m3)):
            # a diverged run writes NaN/Inf; averaging it yields a meaningless comparison
            print(f"{ch:10} {'NON-FINITE mean':>15}")
            bad.append(ch)
            continue
        d = m5 - m3
        pct = 100.0 * d / (abs(m3) if abs(m3) > 1e-9 else 1.0)
        c5, c3 = col(h5, ch), col(h3, ch)
        n = min(len(r5), len(r3))
        diffs = [abs(r5[i][c5] - r3[i][c3]) for i in range(n)]
        if not all(math.isfinite(x) for x in diffs):
            # NaN/Inf anywhere on the trajectory (not just the averaging window) makes the peak
            # metric meaningless and can hide a divergence through max(); fail this channel.
            print(f"{ch:10} {'NON-FINITE sample':>15}")
            bad.append(ch)
            continue
        peak = max(diffs)
        unit = "N" if "Ten" in ch else ("deg" if ch in _ANGLE else "m")
        print(
            f"{ch:10} {m5:15.4g} {m3:15.4g} {d:13.4g} {pct:8.2f}% {peak:13.4g}  ({unit})"
        )
    if bad:
        # A required A/B metric is absent or non-finite -> the comparison is incomplete; fail
        # loudly rather than return success on a partial result (e.g. a deck whose OUTPUTS omit
        # the tensions, or a diverged run that wrote NaN).
        print(
            f"\nERROR: {len(bad)} required channel(s) missing or non-finite in one or both runs "
            f"({', '.join(bad)}); the A/B comparison is incomplete."
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
