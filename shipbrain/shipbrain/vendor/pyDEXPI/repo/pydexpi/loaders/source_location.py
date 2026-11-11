"""Helpers for deriving source locations of errors raised while loading a document.

The loaders record where in the source document an error originated, so that consumers can render
a structured error table pointing back at the offending part of the input. This module holds the
format-specific derivation of that information; the resulting `SourceLocation` value type lives
next to the error registry it feeds, and reading documents in the first place is
`pydexpi.loaders.xml_parsing`.
"""

from lxml import etree

from pydexpi.loaders.error_registry import SourceLocation


def source_location_from_xml_element(element: etree._Element) -> SourceLocation:
    """Derive the source location of an XML element.

    Parameters
    ----------
    element : etree._Element
        The XML element the error refers to.

    Returns
    -------
    SourceLocation
        The location of the element. `column` is always None, as XML parsers report a position per
        document rather than per element. `line` is None for elements that were built in memory
        rather than parsed from a document.
    """
    return SourceLocation(
        element=element.tag,
        xpath=element.getroottree().getpath(element),
        line=element.sourceline,
    )


def source_location_from_xml_syntax_error(exception: etree.XMLSyntaxError) -> SourceLocation:
    """Derive the source location of an XML well-formedness error.

    This is the only place a column is available, as the parser reports the position at which it
    gave up rather than a position per element.

    Parameters
    ----------
    exception : etree.XMLSyntaxError
        The syntax error raised while parsing.

    Returns
    -------
    SourceLocation
        The position at which parsing failed. Positions of 0, which lxml uses when it has no
        position to report, are normalised to None.
    """
    line, column = exception.position
    return SourceLocation(line=line or None, column=column or None)


def escape_json_pointer_token(token: str) -> str:
    """Escape a single token for use in a JSON Pointer, as specified by RFC 6901.

    The replacements have to happen in this order, so that the tilde introduced by escaping a
    slash is not escaped a second time.

    Parameters
    ----------
    token : str
        The raw token, for instance an attribute name read from the document.

    Returns
    -------
    str
        The escaped token.
    """
    return token.replace("~", "~0").replace("/", "~1")


def join_json_pointer(pointer: str, *tokens: str | int) -> str:
    """Append tokens to a JSON Pointer, escaping each of them.

    Parameters
    ----------
    pointer : str
        The pointer to extend. The empty string denotes the root of the document.
    *tokens : str or int
        Tokens to append. Integers are array indices and need no escaping.

    Returns
    -------
    str
        The extended pointer.
    """
    for token in tokens:
        escaped = str(token) if isinstance(token, int) else escape_json_pointer_token(token)
        pointer = f"{pointer}/{escaped}"
    return pointer


def describe_json_value(value: object) -> str:
    """Say what a decoded JSON value is, for a message about a document that holds the wrong one.

    Parameters
    ----------
    value : object
        A value as ``json.loads`` returns it.

    Returns
    -------
    str
        ``"null"``, ``"a boolean"``, ``"a string"``, ``"a number"``, ``"a list"`` or
        ``"an object"``, phrased to follow "is" or "has".
    """
    if value is None:
        return "null"
    # A bool is an int in Python, so it is told apart first.
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, str):
        return "a string"
    if isinstance(value, (int, float)):
        return "a number"
    if isinstance(value, list):
        return "a list"
    return "an object" if isinstance(value, dict) else f"a {type(value).__name__}"
