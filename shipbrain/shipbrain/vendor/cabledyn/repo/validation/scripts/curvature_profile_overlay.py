# File: validation/scripts/curvature_profile_overlay.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Three-code along-arc curvature profile overlay (L-fig) for the 800 m lazy-wave cable.

Assembles the 800 m Lozon lazy-wave span's along-arc curvature profiles -- static and
scored-window dynamic max, arc measured from the hang-off -- from the three codes under
the one committed heave protocol (3 m / 12 s, still water, matched hydro):

  * CableDyn : the profile the committed test itself writes on every run
               (build/lfig_cabledyn_800m.csv, from test_l3_lazywave_dynamic);
  * OrcaFlex : a live rerun of the committed reference model
               (validation/scripts/orcaflex_lazywave_dynamic_reference.build, seg 0.75 m);
  * MoorDyn-F: the SETTLED archived reference outputs at the native 18.6 m design mesh
               (build/moordyn_refs/800m/dyn) AND the settled 4x refinement control
               (build/moordyn_refs/800m_ctrl_r4) -- the mesh-resolution pair: the native
               mesh samples the sag-bend dynamic peak ~29% lower, the refined mesh comes
               within ~2%.

Every series' interior peak is cross-checked against the committed gate cells before
anything is written (fail closed): the overlay cannot silently drift from the gates.

Outputs:
  tests/data/lfig_800m_curvature_summary.csv    (committed record: per series, the interior
                                                 static and dynamic peaks with their arc
                                                 positions and arc-weighted quantiles of the
                                                 dynamic envelope)
  build/validation/lfig_800m_curvature_profiles.csv (full profiles; generated output, not
                                                 committed: the OrcaFlex profile is licensed
                                                 output that licence holders regenerate here)
  build/validation/lfig_800m_curvature_overlay.png (300 DPI; generated output)

Prerequisites: run the l3_lazywave_dynamic gate (writes the CableDyn profile), the
MoorDyn reference generator and the 800 m refinement control (populate
build/moordyn_refs), and have OrcFxAPI licensed for the live OrcaFlex rerun.

Usage: python validation/scripts/curvature_profile_overlay.py
"""

import csv
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "validation" / "scripts"))

from moordyn_lazywave_dynamic_reference import (  # noqa: E402
    OUT as MD_OUT, SITES as MD_SITES, curvature_series, grid_mask,
)

# committed gate cells (test_l3_lazywave_dynamic): the fail-closed cross-check targets
REF_OFX_KDYN = 0.03881       # OrcaFlex 800 m dynamic max (committed rkdyn)
REF_CD_KDYN_TOL = 0.005      # CableDyn peak must sit within 0.5% of the OrcaFlex cell
REF_MD_NATIVE_KDYN = 0.027623   # settled native-mesh cell (committed mkdyn)
REF_MD_R4_KDYN = 0.037932    # settled 4x refinement control (committed in VALIDATION)
LSUS = 920.43387
INTERIOR = (0.03 * LSUS, 0.97 * LSUS)


def interior_peak(arc, k):
    m = (arc >= INTERIOR[0]) & (arc <= INTERIOR[1])
    return float(np.max(k[m]))


def check(name, peak, ref, tol):
    err = abs(peak - ref) / ref
    print(f"  [check] {name}: peak {peak:.6f} vs committed {ref} ({100 * err:.2f}%) "
          f"-> {'OK' if err <= tol else 'MISMATCH - ABORT'}")
    if err > tol:
        sys.exit(1)


def summarise(arc, ks, kd):
    """Interior summary of one profile (arc from the hang-off, 3-97 % of the span).

    Returns the static and dynamic peaks with their arc positions and the 50 % / 90 %
    quantiles of the dynamic envelope weighted by arc length (so meshes of different spacing
    compare on the same footing).
    """
    arc, ks, kd = (np.asarray(v, float) for v in (arc, ks, kd))
    m = (arc >= INTERIOR[0]) & (arc <= INTERIOR[1])
    a, s, d = arc[m], ks[m], kd[m]
    i, j = int(np.argmax(d)), int(np.argmax(s))
    w = np.gradient(a)
    order = np.argsort(d)
    cw = np.cumsum(w[order]) / np.sum(w)
    q50, q90 = (float(d[order][np.searchsorted(cw, q)]) for q in (0.5, 0.9))
    return dict(n_nodes=len(arc), k_static_peak=float(s[j]), arc_static_peak_m=float(a[j]),
                k_dyn_peak=float(d[i]), arc_dyn_peak_m=float(a[i]),
                k_dyn_q50=q50, k_dyn_q90=q90)


SUMMARY_HEADER = """\
# File: tests/data/lfig_800m_curvature_summary.csv
# SPDX-License-Identifier: Apache-2.0
# L-fig 800 m Lozon lazy-wave span: along-arc curvature summary (1/m, arc from the hang-off),
# 3 m / 12 s hang-off heave, still water, matched hydro; interior 3-97 % of the 920.43 m span.
# Written by validation/scripts/curvature_profile_overlay.py (summarise()).
# CableDyn: test_l3_lazywave_dynamic profile (3.84 m mesh, dt 0.05 s, window t in [24, 60] s).
# OrcaFlex 11.6d: validation/scripts/orcaflex_lazywave_dynamic_reference.py build("800m"),
#   target segment 0.75 m, implicit constant dt 0.05 s, 12 s build-up + 48 s,
#   Range Graph curvature Max over stage-1 t in [12, 48] s; static = statics Range Graph.
# MoorDyn-F v2.3.8: settled native 18.6 m mesh and 4x refinement
#   (validation/scripts/moordyn_lazywave_dynamic_reference.py).
"""


def cabledyn_series():
    path = REPO / "build" / "lfig_cabledyn_800m.csv"
    if not path.exists():
        sys.exit(f"missing {path} -- run the l3_lazywave_dynamic gate first")
    rows = list(csv.reader(path.open()))[1:]
    arc = np.array([float(r[0]) for r in rows])
    ks = np.array([float(r[1]) for r in rows])
    kd = np.array([float(r[2]) for r in rows])
    check("CableDyn", interior_peak(arc, kd), REF_OFX_KDYN, REF_CD_KDYN_TOL)
    return arc, ks, kd


def moordyn_series(case_dir, factor, label, ref_kdyn):
    import copy
    site = copy.deepcopy(MD_SITES["800m"])
    for sec in site.sections:
        sec.nsegs *= factor
    case = MD_OUT / case_dir
    if not (case / "MD.MD.Line1.out").exists():
        sys.exit(f"missing {case} -- regenerate the MoorDyn references/control first")
    tg, arcs, K, at_rod = curvature_series(site, case, LSUS)
    win = grid_mask(tg)
    order = np.argsort(arcs)
    arc = arcs[order]
    ks = K[:, 0][order]
    kd = K[:, win].max(axis=1)[order]
    # MoorDyn writes a -1 SENTINEL on end-node curvature channels (no second segment to
    # difference against); curvature is non-negative by definition, so drop sentinel rows
    # rather than committing them into the artifact and flattening the plot autoscale.
    valid = np.isfinite(ks) & np.isfinite(kd) & (ks >= 0.0) & (kd >= 0.0)
    arc, ks, kd = arc[valid], ks[valid], kd[valid]
    check(label, interior_peak(arc, kd), ref_kdyn, 1e-3)
    return arc, ks, kd


def orcaflex_series():
    import OrcFxAPI as ofx
    from orcaflex_lazywave_dynamic_reference import WINDOW, build
    m, line = build("800m")
    m.CalculateStatics()
    # capture the STATIC profile before dynamics (a period-less RangeGraph taken after
    # RunSimulation would return whole-run statistics, not the gate's static state --
    # the same order the committed reference tool uses)
    rgs = line.RangeGraph("Curvature")
    arc_a = np.array(list(rgs.X))
    ks = np.abs(np.array(list(rgs.Mean)))
    m.RunSimulation()
    period = ofx.SpecifiedPeriod(*WINDOW)
    rgd = line.RangeGraph("Curvature", period)
    kd = np.abs(np.array(list(rgd.Max)))
    # this build's End A = touchdown; convert to arc from the hang-off
    arc = LSUS - arc_a
    order = np.argsort(arc)
    arc, ks, kd = arc[order], ks[order], kd[order]
    check("OrcaFlex", interior_peak(arc, kd), REF_OFX_KDYN, 0.002)
    # gate-consistency for the STATIC series too (the committed rkstat cell is 0.02639)
    check("OrcaFlex static", interior_peak(arc, ks), 0.02639, 0.002)
    return arc, ks, kd


def write_summary(series, path):
    """Write the committed per-series summary record."""
    fields = ["n_nodes", "k_static_peak", "arc_static_peak_m", "k_dyn_peak", "arc_dyn_peak_m",
              "k_dyn_q50", "k_dyn_q90"]
    with path.open("w", newline="\n") as f:
        f.write(SUMMARY_HEADER)
        wcsv = csv.writer(f, lineterminator="\n")
        wcsv.writerow(["series", *fields])
        for name, (arc, ks, kd) in series.items():
            sm = summarise(arc, ks, kd)
            wcsv.writerow([name, sm["n_nodes"], *(f"{sm[k]:.6g}" for k in fields[1:])])
    print(f"  committed summary written: {path}")


def main():
    print("=== L-fig: three-code 800 m curvature profile overlay ===")
    series = {}
    series["CableDyn (3.84 m mesh, implicit)"] = cabledyn_series()
    series["OrcaFlex (0.75 m mesh, implicit)"] = orcaflex_series()
    series["MoorDyn-F (native 18.6 m mesh)"] = moordyn_series("800m/dyn", 1,
                                                              "MoorDyn native",
                                                              REF_MD_NATIVE_KDYN)
    series["MoorDyn-F (4x refined, 4.7 m mesh)"] = moordyn_series("800m_ctrl_r4", 4,
                                                                  "MoorDyn r4",
                                                                  REF_MD_R4_KDYN)

    write_summary(series, REPO / "tests" / "data" / "lfig_800m_curvature_summary.csv")
    out_csv = REPO / "build" / "validation" / "lfig_800m_curvature_profiles.csv"
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open("w", newline="") as f:
        wcsv = csv.writer(f)
        wcsv.writerow(["series", "arc_m", "k_static", "k_dynwin_max"])
        for name, (arc, ks, kd) in series.items():
            for i in range(len(arc)):
                wcsv.writerow([name, f"{arc[i]:.6f}", f"{ks[i]:.8e}", f"{kd[i]:.8e}"])
    print(f"  full profiles written (not committed): {out_csv}")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("  matplotlib unavailable -- CSV written, figure skipped")
        return
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2), dpi=300,
                                   gridspec_kw={"width_ratios": [1.6, 1.0]})
    styles = {
        "CableDyn (3.84 m mesh, implicit)": dict(color="#0057b7", ls="-", lw=1.6, marker=None),
        "OrcaFlex (0.75 m mesh, implicit)": dict(color="#222222", ls="--", lw=1.4, marker=None),
        "MoorDyn-F (native 18.6 m mesh)": dict(color="#c0392b", ls="-", lw=1.0, marker="o", ms=3),
        "MoorDyn-F (4x refined, 4.7 m mesh)": dict(color="#e67e22", ls="-", lw=1.0, marker="^", ms=2.5),
    }
    for ax, (lo, hi) in ((ax1, (0.0, LSUS)), (ax2, (300.0, 420.0))):
        for name, (arc, ks, kd) in series.items():
            st = styles[name]
            msel = (arc >= lo) & (arc <= hi)
            ax.plot(arc[msel], kd[msel], label=name if ax is ax1 else None,
                    color=st["color"], ls=st["ls"], lw=st["lw"],
                    marker=st["marker"], ms=st.get("ms", 0))
        ax.set_xlabel("arc from hang-off (m)")
        ax.set_xlim(lo, hi)
        ax.grid(alpha=0.25, lw=0.4)
    ax1.set_ylabel("scored-window max curvature (1/m)")
    ax1.set_title("800 m Lozon lazy-wave span, 3 m / 12 s heave — dynamic curvature envelope")
    ax2.set_title("sag-bend region")
    ax1.legend(fontsize=7.5, loc="upper right")
    fig.tight_layout()
    out_png = REPO / "build" / "validation" / "lfig_800m_curvature_overlay.png"
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png)
    print(f"  figure written: {out_png}")


if __name__ == "__main__":
    main()
