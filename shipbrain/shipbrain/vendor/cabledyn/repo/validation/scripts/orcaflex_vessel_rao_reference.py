# File: validation/scripts/orcaflex_vessel_rao_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex cross-check of RAO-driven vessel motion (OPTIONS ``vesselRAO``).

One vessel, one regular Airy wave (H = 2 m, T = 10 s, travelling along +X, depth 60 m)
and one displacement-RAO table (periods 8/10/12 s; heave 0.5/0.8/0.9 m/m lagging
10/30/50 deg, pitch 1.0/1.5/1.2 deg/m lagging 80/100/120 deg; headings 0 and 90). The
vessel origin, RAO origin and wave-phase origin are at (75, 0, 0). OrcaFlex (default
conventions: rotations in deg/m, phases as lags relative to the wave crest at the RAO
origin, rotation order Rz Ry Rx) and the CableDyn driver move the vessel point
(15, 0, -14) in vessel axes, the fairlead (90, 0, -14) of a lazy-wave cable; their X and Z
histories after OrcaFlex's build-up stage are compared sample by sample at the time steps
0.05, 0.01 and 0.005 s (the same step in both codes).

OrcaFlex's imposed vessel motion leads the RAO response by about 0.29 omega dt of phase (a
first-order artefact of its implicit step: 0.51 deg at 0.05 s, 0.10 deg at 0.01 s); CableDyn
evaluates the RAO response exactly at every sample, so the difference falls in proportion to
the step and is below 1 mm at 0.005 s.

Run from an environment with OrcFxAPI (11.6d used)::

    python validation/scripts/orcaflex_vessel_rao_reference.py <path-to-cabledyn.exe>

Exits 0 when the difference converges at first order to below 1 mm, 1 otherwise, and 2
(skip) when OrcFxAPI or a license is unavailable.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import OrcFxAPI as ofx
except Exception as exc:  # noqa: BLE001 - any import/license failure -> skip
    print(f"# OrcaFlex unavailable ({exc}); skipping (this reference needs a license)")
    sys.exit(2)

PERIODS = (8.0, 10.0, 12.0)
HEAVE = ((0.5, 10.0), (0.8, 30.0), (0.9, 50.0))
PITCH = ((1.0, 80.0), (1.5, 100.0), (1.2, 120.0))
VESSEL_ORIGIN = (75.0, 0.0, 0.0)
POINT_LOCAL = (15.0, 0.0, -14.0)
DT, DURATION, BUILD_UP = 0.05, 20.0, 10.0


def rao_rows() -> list[list[float]]:
    """Rows period, surge A/P, sway A/P, heave A/P, roll A/P, pitch A/P, yaw A/P."""
    return [
        [
            period,
            0.0,
            0.0,
            0.0,
            0.0,
            heave[0],
            heave[1],
            0.0,
            0.0,
            pitch[0],
            pitch[1],
            0.0,
            0.0,
        ]
        for period, heave, pitch in zip(PERIODS, HEAVE, PITCH, strict=True)
    ]


def orcaflex_history(work: Path) -> tuple[list[float], list[float], list[float]]:
    """Build the OrcaFlex model through its YAML text and return t, X, Z of the point."""
    model = ofx.Model()
    model.CreateObject(ofx.ObjectType.VesselType, "vt")
    vessel = model.CreateObject(ofx.ObjectType.Vessel, "ship")
    vessel.VesselType = "vt"
    template = work / "template.yml"
    model.SaveData(str(template))
    text = template.read_text(encoding="utf-8-sig")
    header = (
        "RAOPeriodOrFrequency, RAOSurgeAmp, RAOSurgePhase, RAOSwayAmp, RAOSwayPhase, "
        "RAOHeaveAmp, RAOHeavePhase, RAORollAmp, RAORollPhase, RAOPitchAmp, RAOPitchPhase, "
        "RAOYawAmp, RAOYawPhase:"
    )
    table = "\n".join(
        f"                - [{', '.join(repr(v) for v in row)}]" for row in rao_rows()
    )
    raos = "".join(
        f"            - RAODirection: {direction}\n              {header}\n{table}\n"
        for direction in (0, 90)
    )
    block = re.compile(
        r"(        DisplacementRAOs:\n)          RAOOrigin: \[[^\]]*\]\n(          PhaseOrigin: [^\n]*\n)"
        r"          RAOs:\n(?:            .*\n|              .*\n|                .*\n)*?(?=        LoadRAOs:)"
    )
    text, count = block.subn(
        lambda m: (
            m.group(1)
            + "          RAOOrigin: [0, 0, 0]\n          PhaseOrigin: [0, 0, 0]\n          RAOs:\n"
            + raos
        ),
        text,
    )
    if count != 1:
        raise RuntimeError(
            "could not locate the displacement-RAO block of the OrcaFlex template"
        )
    replacements = {
        r"      WaveType: .*": "      WaveType: Airy",
        r"      WaveDirection: .*": "      WaveDirection: 0",
        r"      WaveHeight: .*": "      WaveHeight: 2",
        r"      WavePeriod: .*": "      WavePeriod: 10",
        r"  SeabedOriginDepth: .*": "  SeabedOriginDepth: 60",
        r"  ImplicitConstantTimeStep: .*": f"  ImplicitConstantTimeStep: {DT}",
        r"  TargetLogSampleInterval: .*": f"  TargetLogSampleInterval: {DT}",
        r"    InitialPosition: .*": f"    InitialPosition: [{', '.join(map(str, VESSEL_ORIGIN))}]",
    }
    for pattern, value in replacements.items():
        text, count = re.subn(pattern, value, text, count=1)
        if count != 1:
            raise RuntimeError(f"template field not found: {pattern}")
    # a stream-function order and current belong to the default Dean-stream wave only
    text = re.sub(r"      WaveStreamFunctionOrder: .*\n", "", text, count=1)
    text = re.sub(
        r"      WaveCurrentSpeedInWaveDirectionAtMeanWaterLevel: .*\n",
        "",
        text,
        count=1,
    )
    text = re.sub(
        r"  StageDuration:\n    - [^\n]*\n    - [^\n]*\n",
        f"  StageDuration:\n    - {BUILD_UP}\n    - {DURATION}\n",
        text,
        count=1,
    )
    model_file = work / "vessel_rao.yml"
    model_file.write_text(text, encoding="utf-8")
    model = ofx.Model(str(model_file))
    model.RunSimulation()
    ship = model["ship"]
    period = ofx.SpecifiedPeriod(0.0, DURATION)
    times = list(model.SampleTimes(period))
    x = list(ship.TimeHistory("X", period, ofx.oeVessel(POINT_LOCAL)))
    z = list(ship.TimeHistory("Z", period, ofx.oeVessel(POINT_LOCAL)))
    return times, x, z


def cabledyn_history(exe: Path, work: Path) -> dict[float, tuple[float, float]]:
    """Run the matching CableDyn deck and return {t: (X, Z)} of the fairlead point."""
    rao = ["HEADING 0"] + [" ".join(repr(v) for v in row) for row in rao_rows()]
    rao += ["HEADING 90"] + [" ".join(repr(v) for v in row) for row in rao_rows()]
    (work / "rao.txt").write_text("\n".join(rao) + "\n", encoding="utf-8")
    deck = f"""vessel RAO cross-check: lazy-wave cable on an RAO-driven vessel
--- LINE TYPES ---
Name Diam Mass EA BA EI Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)
bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0
buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0
--- POINTS ---
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Fixed 0.0 0.0 -56.0
2 Coupled 90.0 0.0 -14.0
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 2 1 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 bare 40.0 13
1 buoy 50.0 16
1 bare 55.0 18
--- OPTIONS ---
9.80665 g
1025.0 rhoW
60.0 WtrDpth
{DT} dtM
{DURATION} TMax
airy 2.0 10.0 0.0 waves
rao.txt vesselRAO
{VESSEL_ORIGIN[0]}|{VESSEL_ORIGIN[1]}|{VESSEL_ORIGIN[2]} vesselRef
--- OUTPUTS ---
Point2px
Point2pz
END
"""
    (work / "vessel_rao.dat").write_text(deck, encoding="utf-8")
    subprocess.run(
        [str(exe), "vessel_rao.dat", "vessel_rao"],
        cwd=work,
        check=True,
        capture_output=True,
    )
    history: dict[float, tuple[float, float]] = {}
    for line in (work / "vessel_rao.out").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        try:
            t, x, z = (float(value) for value in parts[:3])
        except ValueError:
            continue
        history[round(t, 6)] = (x, z)
    return history


def compare(exe: Path, dt: float) -> tuple[int, float, float, float]:
    """Matched samples, amplitude, and max |dX|, |dZ| at one OrcaFlex step and dtM."""
    global DT  # noqa: PLW0603 - both model builders read the module step
    DT = dt
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        times, ox, oz = orcaflex_history(work)
        cd = cabledyn_history(exe, work)
    dx = dz = 0.0
    matched = 0
    for t, x, z in zip(times, ox, oz, strict=True):
        key = round(t, 6)
        if key not in cd:
            continue
        matched += 1
        dx = max(dx, abs(cd[key][0] - x))
        dz = max(dz, abs(cd[key][1] - z))
    amplitude = max(abs(z - (VESSEL_ORIGIN[2] + POINT_LOCAL[2])) for z in oz)
    return matched, amplitude, dx, dz


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    exe = Path(sys.argv[1]).resolve()
    print(f"OrcaFlex {ofx.DLLVersion()} vs CableDyn (same step in both codes)")
    diffs = []
    for dt in (0.05, 0.01, 0.005):
        matched, amplitude, dx, dz = compare(exe, dt)
        diffs.append(max(dx, dz))
        print(
            f"  dt {dt:6.3f} s: {matched} samples, point Z amplitude {amplitude:.4f} m, "
            f"max |dX| = {dx:.3e} m, max |dZ| = {dz:.3e} m"
        )
    # OrcaFlex's imposed vessel motion leads the analytic RAO response by a phase
    # proportional to its implicit time step; CableDyn evaluates the RAO response exactly,
    # so the difference must fall in proportion to the step.
    first_order = diffs[1] < 0.3 * diffs[0] and diffs[2] < 0.6 * diffs[1]
    return 0 if first_order and diffs[2] < 1.0e-3 else 1


if __name__ == "__main__":
    sys.exit(main())
