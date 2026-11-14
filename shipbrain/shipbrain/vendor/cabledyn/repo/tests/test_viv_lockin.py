#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Cross-flow VIV lock-in of a taut line against MoorDyn-F.

A 100 m line (50 segments, D 0.1 m, 10 kg/m, EA 5e7 N, about 50 kN) between two points at 50 m
depth in a uniform 0.15 m/s cross current, lift coefficient 0.8 with MoorDyn's band (dF 0.08,
cF 0.18): the shedding frequency cF U/D = 0.27 Hz sits on the first vertical mode, and the line
locks in. MoorDyn-F (OpenFAST v5 moordyn_driver, dtM 5e-4 s) gives a mid-span A/D of 0.662 at
0.293 Hz over 150-300 s. Gates, over 60-120 s:

* at dtM 0.01 s the mid-span A/D is within 3 % of MoorDyn-F's and the response frequency within
  one spectral bin (1/60 Hz) of it, with the quarter-span amplitude of the first mode;
* at dtM 0.002 s, a step that resolves the mesh zig-zag mode, the line stays locked in with the
  same amplitude (within 2 %): with the nodes' own kinematics in the synchronisation model the
  zig-zag mode was pumped there and the line lost lock-in after about 70 s;
* the same line as a finite-EI cable (EI 1 N m^2, a string to within 1e-6 of its geometric
  stiffness: the cubic-Hermite route with the Gauss-integrated lift) locks in with the EI = 0
  line's mid-span and quarter-span amplitudes (within 1 %) and frequency, at dtM 0.01 s and at
  0.002 s (no smoothing needed on the Hermite route);
* the same finite-EI cable on the multibody march (End A Fixed, and a weighted Connect point on
  two chains 300 m away, which puts the deck on that march) locks in as on the Hermite route
  (within 1 % and one bin);
* the VIV lift files (LINES Outputs flag V) of the EI = 0 line, the cable and the cable on the
  multibody march: no lift on the EI = 0 line's end nodes (MoorDyn's), and the same cross-flow
  lift at the interior nodes on all three (standard deviation over 60-120 s within 1 %) but the
  end nodes' neighbours: the EI = 0 line's end half-segments carry no lift, as MoorDyn's, while
  a cable element shares its lift between its two nodes;
* a bending-stiff, neutrally buoyant cable (8.1 kg/m, EA 5e9 N, EI 5e7 N m^2, about 51 kN:
  beta = pi^2 EI/(T L^2) ~ 1) against the EI = 0 string tensioned to T (1 + beta), which has
  the same first-mode frequency and shape: at U 0.21 m/s both lock into mode 1 with the same
  mid-span A/D (within 3 %) and frequency; at U 0.30 m/s the string jumps to mode 2 (mid-span
  A/D below 0.15) while the cable, whose bending raises f2/f1 to about 3.15, stays in mode 1
  (mid-span A/D above 0.6);
* at U 0.24 m/s, where two lock-in branches coexist, a start from rest with the spread seed settles
  in mode 2 as MoorDyn-C v2.7.2 does (x/L 0.24 A/D within 3 % of its 0.574, frequency within one
  bin of 0.527 Hz), and VIVphaseSeed zero in mode 1 as MoorDyn-F in OpenFAST v5.0.0 (whose phases
  start at zero) does (mid-span A/D within 1 % of its 0.699, frequency within one bin of 0.353 Hz);
* the lift at t = 0, 2 m from the deck's End A, has MoorDyn's direction and size on an EI = 0 line
  and a finite-EI cable, whether the deck writes the line fairlead first or anchor first, and the
  mid-span response over 60 s is the same on both orders (within 1e-5 m: a node at rest takes
  MoorDyn's cross-flow phase in the line's own frame).

usage: test_viv_lockin.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from cabledyn import read_output  # noqa: E402

FAILURES: list[str] = []
MD_AD, MD_F = 0.662, 0.293  # MoorDyn-F reference, mid span
# U 0.24 m/s, where two lock-in branches coexist (VALIDATION.md L2-VIV): MoorDyn-C v2.7.2 (seeded
# phases, RK2, dtM 5e-4 s) settles on mode 2 (quarter span x/L = 0.24: A/D 0.574 at 0.527 Hz);
# MoorDyn-F v2.3.8 (OpenFAST v5.0.0, phases from zero) on mode 1 (mid span: 0.699 at 0.353 Hz)
MDC_Q24, MDC_F24, MDF_M24, MDF_F24 = 0.574, 0.527, 0.699, 0.353
D = 0.1


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


CURRENT = """MoorDyn v2 water kinematics file
uniform cross-flow current for the VIV lock-in gate
--------------------------- WAVES -------------------------------------
0                    WaveKinMod  - type of wave input
""                   WaveKinFile - file containing wave elevation time series
0.000000E+00  dtWave      - time step to use in setting up wave kinematics grid (s)
0                    WaveDir     - wave heading (deg)
2                                - X wave input type
-10, 110, 2                      - X wave grid point data
2                                - Y wave input type
-10, 10, 2                       - Y wave grid point data
2                                - Z wave input type
-100, 0, 2                       - Z wave grid point data
--------------------------- CURRENT -------------------------------------
1                    CurrentMod  - type of current input
z-depth     x-current      y-current
(m)           (m/s)         (m/s)
0.0    0.0  {u}
-100.0 0.0  {u}
--------------------- need this line ------------------
"""


def deck(dtm: float, ei: float = 0.0, ea: float = 5.0e7, mass: float = 10.0, tension: float = 5.0e4,
         waterkin: str = "current.dat", outputs: str = "-") -> str:
    length = 100.0 / (1.0 + tension / ea)
    return f"""--------------------- CableDyn Input File ---------------------------------
VIV lock-in gate: taut line in a uniform cross current
----------------------- LINE TYPES ------------------------------------------
TypeName   Diam   Mass/m   EA        BA/-zeta  EI   Cd    Ca    CdAx  CaAx  Cl   dF    cF
(name)     (m)    (kg/m)   (N)       (N-s/-)   (-)  (-)   (-)   (-)   (-)   (-)  (-)   (-)
riser      0.10   {mass}     {ea}     -0.8      {ei}  1.2   1.0   0.0   0.0   0.8  0.08  0.18
----------------------- POINTS ----------------------------------------------
ID   Attachment   X       Y     Z      M    V     CdA   CA
(#)  (-)          (m)     (m)   (m)    (kg) (m^3) (m^2) (-)
1    Coupled      0.0     0.0   -50.0  0    0     0     0
2    Fixed        100.0   0.0   -50.0  0    0     0     0
----------------------- LINES -----------------------------------------------
ID   LineType   AttachA  AttachB  UnstrLen  NumSegs  Outputs
(#)  (name)     (#)      (#)      (m)       (-)      (-)
1    riser      1        2        {length:.6f}  50       {outputs}
---------------------- OPTIONS ----------------------------------------------
{dtm}    dtM
100.0    WtrDpth
1025.0   rhoW
9.80665  g
{waterkin}  WaterKin
0.25     VIVrmsWindow
120.0    TMax
---------------------- OUTPUTS -----------------------------------------------
L1N25PZ
L1N12PZ
END
------------------------- need this line --------------------------------------
"""


def multibody(text: str) -> str:
    """The deck with End A Fixed and, 300 m away, a 5 t Connect point hung on two chains: a deck
    with a dynamic point runs on the multibody march."""
    for old, new in (
        ("1    Coupled      0.0     0.0   -50.0", "1    Fixed        0.0     0.0   -50.0"),
        ("riser      0.10", "chain      0.20   250.0    1.0e9     -1.0      0.0   1.2   1.0   0.0   0.0"
                           "   0.0  0.08  0.18\nriser      0.10"),
        ("2    Fixed        100.0   0.0   -50.0  0    0     0     0",
         "2    Fixed        100.0   0.0   -50.0  0    0     0     0\n"
         "3    Fixed        0.0     300.0 -20.0  0    0     0     0\n"
         "4    Connect      50.0    300.0 -60.0  5000 0     0     0\n"
         "5    Fixed        100.0   300.0 -20.0  0    0     0     0"),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    riser = next(line for line in text.splitlines() if line.startswith("1    riser"))
    return text.replace(riser + "\n", riser + "\n2    chain      3        4        70.0  20       -\n"
                        "3    chain      5        4        70.0  20       -\n")


def lift_std(path: Path) -> np.ndarray:
    """Standard deviation over 60-120 s of the cross-flow (z) lift at each node of a V file."""
    lines = path.read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.startswith("Time"))
    names = lines[head].split("\t")
    data = np.loadtxt(lines[head + 1:])
    data = data[data[:, 0] >= 60.0]
    cols = [j for j, name in enumerate(names) if name.endswith("LiftZ(N)")]
    return data[:, cols].std(axis=0)


def response(path: Path, mid_name: str = "L1N25PZ", qtr_name: str = "L1N12PZ",
             peak_of: str = "mid") -> tuple[float, float, float]:
    """Mid A/D, peak frequency (of the mid or the quarter channel), quarter A/D over 60-120 s."""
    hist = read_output(path)
    t = hist.column(hist.channels[0])
    mask = t >= 60.0
    mid = hist.column(mid_name)[mask]
    qtr = hist.column(qtr_name)[mask]
    mid = mid - mid.mean()
    qtr = qtr - qtr.mean()
    sig = mid if peak_of == "mid" else qtr
    dt = float(np.median(np.diff(t[mask])))
    freq = np.fft.rfftfreq(sig.size, dt)
    power = np.abs(np.fft.rfft(sig * np.hanning(sig.size)))
    return (
        math.sqrt(2.0) * float(mid.std()) / D,
        float(freq[1:][np.argmax(power[1:])]),
        math.sqrt(2.0) * float(qtr.std()) / D,
    )


def anchor_first(text: str) -> str:
    """The deck with End A on the fixed point at x = 0 and End B on the coupled point at x = 100 m:
    the same line, which the reader turns around (it runs from its fairlead)."""
    a, b = "1    Coupled      0.0     0.0   -50.0", "2    Fixed        100.0   0.0   -50.0"
    assert a in text and b in text
    return text.replace(a, "1    Fixed        0.0     0.0   -50.0").replace(b, "2    Coupled      100.0   0.0   -50.0")


def first_lift(path: Path, x: float, from_end_b: bool) -> float:
    """Cross-flow (z) lift at t = 0 at the node nearest x of a V file (public node order)."""
    lines = path.read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.startswith("Time"))
    names = lines[head].split("\t")
    row = np.array([float(v) for v in lines[head + 1].split()])
    cols = [j for j, name in enumerate(names) if name.endswith("LiftZ(N)")]
    xs = np.linspace(0.0, 100.0, len(cols))
    if from_end_b:
        xs = xs[::-1]
    return float(row[cols[int(np.argmin(np.abs(xs - x)))]])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for u in (0.15, 0.21, 0.24, 0.30):
        (out / f"current_{u}.dat").write_text(CURRENT.format(u=u), encoding="utf-8", newline="\n")
    # the stiff cable and its equal-frequency string (neutrally buoyant: no sag stiffening)
    beta = math.pi**2 * 5.0e7 / (5.0e4 * 100.0**2)
    stiff = {"ei": 5.0e7, "ea": 5.0e9, "mass": 8.1}
    string = {"ea": 5.0e7, "mass": 8.1, "tension": 5.0e4 * (1.0 + beta)}
    runs = [
        (0.01, "viv_dt0.01", deck(0.01, waterkin="current_0.15.dat", outputs="V")),
        (0.002, "viv_dt0.002", deck(0.002, waterkin="current_0.15.dat")),
        ("fei", "viv_fei", deck(0.01, ei=1.0, waterkin="current_0.15.dat", outputs="V")),
        ("fei_fine", "viv_fei_dt0.002", deck(0.002, ei=1.0, waterkin="current_0.15.dat")),
        ("fei_mb", "viv_fei_multibody",
         multibody(deck(0.01, ei=1.0, waterkin="current_0.15.dat", outputs="V"))),
    ]
    for u in (0.21, 0.30):
        runs.append((("stiff", u), f"viv_stiff_u{u}", deck(0.01, waterkin=f"current_{u}.dat", **stiff)))
        runs.append((("string", u), f"viv_string_u{u}", deck(0.01, waterkin=f"current_{u}.dat", **string)))
    # the two-branch band at U 0.24 m/s, probed at MoorDyn's mid (deck node 25: N26 here) and
    # x/L = 0.24 (node 12: N13): the spread seed, and VIVphaseSeed zero
    band = deck(0.01, waterkin="current_0.24.dat").replace("L1N25PZ\nL1N12PZ", "L1N26PZ\nL1N13PZ")
    runs.append(("band", "viv_band_u0.24", band))
    runs.append(("band_zero", "viv_band_u0.24_zero",
                 band.replace("0.25     VIVrmsWindow", "0.25     VIVrmsWindow\nzero     VIVphaseSeed")))
    # the lift at t = 0 has MoorDyn's direction whichever end the deck writes first
    for ei, tag in ((0.0, "ei0"), (1.0, "fei")):
        start = deck(0.01, ei=ei, waterkin="current_0.24.dat", outputs="V").replace("120.0    TMax",
                                                                                  "0.02     TMax")
        runs.append((("t0", tag, False), f"viv_t0_{tag}", start))
        runs.append((("t0", tag, True), f"viv_t0_{tag}_anchor_first", anchor_first(start)))
        # and the whole response is the same: 60 s at U 0.24 m/s, mid span, either deck order
        order = deck(0.01, ei=ei, waterkin="current_0.24.dat").replace(
            "L1N25PZ\nL1N12PZ", "L1N26PZ\nL1N13PZ").replace("120.0    TMax", "60.0     TMax")
        runs.append((("order", tag, False), f"viv_order_{tag}", order))
        runs.append((("order", tag, True), f"viv_order_{tag}_anchor_first", anchor_first(order)))
    for _, name, text in runs:
        (out / f"{name}.dat").write_text(text, encoding="utf-8", newline="\n")
    env = dict(os.environ, OMP_NUM_THREADS="1")

    def run(name: str) -> subprocess.CompletedProcess[str]:
        cmd = [args.exe, f"{name}.dat", name]
        return subprocess.run(cmd, cwd=out, capture_output=True, text=True, env=env)

    # the decks are independent: run them side by side (a checked Debug build is ~10x slower)
    with ThreadPoolExecutor(max_workers=max(1, min(4, os.cpu_count() or 1))) as pool:
        procs = list(pool.map(run, [name for _, name, _ in runs]))
    results = {}
    for (key, name, _), proc in zip(runs, procs):
        if proc.returncode != 0:
            print(proc.stdout[-2000:], proc.stderr[-2000:])
            check(False, f"{name}: the run completes (exit {proc.returncode})")
            continue
        if isinstance(key, tuple) and key[0] == "t0":
            results[key] = first_lift(out / f"{name}.Line1.V.out", 2.0, key[2])
        elif isinstance(key, tuple) and key[0] == "order":
            hist = read_output(out / f"{name}.out")
            results[key] = hist.column("L1N26PZ")
        elif key in ("band", "band_zero"):
            results[key] = response(out / f"{name}.out", "L1N26PZ", "L1N13PZ",
                                    "qtr" if key == "band" else "mid")
        else:
            results[key] = response(out / f"{name}.out")
    if 0.01 in results:
        ad, f, qtr = results[0.01]
        check(abs(ad - MD_AD) <= 0.03 * MD_AD,
              f"dtM 0.01 s: mid-span A/D {ad:.3f}, MoorDyn-F {MD_AD} (within 3 %)")
        check(abs(f - MD_F) <= 1.0 / 60.0,
              f"dtM 0.01 s: response frequency {f:.3f} Hz, MoorDyn-F {MD_F} Hz (within 1/60 Hz)")
        ratio = math.sin(math.pi * 22.0 / 100.0)
        check(abs(qtr / ad - ratio) <= 0.05,
              f"dtM 0.01 s: quarter/mid amplitude {qtr / ad:.3f}, first mode {ratio:.3f}")
    if 0.01 in results and 0.002 in results:
        a1, a2 = results[0.01][0], results[0.002][0]
        check(abs(a2 - a1) <= 0.02 * a1,
              f"dtM 0.002 s stays locked in: mid-span A/D {a2:.3f} against {a1:.3f} at 0.01 s (within 2 %)")
    if 0.01 in results and "fei" in results:
        (a0, f0, q0), (a1, f1, q1) = results[0.01], results["fei"]
        check(abs(a1 - a0) <= 0.01 * a0 and abs(q1 - q0) <= 0.01 * q0,
              f"finite-EI cable: mid/quarter A/D {a1:.3f}/{q1:.3f}, EI = 0 line {a0:.3f}/{q0:.3f} (within 1 %)")
        check(abs(f1 - f0) <= 1.0 / 60.0,
              f"finite-EI cable: response frequency {f1:.3f} Hz, EI = 0 line {f0:.3f} Hz (within 1/60 Hz)")
    if 0.01 in results and "fei_fine" in results:
        (a0, f0, q0), (a1, f1, q1) = results[0.01], results["fei_fine"]
        check(abs(a1 - a0) <= 0.01 * a0 and abs(q1 - q0) <= 0.01 * q0 and abs(f1 - f0) <= 1.0 / 60.0,
              f"finite-EI cable at dtM 0.002 s: mid/quarter A/D {a1:.3f}/{q1:.3f} at {f1:.3f} Hz, EI = 0 "
              f"line at 0.01 s {a0:.3f}/{q0:.3f} at {f0:.3f} Hz (within 1 % and one bin)")
    if "fei" in results and "fei_mb" in results:
        (a0, f0, q0), (a1, f1, q1) = results["fei"], results["fei_mb"]
        check(abs(a1 - a0) <= 0.01 * a0 and abs(q1 - q0) <= 0.01 * q0 and abs(f1 - f0) <= 1.0 / 60.0,
              f"finite-EI cable on the multibody march: mid/quarter A/D {a1:.3f}/{q1:.3f} at {f1:.3f} Hz, "
              f"Hermite route {a0:.3f}/{q0:.3f} at {f0:.3f} Hz (within 1 % and one bin)")
    lifts = {}
    for key, name in ((0.01, "viv_dt0.01"), ("fei", "viv_fei"), ("fei_mb", "viv_fei_multibody")):
        if key in results:
            lifts[key] = lift_std(out / f"{name}.Line1.V.out")
    if 0.01 in lifts:
        ends = lifts[0.01][[0, -1]]
        check(bool(np.all(ends == 0.0)) and lifts[0.01][25] > 0.5,
              f"EI = 0 line lift file: no lift on the end nodes, mid-span cross-flow lift std "
              f"{lifts[0.01][25]:.3f} N")
    for key, what in (("fei", "cable"), ("fei_mb", "cable on the multibody march")):
        if 0.01 in lifts and key in lifts:
            inner0, inner1 = lifts[0.01][2:-2], lifts[key][2:-2]
            worst = float(np.max(np.abs(inner1 - inner0) / np.maximum(inner0, 1.0e-3)))
            check(worst <= 0.01, f"{what} lift file: interior cross-flow lift std within {worst:.2%} of the "
                  "EI = 0 line's (within 1 %)")
    if ("stiff", 0.21) in results and ("string", 0.21) in results:
        (a1, f1, _), (a0, f0, _) = results[("stiff", 0.21)], results[("string", 0.21)]
        check(abs(a1 - a0) <= 0.03 * a0 and abs(f1 - f0) <= 1.0 / 60.0,
              f"U 0.21 m/s: stiff cable A/D {a1:.3f} at {f1:.3f} Hz, equal-frequency string {a0:.3f} "
              f"at {f0:.3f} Hz (mode 1, within 3 % and one bin)")
    if ("stiff", 0.30) in results and ("string", 0.30) in results:
        a1, a0 = results[("stiff", 0.30)][0], results[("string", 0.30)][0]
        check(a1 > 0.6 and a0 < 0.15,
              f"U 0.30 m/s: stiff cable stays in mode 1 (mid-span A/D {a1:.3f}), the string jumps to "
              f"mode 2 (mid-span A/D {a0:.3f})")
    if "band" in results:
        mid, f, qtr = results["band"]
        check(abs(qtr - MDC_Q24) <= 0.03 * MDC_Q24 and abs(f - MDC_F24) <= 1.0 / 60.0 and mid < 0.1,
              f"U 0.24 m/s, seeded phases: mode 2, x/L 0.24 A/D {qtr:.3f} at {f:.3f} Hz, mid span {mid:.3f}; "
              f"MoorDyn-C {MDC_Q24} at {MDC_F24} Hz (within 3 % and one bin)")
    if "band_zero" in results:
        mid, f, _ = results["band_zero"]
        check(abs(mid - MDF_M24) <= 0.01 * MDF_M24 and abs(f - MDF_F24) <= 1.0 / 60.0,
              f"U 0.24 m/s, VIVphaseSeed zero: mode 1, mid-span A/D {mid:.3f} at {f:.3f} Hz; MoorDyn-F "
              f"{MDF_M24} at {MDF_F24} Hz (within 1 % and one bin)")
    for tag, what in (("ei0", "EI = 0 line"), ("fei", "finite-EI cable")):
        a, b = results.get(("t0", tag, False)), results.get(("t0", tag, True))
        if a is not None and b is not None:
            check(a > 4.0 and abs(b - a) <= 1.0e-9 * abs(a),
                  f"{what}: lift at t = 0, 2 m from the deck's End A, {a:+.4f} N fairlead first and "
                  f"{b:+.4f} N anchor first (MoorDyn's +z, the same on both)")
    for tag, what in (("ei0", "EI = 0 line"), ("fei", "finite-EI cable")):
        a, b = results.get(("order", tag, False)), results.get(("order", tag, True))
        if a is not None and b is not None and a.size == b.size:
            gap = float(np.max(np.abs(a - b)))
            check(gap <= 1.0e-5,
                  f"{what}: mid-span response over 60 s at U 0.24 m/s, fairlead first against anchor first, "
                  f"within {gap:.1e} m (1e-5 m; amplitude about 1.6e-2 m)")
    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
