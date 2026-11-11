# File: validation/scripts/performance_records.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Same-host wall-clock records of CableDyn, OrcaFlex, MoorDyn-F and MoorDyn-C (cases L5).

Provenance tool (NOT built by CMake). It builds and times the three L5 wall-clock cases of
VALIDATION.md and writes the records in ``validation/performance``:

* ``dpc`` (L5-DPC): the matched 80, 200 and 800 m pinned-touchdown lazy-wave spans of the L3-6
  protocol (3 m / 12 s hang-off heave, 60 s). CableDyn runs driver decks with 240, 480 and 960
  Hermite elements at dt 0.05 s; OrcaFlex runs the models of
  ``orcaflex_lazywave_dynamic_reference.py`` (0.75 m segments, implicit dt 0.05 s, 12 s build-up
  and 48 s); MoorDyn-F runs the decks of ``moordyn_lazywave_dynamic_reference.py`` refined fourfold
  at 0.125 ms (80, 200 m) and 0.5 ms (800 m), RK4, with its dynamic-relaxation initialisation.
* ``v`` (L5-V): the one-hour VolturnUS-S mooring. CableDyn runs the deck equivalent of the
  ``l3_longduration_mooring`` gate (dt 0.1 s, 3600 s); OrcaFlex runs the model of
  ``orcaflex_longduration_mooring.py`` (dt 0.1 s, 200 s build-up and 3600 s).
* ``wc`` (L5-wc): the WD0050 tension-only chain under the L2-2 A1 heave for 80 s. CableDyn runs
  ``examples/wd0050_chain.dat`` at dt 0.05 s; MoorDyn-C runs the same chain through
  ``moordyn_c_driver.cpp`` (explicit RK2, dtM 1 ms, coupling step 0.1 s).

Protocol: one thread (OMP_NUM_THREADS = OPENBLAS_NUM_THREADS = 1; OrcaFlex ``threadCount = 1``),
high process priority, one warm-up run and three timed runs; the median and range are kept. The
CableDyn, MoorDyn-F and MoorDyn-C times are whole-process wall times (input, initial condition,
dynamics and output). The OrcaFlex time is ``CalculateStatics`` plus ``RunSimulation`` in a fresh
Python process. A separate CableDyn run with CABLEDYN_PROFILE gives the phase split and the solver
counts. Every run is checked against the response of its reference model before it is recorded.
The busy fraction of the host processors during each timed run is recorded alongside.

Usage (from the repository root, in an environment with numpy; OrcaFlex needs OrcFxAPI on
PYTHONPATH):

    python validation/scripts/performance_records.py run --cases dpc v wc --codes cabledyn \\
        --cabledyn-driver <CableDyn_driver.exe> --cabledyn-label <label> --cabledyn-build "<text>"
    python validation/scripts/performance_records.py run --cases dpc v --codes orcaflex
    python validation/scripts/performance_records.py run --cases dpc --codes moordyn-f \\
        --moordyn-f-driver <moordyn_driver.exe> --moordyn-f-build "<text>" [--step-check]
    python validation/scripts/performance_records.py run --cases wc --codes moordyn-c \\
        --mdc-src <MoorDyn source> --mdc-build <MoorDyn build> --gxx <g++> --moordyn-c-build "<text>"
    python validation/scripts/performance_records.py write

Results accumulate in ``<work>/results.json`` (default work directory ``build/performance``);
``write`` turns them into ``validation/performance/performance_summary.csv``,
``wallclock_summary.csv`` and ``performance_metrics.json``.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

import performance_models as pm
from bodies_common import file_sha256, host_description

REPO = SCRIPTS.parents[1]
RECORDS = REPO / "validation" / "performance"
DEFAULT_WORK = REPO / "build" / "performance"
SITES = tuple(pm.DPC_SITES)

# Reference responses each timed model must reproduce before it is recorded.
# L5-DPC: OrcaFlex hang-off effective tension mean / min / max over the scored window (kN), the
# committed constants of tests/test_l3_lazywave_dynamic.f90.
DPC_REFERENCE = {
    "80m": (9.3210, 5.6342, 13.0806),
    "200m": (25.1560, 14.8934, 35.5169),
    "800m": (57.7876, 33.2413, 82.9632),
}
DPC_TOLERANCE = 0.02
# L5-V: OrcaFlex fairlead tension mean / std / min / max over [200, 3600] s (kN), the committed
# constants of tests/test_l3_longduration_mooring.f90, with that gate's tolerances.
V_REFERENCE = (2439.385, 206.079, 2057.857, 2850.911)
V_TOLERANCE = (0.02, 0.03, 0.05, 0.03)
# L5-wc: the scored-window mean and maximum fairlead tension of the two codes agree within the
# L2-2 gate's 15 % band (the cross-code difference is recorded).
WC_TOLERANCE = 0.15


def executable(name: str) -> Path:
    """An executable given as a path (absolute, or relative to the working directory) or as a bare
    name searched on PATH, as an absolute path."""
    if os.sep in name or (os.altsep and os.altsep in name) or Path(name).is_file():
        return Path(name).resolve()
    found = shutil.which(name)
    if found is None:
        raise SystemExit(f"executable {name!r} not found on PATH")
    return Path(found).resolve()


# --------------------------------------------------------------------------------------------
# Process timing
# --------------------------------------------------------------------------------------------
def _system_times() -> tuple[int, int] | None:
    """(idle, total) processor time of the host in 100 ns units (Windows only)."""
    if os.name != "nt":
        return None
    import ctypes
    from ctypes import wintypes

    idle, kernel, user = wintypes.FILETIME(), wintypes.FILETIME(), wintypes.FILETIME()
    if not ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
        return None

    def value(ft):
        return (ft.dwHighDateTime << 32) | ft.dwLowDateTime

    return value(idle), value(kernel) + value(user)


def _process_stats(proc: subprocess.Popen) -> tuple[float | None, float | None]:
    """CPU seconds and peak working set (MiB) of a finished child process (Windows only)."""
    if os.name != "nt":
        return None, None
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    handle = wintypes.HANDLE(int(proc._handle))
    times = [wintypes.FILETIME() for _ in range(4)]
    cpu = None
    if ctypes.windll.kernel32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times]):
        kernel = (times[2].dwHighDateTime << 32) | times[2].dwLowDateTime
        user = (times[3].dwHighDateTime << 32) | times[3].dwLowDateTime
        cpu = (kernel + user) * 1.0e-7
    counters = Counters()
    counters.cb = ctypes.sizeof(Counters)
    peak = None
    if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
        peak = counters.PeakWorkingSetSize / 2.0**20
    return cpu, peak


def run_process(cmd: list[str], cwd: Path, env: dict | None = None, timeout: float = 7200.0) -> dict:
    """Run one process at high priority; wall, CPU and peak memory, with the host busy fraction."""
    flags = getattr(subprocess, "HIGH_PRIORITY_CLASS", 0)
    before = _system_times()
    t0 = time.perf_counter()
    proc = subprocess.Popen(
        cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, creationflags=flags
    )
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        raise RuntimeError(f"{cmd[0]} timed out in {cwd}") from None
    wall = time.perf_counter() - t0
    after = _system_times()
    cpu, peak = _process_stats(proc)
    busy = None
    if before and after and after[1] > before[1]:
        busy = 1.0 - (after[0] - before[0]) / (after[1] - before[1])
    if proc.returncode != 0:
        raise RuntimeError(
            f"{cmd} failed with exit code {proc.returncode} in {cwd}:\n{out[-3000:]}\n{err[-3000:]}"
        )
    return {"wall_s": wall, "cpu_s": cpu, "peak_working_set_MiB": peak, "host_busy": busy,
            "stdout": out, "stderr": err}


def timed_runs(make_run, repeats: int, warmup: int) -> list[dict]:
    """``make_run(k)`` runs measurement k (k < 0 is a warm-up) and returns its timing record."""
    for k in range(warmup):
        make_run(-1 - k)
    runs = []
    for k in range(repeats):
        record = make_run(k)
        for key in ("stdout", "stderr"):
            record.pop(key, None)
        runs.append(record)
        print(f"    run {k + 1}: {record['wall_s']:.3f} s (host busy {fmt_busy(record.get('host_busy'))})",
              flush=True)
    return runs


def fmt_busy(value) -> str:
    return "n/a" if value is None else f"{100.0 * value:.0f} %"


def summarise(runs: list[dict], key: str = "wall_s") -> dict:
    values = [r[key] for r in runs]
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "runs": values}


# --------------------------------------------------------------------------------------------
# CableDyn
# --------------------------------------------------------------------------------------------
def cabledyn_env(profile: bool = False) -> dict:
    env = dict(os.environ)
    env["OMP_NUM_THREADS"] = "1"
    env["OPENBLAS_NUM_THREADS"] = "1"
    env.pop("CABLEDYN_PROFILE", None)
    if profile:
        env["CABLEDYN_PROFILE"] = "1"
    return env


def _parse_finite_ei(line: str) -> dict:
    body = line.split("Finite-EI cable steps:", 1)[1].strip().rstrip(".")
    items = [p.strip() for p in body.split(",")]
    result = {"steps": int(items[0])}
    for item in items[1:]:
        label, value = item.rsplit(":", 1)
        result[label.strip()] = int(value)
    return result


def cabledyn_profile(text: str) -> dict:
    prof = {}
    for line in text.splitlines():
        s = line.strip()
        for label, key in (("input parsing", "input_s"), ("initialisation and statics", "init_statics_s"),
                           ("dynamic march", "march_s"), ("total", "profile_total_s")):
            if s.startswith(label) and s.endswith("%"):
                prof[key] = float(s[len(label):].split()[0])
        if s.startswith("March:"):
            prof["committed_steps"] = int(s.split()[1])
            prof["march_ms_per_step"] = float(s.split()[4])
        if s.startswith("Finite-EI cable steps:"):
            fe = _parse_finite_ei(s)
            prof["finite_ei_steps"] = fe["steps"]
            prof["linear_solves"] = fe.get("linear solves")
            prof["factorisations"] = fe.get("factorisations")
            prof["recovered_intervals"] = fe.get("intervals recovered by substeps")
        if s.startswith("EI = 0 line steps:"):
            parts = s.replace("(", " ").replace(")", " ").replace(",", " ").split()
            prof["ei0_line_steps"] = int(parts[5])
            prof["ei0_newton_iterations"] = int(parts[parts.index("iterations:") + 1])
    return prof


def cabledyn_notes(text: str) -> list[str]:
    """Distinct driver notes, without the numbers, for the record."""
    notes = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("Note:") and s not in notes:
            notes.append(s)
    return notes


def read_cabledyn_out(path: Path) -> tuple[list[str], np.ndarray]:
    with path.open(encoding="utf-8") as fh:
        fh.readline()
        names = fh.readline().split()
    return names, np.loadtxt(path, skiprows=2, ndmin=2)


def cabledyn_version(driver: Path) -> str:
    r = subprocess.run([str(driver), "--version"], capture_output=True, text=True, check=True)
    lines = [ln.strip() for ln in r.stdout.splitlines()]
    version = next((ln for ln in lines if ln.startswith("CableDyn ")), "")
    build = next((ln for ln in lines if ln.startswith("Build ")), "")
    return " ".join(" ".join(x.split()) for x in (version, build) if x)


def window(t: np.ndarray, lo: float, hi: float) -> np.ndarray:
    return (t >= lo - 1.0e-9) & (t <= hi + 1.0e-9)


def cabledyn_response(case: str, root: Path) -> dict:
    names, data = read_cabledyn_out(root.with_suffix(".out"))
    t, ten = data[:, 0], data[:, names.index("FairTen1")] / 1.0e3
    if case == "dpc":
        w = window(t, *pm.DPC_WINDOW)
        return {"tension_mean_kN": float(ten[w].mean()), "tension_min_kN": float(ten[w].min()),
                "tension_max_kN": float(ten[w].max())}
    if case == "v":
        w = window(t, *pm.V_WINDOW)
        return {"tension_mean_kN": float(ten[w].mean()), "tension_std_kN": float(ten[w].std()),
                "tension_min_kN": float(ten[w].min()), "tension_max_kN": float(ten[w].max())}
    w = window(t, pm.WC_WARMUP, pm.WC_WARMUP + pm.WC_SCORE) & on_grid(t, pm.WC_COUPLING_DT)
    return {"tension_mean_kN": float(ten[w].mean()), "tension_max_kN": float(ten[w].max()),
            "tension_min_kN": float(ten[w].min()), "series": [[float(a - pm.WC_WARMUP), float(b)]
                                                           for a, b in zip(t[w], ten[w], strict=True)]}


def on_grid(t: np.ndarray, step: float) -> np.ndarray:
    return np.abs(t / step - np.round(t / step)) < 1.0e-6


def write_cabledyn_case(case: str, site: str | None, directory: Path) -> dict:
    if case == "dpc":
        return pm.write_cabledyn_dpc(site, directory)
    if case == "v":
        return pm.write_cabledyn_v(directory)
    return pm.write_cabledyn_wc(directory)


def run_cabledyn(args, case: str, site: str | None) -> dict:
    driver = executable(args.cabledyn_driver)
    directory = args.work / "cabledyn" / args.cabledyn_label / (case if site is None else f"{case}_{site}")
    if directory.exists():
        shutil.rmtree(directory)
    model = write_cabledyn_case(case, site, directory)

    def one(k: int, profile: bool = False) -> dict:
        root = directory / ("warmup" if k < 0 else ("profile" if profile else f"run{k}"))
        return run_process([str(driver), "deck.dat", root.name], directory, cabledyn_env(profile))

    runs = timed_runs(one, args.repeats, args.warmup)
    profiled = one(0, profile=True)
    response = cabledyn_response(case, directory / "run0")
    profile = cabledyn_profile(profiled["stdout"])
    return {
        "model": model,
        "runs": runs,
        "profile": profile,
        "notes": cabledyn_notes(profiled["stdout"] + profiled["stderr"]),
        "response": response,
        "code": {"name": "CableDyn", "label": args.cabledyn_label, "version": cabledyn_version(driver),
                 "build": args.cabledyn_build, "driver_sha256": file_sha256(driver)},
    }


# --------------------------------------------------------------------------------------------
# OrcaFlex (timed in a fresh Python process per run)
# --------------------------------------------------------------------------------------------
def orcaflex_child(case: str, site: str | None) -> None:
    import OrcFxAPI as ofx

    if case == "dpc":
        import orcaflex_lazywave_dynamic_reference as ref

        model, line = ref.build(site)
    else:
        import orcaflex_longduration_mooring as ref

        model, line = ref.build_model()
    model.threadCount = 1
    c0 = time.process_time()
    t0 = time.perf_counter()
    model.CalculateStatics()
    t1 = time.perf_counter()
    model.RunSimulation()
    t2 = time.perf_counter()
    c1 = time.process_time()
    if case == "dpc":
        period = ofx.SpecifiedPeriod(*ref.WINDOW)
        ten = np.array(line.TimeHistory("Effective tension", period, ofx.oeEndB))
        response = {"tension_mean_kN": float(ten.mean()), "tension_min_kN": float(ten.min()),
                    "tension_max_kN": float(ten.max())}
    else:
        period = ofx.SpecifiedPeriod(*ref.WINDOW)
        ten = np.array(line.TimeHistory("Effective tension", period, ofx.oeEndB))
        response = {"tension_mean_kN": float(ten.mean()), "tension_std_kN": float(ten.std()),
                    "tension_min_kN": float(ten.min()), "tension_max_kN": float(ten.max())}
    print("RESULT " + json.dumps({
        "static_s": t1 - t0, "dynamic_s": t2 - t1, "solve_s": t2 - t0, "solve_cpu_s": c1 - c0,
        "segments": len(line.NodeArclengths) - 1, "thread_count": model.threadCount,
        "dll_version": ofx.DLLVersion(), "response": response,
        "time_step_s": model.general.ImplicitConstantTimeStep,
        "stage_durations_s": list(model.general.StageDuration),
    }))


def run_orcaflex(args, case: str, site: str | None) -> dict:
    directory = args.work / "orcaflex" / (case if site is None else f"{case}_{site}")
    directory.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(Path(__file__).resolve()), "orcaflex-child", case] + ([site] if site else [])
    env = dict(os.environ)
    env["PYTHONPATH"] = str(SCRIPTS) + os.pathsep + env.get("PYTHONPATH", "")
    children = []

    def one(k: int) -> dict:
        record = run_process(cmd, directory, env)
        line = next(ln for ln in record["stdout"].splitlines() if ln.startswith("RESULT "))
        child = json.loads(line[len("RESULT "):])
        record["process_wall_s"] = record["wall_s"]
        record["wall_s"] = child["solve_s"]
        record["static_s"], record["dynamic_s"] = child["static_s"], child["dynamic_s"]
        record["solve_cpu_s"] = child["solve_cpu_s"]
        children.append(child)
        return record

    runs = timed_runs(one, args.repeats, args.warmup)
    last = children[-1]
    return {
        "model": {"elements": last["segments"], "time_step_s": last["time_step_s"],
                  "stage_durations_s": last["stage_durations_s"]},
        "runs": runs,
        "response": last["response"],
        "code": {"name": "OrcaFlex", "label": "orcaflex", "version": f"OrcFxAPI DLL {last['dll_version']}",
                 "build": f"OrcFxAPI from Python {platform.python_version()}, threadCount = {last['thread_count']}"},
    }


# --------------------------------------------------------------------------------------------
# MoorDyn-F (OpenFAST MoorDyn driver)
# --------------------------------------------------------------------------------------------
def run_moordyn_f(args, case: str, site: str) -> dict:
    from moordyn_lazywave_dynamic_reference import score

    driver = executable(args.moordyn_f_driver)
    base = args.work / "moordyn-f" / f"{case}_{site}"

    def one(k: int) -> dict:
        directory = base / ("warmup" if k < 0 else f"run{k}")
        if directory.exists():
            shutil.rmtree(directory)
        pm.write_moordyn_f_dpc(site, directory)
        return run_process([str(driver), "driver.inp"], directory, cabledyn_env())

    runs = timed_runs(one, args.repeats, args.warmup)
    refined = pm.moordyn_f_site(site)
    model = pm.write_moordyn_f_dpc(site, base / "run0")  # rewrites the identical inputs
    r = score(refined, base / "run0", model["span_m"])
    response = {"tension_mean_kN": r["tmean"], "tension_min_kN": r["tmin"], "tension_max_kN": r["tmax"],
                "dynamic_peak_curvature_per_m": r["kdyn"]}
    result = {"model": model, "runs": runs, "response": response,
              "code": {"name": "MoorDyn-F", "label": "moordyn-f", "version": args.moordyn_f_version,
                       "build": args.moordyn_f_build, "driver_sha256": file_sha256(driver)}}
    if args.step_check:
        half = base / "half_step"
        if half.exists():
            shutil.rmtree(half)
        pm.write_moordyn_f_dpc(site, half, dtm=model["time_step_s"] / 2.0)
        record = run_process([str(driver), "driver.inp"], half, cabledyn_env())
        h = score(refined, half, model["span_m"])
        moves = {key: abs(r[key] - h[key]) / max(abs(h[key]), 1.0e-12) for key in ("kdyn", "tmean", "tmin", "tmax")}
        result["step_check"] = {"half_step_s": model["time_step_s"] / 2.0, "half_step_wall_s": record["wall_s"],
                                "largest_relative_move": max(moves.values()), "moves": moves}
        print(f"    halved step: largest response move {100.0 * max(moves.values()):.4f} %", flush=True)
    return result


# --------------------------------------------------------------------------------------------
# MoorDyn-C (moordyn_c_driver.cpp)
# --------------------------------------------------------------------------------------------
def moordyn_c_exe(args) -> Path:
    exe_dir = args.work / "moordyn-c" / "bin"
    exe_dir.mkdir(parents=True, exist_ok=True)
    exe = exe_dir / "moordyn_c_driver.exe"
    src, build = Path(args.mdc_src), Path(args.mdc_build)
    dll = build / "source" / "libmoordyn.dll"
    if not dll.exists():
        raise FileNotFoundError(f"MoorDyn-C library not found: {dll}")
    include = [src / "source", build / "source", src / "source" / "Eigen", build]
    cmd = [str(executable(args.gxx)), "-O2", "-std=gnu++17", *[f"-I{p}" for p in include],
           str(SCRIPTS / "moordyn_c_driver.cpp"), str(dll), "-o", str(exe)]
    env = dict(os.environ)
    env["PATH"] = str(executable(args.gxx).parent) + os.pathsep + env.get("PATH", "")
    subprocess.run(cmd, check=True, env=env)
    shutil.copy2(dll, exe_dir / dll.name)
    return exe


def run_moordyn_c(args, case: str) -> dict:
    exe = moordyn_c_exe(args)
    base = args.work / "moordyn-c" / case
    if base.exists():
        shutil.rmtree(base)
    model = pm.write_moordyn_c_wc(base, args.mdc_dtm)
    cmd = [str(exe), "deck.txt", str(pm.WC_AMP), str(pm.WC_PERIOD), str(pm.WC_WARMUP), str(pm.WC_SCORE),
           str(pm.WC_COUPLING_DT), "tension.txt"]
    env = dict(os.environ)
    env["PATH"] = str(exe.parent) + os.pathsep + str(executable(args.gxx).parent) + os.pathsep + env.get("PATH", "")

    def one(k: int) -> dict:
        record = run_process(cmd, base, env)
        march = [ln for ln in record["stderr"].splitlines() if ln.startswith("wall-clock")]
        record["march_s"] = float(march[-1].split()[1]) if march else None
        return record

    runs = timed_runs(one, args.repeats, args.warmup)
    series = np.loadtxt(base / "tension.txt", ndmin=2)
    series = series[window(series[:, 0], 0.0, pm.WC_SCORE)]
    response = {"tension_mean_kN": float(series[:, 1].mean()), "tension_max_kN": float(series[:, 1].max()),
                "tension_min_kN": float(series[:, 1].min()), "series": series.tolist()}
    return {"model": model, "runs": runs, "response": response,
            "code": {"name": "MoorDyn-C", "label": "moordyn-c", "version": args.moordyn_c_version,
                     "build": args.moordyn_c_build, "library_sha256": file_sha256(
                         Path(args.mdc_build) / "source" / "libmoordyn.dll")}}


# --------------------------------------------------------------------------------------------
# Response checks
# --------------------------------------------------------------------------------------------
def check_response(case: str, site: str | None, result: dict) -> list[str]:
    """Relative differences from the reference response; raises when one is outside its band."""
    resp = result["response"]
    problems, lines = [], []
    if case == "dpc":
        for key, ref in zip(("tension_mean_kN", "tension_min_kN", "tension_max_kN"), DPC_REFERENCE[site],
                            strict=True):
            rel = (resp[key] - ref) / ref
            lines.append(f"{key} {resp[key]:.4f} vs OrcaFlex {ref:.4f} ({100.0 * rel:+.2f} %)")
            if abs(rel) > DPC_TOLERANCE:
                problems.append(lines[-1])
    elif case == "v":
        for key, ref, tol in zip(("tension_mean_kN", "tension_std_kN", "tension_min_kN", "tension_max_kN"),
                                 V_REFERENCE, V_TOLERANCE, strict=True):
            rel = (resp[key] - ref) / ref
            lines.append(f"{key} {resp[key]:.3f} vs OrcaFlex {ref:.3f} ({100.0 * rel:+.2f} %)")
            if abs(rel) > tol:
                problems.append(lines[-1])
    if problems:
        raise RuntimeError(f"{case} {site or ''}: response outside its reference band: {problems}")
    return lines


# --------------------------------------------------------------------------------------------
# Results file and records
# --------------------------------------------------------------------------------------------
def load_results(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"entries": {}}


def save_results(path: Path, results: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8", newline="\n")


def host_record() -> dict:
    return {"host": host_description(), "os_version": platform.version(),
            "python": platform.python_version()}


def cmd_run(args) -> None:
    results_path = args.work / "results.json"
    results = load_results(results_path)
    for case in args.cases:
        sites = list(args.sites) if case == "dpc" else [None]
        for code in args.codes:
            if (case, code) not in (("dpc", "cabledyn"), ("v", "cabledyn"), ("wc", "cabledyn"),
                                    ("dpc", "orcaflex"), ("v", "orcaflex"), ("dpc", "moordyn-f"),
                                    ("wc", "moordyn-c")):
                continue
            for site in sites:
                label = args.cabledyn_label if code == "cabledyn" else code
                key = "/".join(x for x in (case, site, code, label) if x)
                print(f"[{key}]", flush=True)
                if code == "cabledyn":
                    result = run_cabledyn(args, case, site)
                elif code == "orcaflex":
                    result = run_orcaflex(args, case, site)
                elif code == "moordyn-f":
                    result = run_moordyn_f(args, case, site)
                else:
                    result = run_moordyn_c(args, case)
                if code != "moordyn-c":
                    for line in check_response(case, site, result):
                        print(f"    {line}", flush=True)
                result.update({"case": case, "site": site, "date": dt.date.today().isoformat(),
                               **host_record()})
                wall = summarise(result["runs"])
                print(f"    median {wall['median']:.3f} s ({wall['min']:.3f}-{wall['max']:.3f})", flush=True)
                results["entries"][key] = result
                save_results(results_path, results)


def _median(runs: list[dict], key: str):
    values = [r[key] for r in runs if r.get(key) is not None]
    return statistics.median(values) if values else None


def _round(value, digits: int = 4):
    return None if value is None else round(float(value), digits)


def compare_wc(cabledyn: dict, moordyn_c: dict) -> dict:
    a = np.array(cabledyn["response"]["series"])
    b = np.array(moordyn_c["response"]["series"])
    common = np.intersect1d(np.round(a[:, 0], 6), np.round(b[:, 0], 6))
    fa = {round(t, 6): v for t, v in a}
    fb = {round(t, 6): v for t, v in b}
    xa = np.array([fa[t] for t in common])
    xb = np.array([fb[t] for t in common])
    return {"samples": int(common.size),
            "mean_difference_percent": 100.0 * abs(xa.mean() - xb.mean()) / xb.mean(),
            "max_difference_percent": 100.0 * abs(xa.max() - xb.max()) / xb.max()}


def wc_agreement(results: dict) -> dict:
    """The L5-wc CableDyn vs MoorDyn-C trace agreement; raises when it is outside WC_TOLERANCE."""
    extra, problems = {}, []
    for label in sorted({r["code"]["label"] for r in results.values() if r["code"]["name"] == "CableDyn"}):
        cd = results.get(f"wc/cabledyn/{label}")
        mdc = results.get("wc/moordyn-c/moordyn-c")
        if not (cd and mdc):
            continue
        cmp = compare_wc(cd, mdc)
        if cmp["samples"] == 0:
            problems.append(f"{label}: no common output times with MoorDyn-C")
        for key in ("mean_difference_percent", "max_difference_percent"):
            if not cmp[key] <= 100.0 * WC_TOLERANCE:
                problems.append(f"{label}: {key} {cmp[key]:.2f} % > {100.0 * WC_TOLERANCE:.0f} %")
        extra[f"wc/{label}_vs_moordyn-c"] = {k: _round(v, 3) for k, v in cmp.items()}
    if problems:
        raise SystemExit(f"L5-wc response outside the L2-2 band; no records written: {problems}")
    return extra


def cmd_write(args) -> None:
    results = load_results(args.work / "results.json")["entries"]
    if not results:
        raise SystemExit("no results to write")
    # The L5-wc cross-code agreement is checked before any record file is written: a timing is
    # published only for a response inside the L2-2 band.
    extra = wc_agreement(results)
    rows = []
    for key, r in sorted(results.items()):
        wall = summarise(r["runs"])
        prof = r.get("profile", {})
        steps = prof.get("finite_ei_steps") or prof.get("ei0_line_steps")
        solves = prof.get("linear_solves") if prof.get("finite_ei_steps") else prof.get("ei0_newton_iterations")
        rows.append({
            "case": {"dpc": "L5-DPC", "v": "L5-V", "wc": "L5-wc"}[r["case"]],
            "site": r["site"] or "",
            "solver": r["code"]["name"],
            "build": r["code"]["label"],
            "elements": r["model"]["elements"],
            "time_step_s": r["model"]["time_step_s"],
            "total_wall_median_s": _round(wall["median"]),
            "total_wall_min_s": _round(wall["min"]),
            "total_wall_max_s": _round(wall["max"]),
            "static_wall_median_s": _round(prof.get("init_statics_s") if prof else _median(r["runs"], "static_s")),
            "dynamic_wall_median_s": _round(prof.get("march_s") if prof else (
                _median(r["runs"], "dynamic_s") if r["code"]["name"] == "OrcaFlex" else _median(r["runs"], "march_s"))),
            "total_cpu_median_s": _round(_median(r["runs"], "solve_cpu_s") if r["code"]["name"] == "OrcaFlex"
                                         else _median(r["runs"], "cpu_s")),
            "peak_working_set_MiB": _round(_median(r["runs"], "peak_working_set_MiB"), 1),
            "host_busy_median": _round(_median(r["runs"], "host_busy"), 3),
            "newton_per_step": _round(solves / steps, 3) if steps and solves else None,
            "subdivided_intervals": prof.get("recovered_intervals") if prof else None,
            "_key": key,
        })
    RECORDS.mkdir(parents=True, exist_ok=True)
    columns = [c for c in rows[0] if not c.startswith("_")]
    order = {"80m": 0, "200m": 1, "800m": 2, "": 3}
    solver_order = {"CableDyn": 0, "OrcaFlex": 1, "MoorDyn-F": 2, "MoorDyn-C": 3}

    def sort_key(row):
        return (row["case"], order[row["site"]], solver_order[row["solver"]], row["build"])

    rows.sort(key=sort_key)
    for name, selector in (("performance_summary.csv", lambda row: row["case"] == "L5-DPC"),
                           ("wallclock_summary.csv", lambda row: row["case"] != "L5-DPC")):
        with (RECORDS / name).open("w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=columns, lineterminator="\n")
            writer.writeheader()
            for row in rows:
                if selector(row):
                    writer.writerow({c: ("" if row[c] is None else row[c]) for c in columns})
    codes = {}
    for r in results.values():
        c = r["code"]
        codes[c["label"]] = {k: v for k, v in c.items() if k != "label"}
    responses = {row["_key"]: {k: _round(v, 4) for k, v in results[row["_key"]]["response"].items()
                               if k != "series"} for row in rows}
    step_checks = {key: {k: (_round(v, 8) if not isinstance(v, dict) else {a: _round(b, 8) for a, b in v.items()})
                         for k, v in r["step_check"].items()}
                   for key, r in results.items() if "step_check" in r}
    notes = {key: r["notes"] for key, r in results.items() if r.get("notes")}
    hosts = sorted({f"{r['host']} {r['os_version']}" for r in results.values()})
    dates = sorted({r["date"] for r in results.values()})
    record = {
        "protocol": {
            "threads": "one (OMP_NUM_THREADS = OPENBLAS_NUM_THREADS = 1; OrcaFlex threadCount = 1)",
            "repeats": "median of three timed runs after one warm-up; the range is kept",
            "timed_work": "CableDyn, MoorDyn-F and MoorDyn-C: the whole process; OrcaFlex: CalculateStatics "
                          "plus RunSimulation",
            "tool": "validation/scripts/performance_records.py",
        },
        "host": hosts,
        "dates": dates,
        "codes": codes,
        "rows": [{k: v for k, v in row.items() if not k.startswith("_")} for row in rows
                 if row["case"] == "L5-DPC"],
        "wallclock_rows": [{k: v for k, v in row.items() if not k.startswith("_")} for row in rows
                           if row["case"] != "L5-DPC"],
        "responses": responses,
        "wc_trace_agreement": extra,
        "moordyn_f_step_checks": step_checks,
        "cabledyn_driver_notes": notes,
    }
    (RECORDS / "performance_metrics.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {len(rows)} rows to {RECORDS}")


def main(argv: list[str] | None = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["orcaflex-child"]:
        orcaflex_child(argv[1], argv[2] if len(argv) > 2 else None)
        return
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="time cases and add them to the results file")
    run.add_argument("--cases", nargs="+", choices=("dpc", "v", "wc"), default=["dpc", "v", "wc"])
    run.add_argument("--codes", nargs="+", choices=("cabledyn", "orcaflex", "moordyn-f", "moordyn-c"),
                     default=["cabledyn"])
    run.add_argument("--sites", nargs="+", choices=SITES, default=list(SITES))
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--warmup", type=int, default=1)
    run.add_argument("--cabledyn-driver", help="CableDyn driver executable")
    run.add_argument("--cabledyn-label", default="cabledyn", help="build label used in the records")
    run.add_argument("--cabledyn-build", default="", help="build description (source, compiler, options)")
    run.add_argument("--moordyn-f-driver", default=os.environ.get("CD_MDF_DRIVER", "moordyn_driver"))
    run.add_argument("--moordyn-f-version", default="MoorDyn-F v2.3.8 (OpenFAST v5.0.0 MoorDyn driver)")
    run.add_argument("--moordyn-f-build", default="")
    run.add_argument("--step-check", action="store_true", help="also run MoorDyn-F once at half its step")
    run.add_argument("--mdc-src", default=os.environ.get("CD_MDC_SRC", "MoorDyn"))
    run.add_argument("--mdc-build", default=os.environ.get("CD_MDC_BUILD", "MoorDyn-build"))
    run.add_argument("--gxx", default=os.environ.get("CD_GXX", "g++"))
    run.add_argument("--mdc-dtm", type=float, default=pm.WC_MDC_DTM)
    run.add_argument("--moordyn-c-version", default="MoorDyn-C v2.7.2")
    run.add_argument("--moordyn-c-build", default="")
    run.add_argument("--work", type=Path, default=DEFAULT_WORK)
    write = sub.add_parser("write", help="write validation/performance from the results file")
    write.add_argument("--work", type=Path, default=DEFAULT_WORK)
    args = parser.parse_args(argv)
    args.work = args.work.resolve()
    if args.command == "run":
        if "cabledyn" in args.codes and not args.cabledyn_driver:
            parser.error("--cabledyn-driver is required for CableDyn runs")
        cmd_run(args)
    else:
        cmd_write(args)


if __name__ == "__main__":
    main()
