"""Reading XML documents into lxml trees.

Every XML document pyDEXPI reads goes through this module, so that the parser hardening is
configured in one place rather than repeated at each call site. Deriving where in such a document
an error originated is a separate concern and lives in `pydexpi.loaders.source_location`.
"""

from pathlib import Path

from lxml import etree


def create_xml_parser(encoding: str | None = None) -> etree.XMLParser:
    """Create a hardened lxml parser for reading DEXPI documents.

    External entities and network access are disabled, which is what protects against XXE and
    entity expansion attacks. A new parser is created per parse rather than shared, because a
    parser accumulates state (its `error_log`, in particular) and is not safe to reuse across
    concurrent loads. Construction is cheap.

    Parameters
    ----------
    encoding : str or None, optional
        Encoding to use, overriding any declaration in the document. Pass this when the input has
        already been decoded to `str`: its XML declaration is then stale, and honouring it would
        reinterpret freshly encoded bytes and silently corrupt non-ASCII text. Leave as None for
        byte input, so that the document's own declaration is respected. By default None

    Returns
    -------
    etree.XMLParser
        A parser configured for safe reading of untrusted documents.
    """
    return etree.XMLParser(resolve_entities=False, no_network=True, encoding=encoding)


def parse_xml_string(xml_string: str) -> etree._Element:
    """Parse an XML document that has already been decoded to a string.

    Parameters
    ----------
    xml_string : str
        The XML content to parse.

    Returns
    -------
    etree._Element
        The root element of the parsed document.

    Raises
    ------
    etree.XMLSyntaxError
        If the content is not well-formed XML.
    """
    # lxml refuses str input carrying an encoding declaration, so encode first. The declaration is
    # stale once the text has been decoded, hence the matching override on the parser.
    return etree.fromstring(xml_string.encode("utf-8"), create_xml_parser(encoding="utf-8"))


def parse_xml_bytes(xml_bytes: bytes) -> etree._Element:
    """Parse an XML document from its raw bytes, honouring its encoding declaration.

    Parameters
    ----------
    xml_bytes : bytes
        The XML content to parse.

    Returns
    -------
    etree._Element
        The root element of the parsed document.

    Raises
    ------
    etree.XMLSyntaxError
        If the content is not well-formed XML.
    """
    return etree.fromstring(xml_bytes, create_xml_parser())


def parse_xml_file(xml_path: str | Path) -> etree._ElementTree:
    """Parse an XML document from a file on disk, honouring its encoding declaration.

    Parameters
    ----------
    xml_path : str or Path
        Path of the document to parse.

    Returns
    -------
    etree._ElementTree
        The parsed document. A tree rather than an element, as schema validation needs the tree.

    Raises
    ------
    etree.XMLSyntaxError
        If the content is not well-formed XML.
    """
    return etree.parse(str(xml_path), create_xml_parser())


def load_xml_schema(xsd_path: str | Path) -> etree.XMLSchema:
    """Load an XML schema from a file on disk.

    Unlike the documents being validated, a schema is trusted content that ships with pyDEXPI, and
    the DEXPI one declares an internal DTD whose entities have to expand for the schema to compile.
    It is therefore read with a parser that permits entity resolution, keeping only the ban on
    network access.

    Parameters
    ----------
    xsd_path : str or Path
        Path of the XSD to load.

    Returns
    -------
    etree.XMLSchema
        The compiled schema.
    """
    xsd_doc = etree.parse(str(xsd_path), etree.XMLParser(no_network=True))
    return etree.XMLSchema(xsd_doc)
