# File: validation/scripts/bodies_run_moordyn_c.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the MoorDyn-C references of the bodies validation suite.

For every case in ``validation/bodies/cases.json`` with a ``moordyn_c`` reference, the deck is
run at each ``dt_levels`` time step with the scheme given there (rk4), the scored channels of
each level are compared with the finest level, and the finest level is stored as
``references/<ID>/moordyn_c.csv[.gz]`` with a provenance JSON holding the convergence record.
Static references (``moordyn_c_static*``) are MoorDyn-C's own dynamic-relaxation equilibrium
(threshIC as in the deck) read at t = 0. Releases with ``settle`` start from MoorDyn-C's own
line equilibrium about the held bodies (runner ``--settle``), not from the NoIC catenary seed.

Run:  python validation/scripts/bodies_run_moordyn_c.py [CASE_ID ...]
Environment: CD_MDC_SRC (MoorDyn source tree), CD_MDC_BUILD (its CMake build tree),
CD_BODIES_WORK (scratch directory), CD_GXX (g++ used to build the runner).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np
from pathlib import Path

from bodies_common import BODIES, CASES, GXX, WORK, mdc_runner, mdc_version, read_series, write_reference
from bodies_metrics import e_rms

KEEP = re.compile(r"^(Time|Body\d+(P[xyz]|R[xyz])|Rod\d+(N\d+)?P[xyz]|Point\d+[PF][xyz]|Ten[AB]\d+)$")


def run(case_id: str, deck: str, out_name: str, tmax: float, dtout: float, *, noic: bool,
        scheme: str | None = None, dtm: float | None = None, motion: str | None = None,
        cdt: float | None = None, settle: float | None = None) -> tuple[list[str], np.ndarray, dict]:
    exe = mdc_runner()
    wdir = WORK / case_id
    wdir.mkdir(parents=True, exist_ok=True)
    for f in (CASES / case_id).iterdir():
        if f.is_file():
            shutil.copy2(f, wdir / f.name)
    cmd = [str(exe), deck, out_name, "--tmax", repr(tmax), "--dtout", repr(dtout)]
    if noic:
        cmd.append("--noic")
    if scheme:
        cmd += ["--scheme", scheme]
    if dtm:
        cmd += ["--dtm", repr(dtm)]
    if motion:
        cmd += ["--motion", motion]
    if cdt:
        cmd += ["--cdt", repr(cdt)]
    if settle:
        cmd += ["--settle", repr(settle)]
    t0 = time.perf_counter()
    env = dict(os.environ)
    # the runner must resolve the MinGW runtime it was built with, not a conda one on PATH
    env["PATH"] = os.pathsep.join([str(WORK), str(Path(GXX).parent), env.get("PATH", "")])
    p = subprocess.run(cmd, cwd=wdir, capture_output=True, text=True, env=env)
    wall = time.perf_counter() - t0
    if p.returncode:
        raise RuntimeError(f"{case_id}: MoorDyn-C failed ({p.returncode})\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}")
    timing = json.loads(p.stderr.strip().splitlines()[-1])
    timing["wall_s"] = wall
    cols, data = read_series(wdir / out_name)
    return cols, data, timing


def scored_channels(spec: dict, code: str) -> list[str]:
    chans = []
    for m in spec["metrics"]:
        if m.get("ref_code") == code and isinstance(m.get("ref"), str) and not m["ref"].startswith("derived"):
            chans.append(m["ref"])
    return sorted(set(chans))


def convergence_channels(spec: dict, cols: list[str]) -> list[str]:
    chans = [c for c in scored_channels(spec, "moordyn_c") if c in cols]
    return chans or [c for c in cols if c != "Time" and KEEP.match(c) and not c.startswith("Point")]


def t0_node_check(case_id: str, cols: list[str], data: np.ndarray) -> dict:
    """Compare MoorDyn-C's t = 0 rod end positions with the deck (rod-orientation convention guard)."""
    text = (CASES / case_id / "moordyn.txt").read_text().splitlines()
    out = {}
    try:
        i = next(k for k, ln in enumerate(text) if "RODS" in ln and "TYPES" not in ln)
    except StopIteration:
        return out
    for ln in text[i + 3:]:
        if ln.startswith("---"):
            break
        tok = ln.split()
        rid, att = int(tok[0]), tok[2]
        if att.lower() not in ("free", "pinned"):
            continue
        a, b = np.array(tok[3:6], float), np.array(tok[6:9], float)
        n = int(tok[9])
        got_a = np.array([data[0, cols.index(f"Rod{rid}P{c}")] for c in "xyz"])
        got_b = np.array([data[0, cols.index(f"Rod{rid}N{n}P{c}")] for c in "xyz"])
        out[f"Rod{rid}"] = float(max(np.abs(got_a - a).max(), np.abs(got_b - b).max()))
    return out


def _coupling_dt(ref: dict, dt: float) -> float | None:
    """Coupling step of a level: ``cdt = "dtM"`` couples at every MoorDyn time step. MoorDyn-C
    moves a coupled point linearly with the velocity given at the start of each coupling step,
    so a coarse coupling step adds a velocity error a*cdt at the fairlead and a mesh-independent
    tension error sqrt(EA m)*a*cdt (V-S1m at cdt 0.01 s: 2.7 % of the heave tension amplitude)."""
    cdt = ref.get("cdt")
    return dt if cdt == "dtM" else cdt


def dynamic_reference(case_id: str, spec: dict) -> None:
    ref = spec["references"]["moordyn_c"]
    levels = sorted(ref["dt_levels"], reverse=True)
    runs = []
    for dt in levels:
        cols, data, timing = run(case_id, ref["deck"], f"mdc_dt{dt:g}.csv", ref["tmax"], ref["dtout"],
                                 noic=ref["noic"], scheme=ref.get("scheme"), dtm=dt,
                                 motion=ref.get("motion"), cdt=_coupling_dt(ref, dt), settle=ref.get("settle"))
        runs.append((dt, cols, data, timing))
        print(f"  {case_id} dt {dt:g}: march {timing['march_s']:.2f} s")
    dtf, cols, fine, _ = runs[-1]
    chans = convergence_channels(spec, cols)
    wins = [m["window"] for m in spec["metrics"] if m.get("window") and m["ref_code"] == "moordyn_c"]
    win = wins[0] if wins else None
    conv = []
    for dt, c, d, timing in runs:
        errs = {}
        for ch in chans:
            if ch not in c:
                continue
            v = e_rms(d[:, 0], d[:, c.index(ch)], fine[:, 0], fine[:, cols.index(ch)], win)
            if np.isfinite(v):
                errs[ch] = v
        conv.append(dict(dt=dt, e_rms_vs_finest=errs, max_e_rms=max(errs.values()) if errs else None,
                         init_s=timing["init_s"], march_s=timing["march_s"]))
    # agreement of the two finest levels is the convergence evidence
    prev = conv[-2]["max_e_rms"] if len(conv) > 1 else None
    keep = [i for i, c in enumerate(cols) if KEEP.match(c)]
    prov = dict(
        version=mdc_version(), runner="validation/scripts/bodies_mdc_runner.cpp",
        settings=dict(scheme=ref.get("scheme"),
                      init=("MoorDyn_Init_NoIC + lines settled about the held bodies (--settle)" if ref.get("settle")
                            else "MoorDyn_Init_NoIC") if ref["noic"] else "MoorDyn_Init",
                      dtout=ref["dtout"], coupling_dt=ref.get("cdt"), motion=ref.get("motion"),
                      settle_tmaxic=ref.get("settle"),
                      deck=f"cases/{case_id}/{ref['deck']}"),
        dt=dtf, convergence_window=win, convergence=conv, converged_below_0p1pct=bool(prev is not None and prev < 1e-3),
        t0_rod_node_error_m=t0_node_check(case_id, cols, fine),
    )
    write_reference(case_id, "moordyn_c", [cols[i] for i in keep], fine[:, keep], prov, fmt="%.7e")
    print(f"  {case_id}: reference dt {dtf:g}, e_rms(next coarser) = {prev}")


def static_reference(case_id: str, spec: dict, key: str) -> None:
    ref = spec["references"][key]
    cols, data, timing = run(case_id, ref["deck"], f"{key}.csv", 0.1, 0.1, noic=False,
                             scheme="rk4", motion=ref.get("motion"), cdt=0.01)
    keep = [i for i, c in enumerate(cols) if KEEP.match(c)]
    prov = dict(version=mdc_version(), runner="validation/scripts/bodies_mdc_runner.cpp",
                settings=dict(init="MoorDyn_Init dynamic relaxation", deck=f"cases/{case_id}/{ref['deck']}",
                              motion=ref.get("motion"), note="row t = 0 is the static equilibrium"),
                dt=None, init_s=timing["init_s"])
    write_reference(case_id, key, [cols[i] for i in keep], data[:1][:, keep], prov, fmt="%.9e")
    print(f"  {case_id} {key}: init {timing['init_s']:.1f} s")


def main(ids: list[str]) -> None:
    manifest = json.loads((BODIES / "cases.json").read_text())
    for cid, spec in manifest.items():
        if ids and cid not in ids:
            continue
        refs = spec["references"]
        for key in refs:
            if key.startswith("moordyn_c_static"):
                static_reference(cid, spec, key)
        if "moordyn_c" in refs:
            dynamic_reference(cid, spec)


if __name__ == "__main__":
    main(sys.argv[1:])
