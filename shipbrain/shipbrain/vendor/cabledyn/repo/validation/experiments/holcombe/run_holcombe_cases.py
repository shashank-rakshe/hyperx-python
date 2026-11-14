#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Run the prepared Holcombe static cases and record their provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path


def file_record(path: Path) -> dict[str, object]:
    if not path.is_file():
        return {"exists": False, "bytes": 0, "sha256": None}
    data = path.read_bytes()
    return {
        "exists": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("case_directory", type=Path)
    args = parser.parse_args()

    executable = args.executable.resolve()
    case_directory = args.case_directory.resolve()
    cases = json.loads(
        (case_directory / "case_manifest.json").read_text(encoding="utf-8")
    )
    environment = os.environ.copy()
    environment.setdefault("OMP_NUM_THREADS", "1")
    results = []
    for case in cases:
        stem = str(case["case"])
        started = time.perf_counter()
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
        wall_time = time.perf_counter() - started
        console = completed.stdout + completed.stderr
        (case_directory / f"{stem}.console.txt").write_text(console, encoding="utf-8")
        result = {
            "case": stem,
            "return_code": completed.returncode,
            "wall_time_s": wall_time,
            "reported_converged": "converged run written" in console.lower(),
            "static_profile": file_record(case_directory / f"{stem}.static.out"),
            "element_profile": file_record(case_directory / f"{stem}.elements.out"),
            "summary_output": file_record(case_directory / f"{stem}.out"),
        }
        results.append(result)
        print(
            f"{stem}: rc={completed.returncode}, "
            f"converged={result['reported_converged']}, wall={wall_time:.2f} s"
        )

    payload = {
        "executable": str(executable),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "cases": results,
    }
    (case_directory / "run_manifest.json").write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )
    failed = [
        item
        for item in results
        if item["return_code"] != 0
        or not item["reported_converged"]
        or not item["static_profile"]["exists"]
        or not item["element_profile"]["exists"]
    ]
    print(
        f"Completed {len(results) - len(failed)}/{len(results)} cases; failures={len(failed)}"
    )
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
