"""Reading documents written against an earlier DEXPI version than pyDEXPI's classes.

pyDEXPI's classes are DEXPI 2.0.1 and pyDEXPI writes only 2.0.1. It *reads* DEXPI 2.0 by
converting the parsed document before any object is built:
:mod:`pydexpi.loaders.compat.dexpi_2_0_to_2_0_1`.
"""

from .dexpi_2_0_to_2_0_1 import (
    DEXPI_2_0,
    DEXPI_2_0_1,
    JSON_VERSION_KEY,
    ConversionRefusedError,
    DocumentVersion,
    json_document_version,
    json_reading_version,
    upgrade_json_document,
    upgrade_xml_document,
    xml_document_version,
    xml_reading_version,
)

__all__ = [
    "DEXPI_2_0",
    "DEXPI_2_0_1",
    "JSON_VERSION_KEY",
    "ConversionRefusedError",
    "DocumentVersion",
    "json_document_version",
    "json_reading_version",
    "upgrade_json_document",
    "upgrade_xml_document",
    "xml_document_version",
    "xml_reading_version",
]
