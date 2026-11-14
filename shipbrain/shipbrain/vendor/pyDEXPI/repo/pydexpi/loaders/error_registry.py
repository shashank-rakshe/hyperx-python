"""Utility module for error registration during parsing in different loaders."""

from dataclasses import dataclass
from enum import StrEnum
from typing import Literal


class InternalParserError(Exception):
    """Custom exception for internal parser errors.

    This exception is raised when an error occurs during the parsing process that is related to the
    internal logic of the parser.
    """


class ErrorLevels(StrEnum):
    """Enumeration of error severity levels for the DEXPI XML serializer.

    This enum defines the different levels of errors that can occur
    during the parsing and serialization process.

    Levels:
    - INFO: Informational messages. Non-critical for logging.
    - WARNING: Indicates a potential issue or inconsistency, but no loss of DEXPI data.
    - ERROR: Indicates an error that causes a local loss of DEXPI data, due to missing data or
             malformed XML element.
    - CRITICAL: Indicates a severe error that prevents loading the model entirely.
    """

    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"


@dataclass(frozen=True)
class SourceLocation:
    """Where in a source document an error originated.

    This is the same information as the location fields of `ErrorRegistryEntry`, bundled up so that
    format-specific readout logic can return it in one piece. Helpers that derive it from concrete
    documents live in `pydexpi.loaders.source_location`.

    Parameters
    ----------
    element : str or None, optional
        Name of the offending element, e.g. the XML tag "Nozzle" or a DEXPI class name. This is
        always a name, never an element object, by default None
    xpath : str or None, optional
        Path of the offending element within the source document, by default None
    line : int or None, optional
        1-based line number in the source document, by default None
    column : int or None, optional
        1-based column number in the source document, by default None
    """

    element: str | None = None
    xpath: str | None = None
    line: int | None = None
    column: int | None = None


@dataclass
class ErrorRegistryEntry:
    """Data class representing an error entry in the error registry.

    The `element`, `xpath`, `line` and `column` fields locate the error in the source document. They
    are populated on a best-effort basis: a loader fills in whatever its format can provide, and
    leaves the rest as None. Errors that do not originate from a specific element of the source
    document (loader-level errors, for instance) legitimately leave all four unset.

    Parameters
    ----------
    message : str
        Human-readable error message
    level : ErrorLevels
        Severity level of the error
    object_id : str or None, optional
        pyDEXPI object ID associated with the error if available, by default None
    exception : Exception or None, optional
        The exception that caused the error, if applicable, by default None
    element : str or None, optional
        Name of the offending element, e.g. the XML tag "Nozzle" or a DEXPI class name. This is a
        name, never an element object, by default None
    xpath : str or None, optional
        Path of the offending element within the source document, e.g.
        "/PlantModel/Equipment[2]/Nozzle[1]" for XML or a JSON Pointer for JSON. This is a
        structural path into the exact document that was parsed: it is position dependent and is
        not a stable identifier across edits of that document, by default None
    line : int or None, optional
        1-based line number in the source document, by default None
    column : int or None, optional
        1-based column number in the source document. Only available for well-formedness errors,
        as XML parsers do not report a column per element, by default None
    content : str or None, optional
        What the entry is about, when the load does not keep it, serialized in the document's
        format so the data stays recoverable from the report: an object dropped because DEXPI
        2.0.1 gives it no owner, a value the 2.0.1 model cannot hold, or repeated ``<Data>``
        values the loader did not read. It is the text as it stood when dropped -- for a DEXPI 2.0
        document, *after* its conversion to 2.0.1, so with the renames applied (``MoleFractions``,
        ``RatioUnit``) -- not the source document's own spelling, by default None
    """

    message: str
    level: ErrorLevels
    object_id: str | None = None
    exception: Exception | None = None
    element: str | None = None
    xpath: str | None = None
    line: int | None = None
    column: int | None = None
    content: str | None = None


class ErrorRegistry:
    """Registry for collecting and managing errors during serialization.

    This class provides a centralized way to collect, store, and retrieve
    errors that occur during the parsing and serialization process.
    """

    def __init__(self) -> None:
        """Initialize an empty error registry."""
        self.errors = []

    def register_error(
        self,
        message: str,
        level: ErrorLevels | Literal["info", "warning", "error", "critical"],
        object_id: str | None = None,
        exception: Exception | None = None,
        element: str | None = None,
        xpath: str | None = None,
        line: int | None = None,
        column: int | None = None,
        content: str | None = None,
    ) -> None:
        """Convenience method to create and register an error entry.

        This method allows for quick registration of errors by providing the necessary
        information directly as parameters. It creates an ErrorRegistryEntry and registers it.

        Parameters
        ----------
        message : str
            Human-readable error message
        level : ErrorLevels or str
            Severity level of the error. A string is converted to the matching `ErrorLevels`
            member, so that an entry reports the same type whichever loader registered it.
        object_id : str or None, optional
            pyDEXPI object ID associated with the error if available, by default None
        exception : Exception or None, optional
            The exception that caused the error, if applicable, by default None
        element : str or None, optional
            Name of the offending element in the source document, by default None
        xpath : str or None, optional
            Path of the offending element within the source document, by default None
        line : int or None, optional
            1-based line number in the source document, by default None
        column : int or None, optional
            1-based column number in the source document, by default None
        content : str or None, optional
            What was dropped, when the load does not keep it, serialized as it stood when dropped
            (for a DEXPI 2.0 document, after its conversion to 2.0.1), by default None
        """
        new_error = ErrorRegistryEntry(
            message=message,
            level=ErrorLevels(level),
            object_id=object_id,
            exception=exception,
            element=element,
            xpath=xpath,
            line=line,
            column=column,
            content=content,
        )
        self.register_registry_entry(new_error)

    def register_registry_entry(self, error: ErrorRegistryEntry) -> None:
        """Register a new error in the registry.

        This method enables centralized error registration. It keeps track of all errors and
        centrally handles InternalParserErrors, which are automatically reraised.

        Parameters
        ----------
        error : ErrorRegistryEntry
            The error entry to register
        """
        self.errors.append(error)
        if isinstance(error.exception, InternalParserError):
            # If the error is an InternalParserError, it should not be caught by the parser.
            raise error.exception

    def get_errors(self, levels: list[ErrorLevels] | None = None) -> list[ErrorRegistryEntry]:
        """Retrieve all registered errors.

        Parameters
        ----------
        levels : list[ErrorLevels] or None, optional
            If provided, filter errors by their severity level. If None, return all errors.
            Defaults to None.

        Returns
        -------
        list[ErrorRegistryEntry]
            List of all error entries in the registry
        """
        if levels is None:
            return self.errors
        else:
            return [error for error in self.errors if error.level in levels]
