"""Command-line interface for pyDEXPI.

Exposes a practical subset of pyDEXPI's functionality through a clean,
user-friendly terminal interface built with `Typer`_.

Available commands
------------------
* ``pydexpi info``          — print a model summary (equipment, lines, instruments).
* ``pydexpi validate``      — run every validation rule, reporting file:line per finding.
* ``pydexpi convert``       — convert between DEXPI XML and JSON (``--fast`` skips validation).
* ``pydexpi svg``           — render a P&ID diagram to SVG.
* ``pydexpi export-table``  — export equipment / line / instrument tables.
* ``pydexpi export-graph``  — export the plant graph at a chosen abstraction level.
* ``pydexpi diff``          — compare two model states by stable id (``--json``, ``--patch``).
* ``pydexpi git-projection`` — print stable review text of a model, for Git.

Plug-ins add commands: each callable declared under the entry-point group
``pydexpi.cli_plugins`` is called with the Typer app, and ``diff --patch`` prints with the
writer declared under ``pydexpi.patch_writers``. Without an installed writer, ``--patch``
exits 2.

Every command that loads a model takes ``--lenient`` (``strict=False``), which a DEXPI 2.0
process export usually needs. Run ``pydexpi --help`` or ``pydexpi <command> --help`` for full
option details.

.. _Typer: https://typer.tiangolo.com/
"""

import logging
from collections import Counter
from collections.abc import Callable
from enum import StrEnum
from importlib import metadata
from pathlib import Path
from typing import Annotated, Any

try:
    import typer
except ImportError:  # pragma: no cover
    raise SystemExit(
        "The pyDEXPI CLI requires the 'cli' extra.\nInstall it with:  pip install pydexpi[cli]"
    ) from None

logger = logging.getLogger(__name__)

#: The entry-point group of a CLI plug-in: a callable ``register(app: typer.Typer) -> None``
#: that adds its commands to the app.
CLI_PLUGIN_GROUP = "pydexpi.cli_plugins"

#: The entry-point group of what ``diff --patch`` prints with: a callable
#: ``write_patch(old_model, new_model, *, exit_code: bool) -> None``.
PATCH_WRITER_GROUP = "pydexpi.patch_writers"

_APP_SETTINGS: dict[str, Any] = {
    "name": "pydexpi",
    "help": "pyDEXPI CLI — work with DEXPI P&ID models from the terminal.",
    "add_completion": False,
}

#: The core's commands are registered on this app; :func:`build_app` makes the one that runs.
_core_app = typer.Typer(**_APP_SETTINGS)


def discover_plugins(group: str) -> list[Callable[..., Any]]:
    """The callables installed under the entry-point *group*, in the order of their names.

    An entry point that fails to load is skipped, with a warning naming it and the error: one
    broken plug-in must not take the CLI down, and nothing else would say its commands are
    missing.
    """
    plugins: list[Callable[..., Any]] = []
    for entry_point in sorted(metadata.entry_points(group=group), key=lambda point: point.name):
        try:
            plugins.append(entry_point.load())
        except Exception:
            logger.warning(
                "Skipping the pyDEXPI CLI plug-in %r (%s): it failed to load.",
                entry_point.name,
                entry_point.value,
                exc_info=True,
            )
            # The CLI configures no logging handler, so say it where its user looks.
            typer.echo(
                f"Warning: the plug-in {entry_point.name!r} ({entry_point.value}) failed to "
                "load; its commands are not available.",
                err=True,
            )
    return plugins


# ---------------------------------------------------------------------------
# Enum helpers for option validation
# ---------------------------------------------------------------------------


class ConvertFormat(StrEnum):
    """Supported conversion output formats."""

    xml = "xml"
    json = "json"


class GraphLevel(StrEnum):
    """Graph abstraction levels: the keys of ``graph_loader.GRAPH_LEVELS`` (a test keeps them equal).

    ``complete``, ``process`` and ``conceptual`` abstract a P&ID; ``process_flow`` is a DEXPI
    ProcessModel's steps and connections.
    """

    complete = "complete"
    process = "process"
    conceptual = "conceptual"
    process_flow = "process_flow"


class GraphFormat(StrEnum):
    """Supported graph output formats."""

    graphml = "graphml"
    json = "json"


class TableFormat(StrEnum):
    """Supported table output formats."""

    xlsx = "xlsx"
    csv = "csv"
    json = "json"


class TableList(StrEnum):
    """Selectable table lists."""

    all = "all"
    equipment = "equipment"
    line = "line"
    instrument = "instrument"
    piping_component = "piping component"
    valve = "valve"


class TableLanguage(StrEnum):
    """Supported table export languages."""

    en = "en"
    de = "de"
    nl = "nl"
    zh = "zh"


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_FORMAT_MAP = {
    TableFormat.xlsx: ".xlsx",
    TableFormat.csv: ".csv",
    TableFormat.json: ".json",
}

#: The ``--lenient`` option, shared by every command that loads a model through
#: :func:`_load_model`. It is ``strict=False`` on the loaders.
Lenient = Annotated[
    bool,
    typer.Option(
        "--lenient",
        help="Keep objects that omit an attribute DEXPI makes mandatory instead of discarding "
        "them (strict=False). DEXPI process exports usually need this: they routinely omit the "
        "mandatory Identifier. The loader records each omission; the CLI prints only how many "
        "issues it recorded, to stderr (without --lenient too, when the loader left something "
        "out). Proteus XML ignores it.",
    ),
]


def _load_model(file: Path, *, lenient: bool = False) -> "EngineeringModel":  # noqa: F821
    """Load a DEXPI model from an XML or JSON file.

    Uses the public convenience functions from ``pydexpi.loaders.public``
    so that each call gets a fresh serializer instance with no shared state.

    Parameters
    ----------
    file : Path
        Path to the input file (XML or JSON).
    lenient : bool, optional
        Load with ``strict=False``: an object omitting a mandatory attribute is kept rather than
        discarded, and a one-line count of the issues the loader recorded is written to stderr
        (the entries themselves are what ``load_xml_with_report`` / ``load_json_with_report``
        return). A strict load writes that line too when an entry is at ERROR or CRITICAL, which
        is data the document holds and the model does not. Default is ``False``.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    typer.BadParameter
        If *file* does not exist or has an unsupported extension.
    typer.Exit
        With code 1, when a strict load refuses a DEXPI 2.0 document that DEXPI 2.0.1 cannot
        represent without copying or dropping data; the reason is written to stderr.
    """
    _check_input_file(file)

    from pydexpi.loaders.compat import ConversionRefusedError
    from pydexpi.loaders.error_registry import ErrorLevels
    from pydexpi.loaders.public import load_json_with_report, load_xml_with_report

    try:
        if file.suffix.lower() == ".xml":
            report = load_xml_with_report(file.read_bytes(), strict=not lenient)
            reader = "load_xml_with_report"
        else:
            report = load_json_with_report(file.read_text(encoding="utf-8"), strict=not lenient)
            reader = "load_json_with_report"
    except ConversionRefusedError as refusal:
        typer.echo(f"{file.name}: {refusal}", err=True)
        raise typer.Exit(1) from refusal
    # A strict load says so too when the loader left something out: an entry at ERROR or
    # CRITICAL is DEXPI data the model does not hold, and the command's own output cannot show it.
    lost = any(entry.level in (ErrorLevels.ERROR, ErrorLevels.CRITICAL) for entry in report.errors)
    if lenient or lost:
        levels = Counter(str(entry.level) for entry in report.errors)
        breakdown = ", ".join(f"{level}: {levels[level]}" for level in sorted(levels))
        typer.echo(
            ("--lenient: " if lenient else "")
            + f"the loader recorded {len(report.errors)} issue(s) for {file.name}"
            + (f" ({breakdown})" if breakdown else "")
            + f"; pydexpi.loaders.public.{reader} returns them.",
            err=True,
        )
    return report.model


def _announce_written(output: Path, target: "ConvertFormat") -> None:
    """Report a successful conversion.

    Called from both conversion routes, which write through the same serialization elements
    and so produce the same document.
    """
    typer.echo(f"Converted to {target.value}: {output}")


def _is_proteus_xml(file: Path) -> bool:
    """Report whether *file* is a Proteus XML document rather than DEXPI 2.0 XML.

    Uses the same ``PlantInformation`` probe that ``pydexpi.loaders.public`` uses to route
    to ``ProteusSerializer``, so the CLI and the loader always agree about what a file is.

    Parameters
    ----------
    file : Path
        Path to the file to inspect. A non-XML file is never Proteus.

    Returns
    -------
    bool
        True if the document is Proteus XML.
    """
    if file.suffix.lower() != ".xml":
        return False

    from pydexpi.loaders.public import _has_plant_information_tag

    try:
        return _has_plant_information_tag(file.read_bytes())
    except OSError:
        return False


def _check_input_file(file: Path) -> None:
    """Raise ``typer.BadParameter`` unless *file* exists and is an XML or JSON file.

    Parameters
    ----------
    file : Path
        Path to the input file.

    Raises
    ------
    typer.BadParameter
        If *file* does not exist or has an unsupported extension.
    """
    if not file.exists():
        raise typer.BadParameter(f"File not found: {file}")
    suffix = file.suffix.lower()
    if suffix not in (".xml", ".json"):
        raise typer.BadParameter(f"Unsupported file format '{suffix}'. Use .xml or .json.")


def _ensure_parent(path: Path) -> None:
    """Create parent directories for *path* if they do not exist."""
    path.parent.mkdir(parents=True, exist_ok=True)


def _convert_without_model(file: Path, output: Path, target: "ConvertFormat") -> bool:
    """Convert *file* to *output* directly, without building a pyDEXPI model.

    Uses ``FormatConverter`` to translate one serialization element tree into another.
    This skips pydantic validation and preserves the source ids rather than generating
    new ones, but only works for the tree-reference formats (DEXPI XML and JSON).

    Parameters
    ----------
    file : Path
        Path to the input file.
    output : Path
        Path to write the converted document to.
    target : ConvertFormat
        The output format.

    Returns
    -------
    bool
        True if the conversion succeeded and *output* was written. False if the input is
        not something the converter can handle -- Proteus XML, or a document using DEXPI
        classes pyDEXPI does not model -- in which case the reason is reported and the
        caller should fall back to the validated route.

    Raises
    ------
    typer.Exit
        With code 1, writing nothing, when the input is DEXPI 2.0. The fast route rewrites a
        document without converting it, so its output would declare DEXPI 2.0.1 over DEXPI 2.0
        content; the validated route reads it as 2.0.1 instead.
    """
    from pydexpi import DEXPI_SPEC_VERSION
    from pydexpi.loaders.compat import DEXPI_2_0, json_reading_version, xml_reading_version
    from pydexpi.loaders.json_serializer import (
        JsonDeserializationElement,
        JsonSerializationElement,
    )
    from pydexpi.loaders.tree_ref_base import FormatConverter
    from pydexpi.loaders.xml_serializer import (
        DexpiXmlDeserializationElement,
        DexpiXmlModelMetadata,
        DexpiXmlSerializationElement,
    )

    try:
        content = file.read_text(encoding="utf-8")
        if file.suffix.lower() == ".xml":
            element = DexpiXmlDeserializationElement.load_from_string(content)
            version = xml_reading_version(element.element)
        else:
            element = JsonDeserializationElement.load_from_string(content)
            version = json_reading_version(element.data)
    # As below: a document the direct converter cannot read is converted the validated way.
    except Exception as exc:  # noqa: BLE001
        typer.echo(f"Fast conversion unavailable ({exc}); falling back to validated conversion.")
        return False

    if version.declared == DEXPI_2_0:
        typer.echo(
            f"--fast cannot convert {file.name}: the document {version.evidence}, so it is DEXPI "
            f"{DEXPI_2_0}, and --fast rewrites a document without converting it -- its output "
            f"would declare DEXPI {DEXPI_SPEC_VERSION} over DEXPI {DEXPI_2_0} content. Convert "
            f"it without --fast, which reads it as DEXPI {DEXPI_SPEC_VERSION}.",
            err=True,
        )
        raise typer.Exit(1)

    try:
        if target == ConvertFormat.json:
            factory = JsonSerializationElement
        else:
            # DexpiXmlSerializationElement requires metadata; use the same default the
            # DexpiXmlSerializer applies so both routes emit the same document header.
            def factory():
                return DexpiXmlSerializationElement(metadata=DexpiXmlModelMetadata())

        converted = FormatConverter(factory).convert_deser_to_ser(element).export_to_string()
    # Any failure means the fast route cannot be used; fall back to validated conversion.
    # Deliberately blind: the point is that *no* failure of the direct converter should stop the
    # conversion, because the validated route can still do it (BLE001).
    except Exception as exc:  # noqa: BLE001
        typer.echo(f"Fast conversion unavailable ({exc}); falling back to validated conversion.")
        return False

    # newline="" so the fast route writes the document unmodified. Path.write_text takes
    # the text-mode default, which rewrites every line feed to os.linesep and would make
    # --fast emit CRLF on Windows where the validated route (via serializer.save) emits
    # LF.
    with open(output, "w", encoding="utf-8", newline="") as fh:
        fh.write(converted)
    return True


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


@_core_app.command()
def info(
    file: Annotated[Path, typer.Argument(help="Path to a DEXPI XML or JSON file.")],
    lenient: Lenient = False,
) -> None:
    """Print a summary of a DEXPI model.

    Shows counts of equipment, piping network systems, segments and components, and
    instrumentation functions -- or, for a process model, process steps and process connections,
    by kind -- then the equipment and instrument tags. Counts cover the whole model, not only its
    top level. A DEXPI process export usually needs ``--lenient``.
    """
    from pydexpi.toolkits.model_summary import summarize_model

    summary = summarize_model(_load_model(file, lenient=lenient))

    typer.echo(f"File: {file}")
    typer.echo(f"Model type:             {summary.conceptual_model_type or '—'}")
    typer.echo(f"Equipment:              {len(summary.equipment)}")
    typer.echo(f"Piping network systems: {summary.piping_system_count}")
    typer.echo(f"Piping segments:        {summary.piping_segment_count}")
    typer.echo(f"Piping components:      {summary.piping_component_count} (incl. valves)")
    typer.echo(f"Instruments:            {len(summary.instruments)}")
    if summary.process_step_count or summary.process_connection_count:
        typer.echo(f"Process steps:          {summary.process_step_count}")
        typer.echo(f"Process connections:    {summary.process_connection_count}")
        typer.echo(f"  Streams:              {summary.stream_count}")
        typer.echo(f"  Energy flows:         {summary.energy_flow_count}")
        typer.echo(f"  Information flows:    {summary.information_flow_count}")

    if summary.equipment:
        typer.echo("\nEquipment tags:")
        for entry in summary.equipment:
            typer.echo(f"  {entry.type:<30} {entry.tag or '—'}")

    if summary.instruments:
        typer.echo("\nInstrument tags:")
        for entry in summary.instruments:
            typer.echo(f"  {entry.tag or '—'}")


class FailOn(StrEnum):
    """The lowest validation level that makes ``pydexpi validate`` exit with 1."""

    mandatory = "mandatory"
    recommended = "recommended"
    optional = "optional"


def _xml_id_lines(file: Path) -> dict[str, int]:
    """Line of each ``id`` attribute in a DEXPI XML document, for locating validation issues.

    Empty for JSON, and for a document lxml cannot parse (the loader reports that one itself).
    A duplicated id keeps its first line.
    """
    if file.suffix.lower() != ".xml":
        return {}
    from lxml import etree

    from pydexpi.loaders.xml_parsing import parse_xml_file

    try:
        tree = parse_xml_file(file)
    except (OSError, etree.XMLSyntaxError):
        return {}
    lines: dict[str, int] = {}
    for element in tree.getroot().iter():
        element_id = element.get("id")
        if element_id is not None and element.sourceline is not None:
            lines.setdefault(element_id, element.sourceline)
    return lines


def _validate_file(file: Path, *, lenient: bool) -> dict[str, Any]:
    """Load and validate one file, returning a JSON-safe report.

    Loads directly rather than through :func:`_load_model`, which reports only a count of the
    loader's entries: here each entry is part of the result. The report holds ``loader`` (what the loader dropped, defaulted or could not resolve, with
    its source location) and ``issues`` (what the validation rules found, each affected id with
    its line when the file is XML). ``loaded`` is False when nothing could be built.
    """
    import json

    from lxml import etree

    from pydexpi.loaders.compat import ConversionRefusedError
    from pydexpi.loaders.public import load_json_with_report, load_xml_with_report
    from pydexpi.validation import validate

    report: dict[str, Any] = {"file": str(file), "loaded": False, "loader": [], "issues": []}
    try:
        if file.suffix.lower() == ".xml":
            loaded = load_xml_with_report(file.read_bytes(), strict=not lenient)
        else:
            loaded = load_json_with_report(file.read_text(encoding="utf-8"), strict=not lenient)
    except etree.XMLSyntaxError as failure:
        line, column = failure.position
        report["loader"].append(
            {
                "level": "critical",
                "message": f"Not well-formed XML: {failure.msg}",
                "line": line,
                "column": column,
            }
        )
        return report
    except json.JSONDecodeError as failure:
        report["loader"].append(
            {
                "level": "critical",
                "message": f"Not valid JSON: {failure.msg}",
                "line": failure.lineno,
                "column": failure.colno,
            }
        )
        return report
    except (ConversionRefusedError, ValueError) as failure:
        report["loader"].append({"level": "critical", "message": str(failure)})
        return report

    report["loader"] = [
        {
            "level": str(entry.level),
            "message": entry.message,
            "object_id": entry.object_id,
            "element": entry.element,
            "line": entry.line,
            "column": entry.column,
        }
        for entry in loaded.errors
    ]
    report["loaded"] = True
    # An object the document gives no id gets a generated one, which no line holds; the loader
    # may still have located it.
    id_lines = {
        entry["object_id"]: entry["line"]
        for entry in report["loader"]
        if entry["object_id"] and entry["line"]
    }
    id_lines.update(_xml_id_lines(file))
    report["issues"] = [
        {
            "level": issue.level_of_recommendation.value,
            "rule": issue.applied_rule_id,
            "message": issue.short_description,
            "details": issue.long_description,
            "objects": [
                {"id": object_id, "line": id_lines.get(object_id)}
                for object_id in issue.affected_component_ids
            ],
        }
        for issue in validate(loaded.model)
    ]
    return report


def _report_fails(report: dict[str, Any], fail_on: FailOn) -> bool:
    """Whether *report* holds a finding at or above *fail_on*.

    A loader entry at ERROR or CRITICAL always fails: it is data the document holds and the
    model does not.
    """
    from pydexpi.loaders.error_registry import ErrorLevels

    if not report["loaded"] or any(
        entry["level"] in (ErrorLevels.ERROR, ErrorLevels.CRITICAL) for entry in report["loader"]
    ):
        return True
    failing = {
        FailOn.mandatory: {"Mandatory"},
        FailOn.recommended: {"Mandatory", "Recommended"},
        FailOn.optional: {"Mandatory", "Recommended", "Optional"},
    }[fail_on]
    return any(issue["level"] in failing for issue in report["issues"])


@_core_app.command()
def validate(
    files: Annotated[
        list[Path], typer.Argument(help="One or more DEXPI XML or JSON files to validate.")
    ],
    as_json: Annotated[
        bool, typer.Option("--json", help="Print one JSON report per file (machine-readable).")
    ] = False,
    fail_on: Annotated[
        FailOn,
        typer.Option(
            "--fail-on",
            help="Lowest rule level that fails the run. Loader errors always fail.",
            case_sensitive=False,
        ),
    ] = FailOn.mandatory,
    lenient: Lenient = False,
) -> None:
    """Load each file and run every validation rule on it.

    Reports what the loader could not represent (with line and column) and each rule violation
    (with the affected ids and, for XML, their lines). Exits with 0 when every file is clean at
    ``--fail-on``, 1 when a file has a finding at or above it or a loader error, and 2 when a file
    is missing or has an unsupported extension.
    """
    import json

    for file in files:
        _check_input_file(file)

    reports = [_validate_file(file, lenient=lenient) for file in files]
    if as_json:
        _write_stdout(json.dumps(reports if len(reports) > 1 else reports[0], indent=2) + "\n")
    else:
        for report in reports:
            _echo_validation_report(report)
    if any(_report_fails(report, fail_on) for report in reports):
        raise typer.Exit(1)


def _echo_validation_report(report: dict[str, Any]) -> None:
    """Print one file's validation report as ``file:line: level rule message`` lines."""
    name = report["file"]
    for entry in report["loader"]:
        where = f"{name}:{entry['line']}" if entry.get("line") else name
        subject = f" [{entry['object_id']}]" if entry.get("object_id") else ""
        typer.echo(f"{where}: loader {entry['level']}{subject}: {entry['message']}")
    for issue in report["issues"]:
        objects = issue["objects"] or [{"id": None, "line": None}]
        first = objects[0]
        where = f"{name}:{first['line']}" if first["line"] else name
        ids = ", ".join(entry["id"] for entry in objects if entry["id"])
        subject = f" [{ids}]" if ids else ""
        typer.echo(f"{where}: {issue['level']} {issue['rule']}{subject}: {issue['message']}")
    if not report["loaded"]:
        typer.echo(f"{name}: not loaded")
    else:
        typer.echo(
            f"{name}: {len(report['issues'])} issue(s), {len(report['loader'])} loader entr"
            + ("y" if len(report["loader"]) == 1 else "ies")
        )


@_core_app.command()
def convert(
    file: Annotated[
        Path, typer.Argument(help="Path to a DEXPI XML, Proteus XML, or DEXPI JSON file.")
    ],
    output: Annotated[
        Path | None,
        typer.Option("-o", "--output", help="Output file path."),
    ] = None,
    fmt: Annotated[
        ConvertFormat,
        typer.Option(
            "--format",
            "-f",
            help="Output format (xml or json). Inferred from output extension if omitted.",
        ),
    ] = None,
    fast: Annotated[
        bool,
        typer.Option(
            "--fast",
            help="Convert directly without building a pyDEXPI model. Faster and preserves "
            "the source ids, but skips validation. Falls back to the normal route for "
            "input it cannot handle, and refuses a DEXPI 2.0 document, which only the "
            "normal route converts to 2.0.1.",
        ),
    ] = False,
    lenient: Lenient = False,
) -> None:
    """Convert a DEXPI or Proteus file to DEXPI XML or JSON.

    The XML output is DEXPI 2.0.1, the version of pyDEXPI's classes. Proteus XML is
    detected automatically and parsed with ``ProteusSerializer``, so
    ``pydexpi convert proteus.xml -o model.json`` performs a Proteus to DEXPI 2.0.1
    conversion. Proteus is not a tree-reference format, so ``--fast`` does not apply to
    it and the validated route is used instead.

    Proteus ids conventionally contain a hyphen, which the bundled schema's id pattern
    forbids, and the parser preserves source ids verbatim. XML output maps them as it is
    written -- ``Tank-1`` becomes ``Tank_1``, references follow -- so the ids in the file
    satisfy the pattern. JSON output keeps the source spelling, so convert to JSON
    if you need the upstream id verbatim.

    Note that loading Proteus can itself report data loss -- inspect
    ``get_loading_errors()`` via the API if that matters; this command does not surface it.

    If ``--format`` is omitted the target format is inferred from the
    ``--output`` extension, or defaults to the *other* format (XML input
    produces JSON output, and vice-versa).

    By default the file is parsed into a pyDEXPI model and re-serialized, which
    validates it but also assigns a fresh id to every object that did not carry
    one. A DEXPI 2.0 document is read as 2.0.1 on that route. ``--fast``
    translates the document directly instead, preserving it as-is, so it refuses
    a DEXPI 2.0 document: its output would declare 2.0.1 over 2.0 content.
    ``--lenient`` applies to the validated route: a process export that omits
    the mandatory ``Identifier`` otherwise loses most of its objects there (a
    strict load builds 146 objects from the CO2 terminal example, a lenient one
    959), and a DEXPI 2.0 document that 2.0.1 cannot represent without copying
    or dropping data -- the Tennessee Eastman example's ten Compositions that no
    owner claims -- is refused unless it is given.
    """
    from pydexpi.loaders.json_serializer import JsonSerializer
    from pydexpi.loaders.xml_serializer import DexpiXmlSerializer

    _check_input_file(file)

    # Determine target format
    if fmt is not None:
        target = fmt
    elif output is not None:
        ext = output.suffix.lower()
        if ext == ".json":
            target = ConvertFormat.json
        elif ext == ".xml":
            target = ConvertFormat.xml
        else:
            target = ConvertFormat.json if file.suffix.lower() == ".xml" else ConvertFormat.xml
    else:
        target = ConvertFormat.json if file.suffix.lower() == ".xml" else ConvertFormat.xml

    # Determine output path and normalise the suffix so the echoed path always matches the
    # file that the serializer actually writes. The comparison is case-*sensitive* on
    # purpose: the serializers append a lowercase extension, so `out.XML` is announced as
    # `out.XML` while `out.xml` is what lands on disk, so a reader following the announced
    # path on a case-sensitive filesystem finds nothing there. Uppercase extensions are not
    # hypothetical here -- two files in the DEXPI 1.2 tier use `.XML`.
    if output is None:
        output = file.with_suffix(f".{target.value}")
    else:
        expected_suffix = f".{target.value}"
        if output.suffix != expected_suffix:
            output = output.with_suffix(expected_suffix)

    _ensure_parent(output)

    # Only --fast needs to know, and probing here would parse every XML input a second
    # time on the normal route.
    from_proteus = fast and _is_proteus_xml(file)

    if from_proteus:
        # FormatConverter translates between tree-reference formats, and Proteus is not
        # one of them. Say so plainly rather than letting it fail with "No Object element
        # found in XML data", which does not explain anything.
        typer.echo(
            "Proteus input cannot use --fast: it is not a tree-reference format and has to "
            "be parsed into a model. Using the validated route."
        )
    elif fast and _convert_without_model(file, output, target):
        _announce_written(output, target)
        return

    model = _load_model(file, lenient=lenient)

    if target == ConvertFormat.json:
        serializer = JsonSerializer()
        serializer.save(model, output.parent, output.name)
    else:
        serializer = DexpiXmlSerializer()
        serializer.save(model, output.parent, output.stem)

    _announce_written(output, target)


@_core_app.command()
def svg(
    file: Annotated[Path, typer.Argument(help="Path to a DEXPI XML or JSON file.")],
    output: Annotated[
        Path | None,
        typer.Option("-o", "--output", help="Output SVG file path."),
    ] = None,
    pretty: Annotated[
        bool,
        typer.Option("--pretty", help="Enable pretty mode (thinner lines, A3 scaling)."),
    ] = False,
    lenient: Lenient = False,
) -> None:
    """Render a DEXPI P&ID diagram to SVG.

    Wraps ``DrawDiagram.save_svg()`` to produce a vector image of the
    first diagram in the model.
    """
    from pydexpi.exports.svg_export import DrawDiagram

    model = _load_model(file, lenient=lenient)

    if not model.diagram:
        typer.echo("Error: model has no diagram data.", err=True)
        raise typer.Exit(code=1)

    diagram = model.diagram[0] if isinstance(model.diagram, list) else model.diagram

    if output is None:
        output = file.with_suffix(".svg")

    _ensure_parent(output)

    drawer = DrawDiagram(diagram, pretty=pretty)
    drawer.save_svg(object_name=file.stem, filepath=str(output))
    typer.echo(f"SVG saved: {output}")


@_core_app.command("export-table")
def export_table(
    file: Annotated[Path, typer.Argument(help="Path to a DEXPI XML or JSON file.")],
    output: Annotated[
        Path | None,
        typer.Option(
            "-o",
            "--output",
            help="Output path stem (without extension). E.g. 'tables' produces 'tables.xlsx'.",
        ),
    ] = None,
    lists: Annotated[
        list[TableList] | None,
        typer.Option("--list", "-l", help="Which list(s) to include. Repeat for multiple."),
    ] = None,
    fmt: Annotated[
        TableFormat,
        typer.Option("--format", "-f", help="Output format."),
    ] = TableFormat.xlsx,
    language: Annotated[
        TableLanguage,
        typer.Option(
            "--language", help="Language for sheet names, column headers, and title-block labels."
        ),
    ] = TableLanguage.en,
    plain: Annotated[
        bool,
        typer.Option(
            "--plain",
            help="Skip the industrial Excel styling (title block, headers, print setup).",
        ),
    ] = False,
    lenient: Lenient = False,
) -> None:
    """Export equipment, line, instrument, piping-component, or valve tables.

    Wraps ``export_tables()`` from ``pydexpi.exports.table_export``.
    """
    from pydexpi.exports.table_export import export_tables

    model = _load_model(file, lenient=lenient)

    if output is None:
        output = file.with_suffix("")

    _ensure_parent(output)

    list_values = [li.value for li in lists] if lists else ["all"]

    export_tables(
        model,
        path_stem=str(output),
        lists=list_values,
        formats=[_FORMAT_MAP[fmt]],
        language=language.value,
        styled=not plain,
    )
    typer.echo(f"Tables exported ({fmt.value}): {output}{_FORMAT_MAP[fmt]}")


@_core_app.command("export-graph")
def export_graph(
    file: Annotated[Path, typer.Argument(help="Path to a DEXPI XML or JSON file.")],
    output: Annotated[
        Path | None,
        typer.Option("-o", "--output", help="Output file path."),
    ] = None,
    level: Annotated[
        GraphLevel,
        typer.Option("--level", "-l", help="Graph abstraction level."),
    ] = GraphLevel.complete,
    fmt: Annotated[
        GraphFormat,
        typer.Option("--format", "-f", help="Output format."),
    ] = GraphFormat.graphml,
    namespace_ids: Annotated[
        bool,
        typer.Option(
            "--namespace-ids",
            help="Write node ids as [<namespace>:]<level>:<id>, matching the Neo4j export.",
        ),
    ] = False,
    id_namespace: Annotated[
        str | None,
        typer.Option(
            "--id-namespace",
            help="Namespace separating independent models; requires --namespace-ids.",
        ),
    ] = None,
    lenient: Lenient = False,
) -> None:
    """Export the plant graph at a chosen abstraction level.

    Wraps ``get_graph()`` from the public API and serialises to GraphML
    (via NetworkX) or JSON (``node-link`` format). ``--level process_flow`` exports a DEXPI
    process model's steps and connections, one edge per connection keyed by its id: GraphML
    writes the key as the edge ``id``, node-link JSON as the link's ``key``. Step details,
    instrumentation activities and the instrumentation systems that compose them are nodes too.

    ``--namespace-ids`` gives GraphML the same node identity the Neo4j export uses --
    ``[<namespace>:]<level>:<dexpi id>``, with the raw id kept as a ``sourceId`` attribute -- so the
    two can be joined. Off by default, because it changes every id in the file and existing
    Gephi / yEd / Cytoscape workflows read the bare one.
    """
    import json

    import networkx as nx

    from pydexpi.exports.graphml_export import (
        namespace_graphml_ids,
        normalize_graphml_attributes,
    )
    from pydexpi.loaders.public import get_graph

    model = _load_model(file, lenient=lenient)

    if output is None:
        output = file.with_suffix(f".{fmt.value}")

    _ensure_parent(output)

    graph = get_graph(model, graph_level=level.value)

    # Applied before the format branch, on purpose: node-link JSON has node ids too, so an option
    # that only took effect for GraphML would silently do nothing for `--format json`.
    if id_namespace is not None and not namespace_ids:
        raise typer.BadParameter(
            "--id-namespace requires --namespace-ids; without it the ids would be written "
            "bare and the namespace silently dropped."
        )
    if namespace_ids:
        graph = namespace_graphml_ids(graph, level.value, id_namespace)

    if fmt == GraphFormat.graphml:
        if output.suffix.lower() != ".graphml":
            output = output.with_suffix(".graphml")
        # This route builds its own graph rather than going through export_graphml_bytes, so
        # it needs the same boundary check -- otherwise `pydexpi export-graph --format graphml`
        # is a way to hit networkx's whole-document refusal with no idea which attribute
        # caused it.
        normalize_graphml_attributes(graph)
        nx.write_graphml(graph, str(output))
    else:
        if output.suffix.lower() != ".json":
            output = output.with_suffix(".json")
        data = nx.node_link_data(graph)
        with open(output, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, default=str)

    typer.echo(f"Graph exported ({level.value}, {fmt.value}): {output}")


# ---------------------------------------------------------------------------
# Versioning: diff, git-projection
# ---------------------------------------------------------------------------


class IdPolicyOption(StrEnum):
    """Which ids the Git projection trusts across revisions."""

    source = "source"
    all = "all"


def _write_stdout(text: str) -> None:
    """Write *text* as UTF-8 bytes, so no platform newline translation touches it.

    ``git-projection`` is meant to be a Git ``textconv``: CRLFs on Windows would make every line
    differ from the same projection written on Linux.
    """
    import sys

    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.flush()


def _describe(entry) -> str:
    tag = f" {entry.tag}" if entry.tag else ""
    object_id = getattr(entry, "object_id", None) or entry.object_id_2
    return f"{entry.object_type}{tag} ({object_id})"


@_core_app.command()
def diff(
    old: Annotated[Path, typer.Argument(help="The old model: DEXPI XML or JSON.")],
    new: Annotated[Path, typer.Argument(help="The new model: DEXPI XML or JSON.")],
    as_json: Annotated[
        bool, typer.Option("--json", help="Print the DiffResult as JSON (machine-readable).")
    ] = False,
    as_patch: Annotated[
        bool,
        typer.Option(
            "--patch",
            help="Print the patch that turns OLD into NEW, as an installed patch writer "
            "writes it (exits 2 when none is installed).",
        ),
    ] = False,
    semantic_only: Annotated[
        bool, typer.Option("--semantic-only", help="Leave out graphics and metadata changes.")
    ] = False,
    order: Annotated[
        bool,
        typer.Option(
            "--order",
            help="Also report reorders of a segment's items and connections (flow order). "
            "Lists DEXPI declares ordered are always compared.",
        ),
    ] = False,
    exit_code: Annotated[
        bool,
        typer.Option(
            "--exit-code",
            help="Exit with 1 if the models differ, like git diff. The status compares every "
            "ordered list, flow order included, whether or not --order is given; what is "
            "printed does not change. Only an unordered list's order is not a difference "
            "to it.",
        ),
    ] = False,
    lenient: Lenient = False,
) -> None:
    """Compare two model states by stable id.

    Prints what was added, removed, moved and modified. ``--json`` gives the machine-readable
    DiffResult; ``--patch`` hands both models to an installed patch writer. Both models must share
    their ids -- revisions of one model saved as JSON. Two independent exports of a
    third-party file re-mint many ids on every load, and compare as mostly added and removed.
    """
    from pydexpi.diff import id_diff

    if as_json and as_patch:
        raise typer.BadParameter("--json and --patch are exclusive: pick one output.")
    if as_patch and (semantic_only or order):
        # A patch reproduces the whole change, so a partial view of it is refused rather than
        # the option ignored.
        raise typer.BadParameter(
            "--patch always reproduces the whole change; it cannot be combined with "
            "--semantic-only or --order."
        )
    write_patch = None
    if as_patch:
        writers = discover_plugins(PATCH_WRITER_GROUP)
        if not writers:
            typer.echo(
                "Error: --patch needs an installed patch writer (entry-point group "
                "pydexpi.patch_writers); none is installed.",
                err=True,
            )
            raise typer.Exit(2)
        write_patch = writers[0]
    old_model = _load_model(old, lenient=lenient)
    new_model = _load_model(new, lenient=lenient)

    if write_patch is not None:
        write_patch(old_model, new_model, exit_code=exit_code)
        return

    result = id_diff(old_model, new_model, track_order=order)
    if semantic_only:
        result = result.semantic_only()
    # --exit-code answers "do the models differ?", and a reordered segment is a difference --
    # compare_models reports it -- so the status tracks order on every ordered list. It is
    # taken from its own diff, so --exit-code never changes what is printed. An unordered
    # list's order is not a difference here.
    differs = result.has_changes
    if exit_code and not order and not differs:
        status = id_diff(old_model, new_model, track_order=True)
        differs = (status.semantic_only() if semantic_only else status).has_changes
    if as_json:
        _write_stdout(result.model_dump_json(indent=2) + "\n")
    else:
        for title, entries, mark in (
            ("Added", result.added_objects, "+"),
            ("Removed", result.removed_objects, "-"),
            ("Moved", result.moved_objects, ">"),
            ("Modified", result.modified_objects, "~"),
        ):
            if not entries:
                continue
            typer.echo(f"{title} ({len(entries)})")
            for entry in entries:
                line = f"  {mark} {_describe(entry)}"
                if mark == ">":
                    line += (
                        f": {entry.old_parent_id}.{entry.old_container_attribute}"
                        f" -> {entry.new_parent_id}.{entry.new_container_attribute}"
                    )
                elif mark == "~":
                    line += ": " + ", ".join(change.attribute_name for change in entry.changes)
                typer.echo(line)
        typer.echo(
            f"{len(result.added_objects)} added, {len(result.removed_objects)} removed, "
            f"{len(result.moved_objects)} moved, {len(result.modified_objects)} modified"
        )
    if exit_code and differs:
        raise typer.Exit(1)


@_core_app.command("git-projection")
def git_projection(
    file: Annotated[Path, typer.Argument(help="Path to a DEXPI XML or JSON file.")],
    id_policy: Annotated[
        IdPolicyOption,
        typer.Option(
            "--id-policy",
            help="'source': trust ids not shaped like generated ones (XML exports). "
            "'all': trust every id (models kept as JSON with stable ids).",
        ),
    ] = IdPolicyOption.source,
    no_graphics: Annotated[
        bool, typer.Option("--no-graphics", help="Leave the drawing out.")
    ] = False,
    output: Annotated[
        Path | None, typer.Option("-o", "--output", help="Write to a file instead of stdout.")
    ] = None,
    lenient: Lenient = False,
) -> None:
    """Print a stable, reviewable text projection of a model, for Git.

    Small model changes give small text diffs, and the same model gives the same text however it
    was serialized. Use it as a Git textconv driver (see the CLI docs). It is a review view: it is
    not read back, and a textual diff of it is not a patch.
    """
    from pydexpi.versioning import model_to_projection

    loaded = _load_model(file, lenient=lenient)
    try:
        text = model_to_projection(
            loaded, id_policy=id_policy.value, include_graphics=not no_graphics
        )
    except ValueError as error:
        # The model itself cannot be projected: two objects share an id, or one object is
        # composed under two parents (a lenient load keeps both). Say so, not a traceback.
        typer.echo(f"Cannot project {file.name}: {error}", err=True)
        raise typer.Exit(1) from error
    if output is None:
        _write_stdout(text)
        return
    _ensure_parent(output)
    output.write_bytes(text.encode("utf-8"))
    typer.echo(f"Projection written: {output}")


#: What every app gets before its plug-ins: the commands registered above, in their order.
_CORE_COMMANDS = tuple(_core_app.registered_commands)


def build_app() -> typer.Typer:
    """The CLI: the core's commands, then every installed plug-in's (:data:`CLI_PLUGIN_GROUP`).

    A plug-in may place its commands among the core's in the help, by rearranging
    ``app.registered_commands``.
    """
    built = typer.Typer(**_APP_SETTINGS)
    built.registered_commands.extend(_CORE_COMMANDS)
    for register in discover_plugins(CLI_PLUGIN_GROUP):
        register(built)
    return built


def __getattr__(name: str) -> typer.Typer:
    """Build ``app``, the ``pydexpi`` console script, on first access.

    Lazily, so that a plug-in may import this module's helpers at its own import time: the
    plug-ins are loaded only once this module has finished initialising, whichever of the two
    was imported first.
    """
    if name == "app":
        built = globals()["app"] = build_app()
        return built
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


if __name__ == "__main__":
    build_app()()
