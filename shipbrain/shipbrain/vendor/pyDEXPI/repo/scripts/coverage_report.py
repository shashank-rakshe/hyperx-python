#!/usr/bin/env python3
"""Render a coverage JSON report as Markdown for the GitHub Actions job summary.

``coverage``'s own terminal report is one row per file, which is 120-odd rows for this project --
too much to read in a job summary and too noisy to compare between runs. This groups the files by
package instead, and lists the least covered files separately, so the summary answers the two
questions a reviewer actually has: what is the number, and where is the gap.

The report is printed to stdout and appended to ``$GITHUB_STEP_SUMMARY`` when that is set, the
same way ``scripts/compare_benchmarks.py`` publishes its own report.

This script only reports. The floor is enforced by pytest-cov during the test run, so this always
exits 0 -- it is meant to run with ``if: always()`` and still say something useful when the run it
is describing has just failed.

Usage
-----
    ./scripts/test                              # writes coverage.json
    python scripts/coverage_report.py coverage.json
"""

import argparse
import json
import os
import sys
import tomllib
from pathlib import Path

#: How many of the least covered files to list in the collapsible section.
DEFAULT_LEAST_COVERED = 20

#: Files with fewer statements than this are left out of the least-covered list. A two-statement
#: module at 0% is noise next to a 300-statement one at 40%.
MIN_STATEMENTS_FOR_LEAST_COVERED = 10

#: Label for the package row holding modules that sit directly in ``pydexpi/``.
ROOT_PACKAGE = "pydexpi (top level)"


class CoverageReportError(Exception):
    """Raised when the coverage report cannot be read or is not in the expected shape."""


def load_report(path: Path) -> dict:
    """Load a coverage JSON report.

    Parameters
    ----------
    path : Path
        Path to the file written by ``coverage json`` / ``--cov-report=json``.

    Returns
    -------
    dict
        The parsed report.

    Raises
    ------
    CoverageReportError
        If the file is missing, is not valid JSON, or lacks the ``files``/``totals`` keys.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise CoverageReportError(f"could not read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CoverageReportError(f"{path} is not valid JSON: {exc}") from exc

    if not isinstance(data, dict) or "files" not in data or "totals" not in data:
        raise CoverageReportError(f"{path} does not look like a coverage JSON report")
    return data


def read_floor(pyproject: Path) -> float | None:
    """Read ``fail_under`` from ``[tool.coverage.report]``.

    Kept in one place on purpose: the workflow does not repeat the number, so the floor the report
    describes is by construction the floor pytest-cov enforces.

    Parameters
    ----------
    pyproject : Path
        Path to ``pyproject.toml``.

    Returns
    -------
    float or None
        The configured floor, or None if the file or the setting is absent.
    """
    try:
        config = tomllib.loads(pyproject.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None
    floor = config.get("tool", {}).get("coverage", {}).get("report", {}).get("fail_under")
    return float(floor) if isinstance(floor, (int, float)) else None


def percentage(covered: int, total: int) -> float:
    """Return ``covered / total`` as a percentage, treating "nothing to cover" as fully covered.

    This is the same combined line-and-branch ratio coverage itself reports, so the total here
    matches the one pytest-cov checks against the floor.
    """
    if total == 0:
        return 100.0
    return 100.0 * covered / total


def package_of(filename: str) -> str:
    """Return the package a source file is grouped under.

    Files directly inside ``pydexpi/`` share a single row, since there are only a handful of them
    and they are unrelated to each other.

    Parameters
    ----------
    filename : str
        Path as recorded in the coverage report, in either separator style.

    Returns
    -------
    str
        The package label, e.g. ``pydexpi/loaders`` or ``pydexpi (top level)``.
    """
    parts = filename.replace("\\", "/").split("/")
    if len(parts) <= 2:
        return ROOT_PACKAGE
    return "/".join(parts[:-1])


def _totals(summaries: list[dict]) -> dict[str, int]:
    """Sum the coverage counters of several file summaries."""
    keys = ("num_statements", "missing_lines", "num_branches", "covered_lines", "covered_branches")
    return {key: sum(int(summary.get(key, 0)) for summary in summaries) for key in keys}


def build_packages(files: dict[str, dict]) -> list[dict]:
    """Aggregate per-file summaries into per-package rows.

    Parameters
    ----------
    files : dict
        The ``files`` mapping from a coverage JSON report.

    Returns
    -------
    list of dict
        One row per package, sorted by name so consecutive runs are easy to compare. The root
        package sorts first.
    """
    grouped: dict[str, list[dict]] = {}
    for filename, entry in files.items():
        grouped.setdefault(package_of(filename), []).append(entry.get("summary", {}))

    rows = []
    for package, summaries in grouped.items():
        counts = _totals(summaries)
        covered = counts["covered_lines"] + counts["covered_branches"]
        total = counts["num_statements"] + counts["num_branches"]
        rows.append(
            {
                "package": package,
                "files": len(summaries),
                "statements": counts["num_statements"],
                "missing": counts["missing_lines"],
                "branches": counts["num_branches"],
                "coverage": percentage(covered, total),
            }
        )
    return sorted(rows, key=lambda row: (row["package"] != ROOT_PACKAGE, row["package"]))


def build_least_covered(files: dict[str, dict], limit: int = DEFAULT_LEAST_COVERED) -> list[dict]:
    """Return the least covered files, worst first.

    Small modules are excluded (see ``MIN_STATEMENTS_FOR_LEAST_COVERED``) so the list points at
    real gaps rather than at short files whose percentage swings on a single line.
    """
    rows = []
    for filename, entry in files.items():
        summary = entry.get("summary", {})
        statements = int(summary.get("num_statements", 0))
        if statements < MIN_STATEMENTS_FOR_LEAST_COVERED:
            continue
        covered = int(summary.get("covered_lines", 0)) + int(summary.get("covered_branches", 0))
        total = statements + int(summary.get("num_branches", 0))
        rows.append(
            {
                "file": filename.replace("\\", "/"),
                "statements": statements,
                "missing": int(summary.get("missing_lines", 0)),
                "coverage": percentage(covered, total),
            }
        )
    rows.sort(key=lambda row: (row["coverage"], -row["statements"], row["file"]))
    return rows[:limit]


def render(report: dict, floor: float | None, limit: int = DEFAULT_LEAST_COVERED) -> str:
    """Render the whole Markdown report.

    Parameters
    ----------
    report : dict
        A parsed coverage JSON report.
    floor : float or None
        The configured ``fail_under`` value, used for the banner. None omits it.
    limit : int, optional
        How many least-covered files to list.

    Returns
    -------
    str
        The Markdown report.
    """
    files = report["files"]
    totals = report["totals"]
    covered = int(totals.get("covered_lines", 0)) + int(totals.get("covered_branches", 0))
    measurable = int(totals.get("num_statements", 0)) + int(totals.get("num_branches", 0))
    total_coverage = percentage(covered, measurable)

    lines = ["## Test coverage", ""]

    if floor is None:
        lines += [
            "> [!NOTE]",
            f"> **{total_coverage:.2f}%** of {measurable:,} statements and branches are covered.",
        ]
    elif total_coverage >= floor:
        lines += [
            "> [!NOTE]",
            (
                f"> **{total_coverage:.2f}%** of {measurable:,} statements and branches are covered,"
                f" against a floor of {floor:g}%."
            ),
        ]
    else:
        lines += [
            "> [!WARNING]",
            (
                f"> **{total_coverage:.2f}%** of {measurable:,} statements and branches are covered,"
                f" below the floor of {floor:g}%. The test run fails until it is back above."
            ),
        ]
    lines += [""]

    lines += [
        "| Package | Files | Statements | Missing | Branches | Coverage |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in build_packages(files):
        flag = " :warning:" if floor is not None and row["coverage"] < floor else ""
        lines.append(
            f"| `{row['package']}` | {row['files']} | {row['statements']:,} |"
            f" {row['missing']:,} | {row['branches']:,} | {row['coverage']:.1f}%{flag} |"
        )
    lines.append(
        f"| **Total** | **{len(files)}** | **{int(totals.get('num_statements', 0)):,}** |"
        f" **{int(totals.get('missing_lines', 0)):,}** |"
        f" **{int(totals.get('num_branches', 0)):,}** | **{total_coverage:.1f}%** |"
    )
    lines.append("")

    least_covered = build_least_covered(files, limit)
    if least_covered:
        lines += [
            f"<details><summary>{len(least_covered)} least covered files</summary>",
            "",
            "| File | Statements | Missing | Coverage |",
            "| --- | ---: | ---: | ---: |",
        ]
        for row in least_covered:
            lines.append(
                f"| `{row['file']}` | {row['statements']:,} | {row['missing']:,} |"
                f" {row['coverage']:.1f}% |"
            )
        lines += ["", "</details>", ""]

    lines += [
        "<details><summary>How to read this</summary>",
        "",
        "Percentages combine line and branch coverage, which is what the floor is checked",
        "against. `Missing` counts unexecuted statements only, so it does not account for the",
        "whole gap on rows with many branches.",
        "",
        "The floor lives in `[tool.coverage.report] fail_under` in `pyproject.toml` and is",
        "enforced by pytest-cov on every run, locally and in CI. It is seeded at the first",
        "measured value rather than an aspirational one: it exists to stop coverage sliding",
        "backwards, so raise it as coverage improves.",
        "",
        "`pydexpi/pydexpi_classes` reads high because it is largely generated pydantic class",
        "declarations, which execute on import. It is a quarter of the codebase, so it lifts the",
        "total noticeably -- read the per-package rows before concluding anything from the",
        "headline number.",
        "",
        "To reproduce locally:",
        "",
        "```sh",
        "pip install -e '.[dev,export,cli]'",
        "./scripts/test",
        "python scripts/coverage_report.py coverage.json",
        "```",
        "",
        "`htmlcov/index.html` from the same run, also uploaded here as an artifact, shows which",
        "lines are uncovered.",
        "",
        "</details>",
        "",
    ]
    return "\n".join(lines)


def emit(report: str, summary_file: str | None) -> None:
    """Print the report and append it to the GitHub step summary if configured."""
    print(report)
    target = summary_file or os.environ.get("GITHUB_STEP_SUMMARY")
    if not target:
        return
    try:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(report + "\n")
    except OSError as exc:  # pragma: no cover - depends on the CI filesystem
        print(f"warning: could not write summary to {target}: {exc}", file=sys.stderr)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Render a coverage JSON report as Markdown for the GitHub Actions job summary."
    )
    parser.add_argument("report", type=Path, help="coverage JSON report, e.g. coverage.json")
    parser.add_argument(
        "--pyproject",
        type=Path,
        default=Path("pyproject.toml"),
        help="where to read the coverage floor from when --fail-under is not given",
    )
    parser.add_argument(
        "--fail-under",
        type=float,
        default=None,
        help="floor to report against; defaults to fail_under from pyproject.toml",
    )
    parser.add_argument(
        "--least-covered",
        type=int,
        default=DEFAULT_LEAST_COVERED,
        help=f"how many of the least covered files to list (default {DEFAULT_LEAST_COVERED})",
    )
    parser.add_argument("--out", type=Path, default=None, help="also write the report here")
    parser.add_argument(
        "--summary-file",
        default=None,
        help="file to append the report to (defaults to $GITHUB_STEP_SUMMARY)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Entry point. Returns the process exit code."""
    args = parse_args(argv)

    try:
        data = load_report(args.report)
    except CoverageReportError as exc:
        # Reported as a warning, not an error: this script runs with `if: always()`, so a missing
        # report usually means the test run already failed and is already red. Failing here too
        # would only add a second, less informative red mark.
        print(f"::warning::coverage report unavailable: {exc}")
        return 0

    floor = args.fail_under if args.fail_under is not None else read_floor(args.pyproject)
    markdown = render(data, floor, args.least_covered)

    if args.out:
        args.out.write_text(markdown, encoding="utf-8")
    emit(markdown, args.summary_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
