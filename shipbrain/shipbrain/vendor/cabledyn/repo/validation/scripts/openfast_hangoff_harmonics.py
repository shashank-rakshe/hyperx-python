#!/usr/bin/env python3
# File: validation/scripts/openfast_hangoff_harmonics.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Reduce the cable hang-off motion from an OpenFAST coupled `.out` to the shared harmonic table
that drives the L4-1c comparison (`tests/data/lozon_coupled_harmonics.dat`).

The cable hang-off is a fixed point on the platform, so it moves rigidly with the platform 6-DOF
response (ElastoDyn `PtfmSurge/Heave/Pitch`). For the planar head-sea case its fluctuating
translation is ``x_ho = surge + z_off*pitch``, ``z_ho = heave - x_off*pitch`` (small-rotation rigid
transform at the hang-off offset). That translation is FFT-decomposed into the dominant harmonics;
BOTH CableDyn and OrcaFlex are then driven by the identical table, using the cos convention
``disp = mean + sum_k A_k cos(2*pi*t/T_k + phi_k)`` (phi from the FFT angle). Optionally cap the
period to keep the wave/response band that settles fast and carries the fatigue-driving response;
the slow surge drift (long-period, quasi-static) is folded into the reported mean offset.

Usage: python validation/scripts/openfast_hangoff_harmonics.py <coupled.out> <x_off> <z_off> <t_skip> <n_harm> \\
                                                   [out.dat] [max_period_s]
"""

import sys

import numpy as np


def load(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [ln.rstrip("\n") for ln in fh]
    hi = next(i for i, ln in enumerate(lines) if ln.split()[:1] == ["Time"])
    header = lines[hi].split()
    rows = []
    for ln in lines[hi + 2 :]:
        p = ln.split()
        if len(p) != len(header):
            continue
        try:
            rows.append([float(x) for x in p])
        except ValueError:
            continue
    return header, np.array(rows)


def col(header, name):
    low = name.lower()
    return next((i for i, h in enumerate(header) if h.lower() == low), -1)


def main():
    path, x_off, z_off = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    t_skip, n_harm = float(sys.argv[4]), int(sys.argv[5])
    out = sys.argv[6] if len(sys.argv) > 6 else None
    max_period = float(sys.argv[7]) if len(sys.argv) > 7 else 1.0e9

    h, d = load(path)
    idx = {
        name: col(h, name) for name in ("Time", "PtfmSurge", "PtfmHeave", "PtfmPitch")
    }
    missing = [name for name, c in idx.items() if c < 0]
    if missing or d.size == 0:
        sys.exit(
            f"ERROR: {path} lacks required channel(s) {missing or '(no data rows)'}"
        )
    t = d[:, idx["Time"]]
    surge, heave = d[:, idx["PtfmSurge"]], d[:, idx["PtfmHeave"]]
    pitch = np.radians(d[:, idx["PtfmPitch"]])

    mask = t >= t_skip
    t, surge, heave, pitch = t[mask], surge[mask], heave[mask], pitch[mask]
    dt = float(np.median(np.diff(t)))
    n = len(t) - (len(t) % 2)

    x_ho = surge[:n] + z_off * pitch[:n]
    z_ho = heave[:n] - x_off * pitch[:n]
    x_mean, z_mean = float(x_ho.mean()), float(z_ho.mean())
    xf, zf = x_ho - x_mean, z_ho - z_mean

    freqs = np.fft.rfftfreq(n, dt)
    X = np.fft.rfft(xf) * (2.0 / n)
    Z = np.fft.rfft(zf) * (2.0 / n)
    energy = np.abs(X) ** 2 + np.abs(Z) ** 2
    order = [
        k
        for k in np.argsort(energy)[::-1]
        if 0 < k < len(freqs) - 1 and 1.0 / freqs[k] <= max_period
    ]
    sel = order[:n_harm]

    tot = float(np.sum(np.abs(X[1:]) ** 2 + np.abs(Z[1:]) ** 2))
    cap = float(np.sum(energy[sel]))
    L = n * dt
    print(
        f"window {L:.1f} s ({n} samples, dt {dt:.4f} s); hang-off offset ({x_off}, {z_off}) m"
    )
    print(f"surge fluct RMS {np.std(xf):.4f} m, heave fluct RMS {np.std(zf):.4f} m")
    print(f"mean hang-off (x, z) = ({x_mean:.4f}, {z_mean:.4f}) m")
    print(
        f"top {len(sel)} harmonics (period <= {max_period:g} s) capture {100 * cap / tot:.1f}% of the fluctuation"
    )

    rows = []
    for k in sel:
        rows.append(
            (
                1.0 / freqs[k],
                abs(X[k]),
                np.degrees(np.angle(X[k])),
                abs(Z[k]),
                np.degrees(np.angle(Z[k])),
            )
        )
    rows.sort(key=lambda r: -(r[1] ** 2 + r[3] ** 2))
    print(
        f"\n{'period_s':>10} {'surge_A':>10} {'surge_ph':>10} {'heave_A':>10} {'heave_ph':>10}"
    )
    for per, sa, sp, ha, hp in rows[:12]:
        print(f"{per:10.3f} {sa:10.4f} {sp:10.2f} {ha:10.4f} {hp:10.2f}")

    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(
                "# L4-1c hang-off harmonic table (cos convention: A cos(2 pi t/T + phase_deg))\n"
            )
            f.write(
                f"# source {path}; offset ({x_off},{z_off}); window {L:.1f}s; period<={max_period:g}s; capture {100 * cap / tot:.1f}%\n"
            )
            f.write(f"{len(rows)} {x_mean:.6f} {z_mean:.6f}\n")
            f.write("# period_s surge_amp surge_phase_deg heave_amp heave_phase_deg\n")
            for per, sa, sp, ha, hp in rows:
                f.write(f"{per:.6f} {sa:.6f} {sp:.4f} {ha:.6f} {hp:.4f}\n")
        print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
