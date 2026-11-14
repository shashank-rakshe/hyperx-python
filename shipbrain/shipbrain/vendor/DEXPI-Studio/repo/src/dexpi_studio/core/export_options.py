"""The options each pyDEXPI export takes, as Studio offers them.

Each option is a keyword argument of the pyDEXPI export function, with the values that
function accepts. The values come from pyDEXPI where it publishes them (the graph levels,
the table languages), so a level or a language pyDEXPI adds appears here without a change.
``run_export`` passes the chosen values through unchanged.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

OptionKind = Literal["choice", "multi", "flag"]


@dataclass(frozen=True)
class ExportOption:
    """One option of an export.

    Attributes
    ----------
    key : str
        The keyword argument of the pyDEXPI export function.
    label : str
        What the option is called in the dialog.
    kind : {"choice", "multi", "flag"}
        One value of ``choices``, any non-empty set of them, or on/off.
    choices : tuple of (value, label)
        The values the export accepts, with what the dialog shows for each.
    default : str, tuple of str or bool
        The value pyDEXPI uses when the option is not given.
    help : str
        A tooltip.
    """

    key: str
    label: str
    kind: OptionKind
    choices: tuple[tuple[str, str], ...] = ()
    default: str | tuple[str, ...] | bool = ""
    help: str = ""


#: What the dialog calls each graph level. A level pyDEXPI has and this does not name is
#: shown by its own name.
_GRAPH_LEVEL_LABELS: dict[str, str] = {
    "complete": "Complete: every object of the model",
    "process": "Process (P&ID): equipment, piping components and instruments, pipes as edges",
    "conceptual": "Conceptual (P&ID): as Process, without nozzles and equipment internals",
    "process_flow": "Process flow (process model): steps, with streams and flows as edges",
}


def _graph_levels() -> tuple[tuple[str, str], ...]:
    from pydexpi.loaders.graph_loader import GRAPH_LEVELS

    return tuple((level, _GRAPH_LEVEL_LABELS.get(level, level)) for level in GRAPH_LEVELS)


def _graph_level_option() -> ExportOption:
    return ExportOption(
        key="graph_level",
        label="Graph level",
        kind="choice",
        choices=_graph_levels(),
        default="complete",
        help=(
            "Which abstraction of the model the graph shows. The P&ID levels are for plant "
            "models; the process flow level is for process models and is empty for a P&ID."
        ),
    )


def _table_options() -> list[ExportOption]:
    from pydexpi.exports.table_locale import SUPPORTED_LANGUAGES

    language_names = {"en": "English", "de": "German", "nl": "Dutch", "zh": "Chinese"}
    return [
        ExportOption(
            key="lists",
            label="Tables",
            kind="multi",
            choices=(
                ("equipment", "Equipment"),
                ("line", "Lines"),
                ("instrument", "Instruments"),
                ("piping component", "Piping components"),
                ("valve", "Valves"),
            ),
            default=("equipment", "line", "instrument", "piping component", "valve"),
            help=(
                "With every table selected, an Excel or JSON file holds them all, one sheet "
                "or key each. Otherwise each selected table gets a file of its own."
            ),
        ),
        ExportOption(
            key="formats",
            label="Formats",
            kind="multi",
            choices=((".xlsx", "Excel (.xlsx)"), (".csv", "CSV (.csv)"), (".json", "JSON (.json)")),
            default=(".xlsx",),
            help="CSV writes one file per table.",
        ),
        ExportOption(
            key="language",
            label="Language",
            kind="choice",
            choices=tuple((code, language_names.get(code, code)) for code in SUPPORTED_LANGUAGES),
            default="en",
            help="Language of sheet names, column headers and multi-language values.",
        ),
        ExportOption(
            key="styled",
            label="Styled Excel layout",
            kind="flag",
            default=True,
            help="Title block from the model's metadata, styled headers, filters and print setup.",
        ),
    ]


def options_for(export_name: str) -> list[ExportOption]:
    """Return the options of the export named *export_name*, or none."""
    if export_name in {"GraphML", "Neo4j CSV"}:
        return [_graph_level_option()]
    if export_name == "LLM Context":
        return [
            _graph_level_option(),
            ExportOption(
                key="mode",
                label="Content",
                kind="choice",
                choices=(
                    ("graph", "Graph: nodes and edges with their attributes"),
                    ("topology", "Topology: nodes and edges only"),
                ),
                default="graph",
            ),
        ]
    if export_name == "Tables":
        return _table_options()
    if export_name == "Git projection":
        return [
            ExportOption(
                key="id_policy",
                label="Ids to trust",
                kind="choice",
                choices=(
                    ("source", "The source document's (for a model loaded from XML)"),
                    ("all", "All (for a model kept as JSON, whose ids are stable)"),
                ),
                default="source",
                help=(
                    "A DEXPI XML load mints new ids for objects the file does not identify, "
                    "so only the document's own ids are stable across revisions."
                ),
            ),
            ExportOption(
                key="include_graphics",
                label="Include the drawing",
                kind="flag",
                default=True,
                help="Leave it out for a review of the engineering content alone.",
            ),
        ]
    return []


def default_options(export_name: str) -> dict[str, object]:
    """Return the defaults of every option of *export_name*."""
    return {option.key: option.default for option in options_for(export_name)}
