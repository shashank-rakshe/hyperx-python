# SPDX-License-Identifier: Apache-2.0
"""Command-line entry point for the standalone-driver wrapper."""

from __future__ import annotations

import argparse
import sys

from cabledyn.driver import CableDynDriver, DriverError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cabledyn-run",
        description="Run a CableDyn standalone deck with validated output handling.",
    )
    parser.add_argument("deck", help="CableDyn sectioned .dat deck")
    parser.add_argument("output_root", help="output stem; .out is appended")
    parser.add_argument("--executable", help="path to CableDyn_driver.exe")
    parser.add_argument("--timeout", type=float, help="maximum solver wall time in seconds")
    parser.add_argument("--overwrite", action="store_true", help="replace existing result files")
    args = parser.parse_args(argv)
    try:
        result = CableDynDriver(args.executable).run(
            args.deck,
            args.output_root,
            timeout=args.timeout,
            overwrite=args.overwrite,
        )
    except (DriverError, OSError, ValueError) as exc:
        parser.exit(1, f"cabledyn-run: {exc}\n")
    print(result.main_output)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
