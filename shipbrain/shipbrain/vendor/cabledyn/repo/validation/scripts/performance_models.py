# File: validation/scripts/performance_models.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Input files of the wall-clock cases timed by ``performance_records.py``.

The writers produce the CableDyn driver decks with their prescribed-motion files, the
MoorDyn-C deck of the tension-only chain and the refined MoorDyn-F decks of the lazy-wave
spans. The OrcaFlex models are built by the reference tools themselves
(``orcaflex_lazywave_dynamic_reference.py`` and ``orcaflex_longduration_mooring.py``).

Cases
-----
``dpc``  (L5-DPC) the matched pinned-touchdown lazy-wave spans of the L3-6 protocol at 80, 200
         and 800 m: suspended span only, hang-off at (0, 0, -14) heaved 3 sin(2 pi t / 12) m,
         touchdown pinned at the static touchdown point, no seabed in reach, still water,
         Cdn 1.2 / Cdt 0.1 / Can 1.0 / Cat 0, 60 s at dt 0.05 s.
``v``    (L5-V) one IEA-15MW VolturnUS-S chain (850 m, 50 segments, 200 m water) for one hour:
         fairlead surge 5 sin(2 pi t / 90) m and heave 2 sin(2 pi t / 12) m behind a 100 s
         half-cosine ramp (the ``l3_longduration_mooring`` drive), dt 0.1 s.
``wc``   (L5-wc) the WD0050 grounded chain of ``examples/wd0050_chain.dat`` under the
         L2-2 A1 fairlead heave 2 sin(2 pi t / 10) m for 80 s (60 s warm-up and the 20 s
         scored window of ``l2_2_dynamic_parity``).
"""

from __future__ import annotations

import copy
import math
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

GRAV = 9.80665
RHOW = 1025.0

# --------------------------------------------------------------------------------------------
# L5-DPC: matched pinned-touchdown lazy-wave spans (the constants of the L3-6 reference tools)
# --------------------------------------------------------------------------------------------
DPC_DT = 0.05
DPC_TMAX = 60.0
DPC_AMP, DPC_PERIOD = 3.0, 12.0
DPC_HANGOFF = (0.0, 0.0, -14.0)
DPC_BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)
DPC_SITES = {
    "80m": dict(
        touchdown=(83.875401, 0.0, -80.0),
        sections=[("bare", 68.114), ("buoy", 50.0), ("bare", 134.10728 - 118.114)],
        buoy=dict(od=0.29, mass=59.53, ea=4.69e8, ei=1.99e4),
        elements=240,
    ),
    "200m": dict(
        touchdown=(108.969530, 0.0, -199.999951),
        sections=[("bare", 171.978), ("buoy", 60.0), ("bare", 262.50768 - 231.978)],
        buoy=dict(od=0.30, mass=60.85, ea=4.69e8, ei=1.99e4),
        elements=480,
    ),
    "800m": dict(
        touchdown=(349.884466, 0.0, -799.999769),
        sections=[("bare", 372.449), ("buoy", 400.0), ("bare", 920.43387 - 772.449)],
        buoy=dict(od=0.29, mass=59.17, ea=4.69e8, ei=1.99e4),
        elements=960,
    ),
}
# Scored window of the L3-6 protocol (the last three heave periods).
DPC_WINDOW = (24.0, 60.0)
# MoorDyn-F: the native design meshes of moordyn_lazywave_dynamic_reference.py refined fourfold,
# at the largest explicit step whose halving moves every scored response by less than 0.01 %.
MDF_REFINEMENT = 4
MDF_DTM = {"80m": 1.25e-4, "200m": 1.25e-4, "800m": 5.0e-4}


def section_segments(lengths: list[float], total: int) -> list[int]:
    """Split ``total`` elements over the sections in proportion to length (largest remainder)."""
    span = sum(lengths)
    raw = [total * length / span for length in lengths]
    counts = [math.floor(value) for value in raw]
    order = sorted(range(len(raw)), key=lambda i: raw[i] - counts[i], reverse=True)
    for i in order[: total - sum(counts)]:
        counts[i] += 1
    return counts


def dpc_heave(t: float) -> tuple[float, float, float]:
    omega = 2.0 * math.pi / DPC_PERIOD
    return (
        DPC_AMP * math.sin(omega * t),
        DPC_AMP * omega * math.cos(omega * t),
        -DPC_AMP * omega * omega * math.sin(omega * t),
    )


def write_motion(
    path: Path, dt: float, tmax: float, base: tuple[float, float, float], motion, point: int = 1
) -> None:
    """CableDyn motion file: time, point, position, velocity and acceleration of one point."""
    rows = ["# time(s) point_id x(m) y(m) z(m) vx vy vz (m/s) ax ay az (m/s2)"]
    for k in range(round(tmax / dt) + 1):
        t = k * dt
        (dx, vx, ax), (dz, vz, az) = motion(t)
        rows.append(
            f"{t:.4f} {point} {base[0] + dx:.10e} {base[1]:.10e} {base[2] + dz:.10e} "
            f"{vx:.10e} 0.0 {vz:.10e} {ax:.10e} 0.0 {az:.10e}"
        )
    path.write_text("\n".join(rows) + "\n", encoding="ascii")


def _deck(title: str, line_types: str, points: str, sections: str, options: str, outputs: list[str]) -> str:
    out = "\n".join(f'"{name}"' for name in outputs)
    return f"""--------------------- CableDyn Input File ------------------------------------
{title}
--------------------- LINE TYPES ---------------------------------------------
TypeName  Diam   MassDenInAir  EA       BA/-zeta  EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)       (m)    (kg/m)        (N)      (N-s/-)   (N-m2)   (-)   (-)   (-)   (-)
{line_types}
--------------------- POINTS ------------------------------------------------
ID  Type     X       Y    Z      Mass  Vol  CdA  Ca
(-) (-)      (m)     (m)  (m)    (kg)  (m^3) (m^2) (-)
{points}
--------------------- LINES -------------------------------------------------
ID  NodeA  NodeB  Outputs
(-) (-)    (-)    (-)
1   1      2      -
--------------------- SECTIONS ----------------------------------------------
LineID  LineType  Length   NumSegs
(-)     (-)       (m)      (-)
{sections}
--------------------- OPTIONS -----------------------------------------------
{options}
--------------------- OUTPUTS -----------------------------------------------
{out}
--------------------- need this line ----------------------------------------
"""


def write_cabledyn_dpc(site: str, case: Path) -> dict:
    """CableDyn deck of an L5-DPC span; returns the model description."""
    s = DPC_SITES[site]
    case.mkdir(parents=True, exist_ok=True)
    counts = section_segments([length for _, length in s["sections"]], s["elements"])
    b, y = DPC_BARE, s["buoy"]
    line_types = (
        f"bare      {b['od']:.3f}  {b['mass']:.2f}  {b['ea']:.3e}  0.0  {b['ei']:.3e}  1.2  0.1  1.0  0.0\n"
        f"buoy      {y['od']:.3f}  {y['mass']:.2f}  {y['ea']:.3e}  0.0  {y['ei']:.3e}  1.2  0.1  1.0  0.0"
    )
    td = s["touchdown"]
    points = (
        f"1   Coupled  {DPC_HANGOFF[0]:.6f}  0.0  {DPC_HANGOFF[2]:.6f}  0  0  0  0\n"
        f"2   Fixed    {td[0]:.6f}  0.0  {td[2]:.6f}  0  0  0  0"
    )
    sections = "\n".join(
        f"1       {name:<8}  {length:.5f}  {n}" for (name, length), n in zip(s["sections"], counts, strict=True)
    )
    options = f"""{GRAV}  g          - Gravitational acceleration (m/s^2)
{RHOW}   rhoW       - Water density (kg/m^3)
{abs(td[2]) + 200.0:.3f}  WtrDpth    - Seabed 200 m below the pinned touchdown: no contact
{DPC_DT}     dtM        - Time step (s)
{DPC_TMAX}     TMax       - Duration (s)
motion.txt  motionFile - Hang-off heave 3 sin(2 pi t / 12) m from t = 0
dynamic_solver 1.0e-4 1.0e-14 100 12 - Newton tolerance of the shipped Lozon decks"""
    deck = _deck(
        f"L5-DPC matched pinned-touchdown lazy-wave span, {site}, {s['elements']} elements, dt {DPC_DT} s",
        line_types,
        points,
        sections,
        options,
        ["FairTen1", "AnchTen1"],
    )
    (case / "deck.dat").write_text(deck, encoding="ascii")
    write_motion(case / "motion.txt", DPC_DT, DPC_TMAX, DPC_HANGOFF, lambda t: ((0.0, 0.0, 0.0), dpc_heave(t)))
    return {"elements": s["elements"], "section_elements": counts, "time_step_s": DPC_DT}


def moordyn_f_site(site: str):
    """The MoorDyn-F span of the L3-6b reference tool, refined fourfold."""
    from moordyn_lazywave_dynamic_reference import SITES

    refined = copy.deepcopy(SITES[site])
    for section in refined.sections:
        section.nsegs *= MDF_REFINEMENT
    return refined


def write_moordyn_f_dpc(site: str, case: Path, dtm: float | None = None) -> dict:
    """Refined MoorDyn-F deck, driver input and motion of an L5-DPC span."""
    from moordyn_lazywave_dynamic_reference import TMAX, write_deck, write_driver, write_motions

    case.mkdir(parents=True, exist_ok=True)
    refined = moordyn_f_site(site)
    dtm = MDF_DTM[site] if dtm is None else dtm
    lsus, td = write_deck(refined, case, dtm)
    write_driver(refined, case, TMAX, td, inputs=True)
    write_motions(case)
    return {
        "elements": sum(section.nsegs for section in refined.sections),
        "time_step_s": dtm,
        "span_m": lsus,
        "simulated_s": TMAX,
    }


# --------------------------------------------------------------------------------------------
# L5-V: VolturnUS-S one-hour mooring (the l3_longduration_mooring drive)
# --------------------------------------------------------------------------------------------
V_DT, V_TMAX, V_RAMP = 0.1, 3600.0, 100.0
V_AX, V_T1, V_AZ, V_T2 = 5.0, 90.0, 2.0, 12.0
V_FAIRLEAD = (58.0, 0.0, -14.0)
V_WINDOW = (200.0, 3600.0)


def _ramped(amplitude: float, period: float, t: float) -> tuple[float, float, float]:
    """amplitude r(t) sin(omega t) with the rest-consistent half-cosine ramp r over V_RAMP."""
    omega = 2.0 * math.pi / period
    if t < V_RAMP:
        r = 0.5 * (1.0 - math.cos(math.pi * t / V_RAMP))
        dr = 0.5 * (math.pi / V_RAMP) * math.sin(math.pi * t / V_RAMP)
        ddr = 0.5 * (math.pi / V_RAMP) ** 2 * math.cos(math.pi * t / V_RAMP)
    else:
        r, dr, ddr = 1.0, 0.0, 0.0
    s, c = math.sin(omega * t), math.cos(omega * t)
    return (
        amplitude * r * s,
        amplitude * (dr * s + r * omega * c),
        amplitude * (ddr * s + 2.0 * dr * omega * c - r * omega * omega * s),
    )


def write_cabledyn_v(case: Path) -> dict:
    """CableDyn deck of L5-V: examples/iea15mw_volturnus_mooring.dat with the one-hour drive."""
    case.mkdir(parents=True, exist_ok=True)
    source = (REPO / "examples" / "iea15mw_volturnus_mooring.dat").read_text(encoding="utf-8")
    marker = "--------------------- OUTPUTS"
    head, tail = source.split(marker, 1)
    # The l3_longduration_mooring gate carries no seabed damping.
    head = head.replace("1.0e4    cBot", "0.0      cBot", 1)
    extra = (
        f"{V_DT}      dtM        - Time step (s)\n"
        f"{V_TMAX}   TMax       - One hour (s)\n"
        "motion.txt  motionFile - Fairlead surge 5 m / 90 s and heave 2 m / 12 s behind a 100 s ramp\n"
    )
    deck = head.replace("-- Complete option/default reference", extra + "-- Complete option/default reference", 1)
    (case / "deck.dat").write_text(deck + marker + tail, encoding="ascii")
    write_motion(
        case / "motion.txt",
        V_DT,
        V_TMAX,
        V_FAIRLEAD,
        lambda t: (_ramped(V_AX, V_T1, t), _ramped(V_AZ, V_T2, t)),
        point=2,
    )
    return {"elements": 50, "time_step_s": V_DT}


# --------------------------------------------------------------------------------------------
# L5-wc: WD0050 grounded chain, L2-2 A1 heave
# --------------------------------------------------------------------------------------------
WC_DT, WC_WARMUP, WC_SCORE = 0.05, 60.0, 20.0
WC_AMP, WC_PERIOD = 2.0, 10.0
WC_COUPLING_DT = 0.1  # MoorDyn-C coupling step of moordyn_c_driver.cpp (its output interval)
WC_MDC_DTM = 1.0e-3


def wc_heave(t: float) -> tuple[float, float, float]:
    omega = 2.0 * math.pi / WC_PERIOD
    return (
        WC_AMP * math.sin(omega * t),
        WC_AMP * omega * math.cos(omega * t),
        -WC_AMP * omega * omega * math.sin(omega * t),
    )


def write_cabledyn_wc(case: Path) -> dict:
    """CableDyn deck of L5-wc: examples/wd0050_chain.dat with the 80 s A1 heave."""
    case.mkdir(parents=True, exist_ok=True)
    source = (REPO / "examples" / "wd0050_chain.dat").read_text(encoding="utf-8")
    tmax = WC_WARMUP + WC_SCORE
    extra = (
        f"{WC_DT}      dtM        - Time step (s)\n"
        f"{tmax}       TMax       - 60 s warm-up and the 20 s scored window (s)\n"
        "motion.txt  motionFile - Fairlead heave 2 sin(2 pi t / 10) m from t = 0\n"
    )
    deck = source.replace("-- Complete option/default reference", extra + "-- Complete option/default reference", 1)
    (case / "deck.dat").write_text(deck, encoding="ascii")
    # sin(2 pi (t - 60) / 10) = sin(2 pi t / 10): the scored window [60, 80] s is the L2-2 window.
    write_motion(case / "motion.txt", WC_DT, tmax, (0.0, 0.0, 0.0), lambda t: ((0.0, 0.0, 0.0), wc_heave(t)), point=2)
    return {"elements": 41, "time_step_s": WC_DT}


def write_moordyn_c_wc(case: Path, dtm: float = WC_MDC_DTM) -> dict:
    """MoorDyn-C v2 deck of the WD0050 chain (line from the coupled fairlead to the anchor)."""
    case.mkdir(parents=True, exist_ok=True)
    deck = f"""--------------------- MoorDyn Input File ------------------------------------
L5-wc WD0050 grounded chain (fairlead -> anchor), L2-2 A1 heave
----------------------- LINE TYPES ------------------------------------------
TypeName   Diam    Mass/m     EA         BA/-zeta    EI         Cd     Ca     CdAx    CaAx
(name)     (m)     (kg/m)     (N)        (N-s/-)     (N-m^2)    (-)    (-)    (-)     (-)
chain      0.252   390.0      1.674e9    -1.0        0          1.37   1.0    0.64    0.0
---------------------- POINT PROPERTIES --------------------------------
ID    Type      X       Y       Z       Mass   Volume  CdA    Ca
(#)   (-)       (m)     (m)     (m)     (kg)   (m^3)   (m^2)  (-)
1     Coupled   0.0     0.0     0.0     0      0       0      0
2     Fixed     400.0   0.0     -50.0   0      0       0      0
---------------------- LINES ----------------------------------------
ID   LineType   AttachA  AttachB  UnstrLen  NumSegs  LineOutputs
(#)   (name)     (#)      (#)       (m)       (-)     (-)
1     chain      1        2         410.0     41      -
---------------------- OPTIONS -----------------------------------------
{dtm}         dtM                  time step to use in mooring integration (s)
RK2           tScheme              time integration scheme
3.0e6         kBot                 bottom stiffness (Pa/m)
3.0e5         cBot                 bottom damping (Pa-s/m)
1025.0        WtrDnsty             water density (kg/m^3)
50            WtrDpth              water depth (m)
1.0           dtIC                 time interval for analyzing convergence during IC gen (s)
60.0          TmaxIC               max time for ic gen (s)
4.0           CdScaleIC            factor by which to scale drag coefficients during dynamic relaxation (-)
0.001         threshIC             threshold for IC convergence (-)
------------------------- need this line --------------------------------------
"""
    (case / "deck.txt").write_text(deck, encoding="ascii")
    return {"elements": 41, "time_step_s": dtm}
