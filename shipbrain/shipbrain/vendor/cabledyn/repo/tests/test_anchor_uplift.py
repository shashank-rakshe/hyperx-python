#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Anchor uplift channels of the driver: AnchFz<L>, AnchFH<L> and TDP<L>Grd.

Gates, each on the driver's own output files:

* laid catenary: on a grounded R3 chain ``AnchFH`` is the horizontal tension of the analytic
  elastic catenary and equals the fairlead's horizontal force, ``TDP<L>Grd`` is the analytic
  grounded length and ``TDP<L>s + TDP<L>Grd`` the deformed line length, and ``AnchFz`` is the
  small negative end-node share the documentation states (the anchor node's lumped weight plus
  the pull of the anchor segment toward the chain sunk into the penalty seabed);
* suspended line: on a taut chain with no laid length ``AnchFz``/``AnchFH`` are the anchor
  forces of the analytic suspended elastic catenary, consistent with ``AnchTen`` and
  ``AnchIncl``, and ``TDP<L>Grd`` is 0;
* consistency: for an anchor holding one line ``AnchFz<L>`` = ``Point<P>Fz`` and
  ``AnchFH<L>`` = ``Point<P>FH`` exactly, and ``AnchTen`` is the norm of the two, on the static,
  ``EI = 0`` dynamic, point-system, cubic-Hermite, mixed aggregate and multibody routes;
* dynamics: a fairlead surge lifts the anchor of a catenary; at every output time the channels
  are finite and consistent, ``TDP<L>Grd > 0`` implies ``AnchFz < 0`` and ``AnchFz > 0`` implies
  ``TDP<L>Grd = 0``, and the held end state is the suspended elastic catenary;
* sloped seabed: a finite-EI cable laid down a slope from its anchor keeps the down-slope pull,
  so its anchor force runs along the floor and ``AnchTen`` continues the line tension;
* fail-closed contracts: unknown lines reject the names;
* a finite-EI line shared by two turbines (both ends moving, the cubic-Hermite route drives End B
  too): AnchFz is the vertical force on its End B point, minus half the line's submerged weight
  for the symmetric hang at rest (the end force carries the end node's share of the weight).

usage: test_anchor_uplift.py --exe <cabledyn> --examples <examples dir> --output <dir>
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
from cabledyn import read_output  # noqa: E402

FAILURES: list[str] = []
G = 9.80665
RHO = 1025.0
# TDP<L>Grd is continuous with the touchdown point: an anchor node held on the seabed with the next node
# a few millimetres clear of it reads the contact-onset height times the chord over that clearance
# (micrometres to millimetres), not exactly 0. Laid means more than a centimetre.
GRD_TOL = 1.0e-2


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


def set_line_flag(text: str, line_id: int, flags: str) -> str:
    lines = text.splitlines()
    a, b = table_rows(text, "LINES")
    for i in range(a, b):
        tok = lines[i].split()
        if tok and tok[0] == str(line_id):
            tok[3] = flags
            lines[i] = "  ".join(tok)
    return "\n".join(lines) + "\n"


def set_outputs(text: str, names: list[str]) -> str:
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if re.match(r"^-+\s*OUTPUTS\b", line, re.I))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("---"))
    return "\n".join(lines[: start + 1] + [f'"{n}"' for n in names] + lines[end:]) + "\n"


def line_sections(text: str, line_id: int) -> list[tuple[str, float, int]]:
    """(type, length, segments) of each SECTIONS row of one line, End A first."""
    lines = text.splitlines()
    a, b = table_rows(text, "SECTIONS")
    rows = [lines[i].split() for i in range(a, b)]
    return [(tok[1], float(tok[2]), int(tok[3])) for tok in rows if tok and tok[0] == str(line_id)]


def anchor_channels(line_id: int, point_id: int) -> list[str]:
    return [f"AnchTen{line_id}", f"AnchFz{line_id}", f"AnchFH{line_id}", f"Point{point_id}Fz",
            f"Point{point_id}FH"]


def run(exe: str, deck: Path, root: Path, env: dict) -> None:
    proc = subprocess.run([exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=deck.parent)
    if proc.returncode != 0:
        raise SystemExit(f"{deck.name}: driver exit {proc.returncode}\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")


def out_strings(path: Path) -> tuple[list[str], list[list[str]]]:
    """Header and the verbatim value fields of every data row of a driver .out file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    header = lines[1].split("\t")
    return header, [row.split("\t") for row in lines[2:] if row.strip()]


def check_anchor_point(label: str, root: Path, line_id: int, point_id: int) -> None:
    """AnchFz/AnchFH equal the Point<P> resultant of a one-line anchor (the printed text, every
    row), and AnchTen is their norm to the 8 printed digits."""
    header, rows = out_strings(root.with_suffix(".out"))
    col = {name.lower(): k for k, name in enumerate(header)}
    fz, fh = col[f"anchfz{line_id}"], col[f"anchfh{line_id}"]
    pz, ph = col[f"point{point_id}fz"], col[f"point{point_id}fh"]
    same = all(r[fz] == r[pz] and r[fh] == r[ph] for r in rows)
    check(same, f"{label}: AnchFz{line_id}/AnchFH{line_id} = Point{point_id}Fz/FH at all {len(rows)} rows")
    hist = read_output(root.with_suffix(".out"))
    ten = hist.column(f"AnchTen{line_id}")
    norm = np.hypot(hist.column(f"AnchFz{line_id}"), hist.column(f"AnchFH{line_id}"))
    worst = float(np.max(np.abs(norm - ten) / np.maximum(ten, 1e-30)))
    check(worst < 2e-7, f"{label}: AnchTen{line_id} = |(AnchFH, AnchFz)| (max relative difference {worst:.1e})")


def line_lengths(path: Path) -> np.ndarray:
    """Deformed chord length of a line at every row of a dynamic .Line<L>.p.out file."""
    # skip the comment lines (a refined line adds "# DeckNode") and the header row
    lines = [row for row in path.read_text(encoding="utf-8").splitlines() if not row.startswith("#")]
    data = np.array([[float(v) for v in row.split()] for row in lines[1:] if row.strip()])
    xyz = data[:, 1:].reshape(data.shape[0], -1, 3)
    return np.linalg.norm(np.diff(xyz, axis=1), axis=2).sum(axis=1)


def static_line_length(path: Path) -> float:
    """Deformed chord length of a line from a static .Line<L>.p.out table (Node X Y Z)."""
    # skip the comment lines (a refined line adds "# DeckNode") and the header row
    lines = [row for row in path.read_text(encoding="utf-8").splitlines() if not row.startswith("#")]
    data = np.array([[float(v) for v in row.split()] for row in lines[1:] if row.strip()])
    return float(np.linalg.norm(np.diff(data[:, 1:4], axis=0), axis=1).sum())


# ----------------------------------------------------------------------------- analytic catenaries


def newton2(residual, x0: np.ndarray, scale: np.ndarray) -> np.ndarray:
    """Newton iteration on two unknowns (the first a positive tension), with step halving."""
    x = np.array(x0, dtype=float)
    f = np.array(residual(x))
    for _ in range(200):
        jac = np.empty((2, 2))
        for k in range(2):
            dx = np.zeros(2)
            dx[k] = 1e-7 * scale[k]
            jac[:, k] = (np.array(residual(x + dx)) - f) / dx[k]
        step = np.linalg.solve(jac, -f)
        for _ in range(60):
            trial = x + step
            if trial[0] > 0.0:
                f_trial = np.array(residual(trial))
                if np.all(np.isfinite(f_trial)) and np.linalg.norm(f_trial) < max(np.linalg.norm(f), 1e-300):
                    break
            step = 0.5 * step
        x, f = trial, f_trial
        if np.all(np.abs(step) < 1e-12 * scale):
            return x
    raise RuntimeError("catenary Newton iteration did not converge")


def laid_catenary(length: float, span: float, depth: float, w: float, ea: float) -> tuple[float, float, float]:
    """Elastic catenary with a grounded run on a frictionless seabed: (horizontal tension H,
    deformed grounded length, deformed suspended length)."""

    def residual(x: np.ndarray) -> tuple[float, float]:
        h, ls = x
        a = h / w
        xs = a * math.asinh(ls / a) + h * ls / ea + (length - ls) * (1.0 + h / ea)
        zs = a * (math.sqrt(1.0 + (ls / a) ** 2) - 1.0) + w * ls * ls / (2.0 * ea)
        return xs - span, zs - depth

    h, ls = newton2(residual, np.array([1.0e5, 1.5 * depth]), np.array([1.0e5, depth]))
    a = h / w
    u = ls / a
    suspended = ls + (h / (2.0 * w * ea)) * h * (u * math.sqrt(1.0 + u * u) + math.asinh(u))
    return h, (length - ls) * (1.0 + h / ea), suspended


def suspended_catenary(length: float, span: float, rise: float, w: float, ea: float) -> tuple[float, float]:
    """Elastic catenary lifted at its lower (anchor) end: (H, V) of the force the line exerts
    on the anchor, V positive upward."""

    def residual(x: np.ndarray) -> tuple[float, float]:
        h, v = x
        top = (v + w * length) / h
        xs = (h / w) * (math.asinh(top) - math.asinh(v / h)) + h * length / ea
        zs = (h / w) * (math.sqrt(1.0 + top * top) - math.sqrt(1.0 + (v / h) ** 2)) + (
            v * length + 0.5 * w * length * length) / ea
        return xs - span, zs - rise

    h, v = newton2(residual, np.array([w * length, 0.5 * w * length]), np.array([w * length, w * length]))
    return h, v


# ----------------------------------------------------------------------------- the chain decks


R3 = dict(diam=0.2466, mass=373.5, ea=1.607e9)
R4 = dict(diam=0.2791, mass=480.93, ea=2.058e9)


def submerged_weight(line: dict) -> float:
    return (line["mass"] - RHO * math.pi / 4.0 * line["diam"] ** 2) * G


CHAIN = """--------------------- CableDyn Input File ------------------------------------
Anchor uplift gate: one chain leg from a Coupled fairlead (End A) to a Fixed anchor (End B)
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam     MassDenInAir   EA         BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)      (kg/m)         (N)        (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
chain      {diam}   {mass}         {ea}       -1.0       0.0      1.37  0.64  1.0   0.0
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
1     Fixed     {xa}     0.0    {za}      0       0       0      0
2     Coupled   0.0      0.0    {zf}      0       0       0      0
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
1     2       1       p
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
1        chain      {length} {nseg}
--------------------- OPTIONS ------------------------------------------
9.80665      g
1025.0       rhoW
{depth}      WtrDpth
{kbot}       kBot
--------------------- OUTPUTS ------------------------------------------
"FairTen1"
--------------------- need this line -----------------------------------
"""

CHANNELS = ["FairTen1", "Point2FH", "AnchIncl1", "TDP1s", "TDP1Grd", *anchor_channels(1, 1)]


def chain_deck(line: dict, length: float, nseg: int, span: float, depth: float, fair_z: float, kbot: str) -> str:
    deck = CHAIN.format(diam=line["diam"], mass=line["mass"], ea=line["ea"], xa=span, za=-depth, zf=fair_z,
                        length=length, nseg=nseg, depth=depth, kbot=kbot)
    return set_outputs(deck, CHANNELS)


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

    # --- (a) laid catenary: R3 chain, 550 m on a 500 m span at 100 m depth (the tutorial leg). The
    # analytic catenary rests on a rigid seabed, so its gates use a stiff one (kBot 1e9 Pa/m: the
    # chain sinks 13 microns); the tutorial's soft seabed (1e5 Pa/m) gates the end-node share.
    w3 = submerged_weight(R3)
    h_ref, grd_ref, _ = laid_catenary(550.0, 500.0, 100.0, w3, R3["ea"])
    for nseg, kbot in ((55, "1.0e9"), (110, "1.0e9"), (55, "1.0e5"), (110, "1.0e5")):
        label = f"laid catenary, {550.0 / nseg:g} m segments, kBot {kbot}"
        name = f"laid{nseg}_{kbot.replace('.', '').replace('+', '')}"
        (out / f"{name}.dat").write_text(chain_deck(R3, 550.0, nseg, 500.0, 100.0, 0.0, kbot), encoding="utf-8",
                                         newline="\n")
        run(args.exe, out / f"{name}.dat", out / name, env)
        hist = read_output(out / f"{name}.out")
        fz, fh = float(hist.column("AnchFz1")[0]), float(hist.column("AnchFH1")[0])
        grd, s = float(hist.column("TDP1Grd")[0]), float(hist.column("TDP1s")[0])
        ds = 550.0 / nseg
        if kbot == "1.0e9":
            # discretisation: -2.2e-3 on 10 m segments, +5e-5 on 5 m segments
            check(abs(fh - h_ref) < (3e-3 if nseg == 55 else 5e-4) * h_ref,
                  f"{label}: AnchFH1 {fh / 1e3:.2f} kN vs analytic horizontal tension {h_ref / 1e3:.2f} kN "
                  f"({(fh - h_ref) / h_ref:+.1e})")
            check(abs(grd - grd_ref) < 0.5 * ds,
                  f"{label}: TDP1Grd {grd:.2f} m vs analytic grounded length {grd_ref:.2f} m "
                  f"(error {grd - grd_ref:+.2f} m, bound half a segment {0.5 * ds:g} m)")
        fair_h = float(hist.column("Point2FH")[0])
        check(abs(fh - fair_h) < 1e-6 * fh, f"{label}: AnchFH1 equals the fairlead horizontal force Point2FH "
              f"({(fh - fair_h) / fh:+.1e}, frictionless seabed)")
        total = static_line_length(Path(f"{out / name}.Line1.p.out"))
        check(abs(s + grd - total) < 1e-4,
              f"{label}: TDP1s + TDP1Grd = deformed line length {total:.4f} m (difference {s + grd - total:+.1e} m)")
        # the documented end-node share: -(w dL/2 + H delta/dL), delta = w/(kBot d) the sink depth
        delta = w3 / (float(kbot) * R3["diam"])
        share = w3 * ds / 2.0 + fh * delta / ds
        check(-1.05 * share < fz < -0.9 * w3 * ds / 2.0,
              f"{label}: AnchFz1 {fz / 1e3:.2f} kN is the laid anchor's end-node share, estimate "
              f"-{share / 1e3:.2f} kN (node weight -{w3 * ds / 2e3:.2f} kN): downward, not uplift")
        check_anchor_point(label, out / name, 1, 1)

    # --- (b) suspended line: R4 chain 262 m on a 262.5 m chord at 200 m depth, no laid length
    w4 = submerged_weight(R4)
    (out / "taut.dat").write_text(chain_deck(R4, 262.0, 45, 200.0, 200.0, -30.0, "2.0e6"), encoding="utf-8",
                                  newline="\n")
    run(args.exe, out / "taut.dat", out / "taut", env)
    hist = read_output(out / "taut.out")
    fz, fh, ten = (float(hist.column(c)[0]) for c in ("AnchFz1", "AnchFH1", "AnchTen1"))
    incl = math.radians(float(hist.column("AnchIncl1")[0]))
    h_t, v_t = suspended_catenary(262.0, 200.0, 170.0, w4, R4["ea"])
    check(abs(fh - h_t) < 1e-3 * ten and abs(fz - v_t) < 1e-3 * ten,
          f"suspended line: AnchFH1/AnchFz1 {fh / 1e6:.4f}/{fz / 1e6:.4f} MN vs analytic elastic catenary "
          f"{h_t / 1e6:.4f}/{v_t / 1e6:.4f} MN (differences {(fh - h_t) / ten:+.1e}, {(fz - v_t) / ten:+.1e} of AnchTen)")
    node_w = w4 * (262.0 / 45) / 2.0
    check(abs(fz + node_w - fh * math.tan(incl)) < 2e-4 * ten,
          f"suspended line: AnchFz1 + end-node weight = AnchFH1 tan(AnchIncl1) (difference "
          f"{(fz + node_w - fh * math.tan(incl)) / ten:+.1e} of AnchTen): the end force is the anchor "
          "segment's pull plus the anchor node's weight")
    grd_taut = float(hist.column("TDP1Grd")[0])
    check(fz > 0.5 * ten and grd_taut < GRD_TOL,
          f"suspended line: AnchFz1 = {fz / 1e6:.3f} MN uplift and TDP1Grd = {grd_taut:.1e} m (only the anchor "
          "node touches: the TDP sits within the contact-onset height of it)")
    check_anchor_point("suspended line", out / "taut", 1, 1)

    # --- (d) dynamics: a 42 m fairlead surge away from the anchor lifts the laid chain off it
    dt, tmax, offset, ramp = 0.05, 100.0, -42.0, 60.0
    surge_motion(out / "surge.txt", dt, tmax, offset, ramp)
    deck = chain_deck(R3, 550.0, 55, 500.0, 100.0, 0.0, "1.0e5")
    deck = set_option(deck, "dtM", str(dt))
    deck = set_option(deck, "TMax", str(tmax))
    deck = set_option(deck, "motionFile", "surge.txt")
    (out / "lift.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "lift.dat", out / "lift", env)
    hist = read_output(out / "lift.out")
    fz, grd, s = hist.column("AnchFz1"), hist.column("TDP1Grd"), hist.column("TDP1s")
    finite = all(bool(np.all(np.isfinite(hist.column(c)))) for c in CHANNELS)
    check(finite and hist.time.size == 2001, f"surge: every channel is finite at all {hist.time.size} rows")
    check_anchor_point("surge", out / "lift", 1, 1)
    total = line_lengths(Path(f"{out / 'lift'}.Line1.p.out"))
    laid = grd > GRD_TOL
    worst = float(np.max(np.abs(s + grd - total)))
    check(worst < 2e-4, f"surge: TDP1s + TDP1Grd = deformed line length at every row, laid or lifted (max "
          f"difference {worst:.1e} m over {hist.time.size} rows, {int(np.count_nonzero(laid))} of them laid)")
    check(bool(np.all(fz[laid] < 0.0)) and bool(np.all(grd[fz > 0.0] < GRD_TOL)),
          f"surge: TDP1Grd > {GRD_TOL:g} m implies AnchFz1 < 0, and AnchFz1 > 0 implies TDP1Grd <= {GRD_TOL:g} m, "
          "at every row")
    lift, bare = int(np.argmax(fz > 0.0)), int(np.argmax(grd < GRD_TOL))
    check(fz[0] < 0.0 and grd[0] > 390.0 and fz[-1] > 0.0 and grd[-1] < GRD_TOL and bool(np.all(fz[lift:] > 0.0))
          and bool(np.all(grd[bare:] < GRD_TOL)) and 0.0 <= hist.time[lift] - hist.time[bare] < 1.0,
          f"surge: AnchFz1 {fz[0] / 1e3:.1f} -> {fz[-1] / 1e3:.1f} kN and TDP1Grd {grd[0]:.1f} -> {grd[-1]:.1e} m; "
          f"the grounded length reaches 0 at t = {hist.time[bare]:.2f} s and the anchor lifts (AnchFz1 > 0) at "
          f"t = {hist.time[lift]:.2f} s, both for the rest of the run")
    h_end, v_end = suspended_catenary(550.0, 500.0 - offset, 100.0, w3, R3["ea"])
    fz_end, fh_end = float(np.mean(fz[hist.time >= 80.0])), float(np.mean(hist.column("AnchFH1")[hist.time >= 80.0]))
    check(abs(fh_end - h_end) < 5e-3 * h_end and abs(fz_end - v_end) < 3e-3 * h_end,
          f"surge: held state AnchFH1/AnchFz1 {fh_end / 1e6:.4f} MN/{fz_end / 1e3:.1f} kN vs suspended elastic catenary "
          f"{h_end / 1e6:.4f} MN/{v_end / 1e3:.1f} kN")

    # --- (e) finite-EI lazy wave (cubic-Hermite route) under prescribed heave, End B on the seabed
    src = (examples / "lozon_gomex80_power_cable_motion.dat").read_text(encoding="utf-8")
    shutil.copytree(examples / "data", out / "data")
    motion = out / "data" / "lozon" / "gomex80_heave_3m_12s_dt005.txt"
    rows = [r for r in motion.read_text(encoding="utf-8").splitlines() if r.startswith("#") or float(r.split()[0]) <= 3.0001]
    (out / "heave3.txt").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    deck = set_line_flag(src, 1, "p")
    deck = set_option(deck, "TMax", "3.0")
    deck, n_motion = re.subn(r"^\S+\s+motionFile.*$", "heave3.txt motionFile", deck, flags=re.M)
    if n_motion != 1:
        raise RuntimeError("expected one motionFile row in the lazy-wave deck, found %d" % n_motion)
    deck = set_outputs(deck, ["FairTen1", "TDP1s", "TDP1Grd", *anchor_channels(1, 2)])
    (out / "lazywave.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "lazywave.dat", out / "lazywave", env)
    hist = read_output(out / "lazywave.out")
    check_anchor_point("cubic-Hermite lazy wave", out / "lazywave", 1, 2)
    total = line_lengths(Path(f"{out / 'lazywave'}.Line1.p.out"))
    grd = hist.column("TDP1Grd")
    worst = float(np.max(np.abs(hist.column("TDP1s") + grd - total)))
    check(bool(np.all(grd > 30.0)) and worst < 2e-4,
          f"cubic-Hermite lazy wave: TDP1Grd {grd.min():.2f}..{grd.max():.2f} m and TDP1s + TDP1Grd = line length "
          f"(max difference {worst:.1e} m)")
    fz = hist.column("AnchFz1")
    check(bool(np.all(np.abs(fz) <= 1e-9 * hist.column("AnchTen1"))),
          f"cubic-Hermite lazy wave: the grounded end leaves its node weight to the floor (|AnchFz1| <= "
          f"{np.max(np.abs(fz)):.1e} N)")

    # --- (c) the other routes: point system (Free clump weight), mixed aggregate, multibody march
    src = (examples / "clump_weight_free_point.dat").read_text(encoding="utf-8")
    deck = set_outputs(set_option(src, "TMax", "0.5"), ["FairTen1", *anchor_channels(1, 2)])
    (out / "freepoint.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "freepoint.dat", out / "freepoint", env)
    check_anchor_point("Free point (point system)", out / "freepoint", 1, 2)
    hist = read_output(out / "freepoint.out")
    check(bool(np.all(hist.column("AnchFz1") > 0.0)),
          "Free point (point system): the hanging line pulls its clump weight upward (AnchFz1 > 0)")

    src = (examples / "iea15mw_umaine_mixed_cabledyn.dat").read_text(encoding="utf-8")
    deck = set_option(src, "TMax", "0.5")
    # the cable's anchor (End B) node and its laid end section, from the example's own mesh
    sections = line_sections(src, 4)
    n_anchor = sum(nseg for _, _, nseg in sections) + 1
    end_type, end_length, end_nseg = sections[-1]
    check(end_type == "bare", f"mixed example: the cable's anchor section is the bare type ({end_type})")
    l0_end = end_length / end_nseg
    names = ["TDP1s", "TDP1Grd", "TDP4s", "TDP4Grd", *anchor_channels(1, 2), *anchor_channels(4, 8),
             f"BendMom4N{n_anchor}", f"BendMom4N{n_anchor - 1}", f"Curv4N{n_anchor}"]
    deck = set_outputs(deck, names)
    (out / "mixed.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "mixed.dat", out / "mixed", env)
    check_anchor_point("mixed aggregate, EI = 0 chain", out / "mixed", 1, 2)
    check_anchor_point("mixed aggregate, finite-EI cable", out / "mixed", 4, 8)
    hist = read_output(out / "mixed.out")
    check(bool(np.all(hist.column("TDP1Grd") > 0.0)) and bool(np.all(hist.column("AnchFz1") < 0.0)) and
          bool(np.all(hist.column("TDP4Grd") > 0.0)),
          f"mixed aggregate: laid chain (TDP1Grd {hist.column('TDP1Grd')[0]:.1f} m, AnchFz1 "
          f"{hist.column('AnchFz1')[0] / 1e3:.2f} kN) and laid cable (TDP4Grd {hist.column('TDP4Grd')[0]:.1f} m)")
    # the cable's 'bare' type laid on the seabed: the recovered bend moment at the Fixed anchor node and
    # its neighbour carries no fixed-end moment of the element's weight w l0^2 / 12. The line does bend
    # there: the anchor node is held at the seabed depth and the laid run sinks delta = w/(kBot d) into
    # the penalty seabed, a bend of about 2 delta / l0^2 over the anchor element (EI 2 delta / l0^2 =
    # 2.1 N.m on 2.5 m elements), which the bound allows on top of 2 % of the weight moment
    bare_row = re.search(r"^bare\s+(\S+)\s+(\S+)\s+\S+\s+\S+\s+(\S+)", src, re.MULTILINE)
    kbot_row = re.search(r"^(\S+)\s+kBot\b", src, re.MULTILINE)
    check(bare_row is not None and kbot_row is not None, "mixed example: bare LINE TYPES row and kBot option")
    assert bare_row is not None and kbot_row is not None
    d_bare, mass_bare, ei_bare = (float(v) for v in bare_row.groups())
    kbot = float(kbot_row.group(1))
    w_bare = (mass_bare - RHO * math.pi / 4.0 * d_bare**2) * G
    m_end = w_bare * l0_end**2 / 12.0
    m_sink = ei_bare * 2.0 * w_bare / (kbot * d_bare) / l0_end**2
    bound = 0.02 * m_end + m_sink
    bm_anchor, bm_next = hist.column(f"BendMom4N{n_anchor}"), hist.column(f"BendMom4N{n_anchor - 1}")
    check(bool(np.all(np.abs(bm_anchor) < bound)) and bool(np.all(np.abs(bm_next) < bound)) and
          bool(np.all(hist.column(f"Curv4N{n_anchor}") < bound / ei_bare)) and bound < 0.1 * m_end,
          f"mixed aggregate, laid anchor: end-node BendMom4 {np.max(np.abs(bm_anchor)):.2e} N.m and next node "
          f"{np.max(np.abs(bm_next)):.2e} N.m, below {bound:.1f} N.m and far below the element weight moment "
          f"w l0^2/12 = {m_end:.0f} N.m")

    src = (examples / "rigid6_buoy.dat").read_text(encoding="utf-8")
    deck = set_outputs(set_option(src, "TMax", "0.2"), [*anchor_channels(1, 4), *anchor_channels(2, 5)])
    (out / "rigid6.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "rigid6.dat", out / "rigid6", env)
    check_anchor_point("multibody march, line 1", out / "rigid6", 1, 4)
    check_anchor_point("multibody march, line 2", out / "rigid6", 2, 5)

    # --- (d) sloped seabed: a finite-EI cable laid down a 10 deg slope from its anchor. The floor
    # takes only the part of the end force pressing into it, so the anchor keeps the down-slope pull:
    # the anchor force lies along the floor and AnchTen continues the line tension, where dropping
    # the whole downward part read cos(10 deg) of it. Up the end element the tension grows by its
    # along-slope weight w l0 sin(10 deg): on this frictionless floor the along-floor part of the
    # end node's weight stays with the line.
    slope = math.radians(10.0)
    bathy = "".join(f"{x:.1f} {y:.1f} {200.0 + (300.0 - x) * math.tan(slope)!r}\n"
                    for x in range(-200, 701, 100) for y in (-300.0, 300.0))
    (out / "slope_bathy.txt").write_text(bathy, encoding="utf-8", newline="\n")
    d_pc, m_pc, l0_pc = 0.16, 36.7, 2.0
    w_pc = (m_pc - RHO * math.pi / 4.0 * d_pc**2) * G
    deck = f"""finite-EI cable laid down a 10 deg slope from its anchor
--- LINE TYPES ---
TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)
pc {d_pc} {m_pc} 4.69e8 -1 19900 1.2 0.1 1 0
--- POINTS ---
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)
1 Coupled 0 0 -20 0 0 0 0
2 Fixed 300 0 -200 0 0 0 0
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 pc 410 {int(410 / l0_pc)}
--- OPTIONS ---
9.80665 g
1025.0 rhoW
slope_bathy.txt bathymetryFile
100000.0 kBot
1.0e4 cBot
0.05 dtM
0.0 TMax
--- OUTPUTS ---
{" ".join(anchor_channels(1, 2))}
--- need this line ---
"""
    (out / "slope.dat").write_text(deck, encoding="utf-8", newline="\n")
    run(args.exe, out / "slope.dat", out / "slope", env)
    check_anchor_point("finite-EI cable on a sloped seabed", out / "slope", 1, 2)
    hist = read_output(out / "slope.out")
    ten, fz, fh = (float(hist.column(c)[0]) for c in ("AnchTen1", "AnchFz1", "AnchFH1"))
    rows = [row.split() for row in (out / "slope.static.out").read_text(encoding="utf-8").splitlines()[3:]]
    t_next = float(rows[-2][6])
    angle = math.degrees(math.atan2(-fz, fh))
    check(abs(angle - 10.0) < 0.2, f"sloped seabed: the anchor force runs {angle:.2f} deg below horizontal, along "
          "the 10 deg floor (AnchFz < 0: the down-slope pull)")
    expect = t_next + w_pc * l0_pc * math.sin(slope)
    check(abs(ten - expect) < 0.05 * w_pc * l0_pc,
          f"sloped seabed: AnchTen1 {ten:.1f} N continues the next node's tension {t_next:.1f} N plus the end "
          f"element's along-slope weight (expected {expect:.1f} N)")

    # --- fail-closed contracts
    bad = set_outputs(chain_deck(R3, 550.0, 55, 500.0, 100.0, 0.0, "1.0e5"), ["AnchFz2"])
    (out / "bad_line.dat").write_text(bad, encoding="utf-8", newline="\n")
    proc = subprocess.run([args.exe, str(out / "bad_line.dat"), str(out / "bad_line")], capture_output=True,
                          text=True, env=env)
    check(proc.returncode == 1 and "unknown line id" in proc.stderr, "AnchFz of an unknown line is rejected")
    bad = set_outputs(chain_deck(R3, 550.0, 55, 500.0, 100.0, 0.0, "1.0e5").replace(
        "0.0      0.0    0.0 ", "0.0      0.0    -100.0"), ["TDP1Grd"])
    (out / "bad_tdp.dat").write_text(bad, encoding="utf-8", newline="\n")
    proc = subprocess.run([args.exe, str(out / "bad_tdp.dat"), str(out / "bad_tdp")], capture_output=True,
                          text=True, env=env)
    check(proc.returncode != 0 and "exactly one end" in proc.stderr,
          "TDP1Grd of a line grounded at both ends is rejected, as the other TDP channels")
    # a finite-EI line shared by two turbines: both ends move, driven on the cubic-Hermite route
    two_end = """two-moving-end finite-EI line
--- LINE TYPES ---
Name Diam Mass EA BA EI Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)
pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0
--- TURBINES ---
J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw
1 0.0 0.0 0 0 0 0 0 0 0
2 60.0 0.0 0 0 0 0 0 0 0
--- POINTS ---
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)
1 Turbine1 0 0 -20 0 0 0 0
2 Turbine2 0 0 -20 0 0 0 0
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 pcable 75 5
--- OPTIONS ---
9.80665 g
1025.0 rhoW
0.005 dtM
0.01 TMax
--- OUTPUTS ---
AnchTen1 AnchFz1
--- need this line ---
"""
    (out / "two_end.dat").write_text(two_end, encoding="utf-8", newline="\n")
    proc = subprocess.run([args.exe, str(out / "two_end.dat"), str(out / "two_end")], capture_output=True,
                          text=True, env=env)
    check(proc.returncode == 0, "the finite-EI line between two turbines runs (rc %d)" % proc.returncode)
    if proc.returncode == 0:
        rows = [ln.split() for ln in (out / "two_end.out").read_text(encoding="utf-8").splitlines()[2:]]
        anch_ten, anch_fz = float(rows[0][1]), float(rows[0][2])
        # the symmetric hang: each end carries half the submerged weight w L / 2
        w_sub = (250.0 - 1025.0 * math.pi * 0.2**2 / 4.0) * 9.80665
        half = 0.5 * w_sub * 75.0
        print(f"two moving ends: AnchFz1 {anch_fz:.6e} N, -w L / 2 = {-half:.6e} N, AnchTen1 {anch_ten:.6e} N")
        check(abs(anch_fz + half) <= 1.0e-6 * half,
              "AnchFz of a moving End B is the vertical end force, -w L / 2 for the symmetric hang")
        check(abs(anch_fz) < anch_ten, "the vertical End B force is below the End B tension")

    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
