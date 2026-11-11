"""DataFrame export API for pyDEXPI models.

This module provides programmatic access to pandas DataFrames derived from a
pyDEXPI ``EngineeringModel``.  It wraps the existing table-building functions
in :mod:`pydexpi.exports.table_export` and adds graph-based node / edge tables
built from the NetworkX representation.

All ``get_*`` functions return :class:`pandas.DataFrame` objects that can be
used directly in notebooks, analysis pipelines, or written to any format
pandas supports.
"""

import pandas as pd

from pydexpi.exports.table_export import (
    _finalize_dataframe,
    make_equipment_list,
    make_instrument_list,
    make_line_list,
    make_piping_component_list,
    make_valve_list,
)
from pydexpi.pydexpi_classes import EngineeringModel


def get_nozzle_dataframe(model: EngineeringModel) -> pd.DataFrame:
    """Return nozzle IDs, subtags, parent equipment IDs and attachment ID arrays.

    Join parent_equipment_id to the equipment table id; no attachment is inferred
    from a tag. Columns are machine names and do not depend on language.
    """
    from pydexpi.exports.nozzle_export import make_nozzle_list

    return make_nozzle_list(model)


def get_piping_connection_dataframe(model: EngineeringModel) -> pd.DataFrame:
    """Return one row per pipe/connection, including parallel edges and endpoint IDs.

    Segment rows describe segment boundaries; these rows describe individual
    connections. Neither is a universally ordered path. Use graph/path tools for that.
    """
    from pydexpi.exports.piping_topology import make_piping_connection_list

    return make_piping_connection_list(model)


def get_instrument_relationship_dataframe(model: EngineeringModel) -> pd.DataFrame:
    """Return instrumentation property edges and directed signal/measuring flow rows.

    IDs identify real model objects; role/category/ordinal distinguish property
    relationships. Flow rows retain each intermediate line identity, including parallel lines.
    """
    from pydexpi.exports.instrument_relationships import make_instrument_relationship_list

    return make_instrument_relationship_list(model)


# ------------------------------------------------------------------
# Semantic table DataFrames (wrapping existing table_export functions)
# ------------------------------------------------------------------


def get_equipment_dataframe(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Return an equipment list as a DataFrame.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model.
    language : str, default ``"en"``
        Language for column headers and ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        One row per tagged plant item with tag, type, and data attributes.
    """
    return _finalize_dataframe(make_equipment_list(model, language=language), "equipment", language)


def get_line_dataframe(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Return a piping line list as a DataFrame.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model.
    language : str, default ``"en"``
        Language for column headers and ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        One row per piping network segment with ID, boundary item/node IDs,
        parent piping_system_id, endpoint statuses, line number and data attributes.
    """
    return _finalize_dataframe(make_line_list(model, language=language), "line", language)


def get_instrument_dataframe(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Return an instrument list as a DataFrame.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model.
    language : str, default ``"en"``
        Language for column headers and ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        One row per instrumentation function with tag, operated valve,
        sensing location, and data attributes.
    """
    return _finalize_dataframe(
        make_instrument_list(model, language=language), "instrument", language
    )


def get_piping_component_dataframe(
    model: EngineeringModel,
    *,
    language: str = "en",
    include_valves: bool = False,
    include_connectors: bool = False,
) -> pd.DataFrame:
    """Return a piping component list as a DataFrame.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model.
    language : str, default ``"en"``
        Language for column headers and ``MultiLanguageString`` values.
    include_valves : bool, default ``False``
        Whether to also list valves. By default they are left to the dedicated
        valve list (:func:`get_valve_dataframe`).

    include_connectors : bool, default ``False``
        Include PipeOffPageConnector subclasses (topology objects, not PipingComponent).
        Set both inclusion flags to True for a complete inventory. With valves only,
        row count equals the model summary piping_component_count.

    Returns
    -------
    pd.DataFrame
        One row per piping component with class name and data attributes.
    """
    df = make_piping_component_list(
        model,
        language=language,
        include_valves=include_valves,
        include_connectors=include_connectors,
    )
    return _finalize_dataframe(df, "piping component", language)


def get_valve_dataframe(model: EngineeringModel, *, language: str = "en") -> pd.DataFrame:
    """Return a valve list as a DataFrame.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model.
    language : str, default ``"en"``
        Language for column headers and ``MultiLanguageString`` values.

    Returns
    -------
    pd.DataFrame
        One row per valve with tag, valve type, nominal diameter, and data
        attributes.
    """
    return _finalize_dataframe(make_valve_list(model, language=language), "valve", language)


def get_all_tables(model: EngineeringModel, *, language: str = "en") -> dict[str, pd.DataFrame]:
    """Return all semantic tables as a dictionary of DataFrames.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model.
    language : str, default ``"en"``
        Language for column headers and ``MultiLanguageString`` values.

    Returns
    -------
    dict[str, pd.DataFrame]
        Mapping of ``{"equipment": ..., "line": ..., "instrument": ...,
        "piping_component": ..., "valve": ...}``.
    """
    return {
        "equipment": get_equipment_dataframe(model, language=language),
        "line": get_line_dataframe(model, language=language),
        "instrument": get_instrument_dataframe(model, language=language),
        "piping_component": get_piping_component_dataframe(model, language=language),
        "valve": get_valve_dataframe(model, language=language),
    }
