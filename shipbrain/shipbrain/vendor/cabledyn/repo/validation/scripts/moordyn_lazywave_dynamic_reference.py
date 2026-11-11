# File: validation/scripts/moordyn_lazywave_dynamic_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""MoorDyn-F dynamic lazy-wave references (L3-6b): the third-code dynamic comparison.

Runs the OpenFAST v5.0.0 MoorDyn driver (MoorDyn v2, ``MoorDyn_Driver.exe`` on PATH) on
span-only lazy-wave decks matched to the committed L3-6 protocol (the same protocol the
OrcaFlex references and the CableDyn gate use):

* the MATCHED SUSPENDED SPAN in the site frame — hang-off at (0, 0, -14) as a **Coupled
  point** (pinned end, three coupled DOFs), touchdown **Fixed point** at the committed
  seed's touchdown coordinates (pinned), zero-length free connector rods at the section
  junctions (MoorDyn requires a rod at a line-property transition, Hall et al. 2020);
* section arc lengths per Lozon Tables 3/4/11/16/21 at MoorDyn's native design mesh
  densities (the vendored coupled-deck segmentation: ~2.6 m at 80 m, ~5.7/3 m at 200 m,
  ~18.6/13.3 m at 800 m), bottom sections shortened to the pinned touchdown at the same
  density;
* still water, no seabed in reach (WtrDpth = |z_td| + 200), matched hydro
  (Cd 1.2 / Ca 1.0 / CdAx 0.1 / CaAx 0 — MoorDyn's axial drag shares the skin pi*d*L
  convention, Hall 2015 sec. 2.2, so CdAx 0.1 matches the committed protocol's Cdt);
* drive: hang-off harmonic heave z(t) = -14 + 3 sin(2*pi*t/12) via the driver's
  InputsMode-1 time series, dt = 0.05 s, TMax = 60 s, scored on t in [24, 60].

REFERENCE CHECKS (five checks, enforced in-run — every check fails closed):
  1. TOOLCHAIN REPRODUCTION — before anything varies, the committed 200 m static deck
     (validation/scripts/moordyn_lozon/cable_200m.dat) is re-run and its committed peak curvature
     (0.0809) must reproduce; a mismatch aborts the run.
  2. PINNED SETTINGS — every solver/output control is explicit in the generated decks
     (dtM / tScheme / kBot / cBot / IC controls / dtC); nothing rides a tool default.
  3. dt-CONVERGENCE OF THE REFERENCE — every dynamic case re-runs at dtM/2; the scored
     channels must move < 0.01% (the enforced acceptance bound; measured <= 0.001%).
  4. DRIVE PURITY BY READ-BACK — the coupled hang-off node's output z-trace must match
     the commanded 3 m / 12 s harmonic to < 2e-3 m in amplitude and mean (no driver
     interpolation distortion), asserted per case.
  5. IC SETTLEMENT — MoorDyn initialises by dynamic relaxation
     terminated by threshIC, a TENSION-change criterion, and tension settles much
     faster than geometry. The community-typical threshIC = 0.001 / TmaxIC = 300 leaves
     the 800 m sag-bend static curvature ~32% above its converged value (measured
     0.0319 vs 0.0241 at the native mesh) while the tensions are already converged —
     the tension-vs-curvature convergence asymmetry in miniature. The reference decks
     therefore relax to threshIC = 1e-5 / TmaxIC = 900, and each site's static is
     settlement-VERIFIED by re-running at 1e-6 / 1800 and requiring the peak to move
     < 0.5%.

Statics (TMax 0) run first per site and are cross-checked against the known static
three-code band before any dynamic scalar is trusted.

Usage:
    python validation/scripts/moordyn_lazywave_dynamic_reference.py [site ...]   # default: all three

Outputs land under build/moordyn_refs/<site>/ (decks, driver inputs, motions, raw .out)
with the scored scalars printed and collected in build/moordyn_refs/summary.txt.
"""

from __future__ import annotations

import math
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "build" / "moordyn_refs"

GRAV = 9.80665
RHOW = 1025.0
AMP, PER = 3.0, 12.0
# The MD driver LOW-PASS FILTERS prescribed motions (MoorDyn_Driver.f90: alpha = 0.1
# forward+backward exponential smoothing PER dtC SAMPLE, hardcoded) -- at dtC = 0.05 a
# 12 s harmonic attenuates ~5.8% with boundary transients at both series ends. The
# filter's time constant is in SAMPLES, so a small dtC makes it negligible: at
# dtC = 0.0025 the two-pass attenuation is ~0.014% (~0.4 mm on the 3 m drive), verified
# by the read-back assertion. The run extends past the scored window so the backward
# filter pass's end-boundary transient falls outside [24, 60]; channels are scored on
# the protocol's 0.05 s grid (subsampled), matching the OrcaFlex/CableDyn sampling.
TMAX, DTC = 61.5, 0.0025
T_SCORE, T_END = 24.0, 60.0
DT_GRID = 0.05
DTM = 0.0005

BARE = ("bare_cable", 0.1600, 36.70, 4.69e8, 1.99e4)


@dataclass
class Section:
    typ: str
    length: float
    nsegs: int


@dataclass
class Site:
    name: str
    seed: str
    buoy: tuple  # (name, diam, mass, EA, EI)
    sections: list  # top -> bottom
    junction_arcs: list  # arc from hang-off at each section boundary (len = nsec - 1)
    kstat_band: tuple  # (OrcaFlex static peak, rel band) sanity check


SITES = {
    "80m": Site(
        "80m", "gomex80_lazywave_seed.xyz",
        ("buoy_cable", 0.29, 59.53, 4.69e8, 1.99e4),
        [Section("bare_cable", 68.114, 26), Section("buoy_cable", 50.0, 20),
         Section("bare_cable", 15.993, 6)],
        [68.114, 118.114],
        (0.0968, 0.15),
    ),
    "200m": Site(
        "200m", "gomaine200_lazywave_seed.xyz",
        ("buoy_cable", 0.30, 60.85, 4.69e8, 1.99e4),
        [Section("bare_cable", 171.978, 30), Section("buoy_cable", 60.0, 20),
         Section("bare_cable", 30.530, 6)],
        [171.978, 231.978],
        # native 5.7/3 m mesh: the settled static under-reads the sag bend (documented
        # mechanism); band wide enough to admit the under-read, not a parity cell
        (0.0831, 0.30),
    ),
    "800m": Site(
        "800m", "humboldt_lazywave_seed.xyz",
        ("buoy_cable", 0.29, 59.17, 4.69e8, 1.99e4),
        [Section("bare_cable", 372.449, 20), Section("buoy_cable", 400.0, 30),
         Section("bare_cable", 147.985, 8)],
        [372.449, 772.449],
        # MoorDyn's native 18.6 m mesh under-resolves the deep sag bend (the documented
        # mechanism): the settled static reads 0.0241 vs the matched-pinned OrcaFlex
        # 0.0264 -- the sanity band admits the under-read, it is not a parity cell.
        (0.0264, 0.20),
    ),
}


def read_seed(site: Site):
    path = REPO / "tests" / "data" / site.seed
    with open(path) as f:
        nn_s, lsus_s = f.readline().split()
        nn, lsus = int(nn_s), float(lsus_s)
        f.readline()
        pos = np.array([[float(x) for x in f.readline().split()] for _ in range(nn)])
    pos[:, 2] -= 14.0  # site frame
    return lsus, pos


def polyline_at(pos, lsus, arc):
    ds = lsus / (len(pos) - 1)
    k = min(int(arc / ds), len(pos) - 2)
    t = (arc - k * ds) / ds
    return (1 - t) * pos[k] + t * pos[k + 1]


def write_deck(site: Site, case: Path, dtm: float, tmax_ic: float = 900.0,
               thresh_ic: float = 1e-5):
    lsus, pos = read_seed(site)
    td = pos[-1]
    rods, lines = [], []
    for j, arc in enumerate(site.junction_arcs, start=1):
        p = polyline_at(pos, lsus, arc)
        rods.append(f"{j}    connector  Free    {p[0]:10.3f}   0.000  {p[2]:10.3f}  "
                    f"{p[0] + 0.001:10.3f}   0.000  {p[2]:10.3f}   0       -")
    nsec = len(site.sections)
    for i, sec in enumerate(site.sections):
        # line i runs LOWER -> UPPER: AttachB is the upper attachment
        upper = "1" if i == 0 else f"R{i}B"
        lower = "2" if i == nsec - 1 else f"R{i + 1}A"
        lines.append(f"{i + 1}    {sec.typ:<11} {lower:<9} {upper:<9} {sec.length:9.3f}  "
                     f"{sec.nsegs:>3}      pKt")
    bname, bd, bm, bea, bei = site.buoy
    # IC settlement: MoorDyn initialises by dynamic relaxation
    # terminated by threshIC, a TENSION-change criterion. Tension settles much faster
    # than GEOMETRY (curvature), so the community-typical threshIC = 0.001 / TmaxIC = 300
    # leaves the 800 m sag-bend curvature ~32% above its settled value while the tensions
    # are already converged (measured: native-mesh static 0.0319 loose vs 0.0241 settled).
    # The reference therefore relaxes to threshIC = 1e-5 with TmaxIC = 900, and check
    # item 5 below verifies settlement by tightening further and requiring the static
    # peak to hold.
    deck = f"""--------------------- MoorDyn Input File ------------------------------------
L3-6b matched suspended span, {site.name} Lozon lazy-wave cable (coupled hang-off point)
FALSE    Echo
----------------------- LINE TYPES ------------------------------------------
Name  Diam  MassDen  EA       BA/-zeta  EI    Cd    Ca    CdAx   CaAx
(-)   (m)   (kg/m)   (N)      (N-s/-)   (-)   (-)   (-)   (-)    (-)
bare_cable  {BARE[1]:.4f}    {BARE[2]:.2f}     {BARE[3]:.2e}      -1.0     {BARE[4]:.2e}    1.2     1.0     0.100     0.0
{bname}  {bd:.4f}    {bm:.2f}     {bea:.2e}      -1.0     {bei:.2e}    1.2     1.0     0.100     0.0
---------------------- ROD TYPES ---------------------------------------------------------------
TypeName Diam Mass/m Cd Ca CdEnd CaEnd
(name) (m) (kg/m) (-) (-) (-) (-)
connector    0.0100     0.00   0.00   0.00     0.00     0.00
---------------------- BODIES ---------------------------------------
ID   Attachment  X0     Y0    Z0     r0      p0     y0     Mass  CG*   I*      Volume   CdA*   Ca*
(#)   (word)     (m)    (m)   (m)   (deg)   (deg)  (deg)   (kg)  (m)  (kg-m^2)  (m^3)   (m^2)  (-)
---------------------- POINTS --------------------------------
ID   Type      X         Y       Z       M    V    CdA   CA
(-)  (-)      (m)       (m)     (m)    (kg) (m^3) (m^2) (-)
1     Coupled      0.000     0.000   -14.000      0     0      0     0
2     Fixed    {td[0]:9.3f}     0.000  {td[2]:9.3f}      0     0      0     0
---------------------- RODS --------------------------------------------------------------------
ID RodType Attachment Xa Ya Za Xb Yb Zb NumSegs RodOutputs
(#) (name) (#/key) (m) (m) (m) (m) (m) (m) (-) (-)
{chr(10).join(rods)}
---------------------- LINES --------------------------------------
ID  LineType  AttachA   AttachB  UnstrLen  NumSegs  Outputs
(-)   (-)       (-)       (-)      (m)       (-)      (-)
{chr(10).join(lines)}
---------------------- SOLVER OPTIONS ---------------------------------------
{dtm}     dtM
RK4        tScheme
3.0e6      kBot
3.0e5      cBot
1.0        dtIC
{tmax_ic}      TmaxIC
4.0        CdScaleIC
{thresh_ic}    threshIC
------------------------ OUTPUTS --------------------------------------------
LINE1TENB
POINT1FZ
END
------------------------- need this line --------------------------------------
"""
    (case / "deck.dat").write_text(deck)
    return lsus, td


def write_driver(site: Site, case: Path, tmax: float, td, inputs: bool):
    wdepth = abs(td[2]) + 200.0
    drv = f"""MoorDyn driver - L3-6b {site.name} lazy-wave span ({'dynamic' if inputs else 'static'})
----------------------- ENVIRONMENTAL CONDITIONS -------------------------------
{GRAV}                 Gravity
{RHOW}                  rhoW
{wdepth}                   WtrDpth
----------------------- MOORDYN ------------------------------------------------
"deck.dat"              MDInputFile
"MD"                    OutRootName
{tmax}                  TMax
{DTC}                   dtC
{1 if inputs else 0}                       InputsMode
{'"motions.dat"' if inputs else '""'}                      InputsFile
0                       NumTurbines
----------------------- Initial Positions --------------------------------------
ref_X ref_Y surge sway heave roll pitch yaw
(m)(m)(m)(m)(m)(rad)(rad)(rad)
0 0 0 0 0 0 0 0
END of driver input file
"""
    (case / "driver.inp").write_text(drv)


def write_motions(case: Path):
    rows = []
    t = 0.0
    while t <= TMAX + 1e-9:
        z = -14.0 + AMP * math.sin(2 * math.pi * t / PER)
        rows.append(f"{t:.4f}  0.0  0.0  {z:.8f}")
        t += DTC
    (case / "motions.dat").write_text("\n".join(rows) + "\n")


def run_driver(case: Path):
    exe = shutil.which("MoorDyn_Driver.exe") or shutil.which("moordyn_driver")
    r = subprocess.run([exe, "driver.inp"], cwd=case, capture_output=True, text=True,
                       timeout=3600)
    if r.returncode != 0:
        raise RuntimeError(f"driver failed in {case}:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")


def parse_line_out(path: Path):
    """MoorDyn .out parser tolerant of wrapped header/unit rows: the channel-name header
    (starting at the 'Time' token) and the unit row may each span several physical lines;
    data rows are single lines whose first token parses as a float."""
    lines = path.read_text().splitlines()
    names, rows, collecting = [], [], False
    for ln in lines:
        toks = ln.split()
        if not toks:
            continue
        if not collecting:
            if toks[0] == "Time":
                collecting = True
                names.extend(toks)
            continue
        if toks[0].startswith("("):
            continue                      # unit row(s)
        try:
            float(toks[0])
        except ValueError:
            names.extend(toks)            # wrapped header continuation
            continue
        rows.append(list(map(float, toks)))
    arr = np.array(rows)
    if arr.ndim != 2 or arr.shape[1] != len(names):
        raise RuntimeError(f"{path}: parsed {len(names)} names vs data width "
                           f"{arr.shape[1] if arr.ndim == 2 else 'ragged'}")
    return names, arr


def parse_main_out(path: Path):
    return parse_line_out(path)


def curvature_series(site: Site, case: Path, lsus: float):
    """Per-node curvature over time with the node's arc from the hang-off + rod-adjacency."""
    arcs, kurv, at_rod = [], [], []
    sec_top = 0.0
    for i, sec in enumerate(site.sections):
        names, arr = parse_line_out(case / f"MD.MD.Line{i + 1}.out")
        kcols = [(int(re.match(r"Node(\d+)Kurv", n).group(1)), j)
                 for j, n in enumerate(names) if re.match(r"Node\d+Kurv", n)]
        kcols.sort()
        seg = sec.length / sec.nsegs
        for node, j in kcols:
            # line runs LOWER -> UPPER: node 0 = lower end
            arc = sec_top + sec.length - node * seg
            arcs.append(arc)
            kurv.append(arr[:, j])
            # end nodes attach to a rod (interior junctions) or a point (span ends)
            at_rod.append((node == 0 and i < len(site.sections) - 1)
                          or (node == sec.nsegs and i > 0))
        sec_top += sec.length
        tgrid = arr[:, 0]
    return tgrid, np.array(arcs), np.array(kurv), np.array(at_rod)


def hangoff_z_series(site: Site, case: Path):
    names, arr = parse_line_out(case / "MD.MD.Line1.out")
    n_top = site.sections[0].nsegs
    j = names.index(f"Node{n_top}pz")
    return arr[:, 0], arr[:, j]


def tension_series(case: Path):
    names, arr = parse_main_out(case / "MD.MD.out")
    j = names.index("LINE1TENB")
    return arr[:, 0], arr[:, j]


def grid_mask(t):
    """Rows on the protocol's 0.05 s scoring grid within the [T_SCORE, T_END] window."""
    on_grid = np.abs(t / DT_GRID - np.round(t / DT_GRID)) < 1e-6
    return on_grid & (t >= T_SCORE - 1e-9) & (t <= T_END + 1e-9)


def score(site: Site, case: Path, lsus: float):
    tg, arcs, K, at_rod = curvature_series(site, case, lsus)
    interior = (arcs >= 0.03 * lsus) & (arcs <= 0.97 * lsus)
    win = grid_mask(tg)
    kstat = float(K[interior, 0].max())
    kdyn = float(K[np.ix_(interior, win)].max())
    off_rod = interior & ~at_rod
    kstat_norod = float(K[off_rod, 0].max())
    kdyn_norod = float(K[np.ix_(off_rod, win)].max())
    tt, ten = tension_series(case)
    tw = ten[grid_mask(tt)] / 1e3
    tz, zz = hangoff_z_series(site, case)
    zcmd = -14.0 + AMP * np.sin(2 * math.pi * tz / PER)
    wz = grid_mask(tz)
    # Drive read-back: the coupling loop applies the motion with an inherent one-dtC
    # sample lag (protocol-benign: a 2.5 ms shift of a 12 s harmonic moves no scored
    # extremum), so the assertion is SHIFT-INVARIANT -- amplitude and mean of the
    # applied heave must match the command; this is what catches the driver's motion
    # filter (5.8% amplitude loss at dtC = 0.05) and any scaling/offset distortion.
    # The pointwise error is reported for information.
    amp_err = abs((zz[wz].max() - zz[wz].min()) / 2.0 - AMP)
    mean_err = abs(zz[wz].mean() + 14.0)
    zerr = float(np.abs(zz[wz] - zcmd[wz]).max())
    return dict(kstat=kstat, kdyn=kdyn, ampl=kdyn / kstat,
                kstat_norod=kstat_norod, kdyn_norod=kdyn_norod,
                tmean=float(tw.mean()), tmin=float(tw.min()), tmax=float(tw.max()),
                drive_err=zerr, drive_amp_err=float(amp_err), drive_mean_err=float(mean_err))


def check_reproduce_200m(tmp: Path):
    """Item 1: the committed 200 m static deck must reproduce its committed curvature."""
    case = tmp / "check_200m"
    case.mkdir(parents=True, exist_ok=True)
    shutil.copy(REPO / "validation" / "scripts" / "moordyn_lozon" / "cable_200m.dat", case / "cable_200m.dat")
    (case / "driver.inp").write_text(f"""MoorDyn driver - reference reproduction
----------------------- ENVIRONMENTAL CONDITIONS -------------------------------
{GRAV}                 Gravity
{RHOW}                  rhoW
200.0                   WtrDpth
----------------------- MOORDYN ------------------------------------------------
"cable_200m.dat"        MDInputFile
"MD"                    OutRootName
0.0                     TMax
0.01                    dtC
0                       InputsMode
""                      InputsFile
0                       NumTurbines
----------------------- Initial Positions --------------------------------------
ref_X ref_Y surge sway heave roll pitch yaw
(m)(m)(m)(m)(m)(rad)(rad)(rad)
0 0 0 0 0 0 0 0
END of driver input file
""")
    run_driver(case)
    kmax = 0.0
    for f in sorted(case.glob("MD.MD.Line*.out")):
        names, arr = parse_line_out(f)
        kc = [j for j, n in enumerate(names) if re.match(r"Node\d+Kurv", n)]
        kmax = max(kmax, float(arr[0, kc].max()))
    ok = abs(kmax - 0.0809) / 0.0809 < 0.005
    print(f"[check 1] committed 200 m static peak reproduction: {kmax:.6f} vs 0.0809 "
          f"-> {'OK' if ok else 'MISMATCH - ABORT'}")
    if not ok:
        sys.exit(1)


def static_peak(site: Site, case: Path, lsus: float):
    _, arcs, K, _ = curvature_series(site, case, lsus)
    interior = (arcs >= 0.03 * lsus) & (arcs <= 0.97 * lsus)
    return float(K[interior, 0].max())


def run_site(site: Site):
    print(f"\n=== {site.name} ===")
    base = OUT / site.name
    # --- static ---
    stat = base / "static"
    stat.mkdir(parents=True, exist_ok=True)
    lsus, td = write_deck(site, stat, DTM)
    write_driver(site, stat, 0.0, td, inputs=False)
    run_driver(stat)
    kstat = static_peak(site, stat, lsus)
    ref, band = site.kstat_band
    print(f"static peak curvature = {kstat:.6f}  (band check vs {ref}: "
          f"{100 * abs(kstat - ref) / ref:.1f}% <= {100 * band:.0f}%"
          f" {'OK' if abs(kstat - ref) / ref <= band else 'OUT OF BAND - ABORT'})")
    if abs(kstat - ref) / ref > band:
        sys.exit(1)   # fail closed: a mis-built static invalidates the dynamic reference
    # --- check 5: IC-settlement verification (relaxation IS MoorDyn's static solve;
    # tension-criterion termination must not leave the GEOMETRY unsettled) ---
    settle = base / "static_settle"
    settle.mkdir(parents=True, exist_ok=True)
    write_deck(site, settle, DTM, tmax_ic=1800.0, thresh_ic=1e-6)
    write_driver(site, settle, 0.0, td, inputs=False)
    run_driver(settle)
    k2 = static_peak(site, settle, lsus)
    move = abs(k2 - kstat) / max(kstat, 1e-12)
    print(f"[check 5] IC settlement (TmaxIC 900/1e-5 vs 1800/1e-6): static peak "
          f"{kstat:.6f} vs {k2:.6f} (move {100 * move:.3f}%) -> "
          f"{'SETTLED' if move < 0.005 else 'UNSETTLED - ABORT'}")
    if move >= 0.005:
        sys.exit(1)   # fail closed: the IC state is not the converged static
    # --- dynamic, primary dtM + halved (check 3) ---
    results = {}
    for tag, dtm in (("dyn", DTM), ("dyn_half", DTM / 2)):
        case = base / tag
        case.mkdir(parents=True, exist_ok=True)
        write_deck(site, case, dtm)
        write_driver(site, case, TMAX, td, inputs=True)
        write_motions(case)
        run_driver(case)
        results[tag] = score(site, case, lsus)
        r = results[tag]
        print(f"[{tag}] kstat {r['kstat']:.6f}  kdyn {r['kdyn']:.6f}  ampl {r['ampl']:.4f}  "
              f"T mean/min/max {r['tmean']:.4f}/{r['tmin']:.4f}/{r['tmax']:.4f} kN  "
              f"(no-rod kdyn {r['kdyn_norod']:.6f})  drive amp/mean/pointwise err "
              f"{r['drive_amp_err']:.2e}/{r['drive_mean_err']:.2e}/{r['drive_err']:.2e} m")
        if r["drive_amp_err"] > 2e-3 or r["drive_mean_err"] > 2e-3:
            print("  [check 4] DRIVE READ-BACK FAILED (amplitude/mean distortion)")
            sys.exit(1)
    a, b = results["dyn"], results["dyn_half"]
    conv = {k: abs(a[k] - b[k]) / max(abs(b[k]), 1e-12)
            for k in ("kdyn", "tmean", "tmin", "tmax")}
    worst = max(conv.values())
    # Acceptance bound 0.01% -- one order above the worst measured move (<= 0.001% at all
    # three sites), three orders below the tightest parity gate the references feed (1.5%).
    print(f"[check 3] dtM convergence (dtM {DTM} vs {DTM / 2}): worst channel move "
          f"{100 * worst:.4f}% -> {'CONVERGED' if worst < 1e-4 else 'NOT CONVERGED - ABORT'}")
    if worst >= 1e-4:
        sys.exit(1)   # fail closed: a dt-unconverged reference must not reach summary.txt
    return dict(site=site.name, **results["dyn"], dt_conv=worst)


def main(argv):
    names = argv or list(SITES)
    OUT.mkdir(parents=True, exist_ok=True)
    check_reproduce_200m(OUT)
    summary = [run_site(SITES[n]) for n in names]
    lines = []
    for s in summary:
        lines.append(f"{s['site']}: kstat={s['kstat']:.6f} kdyn={s['kdyn']:.6f} "
                     f"ampl={s['ampl']:.4f} T={s['tmean']:.4f}/{s['tmin']:.4f}/{s['tmax']:.4f} kN "
                     f"kdyn_norod={s['kdyn_norod']:.6f} dtconv={100 * s['dt_conv']:.3f}%")
    (OUT / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(["", "=== SUMMARY ==="] + lines))


if __name__ == "__main__":
    main(sys.argv[1:])
