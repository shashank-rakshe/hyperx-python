#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Active-tension (CtrlChan) A/B: CableDyn (CompMooring=5) vs stock MoorDyn (=3).

Both runs are the SAME UMaine coupled OpenFAST case with the platform held at its free-settled
equilibrium pose (still water, no wind/aero, locked rotor), differing ONLY in the mooring
module. A single deterministic ServoDyn controller DLL (``libcabctrl.dll``) drives an IDENTICAL
DeltaL(t) schedule on the controlled lines in both runs -- pay the fairlead-side segment out
(lower tension), hold, then haul it in past baseline (higher tension). Because the platform is
held and the command is bit-identical, the two mooring solvers see the same geometry and the
same length command, so any difference in the tension response is the mooring model.

Active tensioning controls the QUASI-STATIC tension setpoint. This scorer therefore evaluates
the response at three steady holds -- baseline (before the command), the pay-out hold, and the
haul-in hold -- where the commanded length rate DeltaLdot is zero. At each hold the fairlead and
anchor tensions are steady, so the =5-vs-=3 comparison of the tension CHANGE from baseline (which
cancels the codes' small static-tension offset) isolates how each solver renders the commanded
length modulation into tension.

The pay-out and haul-in RAMPS are scored too: over each ramp and its settling into the next hold,
the largest difference between the two codes' tensions must stay within GATE_RAMP_PCT of the
MoorDyn baseline tension of that line. The commanded length changes every step there, so this
checks that the length update enters the time integration the way MoorDyn's does.

Usage:
    python validation/scripts/openfast_activetension_ab.py <cd5.out> <md3.out>
        [t_base_lo t_base_hi t_payout_lo t_payout_hi t_haulin_lo t_haulin_hi]

Defaults match the DLL schedule (pay out over 40-100 s, hold to 160 s, haul in over 160-220 s,
hold to 260 s): baseline [10,38], pay-out hold [110,158], haul-in hold [228,258]; the ramps are
scored over [38,110] and [158,228] (from the end of one hold window to the start of the next).
Channel names are matched case-insensitively (MoorDyn-F emits UPPERCASE).
"""

from __future__ import annotations

import math
import sys

CONTROLLED = [
    "FairTen1",
    "FairTen2",
    "FairTen3",
]  # the lines assigned to control channel 1
ANCHORS = ["AnchTen1", "AnchTen2", "AnchTen3"]
DEFAULT_WINDOWS = (10.0, 38.0, 110.0, 158.0, 228.0, 258.0)

# Agreement gates on the controlled line's quasi-static active-tension response (the change in
# fairlead tension from baseline to each hold), and on the far-end (anchor) tension.
GATE_RESPONSE_PCT = (
    15.0  # |dT(=5) - dT(=3)| / |dT(=3)| at each hold, controlled fairlead
)
GATE_ANCHOR_PCT = 3.0  # anchor mean agreement at each hold
# The command must actually MOVE the tension in BOTH codes: a disconnected DLL/CtrlChan path
# leaves every hold equal to baseline (dT == 0), which would otherwise agree trivially. Require
# a real response -- each controlled hold must change the tension by at least this fraction of
# baseline in each code -- so the A/B cannot pass vacuously on a dead cable-control path.
GATE_MIN_RESPONSE_PCT = 1.0  # |dT| / baseline, per code, per controlled hold
# Ramp agreement: max |T(=5) - T(=3)| over each ramp, as a percentage of the line's MoorDyn
# baseline tension (controlled fairleads and anchors).
GATE_RAMP_PCT = 1.0
# Note: within a steady hold (DeltaLdot=0) the tension is essentially flat, so the =5-vs-=3
# correlation of the hold window is noise-vs-noise and is reported for context only, NOT gated.
# The gated quantity is the tension CHANGE from baseline -- the winch setpoint response.


def load(path: str) -> tuple[list[str], list[list[float]]]:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [ln.rstrip("\n") for ln in fh]
    hi = next((i for i, ln in enumerate(lines) if ln.split()[:1] == ["Time"]), -1)
    if hi < 0:
        return [], []
    header = lines[hi].split()
    rows: list[list[float]] = []
    for ln in lines[hi + 2 :]:
        parts = ln.split()
        if len(parts) != len(header):
            continue
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    return header, rows


def col(header: list[str], name: str) -> int:
    low = name.lower()
    for i, h in enumerate(header):
        if h.lower() == low:
            return i
    return -1


def window(
    header: list[str], rows: list[list[float]], name: str, t0: float, t1: float
) -> list[float] | None:
    c = col(header, name)
    if c < 0:
        return None
    t = col(header, "Time")
    return [r[c] for r in rows if t0 <= r[t] <= t1]


def mean(v: list[float]) -> float:
    return sum(v) / len(v)


def pearson(a: list[float], b: list[float]) -> float:
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    ma, mb = mean(a), mean(b)
    da, db = [x - ma for x in a], [y - mb for y in b]
    den = math.sqrt(sum(x * x for x in da) * sum(y * y for y in db))
    if den == 0:
        return 1.0  # both flat -> perfectly consistent holds
    return sum(x * y for x, y in zip(da, db)) / den


def pct(d: float, ref: float) -> float:
    return 100.0 * d / (abs(ref) if abs(ref) > 1e-9 else 1.0)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    w = (
        [float(x) for x in sys.argv[3:9]]
        if len(sys.argv) >= 9
        else list(DEFAULT_WINDOWS)
    )
    (bl, bh, pl, ph, hl, hh) = w
    h5, r5 = load(sys.argv[1])
    h3, r3 = load(sys.argv[2])
    t5, t3 = col(h5, "Time"), col(h3, "Time")
    if not r5 or not r3 or t5 < 0 or t3 < 0:
        which = "CableDyn(=5)" if (not r5 or t5 < 0) else "MoorDyn(=3)"
        print(
            f"ERROR: no Time-indexed data rows parsed from the {which} .out (empty/malformed)."
        )
        return 1
    dt_est = (r5[-1][t5] - r5[0][t5]) / max(len(r5) - 1, 1)
    if abs(r5[-1][t5] - r3[-1][t3]) > 2.0 * dt_est or len(r5) != len(r3):
        print(
            f"\nERROR: the two runs do not share a time grid ({len(r5)} rows to "
            f"{r5[-1][t5]:.3f} s vs {len(r3)} rows to {r3[-1][t3]:.3f} s); not comparable."
        )
        return 1
    print(
        f"CableDyn(=5) rows {len(r5)} (t_end {r5[-1][t5]:.1f} s)   "
        f"MoorDyn(=3) rows {len(r3)} (t_end {r3[-1][t3]:.1f} s)"
    )
    print(
        f"holds:  baseline [{bl:.0f},{bh:.0f}]   pay-out [{pl:.0f},{ph:.0f}]   "
        f"haul-in [{hl:.0f},{hh:.0f}] s   (DeltaLdot=0 at each)\n"
    )

    holds = {"baseline": (bl, bh), "pay-out": (pl, ph), "haul-in": (hl, hh)}
    fails: list[str] = []

    # Per-channel steady tension at each hold, and the =5-vs-=3 response agreement.
    def report(
        chans: list[str], label: str, gate_pct: float, gate_response: bool
    ) -> None:
        print(f"--- {label} ---")
        for ch in chans:
            base5 = window(h5, r5, ch, bl, bh)
            base3 = window(h3, r3, ch, bl, bh)
            if not base5 or not base3:
                print(f"{ch:10} MISSING")
                fails.append(ch)
                continue
            b5, b3 = mean(base5), mean(base3)
            print(
                f"{ch:10} baseline  =5 {b5 / 1e6:8.4f} MN   =3 {b3 / 1e6:8.4f} MN   "
                f"(static offset {pct(b5 - b3, b3):+5.2f}%)"
            )
            for name, (lo, hi) in holds.items():
                if name == "baseline":
                    continue
                s5, s3 = window(h5, r5, ch, lo, hi), window(h3, r3, ch, lo, hi)
                if not (s5 and s3 and all(math.isfinite(x) for x in s5 + s3)):
                    print(f"           {name:8}  NON-FINITE/MISSING")
                    fails.append(ch)
                    continue
                m5, m3 = mean(s5), mean(s3)
                dt5, dt3 = (
                    m5 - b5,
                    m3 - b3,
                )  # active-tension response (change from baseline)
                resp_pct = pct(dt5 - dt3, dt3)
                corr = pearson(s5, s3)
                flag = ""
                if gate_response:
                    # Both codes must show a real response, else a dead cable-control path
                    # (dT == 0 in both) would pass this agreement gate trivially.
                    live = (
                        abs(pct(dt5, b5)) >= GATE_MIN_RESPONSE_PCT
                        and abs(pct(dt3, b3)) >= GATE_MIN_RESPONSE_PCT
                    )
                    if not live:
                        flag = "  <-- GATE FAIL (no response; command not reaching a module)"
                        fails.append(ch)
                    elif abs(resp_pct) > GATE_RESPONSE_PCT:
                        flag = "  <-- GATE FAIL"
                        fails.append(ch)
                    else:
                        flag = "  ok"
                else:
                    if abs(pct(m5 - m3, m3)) > gate_pct:
                        flag = "  <-- GATE FAIL"
                        fails.append(ch)
                    else:
                        flag = "  ok"
                print(
                    f"           {name:8}  =5 {m5 / 1e6:8.4f}  =3 {m3 / 1e6:8.4f} MN   "
                    f"dT(=5) {dt5 / 1e3:+8.1f}  dT(=3) {dt3 / 1e3:+8.1f} kN   "
                    f"resp {resp_pct:+6.1f}%  corr {corr:.4f}{flag}"
                )
        print()

    report(
        CONTROLLED, "controlled lines -- active-tension response (channel 1)", 0.0, True
    )
    report(
        ANCHORS, "anchor (far-end) tensions -- steady agreement", GATE_ANCHOR_PCT, False
    )

    # Ramps: the largest tension difference between the codes while the length changes.
    ramps = {"pay-out ramp": (bh, pl), "haul-in ramp": (ph, hl)}
    print("--- ramps -- largest tension difference while the length changes ---")
    for ch in CONTROLLED + ANCHORS:
        base3 = window(h3, r3, ch, bl, bh)
        c5, c3 = col(h5, ch), col(h3, ch)
        if not base3 or c5 < 0 or c3 < 0:
            print(f"{ch:10} MISSING")
            fails.append(ch)
            continue
        b3 = mean(base3)
        parts = []
        flag = "  ok"
        for name, (lo, hi) in ramps.items():
            d = max(
                (
                    abs(x5[c5] - x3[c3])
                    for x5, x3 in zip(r5, r3)
                    if lo <= x5[t5] <= hi and abs(x5[t5] - x3[t3]) <= 0.5 * dt_est
                ),
                default=math.nan,
            )
            parts.append(f"{name} {d / 1e3:7.1f} kN ({pct(d, b3):5.2f}%)")
            if not (math.isfinite(d) and pct(d, b3) <= GATE_RAMP_PCT):
                flag = "  <-- GATE FAIL"
        if flag != "  ok":
            fails.append(ch)
        print(f"{ch:10} " + "   ".join(parts) + flag)
    print()

    if fails:
        print(f"RESULT: FAIL -- {', '.join(dict.fromkeys(fails))}")
        return 1
    print(
        f"RESULT: PASS -- both codes show a real active-tension response "
        f"(>= {GATE_MIN_RESPONSE_PCT:.0f}% of baseline), the commanded pay-out/haul-in tension "
        f"response on the controlled lines agrees within {GATE_RESPONSE_PCT:.0f}%, and the anchor "
        f"tensions within {GATE_ANCHOR_PCT:.0f}% between CableDyn and stock MoorDyn, and during the "
        f"ramps the tensions differ by at most {GATE_RAMP_PCT:.0f}% of the baseline, end to end "
        "through the OpenFAST ServoDyn cable-control path."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
