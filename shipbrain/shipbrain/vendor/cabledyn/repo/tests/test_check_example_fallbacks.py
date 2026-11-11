#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The example scan of the round-off CI job must fail where it is meant to.

A stand-in driver, whose behaviour each deck selects, exercises tests/check_example_fallbacks.py
as a child process would: every fallback note fails the scan and names its deck, also when wrapped
over two lines; a non-zero exit and a timeout fail it; a clean deck passes. With a forced kernel,
a run that names another kernel or none at all fails it. The built driver then shows the same on
the real OpenBLAS: an unknown kernel name is not reported as taken.

Usage: test_check_example_fallbacks.py <cabledyn executable> <examples directory>
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scan", HERE / "check_example_fallbacks.py")
assert spec is not None and spec.loader is not None
scan = importlib.util.module_from_spec(spec)
sys.modules["scan"] = scan  # dataclasses look the module up by name
spec.loader.exec_module(scan)

# Each deck holds what the driver prints to stderr, then a last line with its exit code.
FAKE_DRIVER = """
import sys
import time
text = open(sys.argv[1], encoding="utf-8").read().split("|")
if text[-1] == "hang":
    time.sleep(60)
sys.stderr.write(text[0])
sys.exit(int(text[-1]))
"""

NOTES = {
    "newton": "   Note: line 1: the discrete attachment equilibrium was reached after a failed "
    "Newton solve (pseudo-transient continuation).\n",
    "wrapped": "   Note: line 1: reached after a failed\n   Newton solve.\n",
    "stalled": "   Note: the Newton iteration stalled at the load fraction 0.5.\n",
    "looser": "   Note: a looser tolerance is needed.\n",
    "floor": "   Note: line 1: static residual floor above the dynamic tolerance 1.00E-08; "
    "equilibrium accepted at the relative residual 2.00E-07.\n",
    "torsion_floor": "   Note: line 1: torsion static residual floor above the tolerance "
    "1.00E-08; twisted equilibrium accepted at 2.00E-07.\n",
    "substep": "  Note: line 1: 3 step(s) kept the whole step because a resolving sub-step did "
    "not converge.\n",
}
# Notes of a healthy run that must not trip the scan.
CLEAN = (
    "   Note: LINE 1: dtM = 0.1 s resolves its axial period of 1 s in 10 steps.\n"
    "   Note: line 1: 2 attachment(s) lumped at the nearest nodes.\n"
    "  CableDyn initialization completed.\n"
)


def write_deck(directory: Path, name: str, console: str, status: str = "0") -> Path:
    deck = directory / f"{name}.dat"
    deck.write_text(f"{console}|{status}", encoding="utf-8")
    return deck


def run_scan(command, decks, out, *, coretype=None, timeout=20.0):
    """The exit status and the printed report of a scan."""
    text = io.StringIO()
    with contextlib.redirect_stdout(text):
        runs = scan.scan(command, decks, out, jobs=4, timeout=timeout, coretype=coretype)
        status = scan.report(runs, coretype)
    return status, text.getvalue()


def check(condition: bool, what: str, failures: list[str], detail: str = "") -> None:
    print(f"{'ok' if condition else 'FAIL'}: {what}")
    if not condition:
        failures.append(f"{what}\n{detail}")


def main() -> int:
    driver, examples = Path(sys.argv[1]), Path(sys.argv[2])
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        decks = root / "decks"
        decks.mkdir()
        fake = root / "fake_driver.py"
        fake.write_text(FAKE_DRIVER, encoding="utf-8")
        command = [sys.executable, str(fake)]

        clean = write_deck(decks, "clean", CLEAN)
        status, text = run_scan(command, [clean], root / "clean")
        check(status == 0 and "OFFENDS" not in text, "a clean deck passes", failures, text)

        for name, note in NOTES.items():
            deck = write_deck(decks, name, CLEAN + note)
            status, text = run_scan(command, [clean, deck], root / name)
            listed = f"  {deck.name} (exit 0)" in text and f"  {clean.name} (" not in text
            check(status == 1 and listed, f"the note {name} fails its deck", failures, text)

        failed = write_deck(decks, "failed", CLEAN, "3")
        status, text = run_scan(command, [failed], root / "failed")
        check(status == 1 and "failed.dat (exit 3)" in text, "an exit status fails", failures, text)

        hung = write_deck(decks, "hung", CLEAN, "hang")
        status, text = run_scan(command, [hung], root / "hung", timeout=2.0)
        check(status == 1 and "hung.dat (no exit)" in text, "a timeout fails", failures, text)

        taken = write_deck(decks, "taken", "Core: Prescott\n" + CLEAN)
        status, text = run_scan(command, [taken], root / "taken", coretype="Prescott")
        check(status == 0, "the forced kernel passes", failures, text)
        status, text = run_scan(command, [taken], root / "case", coretype="PRESCOTT")
        check(status == 0, "kernel names match in any case", failures, text)

        other = write_deck(decks, "other", "Core not found: Prescott\nCore: Haswell\n" + CLEAN)
        status, text = run_scan(command, [other], root / "other", coretype="Prescott")
        check(status == 1 and "ran Haswell" in text, "another kernel fails", failures, text)

        status, text = run_scan(command, [clean], root / "none", coretype="Prescott")
        check(status == 1 and "named no kernel" in text, "no kernel fails", failures, text)

        status, text = run_scan(command, [taken, other], root / "mixed", coretype="Prescott")
        check(status == 1 and "ran Haswell" in text, "one wrong run fails", failures, text)

        # The shipped decks: the top-level decks and those of the MoorDyn-C kinematics folders,
        # with distinct names (each writes its outputs under its own name), and no auxiliary file.
        shipped = scan.example_decks(examples.resolve())
        names = [deck.name for deck in shipped]
        folders = {deck.parent.name for deck in shipped}
        check(
            "chain_wavekin7_currents1.dat" in names
            and len(set(names)) == len(names)
            and not folders & {"data", "openfast"},
            "the scan collects every shipped deck once",
            failures,
            "\n".join(str(deck) for deck in shipped),
        )

        # The real driver and OpenBLAS: a kernel that does not exist cannot be confirmed.
        real = io.StringIO()
        with contextlib.redirect_stdout(real):
            status = scan.main(
                [
                    "--driver",
                    str(driver),
                    "--examples",
                    str(examples),
                    "--out",
                    str(root / "real"),
                    "--coretype",
                    "NoSuchKernel",
                    "--kernel-only",
                ]
            )
        check(status == 1, "an unknown kernel fails on the real driver", failures, real.getvalue())

    for failure in failures:
        print(f"\nFAILED: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
