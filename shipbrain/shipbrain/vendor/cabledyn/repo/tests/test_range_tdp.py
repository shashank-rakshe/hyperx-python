#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Range graphs (LINES flag r) and touchdown-point channels (TDP<L>...) of the driver.

Gates, each on the driver's own output files:

* envelopes: on every standalone route (static, EI = 0 lines, Free points, cubic-Hermite,
  the mixed aggregate and the multibody march) the minimum and maximum of
  ``<root>.Line<L>.range.out`` equal those of the ``Ten``/``Curv``/``BendMom``/``Dec``
  node channels of the same run over the rows of the range window, exactly; the mean
  agrees to rounding, and the clearance is ``pz`` minus the seabed elevation;
* statics: ``TDP<L>s``/``x``/``z``/``Lay`` of a grounded chain match the analytic elastic
  catenary with a touchdown point;
* tracking: under a slow fairlead surge the TDP follows the quasi-static catenary, and
  the excursion is the horizontal TDP displacement;
* agreement: every TDP channel equals ``cabledyn.touchdown_history`` on the per-line
  position file of the same run.

usage: test_range_tdp.py --exe <cabledyn> --examples <examples dir> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from cabledyn import read_output, touchdown_history  # noqa: E402

FAILURES: list[str] = []


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


# ----------------------------------------------------------------------------- decks


def table_rows(text: str, name: str) -> tuple[int, int]:
    """Line index range of the data rows of a deck table (after its two header rows)."""
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if re.match(r"^-+\s*" + name + r"\b", line, re.I))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("---"))
    return start + 3, end


def set_line_flag(text: str, line_id: int, flags: str) -> str:
    lines = text.splitlines()
    a, b = table_rows(text, "LINES")
    for i in range(a, b):
        tok = lines[i].split()
        if tok and tok[0] == str(line_id):
            tok[3] = flags
            lines[i] = "  ".join(tok)
    return "\n".join(lines) + "\n"


def set_option(text: str, key: str, value: str) -> str:
    lines = text.splitlines()
    a, b = table_rows(text, "OPTIONS")
    a -= 2
    for i in range(a, b):
        tok = lines[i].split()
        if len(tok) >= 2 and tok[1].lower() == key.lower():
            lines[i] = f"{value}  {key}"
            return "\n".join(lines) + "\n"
    lines.insert(a, f"{value}  {key}")
    return "\n".join(lines) + "\n"


def set_outputs(text: str, names: list[str]) -> str:
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if re.match(r"^-+\s*OUTPUTS\b", line, re.I))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("---"))
    return "\n".join(lines[: start + 1] + [f'"{n}"' for n in names] + lines[end:]) + "\n"


def node_count(text: str, line_id: int) -> int:
    lines = text.splitlines()
    a, b = table_rows(text, "SECTIONS")
    return 1 + sum(int(lines[i].split()[3]) for i in range(a, b) if lines[i].split()[:1] == [str(line_id)])


def node_channels(line_id: int, nodes: list[int]) -> list[str]:
    names = []
    for j in nodes:
        names += [f"Ten{line_id}N{j}", f"Curv{line_id}N{j}", f"BendMom{line_id}N{j}", f"L{line_id}N{j}Dec"]
        names += [f"L{line_id}N{j}p{c}" for c in "xyz"]
    return names


def tdp_channels(line_id: int) -> list[str]:
    return [f"TDP{line_id}{c}" for c in ("s", "x", "y", "z", "Lay", "Exc")]


def run(exe: str, deck: Path, root: Path, env: dict) -> None:
    proc = subprocess.run([exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=deck.parent)
    if proc.returncode != 0:
        raise SystemExit(f"{deck.name}: driver exit {proc.returncode}\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")


# ----------------------------------------------------------------------------- gates


def range_table(path: Path) -> dict[str, np.ndarray]:
    lines = path.read_text(encoding="utf-8").splitlines()
    header = lines[1].split()
    data = np.array([[float(v) for v in row.split()] for row in lines[3:] if row.strip()])
    return {name: data[:, k] for k, name in enumerate(header)}


def check_envelopes(label: str, root: Path, line_id: int, nodes: list[int], t_start: float, seabed_z: float) -> None:
    """The range file equals the offline envelopes of the node channels of the same run."""
    hist = read_output(root.with_suffix(".out"))
    table = range_table(Path(f"{root}.Line{line_id}.range.out"))
    t = hist.time
    rows = t >= t_start - 1e-9 * max(1.0, abs(t_start))
    n = int(np.count_nonzero(rows))
    title = Path(f"{root}.Line{line_id}.range.out").read_text(encoding="utf-8").splitlines()[0]
    check(f"; {n} samples" in title, f"{label}: range window holds the {n} output rows at t >= {t_start:g} s")
    exact = True
    mean_err = 0.0
    clear_err = 0.0
    for j in nodes:
        k = j - 1
        for prefix, column in (("Ten", "Tension"), ("Curv", "Curvature"), ("BendMom", "BendMoment")):
            v = hist.column(f"{prefix}{line_id}N{j}")[rows]
            exact &= v.min() == table[column + "Min"][k] and v.max() == table[column + "Max"][k]
            mean_err = max(mean_err, abs(v.mean() - table[column + "Mean"][k]) / max(abs(v).max(), 1e-30))
        v = hist.column(f"L{line_id}N{j}Dec")[rows]
        exact &= v.min() == table["DeclinationMin"][k] and v.max() == table["DeclinationMax"][k]
        mean_err = max(mean_err, abs(v.mean() - table["DeclinationMean"][k]) / max(abs(v).max(), 1e-30))
        c = hist.column(f"L{line_id}N{j}pz")[rows] - seabed_z
        for stat, f in (("Min", np.min), ("Max", np.max), ("Mean", np.mean)):
            clear_err = max(clear_err, abs(f(c) - table["Clearance" + stat][k]))
    check(exact, f"{label}: range minimum and maximum equal the node channels exactly ({len(nodes)} nodes)")
    check(mean_err < 1e-6, f"{label}: range mean equals the channel mean (max relative difference {mean_err:.1e})")
    check(clear_err < 2e-5 * max(1.0, abs(seabed_z)),
          f"{label}: clearance is pz minus the seabed (max difference {clear_err:.1e} m)")


def check_tdp_vs_python(label: str, root: Path, line_id: int, seabed_z: float, tol: float) -> None:
    """Every TDP channel equals cabledyn.touchdown_history on the per-line position file."""
    hist = read_output(root.with_suffix(".out"))
    ref = touchdown_history(read_output(Path(f"{root}.Line{line_id}.p.out")), seabed_z=seabed_z, tolerance=1e-6)
    m = ref.touching
    check(bool(np.all(m)), f"{label}: the line touches down at every output time")
    worst = 0.0
    pairs = (("s", ref.arc_length), ("x", ref.coordinates[:, 0]), ("y", ref.coordinates[:, 1]),
             ("z", ref.coordinates[:, 2]), ("Lay", ref.layback), ("Exc", ref.excursion))
    for comp, values in pairs:
        worst = max(worst, float(np.max(np.abs(hist.column(f"TDP{line_id}{comp}")[m] - values[m]))))
    check(worst < tol, f"{label}: TDP channels agree with touchdown_history (max difference {worst:.1e} m)")


def check_output_recovery(exe: str, deck: str, out: Path, env: dict, nodes: list[int]) -> None:
    """OPTIONS OutputRecovery on the lazy-wave run: the element definitions change only the
    interior node tension, curvature and bend moment; the end forces (also the end-node
    Tension), positions and TDP are unchanged; an unknown value stops the run."""
    element = set_option(deck, "OutputRecovery", "element")
    (out / "lazywave_element.dat").write_text(element, encoding="utf-8", newline="\n")
    run(exe, out / "lazywave_element.dat", out / "lazywave_element", env)
    eq = read_output(out / "lazywave.out")
    el = read_output(out / "lazywave_element.out")
    same = ["FairTen1", *tdp_channels(1), f"Ten1N{nodes[0]}", f"Ten1N{nodes[-1]}"]
    same += [f"L1N{j}p{c}" for j in nodes for c in "xyz"]
    check(all(np.array_equal(eq.column(n), el.column(n)) for n in same),
          "OutputRecovery element: end forces, end-node Tension, positions and TDP channels are unchanged")
    changed = all(
        not np.array_equal(eq.column(f"{p}1N{j}"), el.column(f"{p}1N{j}"))
        for j in nodes[1:-1]
        for p in ("Ten", "Curv", "BendMom")
    )
    check(changed, "OutputRecovery element: every interior Ten, Curv and BendMom channel takes the element definition")
    bad = set_option(deck, "OutputRecovery", "nodal")
    (out / "lazywave_bad.dat").write_text(bad, encoding="utf-8", newline="\n")
    proc = subprocess.run([exe, str(out / "lazywave_bad.dat"), str(out / "lazywave_bad")], capture_output=True,
                          text=True, env=env, cwd=out)
    check(proc.returncode == 1 and "must be equilibrium or element" in proc.stdout + proc.stderr,
          "OutputRecovery: an unknown value stops the run by name")


def check_soft_section_curvature(exe: str, deck: str, out: Path, env: dict, nodes: list[int]) -> None:
    """A section softer than max(|w| L0^2)/12 times 1 m (1.3 kN m^2 on this cable) cannot resolve a
    curvature from the recovered moment, whose error does not scale with EI: Curv takes the exact
    geometric trace (the OutputRecovery element value) instead of an amplified moment error. With
    EI = 100 N m^2 the recovered curvature would exceed 6 1/m against a peak trace of 0.12 1/m."""
    soft, count = re.subn(r"1\.99e4", "1.0e2", deck)
    if count != 2:
        raise RuntimeError("expected two EI entries in the lazy-wave line types, found %d" % count)
    names = [f"Curv1N{j}" for j in nodes]
    soft = set_outputs(soft, names)
    (out / "lazywave_soft.dat").write_text(soft, encoding="utf-8", newline="\n")
    run(exe, out / "lazywave_soft.dat", out / "lazywave_soft", env)
    element = set_option(soft, "OutputRecovery", "element")
    (out / "lazywave_soft_element.dat").write_text(element, encoding="utf-8", newline="\n")
    run(exe, out / "lazywave_soft_element.dat", out / "lazywave_soft_element", env)
    eq = read_output(out / "lazywave_soft.out")
    el = read_output(out / "lazywave_soft_element.out")
    worst = max(float(np.max(np.abs(eq.column(n) - el.column(n)))) for n in names)
    peak = max(float(np.max(el.column(n))) for n in names)
    check(worst == 0.0 and 0.0 < peak < 1.0,
          f"soft section (EI = 100 N m^2): Curv takes the exact geometric trace (peak {peak:.3f} 1/m, "
          f"difference to OutputRecovery element {worst:.1e})")


def catenary_tdp(length: float, span: float, depth: float, w: float, ea: float) -> tuple[float, float, float]:
    """Elastic catenary resting on a frictionless seabed: (TDP deformed arc from the fairlead,
    TDP horizontal distance from the fairlead, horizontal tension)."""

    def residual(h: float, ls: float) -> tuple[float, float]:
        a = h / w
        x = a * math.asinh(ls / a) + h * ls / ea + (length - ls) * (1.0 + h / ea)
        z = a * (math.sqrt(1.0 + (ls / a) ** 2) - 1.0) + w * ls * ls / (2.0 * ea)
        return x - span, z - depth

    h, ls = 1.0e5, depth * 1.5
    for _ in range(100):
        f = residual(h, ls)
        d = 1e-6
        j = np.array([
            [(residual(h * (1 + d), ls)[0] - f[0]) / (h * d), (residual(h, ls * (1 + d))[0] - f[0]) / (ls * d)],
            [(residual(h * (1 + d), ls)[1] - f[1]) / (h * d), (residual(h, ls * (1 + d))[1] - f[1]) / (ls * d)],
        ])
        step = np.linalg.solve(j, -np.array(f))
        h, ls = h + step[0], ls + step[1]
        if abs(step[0]) < 1e-9 * h and abs(step[1]) < 1e-12 * ls:
            break
    a = h / w
    u = ls / a
    stretched = ls + (h / (2.0 * w * ea)) * h * (u * math.sqrt(1.0 + u * u) + math.asinh(u))
    x_susp = a * math.asinh(u) + h * ls / ea
    return stretched, x_susp, h


CHAIN = """--------------------- CableDyn Input File ------------------------------------
Range-graph and touchdown gate: R3 chain catenary, 100 m depth, grounded at End B
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam     MassDenInAir   EA         BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)      (kg/m)         (N)        (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
1     Fixed     500.0    0.0    -100.0    0       0       0      0
2     Coupled   0.0      0.0    0.0       0       0       0      0
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
1     2       1       -
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
1        chainR3    550.0    {nseg}
--------------------- OPTIONS ------------------------------------------
9.80665      g
1025.0       rhoW
100.0        WtrDpth
{kbot}       kBot
--------------------- OUTPUTS ------------------------------------------
"FairTen1"
--------------------- need this line -----------------------------------
"""
CHAIN_W = (373.5 - 1025.0 * math.pi / 4.0 * 0.2466**2) * 9.80665


def surge_motion(path: Path, dt: float, tmax: float, offset: float, ramp: float) -> None:
    """Fairlead (point 2) surge from x = 0 to x = offset with a quintic ramp, then held."""
    rows = ["# time id x y z vx vy vz ax ay az"]
    for i in range(int(round(tmax / dt)) + 1):
        t = i * dt
        tau = min(t / ramp, 1.0)
        s = 10 * tau**3 - 15 * tau**4 + 6 * tau**5
        ds = (30 * tau**2 - 60 * tau**3 + 30 * tau**4) / ramp if t < ramp else 0.0
        dds = (60 * tau - 180 * tau**2 + 120 * tau**3) / ramp**2 if t < ramp else 0.0
        rows.append("%.6f 2 %.12e 0 0 %.12e 0 0 %.12e 0 0" % (t, offset * s, offset * ds, offset * dds))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")


def fairlead_x(out: Path) -> tuple[np.ndarray, np.ndarray]:
    rows = [r.split() for r in (out / "surge.txt").read_text(encoding="utf-8").splitlines()[1:]]
    return np.array([float(r[0]) for r in rows]), np.array([float(r[2]) for r in rows])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--examples", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    examples = Path(args.examples)
    env = dict(os.environ)

    # --- statics: the analytic elastic catenary with a touchdown point. A stiff seabed keeps the
    # grounded chain on z = -WtrDpth; nodal contact places the TDP within one segment of the
    # tangent point, so the error must fall below half a segment and shrink with the mesh.
    s_ref, x_ref, _ = catenary_tdp(550.0, 500.0, 100.0, CHAIN_W, 1.607e9)
    errors = []
    for nseg in (550, 1100):
        deck = CHAIN.format(nseg=nseg, kbot="1.0e9")
        deck = set_line_flag(deck, 1, "r")
        names = ["FairTen1", *tdp_channels(1)]
        if nseg == 550:
            names += node_channels(1, list(range(1, 552)))
        deck = set_outputs(deck, names)
        (out / f"static{nseg}.dat").write_text(deck, encoding="utf-8", newline="\n")
        run(args.exe, out / f"static{nseg}.dat", out / f"static{nseg}", env)
        hist = read_output(out / f"static{nseg}.out")
        s, x, z, lay = (float(hist.column(f"TDP1{c}")[0]) for c in ("s", "x", "z", "Lay"))
        ds = 550.0 / nseg
        errors.append(max(abs(s - s_ref), abs(x - x_ref)))
        check(errors[-1] < 0.5 * ds,
              f"static, {ds:g} m segments: TDP arc {s:.3f} m / x {x:.3f} m vs analytic catenary "
              f"{s_ref:.3f} m / {x_ref:.3f} m (error {errors[-1]:.3f} m)")
        check(abs(z + 100.0) < 1e-5 and abs(lay - x) < 1e-9 and hist.column("TDP1Exc")[0] == 0.0,
              f"static, {ds:g} m segments: TDP on the seabed, layback = horizontal distance to the fairlead, "
              "zero excursion")
    check(errors[1] < 0.75 * errors[0], f"static: the TDP error shrinks with the mesh ({errors[0]:.3f} -> "
          f"{errors[1]:.3f} m)")
    check_envelopes("static", out / "static550", 1, list(range(1, 552)), 0.0, -100.0)

    # --- tracking: EI = 0 chain on the stiff seabed, slow 12 m surge away from the anchor, then
    # held: the TDP follows the quasi-static catenary (within the half-segment nodal-contact bound)
    dt, tmax, offset, ramp = 0.05, 60.0, -12.0, 40.0
    surge_motion(out / "surge.txt", dt, tmax, offset, ramp)
    deck = CHAIN.format(nseg=550, kbot="1.0e9")
    deck = set_option(deck, "dtM", str(dt))
    deck = set_option(deck, "TMax", str(tmax))
    deck = set_option(deck, "motionFile", "surge.txt")
    deck = set_outputs(deck, ["FairTen1", *tdp_channels(1)])
    (out / "track.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "track.dat", out / "track", env)
    hist = read_output(out / "track.out")
    s0, x0 = catenary_tdp(550.0, 500.0, 100.0, CHAIN_W, 1.607e9)[:2]
    s1, x1 = catenary_tdp(550.0, 500.0 - offset, 100.0, CHAIN_W, 1.607e9)[:2]
    s_end, x_end = float(hist.column("TDP1s")[-1]), float(hist.column("TDP1x")[-1])
    check(abs(float(hist.column("TDP1s")[0]) - s0) < 0.5 and abs(s_end - s1) < 0.5,
          f"tracking: TDP arc {hist.column('TDP1s')[0]:.2f} -> {s_end:.2f} m vs quasi-static catenary "
          f"{s0:.2f} -> {s1:.2f} m")
    check(abs(x_end - (offset + x1)) < 0.5, f"tracking: TDP x {x_end:.2f} m vs quasi-static {offset + x1:.2f} m")
    exc = hist.column("TDP1Exc")
    xs = hist.column("TDP1x")
    check(bool(np.allclose(exc, -(xs - xs[0]), atol=1e-4)),
          "tracking: excursion is the horizontal TDP displacement toward the fairlead")
    check(abs(float(exc[-1]) - (x0 - (offset + x1))) < 0.5,
          f"tracking: final excursion {exc[-1]:.2f} m vs quasi-static {x0 - (offset + x1):.2f} m")
    lay = hist.column("TDP1Lay")
    check(bool(np.allclose(lay, xs - np.interp(hist.time, *fairlead_x(out)), atol=1e-4)),
          "tracking: layback is the horizontal distance from the TDP to the moving fairlead")

    # --- EI = 0 chain on the default penalty seabed, same surge: channels vs touchdown_history
    # (a finite contact slope keeps the TDP well conditioned against the 8-digit position file)
    deck = CHAIN.format(nseg=110, kbot="1.0e5")
    deck = set_line_flag(deck, 1, "pr")
    deck = set_option(deck, "dtM", str(dt))
    deck = set_option(deck, "TMax", str(tmax))
    deck = set_option(deck, "motionFile", "surge.txt")
    deck = set_option(deck, "RangeStart", "20.0")
    nodes = list(range(1, 112))
    deck = set_outputs(deck, ["FairTen1", *tdp_channels(1), *node_channels(1, nodes)])
    (out / "surge.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "surge.dat", out / "surge", env)
    check_tdp_vs_python("EI=0 surge", out / "surge", 1, -100.0, 5e-3)
    check_envelopes("EI=0 surge", out / "surge", 1, nodes, 20.0, -100.0)

    # --- cubic-Hermite lazy wave (finite-EI) under prescribed heave
    src = (examples / "lozon_gomex80_power_cable_motion.dat").read_text(encoding="utf-8")
    shutil.copytree(examples / "data", out / "data")
    motion = out / "data" / "lozon" / "gomex80_heave_3m_12s_dt005.txt"
    rows = [
        r for r in motion.read_text(encoding="utf-8").splitlines() if r.startswith("#") or float(r.split()[0]) <= 3.0001
    ]
    (out / "heave3.txt").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    deck = set_line_flag(src, 1, "pr")
    deck = set_option(deck, "TMax", "3.0")
    deck, n_motion = re.subn(r"^\S+\s+motionFile.*$", "heave3.txt motionFile", deck, flags=re.M)
    if n_motion != 1:
        raise RuntimeError("expected one motionFile row in the lazy-wave deck, found %d" % n_motion)
    deck = set_option(deck, "RangeStart", "1.0")
    nn = node_count(src, 1)
    nodes = sorted(set(range(1, nn + 1, 8)) | {nn})
    deck = set_outputs(deck, ["FairTen1", *tdp_channels(1), *node_channels(1, nodes)])
    (out / "lazywave.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "lazywave.dat", out / "lazywave", env)
    check_envelopes("cubic-Hermite", out / "lazywave", 1, nodes, 1.0, -80.0)
    check_tdp_vs_python("cubic-Hermite", out / "lazywave", 1, -80.0, 5e-3)
    check_output_recovery(args.exe, deck, out, env, nodes)
    check_soft_section_curvature(args.exe, deck, out, env, nodes)

    # --- Free point (point-system route)
    src = (examples / "clump_weight_free_point.dat").read_text(encoding="utf-8")
    deck = set_option(src, "TMax", "0.5")
    names = ["FairTen1"]
    lines = src.splitlines()
    a, b = table_rows(src, "LINES")
    ids = [int(lines[i].split()[0]) for i in range(a, b) if lines[i].split()]
    for lid in ids:
        deck = set_line_flag(deck, lid, "r")
        names += node_channels(lid, list(range(1, node_count(src, lid) + 1)))
    deck = set_outputs(deck, names)
    (out / "freepoint.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "freepoint.dat", out / "freepoint", env)
    for lid in ids:
        check_envelopes(f"Free point line {lid}", out / "freepoint", lid,
                        list(range(1, node_count(src, lid) + 1)), 0.0, -250.0)

    # --- mixed EI = 0 + finite-EI (the aggregate that OpenFAST couples)
    src = (examples / "iea15mw_umaine_mixed_cabledyn.dat").read_text(encoding="utf-8")
    deck = set_option(src, "TMax", "0.5")
    names = [*tdp_channels(1), *tdp_channels(4)]
    for lid in (1, 4):
        deck = set_line_flag(deck, lid, "r")
        names += node_channels(lid, list(range(1, node_count(src, lid) + 1)))
    deck = set_outputs(deck, names)
    (out / "mixed.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "mixed.dat", out / "mixed", env)
    for lid in (1, 4):
        check_envelopes(f"mixed line {lid}", out / "mixed", lid, list(range(1, node_count(src, lid) + 1)), 0.0,
                        -200.0)
    hist = read_output(out / "mixed.out")
    for lid in (1, 4):
        ref = touchdown_history(hist, seabed_z=-200.0, tolerance=1e-6, line_id=lid)
        worst = 0.0
        for comp, values in (("s", ref.arc_length), ("x", ref.coordinates[:, 0]), ("Lay", ref.layback),
                             ("Exc", ref.excursion)):
            worst = max(worst, float(np.max(np.abs(hist.column(f"TDP{lid}{comp}") - values))))
        check(worst < 5e-3, f"mixed line {lid}: TDP channels agree with touchdown_history (difference {worst:.1e} m)")

    # --- multibody march (Rigid6 buoy)
    src = (examples / "rigid6_buoy.dat").read_text(encoding="utf-8")
    deck = set_option(src, "TMax", "0.2")
    lines = src.splitlines()
    a, b = table_rows(src, "LINES")
    lid = int(lines[a].split()[0])
    deck = set_line_flag(deck, lid, "r")
    nodes = list(range(1, node_count(src, lid) + 1))
    deck = set_outputs(deck, node_channels(lid, nodes))
    (out / "rigid6.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "rigid6.dat", out / "rigid6", env)
    check_envelopes("Rigid6 body", out / "rigid6", lid, nodes, 0.0, -100.0)

    # --- fail-closed contracts
    bad = set_option(CHAIN.format(nseg=55, kbot="1.0e5"), "RangeStart", "1.0")
    (out / "bad_rangestart.dat").write_text(bad, encoding="utf-8", newline="\n")
    proc = subprocess.run([args.exe, str(out / "bad_rangestart.dat"), str(out / "bad")], capture_output=True,
                          text=True, env=env)
    check(proc.returncode == 1 and "RangeStart" in proc.stderr, "RangeStart without a range line is rejected")
    bad = CHAIN.format(nseg=55, kbot="1.0e5").replace("0.0      0.0    0.0 ", "0.0      0.0    -100.0")
    bad = set_outputs(bad, ["TDP1s"])
    (out / "bad_tdp.dat").write_text(bad, encoding="utf-8", newline="\n")
    proc = subprocess.run([args.exe, str(out / "bad_tdp.dat"), str(out / "bad2")], capture_output=True, text=True,
                          env=env)
    check(proc.returncode != 0 and "exactly one end" in proc.stderr,
          "TDP channels of a line grounded at both ends are rejected")

    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
