# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Smoke-test an installed cabledyn platform wheel, outside the source tree.

The installed package must load the CableDyn library it carries (not one from a build tree or
CABLEDYN_LIBRARY), select the driver it carries (not one on PATH), and run a standalone deck to
completion. With --expect-build, the driver's --version must report that build ("x86-64-v3"
for the x86-64 release wheels, "baseline" otherwise). Usage:

    python release/smoke_test_wheel.py <deck.dat> [--expect-build x86-64-v3|baseline]
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("deck", type=Path)
    parser.add_argument("--expect-build", choices=["x86-64-v3", "baseline"])
    args = parser.parse_args()
    deck = args.deck.resolve()
    for name in ("CABLEDYN_LIBRARY", "CABLEDYN_DRIVER"):
        os.environ.pop(name, None)

    import cabledyn
    from cabledyn import _discovery, driver

    package = Path(cabledyn.__file__).resolve().parent
    library = _discovery.find_library()
    if library.parent != package:
        print(f"FAIL: the library {library} is not the one in the package {package}", file=sys.stderr)
        return 1
    print(f"library : {library}")
    print(f"version : {cabledyn.version_string()}")

    executable = driver._resolve_executable(None)
    if executable.parent != package / "bin":
        print(f"FAIL: the driver {executable} is not the one in {package / 'bin'}", file=sys.stderr)
        return 1
    print(f"driver  : {executable}")

    if args.expect_build:
        banner = subprocess.run([str(executable), "--version"], capture_output=True, text=True, check=False)
        build = [line.split(None, 1)[1].strip() for line in banner.stdout.splitlines() if line.split()[:1] == ["Build"]]
        if banner.returncode != 0 or not build or not build[0].startswith(args.expect_build):
            print(
                f"FAIL: the driver reports build {build} (exit {banner.returncode}); expected {args.expect_build}",
                file=sys.stderr,
            )
            return 1
        print(f"build   : {build[0]}")

    with tempfile.TemporaryDirectory() as work:
        root = Path(work) / deck.stem
        result = driver.CableDynDriver().run(deck, output_root=root)
        outputs = sorted(p.name for p in Path(work).iterdir())
    if result is None or not any(name.endswith(".out") for name in outputs):
        print(f"FAIL: the driver run wrote no .out file ({outputs})", file=sys.stderr)
        return 1
    print(f"deck    : {deck.name} ran; outputs {outputs}")
    print("PASS: the installed wheel carries a working library and driver")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
