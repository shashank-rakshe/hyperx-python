#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run every shipped example deck and fail on a solver fallback note.

Each deck of the examples directory and of its MoorDyn-C kinematics folders (moordynC_*) runs on
the given driver, single-threaded, from its own folder, with its output root under a scratch
directory. A deck offends when the driver does not exit with 0, runs past
the timeout, or writes a fallback note to the console: a deck that should converge cleanly must
not reach its result through a failed Newton solve, a stall, a looser tolerance or a sub-step that
gave up. Such a note marks round-off fragility, which a different BLAS kernel can turn into a
failure.

With --coretype every run sets OPENBLAS_CORETYPE to that kernel and asks OpenBLAS to name the
kernel it selected. The check fails when OpenBLAS names another kernel, or when no run names one
at all, as with a build of OpenBLAS without dynamic architecture support, which ignores the
variable. --kernel-only runs the first deck alone for that check, before a long test run.

Usage: check_example_fallbacks.py --driver <cabledyn executable> --examples <directory>
                                  --out <scratch directory> [--coretype <kernel>]
                                  [--kernel-only] [--jobs <n>] [--timeout <seconds>]
Exit status: 0 clean; 1 an offending deck or the wrong kernel; 2 no decks or bad arguments.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

# The console notes of a fallback. A note may be wrapped, so whitespace runs match any spacing.
FALLBACK_NOTES = (
    ("failed Newton solve", re.compile(r"after\s+a\s+failed\s+Newton\s+solve", re.IGNORECASE)),
    ("stall", re.compile(r"\bstalled\b", re.IGNORECASE)),
    ("looser tolerance", re.compile(r"\blooser\s+tolerance\b", re.IGNORECASE)),
    # The note of an equilibrium accepted above the requested tolerance.
    ("looser tolerance", re.compile(r"\bresidual\s+floor\s+above\b", re.IGNORECASE)),
    ("sub-step", re.compile(r"\bresolving\s+sub-step\s+did\s+not\s+converge", re.IGNORECASE)),
)
# What OpenBLAS prints at start-up under OPENBLAS_VERBOSE=2, in a dynamic-architecture build only.
CORE_LINE = re.compile(r"^\s*Core:\s*(\S+)\s*$", re.MULTILINE)


@dataclass
class DeckRun:
    """The outcome of one deck."""

    deck: str
    returncode: int | None = None
    seconds: float = 0.0
    notes: list[str] = field(default_factory=list)
    cores: set[str] = field(default_factory=set)

    @property
    def offends(self) -> bool:
        return self.returncode != 0 or bool(self.notes)


def fallback_notes(console: str) -> list[str]:
    """The console text of every fallback note, one entry per note found."""
    found: list[str] = []
    for name, pattern in FALLBACK_NOTES:
        for match in pattern.finditer(console):
            start = console.rfind("\n", 0, match.start()) + 1
            stop = console.find("\n", match.end())
            line = console[start : stop if stop >= 0 else len(console)].strip()
            found.append(f"{name}: {line[:200]}")
    return found


def example_decks(examples: Path) -> list[Path]:
    """The shipped decks: every .dat of the examples directory and of its MoorDyn-C kinematics
    folders (moordynC_*), whose decks read fixed-name files beside them. The data and openfast
    folders hold auxiliary files and coupled decks, not standalone decks."""
    decks = [path for path in examples.glob("*.dat") if path.is_file()]
    decks += [path for path in examples.glob("moordynC_*/*.dat") if path.is_file()]
    return sorted(decks, key=lambda path: path.name)


def run_deck(
    command: Sequence[str],
    deck: Path,
    out: Path,
    timeout: float,
    coretype: str | None,
) -> DeckRun:
    """Run one deck from the directory of the deck, whose relative paths it may use."""
    env = dict(os.environ, OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1")
    if coretype is not None:
        env.update(OPENBLAS_CORETYPE=coretype, OPENBLAS_VERBOSE="2")
    result = DeckRun(deck.name)
    start = time.monotonic()
    try:
        process = subprocess.run(
            [*command, deck.name, str(out / deck.stem)],
            cwd=deck.parent,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        result.seconds = time.monotonic() - start
        result.notes.append(f"timeout: still running after {timeout:g} s")
        return result
    result.seconds = time.monotonic() - start
    result.returncode = process.returncode
    console = process.stdout + "\n" + process.stderr
    (out / f"{deck.stem}.console.log").write_text(console, encoding="utf-8")
    result.notes = fallback_notes(console)
    result.cores = set(CORE_LINE.findall(console))
    return result


def kernel_problem(runs: Sequence[DeckRun], coretype: str) -> str | None:
    """Why the runs did not use the kernel ``coretype``, or None if they did."""
    cores = set().union(*(run.cores for run in runs)) if runs else set()
    if not cores:
        return (
            f"OpenBLAS named no kernel, so OPENBLAS_CORETYPE={coretype} was not shown to take "
            "effect: the driver is not on a dynamic-architecture OpenBLAS"
        )
    wrong = sorted(core for core in cores if core.lower() != coretype.lower())
    if wrong:
        return f"OPENBLAS_CORETYPE={coretype} did not take effect: OpenBLAS ran {', '.join(wrong)}"
    return None


def scan(
    command: Sequence[str],
    decks: Sequence[Path],
    out: Path,
    *,
    jobs: int,
    timeout: float,
    coretype: str | None,
) -> list[DeckRun]:
    """Run the decks, printing each result as it arrives."""
    out.mkdir(parents=True, exist_ok=True)
    runs: list[DeckRun] = []
    with ThreadPoolExecutor(jobs) as pool:
        pending = [
            pool.submit(run_deck, command, deck, out, timeout, coretype) for deck in decks
        ]
        for future in as_completed(pending):
            run = future.result()
            runs.append(run)
            state = "OFFENDS" if run.offends else "ok"
            print(f"{state:8}{run.seconds:9.1f} s  {run.deck}", flush=True)
    return sorted(runs, key=lambda run: run.deck)


def report(runs: Sequence[DeckRun], coretype: str | None) -> int:
    """Print the offending decks and the verdict; return the exit status."""
    offending = [run for run in runs if run.offends]
    if offending:
        print(f"\n{len(offending)} of {len(runs)} example decks offend:")
        for run in offending:
            exit_text = "no exit" if run.returncode is None else f"exit {run.returncode}"
            print(f"  {run.deck} ({exit_text})")
            for note in run.notes:
                print(f"    {note}")
    problem = kernel_problem(runs, coretype) if coretype is not None else None
    if problem is not None:
        print(f"\nFAIL: {problem}")
    if offending or problem is not None:
        return 1
    kernel = f" on the {coretype} kernel" if coretype is not None else ""
    print(f"\n{len(runs)} example decks ran{kernel} with no fallback note")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fail on a fallback note of an example deck.")
    parser.add_argument("--driver", required=True, type=Path, help="the cabledyn executable")
    parser.add_argument("--examples", required=True, type=Path, help="the examples directory")
    parser.add_argument("--out", required=True, type=Path, help="scratch output directory")
    parser.add_argument("--coretype", help="the OpenBLAS kernel to force and to confirm")
    parser.add_argument(
        "--kernel-only", action="store_true", help="only confirm --coretype, on the first deck"
    )
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="parallel decks")
    parser.add_argument("--timeout", type=float, default=3600.0, help="seconds for each deck")
    args = parser.parse_args(argv)
    if args.kernel_only and args.coretype is None:
        parser.error("--kernel-only needs --coretype")

    examples = args.examples.resolve()
    decks = example_decks(examples)
    if not decks:
        print(f"FAIL: no example decks in {examples}")
        return 2
    command = [str(args.driver.resolve())]
    out = args.out.resolve()
    if args.kernel_only:
        runs = scan(command, decks[:1], out, jobs=1, timeout=args.timeout, coretype=args.coretype)
        problem = kernel_problem(runs, args.coretype)
        print(f"FAIL: {problem}" if problem else f"OpenBLAS ran the {args.coretype} kernel")
        return 1 if problem else 0
    runs = scan(
        command, decks, out, jobs=args.jobs, timeout=args.timeout, coretype=args.coretype
    )
    return report(runs, args.coretype)


if __name__ == "__main__":
    sys.exit(main())
