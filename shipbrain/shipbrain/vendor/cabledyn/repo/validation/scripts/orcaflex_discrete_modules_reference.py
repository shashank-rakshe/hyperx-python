# File: validation/scripts/orcaflex_discrete_modules_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex cross-check of discrete buoyancy modules on a lazy-wave cable (ATTACHMENTS).

The lazy-wave cable of tests/test_line_attachments.f90: bare cable (D 0.16 m, 36.70 kg/m,
EA 4.69e8 N, EI 1.99e4 N m2) from a hang-off at (90, 0, -14) to an anchor at (0, 0, -56),
145 m long, both ends pinned; over its middle 50 m (arc 40-90 m from the hang-off) it
carries buoyancy modules at pitch 5 m (10 modules; each 114.15 kg, 0.2297 m3), meshed at
3.08 m / 0.625 m / 3.06 m. OrcaFlex (clump attachments of negligible height, the same
segmentation) and the CableDyn driver solve the static equilibrium; the node positions,
the hang-off tension, and the curvature at the modules and between them are compared, at the
module-zone element lengths 0.625 m and 0.3125 m.

OrcaFlex's node curvature averages the bend over the node's two half segments, which smooths
the curvature peak under a point load: at the modules it lies 16 % below the Hermite nodal
curvature at 0.625 m and 8 % below at 0.3125 m, converging at first order, while CableDyn's
peak moves by 0.5 % under the same halving. Shape (6 cm on 145 m), hang-off tension (0.02 %)
and the curvature between modules (2.0 %, 0.4 %) agree at both meshes.

Run from an environment with OrcFxAPI (11.6d used)::

    python validation/scripts/orcaflex_discrete_modules_reference.py <path-to-cabledyn.exe>

Exits 0 when the node positions agree to 1 % of the depth range, the tension to 1 % and the
mid-pitch curvature to 2 % at both meshes, and OrcaFlex's module-node curvature converges
toward CableDyn's; 1 otherwise; 2 (skip) without OrcFxAPI.
"""

from __future__ import annotations

import math
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import OrcFxAPI as ofx
except Exception as exc:  # noqa: BLE001 - any import/license failure -> skip
    print(f"# OrcaFlex unavailable ({exc}); skipping (this reference needs a license)")
    sys.exit(2)

PITCH = 5.0
MODULE_MASS = (59.53 - 36.70) * PITCH  # kg
MODULE_VOLUME = 0.25 * math.pi * (0.29**2 - 0.16**2) * PITCH  # m3
BUOY_SEGMENTS = 80  # segments over the 50 m module zone (0.625 m)
SECTIONS = ((40.0, 13), (50.0, BUOY_SEGMENTS), (55.0, 18))  # from the hang-off
HANGOFF = (90.0, 0.0, -14.0)
ANCHOR = (0.0, 0.0, -56.0)
ARCS = [40.0 + 0.5 * PITCH + i * PITCH for i in range(10)]


def orcaflex_profile() -> tuple[list[float], list[float], list[float], float]:
    """Node X, Z and curvature from the hang-off, and the hang-off effective tension [N]."""
    model = ofx.Model()
    env = model.environment
    env.WaterDepth = 500.0
    env.Density = 1.025
    env.WaveHeight = 0.0
    bare = model.CreateObject(ofx.ObjectType.LineType, "bare")
    bare.OD = 0.16
    bare.ID = 0.0
    bare.MassPerUnitLength = 36.70 / 1000.0
    bare.EA = 4.69e8 / 1000.0
    bare.EIx = 1.99e4 / 1000.0
    bare.EIy = 1.99e4 / 1000.0
    clump = model.CreateObject(ofx.ObjectType.ClumpType, "module")
    clump.Mass = MODULE_MASS / 1000.0
    clump.Volume = MODULE_VOLUME
    clump.Height = 0.01
    clump.Offset = 0.0
    line = model.CreateObject(ofx.ObjectType.Line, "cable")
    line.NumberOfSections = len(SECTIONS)
    line.LineType = ["bare"] * len(SECTIONS)
    line.Length = [length for length, _ in SECTIONS]
    line.TargetSegmentLength = [length / n for length, n in SECTIONS]
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = HANGOFF
    line.EndBConnection = "Fixed"
    line.EndBX, line.EndBY, line.EndBZ = ANCHOR
    line.NumberOfAttachments = len(ARCS)
    line.AttachmentType = ["module"] * len(ARCS)
    line.Attachmentz = ARCS
    model.CalculateStatics()
    nodes = sum(n for _, n in SECTIONS) + 1
    x = [line.StaticResult("X", ofx.oeNodeNum(i)) for i in range(1, nodes + 1)]
    z = [line.StaticResult("Z", ofx.oeNodeNum(i)) for i in range(1, nodes + 1)]
    curvature = [
        line.StaticResult("Curvature", ofx.oeNodeNum(i)) for i in range(2, nodes)
    ]
    tension = 1000.0 * line.StaticResult("Effective tension", ofx.oeEndA)
    return x, z, [math.nan, *curvature, math.nan], tension


def cabledyn_profile(
    exe: Path, work: Path
) -> tuple[list[float], list[float], list[float], float]:
    """The same static equilibrium from the CableDyn driver's .static.out."""
    deck = (
        f"""lazy-wave cable with discrete buoyancy modules (OrcaFlex cross-check)
--- LINE TYPES ---
Name Diam Mass EA BA EI Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)
bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0
--- POINTS ---
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Fixed {ANCHOR[0]} {ANCHOR[1]} {ANCHOR[2]}
2 Coupled {HANGOFF[0]} {HANGOFF[1]} {HANGOFF[2]}
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 2 1 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
"""
        + "".join(f"1 bare {length} {n}\n" for length, n in SECTIONS)
        + f"""--- ATTACHMENTS ---
LineID ArcLength Mass Volume CdA Ca
(-) (m) (kg) (m^3) (m^2) (-)
1 {ARCS[0]}:{PITCH}:{ARCS[-1]} {MODULE_MASS!r} {MODULE_VOLUME!r} 0.0 1.0
--- OPTIONS ---
9.80665 g
1025.0 rhoW
0.05 dtM
0.0 TMax
--- OUTPUTS ---
FairTen1
END
"""
    )
    (work / "modules.dat").write_text(deck, encoding="utf-8")
    subprocess.run(
        [str(exe), "modules.dat", "modules"], cwd=work, check=True, capture_output=True
    )
    # columns by header name: a refined line adds a DeckNode column
    header: list[str] = []
    rows = []
    for line in (work / "modules.static.out").read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if fields[:1] == ["LineID"]:
            header = fields
            continue
        try:
            values = [float(v) for v in fields]
        except ValueError:
            continue
        if header and len(values) == len(header):
            rows.append(dict(zip(header, values, strict=True)))
    rows.sort(key=lambda r: r["Node"])
    return (
        [r["X"] for r in rows],
        [r["Z"] for r in rows],
        [r["Curvature"] for r in rows],
        rows[0]["Tension"],
    )


def compare(
    exe: Path, buoy_segments: int
) -> tuple[float, float, float, float, float, float]:
    """Arch rise, max node offset, tension ratio - 1, and the module / mid-pitch curvature
    differences (max relative; module peak as CableDyn minus OrcaFlex over CableDyn)."""
    global SECTIONS  # noqa: PLW0603 - both model builders read the module mesh
    SECTIONS = ((40.0, 13), (50.0, buoy_segments), (55.0, 18))
    h = 50.0 / buoy_segments
    ox, oz, ok_, oten = orcaflex_profile()
    with tempfile.TemporaryDirectory() as tmp:
        cx, cz, ck, cten = cabledyn_profile(exe, Path(tmp))
    if len(cx) != len(ox):
        raise RuntimeError(
            f"node count differs: OrcaFlex {len(ox)}, CableDyn {len(cx)}"
        )
    rise = max(oz) - min(oz)
    offset = max(
        math.hypot(a - b, c - d) for a, b, c, d in zip(cx, ox, cz, oz, strict=True)
    )
    module_nodes = [13 + round((s - 40.0) / h) for s in ARCS]
    mid_nodes = [n + round(0.5 * PITCH / h) for n in module_nodes[:-1]]
    k_mod = max((ck[n] - ok_[n]) / ck[n] for n in module_nodes[2:-2])
    k_mid = max(abs(ck[n] / ok_[n] - 1.0) for n in mid_nodes[2:-2])
    return rise, offset, cten / oten - 1.0, k_mod, k_mid, oten


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    exe = Path(sys.argv[1]).resolve()
    print(
        f"OrcaFlex {ofx.DLLVersion()} vs CableDyn, discrete modules at pitch {PITCH} m"
    )
    results = []
    for segments in (80, 160):
        rise, offset, dten, k_mod, k_mid, oten = compare(exe, segments)
        results.append((offset / rise, dten, k_mod, k_mid))
        print(
            f"  module-zone element {50.0 / segments:.4f} m: hang-off tension {oten:.1f} N "
            f"({dten:+.3%}); max node offset {offset:.4f} m ({offset / rise:.3%} of the "
            f"{rise:.2f} m depth range); curvature between modules {k_mid:.3%}; OrcaFlex "
            f"module-node curvature below CableDyn's by {k_mod:.2%}"
        )
    shape_ok = all(r[0] < 0.01 and abs(r[1]) < 0.01 and r[3] < 0.02 for r in results)
    # OrcaFlex's node curvature averages the bend over the node's half segments, which
    # smooths the peak under a point load; it approaches the Hermite nodal value as the
    # segments shrink.
    peak_converges = results[1][2] < 0.6 * results[0][2]
    return 0 if shape_ok and peak_converges else 1


if __name__ == "__main__":
    sys.exit(main())
