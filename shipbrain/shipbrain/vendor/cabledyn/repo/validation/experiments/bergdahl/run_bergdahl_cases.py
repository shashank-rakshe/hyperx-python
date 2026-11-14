#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Run the prepared Bergdahl cases and record solver-quality metadata."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path


MISS_RE = re.compile(r"(?:with\s+)?(\d+)/(\d+)\s+nonlinear convergence misses")
CONSECUTIVE_MISS_RE = re.compile(r"max consecutive misses=(\d+)")
RECOVERY_RE = re.compile(
    r"Recovery audit: dynamic run subdivided\s+(\d+)\s+nominal interval\(s\); "
    r"maximum substeps used=(\d+)\."
)


def run_one(executable: Path, case_directory: Path, case: dict) -> dict:
    stem = str(case["case"])
    started = time.perf_counter()
    environment = os.environ.copy()
    environment.setdefault("OMP_NUM_THREADS", "1")
    completed = subprocess.run(
        [str(executable), f"{stem}.dat", stem],
        cwd=case_directory,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    wall = time.perf_counter() - started
    console = completed.stdout + completed.stderr
    (case_directory / f"{stem}.console.txt").write_text(console, encoding="utf-8")
    match = MISS_RE.search(console)
    consecutive_match = CONSECUTIVE_MISS_RE.search(console)
    recovery_match = RECOVERY_RE.search(console)
    result_path = case_directory / f"{stem}.out"
    output_size = result_path.stat().st_size if result_path.exists() else 0
    return {
        "case": stem,
        "return_code": completed.returncode,
        "wall_time_s": wall,
        "nonlinear_misses": int(match.group(1)) if match else 0,
        "maximum_consecutive_misses": int(consecutive_match.group(1)) if consecutive_match else 0,
        "recovered_nominal_intervals": int(recovery_match.group(1)) if recovery_match else 0,
        "maximum_recovery_substeps": int(recovery_match.group(2)) if recovery_match else 1,
        "time_steps": int(match.group(2)) if match else int(round(float(case["total_cycles"]) * float(case["period_s"]) / float(case["dt_s"]))),
        "output_exists": result_path.exists(),
        "output_size_bytes": output_size,
        "output_sha256": hashlib.sha256(result_path.read_bytes()).hexdigest() if output_size > 0 else None,
        "completed_with_warning": "completed run with warnings" in console.lower(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("case_directory", type=Path)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--pattern", default="")
    args = parser.parse_args()
    executable = args.executable.resolve()
    case_directory = args.case_directory.resolve()
    manifest = json.loads((case_directory / "case_manifest.json").read_text(encoding="utf-8"))
    if args.pattern:
        manifest = [case for case in manifest if args.pattern in str(case["case"])]
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(run_one, executable, case_directory, case): case for case in manifest}
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            print(
                f"{result['case']}: rc={result['return_code']}, misses={result['nonlinear_misses']}, "
                f"wall={result['wall_time_s']:.2f} s",
                flush=True,
            )
    results.sort(key=lambda item: item["case"])
    payload = {
        "executable": str(executable),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "workers": args.workers,
        "cases": results,
    }
    (case_directory / "run_manifest.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    failed = [
        result
        for result in results
        if result["return_code"] != 0 or not result["output_exists"] or result["output_size_bytes"] == 0
    ]
    print(f"Completed {len(results) - len(failed)}/{len(results)} cases; failures={len(failed)}")
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
