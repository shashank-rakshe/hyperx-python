"""Exceptions raised by the Canonical Intermediate Representation (CIR) package."""

from __future__ import annotations


class CIRError(Exception):
    """Base class for every error raised by the :mod:`cir` package."""


class SchemaVersionError(CIRError):
    """A CIR document's schema version is incompatible with this library.

    Raised on load when the document's ``schema_version`` differs in MAJOR
    version from :data:`cir.version.SCHEMA_VERSION` (see :mod:`cir.version`).
    """


class LicenseLaneError(CIRError):
    """A record's :class:`~cir.enums.DataLane` is incompatible with its license.

    This is the typed, explicit guard behind the research/commercial two-lane data
    discipline (see ``docs/DECISIONS.md``, Decision 1). It is raised by the audit
    helpers (e.g. :meth:`cir.schema.DrawingSet.assert_commercial_safe`) and the
    dataset ``audit`` command so that a non-commercial or unverified source can
    never silently end up in the commercial lane that trains shippable weights.

    Note: at *model construction* time the same invariant surfaces as a
    :class:`pydantic.ValidationError` (validators must raise ``ValueError``); this
    typed error is for the explicit, pipeline-level guards.
    """


class SerializationError(CIRError):
    """(De)serialization of a CIR document failed (bad format, missing codec, ...)."""
