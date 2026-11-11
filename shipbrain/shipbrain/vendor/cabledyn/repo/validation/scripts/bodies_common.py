# File: validation/scripts/bodies_common.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Shared paths, tool discovery, series I/O and provenance for the bodies validation suite.

The reference generators ``bodies_run_moordyn_c.py`` and ``bodies_analytic.py`` write their
series through :func:`write_reference`, which stores a compact CSV (gzip above 256 kB) next to
a provenance JSON (code, version, settings, dt, hash, date, CPU and operating system).
``orcaflex_vd1b_reference.py`` writes summary values only (``references/V-D1b/orcaflex.json``).
"""

from __future__ import annotations

import datetime as _dt
import gzip
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
BODIES = REPO / "validation" / "bodies"
CASES = BODIES / "cases"
REFS = BODIES / "references"
SCRIPTS = REPO / "validation" / "scripts"

# Local tool locations (override with environment variables).
MDC_SRC = Path(os.environ.get("CD_MDC_SRC", "MoorDyn"))
MDC_BUILD = Path(os.environ.get("CD_MDC_BUILD", "MoorDyn-build"))
WORK = Path(os.environ.get("CD_BODIES_WORK", "bodies-work"))
MDF_DRIVER = os.environ.get("CD_MDF_DRIVER", "moordyn_driver")
GXX = os.environ.get("CD_GXX", "g++")

GZIP_ABOVE = 256 * 1024


def git_describe(path: Path) -> dict:
    """Return the commit hash and tag of a git checkout (empty strings when unknown)."""
    out = {"commit": "", "describe": ""}
    for key, args in (("commit", ["rev-parse", "HEAD"]), ("describe", ["describe", "--tags", "--always"])):
        try:
            out[key] = subprocess.run(
                ["git", "-C", str(path), *args], capture_output=True, text=True, check=True
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            pass
    return out


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def mdc_runner() -> Path:
    """Compile (once) and return the MoorDyn-C runner executable in the work directory."""
    WORK.mkdir(parents=True, exist_ok=True)
    exe = WORK / "bodies_mdc_runner.exe"
    src = SCRIPTS / "bodies_mdc_runner.cpp"
    dll = MDC_BUILD / "source" / "libmoordyn.dll"
    if not dll.exists():
        raise FileNotFoundError(f"MoorDyn-C library not found: {dll} (set CD_MDC_BUILD)")
    stamp = WORK / "bodies_mdc_runner.stamp"
    key = file_sha256(src) + file_sha256(dll)
    if exe.exists() and stamp.exists() and stamp.read_text() == key:
        return exe
    inc = [MDC_SRC / "source", MDC_BUILD / "source", MDC_SRC / "source" / "Eigen", MDC_BUILD]
    cmd = [GXX, "-O2", "-std=c++17", *[f"-I{p}" for p in inc], str(src), str(dll), "-o", str(exe)]
    env = dict(os.environ)
    env["PATH"] = str(Path(GXX).parent) + os.pathsep + env.get("PATH", "")
    subprocess.run(cmd, check=True, env=env)
    shutil.copy2(dll, WORK / "libmoordyn.dll")
    stamp.write_text(key)
    return exe


def mdc_version() -> dict:
    info = git_describe(MDC_SRC)
    dll = MDC_BUILD / "source" / "libmoordyn.dll"
    info["library_sha256"] = file_sha256(dll) if dll.exists() else ""
    info["build"] = "Release -O3, Strawberry g++ 13.2 (out-of-tree CMake/Ninja)"
    return info


def host_description() -> str:
    """CPU model and operating system of this machine, without its network name."""
    cpu = ""
    try:
        if platform.system() == "Windows":
            import winreg

            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                                 r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")
            cpu = str(winreg.QueryValueEx(key, "ProcessorNameString")[0])
        elif Path("/proc/cpuinfo").is_file():
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.lower().startswith("model name"):
                    cpu = line.split(":", 1)[1]
                    break
    except OSError:
        cpu = ""
    cpu = " ".join(cpu.split()) or platform.machine() or "unknown CPU"
    return f"{cpu}, {platform.system() or 'unknown OS'}"


def write_reference(case_id: str, code: str, columns: list[str], data: np.ndarray,
                    provenance: dict, fmt: str = "%.8e", tag: str = "") -> Path:
    """Store a reference series ``references/<case_id>/<code>[_tag].csv[.gz]`` + provenance JSON."""
    out_dir = REFS / case_id
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = code + (f"_{tag}" if tag else "")
    buf = io.StringIO()
    buf.write(",".join(columns) + "\n")
    np.savetxt(buf, np.atleast_2d(data), delimiter=",", fmt=fmt)
    raw = buf.getvalue().encode()
    for old in (out_dir / f"{stem}.csv", out_dir / f"{stem}.csv.gz"):
        old.unlink(missing_ok=True)
    if len(raw) > GZIP_ABOVE:
        path = out_dir / f"{stem}.csv.gz"
        with gzip.GzipFile(path, "wb", mtime=0) as fh:
            fh.write(raw)
    else:
        path = out_dir / f"{stem}.csv"
        path.write_bytes(raw)
    prov = {
        "case": case_id,
        "code": code,
        "series": path.name,
        "date": _dt.date.today().isoformat(),
        "host": host_description(),
        **provenance,
    }
    (out_dir / f"{stem}.json").write_text(json.dumps(prov, indent=2, sort_keys=False) + "\n")
    return path


def read_series(path: Path) -> tuple[list[str], np.ndarray]:
    """Read a CSV reference (optionally gzipped) or a CableDyn/MoorDyn whitespace table."""
    path = Path(path)
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt") as fh:
        text = fh.read()
    # CableDyn .out files open with a '#' comment line and name the time column Time(s)
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if "," in lines[0]:
        cols = [c.strip() for c in lines[0].split(",")]
        data = np.loadtxt(io.StringIO("\n".join(lines[1:])), delimiter=",", ndmin=2)
        return cols, data
    # whitespace table: header row, optional units row, numbers
    cols = ["Time" if c == "Time(s)" else c for c in lines[0].split()]
    start = 1
    try:
        float(lines[1].split()[0])
    except ValueError:
        start = 2
    data = np.loadtxt(io.StringIO("\n".join(lines[start:])), ndmin=2)
    return cols, data


def load_reference(case_id: str, code: str, tag: str = "") -> tuple[dict[str, np.ndarray], dict]:
    """Return ({channel: series}, provenance) for a stored reference."""
    stem = code + (f"_{tag}" if tag else "")
    d = REFS / case_id
    path = d / f"{stem}.csv"
    if not path.exists():
        path = d / f"{stem}.csv.gz"
    cols, data = read_series(path)
    prov = json.loads((d / f"{stem}.json").read_text())
    return {c: data[:, i] for i, c in enumerate(cols)}, prov


def load_summary(case_id: str, code: str, tag: str = "") -> dict | None:
    """Return the ``summary`` record of a reference kept as summary values only (else None)."""
    stem = code + (f"_{tag}" if tag else "")
    path = REFS / case_id / f"{stem}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text()).get("summary")
