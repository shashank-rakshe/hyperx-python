#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Coupled linearization A/B: CableDyn (CompMooring=5) vs stock MoorDyn (=3).

Twin still-water IEA-15MW UMaine runs, identical except for the mooring module,
each linearized once at the same time with module-level output (LinOutMod).

The script derives the linearization decks from a time-domain twin pair:
  * .fst: one linearization at --t-lin (default 0, the still-water initial
    operating point the CableDyn documentation prescribes), LinInputs =
    LinOutputs = 2, LinOutMod, and a FULL-PRECISION OutFmt (--outfmt, default
    ES24.15E3). OpenFAST writes the .lin matrices with OutFmt; the usual
    ES10.3E2 keeps 4 significant digits, which cannot resolve MoorDyn's
    D - C A^-1 B (D ~ 1e8 N/m, the result ~ 1e4 N/m) -- the cancellation
    turns the reduction into noise;
  * HydroDyn: ExctnMod = RdtnMod = NewmanApp = 0 (HydroDyn refuses to
    linearize DFT excitation, convolution radiation and Newman drift);
  * SeaState: WaveMod = 0 (still water; SeaState linearizes only still water);
  * MoorDyn deck: TmaxIC = --md-tmaxic (default 400 s) and threshIC = 1e-7,
    so the dynamic-relaxation initial state is settled, and no
    `SeaState WaterKin` row (no effect in still water).

Both modules linearize with the line dynamics: the continuous states are the
line nodes' positions and velocities (882 on this deck, in the same layout), and
the zero-frequency stiffness is the reduction K = D - C A^-1 B of each.

WHAT IS GATED
  1. CableDyn invariants of a tangent mooring stiffness at equilibrium, on its
     K (force rows vs translation-displacement columns, matched by ROW/COLUMN
     LABELS): symmetry, negative (restoring) displacement diagonals, and no net
     sway force under a collective surge of this y-symmetric spread.
  2. The reference itself: MoorDyn's zero-frequency reduction
     K_md = D - C A^-1 B must be symmetric (<= 1e-3) and its .lin matrices
     must carry >= 10 significant digits; otherwise the comparison is refused
     with a named error (the usual cause is a low-precision OutFmt).
  3. CableDyn against MoorDyn, entry by entry:
       * per-fairlead 3x3 stiffness blocks: entries >= 10 % of the block's
         largest within --gate-pct (default 0.5 %), every entry >= 1 % of it
         within 2 x --gate-pct; cross-fairlead entries ~0 in both;
       * the 6x6 platform stiffness about the global origin (rigid platform
         motion of the fairleads plus the geometric term of each code's own
         operating-point fairlead loads): diagonals within --gate-pct, every
         entry within --gate-pct of sqrt(K_ii K_jj).
     Measured on this model (OutFmt ES24.15E3, TmaxIC 400 s, t = 0): the
     fairlead entries agree to 0.10 % (the small transverse entry to 0.29 %),
     the 6x6 diagonals to <= 0.10 % and every 6x6 entry to 1.1e-3 of
     sqrt(K_ii K_jj) or better.
  4. The dynamics: both state matrices stable (every eigenvalue in the left
     half-plane), and the lowest --n-modes line-mode frequencies of CableDyn's
     A within --freq-pct (default 1 %) of MoorDyn's. Measured: 0.04-0.07 % on
     the first three modes, 0.3 % on the ninth (CableDyn's consistent mass
     against MoorDyn's lumped mass). The damping ratios are printed, not gated: the
     quadratic drag has no slope at rest, so both codes difference it over the
     same +-0.1 m/s velocity step, and CableDyn's drag, integrated over the
     element rather than lumped at the node, gives half the slope for a one-node
     perturbation.
  5. With --cable-deck and --driver (optional): every coupled point of a mixed
     deck (EI = 0 lines and finite-EI cables) against the deck's own static
     solution. The deck is linearized in the same OpenFAST case (seabed
     friction off: a stuck laid run is a different static problem), and the
     standalone driver solves it at TMax = 0 with one coupled point moved
     +-h (--cable-h, default 0.05 m) along each axis; -dF/dx of those solves is
     the reference. Per-point 3x3 entries >= 10 % of the block's largest within
     --cable-pct (default 1 %), every entry >= 1 % of it within twice that.
     Measured on examples/iea15mw_umaine_mixed_cabledyn.dat: the lazy-wave
     cable's 36.0 / 2.62 / 38.5 N/m within 3.3e-4, the chains within 7e-5.

The 6x6 is the module-level stiffness. A full-system ElastoDyn linearization
additionally contains a term of ElastoDyn/glue origin proportional to the
static vertical platform load (identical for both modules; see VALIDATION.md).

Case directory: the twin pair examples/openfast/IEA-15-UMaine_CompMooring5_CableDyn.fst
and IEA-15-UMaine_CompMooring3_MoorDyn.fst (the --ref-cd/--ref-md defaults)
with their mooring decks CableDyn_UMaine.dat and MoorDyn_UMaine.dat, plus the
files they reference that are not in the repository: the ElastoDyn (with its
tower and blade files), HydroDyn and SeaState inputs and the WAMIT HydroData
folder of OpenFAST r-test glue-codes/fast-farm/MD_Shared (turbine 1, with the
pose reset to zero as described in examples/openfast/README.md). The script
writes its Main_lin_* decks and *_lin input copies into that directory.

Fail-closed: missing .lin files, unparseable sections, empty matched blocks
(e.g. a module whose coupled-mesh inputs did not enter the linearization set),
mismatched fairlead geometry between the two decks, and non-finite entries all
abort with a named error.

Usage:
    python validation/scripts/openfast_lin_ab.py --exe <openfast.exe> --case-dir <dir>
        [--ref-cd IEA-15-UMaine_CompMooring5_CableDyn.fst]
        [--ref-md IEA-15-UMaine_CompMooring3_MoorDyn.fst]
        [--t-lin 0.0] [--gate-pct 0.5] [--outfmt ES24.15E3] [--md-tmaxic 400]
        [--n-modes 9] [--freq-pct 1.0]
        [--cable-deck <mixed deck> --driver <cabledyn driver> [--cable-h 0.05] [--cable-pct 1.0]]
        [--skip-run]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

LIN_BLOCK = re.compile(r"^-+\s*LINEARIZATION\s*-+", re.IGNORECASE)
MIN_DIGITS = 10   # significant digits the .lin matrices must carry for the MoorDyn reduction


def die(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def swap_keys(src: Path, dst: Path, swaps: dict[str, str], required: bool, what: str,
              drop: re.Pattern | None = None) -> set[str]:
    """Copy a value-first OpenFAST input file, replacing the value field of the
    named keys. The key is the LAST word before ' - ' (LinTimes carries a
    comma-separated value list). Lines matching `drop` are left out."""
    lines = src.read_text().splitlines(keepends=True)
    out: list[str] = []
    seen: set[str] = set()
    for ln in lines:
        if drop is not None and drop.match(ln):
            continue
        m = re.match(r"^\s*[^-\s].*?(\w+)\s+-\s", ln)
        key = m.group(1) if m else None
        if key in swaps:
            rest = ln[ln.index(key):]
            out.append(f"{swaps[key]:<22} {rest}")
            seen.add(key)
        else:
            out.append(ln)
    missing = set(swaps) - seen
    if required and missing:
        die(f"{src.name}: {what} keys not found: {sorted(missing)}")
    dst.write_text("".join(out))
    return seen


def file_entry(text: str, key: str, where: str) -> str:
    m = re.search(rf'"([^"]+)"\s+{key}\b', text)
    if not m:
        die(f"{where}: {key} entry not found")
    return m.group(1)


def derive(dst_fst: Path, text: str, key: str, suffix: str, swaps: dict[str, str],
           need: set[str], what: str, drop: re.Pattern | None = None) -> str:
    """Write a modified copy of the input file the .fst names under `key` and
    point the .fst text at it."""
    name = file_entry(text, key, dst_fst.name)
    src = (dst_fst.parent / name).resolve()
    if not src.is_file():
        die(f"{dst_fst.name}: {key} file not found: {src}")
    dst = dst_fst.parent / (src.stem + suffix + src.suffix)
    seen = swap_keys(src, dst, swaps, required=False, what=what, drop=drop)
    if need and not need & seen:
        die(f"{src.name}: none of {sorted(need)} found -- cannot make the {what} deck")
    return text.replace(f'"{name}"', f'"{dst.name}"')


def prepare_lin_deck(src: Path, dst: Path, t_lin: float, outfmt: str, md_tmaxic: float) -> None:
    """Copy an .fst deck, enabling one linearization snapshot at t_lin, and derive
    linearization-compatible HydroDyn/SeaState twins (and, for MoorDyn, a settled
    initial-condition deck)."""
    if not src.is_file():
        die(f"reference deck not found: {src}")
    swap_keys(src, dst, {
        "TMax": f"{max(t_lin, 0.1):.6f}",
        "OutFmt": f'"{outfmt}"',
        "Linearize": "True",
        "CalcSteady": "False",
        "NLinTimes": "1",
        "LinTimes": f"{t_lin:.6f}",
        # 2 = ALL module inputs/outputs: under the "standard" set (1) neither
        # mooring module's coupled MESH enters the linearization set (measured:
        # n_u = 0 for stock MoorDyn too), and the impedance needs the mesh columns.
        "LinInputs": "2",
        "LinOutputs": "2",
        "LinOutJac": "False",
        "LinOutMod": "True",
    }, required=True, what="linearization")

    text = dst.read_text()
    text = derive(dst, text, "HydroFile", "_lin",
                  {"ExctnMod": "0", "RdtnMod": "0", "NewmanApp": "0"},
                  {"ExctnMod", "RdtnMod"}, "HydroDyn linearization")
    if re.search(r'^\s*1\s+CompSeaSt\b', text, re.M):
        text = derive(dst, text, "SeaStFile", "_lin", {"WaveMod": "0"}, {"WaveMod"},
                      "SeaState still-water")
    if re.search(r'^\s*3\s+CompMooring\b', text, re.M):
        text = derive(dst, text, "MooringFile", "_lin",
                      {"TmaxIC": f"{md_tmaxic:.1f}", "threshIC": "1.0e-7"}, {"TmaxIC"},
                      "MoorDyn settled-IC", drop=re.compile(r"^\s*SeaState\s+WaterKin\b", re.I))
    dst.write_text(text)


def run_case(exe: Path, fst: Path) -> None:
    proc = subprocess.run(
        [str(exe), str(fst.name)],
        cwd=fst.parent,
        capture_output=True,
        text=True,
        timeout=3600,
    )
    if proc.returncode != 0:
        tail = "\n".join((proc.stdout + proc.stderr).splitlines()[-25:])
        die(f"openfast failed on {fst.name} (rc={proc.returncode}):\n{tail}")


def coupled_points(fst: Path) -> np.ndarray:
    """Coordinates of the Coupled/Vessel points of the mooring deck named by the .fst,
    in deck order (the order of the coupled-mesh nodes in both modules)."""
    text = fst.read_text()
    deck = (fst.parent / file_entry(text, "MooringFile", fst.name)).resolve()
    if not deck.is_file():
        die(f"{fst.name}: MooringFile not found: {deck}")
    pts: list[list[float]] = []
    in_points = False
    for ln in deck.read_text().splitlines():
        if ln.lstrip().startswith("-"):
            in_points = "POINTS" in ln.upper() or "CONNECTION" in ln.upper()
            continue
        tok = ln.split()
        if in_points and len(tok) >= 5 and tok[0].isdigit() and \
                tok[1].lower() in ("coupled", "vessel", "cpld", "ves"):
            pts.append([float(v) for v in tok[2:5]])
    if not pts:
        die(f"{deck.name}: no Coupled/Vessel points found in the POINTS section")
    return np.array(pts)


def parse_module_lin(path: Path) -> dict:
    """Parse an OpenFAST module .lin file: sizes, labels, operating points, A/B/C/D."""
    if not path.is_file():
        die(f"missing linearization file: {path}")
    text = path.read_text().splitlines()

    def read_int(pattern: str) -> int:
        for ln in text:
            m = re.search(pattern, ln)
            if m:
                return int(m.group(1))
        return 0

    n_x = read_int(r"Number of continuous states:\s*(\d+)")
    n_u = read_int(r"Number of inputs:\s*(\d+)")
    n_y = read_int(r"Number of outputs:\s*(\d+)")

    def read_labels(header: str, count: int) -> list[str]:
        # Layout: the header line, a column-title row, a dashes underline row, then
        # one entry per row starting with its integer index. Take ONLY rows whose
        # first token is an integer -- a positional skip miscounts (measured: the
        # dashes row became label 1 and every row/column selection shifted by one,
        # silently extracting a shifted block from a CORRECT matrix).
        labels: list[str] = []
        for i, ln in enumerate(text):
            if header in ln:
                j = i + 1
                while j < len(text) and len(labels) < count:
                    row = text[j].strip()
                    j += 1
                    if not row:
                        continue
                    tok = row.split()[0]
                    if not tok.lstrip("+-").isdigit():
                        continue
                    labels.append(row)
                break
        if len(labels) != count:
            die(f"{path.name}: expected {count} labels under '{header}', got {len(labels)}")
        return labels

    u_labels = read_labels("Order of inputs", n_u) if n_u else []
    y_labels = read_labels("Order of outputs", n_y) if n_y else []
    digits = [99]

    def read_matrix(name: str, rows: int, cols: int) -> np.ndarray:
        if rows == 0 or cols == 0:
            return np.zeros((rows, cols))
        pat = re.compile(rf"^{name}:\s*\d+\s*x\s*\d+")
        for i, ln in enumerate(text):
            if pat.match(ln.strip()):
                # Wide rows WRAP across physical lines in .lin files: accumulate
                # exactly rows*cols floats (never count physical lines), stopping
                # on the first non-numeric token (the next section header).
                flat: list[float] = []
                j = i + 1
                while j < len(text) and len(flat) < rows * cols:
                    toks = text[j].split()
                    j += 1
                    if not toks:
                        continue
                    try:
                        flat.extend(float(v) for v in toks)
                    except ValueError:
                        break
                    if len(flat) == len(toks):   # first data row: mantissa digits
                        mant = toks[0].lstrip("+-").upper().split("E")[0].replace(".", "")
                        digits[0] = min(digits[0], len(mant))
                if len(flat) != rows * cols:
                    die(f"{path.name}: {name} yielded {len(flat)} values, expected {rows * cols}")
                mat = np.array(flat).reshape(rows, cols)
                if not np.all(np.isfinite(mat)):
                    die(f"{path.name}: {name} contains non-finite entries")
                return mat
        die(f"{path.name}: matrix {name} ({rows}x{cols}) not found")
        raise AssertionError

    mats = {
        "A": read_matrix("A", n_x, n_x),
        "B": read_matrix("B", n_x, n_u),
        "C": read_matrix("C", n_y, n_x),
        "D": read_matrix("D", n_y, n_u),
    }
    return {"n_x": n_x, "u_labels": u_labels, "y_labels": y_labels, "digits": digits[0], **mats}


def match_indices(labels: list[str], must: list[str]) -> list[int]:
    idx = [i for i, s in enumerate(labels) if all(m.lower() in s.lower() for m in must)]
    return idx


def op_values(labels: list[str], idx: list[int]) -> np.ndarray:
    """Operating-point column (second token) of the selected label rows."""
    return np.array([float(labels[i].split()[1].rstrip(",")) for i in idx])


def static_impedance(mod: dict) -> np.ndarray:
    """K = D - C A^+ B (reduces to D when the module carries no states).

    A^+ is the pseudo-inverse only when A is singular to working precision (cond >
    1e14): a mooring on a FRICTIONLESS seabed can have neutral horizontal modes on
    its grounded nodes (zero restoring force). The minimum-norm solution projects
    the neutral modes out -- they stay put under a static boundary displacement,
    which is exactly the quasi-static physics. A merely ill-conditioned A is solved
    plainly: the soft lateral modes of a long laid cable are physical, and
    truncating them corrupts every subsystem's reduction. On the settled UMaine
    deck A is regular (the seabed penalty and line tension restrain every node)."""
    if mod["n_x"] == 0:
        return mod["D"]
    A = mod["A"]
    sv = np.linalg.svd(A, compute_uv=False)
    cond = sv[0] / max(sv[-1], 1e-300)
    print(f"state matrix: {A.shape[0]} states, cond ~ {cond:.2e}")
    if cond > 1e14:
        print("note: neutral modes; using the pseudo-inverse zero-frequency reduction")
        X = np.linalg.lstsq(A, mod["B"], rcond=1e-12)[0]
    else:
        X = np.linalg.solve(A, mod["B"])
    return mod["D"] - mod["C"] @ X


def line_modes(A: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    """Natural frequencies (Hz) and damping ratios of the oscillatory modes of a
    state matrix, ascending in frequency, and its largest eigenvalue real part."""
    ev = np.linalg.eigvals(A)
    osc = ev[ev.imag > 1e-9 * max(np.abs(ev).max(), 1.0)]
    wn = np.abs(osc)
    order = np.argsort(wn)
    return wn[order] / (2.0 * np.pi), -osc.real[order] / wn[order], float(ev.real.max())


def deck_points(deck: Path) -> list[tuple[int, str, list[float], int]]:
    """(id, type, xyz, line index) of every row of a deck's POINTS section."""
    out = []
    in_points = False
    for k, ln in enumerate(deck.read_text().splitlines()):
        if ln.lstrip().startswith("-"):
            in_points = "POINTS" in ln.upper()
            continue
        tok = ln.split()
        if in_points and len(tok) >= 5 and tok[0].isdigit():
            out.append((int(tok[0]), tok[1].lower(), [float(v) for v in tok[2:5]], k))
    return out


def driver_point_loads(driver: Path, deck: Path, work: Path, pid: int, xyz: list[float],
                       coupled: list[int]) -> np.ndarray:
    """The static loads Point<P>F{x,y,z} on every coupled point with point pid moved
    to xyz: the deck solved by the standalone driver at TMax = 0."""
    lines = deck.read_text().splitlines()
    row = {p[0]: p[3] for p in deck_points(deck)}[pid]
    tok = lines[row].split()
    lines[row] = "  ".join(tok[:2] + [f"{v:.10f}" for v in xyz] + tok[5:])
    out: list[str] = []
    in_outputs = False
    has_tmax = any(re.match(r"^\s*\S+\s+TMax\b", ln) for ln in lines)
    for ln in lines:
        up = ln.strip().upper()
        if ln.lstrip().startswith("-") and "OUTPUTS" in up:
            if not has_tmax:
                # a coupled deck leaves TMax to the host: the static start alone
                out.append("0.0      TMax      - Standalone duration (s); 0 solves the static start")
            in_outputs = True
            out.append(ln)
            out.extend(f'"Point{p}F{c}"' for p in coupled for c in "xyz")
            continue
        if in_outputs:
            if up.startswith("END"):
                in_outputs = False
                out.append(ln)
            continue
        if re.match(r"^\s*\S+\s+TMax\b", ln):
            ln = re.sub(r"^\s*\S+", "0.0", ln, count=1)
        out.append(ln)
    work.mkdir(parents=True, exist_ok=True)
    (work / "trial.dat").write_text("\n".join(out) + "\n")
    proc = subprocess.run([str(driver), "trial.dat", "trial"], cwd=work, capture_output=True,
                          text=True, timeout=3600)
    if proc.returncode != 0:
        tail = "\n".join((proc.stdout + proc.stderr).splitlines()[-15:])
        die(f"driver failed on {deck.name} with point {pid} at {xyz}:\n{tail}")
    rows = [r for r in (work / "trial.out").read_text().splitlines() if r.strip() and not r.startswith("#")]
    head = rows[0].split()
    vals = [float(v) for v in rows[1].split()]
    return np.array([[vals[head.index(f"Point{p}F{c}")] for c in "xyz"] for p in coupled])


def cable_gate(args: argparse.Namespace, case: Path, cd_fst: Path) -> list[str]:
    """Gate 5: a mixed deck's coupled-point stiffness against its static solution."""
    src = args.cable_deck.resolve()
    if not src.is_file():
        die(f"cable deck not found: {src}")
    if not args.driver.is_file():
        die(f"driver not found: {args.driver}")
    deck = case / "CableDyn_cable_lin.dat"
    text, n_mu = re.subn(r"^(\s*)\S+(\s+frictionMu\b)", r"\1none\2", src.read_text(), flags=re.M)
    deck.write_text(text)
    fst = case / "Main_lin_cable.fst"
    fst_text = cd_fst.read_text()
    name = file_entry(fst_text, "MooringFile", cd_fst.name)
    fst.write_text(fst_text.replace(f'"{name}"', f'"{deck.name}"'))
    if not args.skip_run:
        print(f"running {fst.name} ...")
        run_case(args.exe, fst)
    mod = parse_module_lin(case / "Main_lin_cable.1.CD.lin")
    kb, _ = block(mod, -static_impedance(mod), ["force"], ["translation displacement"],
                  "cable-deck stiffness")
    pts = [p for p in deck_points(deck) if p[1] in ("coupled", "vessel", "cpld", "ves")]
    ids = [p[0] for p in pts]
    if kb.shape != (3 * len(ids), 3 * len(ids)):
        die(f"cable-deck stiffness block {kb.shape} does not match {len(ids)} coupled points")
    h = args.cable_h
    tol = args.cable_pct / 100.0
    worst_dom = worst_all = 0.0
    print(f"cable deck {src.name} (frictionMu rows set to none: {n_mu}), coupled points {ids}, "
          f"static reference from +-{h} m driver solves; K lin / K static / rel. diff (N/m):")
    for ip, (pid, _, xyz, _) in enumerate(pts):
        kref = np.zeros((3, 3))
        for k in range(3):
            xp, xm = list(xyz), list(xyz)
            xp[k] += h
            xm[k] -= h
            fp = driver_point_loads(args.driver, deck, case / "cable_lin_work", pid, xp, ids)
            fm = driver_point_loads(args.driver, deck, case / "cable_lin_work", pid, xm, ids)
            kref[:, k] = -(fp[ip] - fm[ip]) / (2.0 * h)
        b = kb[3 * ip:3 * ip + 3, 3 * ip:3 * ip + 3]
        big = np.abs(kref).max()
        for i in range(3):
            cells = []
            for j in range(3):
                rel = (b[i, j] - kref[i, j]) / kref[i, j] if abs(kref[i, j]) > 1e-2 * big else 0.0
                if abs(kref[i, j]) >= 0.1 * big:
                    worst_dom = max(worst_dom, abs(rel))
                if abs(kref[i, j]) >= 1e-2 * big:
                    worst_all = max(worst_all, abs(rel))
                cells.append(f"{b[i, j]:11.5g} / {kref[i, j]:11.5g} / {rel:+.2e}")
            print(f"  point {pid} {'xyz'[i]}: " + " | ".join(cells))
    print(f"cable deck: dominant entries max rel. diff {worst_dom:.2e} (gate {tol:.1e}); "
          f"all entries >= 1% of block max {worst_all:.2e} (gate {2 * tol:.1e})")
    if worst_dom > tol or worst_all > 2 * tol:
        return ["the cable deck's linearized point stiffness differs from its static solution"]
    return []


def block(mod: dict, K: np.ndarray, row_must: list[str], col_must: list[str], what: str) -> tuple:
    rows = match_indices(mod["y_labels"], row_must)
    cols = match_indices(mod["u_labels"], col_must)
    if not rows or not cols:
        die(f"{what}: no labels matched rows={row_must} ({len(rows)}) cols={col_must} ({len(cols)}) "
            f"-- the module's coupled mesh did not enter the linearization set")
    return K[np.ix_(rows, cols)], rows


def skew(v: np.ndarray) -> np.ndarray:
    return np.array([[0.0, -v[2], v[1]], [v[2], 0.0, -v[0]], [-v[1], v[0], 0.0]])


def platform_stiffness(K: np.ndarray, r: np.ndarray, F0: np.ndarray) -> np.ndarray:
    """6x6 stiffness -d[F; M]/d[u; theta] about the global origin for a rigid motion
    of the fairleads (d_i = u + theta x r_i), from the nodal stiffness K = -dF/dx and
    the operating-point fairlead loads F0 (load on the platform): the moment
    linearisation adds the geometric term (theta x r_i) x F_i."""
    n = r.shape[0]
    T = np.zeros((3 * n, 6))
    for i in range(n):
        T[3 * i:3 * i + 3, 0:3] = np.eye(3)
        T[3 * i:3 * i + 3, 3:6] = -skew(r[i])
    dF = -K @ T
    L = np.zeros((6, 6))
    for i in range(n):
        L[0:3] += dF[3 * i:3 * i + 3]
        L[3:6] += skew(r[i]) @ dF[3 * i:3 * i + 3]
        L[3:6, 3:6] += skew(F0[i]) @ skew(r[i])
    return -L


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--case-dir", type=Path, required=True)
    ap.add_argument("--ref-cd", default="IEA-15-UMaine_CompMooring5_CableDyn.fst")
    ap.add_argument("--ref-md", default="IEA-15-UMaine_CompMooring3_MoorDyn.fst")
    ap.add_argument("--t-lin", type=float, default=0.0)
    ap.add_argument("--gate-pct", type=float, default=0.5,
                    help="CableDyn vs MoorDyn tolerance in %% (see the module docstring)")
    ap.add_argument("--outfmt", default="ES24.15E3",
                    help="OutFmt written into both decks; the .lin matrices use it")
    ap.add_argument("--md-tmaxic", type=float, default=400.0,
                    help="MoorDyn dynamic-relaxation time TmaxIC (s)")
    ap.add_argument("--n-modes", type=int, default=9,
                    help="lowest line modes whose frequencies are gated")
    ap.add_argument("--freq-pct", type=float, default=1.0,
                    help="CableDyn vs MoorDyn line-mode frequency tolerance in %%")
    ap.add_argument("--cable-deck", type=Path,
                    help="a mixed EI = 0 + finite-EI deck for gate 5 (needs --driver)")
    ap.add_argument("--driver", type=Path, help="the standalone CableDyn driver (gate 5)")
    ap.add_argument("--cable-h", type=float, default=0.05,
                    help="coupled-point displacement of the gate-5 static solves (m)")
    ap.add_argument("--cable-pct", type=float, default=1.0, help="gate-5 tolerance in %%")
    ap.add_argument("--skip-run", action="store_true")
    args = ap.parse_args()
    if (args.cable_deck is None) != (args.driver is None):
        die("--cable-deck and --driver go together")

    case = args.case_dir
    cd_fst = case / "Main_lin_cd5.fst"
    md_fst = case / "Main_lin_md3.fst"
    prepare_lin_deck(case / args.ref_cd, cd_fst, args.t_lin, args.outfmt, args.md_tmaxic)
    prepare_lin_deck(case / args.ref_md, md_fst, args.t_lin, args.outfmt, args.md_tmaxic)

    if not args.skip_run:
        for fst in (cd_fst, md_fst):
            print(f"running {fst.name} ...")
            run_case(args.exe, fst)

    cd = parse_module_lin(case / "Main_lin_cd5.1.CD.lin")
    md = parse_module_lin(case / "Main_lin_md3.1.MD.lin")
    print(f"CD: n_x={cd['n_x']} n_u={len(cd['u_labels'])} n_y={len(cd['y_labels'])}")
    print(f"MD: n_x={md['n_x']} n_u={len(md['u_labels'])} n_y={len(md['y_labels'])}")
    if cd["n_x"] == 0:
        die("CableDyn module reported no continuous states under linearization "
            "(the line positions and velocities must be states)")

    r_cd = coupled_points(cd_fst)
    r_md = coupled_points(md_fst)
    if r_cd.shape != r_md.shape or np.abs(r_cd - r_md).max() > 1e-6:
        die(f"the two mooring decks have different Coupled/Vessel fairleads:\nCD {r_cd}\nMD {r_md}")

    K_cd = static_impedance(cd)
    K_md = static_impedance(md)

    # 1. CableDyn's quasi-static stiffness invariants.
    kb_cd, rows_cd = block(cd, K_cd, ["force"], ["translation displacement"], "CD stiffness")
    n = kb_cd.shape[0]
    if n != 3 * r_cd.shape[0] or kb_cd.shape[1] != n:
        die(f"CD stiffness block {kb_cd.shape} does not match {r_cd.shape[0]} coupled fairleads")
    sym = np.linalg.norm(kb_cd - kb_cd.T) / max(np.linalg.norm(kb_cd), 1e-30)
    print(f"CD stiffness block {kb_cd.shape}: symmetry |K-K^T|/|K| = {sym:.2e} (gate 1e-3)")
    diag = np.diag(kb_cd)
    print(f"CD displacement diagonals: min {diag.min():.4g}, max {diag.max():.4g} N/m (gate: all < 0)")
    e = np.zeros(n)
    e[0::3] = 1.0  # collective +x on every fairlead
    fx = float(kb_cd[0::3, :] @ e @ np.ones(n // 3))
    fy = float(kb_cd[1::3, :] @ e @ np.ones(n // 3))
    print(f"CD collective surge stiffness: dFx = {fx:.5g} N/m, net sway leak |dFy/dFx| = "
          f"{abs(fy) / max(abs(fx), 1e-30):.2e} (gate 1e-2 on this y-symmetric spread)")
    failures: list[str] = []
    if not (sym <= 1e-3 and bool(np.all(diag < 0.0)) and abs(fy) <= 1e-2 * abs(fx)):
        failures.append("CD stiffness block violates the quasi-static invariants")

    # 2. The reference: MoorDyn's zero-frequency reduction on the same block.
    kb_md, rows_md = block(md, K_md, ["force"], ["translation displacement"], "MD stiffness")
    if kb_md.shape != kb_cd.shape:
        die(f"MD stiffness block {kb_md.shape} differs from CD {kb_cd.shape}")
    sym_md = np.linalg.norm(kb_md - kb_md.T) / max(np.linalg.norm(kb_md), 1e-30)
    print(f"MD reference: .lin digits {md['digits']} (gate >= {MIN_DIGITS}), "
          f"symmetry |K-K^T|/|K| = {sym_md:.2e} (gate 1e-3)")
    if md["digits"] < MIN_DIGITS or sym_md > 1e-3:
        failures.append(f"MoorDyn reference unusable (digits {md['digits']}, asymmetry {sym_md:.2e}): "
                        f"write the .lin files with a full-precision OutFmt (e.g. ES24.15E3) and "
                        f"settle the MoorDyn initial condition (TmaxIC)")

    # 3. CableDyn vs MoorDyn, entry by entry.
    F0_cd = op_values(cd["y_labels"], rows_cd).reshape(-1, 3)
    F0_md = op_values(md["y_labels"], rows_md).reshape(-1, 3)
    dF0 = np.abs(F0_cd - F0_md).max() / np.abs(F0_md).max()
    print(f"operating-point fairlead loads: max |CD-MD| / max|F| = {dF0:.2e} (gate 1e-2)")
    if dF0 > 1e-2:
        failures.append("the two operating points differ (fairlead loads)")
    K = -kb_cd    # stiffness = -dF/dx
    Kr = -kb_md
    tol = args.gate_pct / 100.0
    worst_dom, worst_all, worst_x = 0.0, 0.0, 0.0
    print("per-fairlead 3x3 blocks (K = -dF/dx, N/m), CD / MD / rel. diff:")
    for p in range(n // 3):
        s = slice(3 * p, 3 * p + 3)
        b, br = K[s, s], Kr[s, s]
        big = np.abs(br).max()
        for i in range(3):
            row = []
            for j in range(3):
                rel = (b[i, j] - br[i, j]) / br[i, j] if abs(br[i, j]) > 1e-2 * big else 0.0
                if abs(br[i, j]) >= 0.1 * big:
                    worst_dom = max(worst_dom, abs(rel))
                if abs(br[i, j]) >= 1e-2 * big:
                    worst_all = max(worst_all, abs(rel))
                row.append(f"{b[i, j]:11.5g} / {br[i, j]:11.5g} / {rel:+.2e}")
            print(f"  fairlead {p + 1} {'xyz'[i]}: " + " | ".join(row))
        for q in range(n // 3):
            if q != p:
                t = slice(3 * q, 3 * q + 3)
                worst_x = max(worst_x, float(np.abs(K[s, t]).max() + np.abs(Kr[s, t]).max()) / big)
    print(f"fairlead blocks: dominant entries max rel. diff {worst_dom:.2e} (gate {tol:.1e}); "
          f"all entries >= 1% of block max {worst_all:.2e} (gate {2 * tol:.1e}); "
          f"cross-fairlead / block max {worst_x:.1e} (gate 1e-6)")
    if worst_dom > tol or worst_all > 2 * tol or worst_x > 1e-6:
        failures.append("per-fairlead stiffness differs from MoorDyn beyond the gate")

    K6 = platform_stiffness(K, r_cd, F0_cd)
    K6r = platform_stiffness(Kr, r_md, F0_md)
    dofs = ["Surge", "Sway", "Heave", "Roll", "Pitch", "Yaw"]
    print("platform 6x6 stiffness about the origin, diagonal (CD / MD / rel. diff):")
    rel_d = np.diag(K6) / np.diag(K6r) - 1.0
    for i in range(6):
        print(f"  {dofs[i]:5s} {K6[i, i]:13.6e} / {K6r[i, i]:13.6e} / {rel_d[i]:+.2e}")
    norm = np.abs(K6 - K6r) / np.sqrt(np.abs(np.outer(np.diag(K6r), np.diag(K6r))))
    i, j = np.unravel_index(int(norm.argmax()), norm.shape)
    print(f"  surge-pitch {K6[0, 4]:.6e} / {K6r[0, 4]:.6e}, sway-roll {K6[1, 3]:.6e} / {K6r[1, 3]:.6e}")
    print(f"6x6: max |diag rel. diff| {np.abs(rel_d).max():.2e} (gate {tol:.1e}); "
          f"max |dK_ij|/sqrt(K_ii K_jj) {norm.max():.2e} at ({dofs[i]},{dofs[j]}) (gate {tol:.1e})")
    if np.abs(rel_d).max() > tol or norm.max() > tol:
        failures.append("platform 6x6 stiffness differs from MoorDyn beyond the gate")

    # 4. The dynamics: stability and the lowest line-mode frequencies.
    f_cd, z_cd, re_cd = line_modes(cd["A"])
    f_md, z_md, re_md = line_modes(md["A"])
    nm = args.n_modes
    if len(f_cd) < nm or len(f_md) < nm:
        die(f"fewer than {nm} oscillatory modes (CD {len(f_cd)}, MD {len(f_md)})")
    rel_f = f_cd[:nm] / f_md[:nm] - 1.0
    print(f"state matrices: max Re(lambda) CD {re_cd:.3e}, MD {re_md:.3e} (gate < 0)")
    print(f"lowest {nm} line modes, f [Hz] CD / MD / rel. diff, damping ratio CD / MD (not gated):")
    for i in range(nm):
        print(f"  {i + 1:2d}  {f_cd[i]:.6f} / {f_md[i]:.6f} / {rel_f[i]:+.2e}   {z_cd[i]:.4f} / {z_md[i]:.4f}")
    print(f"line modes: max |rel. diff| {np.abs(rel_f).max():.2e} (gate {args.freq_pct / 100.0:.1e})")
    if not (re_cd < 0.0 and re_md < 0.0):
        failures.append("a state matrix has an eigenvalue in the right half-plane")
    if np.abs(rel_f).max() > args.freq_pct / 100.0:
        failures.append("the line-mode frequencies differ from MoorDyn beyond the gate")

    # 5. Optional: a mixed deck's coupled points against its own static solution.
    if args.cable_deck is not None:
        failures += cable_gate(args, case, cd_fst)

    if failures:
        die("; ".join(failures))
    print("PASS")


if __name__ == "__main__":
    main()
