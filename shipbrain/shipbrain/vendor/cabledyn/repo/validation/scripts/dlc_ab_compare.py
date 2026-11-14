#!/usr/bin/env python
# File: validation/scripts/dlc_ab_compare.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A/B compare two coupled OpenFAST runs of the SAME model that differ only in the mooring
module -- ``CompMooring = 3`` (stock MoorDyn-F, the reference) vs ``CompMooring = 5`` (CableDyn) --
on the CableDyn DLC verification-and-validation channels.

For each channel it reports the CableDyn-minus-MoorDyn delta of the mean, standard deviation, and
maximum over a scored window (the IC transient dropped), as a percentage of the MoorDyn value. This
is the per-case accuracy score behind the coupled DLC matrix in
``validation/OPENFAST_DLC_VERIFICATION.md``:

  * platform DOFs (all six: PtfmSurge / PtfmSway / PtfmHeave / PtfmRoll / PtfmPitch / PtfmYaw)
    -- gate: DYNAMIC response (std + max) with a COMBINED absolute+relative tolerance
    (|delta| <= 0.02 + 3 %*|ref|) -- the 3 % relative gate plus a small absolute floor so a
    tiny-motion DOF (a sub-0.1 deg parked-case yaw) is not failed on a denominator-noisy percentage,
    while a genuinely different oscillation amplitude still trips it. The mean is reported for
    information only (a small mean surge makes its percentage denominator-noisy, and the static
    load it reflects is already gated on the tensions); a near-zero-mean symmetric DOF (a head-on
    roll/sway/yaw at ~0) additionally gates its absolute mean drift.
  * fairlead tension (FairTen1..N)                               -- gate: mean within 2 %
  * anchor tension  (AnchTen1..N)                                -- gate: mean within 3 %

Platform DOFs come from the glue ``<root>.out``; MoorDyn writes its tensions to ``<root>.MD.out``
while CableDyn writes them into the glue ``<root>.out`` -- both are searched, case-insensitively.

Usage:
    python validation/scripts/dlc_ab_compare.py <md3_root>.out <cd5_root>.out [t_start_s]

Exit code 0 iff every present channel is inside its gate; 1 otherwise (so it can gate CI).
"""
from __future__ import annotations

import os
import sys

import numpy as np

GATES = {"Ptfm": 3.0, "FairTen": 2.0, "AnchTen": 3.0}  # mean %-delta gate per channel family


def _load(path: str):
    with open(path) as f:
        lines = f.readlines()
    hdr = next((i for i, ln in enumerate(lines) if ln.split()[:1] == ["Time"]), None)
    if hdr is None:
        raise ValueError(f"{path}: no 'Time' header row found -- not an OpenFAST/MoorDyn output file?")
    names = lines[hdr].split()
    # rows start two lines below the header (skip the units line). np.atleast_2d keeps a
    # single-data-row file 2-D so downstream data[:, 0] indexing holds.
    data = np.atleast_2d(np.genfromtxt(lines[hdr + 2 :]))
    if data.size == 0 or data.shape[1] < 2:
        raise ValueError(f"{path}: no numeric data rows under the 'Time' header.")
    return names, data


def _sidecar(root_out: str, suffix: str) -> str | None:
    cand = root_out[:-4] + suffix if root_out.endswith(".out") else root_out + suffix
    return cand if os.path.exists(cand) else None


def _find(names, ch):
    for i, n in enumerate(names):
        if n.upper() == ch.upper():
            return i
    return None


def _stats(data, j, t0):
    x = data[data[:, 0] >= t0, j]
    if x.size == 0:
        # t0 is at or past the run end: no samples in the scored window. Return NaN so the
        # per-channel non-finite gate fails the case loudly instead of raising on an empty mean.
        return float("nan"), float("nan"), float("nan")
    return x.mean(), x.std(), x.max()


def _gate_for(ch: str) -> float:
    for fam, g in GATES.items():
        if ch.startswith(fam):
            return g
    return 3.0


NEAR_ZERO = 1e-2  # |mean| below this (m or deg) is "~0" -> gate on absolute, not %-, delta
ABS_TOL = 0.05    # absolute mean-delta gate for a ~0 channel (m or deg): catches a real drift
DYN_ATOL = 0.02   # absolute floor on the platform dynamic-response gate (m or deg): below this a
#                   std/max difference is physically negligible, so it is not failed on a noisy %


def compare(md_out: str, cd_out: str, t0: float = 10.0) -> int:
    # MoorDyn tensions live in the .MD.out sidecar; CableDyn's in the glue .out. Load all sources.
    sources = {"md_main": _load(md_out), "cd_main": _load(cd_out)}
    md_side = _sidecar(md_out, ".MD.out")
    if md_side:
        sources["md_side"] = _load(md_side)

    def pick(role, ch):  # role in {"md","cd"}
        for key in ([f"{role}_side", f"{role}_main"] if role == "md" else [f"{role}_main"]):
            if key in sources:
                names, data = sources[key]
                j = _find(names, ch)
                if j is not None:
                    return _stats(data, j, t0)
        return None

    ok = True

    # Tolerance is HALF an output step (DT_Out), inferred from the reference time column -- NOT a
    # fraction of the total run length. A duration-scaled tolerance (1e-3 * TMax) would grow to
    # ~3.6 s on a 1 h DLC ensemble, silently tolerating a multi-sample early abort or grid shift;
    # half a sample catches a miss of even a single output row regardless of TMax.
    t_grid_md = sources["md_main"][1][:, 0]
    t_grid_cd = sources["cd_main"][1][:, 0]
    d_md = np.diff(t_grid_md)
    d_md = d_md[d_md > 0]
    dt_out = float(np.median(d_md)) if d_md.size else 0.0
    # Completion tolerance: HALF an output step -- "did the run reach TMax?" allows a last-row miss.
    t_tol = max(1e-6, 0.5 * dt_out)
    # Grid-EQUALITY tolerance: a tight rounding tolerance, NOT the half-step completion tolerance.
    # The A/B decks differ only in CompMooring, so identical TStart/DT_Out write identical sample
    # times -- element-wise they must match to output-rounding, not merely to within half a step (a
    # whole-grid shift under half a step would otherwise slip through and compare different instants).
    grid_tol = max(1e-6, 1e-3 * dt_out)

    # ROBUSTNESS gate: CableDyn must reach the SAME end time as the MoorDyn reference. A CableDyn
    # run that aborts after the transient but before TMax would otherwise be scored on its partial
    # window and could pass -- the completion failure the robustness gate must catch.
    t_md = float(t_grid_md[-1])
    t_cd = float(t_grid_cd[-1])
    if abs(t_cd - t_md) > t_tol:
        print(f"ROBUSTNESS FAIL: CableDyn reached t = {t_cd:g} s but MoorDyn reached {t_md:g} s "
              f"(> half an output step, {t_tol:g} s) -- the CableDyn run did not complete the full TMax.")
        ok = False
    # The two decks must differ ONLY in CompMooring / MooringFile -- same TMax, DT_Out, TStart -- so
    # the output rows land on identical sample times. If the row grids differ (a stray DT_Out/TStart
    # change) each channel's mean/std/max would compare over different sample times and a delta
    # reflect sampling rather than mooring behaviour. Require matching grids.
    n_md, n_cd = len(sources["md_main"][1]), len(sources["cd_main"][1])
    if n_md != n_cd:
        print(f"GRID FAIL: MoorDyn wrote {n_md} rows, CableDyn {n_cd} -- the A/B decks must share "
              f"one output grid (differ only in CompMooring / MooringFile).")
        ok = False
    else:
        # Equal row counts alone do not prove one grid: a stray TStart/DT_Out change that preserves
        # the count (and end time) would still shift the sample TIMES, so each channel's mean/std/max
        # would average over different instants of the same realization. Compare the Time columns
        # element-wise to the tight grid-equality tolerance (identical grids match to rounding), NOT
        # the loose half-step completion tolerance -- a sub-half-step whole-grid shift must still fail.
        dt_grid = float(np.max(np.abs(t_grid_md - t_grid_cd)))
        if dt_grid > grid_tol:
            print(f"GRID FAIL: MoorDyn and CableDyn share {n_md} rows but their sample times differ "
                  f"by up to {dt_grid:g} s (> {grid_tol:g} s) -- the A/B decks must share one output "
                  f"grid (same TStart / DT_Out); a mean/std/max over mismatched times reflects "
                  f"sampling, not mooring behaviour.")
            ok = False

    # The MoorDyn tension channels are scored from the .MD.out SIDECAR (preferred below), which may be
    # written on MoorDyn's own module cadence rather than the glue DT_Out grid. If it is, the fairlead/
    # anchor stats would average over different instants than the platform channels (and than CableDyn)
    # -- the same sampling artifact the main grid gate prevents. Require the sidecar on the scoring grid.
    if "md_side" in sources:
        t_side = sources["md_side"][1][:, 0]
        if len(t_side) != n_md:
            print(f"GRID FAIL: MoorDyn .MD.out sidecar wrote {len(t_side)} rows vs {n_md} in the glue "
                  f"output -- the tension sidecar must share the scoring grid (same DT_Out).")
            ok = False
        else:
            dt_side = float(np.max(np.abs(t_side - t_grid_md)))
            if dt_side > grid_tol:
                print(f"GRID FAIL: MoorDyn .MD.out sidecar sample times differ from the glue grid by up "
                      f"to {dt_side:g} s (> {grid_tol:g} s) -- the tension stats would average over "
                      f"different instants than the platform channels.")
                ok = False

    # The gated channel set is seeded from the MoorDyn REFERENCE (its line count), never inferred
    # from whatever CableDyn happened to output: the fairlead/anchor gates MUST be scored, so a
    # CableDyn deck that forgot its tension OUTPUTS fails loudly, not silently on the DOFs alone.
    # The MoorDyn tensions normally live ONLY in the .MD.out sidecar, so a missing sidecar (or a
    # reference with no discoverable FairTen lines) means the fairlead/anchor gates cannot be scored
    # at all -- a hard failure, never a silent platform-only pass.
    if "md_side" not in sources:
        print("REFERENCE FAIL: MoorDyn .MD.out sidecar not found -- tension gates unscorable.")
        ok = False
    md_names = (sources.get("md_side") or sources["md_main"])[0]
    # Count the mooring lines the reference actually carries by scanning FairTen1, FairTen2, ...
    # until the first missing one -- no hard cap, so a model with more than a dozen lines has every
    # FairTen<L>/AnchTen<L> gated (the tool documents FairTen1..N / AnchTen1..N). The scan is bounded
    # by the finite channel list, and MoorDyn/OpenFAST number these contiguously (one per line).
    nlines = 0
    while _find(md_names, f"FairTen{nlines + 1}") is not None:
        nlines += 1
    if nlines == 0:
        print("REFERENCE FAIL: no FairTen<L> in the MoorDyn reference -- tension gates unscored.")
        ok = False
    # All six platform DOFs: directional/asymmetric DLCs (yaw error, ECD, EWS) load roll and yaw,
    # so gate them too. The near-zero absolute gate above handles the symmetric head-on cases where
    # roll/yaw sit at ~0 (their percentage would otherwise be denominator-noise).
    gated = ["PtfmSurge", "PtfmSway", "PtfmHeave", "PtfmRoll", "PtfmPitch", "PtfmYaw"]
    for L in range(1, nlines + 1):
        gated += [f"FairTen{L}", f"AnchTen{L}"]

    hdr = f"{'channel':11}{'MoorDyn mean':>15}{'CableDyn mean':>15}"
    hdr += f"{'d_mean%':>10}{'d_std%':>9}{'d_max%':>9}  gate"
    print(hdr)
    for ch in gated:
        a, b = pick("md", ch), pick("cd", ch)
        if a is None or b is None:
            # A gated channel missing from EITHER side (a stripped OUTPUTS section or a missing
            # .MD.out sidecar) is a hard failure -- not a silent skip that leaves the verdict PASS.
            print(f"{ch:11}  MISSING -- MoorDyn={a is not None}, CableDyn={b is not None}")
            ok = False
            continue
        ma, sa, xa = a
        mb, sb, xb = b
        # A completed run can still write NaN/Inf into a channel; because every comparison with NaN
        # is False, the gate below would silently leave the verdict PASS. Reject non-finite stats
        # outright -- the robustness gate requires clean, finite output on every gated channel.
        if not all(np.isfinite(v) for v in (ma, sa, xa, mb, sb, xb)):
            print(f"{ch:11}  NON-FINITE (NaN/Inf) in the scored window")
            ok = False
            continue
        # A channel is "~0" only when BOTH codes sit near zero (so a CableDyn mean drift on an
        # otherwise-symmetric DOF is NOT waived); such a channel is then gated on the ABSOLUTE mean
        # delta, not the denominator-noisy percentage.
        near_zero = max(abs(ma), abs(mb)) <= NEAR_ZERO
        scale = abs(ma) if not near_zero else 1.0
        dm = 100 * (mb - ma) / scale
        ds = 100 * (sb - sa) / (abs(sa) if abs(sa) > 1e-9 else 1.0)
        dx = 100 * (xb - xa) / (abs(xa) if abs(xa) > 1e-2 else 1.0)
        gate = _gate_for(ch)
        is_ptfm = ch.startswith("Ptfm")
        if is_ptfm:
            # PLATFORM DOFs are gated on the DYNAMIC response (std + max), the physical comparand;
            # the mean reflects the static load (already gated on the tensions) and is
            # denominator-noisy for a small mean, so it is reported, not gated. Gate std/max with a
            # COMBINED absolute+relative
            # tolerance (|d| <= atol + rtol*|ref|, numpy-allclose style): the relative part is the
            # 3 % gate, and the small absolute floor DYN_ATOL keeps a physically-negligible amplitude
            # difference on a tiny-motion DOF (a sub-0.1 deg parked-case yaw, where 3 % is 0.001 deg)
            # from failing on denominator-noise -- while a genuinely different oscillation amplitude,
            # including a zero-mean sway in a yawed/side-wave DLC, still trips it. A near-zero-MEAN
            # symmetric DOF ALSO gates its absolute mean drift (the percentage would be meaningless).
            over = (abs(sb - sa) > DYN_ATOL + (gate / 100) * abs(sa)
                    or abs(xb - xa) > DYN_ATOL + (gate / 100) * abs(xa))
            note = f"dyn {gate:.0f}%"
            if near_zero:
                over = over or abs(mb - ma) > ABS_TOL
                note = f"dyn {gate:.0f}%+|d|"
        elif near_zero:
            # a near-zero tension channel: gate the absolute mean delta, not the exploding percentage.
            over, note = abs(mb - ma) > ABS_TOL, f"|d|<{ABS_TOL}"
        else:
            # tensions (fairlead/anchor): the mean is the direct mooring-load comparand.
            over, note = abs(dm) > gate, f"{gate:.0f}%"
        if over:
            ok = False
        flag = "  <-- OVER" if over else ""
        print(f"{ch:11}{ma:15.5g}{mb:15.5g}{dm:10.3f}{ds:9.2f}{dx:9.2f}  {note}{flag}")
    verdict = "PASS" if ok else "FAIL"
    print(f"\nscored t >= {t0} s (both runs to t = {t_cd:g} s)   VERDICT: {verdict}")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    t = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    sys.exit(compare(sys.argv[1], sys.argv[2], t))
