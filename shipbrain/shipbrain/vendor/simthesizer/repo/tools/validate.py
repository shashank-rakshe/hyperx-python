#!/usr/bin/env python3
"""Compare engine observations and record validation decisions."""

import argparse
import json
from pathlib import Path

from validation.bundles import pair
from validation.capture import run_sim
from validation.decisions import ACTIONS, check_decision, write_decision
from validation.inspection import inspect_report
from validation.validator import compare, write_report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    capture = sub.add_parser("run-sim", help="capture native scheduler observations")
    for name in ("binary", "config", "workload", "environment", "out"):
        capture.add_argument("--" + name, type=Path, required=True)
    capture.add_argument("--duration", type=float, required=True)
    capture.add_argument("--interval", type=float, default=0.1)
    capture.add_argument("--revision", required=True)
    build = sub.add_parser("pair", help="pair complete engine observation bundles")
    for name in ("reference", "candidate", "out"):
        build.add_argument("--" + name, type=Path, required=True)
    build.add_argument("--comparison", dest="policy", type=Path, required=True)
    build.add_argument("--case-id", required=True)
    build.add_argument("--data-kind", required=True)
    build.add_argument("--allow-heldout", action="store_true")

    comparison = sub.add_parser("compare", help="write engine comparison evidence")
    comparison.add_argument("case", type=Path)
    comparison.add_argument("--out", type=Path, required=True)
    comparison.add_argument("--check-acceptance", action="store_true")

    inspect = sub.add_parser("inspect", help="read bounded findings and time bins")
    inspect.add_argument("report", type=Path)
    inspect.add_argument("--metric")
    inspect.add_argument("--start", type=float)
    inspect.add_argument("--end", type=float)
    inspect.add_argument("--limit", type=int, default=3)
    inspect.add_argument("--offset", type=int, default=0)

    decision = sub.add_parser("decide", help="record a judgment and evidence hashes")
    check = sub.add_parser("check", help="check declared state and evidence integrity")
    for command in (decision, check):
        command.add_argument("--task-root", type=Path, required=True)
        command.add_argument(
            "--state", type=Path, default=Path("validation-state.json")
        )
    decision.add_argument("--action", choices=ACTIONS, required=True)
    decision.add_argument("--reason", required=True)
    decision.add_argument("--evidence", type=Path, action="append", required=True)
    decision.add_argument("--pending-check", action="append", default=[])
    decision.add_argument("--next-step")
    decision.add_argument("--blocker")
    check.add_argument("--previous-digest", help="reject an unchanged decision")
    args = parser.parse_args(argv)

    try:
        if args.command == "run-sim":
            run_sim(args)
            print(args.out / "bundle.json")
            return 0
        if args.command == "compare":
            report = compare(args.case, check_acceptance=args.check_acceptance)
            write_report(report, args.out)
            print(
                f"{report['case_id']}: {report['analysis_status']} ({args.out / 'report.html'})"
            )
            if args.check_acceptance:
                status = report["acceptance_check"]["status"]
                print(f"Acceptance check: {status}")
                return {"PASS": 0, "FAIL": 2, "INCOMPLETE": 3}[status]
            return 0
        if args.command == "pair":
            pair(args)
            print(args.out / "case.json")
            return 0
        if args.command == "inspect":
            result = inspect_report(args)
        elif args.command == "decide":
            result = write_decision(args)
        else:
            result = check_decision(args.task_root, args.state, args.previous_digest)
        print(json.dumps(result, indent=2, allow_nan=False))
        if args.command == "check":
            return {"COMPLETE": 0, "BLOCKED": 2, "CONTINUE": 3}[result["status"]]
        return 0
    except (OSError, KeyError, TypeError, ValueError) as exc:
        print(f"Invalid input or report error: {exc}")
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
