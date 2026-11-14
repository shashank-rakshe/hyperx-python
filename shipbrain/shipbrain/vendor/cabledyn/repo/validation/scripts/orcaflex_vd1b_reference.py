# File: validation/scripts/orcaflex_vd1b_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex twin of bodies case V-D1b (third-code arbiter for the slack-snap leg tension).

V-D1b: a 20 t, 40 m^3 buoy (CG z = -20 m, 100 m water) on three 86.85 m polyester legs,
held 5 m off in surge while the lines settle, then released at t = 0 (still water).
The case deck is validation/bodies/cases/V-D1b/cabledyn.dat (moordyn.txt is the same model).

Mapping (all loads per unit length/area identical to the MoorDyn/CableDyn deck):

* Buoy: OrcaFlex 6D *spar* buoy, one cylinder whose axis is global +y (attitude -90 deg
  about x). MoorDyn-C's body drag is 0.5 rho CdA |v| v with the vector norm (Body.cpp,
  isotropic CdA 8 m^2); a lumped 6D buoy applies drag per axis (v_i |v_i|), a spar-buoy
  cylinder applies 0.5 rho Cd A |v_n| v_n in its normal plane, which is the x-z plane of
  this symmetric problem (v_y = 0). Cylinder D x L chosen so that D L = 8 m^2 (Cd_n 1) and
  pi D^2 L / 4 = 40 m^3, centred on the CG (buoyancy at the CG as in MoorDyn). Added mass
  Ca 0.5 on the three translations, none on the rotations; no rotational drag; mass 20 t,
  isotropic inertia 35 t m^2. Held in statics (DegreesOfFreedomInStatics None) = release R.
* Lines: OD 0.12 m, 15 kg/m, EA 5e7 N, EI = GJ = 0, Cdn 1.2, Cdz 0.2 (OrcaFlex area pi d,
  as MoorDyn-C Cdt; see VALIDATION.md L3-6a), Can 1, Caz 0; compression limited (EI = 0 ->
  tension-only, as both codes). Axial damping BA/-zeta = -1 -> the MoorDyn segment
  coefficient BA = l_seg sqrt(EA m) [N s], i.e. a separated Rayleigh axial-stiffness
  coefficient beta = l_seg sqrt(m / EA) [s] (force beta EA d(eps)/dt).
* Seabed: flat elastic, normal stiffness kBot 1e5 Pa/m (OrcaFlex kN/m/m^2 on the contact
  area OD x l), frictionless. OrcaFlex puts contact at the line's outer surface, MoorDyn at
  the centreline, so the seabed sits OD/2 below 100 m and the anchors are Fixed at z = -100
  (an Anchored end at seabed + OD/2 shortens legs 2/3 and drops their held tension 4 %).
  The flat elastic seabed's damping is not settable in 11.6 (reads 0); the deck's cBot
  moves CableDyn's FairTen1 by 0.25 % e_rms (120 s) and is left out here.
* Output: FairTen = magnitude of the End A "End force" (force the line exerts on its
  connection; the end node's inertia is included -- 0.2 % of the snap peaks at 80
  segments, vanishing with refinement).

* Committed reference: the summary values the bodies suite scores (statistics over
  t in [0.5, 120] s on the 0.01 s grid, the dominant fairlead-tension harmonic, the first two
  FairTen1 snap maxima; bodies_summary.reference_summary) go into
  validation/bodies/references/V-D1b/orcaflex.json. The full series is licensed OrcaFlex
  output and is not redistributed; ``ref`` also saves it as a local .npz in --out.

Usage (OrcFxAPI 11.6d):
  python orcaflex_vd1b_reference.py sweep [--tmax 30]      # segment / dt convergence
  python orcaflex_vd1b_reference.py ref --nseg 320 --dt 0.00025 --out <dir>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bodies_common import REFS  # noqa: E402
from bodies_summary import reference_summary  # noqa: E402

try:
    import OrcFxAPI as ofx
except Exception as exc:  # noqa: BLE001 - any import/license failure -> skip
    print(f"# OrcaFlex unavailable ({exc}); skipping")
    sys.exit(2)

RHO, G = 1025.0, 9.80665
DEPTH = 100.0
X0 = 5.0
BODY_Z = -20.0
MASS, INERTIA, VOL, CDA, CA = 2.0e4, 3.5e4, 40.0, 8.0, 0.5
D, MLIN, EA = 0.12, 15.0, 5.0e7
CDN, CDT, CAN, CAT = 1.2, 0.2, 1.0, 0.0
LEN = 86.85
KBOT = 1.0e5
FAIR = [(1.5, 0.0, -2.0), (-0.75, 1.299, -2.0), (-0.75, -1.299, -2.0)]
ANCH = [(40.0, 0.0, -100.0), (-20.0, 34.641, -100.0), (-20.0, -34.641, -100.0)]
BUILDUP = 1.0e-3
# the scored summary: window (the release transient of the slack leg is excluded), grid, the
# channels with a dominant harmonic, and the FairTen1 snap spans
SUMMARY_WINDOW, SUMMARY_DT = (0.5, 120.0), 0.01
SUMMARY_CHANNELS = ["Body1Px", "Body1Pz", "FairTen1", "FairTen2", "FairTen3"]
HARMONIC_CHANNELS = ("FairTen1", "FairTen2", "FairTen3")
SNAP_SPANS = {"FairTen1": [(1.8, 2.1), (2.4, 2.8)]}


def body_to_local(p):
    """Body-frame (MoorDyn) offset -> OrcaFlex buoy local axes (attitude -90 deg about x)."""
    x, y, z = p
    return (x, -z, y)


def build(nseg, dt, tmax, *, buoy="spar", axial_damp=True, log_dt=0.01):
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = DEPTH + 0.5 * D  # OrcaFlex seabed contact at OD/2; MoorDyn at the centreline
    env.Density = RHO / 1000.0
    env.WaveHeight = 0.0
    env.SeabedModel = "Elastic"
    env.SeabedNormalStiffness = KBOT / 1000.0
    m.general.StageDuration = [BUILDUP, tmax]
    m.general.DynamicsSolutionMethod = "Implicit time domain"
    m.general.ImplicitConstantTimeStep = dt
    m.general.TargetLogSampleInterval = log_dt

    rd = m.CreateObject(ofx.ObjectType.RayleighDampingCoefficients, "ba")
    rd.Mode = "Coefficients (separated)"
    rd.AxialStiffnessCoefficient = (LEN / nseg) * math.sqrt(MLIN / EA) if axial_damp else 0.0

    lt = m.CreateObject(ofx.ObjectType.LineType, "poly")
    lt.OD, lt.ID = D, 0.0
    lt.MassPerUnitLength = MLIN / 1000.0
    lt.EA = EA / 1000.0
    lt.EIx = lt.EIy = lt.GJ = 0.0
    lt.CompressionIsLimited = "Yes"
    lt.Cdn, lt.Cdz, lt.Can, lt.Caz = CDN, CDT, CAN, CAT
    lt.SeabedLateralFrictionCoefficient = 0.0
    lt.SeabedAxialFrictionCoefficient = 0.0
    lt.RayleighDampingCoefficients = "ba"

    b = m.CreateObject(ofx.ObjectType.Buoy6D, "buoy")
    b.BuoyType = "Spar buoy" if buoy == "spar" else "Lumped buoy"
    b.DegreesOfFreedomInStatics = "None"
    b.InitialX, b.InitialY, b.InitialZ = X0, 0.0, BODY_Z
    b.InitialRotation1, b.InitialRotation2, b.InitialRotation3 = -90.0, 0.0, 0.0
    b.Mass = MASS / 1000.0
    b.MomentOfInertiaX = b.MomentOfInertiaY = b.MomentOfInertiaZ = INERTIA / 1000.0
    if buoy == "spar":
        dia = 4.0 * VOL / (math.pi * CDA)
        cl = CDA / dia
        b.StackBaseCentreZ = -0.5 * cl
        b.CylinderOuterDiameter = (dia,)
        b.CylinderInnerDiameter = (0.0,)
        b.CylinderLength = (cl,)
        b.CylinderNormalDragArea = (CDA,)
        b.CylinderNormalDragForceCoefficient = (1.0,)
        b.CylinderAxialDragArea = (0.0,)          # axial = global y; v_y = 0
        b.CylinderNormalAddedMassForceCoefficient = (CA,)
        b.CylinderAxialAddedMassForceCoefficient = (CA,)
    else:  # lumped buoy: per-axis drag (v_i |v_i|) -- the convention probe
        b.Volume = VOL
        for ax in "XYZ":
            b.SetData(f"DragArea{ax}", -1, CDA)
            b.SetData(f"DragForceCoefficient{ax}", -1, 1.0)
            b.SetData(f"AddedMassCoefficient{ax}", -1, CA)

    lines = []
    for i in range(3):
        ln = m.CreateObject(ofx.ObjectType.Line, f"leg{i + 1}")
        ln.LineType = ("poly",)
        ln.Length = (LEN,)
        ln.TargetSegmentLength = (LEN / nseg,)
        ln.EndAConnection = "buoy"
        ln.EndAX, ln.EndAY, ln.EndAZ = body_to_local(FAIR[i])
        ln.EndBConnection = "Fixed"
        ln.EndBX, ln.EndBY, ln.EndBZ = ANCH[i]
        lines.append(ln)
    return m, b, lines


def run(nseg, dt, tmax, **kw):
    m, b, lines = build(nseg, dt, tmax, **kw)
    t0 = time.time()
    m.CalculateStatics()
    fair0 = [(ln.StaticResult("X", ofx.oeEndA), ln.StaticResult("Effective tension", ofx.oeEndA),
              ln.StaticResult("Wall tension", ofx.oeEndA), ln.StaticResult("End force", ofx.oeEndA)) for ln in lines]
    m.RunSimulation()
    per = ofx.SpecifiedPeriod(-BUILDUP, tmax)  # first sample = the static state (t = 0)
    t = np.asarray(m.general.TimeHistory("Time", per)) + BUILDUP  # release at t = 0
    out = {"Time": t}
    for i, ln in enumerate(lines):
        out[f"FairTen{i + 1}"] = 1e3 * np.asarray(ln.TimeHistory("End force", per, ofx.oeEndA))
        out[f"EffTenA{i + 1}"] = 1e3 * np.asarray(ln.TimeHistory("Effective tension", per, ofx.oeEndA))
        out[f"AnchTen{i + 1}"] = 1e3 * np.asarray(ln.TimeHistory("End force", per, ofx.oeEndB))
    out["Body1Px"] = np.asarray(b.TimeHistory("X", per))
    out["Body1Pz"] = np.asarray(b.TimeHistory("Z", per))
    out["Body1Ry"] = np.asarray(b.TimeHistory("Rotation 3", per))
    return out, dict(wall_s=time.time() - t0, static_fair_x=fair0)


def e_rms(t, y, tr, yr):
    """bodies_metrics.e_rms: RMS difference over the largest reference excursion from its end value."""
    yi = np.interp(tr, t, y)
    return float(np.sqrt(np.mean((yi - yr) ** 2)) / np.max(np.abs(yr - yr[-1])))


def sweep(args):
    tmax = args.tmax
    runs = {}
    for nseg, dt in ((80, 1e-3), (160, 1e-3), (320, 1e-3), (320, 5e-4), (320, 2.5e-4), (640, 5e-4)):
        out, info = run(nseg, dt, tmax)
        runs[(nseg, dt)] = out
        print(f"nseg {nseg:4d} dt {dt:g}: wall {info['wall_s']:.0f} s, FairTen1 t0 {out['FairTen1'][0]:.1f} N, "
              f"max {out['FairTen1'].max():.1f} N", flush=True)
        np.savez_compressed(Path(args.out) / f"of_s{nseg}_dt{dt:g}_t{tmax:g}.npz", **out)
    ref = runs[(640, 5e-4)] if (640, 5e-4) in runs else runs[(320, 2.5e-4)]
    for k, out in runs.items():
        print(k, {c: f"{100 * e_rms(out['Time'], out[c], ref['Time'], ref[c]):.3f}%"
                  for c in ("FairTen1", "FairTen2", "Body1Px")})


def write_ref(args):
    out, info = run(args.nseg, args.dt, args.tmax)
    local = Path(args.out)
    local.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(local / f"of_s{args.nseg}_dt{args.dt:g}_t{args.tmax:g}.npz", **out)
    summary = reference_summary(out["Time"], {c: out[c] for c in SUMMARY_CHANNELS}, SUMMARY_WINDOW,
                                SUMMARY_DT, HARMONIC_CHANNELS, SNAP_SPANS)
    d = REFS / "V-D1b"
    old = json.loads((d / "orcaflex.json").read_text()) if (d / "orcaflex.json").exists() else {}
    src = Path(__file__).read_bytes()
    prov = {
        "case": "V-D1b", "code": "orcaflex",
        "date": time.strftime("%Y-%m-%d"),
        "version": {"orcaflex": ofx.DLLVersion(), "script": "validation/scripts/orcaflex_vd1b_reference.py",
                    "script_sha256": hashlib.sha256(src).hexdigest()},
        "settings": {"solver": "implicit, constant step", "dt": args.dt, "segments_per_leg": args.nseg,
                     "log_interval": 0.01, "dtout": 0.01, "tmax": args.tmax,
                     "release": "buoy held in statics (DegreesOfFreedomInStatics None), free from t = 0",
                     "buoy": "spar buoy, 1 cylinder along global y: 0.5 rho CdA |v| v in x-z",
                     "seabed": "flat elastic, kBot 1e5 Pa/m, centreline contact, undamped (deck cBot 1e4)",
                     "FairTen": "End A End force magnitude"},
        "wall_s": info["wall_s"],
        "summary": summary,
    }
    # keep the recorded refinement study and arbitration (sweep mode) with the new summary
    for key in ("static_check", "convergence", "arbitration"):
        if key in old:
            prov[key] = old[key]
    (d / "orcaflex.json").write_text(json.dumps(prov, indent=2) + "\n", newline="\n")
    print(json.dumps(prov, indent=2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["sweep", "ref", "one"])
    ap.add_argument("--nseg", type=int, default=320)
    ap.add_argument("--dt", type=float, default=5e-4)
    ap.add_argument("--tmax", type=float, default=120.0)
    ap.add_argument("--buoy", default="spar")
    ap.add_argument("--out", default=".")
    args = ap.parse_args()
    if args.mode == "sweep":
        sweep(args)
    elif args.mode == "ref":
        write_ref(args)
    else:
        out, info = run(args.nseg, args.dt, args.tmax, buoy=args.buoy)
        print(info)
        np.savez_compressed(Path(args.out) / f"of_{args.buoy}_s{args.nseg}_dt{args.dt:g}_t{args.tmax:g}.npz", **out)
        for tt in (0, 1, 2, 3, 4, 5, 10):
            i = int(np.argmin(abs(out["Time"] - tt)))
            print(tt, {k: round(float(v[i]), 3) for k, v in out.items()})
    return 0


if __name__ == "__main__":
    sys.exit(main())
