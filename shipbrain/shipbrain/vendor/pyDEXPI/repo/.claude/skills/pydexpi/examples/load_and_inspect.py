"""Load a DEXPI model, count what is in it, and validate it.

The starting point for almost any pyDEXPI task: `pydexpi.load_xml_file` for the model,
`model_toolkit.get_all_instances_in_model` to pull out objects by type, `get_display_name`
for captions, `attribute_label` / `enum_value_label` for an object's attributes,
`piping_toolkit.run_items` for a line's items in flow order, and `default_validator.validate`
for the issue list.

Run:
    python .claude/skills/pydexpi/examples/load_and_inspect.py [MODEL] [--out DIR]

MODEL defaults to data/reference_pid.xml. --out is accepted and ignored; this example
writes nothing, but the flag keeps the interface uniform across the examples.
"""

import argparse
from collections import Counter
from enum import Enum
from pathlib import Path

from pydexpi import attribute_label, enum_value_label, get_display_name, load_xml_file
from pydexpi.pydexpi_classes.plant import instrumentation, piping, processEquipment
from pydexpi.pydexpi_classes.pydexpi_classes import PhysicalQuantity
from pydexpi.toolkits import piping_toolkit
from pydexpi.toolkits.base_model_utils import get_data_attributes
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model
from pydexpi.validation.default_validator import validate

DEFAULT_MODEL = Path("data/reference_pid.xml")


def format_value(value: object) -> str:
    """Render a data attribute value the way a user interface would show it."""
    if isinstance(value, PhysicalQuantity):
        # A unit is an enum member too: enum_value_label gives its symbol ("m³/h", "barg").
        return f"{value.value:g} {enum_value_label(value.unit)}"
    if isinstance(value, Enum):
        return enum_value_label(value)  # "Fail close", "DIN 2448 DN 80"
    return str(value)


def print_attributes(obj) -> None:
    """Print the data attributes that carry a value, labelled for a human."""
    print(f"\n{get_display_name(obj)}:")
    for name, value in get_data_attributes(obj).items():
        if value is not None and value != "":
            # attribute_label, not the raw camelCase name: "designVolumeFlowRate" reads as
            # "Design volume flow rate".
            print(f"  {attribute_label(name):<40} {format_value(value)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", nargs="?", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--out", type=Path, default=None, help="Unused; accepted for symmetry.")
    args = parser.parse_args()

    model = load_xml_file(args.model)

    # TaggedPlantItem is the base class that catches pumps, tanks and heat exchangers alike.
    equipment = get_all_instances_in_model(model, processEquipment.TaggedPlantItem)
    systems = get_all_instances_in_model(model, piping.PipingNetworkSystem)
    segments = get_all_instances_in_model(model, piping.PipingNetworkSegment)
    instruments = get_all_instances_in_model(model, instrumentation.ProcessInstrumentationFunction)

    print(f"Model:                  {args.model}")
    print(f"Equipment:              {len(equipment)}")
    print(f"Piping network systems: {len(systems)}")
    print(f"Piping segments:        {len(segments)}")
    print(f"Instruments:            {len(instruments)}")

    # get_display_name is the single source of truth for captions -- do not re-derive a tag
    # from tagName and friends, it is type-aware and covers cases those attributes do not.
    print("\nEquipment:")
    for item in equipment:
        print(f"  {type(item).__name__:<30} {get_display_name(item)}")

    # One pump and one segment, attribute by attribute: quantities, enums and strings.
    pumps = [item for item in equipment if isinstance(item, processEquipment.Pump)]
    for obj in (pumps[:1] or equipment[:1]) + segments[:1]:
        print_attributes(obj)

    # A line in flow order: run_items follows each segment from source to target and carries
    # on through tees along the run, never into a branch. Where a model does not say which way
    # a line goes, it raises rather than guesses, so such lines are skipped here.
    runs = []
    for segment in segments:
        try:
            runs.append(piping_toolkit.run_items(model, segment))
        except (
            piping_toolkit.DexpiCorruptPipingSegmentException,
            piping_toolkit.PipingTraversalException,
        ):
            continue
    longest = max(runs, key=len, default=[])
    print(f"\nLongest line ({len(longest)} items, flow order):")
    for item in longest:
        print(f"  {get_display_name(item)}")

    issues = validate(model)
    by_level = Counter(issue.level_of_recommendation for issue in issues)
    print(f"\nValidation issues: {len(issues)}")
    for level, count in sorted(by_level.items()):
        print(f"  {level:<12} {count}")

    # Only MANDATORY issues mean the model violates the DEXPI specification. RECOMMENDED and
    # OPTIONAL are advisory -- a model carrying them is not broken.
    for issue in issues:
        if issue.level_of_recommendation == "Mandatory":
            print(f"  ! {issue.applied_rule_id}: {issue.short_description}")


if __name__ == "__main__":
    main()
