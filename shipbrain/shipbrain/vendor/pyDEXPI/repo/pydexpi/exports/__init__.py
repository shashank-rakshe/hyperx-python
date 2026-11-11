"""Export modules for pyDEXPI models.

This package provides various export formats for converting pyDEXPI
``EngineeringModel`` instances into interchange and reporting formats.

API layers (per exporter)
-------------------------
1. **Graph object** — ``build_graph(...)`` returns a NetworkX ``MultiDiGraph``.
2. **Structured in-memory data** — ``get_*_records`` / ``get_*_dataframe``
   return dicts or DataFrames without touching the filesystem.
3. **Serialized in-memory export** — ``export_*_bytes`` (GraphML) /
   ``export_*_strings`` (CSV) return the final interchange payload in memory.
4. **File-writing convenience wrappers** — ``export_*`` write to disk.

Submodules
----------
table_export
    Equipment, line, instrument, piping component, and valve tables
    (Excel/CSV/JSON), with industrial Excel styling and multi-language labels.
table_style
    Style spec and title-block layout for the Excel tables.
table_locale
    Translations (en/de/nl/zh) and unit symbols for the table export.
dataframe_export
    Programmatic DataFrame API wrapping table and graph exports.
graphml_export
    GraphML export via NetworkX.
neo4j_export
    Neo4j-compatible CSV node/relationship export.
llm_context_export
    Compact LLM-ready text export from GraphML.
"""

from pydexpi.exports.dataframe_export import (
    get_all_tables,
    get_equipment_dataframe,
    get_instrument_dataframe,
    get_instrument_relationship_dataframe,
    get_line_dataframe,
    get_nozzle_dataframe,
    get_piping_component_dataframe,
    get_piping_connection_dataframe,
    get_valve_dataframe,
)
from pydexpi.exports.graphml_export import export_graphml, export_graphml_bytes
from pydexpi.exports.llm_context_export import (
    DEFAULT_LLM_SKIP_KEYS,
    export_llm_context,
    export_llm_context_strings,
)
from pydexpi.exports.neo4j_export import (
    Neo4jCsvExport,
    Neo4jRecords,
    export_neo4j_csv,
    export_neo4j_csv_strings,
    get_neo4j_records,
)
from pydexpi.exports.table_export import export_tables

__all__ = [
    "DEFAULT_LLM_SKIP_KEYS",
    "Neo4jCsvExport",
    # Neo4j — dataclasses
    "Neo4jRecords",
    # GraphML
    "export_graphml",
    "export_graphml_bytes",
    # LLM context
    "export_llm_context",
    "export_llm_context_strings",
    # Neo4j — file-writing convenience wrapper
    "export_neo4j_csv",
    # Neo4j — serialized in-memory export
    "export_neo4j_csv_strings",
    # Table / DataFrame exports
    "export_tables",
    "get_all_tables",
    "get_equipment_dataframe",
    "get_instrument_dataframe",
    "get_instrument_relationship_dataframe",
    "get_line_dataframe",
    # Neo4j — structured in-memory data
    "get_neo4j_records",
    "get_nozzle_dataframe",
    "get_piping_component_dataframe",
    "get_piping_connection_dataframe",
    "get_valve_dataframe",
]
