"""Summarise a DEXPI model: counts, tags, and validation issues.

The same ground `pydexpi info` covers, plus validation, and with a --json mode so an agent or
script can branch on the result instead of parsing prose.

Usage:
    python .claude/skills/pydexpi/scripts/inspect_model.py MODEL [--json] [--lenient]

MODEL is a DEXPI XML (including Proteus) or JSON file. --lenient loads with strict=False, keeping
objects that omit an attribute DEXPI makes mandatory -- a DEXPI process export usually needs it.
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

from pydexpi import load_json_file, load_xml_file
from pydexpi.loaders.compat import ConversionRefusedError
from pydexpi.toolkits.model_summary import summarize_model
from pydexpi.validation.default_validator import validate

#: How many MANDATORY issues of one rule the human output lists; --json lists them all.
LISTED_PER_RULE = 5


def load(path: Path, lenient: bool = False):
    """Load by extension. .json goes to the JSON serializer, everything else to XML.

    The XML loader detects Proteus by content (a PlantInformation child under PlantModel), so
    Proteus files need no special handling here. *lenient* is ``strict=False``.
    """
    if path.suffix.lower() == ".json":
        return load_json_file(path, strict=not lenient)
    return load_xml_file(path, strict=not lenient)


def summarise(model, path: Path) -> dict:
    """Build the summary as a plain dict, so both output modes render the same numbers.

    The counts are `summarize_model`'s -- the same ones `pydexpi info` and the MCP server report.
    """
    summary = summarize_model(model)
    issues = validate(model)

    return {
        "file": str(path),
        **summary.to_dict(),
        "equipment": [
            {"type": entry.type, "label": entry.display_name, "id": entry.id}
            for entry in summary.equipment
        ],
        "instruments": [
            {"type": entry.type, "label": entry.display_name, "id": entry.id}
            for entry in summary.instruments
        ],
        "validation_issue_count": len(issues),
        "validation_issues_by_level": dict(
            Counter(str(issue.level_of_recommendation) for issue in issues)
        ),
        "mandatory_issues": [
            {
                "rule": issue.applied_rule_id,
                "description": issue.short_description,
                "affected": issue.affected_component_ids,
            }
            for issue in issues
            if str(issue.level_of_recommendation) == "Mandatory"
        ],
    }


def print_human(summary: dict) -> None:
    print(f"File:                   {summary['file']}")
    print(f"Model type:             {summary['conceptual_model_type']}")
    print(f"Equipment:              {summary['equipment_count']}")
    print(f"Piping network systems: {summary['piping_system_count']}")
    print(f"Piping segments:        {summary['piping_segment_count']}")
    print(f"Piping components:      {summary['piping_component_count']} (incl. valves)")
    print(f"Instruments:            {summary['instrument_count']}")
    if summary["process_step_count"] or summary["process_connection_count"]:
        print(f"Process steps:          {summary['process_step_count']}")
        print(f"Process connections:    {summary['process_connection_count']}")
        print(f"  Streams:              {summary['stream_count']}")
        print(f"  Energy flows:         {summary['energy_flow_count']}")
        print(f"  Information flows:    {summary['information_flow_count']}")

    if summary["equipment"]:
        print("\nEquipment:")
        for item in summary["equipment"]:
            print(f"  {item['type']:<30} {item['label']}")

    if summary["instruments"]:
        print("\nInstruments:")
        for item in summary["instruments"]:
            print(f"  {item['type']:<30} {item['label']}")

    print(f"\nValidation issues:      {summary['validation_issue_count']}")
    for level, count in sorted(summary["validation_issues_by_level"].items()):
        print(f"  {level:<12} {count}")
    # A few per rule: a --lenient process export fails the mandatory-attribute rule on hundreds
    # of objects, which would bury every other rule's line. --json lists every one.
    by_rule: dict[str, list[dict]] = {}
    for issue in summary["mandatory_issues"]:
        by_rule.setdefault(issue["rule"], []).append(issue)
    for rule, issues in by_rule.items():
        for issue in issues[:LISTED_PER_RULE]:
            print(f"  ! {rule}: {issue['description']}")
        if len(issues) > LISTED_PER_RULE:
            print(
                f"  ! {rule}: ... {len(issues) - LISTED_PER_RULE} more, {len(issues)} in all "
                "(--json lists every one)"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path, help="Path to a DEXPI XML or JSON file.")
    parser.add_argument("--json", action="store_true", help="Emit the summary as JSON.")
    parser.add_argument(
        "--lenient",
        action="store_true",
        help="Load with strict=False: keep objects that omit a mandatory attribute.",
    )
    args = parser.parse_args()

    if not args.model.exists():
        print(f"No such file: {args.model}", file=sys.stderr)
        return 1

    try:
        model = load(args.model, lenient=args.lenient)
    except ConversionRefusedError as refusal:
        # A DEXPI 2.0 file that 2.0.1 cannot hold whole is refused strictly; --lenient converts it.
        print(refusal, file=sys.stderr)
        return 1
    summary = summarise(model, args.model)

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print_human(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
