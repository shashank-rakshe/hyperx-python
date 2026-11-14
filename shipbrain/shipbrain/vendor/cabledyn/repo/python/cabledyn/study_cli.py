# SPDX-License-Identifier: Apache-2.0
"""Command-line batch execution of generated CableDyn deck studies."""

from __future__ import annotations

import argparse
import sys

from cabledyn.errors import DriverError, StudyFormatError, StudyOutputError
from cabledyn.study import run_study


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cabledyn-study",
        description="Run a provenance-checked CableDyn cases.json study.",
    )
    parser.add_argument("manifest", help="cases.json from cabledyn-deck generate")
    parser.add_argument("--executable", help="path to CableDyn_driver.exe")
    parser.add_argument("--output-directory")
    parser.add_argument("--jobs", type=int, default=1, help="parallel native processes")
    parser.add_argument("--timeout", type=float, help="per-case wall-time limit (s)")
    parser.add_argument(
        "--channel",
        action="append",
        dest="channels",
        help="main-output channel to summarize (repeatable; default: all)",
    )
    parser.add_argument("--start", type=float, help="statistics period start (s)")
    parser.add_argument("--stop", type=float, help="statistics period stop (s)")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = run_study(
            args.manifest,
            executable=args.executable,
            output_directory=args.output_directory,
            channels=args.channels,
            start=args.start,
            stop=args.stop,
            timeout=args.timeout,
            jobs=args.jobs,
            overwrite=args.overwrite,
        )
    except StudyOutputError as exc:
        # The cases ran; only the study-level summary artifacts could not be written.
        parser.exit(3, f"cabledyn-study: {exc}\n")
    except (DriverError, StudyFormatError, OSError, ValueError) as exc:
        parser.exit(2, f"cabledyn-study: {exc}\n")
    for case in result.cases:
        detail = f": {case.error}" if case.error else ""
        print(f"{case.name}: {case.status}{detail}")
    print(f"study_manifest: {result.study_manifest}")
    print(f"summary_csv: {result.summary_csv}")
    return 0 if result.passed else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
