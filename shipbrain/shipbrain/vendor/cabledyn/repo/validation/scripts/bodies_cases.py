# File: validation/scripts/bodies_cases.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Case definitions of the bodies validation suite.

Writes, for every case, the CableDyn deck (MoorDyn v2 row dialect), the MoorDyn-C
twin (same numbers, MoorDyn v2 columns) and any shared auxiliary file into
``validation/bodies/cases/<ID>/``, plus ``validation/bodies/cases.json``: the machine-readable
case matrix (reference runs, scored channels, metrics and gates) read by
``bodies_run_moordyn_c.py``, ``bodies_analytic.py`` and ``bodies_score.py``.

Run:  python validation/scripts/bodies_cases.py
"""

from __future__ import annotations

import json
import math

from bodies_common import BODIES, CASES
from bodies_decks import G, RHO, cd_deck, md_deck

# --------------------------------------------------------------------------------------
# Shared data
# --------------------------------------------------------------------------------------

POLY_BUOY = dict(name="poly", d=0.12, m=15.0, EA=5.0e7, BA=-1.0, Cd=1.2, Ca=1.0, CdAx=0.2, CaAx=0.0)
POLY_SPAR = dict(name="poly", d=0.10, m=10.0, EA=2.0e7, BA=-1.0, Cd=1.2, Ca=1.0, CdAx=0.2, CaAx=0.0)
CHAIN_IEA = dict(name="chain", d=0.333, m=685.0, EA=3.27e9, BA=-1.0, Cd=1.37, Ca=1.0, CdAx=0.64, CaAx=0.0)

# Options that switch CableDyn to the MoorDyn body and rod formulations.
PARITY_BODY = [("moordyn", "bodyWetting"), ("moordyn", "bodyHydro")]
PARITY_ROD = [("moordyn", "rodHydro")]

MANIFEST: dict[str, dict] = {}


def _write(case_id: str, files: dict[str, str]) -> None:
    d = CASES / case_id
    d.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (d / name).write_text(text, newline="\n")


def _metric(mid, metric, cd, ref_code, ref, gate, window=None, note="", **kw):
    m = dict(id=mid, metric=metric, cd=cd, ref_code=ref_code, ref=ref, gate=gate)
    if window:
        m["window"] = window
    if note:
        m["note"] = note
    m.update(kw)
    return m


# --------------------------------------------------------------------------------------
# V-D1: Rigid6 buoy on three taut legs (examples/rigid6_buoy.dat), surge decays
# --------------------------------------------------------------------------------------

def buoy_model(x0: float, nseg: int = 80) -> dict:
    return dict(
        title=f"V-D1 submerged 6-DOF buoy on three taut polyester legs, surge release from {x0} m",
        notes=["Buoy of examples/rigid6_buoy.dat (20 t, 40 m^3, z = -20 m, 100 m water), still water.",
               "Release protocol R: body held at X0 while the lines settle, then released at t = 0.",
               "Body CdA written trans|rot (MoorDyn-C 2.7.1 reads 3/6-entry lists from entry 2)."],
        line_types=[POLY_BUOY],
        bodies=[dict(id=1, att="Free", xyz=[x0, 0.0, -20.0], rpy=[0, 0, 0], mass=2.0e4, cg="0",
                     I="3.5e4", vol=40.0, cda="8|0", ca="0.5")],
        points=[
            dict(id=1, att="Body1", xyz=[1.5, 0.0, -2.0]),
            dict(id=2, att="Body1", xyz=[-0.75, 1.299, -2.0]),
            dict(id=3, att="Body1", xyz=[-0.75, -1.299, -2.0]),
            dict(id=4, att="Fixed", xyz=[40.0, 0.0, -100.0]),
            dict(id=5, att="Fixed", xyz=[-20.0, 34.641, -100.0]),
            dict(id=6, att="Fixed", xyz=[-20.0, -34.641, -100.0]),
        ],
        lines=[dict(id=i, type="poly", a=i, b=i + 3, L=86.85, nseg=nseg) for i in (1, 2, 3)],
    )


# OrcaFlex cross-check of V-D1b, scored on the summary values of the OrcaFlex series
# (references/V-D1b/orcaflex.json "summary"; the series itself is licensed output and is not
# redistributed) over t in [0.5, 120] s: statistics, the dominant fairlead-tension harmonic, the
# first two FairTen1 snap maxima and the surge decay. At 320 segments CableDyn sits 0.001-3.5 %
# from OrcaFlex; the gates leave room for OrcaFlex's own ~0.5 % mesh/dt spread at the snaps,
# and a 12.5 % body-drag or 5 % line-EA perturbation of the deck fails several of them.
OFX_WIN = [0.5, 120.0]
OFX_NOTE = "OrcaFlex 11.6d summary value (orcaflex_vd1b_reference.py); cross-check, not the pass/fail reference"


def _ofx(mid, metric, cd, gate, **kw):
    return _metric(mid, metric, cd, "orcaflex", cd, gate, window=OFX_WIN, note=OFX_NOTE, **kw)


VD1B_ORCAFLEX = [
    _ofx("of_surge_period", "e_T", "Body1Px", 0.003),
    _ofx("of_surge_min", "e_stat", "Body1Px", 0.005, stat="min", scale="excursion"),
    _ofx("of_surge_std", "e_stat", "Body1Px", 0.005, stat="std", scale="self"),
    _ofx("of_heave_std", "e_stat", "Body1Pz", 0.01, stat="std", scale="self"),
    *[m for i in (1, 2) for m in (
        _ofx(f"of_FairTen{i}_mean", "e_stat", f"FairTen{i}", 0.005, stat="mean", scale="excursion"),
        _ofx(f"of_FairTen{i}_std", "e_stat", f"FairTen{i}", 0.01, stat="std", scale="self"),
        _ofx(f"of_FairTen{i}_max", "e_stat", f"FairTen{i}", 0.05, stat="max", scale="self"),
        _ofx(f"of_FairTen{i}_harm", "e_harm", f"FairTen{i}", 0.10),
    )],
    _ofx("of_FairTen1_snap1", "e_snap", "FairTen1", 0.06, snap=0),
    _ofx("of_FairTen1_snap2", "e_snap", "FairTen1", 0.06, snap=1),
]


def case_buoy(case_id: str, x0: float, nseg: int = 80, dtm: float = 0.01,
              md_dt: tuple[float, ...] = (1e-4, 5e-5, 2.5e-5), extra_metrics: tuple = ()) -> None:
    model = buoy_model(x0, nseg)
    tmax = 120.0
    cd_outputs = ["Body1Px", "Body1Py", "Body1Pz", "Body1Rx", "Body1Ry", "Body1Rz",
                  "FairTen1", "FairTen2", "FairTen3", "AnchTen1", "AnchTen2", "AnchTen3"]
    # 80-segment legs: dtM 0.1 s under-resolves the leg modes (FairTen e_rms 1.5 % at 0.1 s,
    # 0.1 % at 0.01 s on V-D1a)
    cd = cd_deck(model, dict(depth=100.0, rows=[("deck", "bodyIC"), *PARITY_BODY, (dtm, "dtM"),
                                                 (tmax, "TMax"), ("none", "current"),
                                                 ("none", "waves")]), cd_outputs)
    md = md_deck(model, dict(dtM=5e-5, depth=100.0))
    _write(case_id, {"cabledyn.dat": cd, "moordyn.txt": md})
    gate_rms = 0.005
    MANIFEST[case_id] = dict(
        family="V-D1 decay", title=model["title"], tier="xcode",
        cabledyn_deck="cabledyn.dat", tmax=tmax,
        references=dict(moordyn_c=dict(deck="moordyn.txt", tmax=tmax, dtout=0.05, noic=True, settle=300.0,
                                        scheme="rk4", dt_levels=list(md_dt))),
        metrics=[
            _metric("surge_rms", "e_rms", "Body1Px", "moordyn_c", "Body1Px", gate_rms),
            _metric("heave_rms", "e_rms", "Body1Pz", "moordyn_c", "Body1Pz", 0.05,
                    note="heave excursion is small; gate on the relative-to-surge scale in e_rms_abs"),
            _metric("surge_period", "e_T", "Body1Px", "moordyn_c", "Body1Px", 0.003),
            *[_metric(f"FairTen{i}_rms", "e_rms", f"FairTen{i}", "moordyn_c", f"TenA{i}", gate_rms) for i in (1, 2, 3)],
            _metric("FairTen1_t0", "e_t0", "FairTen1", "moordyn_c", "TenA1", 0.005,
                    note="release protocol: initial fairlead tension within 0.5 % before scoring"),
            *extra_metrics,
        ],
    )


# --------------------------------------------------------------------------------------
# V-D2: submerged free spar rod on four legs (examples/rod_moored_spar.dat)
# --------------------------------------------------------------------------------------

def spar_model(dx: float, dz: float, cdend: float = 0.0, caend: float = 0.0, nseg: int = 20,
               lmult: int = 1) -> dict:
    # End A on top, End B below (MoorDyn-C builds a free/pinned rod's initial orientation from
    # End B's position vector, so End B must lie on the ray from the origin through End A);
    # the release offset is applied by shifting the anchors by (-dx, 0, 0), which is the same
    # physical problem as moving the rod by +dx.
    return dict(
        title=f"V-D2 submerged free spar rod on four taut legs, release dx = {dx} m, dz = {dz} m",
        notes=["Rod of examples/rod_moored_spar.dat (d 1 m, L 10 m, 300 kg/m), 50 m water, still water.",
               "End A top (z = -20), End B bottom (z = -30); anchors shifted by -dx instead of moving the rod.",
               "Release protocol R: rod held while the lines settle, released at t = 0."],
        line_types=[POLY_SPAR],
        rod_types=[dict(name="spar", d=1.0, m=300.0, Cd=0.8, Ca=1.0, CdEnd=cdend, CaEnd=caend)],
        rods=[dict(id=1, type="spar", att="Free", a=[0.0, 0.0, -20.0 + dz], b=[0.0, 0.0, -30.0 + dz],
                   nseg=nseg, out="-")],
        points=[
            dict(id=1, att="Fixed", xyz=[25.0 - dx, 0.0, -50.0]),
            dict(id=2, att="Fixed", xyz=[-25.0 - dx, 0.0, -50.0]),
            dict(id=3, att="Fixed", xyz=[-dx, 30.0, -50.0]),
            dict(id=4, att="Fixed", xyz=[-dx, -30.0, -50.0]),
        ],
        lines=[dict(id=1, type="poly", a="R1B", b=1, L=31.95, nseg=16 * lmult),
               dict(id=2, type="poly", a="R1B", b=2, L=31.95, nseg=16 * lmult),
               dict(id=3, type="poly", a="R1A", b=3, L=42.40, nseg=20 * lmult),
               dict(id=4, type="poly", a="R1A", b=4, L=42.40, nseg=20 * lmult)],
    )


def body_rod_twin(model: dict) -> dict:
    """MoorDyn-C twin of a free rod: the rod fixed to a massless, volumeless Free body at its
    centre. MoorDyn-C's free-rod equations (reference End A) do not include the centripetal and
    gyroscopic terms (commented out in Rod::doRHS), which matter in large-rotation releases;
    the body path includes them, and for planar rotation of an axisymmetric rod it is exact."""
    twin = json.loads(json.dumps(model))
    rod = twin["rods"][0]
    c = [0.5 * (a + b) for a, b in zip(rod["a"], rod["b"])]
    twin["bodies"] = [dict(id=1, att="Free", xyz=c, rpy=[0, 0, 0], mass=0.0, cg="0", I="0", vol=0.0,
                           cda="0", ca="0")]
    rod["att"] = "Body1"
    rod["a"] = [a - ci for a, ci in zip(rod["a"], c)]
    rod["b"] = [b - ci for b, ci in zip(rod["b"], c)]
    twin["md_notes"] = twin.get("md_notes", []) + [
        "MoorDyn-C twin: the free rod is expressed as a rod fixed to a massless Free body at its centre",
        "(MoorDyn-C's free-rod equations omit the centripetal term; see validation/bodies/README.md)."]
    return twin


def case_spar(case_id: str, dx: float, dz: float, large: bool, cdend=0.0, caend=0.0, lmult: int = 4,
              dtm: float = 0.002, md_dt=(2.5e-5, 1.25e-5)) -> None:
    # 64/80 line segments in both codes: the slack-taut snap needs them (16/20 segments leave a
    # 6 % error in the first extreme; 64/80 is within 0.8 % of the Richardson limit), and the
    # small releases use them too so that line discretisation stays out of the comparison.
    model = spar_model(dx, dz, cdend, caend, lmult=lmult)
    tmax = 10.0 if large else 60.0
    nseg = model["rods"][0]["nseg"]
    cd_outputs = ["Rod1Px", "Rod1Py", "Rod1Pz", f"Rod1N{nseg}Px", f"Rod1N{nseg}Py", f"Rod1N{nseg}Pz",
                  "FairTen1", "FairTen2", "FairTen3", "FairTen4"]
    cd = cd_deck(model, dict(depth=50.0, rows=[("deck", "bodyIC"), *PARITY_ROD, (dtm, "dtM"),
                                                (tmax, "TMax"), ("none", "current"), ("none", "waves")]),
                 cd_outputs)
    md = md_deck(body_rod_twin(model), dict(dtM=2.5e-5, depth=50.0))
    md_free = md_deck(model, dict(dtM=2.5e-5, depth=50.0))
    _write(case_id, {"cabledyn.dat": cd, "moordyn.txt": md, "moordyn_freerod.txt": md_free})
    g_rms = 0.05 if large else 0.02
    ch = "Rod1Px" if dx else "Rod1Pz"
    metrics = [
        _metric("endA_rms", "e_rms", ch, "moordyn_c", ch, g_rms),
        _metric("endB_rms", "e_rms", ch.replace("Rod1", f"Rod1N{nseg}"), "moordyn_c",
                ch.replace("Rod1", f"Rod1N{nseg}"), g_rms),
        *[_metric(f"FairTen{i}_rms", "e_rms", f"FairTen{i}", "moordyn_c", f"TenA{i}", g_rms)
          for i in (1, 2, 3, 4)],
        _metric("FairTen1_t0", "e_t0", "FairTen1", "moordyn_c", "TenA1", 0.005,
                note="release protocol: initial tension within 0.5 % before scoring"),
    ]
    if large:
        metrics.append(_metric("endA_peak", "e_pk", ch, "moordyn_c", ch, 0.05))
    if cdend or caend:
        # the period is scored while the decay is resolved; once the motion has decayed to the
        # mooring lines' own ringing, zero crossings of the residual are not the heave period
        # (the heave has decayed into that ringing by t = 5 s)
        # (the heave has decayed into the ringing by t = 5 s)
        metrics = [_metric("heave_period", "e_T", "Rod1Pz", "moordyn_c", "Rod1Pz", 0.01, window=[0.0, 5.0]),
                   _metric("heave_rms", "e_rms", "Rod1Pz", "moordyn_c", "Rod1Pz", 0.03)]
    MANIFEST[case_id] = dict(
        family="V-D2 decay" if not (cdend or caend) else "V-R3 ROD TYPES semantics",
        title=model["title"], tier="xcode", cabledyn_deck="cabledyn.dat", tmax=tmax,
        references=dict(moordyn_c=dict(deck="moordyn.txt", tmax=tmax, dtout=0.01, noic=True, settle=300.0,
                                        scheme="rk4", dt_levels=list(md_dt))),
        metrics=metrics,
    )


# --------------------------------------------------------------------------------------
# V-SP / V-D3: ballasted surface-piercing spar + waterplane-term check
# --------------------------------------------------------------------------------------

SPAR = dict(d=8.0, top=10.0, bottom=-80.0, mrod=5000.0, Cd=0.8, Ca=1.0, CdEnd=0.6, CaEnd=0.6,
            nseg=45, mbody=3.67e6, zcg=-70.0, Ib="1.37e8|1.37e8|2.94e7")
# Squat spar on which MoorDyn's waterplane term dominates the pitch stiffness (V-SPW).
SQUAT = dict(d=10.0, top=5.0, bottom=-20.0, mrod=1000.0, Cd=0.0, Ca=1.0, CdEnd=0.0, CaEnd=0.0,
             nseg=25, mbody=None, zcg=None, Ib=None)


def squat_ballast():
    """Body mass and CG of the squat spar: floats at 20 m draft with total z_G = -10.1 m."""
    d, L = SQUAT["d"], SQUAT["top"] - SQUAT["bottom"]
    vol = math.pi * d * d / 4.0 * (-SQUAT["bottom"])
    mtot = RHO * vol
    mrod = SQUAT["mrod"] * L
    zrod = 0.5 * (SQUAT["top"] + SQUAT["bottom"])
    zg_tot = -10.1
    mb = mtot - mrod
    zcb = (zg_tot * mtot - mrod * zrod) / mb
    ib = mb * 3.0 ** 2  # radius of gyration 3 m about the ballast CG
    return mb, zcb, ib


def surface_spar_model(p: dict, z0: float, pitch_deg: float, title: str) -> dict:
    # End A at the bottom: MoorDyn applies its rod waterplane moment only when End A is below
    # the surface and End B above. The rod is fixed to the body, so MoorDyn-C's free-rod
    # initial-orientation convention does not apply.
    if p["mbody"] is None:
        mb, zcb, ib = squat_ballast()
        cg, inertia = f"0|0|{zcb:.6f}", f"{ib:.6e}|{ib:.6e}|{0.5 * mb * 4.0:.6e}"
    else:
        mb, cg, inertia = p["mbody"], f"0|0|{p['zcg']}", p["Ib"]
    return dict(
        title=title,
        notes=["Free body at the waterline carrying a rigidly attached surface-piercing rod; no lines.",
               "Body Volume = 0: all buoyancy comes from the rod; CG/I of the body are the ballast."],
        rod_types=[dict(name="spar", d=p["d"], m=p["mrod"], Cd=p["Cd"], Ca=p["Ca"], CdEnd=p["CdEnd"],
                        CaEnd=p["CaEnd"])],
        bodies=[dict(id=1, att="Free", xyz=[0.0, 0.0, z0], rpy=[0.0, pitch_deg, 0.0], mass=mb, cg=cg,
                     I=inertia, vol=0.0, cda="0", ca="0")],
        rods=[dict(id=1, type="spar", att="Body1", a=[0.0, 0.0, p["bottom"]], b=[0.0, 0.0, p["top"]],
                   nseg=p["nseg"], out="-")],
    )


def case_surface_spar(case_id: str, p: dict, z0: float, pitch: float, tmax: float, dt_cd: float,
                      metrics: list, title: str, md_dt=(0.01, 0.005, 0.0025)) -> None:
    model = surface_spar_model(p, z0, pitch, title)
    outs = ["Body1Px", "Body1Pz", "Body1Ry", "Rod1Px", "Rod1Pz"]
    base = [("deck", "bodyIC"), (dt_cd, "dtM"), (tmax, "TMax"), ("none", "current"), ("none", "waves")]
    files = {
        "cabledyn.dat": cd_deck(model, dict(depth=200.0, rows=base), outs),
        "cabledyn_mdparity.dat": cd_deck(model, dict(depth=200.0, rows=base + PARITY_ROD), outs),
        "cabledyn_static.dat": cd_deck(model, dict(depth=200.0, rows=[("static", "bodyIC"), (dt_cd, "dtM"),
                                                                  (dt_cd, "TMax")]), outs),
        "moordyn.txt": md_deck(model, dict(dtM=md_dt[0], depth=200.0)),
    }
    _write(case_id, files)
    MANIFEST[case_id] = dict(
        family="V-SP surface-piercing spar", title=title, tier="fast / xcode",
        cabledyn_deck="cabledyn.dat", cabledyn_deck_parity="cabledyn_mdparity.dat", tmax=tmax,
        references=dict(analytic=dict(script="bodies_analytic.py"),
                        moordyn_c=dict(deck="moordyn.txt", tmax=tmax, dtout=0.05, noic=True,
                                        scheme="rk4", dt_levels=list(md_dt))),
        metrics=metrics,
    )


# --------------------------------------------------------------------------------------
# V-P1: dry pinned-rod pendulum
# --------------------------------------------------------------------------------------

PEND = dict(L=10.0, d=0.2, m=50.0, zpin=20.0)


def pend_period(theta0_deg: float) -> float:
    from scipy.special import ellipk

    L, d, m = PEND["L"], PEND["d"], PEND["m"] * PEND["L"]
    ia = m * (L * L / 3.0 + d * d / 16.0)
    w0 = math.sqrt(m * G * L / 2.0 / ia)
    k = math.sin(math.radians(theta0_deg) / 2.0)
    return 4.0 * ellipk(k * k) / w0


def case_pendulum(case_id: str, theta0: float) -> None:
    L = PEND["L"]
    th = math.radians(theta0)
    T = pend_period(theta0)
    dt = round(T / 100.0, 4)
    tmax = round(50 * T / dt) * dt
    b = [L * math.sin(th), 0.0, -L * math.cos(th)]

    def model(zpin):
        return dict(
            title=f"V-P1 dry rigid rod pendulum pinned at End A, released from {theta0} deg",
            notes=["No fluid loads act: the rod stays above the water (CableDyn deck) or rho = 0 (MoorDyn-C).",
                   "MoorDyn-C twin: pin at the origin so End B lies on the ray through End A (initial-"
                   "orientation convention), with WtrDnsty 0 instead of a dry pin at z = +20 m."],
            rod_types=[dict(name="pend", d=PEND["d"], m=PEND["m"], Cd=0.0, Ca=0.0, CdEnd=0.0, CaEnd=0.0)],
            rods=[dict(id=1, type="pend", att="Pinned", a=[0.0, 0.0, zpin],
                       b=[b[0], 0.0, zpin + b[2]], nseg=10, out="-")],
        )

    cd = cd_deck(model(PEND["zpin"]), dict(depth=100.0, rows=[("deck", "bodyIC"), (1.0, "rhoInf"),
                                                               (dt, "dtM"), (tmax, "TMax")]),
                 ["Rod1Px", "Rod1Pz", "Rod1N10Px", "Rod1N10Pz"])
    md = md_deck(model(0.0), dict(dtM=1e-3, depth=100.0, rho=0.0))
    _write(case_id, {"cabledyn.dat": cd, "moordyn.txt": md})
    MANIFEST[case_id] = dict(
        family="V-P1 pendulum", title=model(0)["title"], tier="fast",
        cabledyn_deck="cabledyn.dat", tmax=tmax, dt=dt,
        references=dict(analytic=dict(script="bodies_analytic.py"),
                        moordyn_c=dict(deck="moordyn.txt", tmax=min(tmax, 60.0), dtout=0.01, noic=True,
                                        scheme="rk4", dt_levels=[1e-3, 5e-4, 2.5e-4],
                                        note="cross-check only; channels offset by the pin height")),
        metrics=[
            _metric("period", "e_T", "derived:pend_angle", "analytic", "theta", 0.001,
                    ref_value=T),
            _metric("angle_rms", "e_rms", "derived:pend_angle", "analytic", "theta", 0.01,
                    window=[0.0, 5 * T]),

        ],
    )


# --------------------------------------------------------------------------------------
# V-S1m: minimal shared anchor (the three FS-1 lines that meet at the farm centroid)
# --------------------------------------------------------------------------------------

R_ANCH, R_FL, Z_FL, Z_AN, L_IEA = 837.6, 58.0, -14.0, -200.0, 850.0
SIDE = R_ANCH * math.sqrt(3.0)
TURBINES = [(1, 0.0, 0.0), (2, SIDE, 0.0), (3, SIDE / 2.0, SIDE * math.sqrt(3.0) / 2.0)]
CENTROID = (SIDE / 2.0, SIDE * math.sqrt(3.0) / 6.0)
SHARED_AZ = {1: 30.0, 2: 150.0, 3: 270.0}


def shared_anchor_model() -> dict:
    pts, lines = [], []
    for j, xt, yt in TURBINES:
        az = math.radians(SHARED_AZ[j])
        lx, ly = R_FL * math.cos(az), R_FL * math.sin(az)
        pts.append(dict(id=j, att=f"Turbine{j}", xyz=[round(lx, 6), round(ly, 6), Z_FL],
                        mdc_att="Coupled", mdc_xyz=[round(xt + lx, 6), round(yt + ly, 6), Z_FL]))
    pts.append(dict(id=4, att="Fixed", xyz=[round(CENTROID[0], 6), round(CENTROID[1], 6), Z_AN]))
    for j in (1, 2, 3):
        lines.append(dict(id=j, type="chain", a=j, b=4, L=L_IEA, nseg=200))
    return dict(
        title="V-S1m three IEA-15MW VolturnUS-S chains from three turbines to one shared anchor",
        notes=["Turbines at the vertices of an equilateral triangle of side 837.6*sqrt(3) m; the shared",
               "anchor sits at the centroid (837.6 m from every turbine), 200 m water; each line is the",
               "single-turbine VolturnUS line of examples/iea15mw_volturnus_mooring.dat."],
        md_notes=["MoorDyn-C twin: the fairleads are Coupled points in farm-global coordinates."],
        line_types=[CHAIN_IEA],
        points=pts,
        lines=lines,
    )


def case_shared_anchor(case_id: str) -> None:
    model = shared_anchor_model()
    tmax = 300.0
    turb = [f"{j}  {x:.6f}  {y:.6f}  0.0  0 0 0 0 0 0" for j, x, y in TURBINES]
    sections = [("TURBINES", ["J  X0  Y0  Z0  PtfmSurge  PtfmSway  PtfmHeave  PtfmRoll  PtfmPitch  PtfmYaw",
                              "(-)  (m)  (m)  (m)  (m)  (m)  (m)  (deg)  (deg)  (deg)", *turb])]
    outs = ["FairTen1", "FairTen2", "FairTen3", "AnchTen1", "AnchTen2", "AnchTen3",
            "Point4Fx", "Point4Fy", "Point4Fz", "Point4FH"]
    common = [("none", "current"), ("none", "waves"), ("none", "frictionMu")]
    static = cd_deck(model, dict(depth=200.0, kbot=3.0e6, sections=sections, rows=common), outs)
    turb10 = list(turb)
    turb10[0] = f"1  {TURBINES[0][1]:.6f}  {TURBINES[0][2]:.6f}  0.0  10 0 0 0 0 0"
    static10 = cd_deck(model, dict(depth=200.0, kbot=3.0e6, rows=common,
                                   sections=[(sections[0][0], sections[0][1][:2] + turb10)]), outs)
    dyn = cd_deck(model, dict(depth=200.0, kbot=3.0e6, sections=sections,
                              rows=[(0.1, "dtM"), (tmax, "TMax"), ("motion_turbines.txt", "motionFile"),
                                    *common]), outs)
    md_static = md_deck(model, dict(dtM=5e-4, depth=200.0, kbot=3.0e6, dtIC=2.0, TmaxIC=600.0,
                                     CdScaleIC=4.0, threshIC=1e-6), dialect="mdc")
    md_dyn = md_deck(model, dict(dtM=5e-4, depth=200.0, kbot=3.0e6, dtIC=2.0, TmaxIC=600.0,
                                  CdScaleIC=4.0, threshIC=1e-6), dialect="mdc")

    # Prescribed motion: T1 surge 5 m / 100 s, all turbines heave 2 m / 12 s.
    motion_md = ["# dof c0 c1 c2 amp period phase  (x = c0 + c1 t + c2 t^2 + amp sin(2 pi t/period + phase))"]
    for p in model["points"][:3]:
        j = p["id"]
        x, y, z = p["mdc_xyz"]
        base = 3 * (j - 1)
        motion_md.append(f"{base} {x} 0 0 {5.0 if j == 1 else 0.0} 100 0")
        motion_md.append(f"{base + 1} {y} 0 0 0 100 0")
        motion_md.append(f"{base + 2} {z} 0 0 2.0 12 0")
    held_md = ["# dof c0 c1 c2 amp period phase (hosts held)"]
    for p in model["points"][:3]:
        base = 3 * (p["id"] - 1)
        for k in range(3):
            held_md.append(f"{base + k} {p['mdc_xyz'][k]} 0 0 0 1 0")
    surge10 = list(held_md)
    surge10[1] = f"0 {model['points'][0]['mdc_xyz'][0] + 10.0} 0 0 0 1 0"
    # CableDyn per-turbine 6-DOF record: time J x y z q0 q1 q2 q3 vx vy vz
    # wx wy wz ax ay az alx aly alz, farm-global reference-point position and unit quaternion.
    rows = ["# time J x y z q0 q1 q2 q3 vx vy vz wx wy wz ax ay az alx aly alz"]
    dt_m = 0.1
    n = int(round(tmax / dt_m))
    for k in range(n + 1):
        t = k * dt_m
        for j, xt, yt in TURBINES:
            ws, wh = 2 * math.pi / 100.0, 2 * math.pi / 12.0
            sx = 5.0 * math.sin(ws * t) if j == 1 else 0.0
            vx = 5.0 * ws * math.cos(ws * t) if j == 1 else 0.0
            ax = -5.0 * ws * ws * math.sin(ws * t) if j == 1 else 0.0
            hz, vz, az_ = 2.0 * math.sin(wh * t), 2.0 * wh * math.cos(wh * t), -2.0 * wh * wh * math.sin(wh * t)
            rows.append(f"{t:.1f} {j} {xt + sx:.7f} {yt:.6f} {hz:.7f} 1 0 0 0 {vx:.7g} 0 {vz:.7g} 0 0 0 "
                        f"{ax:.7g} 0 {az_:.7g} 0 0 0")
    _write(case_id, {
        "cabledyn_static.dat": static, "cabledyn_static_surge10.dat": static10, "cabledyn.dat": dyn,
        "moordyn_static.txt": md_static, "moordyn.txt": md_dyn,
        "motion_mdc.txt": "\n".join(motion_md) + "\n", "held_mdc.txt": "\n".join(held_md) + "\n",
        "surge10_mdc.txt": "\n".join(surge10) + "\n",
        "motion_turbines.txt": "\n".join(rows) + "\n",
    })
    MANIFEST[case_id] = dict(
        family="V-S1 shared anchor", title=model["title"], tier="xcode",
        cabledyn_deck="cabledyn.dat", cabledyn_deck_static="cabledyn_static.dat", tmax=tmax,
        references=dict(
            moordyn_c=dict(deck="moordyn.txt", tmax=tmax, dtout=0.1, noic=False, scheme="rk4",
                            motion="motion_mdc.txt", cdt="dtM", dt_levels=[5e-4, 2.5e-4]),
            moordyn_c_static=dict(deck="moordyn_static.txt", motion="held_mdc.txt"),
            moordyn_c_static_surge10=dict(deck="moordyn_static.txt", motion="surge10_mdc.txt"),
        ),
        metrics=[
            _metric("static_symmetry", "e_rel_spread", "static:FairTen1,FairTen2,FairTen3", "self", None, 1e-6,
                    note="held hosts: the three line tensions equal"),
            _metric("static_FairTen1", "e_stat_value", "static:FairTen1", "moordyn_c_static", "TenA1", 0.005),
            _metric("static_surge10_FairTen1", "e_stat_value", "static_surge10:FairTen1",
                    "moordyn_c_static_surge10", "TenA1", 0.005,
                    note="needs the CableDyn static deck with T1 PtfmSurge = 10"),
            _metric("anchor_FH", "e_rms_star", "derived:anchor_FH", "moordyn_c", "derived:anchor_FH", 0.02,
                    window=[100.0, tmax]),
            *[_metric(f"FairTen{i}", "e_rms_star", f"FairTen{i}", "moordyn_c", f"TenA{i}", 0.02,
                      window=[100.0, tmax]) for i in (1, 2, 3)],
        ],
    )


# --------------------------------------------------------------------------------------
# V-M: mixed topology (BodiesAndRods style): a free body carrying a fixed rod and a pinned
# rod, taut moorings, a chain through two Free points, and a finite-EI cable
# --------------------------------------------------------------------------------------

NYLON = dict(name="nylon", d=0.124, m=13.76, EA=2.515288e6, BA=-0.8, Cd=1.6, Ca=1.0, CdAx=0.05, CaAx=0.0)
CHAIN_M = dict(name="chain", d=0.1, m=20.0, EA=5.0e8, BA=-0.8, Cd=1.2, Ca=1.0, CdAx=0.4, CaAx=0.0)
CABLE_M = dict(name="cable", d=0.15, m=30.0, EA=5.0e8, BA=-0.8, EI=1.0e4, Cd=1.2, Ca=1.0, CdAx=0.01, CaAx=0.0)


def mixed_model(x0: float, free_rod: bool = False, chain: bool = True) -> dict:
    """Free body (volume 160 m^3, 150 t) at (x0, 0, -15) with rod 1 fixed above it, rod 2 pinned
    below it (End A on the body, hanging) and held down by a vertical tether from its End B,
    three taut nylon legs, a chain from an anchor through Free points 8 (a small buoy) and 9 (a
    clump) to the body, and a finite-EI cable (EI 1e4 N m^2) to an anchor. The anchors stay put
    and the body starts displaced by x0 (the tether anchor sits below the displaced rod). With
    free_rod, the chain's middle span runs through a buoyant free rod instead of a line. The Free
    points start at their static equilibrium about the body held at x0 = 3 m (CableDyn's static
    solve; MoorDyn-C's settle relaxes the lines, not the points, to that tolerance)."""
    r = 3.0
    lines = [dict(id=i, type="nylon", a=i, b=i + 3, L=150.0, nseg=40) for i in (1, 2, 3)]
    points = [
        dict(id=1, att="Body1", xyz=[r, 0.0, 0.0]),
        dict(id=2, att="Body1", xyz=[-0.5 * r, 0.5 * math.sqrt(3.0) * r, 0.0]),
        dict(id=3, att="Body1", xyz=[-0.5 * r, -0.5 * math.sqrt(3.0) * r, 0.0]),
        dict(id=4, att="Fixed", xyz=[150.0, 0.0, -70.0]),
        dict(id=5, att="Fixed", xyz=[-75.0, 129.904, -70.0]),
        dict(id=6, att="Fixed", xyz=[-75.0, -129.904, -70.0]),
        dict(id=7, att="Fixed", xyz=[-100.0, 0.0, -70.0]),
        dict(id=8, att="Free", xyz=[-58.5035, 0.0, -44.4991], m=100.0, v=1.0),
        dict(id=9, att="Free", xyz=[-17.9514, 0.0, -46.3345], m=400.0),
        dict(id=10, att="Body1", xyz=[-2.0, 0.0, -2.0]),
        dict(id=11, att="Fixed", xyz=[x0, 0.0, -70.0]),
        dict(id=12, att="Body1", xyz=[0.0, 3.0, -2.0]),
        dict(id=13, att="Fixed", xyz=[0.0, 60.0, -70.0]),
    ]
    lines += [dict(id=4, type="chain", a=8, b=7, L=50.0, nseg=12),
              dict(id=5, type="chain", a=9, b=8, L=42.0, nseg=10),
              dict(id=6, type="chain", a=10, b=9, L=35.0, nseg=8),
              dict(id=7, type="nylon", a="R2B", b=11, L=42.0, nseg=12),
              dict(id=8, type="cable", a=12, b=13, L=90.0, nseg=30)]
    rod_types = [dict(name="can", d=2.0, m=1500.0, Cd=0.8, Ca=1.0, CdEnd=0.0, CaEnd=0.0),
                 dict(name="arm", d=0.5, m=600.0, Cd=1.0, Ca=1.0, CdEnd=0.0, CaEnd=0.0)]
    rods = [dict(id=1, type="can", att="Body1", a=[0.0, 0.0, 2.0], b=[0.0, 0.0, 8.0], nseg=4, out="-"),
            dict(id=2, type="arm", att="Body1Pinned", a=[0.0, 0.0, -2.0], b=[0.0, 0.0, -12.0], nseg=5, out="-")]
    if free_rod:
        # the middle chain span becomes chain - free buoyant rod - chain
        rod_types.append(dict(name="float", d=1.0, m=300.0, Cd=1.0, Ca=1.0, CdEnd=0.0, CaEnd=0.0))
        a, b = [-50.0, 0.0, -47.0], [-46.0, 0.0, -46.0]
        rods.append(dict(id=3, type="float", att="Free", a=a, b=b, nseg=4, out="-"))
        lines[4] = dict(id=5, type="chain", a="R3A", b=8, L=13.0, nseg=4)
        lines.append(dict(id=9, type="chain", a=9, b="R3B", L=25.0, nseg=6))
    if not chain:
        # no chain: points 8 and 9 stay (MoorDyn-C needs sequential ids) as unused Fixed points,
        # and the lines are renumbered
        lines = [ln for ln in lines if ln["id"] not in (4, 5, 6)]
        for k, ln in enumerate(lines, start=1):
            ln["id"] = k
        for p in points:
            if p["id"] in (8, 9):
                p["att"] = "Fixed"
                p.pop("m", None)
                p.pop("v", None)
    return dict(
        title=f"V-M mixed topology: free body with fixed and pinned rods, "
              f"{'chain through Free points, ' if chain else ''}finite-EI cable; release from x = {x0} m",
        notes=["BodiesAndRods-style: Rigid6 body, Body1 rod, Body1Pinned rod with a line on its End B,",
               "EI=0 taut legs and a chain through Free points, a finite-EI cable; 70 m water, still water."],
        line_types=[NYLON, CHAIN_M, CABLE_M],
        rod_types=rod_types,
        bodies=[dict(id=1, att="Free", xyz=[x0, 0.0, -15.0], rpy=[0, 0, 0], mass=1.5e5, cg="0", I="2e6",
                     vol=160.0, cda="20|0", ca="0.5")],
        rods=rods,
        points=points,
        lines=lines,
    )


# 1 mm pin tether: k = EA/L = 1e12 N/m, damping BA/L = 7.5e7 N s/m (about half critical with a 6 t rod)
PIN_TETHER = dict(name="pin", d=0.01, m=1.0, EA=1.0e9, BA=7.5e4, Cd=0.0, Ca=0.0, CdAx=0.0, CaAx=0.0)


def pinned_rod_twin(model: dict, gap: float = 1.0e-3) -> dict:
    """MoorDyn-C twin of rods pinned to a body. MoorDyn-C adds every rod attached to a body,
    pinned or not, to the body's equations with its full force, moment and 6x6 mass
    (Body::doRHS / Rod::getNetForceAndMass), so a pinned rod passes its moment about the pin and
    its rotational inertia to the body, and the rod's own rotation equation drops the pin
    acceleration (Rod::getStateDeriv). The twin carries each pinned rod on a massless Free body
    at its centre and hangs it from the parent body by a 1 mm, EA 1e9 N tether, which transmits
    the pin force and no moment (the rod pulls the tether taut)."""
    twin = json.loads(json.dumps(model))
    twin["line_types"] = twin["line_types"] + [PIN_TETHER]
    next_body = max(b["id"] for b in twin["bodies"]) + 1
    next_point = max(p["id"] for p in twin["points"]) + 1
    next_line = max(ln["id"] for ln in twin["lines"]) + 1
    for rod in twin["rods"]:
        att = rod["att"]
        if not (att.lower().startswith("body") and att.lower().endswith("pinned")):
            continue
        parent = next(b for b in twin["bodies"] if b["id"] == int(att[4:-6]))
        a_loc, b_loc = rod["a"], rod["b"]
        c_glob = [p + 0.5 * (a + b) for p, a, b in zip(parent["xyz"], a_loc, b_loc)]
        twin["bodies"].append(dict(id=next_body, att="Free", xyz=c_glob, rpy=[0, 0, 0], mass=0.0, cg="0",
                                   I="0", vol=0.0, cda="0", ca="0"))
        c_loc = [0.5 * (a + b) for a, b in zip(a_loc, b_loc)]
        rod["att"] = f"Body{next_body}"
        rod["a"] = [a - c for a, c in zip(a_loc, c_loc)]
        rod["b"] = [b - c for b, c in zip(b_loc, c_loc)]
        twin["points"] += [dict(id=next_point, att=f"Body{parent['id']}", xyz=[a_loc[0], a_loc[1], a_loc[2] + gap]),
                           dict(id=next_point + 1, att=f"Body{next_body}", xyz=rod["a"])]
        twin["lines"].append(dict(id=next_line, type="pin", a=next_point, b=next_point + 1, L=gap, nseg=1))
        next_body += 1
        next_point += 2
        next_line += 1
    twin["md_notes"] = twin.get("md_notes", []) + [
        "MoorDyn-C twin: each Body<N>Pinned rod rides on a massless Free body hung from its parent by a",
        "1 mm stiff tether (MoorDyn-C passes a pinned rod's moment and inertia to the body; see README)."]
    return twin


def case_mixed(case_id: str, x0: float, chain: bool) -> None:
    model = mixed_model(x0, chain=chain)
    tmax = 60.0
    # line ids: legs 1-3, then (with the chain) chain 4-6, tether, cable
    tether, cable = (7, 8) if chain else (4, 5)
    outs = ["Body1Px", "Body1Py", "Body1Pz", "Body1Rx", "Body1Ry", "Body1Rz", "Rod2Px", "Rod2Pz",
            "Rod2N5Px", "Rod2N5Pz", "FairTen1", "FairTen2", "FairTen3", f"FairTen{tether}",
            f"FairTen{cable}", "Body1Fx", "Body1Fz", "Body1My", "Rod2TenB", "Rod2Sub", "Point13FH"]
    if chain:
        outs += ["Point8Px", "Point8Pz", "Point9Px", "Point9Pz", "FairTen6"]
    cd = cd_deck(model, dict(depth=70.0, rows=[("deck", "bodyIC"), *PARITY_BODY, *PARITY_ROD, (0.005, "dtM"),
                                               (tmax, "TMax"), ("none", "current"), ("none", "waves")]),
                 outs)
    # the full mix with a free rod in the chain: every object at its static equilibrium, no
    # release (static-equilibrium sanity: the march starts at rest and stays there)
    files = {"cabledyn.dat": cd, "moordyn.txt": md_deck(pinned_rod_twin(model), dict(dtM=1e-4, depth=70.0)),
             "moordyn_bodypinned.txt": md_deck(model, dict(dtM=1e-4, depth=70.0))}
    g = 0.05
    metrics = [
        _metric("surge_rms", "e_rms", "Body1Px", "moordyn_c", "Body1Px", g),
        _metric("heave_rms", "e_rms", "Body1Pz", "moordyn_c", "Body1Pz", g),
        _metric("pitch_rms", "e_rms", "Body1Ry", "moordyn_c", "Body1Ry", g),
        _metric("pinned_rod_rms", "e_rms", "Rod2N5Px", "moordyn_c", "Rod2N5Px", g),
        *[_metric(f"FairTen{i}_rms", "e_rms", f"FairTen{i}", "moordyn_c", f"TenA{i}", g)
          for i in (1, 2, 3, tether)],
        _metric("cable_t0", "e_t0", f"FairTen{cable}", "moordyn_c", f"TenA{cable}", 0.005,
                note="finite-EI cable (EI 1e4 N m^2, cubic Hermite) vs MoorDyn-C's lumped bending line: "
                     "static hang-off tension; its dynamic swing is under 1 % of the mean, where the two "
                     "bending models differ by about 0.2 % of the mean"),
        _metric("decay", "decay_ratio", "Body1Px", "self", None, 0.5, window=[0.0, tmax],
                note="energy decay: late surge amplitude over the early one (last vs first fifth)"),
    ]
    if chain:
        metrics.insert(4, _metric("free_point_rms", "e_rms", "Point9Px", "moordyn_c", "Point9Px", g))
        # the full mix with a free rod in the chain: every object at its static equilibrium, no
        # release (static-equilibrium sanity: the march starts at rest and stays there)
        rest_model = mixed_model(0.0, free_rod=True)
        files["cabledyn_rest.dat"] = cd_deck(rest_model, dict(depth=70.0, rows=[
            ("static", "bodyIC"), *PARITY_BODY, *PARITY_ROD, (0.005, "dtM"), (20.0, "TMax"),
            ("none", "current"), ("none", "waves")]), outs + ["Rod3Px", "Rod3Pz"])
        metrics += [
            _metric("rest_drift_body", "e_drift_abs", "Body1Px,Body1Py,Body1Pz", "self", None, 5e-3,
                    cd_run="_rest",
                    note="static equilibrium: the full mix stays at rest [m]; the finite-EI cable enters the "
                         "object statics without its bending stiffness"),
            _metric("rest_drift_rods", "e_drift_abs", "Rod2N5Px,Rod2N5Pz,Rod3Px,Rod3Pz", "self", None, 1e-3,
                    cd_run="_rest", note="pinned and free rods stay at rest [m]"),
        ]
    _write(case_id, files)
    MANIFEST[case_id] = dict(
        family="V-M mixed topology", title=model["title"], tier="xcode",
        cabledyn_deck="cabledyn.dat", tmax=tmax,
        references=dict(moordyn_c=dict(deck="moordyn.txt", tmax=tmax, dtout=0.05, noic=True, settle=300.0,
                                        scheme="rk4", dt_levels=[1e-4, 5e-5])),
        metrics=metrics,
    )
    if chain:
        MANIFEST[case_id]["cabledyn_deck_rest"] = "cabledyn_rest.dat"


# --------------------------------------------------------------------------------------

def build() -> None:
    case_buoy("V-D1a", 0.5)
    # V-D1b: the released slack leg snaps taut; at 80 segments MoorDyn-C's FairTen1 moves 1.4 %
    # (80 -> 160) and 0.8 % (160 -> 320) and an OrcaFlex twin (orcaflex_vd1b_reference.py) puts
    # both codes within 0.5-0.8 % of it only at 320, where they agree within 0.25 %.
    case_buoy("V-D1b", 5.0, nseg=320, dtm=0.001, md_dt=(2.5e-5, 1.25e-5), extra_metrics=VD1B_ORCAFLEX)
    # V-D2a: the side legs nearly go slack and snap taut in the first seconds; at 64/80 segments
    # the codes' line mass discretisations (CableDyn consistent, MoorDyn-C lumped) differ by up to
    # 3 % there, and each code is up to 2.5 % from its own 4x-refined solution. At 256/320 they
    # agree within 1 %.
    case_spar("V-D2a", 0.1, 0.0, False, lmult=16, dtm=0.001, md_dt=(2.5e-5,))
    case_spar("V-D2b", 0.0, 0.1, False)
    # V-D2c: the downstream legs go slack and snap taut; the snap is not segment-converged at
    # 64/80 (MoorDyn-C itself moves 11 % in FairTen1 between 64/80 and 128/160), at 128/160 the
    # codes agree within 2-4 % from dtM 0.0005 to 0.002 s.
    case_spar("V-D2c", 2.0, 0.0, True, lmult=8, md_dt=(1.25e-5, 6.25e-6))
    case_spar("V-D2d", 0.0, 1.0, True)
    case_spar("V-R3", 0.0, 0.1, False, cdend=0.6, caend=0.6)
    case_surface_spar(
        "V-SP-heave", SPAR, 1.0, 0.0, 200.0, 0.1,
        [_metric("draft", "e_eq", "static:Body1Pz", "analytic", "z_eq", 1e-4,
                 note="static equilibrium (cabledyn_static.dat) vs rho A draft = m"),
         _metric("heave_period", "e_T", "Body1Pz", "analytic", "T_heave", 0.01)],
        "V-SP/V-D3 ballasted surface-piercing spar, heave release from +1 m")
    case_surface_spar(
        "V-SP-pitch", SPAR, 0.0, 3.0, 400.0, 0.1,
        [_metric("pitch_period", "e_T", "Body1Ry", "analytic", "T_pitch_exact", 0.02),
         _metric("pitch_rms_md", "e_rms", "Body1Ry", "moordyn_c", "Body1Ry", 0.03,
                 note="scored on the cabledyn_mdparity.dat run (rodHydro moordyn)", cd_run="_mdparity")],
        "V-SP/V-D3 ballasted surface-piercing spar, pitch release from 3 deg")
    case_surface_spar(
        "V-SPW", SQUAT, 0.0, 2.0, 300.0, 0.1,
        [_metric("pitch_period_exact", "e_T", "Body1Ry", "analytic", "T_pitch_exact", 0.01),
         _metric("pitch_period_md", "e_T", "Body1Ry", "moordyn_c", "Body1Ry", 0.01,
                 note="scored on the cabledyn_mdparity.dat run (rodHydro moordyn)", cd_run="_mdparity")],
        "V-SPW waterplane-term check: squat spar (d 10 m, draft 20 m, GM 0.41 m), pitch release 2 deg",
        md_dt=(0.01, 0.005, 0.0025))
    for cid, th in (("V-P1a", 10.0), ("V-P1b", 60.0), ("V-P1c", 120.0)):
        case_pendulum(cid, th)
    case_shared_anchor("V-S1m")
    case_mixed("V-M1", 3.0, chain=False)
    case_mixed("V-M2", 3.0, chain=True)
    (BODIES / "cases.json").write_text(json.dumps(MANIFEST, indent=1) + "\n", newline="\n")
    print(f"wrote {len(MANIFEST)} cases to {CASES}")


if __name__ == "__main__":
    build()
