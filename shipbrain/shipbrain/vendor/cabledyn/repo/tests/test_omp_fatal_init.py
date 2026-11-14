#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Every OpenMP parallel region of the library and the driver prepares its threads for the
abnormal-end report once per thread: its first statement is ``CALL CD_Fatal_Thread_Init()``,
before any worksharing loop, so a stack overflow on a worker thread is reported like one on
the main thread (src/cabledyn_fatal.c). A combined ``PARALLEL DO`` (or ``SECTIONS``,
``WORKSHARE``, ``LOOP``) construct has no place for that statement and is refused, as is the
call made inside a loop body, where it would run once per iteration."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r"^\s*!\$omp\s+parallel\b(?P<rest>.*)$", re.IGNORECASE)
COMBINED = re.compile(r"^\s*(?:do|sections|workshare|loop)\b", re.IGNORECASE)
DO_STATEMENT = re.compile(r"^\s*(?:\w+\s*:\s*)?do\b", re.IGNORECASE)
# A call that installs the abnormal-end handlers, from Fortran or C (not a declaration).
INSTALL = re.compile(
    r"^\s*call\s+cd_fatal_report_install\b"
    r"|^\s*(?!void\b)[^/*]*\bcabledyn_fatal_report_install\s*\(\s*\)\s*;",
    re.IGNORECASE,
)
INIT = re.compile(
    r"^\s*call\s+cd_fatal_thread_init\s*(?:\(\s*\))?\s*(?:!.*)?$", re.IGNORECASE
)


def sources() -> list[Path]:
    """The Fortran sources of the core library and the driver (not the OpenFAST tree)."""
    files = sorted((ROOT / "src").glob("*.f90")) + sorted((ROOT / "app").glob("*.f90"))
    return [path for path in files if "openfast" not in path.parent.name.lower()]


def is_statement(text: str) -> bool:
    """A line that is neither blank nor a comment (OpenMP directives count as statements)."""
    stripped = text.strip()
    return bool(stripped) and (not stripped.startswith("!") or stripped[:2] == "!$")


def check(lines: list[str]) -> tuple[int, list[str]]:
    """Count the parallel regions and describe each problem as '<line>: <reason>'."""
    found, problems = 0, []
    previous = ""
    index = 0
    while index < len(lines):
        line = lines[index]
        if INIT.match(line) and DO_STATEMENT.match(previous):
            problems.append(f"{index + 1}: the call runs once per loop iteration")
        match = DIRECTIVE.match(line)
        if match is not None:
            found += 1
            first = index
            while lines[index].rstrip().endswith("&"):
                index += 1
            if COMBINED.match(match.group("rest")):
                problems.append(
                    f"{first + 1}: a combined construct; split it into PARALLEL + DO"
                )
            else:
                following = (
                    lines[k]
                    for k in range(index + 1, len(lines))
                    if is_statement(lines[k])
                )
                if not INIT.match(next(following, "")):
                    problems.append(f"{first + 1}: the first statement is not the call")
        if is_statement(lines[index]):
            previous = lines[index]
        index += 1
    return found, problems


def install_calls() -> list[str]:
    """Every place in the library, the driver and the OpenFAST integration that installs the
    abnormal-end handlers, as '<path>:<line>'."""
    found = []
    for folder in ("src", "app", "integration"):
        for path in sorted((ROOT / folder).rglob("*")):
            if path.suffix.lower() not in {".f90", ".c", ".h"} or not path.is_file():
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if INSTALL.search(line):
                    found.append(f"{path.relative_to(ROOT).as_posix()}:{number}")
    return found


class OmpFatalInitTest(unittest.TestCase):
    def test_only_the_driver_installs_the_handlers(self) -> None:
        # A host that loads the library (OpenFAST, Python) keeps its own signal and exception
        # handling: only the standalone driver program installs the report.
        calls = install_calls()
        self.assertEqual([c.split(":")[0] for c in calls], ["app/cabledyn.f90"], calls)

    def test_every_parallel_region_prepares_its_threads_once(self) -> None:
        total = 0
        problems = []
        for path in sources():
            found, issues = check(path.read_text(encoding="utf-8").splitlines())
            total += found
            problems += [f"{path.relative_to(ROOT)}:{issue}" for issue in issues]
        self.assertGreater(
            total, 0, "no OpenMP parallel region found: the scan is broken"
        )
        self.assertEqual(
            problems, [], "OpenMP regions that do not prepare their threads once"
        )

    def test_the_scan_accepts_the_split_form(self) -> None:
        good = [
            "    !$OMP PARALLEL DEFAULT(SHARED) &",
            "    !$OMP PRIVATE(i)",
            "    ! comment",
            "    CALL CD_Fatal_Thread_Init() ! note",
            "    !$OMP DO SCHEDULE(STATIC)",
            "    DO i = 1, n",
            "      x(i) = 0",
            "    END DO",
            "    !$OMP END DO",
            "    !$OMP END PARALLEL",
        ]
        self.assertEqual(check(good), (1, []))

    def test_the_scan_refuses_missing_combined_and_per_iteration_calls(self) -> None:
        bad = [
            "  !$OMP PARALLEL DO",
            "  DO i = 1, n",
            "    CALL CD_Fatal_Thread_Init()",
            "  END DO",
            "  !$OMP PARALLEL",
            "  x = 1",
            "  !$OMP END PARALLEL",
        ]
        found, problems = check(bad)
        self.assertEqual(found, 2)
        self.assertEqual([p.split(":")[0] for p in problems], ["1", "3", "5"], problems)


if __name__ == "__main__":
    unittest.main()
