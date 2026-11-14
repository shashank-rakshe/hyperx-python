"""Attribution of generated files to the system that produced them.

DEXPI 2.0 reserves a place for this on the model root:
:class:`~pydexpi.pydexpi_classes.pydexpi_classes.EngineeringModel` carries
``originatingSystemName``, ``originatingSystemVendorName`` and
``originatingSystemVersion`` -- "the system from which the EngineeringModel
originates, e.g., the name of a P&ID tool".  Until now pyDEXPI only ever *read*
those fields (the Proteus importer is the sole writer); this module lets pyDEXPI
also stamp them on the files it writes, and lets a host application rebrand that
stamp.

Two carriers, deliberately kept apart
-------------------------------------
**The typed DEXPI fields carry the brand and nothing else.**  ``originatingSystemName``
is a standardised, queryable field -- it ends up as a Neo4j property, an Excel
title-block row and a GraphML graph attribute -- so it must read exactly
``"ExampleCAD"``, never ``"ExampleCAD (powered by pyDEXPI)"``, or grouping and filtering on
it break.

**The free-text generator string carries the credit.**  :func:`generator_string`
and :func:`generator_comment` feed places that are prose by nature and that no tool
parses semantically: the XML header comment, the SVG ``<metadata>`` element, the
PDF ``Producer``, and the Excel workbook description.  That is where a "powered by
pyDEXPI" tail belongs.

Never overwrite
---------------
:func:`stamp_originating_system` fills a field only when it is ``None``.  A model
loaded from a vendor tool keeps its own provenance, so a load/save round-trip does
not launder ``"P&ID Toolbox"`` into ``"pyDEXPI"``.

``None`` is the only "unset" value.  These fields are typed
``str | Undefined | None``, and an explicit ``Undefined`` is a *statement* by the
source document that the value is knowingly unknown -- that is data, and it is left
alone.

Configuration
-------------
Everything is read from the environment, so a container or CI job can rebrand
without touching code:

=========================== =================================================
``PYDEXPI_SYSTEM_NAME``     Originating system name.  Default ``pyDEXPI``.
``PYDEXPI_SYSTEM_VENDOR``   Vendor name.  Default: the pyDEXPI authors.
``PYDEXPI_SYSTEM_VERSION``  Version string.  Default: installed pyDEXPI version.
``PYDEXPI_SYSTEM_URL``      Project URL shown in the generator comment.
``PYDEXPI_POWERED_BY``      ``0``/``false`` drops the "powered by" tail.
                            Default on.
``PYDEXPI_EXPORT_DATETIME`` ``1``/``true`` also stamps ``exportDateTime``.
                            Default **off**, see below.
=========================== =================================================

The environment is read on *every* call rather than cached at import, so tests can
``monkeypatch.setenv`` and a long-running host can rebrand at runtime.

Why ``exportDateTime`` is opt-in
--------------------------------
Stamping the current time would make every export byte-different from the last,
which defeats reproducible output and the order-insensitive model hashing in
:mod:`pydexpi.hashing`.  Attribution does not need a timestamp, so the default is
to leave the field alone; set ``PYDEXPI_EXPORT_DATETIME`` when an actual export
timestamp is wanted.
"""

import os
from dataclasses import dataclass
from datetime import UTC, datetime
from importlib.metadata import PackageNotFoundError, version as _distribution_version

from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel

__all__ = [
    "PYDEXPI_SYSTEM_NAME",
    "PYDEXPI_URL",
    "PYDEXPI_VENDOR_NAME",
    "UNKNOWN_VERSION",
    "Attribution",
    "generator_comment",
    "generator_string",
    "get_attribution",
    "get_version",
    "needs_stamp",
    "stamp_exported_model",
    "stamp_originating_system",
]

#: Distribution name as declared in ``pyproject.toml``.
_DISTRIBUTION = "pyDEXPI"

PYDEXPI_SYSTEM_NAME = "pyDEXPI"
PYDEXPI_VENDOR_NAME = "Process Intelligence Research, TU Delft"
PYDEXPI_URL = "https://github.com/process-intelligence-research/pyDEXPI"

#: Reported when the distribution is not installed, e.g. a source checkout run
#: without ``pip install -e .``.
UNKNOWN_VERSION = "unknown"

ENV_SYSTEM_NAME = "PYDEXPI_SYSTEM_NAME"
ENV_SYSTEM_VENDOR = "PYDEXPI_SYSTEM_VENDOR"
ENV_SYSTEM_VERSION = "PYDEXPI_SYSTEM_VERSION"
ENV_SYSTEM_URL = "PYDEXPI_SYSTEM_URL"
ENV_POWERED_BY = "PYDEXPI_POWERED_BY"
ENV_EXPORT_DATETIME = "PYDEXPI_EXPORT_DATETIME"

#: The ``EngineeringModel`` fields that always get stamped when unset.
ORIGINATING_SYSTEM_FIELDS = (
    "originatingSystemName",
    "originatingSystemVendorName",
    "originatingSystemVersion",
)

_FALSEY = {"0", "false", "no", "off", ""}


@dataclass(frozen=True)
class Attribution:
    """Resolved identity of the system producing an export.

    Attributes
    ----------
    system_name : str
        Goes into ``originatingSystemName`` verbatim.
    vendor_name : str
        Goes into ``originatingSystemVendorName`` verbatim.
    version : str
        Goes into ``originatingSystemVersion`` verbatim.
    url : str or None
        Project URL for the generator comment; ``None`` when a rebranded host
        supplied no URL and suppressed the pyDEXPI credit.
    powered_by : bool
        Whether a "powered by pyDEXPI" tail applies.  Only ever ``True`` when
        *system_name* has actually been overridden -- unbranded pyDEXPI does not
        advertise itself as powered by itself.
    """

    system_name: str
    vendor_name: str
    version: str
    url: str | None
    powered_by: bool


def get_version() -> str:
    """Return the installed pyDEXPI version.

    Read from the installed distribution metadata rather than from
    ``pyproject.toml``, so the reported version is the one actually running.

    Returns
    -------
    str
        The version, or :data:`UNKNOWN_VERSION` if pyDEXPI is not installed.
    """
    try:
        return _distribution_version(_DISTRIBUTION)
    except PackageNotFoundError:
        return UNKNOWN_VERSION


def _env(name: str) -> str | None:
    """Return a stripped environment value, treating blank as unset."""
    value = os.environ.get(name)
    if value is None:
        return None
    return value.strip() or None


def _env_flag(name: str, *, default: bool) -> bool:
    """Return a boolean environment flag."""
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() not in _FALSEY


def get_attribution() -> Attribution:
    """Resolve the current attribution from the environment.

    Returns
    -------
    Attribution
        The identity to stamp on exports.
    """
    name = _env(ENV_SYSTEM_NAME) or PYDEXPI_SYSTEM_NAME
    overridden = name != PYDEXPI_SYSTEM_NAME

    if overridden:
        # A host that rebrands but gives no version of its own must not inherit
        # pyDEXPI's version number -- that would misattribute it.
        vendor = _env(ENV_SYSTEM_VENDOR) or name
        system_version = _env(ENV_SYSTEM_VERSION) or UNKNOWN_VERSION
    else:
        vendor = _env(ENV_SYSTEM_VENDOR) or PYDEXPI_VENDOR_NAME
        system_version = _env(ENV_SYSTEM_VERSION) or get_version()

    powered_by = overridden and _env_flag(ENV_POWERED_BY, default=True)

    # An unbranded build always links pyDEXPI. A rebranded one links its own URL
    # if given, else pyDEXPI's -- but only while it still carries the credit.
    url = _env(ENV_SYSTEM_URL)
    if url is None and (not overridden or powered_by):
        url = PYDEXPI_URL

    return Attribution(
        system_name=name,
        vendor_name=vendor,
        version=system_version,
        url=url,
        powered_by=powered_by,
    )


def generator_string(attribution: Attribution | None = None) -> str:
    """Return the free-text generator identifier.

    ``"pyDEXPI 2.1.0"``, or ``"ExampleCAD 1.4.2 (powered by pyDEXPI 2.1.0)"`` when a
    host application has rebranded the export.

    Parameters
    ----------
    attribution : Attribution, optional
        Resolved attribution; read from the environment when omitted.

    Returns
    -------
    str
        A human-readable identifier. Never goes into a typed DEXPI field.
    """
    attribution = attribution or get_attribution()
    text = f"{attribution.system_name} {attribution.version}"
    if attribution.powered_by:
        text += f" (powered by {PYDEXPI_SYSTEM_NAME} {get_version()})"
    return text


def generator_comment(attribution: Attribution | None = None) -> str:
    """Return the one-line "Generated with ..." banner used in file headers.

    Parameters
    ----------
    attribution : Attribution, optional
        Resolved attribution; read from the environment when omitted.

    Returns
    -------
    str
        The banner text, without any comment delimiters.
    """
    attribution = attribution or get_attribution()
    text = f"Generated with {generator_string(attribution)}"
    if attribution.url:
        text += f" - {attribution.url}"
    return text


def stamp_originating_system(
    model: EngineeringModel, attribution: Attribution | None = None
) -> EngineeringModel:
    """Fill the model's originating-system fields where they are unset.

    Mutates *model* in place.  Use :func:`stamp_exported_model` on the
    serialization path, where the caller's object must stay untouched.

    Only fields that are ``None`` are written: an existing value, including an
    explicit ``Undefined``, is data and is preserved.

    Parameters
    ----------
    model : EngineeringModel
        The model to stamp.
    attribution : Attribution, optional
        Resolved attribution; read from the environment when omitted.

    Returns
    -------
    EngineeringModel
        The same *model*, for convenience.
    """
    attribution = attribution or get_attribution()
    values = {
        "originatingSystemName": attribution.system_name,
        "originatingSystemVendorName": attribution.vendor_name,
        "originatingSystemVersion": attribution.version,
    }
    for field_name, value in values.items():
        if getattr(model, field_name) is None:
            setattr(model, field_name, value)

    if model.exportDateTime is None and _env_flag(ENV_EXPORT_DATETIME, default=False):
        model.exportDateTime = datetime.now(UTC)

    return model


def needs_stamp(model: object) -> bool:
    """Return whether *model* is an ``EngineeringModel`` with anything left to stamp.

    Lets the serializers avoid copying a model that would not change.

    Parameters
    ----------
    model : object
        Any object; only an ``EngineeringModel`` can ever need stamping.

    Returns
    -------
    bool
        ``True`` if :func:`stamp_originating_system` would change something.
    """
    if not isinstance(model, EngineeringModel):
        return False
    if any(getattr(model, name) is None for name in ORIGINATING_SYSTEM_FIELDS):
        return True
    return model.exportDateTime is None and _env_flag(ENV_EXPORT_DATETIME, default=False)


def stamp_exported_model(model: object) -> object:
    """Return a stamped model for export, leaving the caller's object untouched.

    Serialization must not mutate the model the caller still holds, so this stamps
    a copy -- and only makes one when there is something to stamp.  The copy is
    shallow, which is enough because only scalar attributes on the root are set.

    Parameters
    ----------
    model : object
        The model about to be serialized.  The serializers accept any
        ``PyDexpiBaseModel``; anything that is not an ``EngineeringModel`` is
        returned unchanged.

    Returns
    -------
    object
        *model* itself, or a stamped shallow copy of it.
    """
    if not needs_stamp(model):
        return model
    return stamp_originating_system(model.model_copy())
