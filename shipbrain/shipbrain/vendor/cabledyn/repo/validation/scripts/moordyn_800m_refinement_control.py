# File: validation/scripts/moordyn_800m_refinement_control.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""MoorDyn-F 800 m mesh-refinement CONTROL for the L3-6b mechanism cell.

The committed mechanism cell records that on MoorDyn-F's native 18.6 m mesh the 800 m
sag-bend dynamic curvature peak differs by -28.8% from the implicit codes and the dynamic
amplification reads 1.14 against 1.47. This control shows that the difference is mesh
resolution, not formulation, by refining the SAME pinned-span problem 2x and 4x and
watching both quantities converge toward the implicit values. Wall-clock time is recorded
alongside; MoorDyn initialises by dynamic relaxation, and its explicit dtM follows the
segment-length CFL limit.

Requires the settled-IC reference decks (threshIC 1e-5 / TmaxIC 900, the committed
generator defaults): with a looser relaxation threshold the refined statics are not yet
settled and the trend is contaminated (measured: loose r4 static 0.0353 vs settled
0.0262).

Per case it prints the peak LOCATIONS (the static and dynamic peaks must both sit at the
sag bend, arc ~354 m from the hang-off -- the same-location guarantee of the committed
contrast) and the peak node's scored-window curvature swing (participation).

Implicit-code references (committed L3-6 constants): static 0.02639, dynamic 0.03881,
amplification 1.4707.

Usage: python validation/scripts/moordyn_800m_refinement_control.py
Outputs land under build/moordyn_refs/800m_ctrl_*; the trend numbers are quoted in
VALIDATION.md's L3-6b row with this tool as provenance.
"""
import copy
import sys
import time

import numpy as np

from moordyn_lazywave_dynamic_reference import (
    OUT, SITES, TMAX, curvature_series, grid_mask, run_driver, score,
    write_deck, write_driver, write_motions,
)

BASE = SITES["800m"]
LSUS = sum(s.length for s in BASE.sections)
REF_KSTAT, REF_KDYN, REF_AMPL = 0.02639, 0.03881, 1.4707


def refined(factor):
    s = copy.deepcopy(BASE)
    s.name = f"800m_r{factor}"
    for sec in s.sections:
        sec.nsegs *= factor
    return s


def run_case(site, tag, dtm):
    case = OUT / tag
    case.mkdir(parents=True, exist_ok=True)
    _, td = write_deck(site, case, dtm)
    write_driver(site, case, TMAX, td, inputs=True)
    write_motions(case)
    t0 = time.perf_counter()
    run_driver(case)
    wall = time.perf_counter() - t0
    r = score(site, case, LSUS)

    # peak locations + participation (same-location guarantee of the committed contrast)
    tg, arcs, K, _ = curvature_series(site, case, LSUS)
    win = grid_mask(tg)
    interior = (arcs >= 0.03 * LSUS) & (arcs <= 0.97 * LSUS)
    kstat_all, kdyn_all = K[:, 0], K[:, win].max(axis=1)
    i_s = np.flatnonzero(interior)[np.argmax(kstat_all[interior])]
    i_d = np.flatnonzero(interior)[np.argmax(kdyn_all[interior])]
    swing = K[i_d, win].max() - K[i_d, win].min()

    segmax = max(sec.length / sec.nsegs for sec in site.sections)
    print(f"[{tag}] seg_max {segmax:5.2f} m  dtM {dtm * 1e3:.2f} ms  wall {wall:7.1f} s  "
          f"kstat {r['kstat']:.6f} @ {arcs[i_s]:.1f} m  kdyn {r['kdyn']:.6f} @ {arcs[i_d]:.1f} m  "
          f"ampl {r['ampl']:.4f}  peak-node window swing {swing:.5f} 1/m  "
          f"T {r['tmean']:.4f}/{r['tmin']:.4f}/{r['tmax']:.4f} kN")
    sys.stdout.flush()
    assert r["drive_amp_err"] < 2e-3 and r["drive_mean_err"] < 2e-3, "drive read-back failed"
    return r, wall


def main():
    results = {}
    results["native"] = run_case(BASE, "800m_ctrl_native", 0.0005)
    results["r2"] = run_case(refined(2), "800m_ctrl_r2", 0.0005)
    results["r4"] = run_case(refined(4), "800m_ctrl_r4", 0.0005)
    results["r4_half"] = run_case(refined(4), "800m_ctrl_r4_half", 0.00025)

    a, b = results["r4"][0], results["r4_half"][0]
    print(f"\nr4 dtM-halving: ampl {a['ampl']:.4f} vs {b['ampl']:.4f} "
          f"(move {100 * abs(a['ampl'] - b['ampl']) / b['ampl']:.4f}%), "
          f"kdyn move {100 * abs(a['kdyn'] - b['kdyn']) / b['kdyn']:.4f}%, "
          f"wall {results['r4'][1]:.1f} -> {results['r4_half'][1]:.1f} s")
    print(f"implicit-code references: kstat {REF_KSTAT}  kdyn {REF_KDYN}  ampl {REF_AMPL}")
    print("dynamic-peak difference vs implicit (native -> r2 -> r4): "
          + "  ".join(f"{100 * (results[k][0]['kdyn'] - REF_KDYN) / REF_KDYN:+.1f}%"
                      for k in ("native", "r2", "r4")))
    print("amplification (native -> r2 -> r4): "
          + "  ".join(f"{results[k][0]['ampl']:.4f}" for k in ("native", "r2", "r4"))
          + f"   [implicit {REF_AMPL}]")
    print("wall-clock (s): "
          + "  ".join(f"{results[k][1]:.1f}" for k in ("native", "r2", "r4")))


if __name__ == "__main__":
    main()
