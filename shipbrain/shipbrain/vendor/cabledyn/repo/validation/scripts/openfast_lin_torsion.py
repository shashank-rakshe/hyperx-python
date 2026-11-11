#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""OpenFAST linearisation of finite-EI lines restrained in torsion (CompMooring = 5).

Three decks, each linearised once at t = 0 in the case of openfast_lin_ab.py (the IEA-15MW
UMaine model, platform DOFs only, still water, OutFmt ES24.15E3, module-level output), with
the deck below as the only mooring:

  1. A straight, neutrally buoyant 100 m line held taut at 0.5 % strain between a coupled
     fairlead (0, 0, -20) and a fixed anchor below it, pinned in bending and rigid in torsion
     at both ends, GJ = 5e4 N m^2, polar inertia Irn = 2 kg m, 50 elements, no drag or added
     mass. Gated:
       * the torsional modes from the eigenvalues of the module's A (the modes whose
         eigenvectors lie on the twist states): the first three frequencies against the
         continuum's n pi/L sqrt(GJ/Irn), within the lumped-inertia discretisation error
         (n pi/N)^2/24, and against the lumped chain's 2 sqrt(GJ/Irn)/h sin(n pi/(2N));
       * the roll stiffness of the coupled point: -(D - C A^-1 B) of the fairlead moment about
         the line axis per unit rotation about it against GJ/L; the feedthrough D alone is
         printed (the end element's GJ/l_e: what a linearisation without twist states gives).
  2. The lazy-wave power cable of examples/iea15mw_umaine_mixed_cabledyn.dat (line 4, the
     same mesh, seabed friction off) alone, with GJ = 5e4 N m^2 and the sections' polar
     inertia, pinned in bending at both ends with the directors along its static end tangents,
     rigid in torsion, and twisted by --pretwist (default 90 deg) at End B: a twisted,
     non-planar lazy wave. Gated against the standalone driver's static solutions of the same
     deck (TMax = 0), by central differences:
       * rotation about the End A director d: Pretwist(A) = +-delta (--dtwist, default 0.5 deg)
         rolls the fairlead frame about d as a platform rotation about d does, so
         -d Torq1N1/d delta is d^T K_rot d (the moment on the fairlead about d is the torque);
       * translation: the coupled point moved +-h (--cable-h, default 0.05 m) along each axis:
         the 3x3 force stiffness and the torque row d^T K_M,x;
       * the force column per rotation about d, K_F,rot d, against that torque row, its
         reciprocal (the static stiffness is symmetric): the static force changes by about
         1e-3 N over the rotation step, below the 8 digits the driver writes, so its direct
         difference is only printed;
     entries >= 10 % of the largest of their block within --pct (default 1 %), every entry
     >= 1 % of it within twice that. The operating-point moment about d must equal the
     static Torq1N1.

  3. The straight line of 1 restrained in torsion at End A only, End B free to twist: the free
     end's angle is a state; the torsional modes of A are the clamped-free ones, against the
     continuum's quarter-wave (2n - 1) pi/(2L) sqrt(GJ/Irn) within x^2/6, x = (2n - 1) pi/(4N),
     and the lumped chain's 2 sqrt(GJ/Irn)/h sin(x); the roll stiffness about the line axis
     vanishes (the platform turns the line as a whole), against the feedthrough GJ/l_e.

Measured (the 0.4.0 module): the three torsional modes are the lumped chain's to 5e-14 and the
continuum's within -1.6e-4, -6.6e-4, -1.5e-3; the straight line's roll stiffness is GJ/L to
1.5e-14 (feedthrough D alone 25 000 = GJ/l_e); the twisted lazy wave matches its static
solutions to 4.9e-4 (the moment about d per unit rotation 82.4268 / 82.4263 N m/rad, 5.9e-6);
the line free at End B has 100 twist states, its modes are the clamped-free chain's to 2.5e-13
and lie 4.1e-5, 3.7e-4, 1.0e-3 below the quarter-wave, and its roll stiffness is 0 against the
feedthrough 25 000.
An executable without twist states refuses both decks at initialisation ("formal OpenFAST
linearization of a line restrained in torsion is not supported"); with the twist angles held
the straight line's roll stiffness would be the end element's GJ/l_e, 50 times GJ/L.

Usage:
    python validation/scripts/openfast_lin_torsion.py --exe <openfast.exe> --case-dir <dir>
        --driver <cabledyn driver> [--ref-cd IEA-15-UMaine_CompMooring5_CableDyn.fst]
        [--mixed-deck examples/iea15mw_umaine_mixed_cabledyn.dat] [--pretwist 90]
        [--dtwist 0.5] [--cable-h 0.05] [--pct 1.0] [--skip-run]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import openfast_lin_ab as ab

RHOW = 1025.0
GJ = 5.0e4
L_STRAIGHT = 100.0
N_STRAIGHT = 50
IRN_STRAIGHT = 2.0


def straight_deck(tors_b: str = "Rigid") -> str:
    mass = RHOW * 0.25 * np.pi * 0.2**2
    return "\n".join([
        "--------------------- CableDyn Input File ------------------------------------",
        "Straight vertical line restrained in torsion (openfast_lin_torsion.py)",
        "--------------------- LINE TYPES ---------------------------------------------",
        "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat",
        "(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)",
        f"cab 0.2 {mass:.16e} 1.0e7 0.0 1.0e6 1.0e8 {GJ:.1e} 1.0 {IRN_STRAIGHT} 0.0 0.0 0.0 0.0",
        "--------------------- POINTS ------------------------------------------------",
        "ID Type X Y Z",
        "(-) (-) (m) (m) (m)",
        "1 Coupled 0.0 0.0 -20.0",
        "2 Fixed 0.0 0.0 -120.5",
        "--------------------- LINES -------------------------------------------------",
        "ID NodeA NodeB Outputs",
        "(-) (-) (-) (-)",
        "1 1 2 -",
        "--------------------- SECTIONS ----------------------------------------------",
        "LineID LineType Length NumSegs",
        "(-) (-) (m) (-)",
        f"1 cab {L_STRAIGHT} {N_STRAIGHT}",
        "--------------------- END CONNECTIONS ---------------------------------------",
        "LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist",
        "(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)",
        "1 A Pinned 0 0 -1 Rigid 1 0 0 0",
        f"1 B Pinned 0 0 -1 {tors_b} 1 0 0 0",
        "--------------------- OPTIONS -----------------------------------------------",
        "0.025 dtM - CableDyn time step (s)",
        "--------------------- OUTPUTS -----------------------------------------------",
        '"Torq1N1"',
        "END",
        "--------------------- need this line ----------------------------------------",
        "",
    ])


def lazy_wave_parts(mixed: Path) -> dict:
    """Line 4 of the mixed example: its line types, end points, sections and options."""
    if not mixed.is_file():
        ab.die(f"mixed deck not found: {mixed}")
    lines = mixed.read_text().splitlines()
    sec = None
    types, points, sections, options = {}, {}, [], []
    for ln in lines:
        if ln.lstrip().startswith("-"):
            up = ln.upper()
            sec = next((s for s in ("LINE TYPES", "POINTS", "LINES", "SECTIONS", "OPTIONS", "OUTPUTS")
                        if s in up), None)
            continue
        tok = ln.split()
        if not tok or tok[0].startswith("("):
            continue
        if sec == "LINE TYPES" and len(tok) == 10 and tok[0] in ("bare", "buoy"):
            types[tok[0]] = tok
        elif sec == "POINTS" and tok[0] in ("7", "8"):
            points[tok[0]] = [float(v) for v in tok[2:5]]
        elif sec == "SECTIONS" and tok[0] == "4":
            sections.append(tok)
        elif sec == "OPTIONS" and len(tok) >= 2 and tok[1] in ("kBot", "cBot", "rhoInf", "dtM"):
            options.append(ln)
    if set(types) != {"bare", "buoy"} or set(points) != {"7", "8"} or not sections:
        ab.die(f"{mixed.name}: line 4 (bare/buoy lazy wave between points 7 and 8) not found")
    return {"types": types, "points": points, "sections": sections, "options": options}


def lazy_wave_deck(parts: dict, ez_a, ez_b, pretwist_a: float, pretwist_b: float, torsion: bool,
                   point_a=None) -> str:
    """The lazy-wave cable alone (line 1 between points 1 and 2), restrained in torsion."""
    # GAs, Irt and the polar inertia Irn of each section take the circular-section closure values
    # EA/(2 (1 + 0.3)), m d^2/16 and m d^2/8
    rows = []
    for name in ("bare", "buoy"):
        t = parts["types"][name]
        d, m, ea = float(t[1]), float(t[2]), float(t[3])
        rows.append(f"{name} {t[1]} {t[2]} {t[3]} {t[4]} {t[5]} {ea / 2.6:.6e} {GJ:.1e} {m * d * d / 16:.6e} "
                    f"{m * d * d / 8:.6e} {' '.join(t[6:10])}")
    pa = parts["points"]["7"] if point_a is None else point_a
    pb = parts["points"]["8"]
    out = [
        "--------------------- CableDyn Input File ------------------------------------",
        "Twisted lazy-wave power cable restrained in torsion (openfast_lin_torsion.py)",
        "--------------------- LINE TYPES ---------------------------------------------",
        "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat",
        "(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)",
        *rows,
        "--------------------- POINTS ------------------------------------------------",
        "ID Type X Y Z",
        "(-) (-) (m) (m) (m)",
        f"1 Coupled {pa[0]:.10f} {pa[1]:.10f} {pa[2]:.10f}",
        f"2 Fixed {pb[0]:.10f} {pb[1]:.10f} {pb[2]:.10f}",
        "--------------------- LINES -------------------------------------------------",
        "ID NodeA NodeB Outputs",
        "(-) (-) (-) (-)",
        "1 1 2 -",
        "--------------------- SECTIONS ----------------------------------------------",
        "LineID LineType Length NumSegs",
        "(-) (-) (m) (-)",
        *["1 " + " ".join(s[1:4]) for s in parts["sections"]],
    ]
    if torsion:
        out += [
            "--------------------- END CONNECTIONS ---------------------------------------",
            "LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist",
            "(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)",
            f"1 A Pinned {ez_a[0]:.12f} {ez_a[1]:.12f} {ez_a[2]:.12f} Rigid 0 1 0 {pretwist_a:.12f}",
            f"1 B Pinned {ez_b[0]:.12f} {ez_b[1]:.12f} {ez_b[2]:.12f} Rigid 0 1 0 {pretwist_b:.12f}",
        ]
    out += [
        "--------------------- OPTIONS -----------------------------------------------",
        *parts["options"],
        "200.0 WtrDpth - Water depth (m)",
        "none frictionMu - Seabed friction coefficient",
        "--------------------- OUTPUTS -----------------------------------------------",
        '"Point1Fx"', '"Point1Fy"', '"Point1Fz"', '"L1N1px"', '"L1N1py"', '"L1N1pz"', '"L1N2px"',
        '"L1N2py"', '"L1N2pz"',
    ]
    if torsion:
        out.append('"Torq1N1"')
    out += ["END", "--------------------- need this line ----------------------------------------", ""]
    return "\n".join(out)


def driver_solve(driver: Path, text: str, work: Path) -> dict:
    """The deck solved by the standalone driver at TMax = 0; its first output row by name."""
    work.mkdir(parents=True, exist_ok=True)
    text = text.replace("--------------------- OUTPUTS",
                        "0.0 TMax - Standalone duration (s); 0 solves the static start\n"
                        "--------------------- OUTPUTS", 1)
    (work / "trial.dat").write_text(text)
    proc = subprocess.run([str(driver), "trial.dat", "trial"], cwd=work, capture_output=True, text=True,
                          timeout=3600, check=False)
    if proc.returncode != 0:
        tail = "\n".join((proc.stdout + proc.stderr).splitlines()[-15:])
        ab.die(f"driver failed:\n{tail}")
    rows = [r for r in (work / "trial.out").read_text().splitlines() if r.strip() and not r.startswith("#")]
    head = rows[0].split()
    vals = [float(v) for v in rows[1].split()]
    return dict(zip(head, vals))


def lin_case(args: argparse.Namespace, case: Path, name: str, deck_text: str) -> dict:
    """Linearise the deck alone in the openfast_lin_ab case (its prepared CableDyn .fst)."""
    deck = case / f"CableDyn_{name}.dat"
    deck.write_text(deck_text)
    base = case / "Main_lin_cd5.fst"
    if not base.is_file():
        ab.prepare_lin_deck(case / args.ref_cd, base, 0.0, "ES24.15E3", 400.0)
    fst = case / f"Main_lin_{name}.fst"
    text = base.read_text()
    moor = ab.file_entry(text, "MooringFile", base.name)
    fst.write_text(text.replace(f'"{moor}"', f'"{deck.name}"'))
    if not args.skip_run:
        print(f"running {fst.name} ...")
        ab.run_case(args.exe, fst)
    return ab.parse_module_lin(case / f"Main_lin_{name}.1.CD.lin")


def mesh_rows(mod: dict, kinds: list[str], labels: str) -> list[int]:
    out = []
    for kind in kinds:
        idx = ab.match_indices(mod[labels], [kind])
        if len(idx) != 3:
            ab.die(f"expected 3 '{kind}' labels on the single coupled point, got {len(idx)}")
        out += idx
    return out


def reduced_6x6(mod: dict) -> tuple[np.ndarray, np.ndarray]:
    """K = -(D - C A^-1 B) and the feedthrough -D over [force; moment] x [translation; rotation]."""
    K = ab.static_impedance(mod)
    rows = mesh_rows(mod, [" force", " moment"], "y_labels")
    cols = mesh_rows(mod, ["translation displacement", "orientation angle"], "u_labels")
    return -K[np.ix_(rows, cols)], -mod["D"][np.ix_(rows, cols)]


def gate_straight(args: argparse.Namespace, case: Path) -> list[str]:
    mod = lin_case(args, case, "tors_straight", straight_deck())
    fails = []
    # torsional modes: eigenvectors on the twist states
    labels = [ab_label(s) for s in state_labels(case / "Main_lin_tors_straight.1.CD.lin", mod["n_x"])]
    tw = np.array(["twist" in s for s in labels])
    print(f"straight line: {mod['n_x']} states, {int(tw.sum())} twist")
    ev, vec = np.linalg.eig(mod["A"])
    share = np.sum(np.abs(vec[tw, :])**2, axis=0) / np.sum(np.abs(vec)**2, axis=0)
    pick = (ev.imag > 1e-9) & (share > 0.999)
    w = np.sort(np.abs(ev[pick]))
    h = L_STRAIGHT / N_STRAIGHT
    c = np.sqrt(GJ / IRN_STRAIGHT)
    worst_c = worst_d = 0.0
    leak = float(np.max(1.0 - share[pick])) if pick.any() else 1.0
    if len(w) < 3:
        ab.die(f"found {len(w)} torsional modes, expected at least 3")
    for n in (1, 2, 3):
        wc = n * np.pi / L_STRAIGHT * c
        wd = 2.0 / h * c * np.sin(n * np.pi / (2 * N_STRAIGHT))
        ec, ed = w[n - 1] / wc - 1.0, w[n - 1] / wd - 1.0
        bound = 1.2 * (n * np.pi / N_STRAIGHT) ** 2 / 24.0 + 1e-6
        print(f"  torsional mode {n}: {w[n - 1] / (2 * np.pi):.8f} Hz; continuum {wc / (2 * np.pi):.8f} "
              f"({ec:+.3e}, bound {bound:.2e}); lumped chain {wd / (2 * np.pi):.8f} ({ed:+.3e})")
        worst_c = max(worst_c, abs(ec) / bound)
        worst_d = max(worst_d, abs(ed))
    print(f"  max non-twist share of a torsional eigenvector {leak:.2e}")
    if worst_c > 1.0 or worst_d > 1e-6:
        fails.append("the torsional modes of A differ from n pi/L sqrt(GJ/Irn)")
    K, Dft = reduced_6x6(mod)
    k_zz, d_zz = K[5, 5], Dft[5, 5]
    print(f"  roll stiffness about the line axis -(D - C A^-1 B) = {k_zz:.9e} N m/rad; GJ/L = "
          f"{GJ / L_STRAIGHT:.9e} ({k_zz / (GJ / L_STRAIGHT) - 1.0:+.2e}); feedthrough -D = {d_zz:.6e} "
          f"(GJ/l_e = {GJ / h:.6e})")
    print(f"  rotational block about x, y: {K[3, 3]:.3e}, {K[4, 4]:.3e} N m/rad")
    if abs(k_zz / (GJ / L_STRAIGHT) - 1.0) > 1e-6:
        fails.append("the straight line's roll stiffness differs from GJ/L")
    return fails


def gate_straight_free(args: argparse.Namespace, case: Path) -> list[str]:
    mod = lin_case(args, case, "tors_straight_free", straight_deck("Free"))
    fails = []
    labels = [ab_label(s) for s in state_labels(case / "Main_lin_tors_straight_free.1.CD.lin", mod["n_x"])]
    tw = np.array(["twist" in s for s in labels])
    print(f"straight line free at End B: {mod['n_x']} states, {int(tw.sum())} twist")
    if int(tw.sum()) != 2 * N_STRAIGHT:
        fails.append("the free end's angle is not a state")
    ev, vec = np.linalg.eig(mod["A"])
    share = np.sum(np.abs(vec[tw, :])**2, axis=0) / np.sum(np.abs(vec)**2, axis=0)
    pick = (ev.imag > 1e-9) & (share > 0.999)
    w = np.sort(np.abs(ev[pick]))
    h = L_STRAIGHT / N_STRAIGHT
    c = np.sqrt(GJ / IRN_STRAIGHT)
    worst_c = worst_d = 0.0
    if len(w) < 3:
        ab.die(f"found {len(w)} torsional modes of the line free at End B, expected at least 3")
    for n in (1, 2, 3):
        x = (2 * n - 1) * np.pi / (4 * N_STRAIGHT)
        wc = (2 * n - 1) * np.pi / (2 * L_STRAIGHT) * c
        wd = 2.0 / h * c * np.sin(x)
        ec, ed = w[n - 1] / wc - 1.0, w[n - 1] / wd - 1.0
        bound = 1.2 * x**2 / 6.0 + 1e-6
        print(f"  torsional mode {n}: {w[n - 1] / (2 * np.pi):.8f} Hz; quarter-wave {wc / (2 * np.pi):.8f} "
              f"({ec:+.3e}, bound {bound:.2e}); clamped-free chain {wd / (2 * np.pi):.8f} ({ed:+.3e})")
        worst_c = max(worst_c, abs(ec) / bound)
        worst_d = max(worst_d, abs(ed))
    if worst_c > 1.0 or worst_d > 1e-6:
        fails.append("the torsional modes of A differ from the clamped-free ones")
    K, Dft = reduced_6x6(mod)
    print(f"  roll stiffness about the line axis -(D - C A^-1 B) = {K[5, 5]:.3e} N m/rad (GJ/L = "
          f"{GJ / L_STRAIGHT:.3e}); feedthrough -D = {Dft[5, 5]:.6e} (GJ/l_e = {GJ / h:.6e})")
    if abs(K[5, 5]) > 1e-6 * GJ / L_STRAIGHT:
        fails.append("the line free at End B has a roll stiffness")
    return fails


def state_labels(path: Path, n_x: int) -> list[str]:
    text = path.read_text().splitlines()
    out: list[str] = []
    for i, ln in enumerate(text):
        if "Order of continuous states" in ln:
            j = i + 1
            while j < len(text) and len(out) < n_x:
                row = text[j].strip()
                j += 1
                if row and row.split()[0].isdigit():
                    out.append(row)
            break
    if len(out) != n_x:
        ab.die(f"{path.name}: expected {n_x} state labels, got {len(out)}")
    return out


def ab_label(row: str) -> str:
    return row.split(None, 4)[-1]


def gate_lazy_wave(args: argparse.Namespace, case: Path) -> list[str]:
    parts = lazy_wave_parts(args.mixed_deck.resolve())
    work = case / "tors_lw_work"
    # the static end tangents of the untwisted, unrestrained cable: the bending-pinned directors
    p0 = driver_solve(args.driver, lazy_wave_deck(parts, None, None, 0.0, 0.0, False), work)
    t_a = np.array([p0["L1N2px"] - p0["L1N1px"], p0["L1N2py"] - p0["L1N1py"], p0["L1N2pz"] - p0["L1N1pz"]])
    t_a /= np.linalg.norm(t_a)
    ez_b = np.array([1.0, 0.0, 0.0])
    deck = lazy_wave_deck(parts, t_a, ez_b, 0.0, args.pretwist, True)
    mod = lin_case(args, case, "tors_lazywave", deck)
    K, _ = reduced_6x6(mod)
    d = t_a
    rows = mesh_rows(mod, [" moment"], "y_labels")
    m_op = ab.op_values(mod["y_labels"], rows)
    s0 = driver_solve(args.driver, deck, work)
    print(f"twisted lazy wave (Pretwist B {args.pretwist} deg): {mod['n_x']} states; End A director "
          f"{np.array2string(d, precision=5)}")
    print(f"  operating point: moment about d {m_op @ d:.9e} N m, static Torq1N1 {s0['Torq1N1']:.9e} N m")
    fails = []
    if abs(m_op @ d - s0["Torq1N1"]) > 1e-6 * max(abs(s0["Torq1N1"]), 1.0):
        fails.append("the operating-point moment about the End A director is not the static torque")
    # the static reference: rotation about d (Pretwist A) and translations of the coupled point
    dl = np.radians(args.dtwist)
    ref_rot = np.zeros(4)   # [F; M.d] per unit rotation about d
    sp = driver_solve(args.driver, lazy_wave_deck(parts, t_a, ez_b, args.dtwist, args.pretwist, True), work)
    sm = driver_solve(args.driver, lazy_wave_deck(parts, t_a, ez_b, -args.dtwist, args.pretwist, True), work)
    for k, c in enumerate("xyz"):
        ref_rot[k] = -(sp[f"Point1F{c}"] - sm[f"Point1F{c}"]) / (2 * dl)
    ref_rot[3] = -(sp["Torq1N1"] - sm["Torq1N1"]) / (2 * dl)
    ref_tr = np.zeros((4, 3))   # [F; M.d] per unit translation
    pa = np.array(parts["points"]["7"])
    for j in range(3):
        e = np.zeros(3)
        e[j] = args.cable_h
        sp = driver_solve(args.driver, lazy_wave_deck(parts, t_a, ez_b, 0.0, args.pretwist, True, pa + e), work)
        sm = driver_solve(args.driver, lazy_wave_deck(parts, t_a, ez_b, 0.0, args.pretwist, True, pa - e), work)
        for k, c in enumerate("xyz"):
            ref_tr[k, j] = -(sp[f"Point1F{c}"] - sm[f"Point1F{c}"]) / (2 * args.cable_h)
        ref_tr[3, j] = -(sp["Torq1N1"] - sm["Torq1N1"]) / (2 * args.cable_h)
    lin_rot = np.concatenate([K[0:3, 3:6] @ d, [d @ K[3:6, 3:6] @ d]])
    lin_tr = np.vstack([K[0:3, 0:3], d @ K[3:6, 0:3]])
    tol = args.pct / 100.0

    def compare(what: str, lin: np.ndarray, ref: np.ndarray, units: list[str]) -> tuple[float, float]:
        big = np.abs(ref).max()
        dom = allv = 0.0
        for i in range(lin.shape[0]):
            cells = []
            for j in range(lin.shape[1]):
                rel = (lin[i, j] - ref[i, j]) / ref[i, j] if abs(ref[i, j]) > 1e-2 * big else 0.0
                if abs(ref[i, j]) >= 0.1 * big:
                    dom = max(dom, abs(rel))
                if abs(ref[i, j]) >= 1e-2 * big:
                    allv = max(allv, abs(rel))
                cells.append(f"{lin[i, j]:12.6g} / {ref[i, j]:12.6g} / {rel:+.2e}")
            print(f"  {what} {units[i]}: " + " | ".join(cells))
        return dom, allv

    print("  K lin / K static / rel. diff; the moment about d per unit rotation about d (N m/rad):")
    d1, a1 = compare("rot", lin_rot[3:4, None], ref_rot[3:4, None], ["M.d"])
    print("  the force per unit translation x | y | z (N/m):")
    d2, a2 = compare("tr ", lin_tr[0:3], ref_tr[0:3], ["Fx", "Fy", "Fz"])
    print("  the moment about d per unit translation x | y | z (N m/m):")
    d3, a3 = compare("tr ", lin_tr[3:4], ref_tr[3:4], ["M.d"])
    # The force per unit rotation changes the fairlead force (1e4 N, written with 8 digits) by
    # about 1e-3 N over the rotation step, below the output resolution: it is gated against the
    # static moment per unit translation, its reciprocal (the static stiffness is symmetric), and
    # the direct static difference is only printed.
    print("  the force per unit rotation about d (N/rad) against the static moment per unit translation:")
    d4, a4 = compare("rot", lin_rot[0:3, None], ref_tr[3:4].T, ["Fx", "Fy", "Fz"])
    print("  (the static force per unit rotation, at the output resolution: "
          + ", ".join(f"{v:.4g}" for v in ref_rot[0:3]) + " N/rad)")
    dom, allv = max(d1, d2, d3, d4), max(a1, a2, a3, a4)
    print(f"  twisted lazy wave: dominant entries max rel. diff {dom:.2e} (gate {tol:.1e}); all entries "
          f">= 1% of block max {allv:.2e} (gate {2 * tol:.1e})")
    if dom > tol or allv > 2 * tol:
        fails.append("the twisted lazy wave's linearised stiffness differs from its static solutions")
    return fails


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--case-dir", type=Path, required=True)
    ap.add_argument("--driver", type=Path, required=True)
    ap.add_argument("--ref-cd", default="IEA-15-UMaine_CompMooring5_CableDyn.fst")
    ap.add_argument("--mixed-deck", type=Path,
                    default=Path(__file__).resolve().parents[2] / "examples" / "iea15mw_umaine_mixed_cabledyn.dat")
    ap.add_argument("--pretwist", type=float, default=90.0, help="End B pretwist of the lazy wave (deg)")
    ap.add_argument("--dtwist", type=float, default=0.5, help="Pretwist(A) step of the static reference (deg)")
    ap.add_argument("--cable-h", type=float, default=0.05, help="coupled-point step of the static reference (m)")
    ap.add_argument("--pct", type=float, default=1.0, help="lazy-wave tolerance in %%")
    ap.add_argument("--skip-run", action="store_true")
    args = ap.parse_args()
    if not args.driver.is_file():
        ab.die(f"driver not found: {args.driver}")
    case = args.case_dir
    fails = gate_straight(args, case) + gate_straight_free(args, case) + gate_lazy_wave(args, case)
    if fails:
        ab.die("; ".join(fails))
    print("PASS")


if __name__ == "__main__":
    main()
