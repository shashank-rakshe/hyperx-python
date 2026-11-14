"""
This module provides functions and utilities for exporting tables from a EngineeringModel
to various formats (Excel, CSV, JSON). It includes logic for formatting, column ordering,
and attribute extraction for equipment, lines, instruments, and piping components.
"""

import json
from collections.abc import Iterable
from enum import Enum, StrEnum
from pathlib import Path
from typing import Literal

import pandas as pd

from pydexpi.attribution import generator_string
from pydexpi.exports import table_style
from pydexpi.exports.semantic_identity import IDENTITY_COLUMNS, IdentityContext, semantic_frame
from pydexpi.exports.table_locale import (
    float_to_str,
    get_sheet_name,
    normalize_language,
    translate_label,
    unit_symbol,
)
from pydexpi.pydexpi_classes import EngineeringModel, MultiLanguageString, PyDexpiBaseModel
from pydexpi.pydexpi_classes.core import physicalQuantities
from pydexpi.pydexpi_classes.plant import instrumentation, piping, processEquipment
from pydexpi.toolkits.base_model_utils import get_composition_attributes, get_data_attributes
from pydexpi.toolkits.display_labels import humanize_attribute_name
from pydexpi.toolkits.display_name import humanize_class_name, instrument_tag
from pydexpi.toolkits.model_provenance import (
    GENERATOR_KEY,
    flatten_multi_language_string,
    get_model_provenance,
)
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model
from pydexpi.toolkits.quantity_format import value_with_symbol

COLUMN_PRIORITIES = {
    "equipment": ["Tag", "Equipment type"],
    "line": ["Line number", "Segment number"],
    "instrument": ["Tag", "Operated valve", "Sensing location"],
    "piping component": ["Piping component number", "Piping component"],
    "valve": ["Tag", "Valve type", "Nominal diameter"],
}

#: The DEXPI valve base classes. There is no common ``Valve`` class; valves are
#: exactly the subclass trees of these three ``PipingComponent`` children.
VALVE_CLASSES = (piping.OperatedValve, piping.CheckValve, piping.SafetyValveOrFitting)


class ListType(StrEnum):
    """Enum for the different list types that can be exported."""

    EQUIPMENT = "equipment"
    LINE = "line"
    INSTRUMENT = "instrument"
    PIPING_COMPONENT = "piping component"
    VALVE = "valve"
    ALL = "all"


class ExportFormat(StrEnum):
    """Enum for the different export formats."""

    XLSX = ".xlsx"
    CSV = ".csv"
    JSON = ".json"


def export_tables(
    model: EngineeringModel,
    path_stem: str,
    lists: Iterable[Literal["all", "equipment", "line", "instrument", "piping component", "valve"]]
    | None = None,
    formats: Iterable[Literal[".xlsx", ".csv", ".json"]] | None = None,
    *,
    language: str = "en",
    styled: bool = True,
) -> None:
    """
    Main function to build and export selected lists from a EngineeringModel.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model to export tables from.
    path_stem : str
        The path and filename stem for the output files (without extension).
    lists : Iterable of Literal {"all", "equipment", "line", "instrument", "piping component", "valve"}, optional
        The types of lists to export. If ``None``, all lists are exported.
    formats : Iterable of Literal {".xlsx", ".csv", ".json"}, optional
        The formats to export the lists in. If ``None``, defaults to ``.xlsx``.
    language : str, default ``"en"``
        Language for sheet names, column headers, and ``MultiLanguageString``
        values. One of the languages in
        :data:`pydexpi.exports.table_locale.SUPPORTED_LANGUAGES`.
    styled : bool, default ``True``
        Whether ``.xlsx`` output gets the industrial document layout: a title
        block from the model's metadata, styled headers, frozen panes,
        autofilter, and print setup. With ``False`` the data header sits in
        row 1, as in the unstyled legacy layout. When reading a styled sheet
        programmatically, compute the header offset with
        :func:`pydexpi.exports.table_style.data_header_row`.

    Returns
    -------
    None
        Files are written to disk at paths derived from ``path_stem``.
    """
    path_stem = Path(path_stem)
    language = normalize_language(language)
    if lists is None:
        lists = (ListType.ALL,)
    if formats is None:
        formats = (ExportFormat.XLSX,)
    lists = tuple(lists)

    tables = _build_tables(model, language)
    provenance = get_model_provenance(model, preferred_language=language)

    for raw_format in formats:
        format = ExportFormat(raw_format)
        if ListType.ALL in lists:
            # Export all tables in one file
            if format == ExportFormat.XLSX:
                out_path = path_stem.with_suffix(format)
                _write_workbook(tables, out_path, provenance, language, styled)
            elif format == ExportFormat.JSON:
                out_path = path_stem.with_suffix(format)
                # Names the software writing this file, beside the model's own
                # provenance; see model_provenance.GENERATOR_KEY.
                tables_dict = {"metadata": {**provenance, GENERATOR_KEY: generator_string()}}
                tables_dict.update(
                    {
                        key.value: json.loads(df.to_json(orient="records"))
                        for key, df in tables.items()
                    }
                )
                with open(out_path, "w", encoding="utf-8") as f:
                    json.dump(tables_dict, f, indent=4, ensure_ascii=False)
            elif format == ExportFormat.CSV:
                # Export each table as a separate CSV file
                for key, df in tables.items():
                    out_path = path_stem.with_name(f"{path_stem.name}_{key.value}").with_suffix(
                        format
                    )
                    df.to_csv(out_path, index=False)
        else:
            # Export selected tables individually
            multi = len(lists) > 1
            for list_type in lists:
                key = ListType(list_type)
                df = tables[key]
                if multi:
                    out_path = path_stem.with_name(f"{path_stem.name}_{key.value}").with_suffix(
                        format
                    )
                else:
                    out_path = path_stem.with_suffix(format)
                if format == ExportFormat.XLSX:
                    _write_workbook({key: df}, out_path, provenance, language, styled)
                elif format == ExportFormat.JSON:
                    df = df.where(pd.notnull(df), None)
                    df.to_json(out_path, orient="records", indent=4, force_ascii=False)
                elif format == ExportFormat.CSV:
                    df.to_csv(out_path, index=False)


def _write_workbook(
    tables: dict[ListType, pd.DataFrame],
    out_path: Path,
    provenance: dict,
    language: str,
    styled: bool,
) -> None:
    """Write one workbook with a sheet per table, styling it if requested."""
    title_rows = table_style.title_block_rows(provenance, language) if styled else []
    header_row = table_style.data_header_row(provenance, language, styled)
    title_texts = tuple(label for label, _ in title_rows)
    with pd.ExcelWriter(out_path) as writer:
        for key, df in tables.items():
            sheet_name = get_sheet_name(key.value, language)
            df.to_excel(writer, sheet_name=sheet_name, startrow=header_row - 1, index=False)
            ws = writer.sheets[sheet_name]
            first_column_texts = title_texts
            if styled:
                table_style.write_title_block(ws, title_rows, sheet_name)
                table_style.style_table(
                    ws, header_row=header_row, n_rows=len(df), n_cols=len(df.columns)
                )
                # the sheet title in A1 shares column A with the data
                first_column_texts = (sheet_name, *title_texts)
            table_style.set_column_widths(ws, df, first_column_texts)
        if styled:
            table_style.set_workbook_properties(writer.book, provenance)


def reorder_columns(df: pd.DataFrame, priority: list[str]) -> pd.DataFrame:
    """Reorder the columns of a DataFrame based on a given priority list. Sort rest alphabetically.

    Parameters
    ----------
    df : pd.DataFrame
        The DataFrame to reorder.
    priority : list[str]
        The list of column names to prioritize in the order they should appear.

    Returns
    -------
    pd.DataFrame
        The DataFrame with reordered columns.
    """
    cols = df.columns.tolist()
    ordered = [c for c in priority if c in cols]
    remaining = sorted([c for c in cols if c not in ordered])
    return df[ordered + remaining]


def format_string(s: str) -> str:
    """Format pyDEXPI attribute names for display as column headers.

    Delegates to :func:`pydexpi.toolkits.display_labels.humanize_attribute_name`, the single
    implementation of the casing. It deliberately does *not* apply the curated overrides of
    :func:`~pydexpi.toolkits.display_labels.attribute_label`: these headers are the keys of the
    translation tables in :mod:`pydexpi.exports.table_locale`.

    Parameters
    ----------
    s : str
        The original attribute name in camelCase or PascalCase.

    Returns
    -------
    str
        A human-readable label with the first character capitalized and spaces
        inserted before internal capital letters (which are lowercased).
    """
    return humanize_attribute_name(s)


def get_attribute_value(value_object: object, language: str = "en") -> str | None:
    """Resolve a DEXPI data attribute value to a printable string.

    Parameters
    ----------
    value_object : object
        The attribute value: physical quantities, ``MultiLanguageString``,
        ``Enum`` and ``str`` values render; anything else (``None``, the
        ``Undefined`` sentinel, unsupported types) yields ``None``.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.

    Returns
    -------
    str | None
        A string formatted as "<value> <symbol>" for physical quantities (e.g.
        ``"60 m"``), the preferred-language string for MultiLanguageStrings,
        the underlying ``.value`` for Enums, the original string for ``str``
        inputs, or ``None`` if the type is not handled.
    """
    if hasattr(physicalQuantities, value_object.__class__.__name__):
        return value_with_symbol(float_to_str(value_object.value), unit_symbol(value_object.unit))
    elif isinstance(value_object, MultiLanguageString):
        return flatten_multi_language_string(value_object, language)
    elif isinstance(value_object, Enum):
        return value_object.value
    elif isinstance(value_object, str):
        return value_object
    return None


def extend_row_with_subequipment(
    row: dict, comp_object: PyDexpiBaseModel, i: int | None, language: str = "en"
) -> dict:
    """Extend a parent equipment row with sub-equipment data attributes.

    Parameters
    ----------
    row : dict
        The row under construction for the parent equipment.
    comp_object : PyDexpiBaseModel
        The sub-equipment object whose data attributes will be appended.
    i : int | None
        Index of the sub-equipment within a list (used to disambiguate names),
        or ``None`` if the sub-equipment is a single object.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.

    Returns
    -------
    dict
        The updated row containing additional columns for the sub-equipment's
        formatted data attributes.
    """
    # Get the sub equipment tag
    sub_tag = comp_object.subTagName if hasattr(comp_object, "subTagName") else None
    if sub_tag is None:
        sub_tag = humanize_class_name(comp_object.__class__.__name__)
        if i is not None:
            sub_tag += " " + str(i + 1)

    # Get sub equipment data attributes
    data_comp_attributes = get_data_attributes(comp_object)
    for (
        data_comp_name,
        data_comp_value_object,
    ) in data_comp_attributes.items():
        if data_comp_name == "subTagName":
            continue
        formated_data_comp_name = sub_tag + ", " + format_string(data_comp_name)
        sub_value = get_attribute_value(data_comp_value_object, language)
        row[formated_data_comp_name] = sub_value

    return row


def make_equipment_list(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Collect all equipment instances and their attributes as a table.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model containing equipment instances.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        A table where each row represents a tagged plant item and columns include
        identifiers, data attributes, and flattened sub-equipment attributes.
    """
    language = normalize_language(language)
    table = []
    identity = IdentityContext(model)
    tagged_plant_items = get_all_instances_in_model(model, processEquipment.TaggedPlantItem)
    for item in tagged_plant_items:
        row = identity.record(item)
        # Identifier
        row["Tag"] = item.tagName
        row["Equipment type"] = humanize_class_name(item.__class__.__name__)
        # data attributes
        data_attributes = get_data_attributes(item)
        for name, value_object in data_attributes.items():
            if "tag" not in name.lower():  # skip tagName again
                formated_name = format_string(name)
                value = get_attribute_value(value_object, language)
                row[formated_name] = value
        # compositional attributes -> sub equipment
        comp_attributes = get_composition_attributes(item)
        for comp_objects in comp_attributes.values():
            # data attributes of sub equipment
            if isinstance(comp_objects, list):
                for i, comp_object in enumerate(comp_objects):
                    row = extend_row_with_subequipment(row, comp_object, i, language)
            else:
                row = extend_row_with_subequipment(row, comp_objects, None, language)

        table.append(row)

    equipment_list = semantic_frame(table)
    return equipment_list


def make_line_list(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Collect piping network segments and their attributes as a table.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model containing piping network systems and segments.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        A table with one row per piping network segment including the line number
        of its parent system and its data attributes (with system-level
        attributes propagated to segments where applicable).
    """
    language = normalize_language(language)
    table = []
    identity = IdentityContext(model)
    systems = get_all_instances_in_model(model, piping.PipingNetworkSystem)
    owners = {}
    for system in systems:
        for segment in system.segments:
            if id(segment) in owners and owners[id(segment)] is not system:
                raise ValueError(f"Ambiguous piping system for segment {segment.id!r}")
            owners[id(segment)] = system
    for segment in get_all_instances_in_model(model, piping.PipingNetworkSegment):
        system = owners.get(id(segment))
        row = identity.record(segment)
        row["piping_system_id"] = identity.object_id(system)
        row["Line number"] = get_attribute_value(getattr(system, "lineNumber", None), language)
        for role, attribute in (
            ("source_item", "sourceItem"),
            ("target_item", "targetItem"),
            ("source_node", "sourceNode"),
            ("target_node", "targetNode"),
        ):
            row.update(identity.reference(getattr(segment, attribute), role))
        system_data = get_data_attributes(system) if system is not None else {}
        for name, value_object in get_data_attributes(segment).items():
            effective_value = system_data.get(name) if value_object is None else value_object
            row[format_string(name)] = get_attribute_value(effective_value, language)
        table.append(row)

    line_list = semantic_frame(
        table,
        (
            "piping_system_id",
            "source_item_id",
            "target_item_id",
            "source_node_id",
            "target_node_id",
            "source_item_status",
            "target_item_status",
            "source_node_status",
            "target_node_status",
        ),
    )
    return line_list


def make_instrument_list(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Collect process instrumentation functions and their attributes as a table.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model containing instrumentation functions and related objects.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        A table with one row per instrumentation function including Tag, operated
        valve (if any), sensing location, and other data attributes.
    """
    language = normalize_language(language)
    table = []
    identity = IdentityContext(model)
    instruments = get_all_instances_in_model(model, instrumentation.ProcessInstrumentationFunction)
    for instrument_object in instruments:
        row = identity.record(instrument_object)
        # Identifier
        row["Tag"] = instrument_tag(instrument_object)
        # Operated valve reference
        actuating_functions = instrument_object.actuatingFunctions
        for actuating_function in actuating_functions:
            actuating_system = actuating_function.systems
            if actuating_system:
                operatedValveReference = actuating_system.operatedValveReference
                if operatedValveReference:
                    row["Operated valve"] = get_attribute_value(
                        getattr(operatedValveReference.valve, "pipingComponentNumber", None),
                        language,
                    )
        # Sensing location
        generating_functions = instrument_object.processSignalGeneratingFunctions
        for generating_function in generating_functions:
            sensing_location = generating_function.sensingLocation
            if sensing_location:
                if issubclass(sensing_location.__class__, piping.PipingComponent):
                    row["Sensing location"] = get_attribute_value(
                        getattr(sensing_location, "pipingComponentNumber", None), language
                    )  # TODO replace with tag
                elif issubclass(sensing_location.__class__, piping.PipingNetworkSegment):
                    row["Sensing location"] = get_attribute_value(
                        sensing_location.segmentNumber, language
                    )  # TODO replace with tag
                elif issubclass(sensing_location.__class__, processEquipment.Nozzle):
                    row["Sensing location"] = get_attribute_value(
                        sensing_location.subTagName, language
                    )  # TODO check if this makes sense
        # Data attributes
        data_attributes = get_data_attributes(instrument_object)
        for name, value_object in data_attributes.items():
            formated_name = format_string(name)
            value = get_attribute_value(value_object, language)
            row[formated_name] = value
        table.append(row)

    instrument_list = semantic_frame(
        table,
        ("Tag", "Process instrumentation function number", "Operated valve", "Sensing location"),
    )
    return instrument_list


def make_piping_component_list(
    model: EngineeringModel,
    *,
    language: str = "en",
    include_valves: bool = False,
    include_connectors: bool = False,
) -> pd.DataFrame:
    """Collect piping components and their attributes as a table.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model containing piping components.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.
    include_valves : bool, default ``False``
        Whether to also list valves. By default they are left to the dedicated
        valve list (:func:`make_valve_list`).

    include_connectors : bool, default ``False``
        Include PipeOffPageConnector subclasses (topology objects, not PipingComponent).
        Set both inclusion flags to True for a complete inventory. With valves only,
        row count equals the model summary piping_component_count.

    Returns
    -------
    pd.DataFrame
        A table with one row per piping component including its class name and data
        attributes.
    """
    language = normalize_language(language)
    table = []
    identity = IdentityContext(model)
    piping_components = get_all_instances_in_model(
        model,
        (piping.PipingComponent, piping.PipeOffPageConnector)
        if include_connectors
        else piping.PipingComponent,
    )
    for piping_component_object in piping_components:
        if not include_valves and isinstance(piping_component_object, VALVE_CLASSES):
            continue
        row = identity.record(piping_component_object)
        row["Piping component"] = humanize_class_name(piping_component_object.__class__.__name__)
        # Data attributes
        data_attributes = get_data_attributes(piping_component_object)
        for name, value_object in data_attributes.items():
            formated_name = format_string(name)
            value = get_attribute_value(value_object, language)
            row[formated_name] = value
        table.append(row)

    piping_component_list = semantic_frame(table)
    return piping_component_list


def make_valve_list(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Collect all valves and their attributes as a table.

    Valves are the subclass trees of :data:`VALVE_CLASSES` -- operated valves,
    check valves, and safety valves or fittings.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model containing valves.
    language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        A table with one row per valve including tag, valve type, nominal
        diameter (read from the valve's piping nodes), and data attributes.
    """
    # TODO Valve tag: DEXPI has no dedicated valve tag; use the component identifiers for now.
    language = normalize_language(language)
    table = []
    identity = IdentityContext(model)
    valves = get_all_instances_in_model(model, VALVE_CLASSES)
    for valve in valves:
        row = identity.record(valve)
        # Not every valve class carries every identifier: safety valves have a
        # positionNumber but no pipingComponentNumber.
        row["Tag"], tag_source = None, None
        for attribute in ("pipingComponentNumber", "pipingComponentName", "positionNumber"):
            tag = get_attribute_value(getattr(valve, attribute, None), language)
            if tag is not None:
                row["Tag"], tag_source = tag, attribute
                break
        row["Valve type"] = humanize_class_name(valve.__class__.__name__)
        row["Nominal diameter"] = _first_node_diameter(valve)
        # Data attributes; the identifier used as Tag is not repeated
        data_attributes = get_data_attributes(valve)
        for name, value_object in data_attributes.items():
            if name == tag_source:
                continue
            formated_name = format_string(name)
            value = get_attribute_value(value_object, language)
            row[formated_name] = value
        table.append(row)

    valve_list = semantic_frame(table)
    return valve_list


def _first_node_diameter(valve: PyDexpiBaseModel) -> str | None:
    """Read a nominal diameter off a valve's piping nodes.

    DEXPI keeps the nominal diameter on the ``PipingNode`` objects, not on the
    valve itself. The readable representation is preferred over the bare
    numerical value.
    """
    for attribute in (
        "nominalDiameterRepresentation",
        "nominalDiameterNumericalValueRepresentation",
    ):
        for node in valve.nodes or []:
            value = getattr(node, attribute, None)
            if isinstance(value, str) and value.strip():
                return value
    return None


def _finalize_dataframe(df: pd.DataFrame, list_type: str, language: str = "en") -> pd.DataFrame:
    """Drop all-empty columns, order columns, and translate the headers.

    The builders produce canonical English headers; translation is a rename
    pass applied here, after :data:`COLUMN_PRIORITIES` (which is keyed by the
    English labels) has been applied.
    """
    language = normalize_language(language)
    stable = set(IDENTITY_COLUMNS) | set(df.attrs.get("stable_columns", ()))
    df = df.drop(columns=[c for c in df if c not in stable and df[c].isna().all()])
    df = reorder_columns(df, COLUMN_PRIORITIES.get(list_type, []))
    if language != "en":
        df = df.rename(
            columns={
                column: translate_label(column, language)
                for column in df.columns
                if column not in stable or column != column.lower()
            }
        )
    return df


def _build_tables(model: EngineeringModel, language: str) -> dict[ListType, pd.DataFrame]:
    """Build and finalize every exportable table."""
    tables = {
        ListType.EQUIPMENT: make_equipment_list(model, language=language),
        ListType.LINE: make_line_list(model, language=language),
        ListType.INSTRUMENT: make_instrument_list(model, language=language),
        ListType.PIPING_COMPONENT: make_piping_component_list(model, language=language),
        ListType.VALVE: make_valve_list(model, language=language),
    }
    return {key: _finalize_dataframe(df, key.value, language) for key, df in tables.items()}
