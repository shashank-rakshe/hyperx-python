"""The JSON wire form of individual attribute values.

A diff reports the two values of a changed attribute as plain JSON, and every consumer that
reads one -- the diff's JSON output, a comparison of two values, a tool that stores a diff --
needs the *same* JSON for the same value. This module is that one encoding. It lives with the
loaders because it is a serialization concern, and so that every consumer can use it without
depending on the diff.

The encoding
------------

=====================================  ==========================================================
Live value                             Wire form
=====================================  ==========================================================
``None``, ``str``, ``int``, ``float``  itself
``bool``                               itself
a ``float`` that is not finite         the string ``"NaN"``, ``"Infinity"`` or ``"-Infinity"``,
                                       at any depth: alone, in a list, inside an object's form
a ``StrEnum`` member                   its *value* (it is a ``str``)
``datetime``                           ISO 8601 string (``datetime.isoformat``)
a pyDEXPI object or data type          ``{"dexpi_class": <class name>, "data": <subtree>}``, the
                                       *envelope*: ``data`` is the pyDEXPI JSON serializer's
                                       representation, composition in full and references as ids
a reference to an object               ``{"dexpi_ref": <id>, "dexpi_class": <class name>}`` via
                                       :func:`encode_ref` -- names the object, does not copy it
``list`` / ``tuple`` / ``dict``        encoded element-wise
=====================================  ==========================================================

Anything else raises :class:`UnsupportedValueError` rather than falling back to ``str(value)``:
a silent stringification would make a reported value look complete while having dropped
information.

Every string form here names the live value unambiguously for the attribute it belongs to: the
generated classes validate their fields, so an enum's value or an ISO timestamp read into the
attribute's own type is the live value again.

Numbers that are not finite
---------------------------
A DEXPI ``Double`` is an ``xsd:double``, which admits ``NaN``, ``INF`` and ``-INF``, so a loaded
model may hold one, and a diff that reports the attribute has to carry it. JSON has no number for
one: ``json.dumps`` writes the bare tokens ``NaN`` and ``Infinity``, which a strict parser
refuses, and pydantic's ``model_dump_json`` writes ``null``, which reads as another value. The
wire form is therefore the JSON *string* ``"NaN"``, ``"Infinity"`` or ``"-Infinity"``
(``json_serializer.non_finite_token``), wherever the number sits. So every value
:func:`encode_value` returns is strict JSON, and whichever way it is serialized afterwards --
``model_dump_json``, ``model_dump(mode="json")``, ``json.dumps`` -- it says the same.

It is read like the other string forms, by the type of the attribute it belongs to: a ``float``
field reads ``"NaN"`` as the number and a ``str`` field as the text. That is unambiguous because
no generated class has a field that takes both a string and a float, which
``tests/test_loaders/test_value_codec.py`` holds a regeneration to. Two wire values are equal
exactly when they say the same, a NaN included, which a comparison of two floats would deny: the
diff compares wire forms for that reason.

A JSON value written by hand may hold a float that is not finite. :func:`spell_non_finite` spells
it as its token, so the value is strict JSON whoever wrote it. Encoding a wire value again spells
such a float as its token and changes nothing else.

``None`` is *no value*, and there is no separate marker for an absent attribute: the attribute's
class says whether ``None`` is one of its values. A mandatory attribute a ``strict=False`` load left
absent holds ``None`` although its type refuses it, so it encodes as ``None`` and the envelope of
its object leaves it out.
"""

from __future__ import annotations

import math
from datetime import datetime
from typing import Any

from pydexpi.loaders.json_serializer import JsonSerializer, non_finite_token
from pydexpi.pydexpi_classes import PyDexpiBaseModel, PyDexpiDataTypeBaseModel

__all__ = [
    "JsonValue",
    "UnsupportedValueError",
    "encode_ref",
    "encode_value",
    "is_envelope",
    "is_ref",
]

JsonValue = dict[str, Any] | list[Any] | str | int | float | bool | None
"""A plain JSON value, as :func:`encode_value` returns it: strict JSON, every float finite."""

#: The one serializer every envelope is written with. Stateless between calls. It writes a number
#: that is not finite as its string token, so an envelope is strict JSON like every other value.
_JSON = JsonSerializer(indent=None, non_finite="strings")


class UnsupportedValueError(TypeError):
    """Raised by :func:`encode_value` for a value it has no wire form for.

    Attributes
    ----------
    value : object
        The value that could not be encoded.
    """

    def __init__(self, value: object) -> None:
        self.value = value
        super().__init__(f"Cannot encode a value of type {type(value).__name__!r} as JSON.")


def encode_value(value: Any) -> JsonValue:
    """Encode a live attribute value as plain JSON.

    See the module docstring for the table of forms. Composition is written out in full: an object
    value becomes an envelope holding its whole subtree, in the form
    ``JsonSerializer().dict_to_model(envelope["data"])`` reads. An object a ``strict=False`` load
    kept without a mandatory attribute is written without it, so only a lenient read takes it
    back. A required reference holding ``None`` -- a label fragment whose ``Object`` the XML
    loader could not resolve -- is left out like any unset reference. A value that only *points
    at* an object -- a reference -- should be written with :func:`encode_ref` instead, which does
    not copy the target.

    Parameters
    ----------
    value : Any
        The live value.

    Returns
    -------
    JsonValue
        The wire form: strict JSON, with a NaN or an infinity as its string token.

    Raises
    ------
    UnsupportedValueError
        If the value, or anything inside it, has no wire form.
    """
    if isinstance(value, float) and not math.isfinite(value):
        return non_finite_token(value)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, (PyDexpiBaseModel, PyDexpiDataTypeBaseModel)):
        try:
            data = _JSON.model_to_dict(value)
        except TypeError as exc:
            # The exporter's "Unsupported data type" for a leaf it cannot write.
            raise UnsupportedValueError(value) from exc
        return {"dexpi_class": type(value).__name__, "data": data}
    if isinstance(value, (list, tuple)):
        return [encode_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): encode_value(item) for key, item in value.items()}
    raise UnsupportedValueError(value)


def spell_non_finite(value: Any) -> Any:
    """Spell every NaN and infinity inside a value that is already in wire form as its token.

    The part of :func:`encode_value` that applies to plain JSON: a float that is not finite,
    alone or at any depth of lists and dicts, becomes ``"NaN"``, ``"Infinity"`` or
    ``"-Infinity"``. Nothing else is read or changed, and a value that holds no such float is
    returned as the object it is, so calling it on a value :func:`encode_value` wrote costs one
    walk and no copy. A JSON value written by hand is made strict JSON this way.

    Parameters
    ----------
    value : Any
        A JSON value: ``None``, a ``str``, a number, a ``bool``, or lists and dicts of them.

    Returns
    -------
    Any
        *value* itself when it holds no float that is not finite, else a copy of the containers
        on the way to each such float, with the float as its token.
    """
    if isinstance(value, float):
        return value if math.isfinite(value) else non_finite_token(value)
    if isinstance(value, list):
        spelled = [spell_non_finite(item) for item in value]
        return (
            value if all(new is old for new, old in zip(spelled, value, strict=True)) else spelled
        )
    if isinstance(value, dict):
        changed = False
        result = {}
        for key, item in value.items():
            new = spell_non_finite(item)
            changed = changed or new is not item
            result[key] = new
        return result if changed else value
    return value


def encode_ref(obj: PyDexpiBaseModel) -> dict[str, str]:
    """Encode a *reference* to an object: its id and class, not its content.

    An envelope would copy the target's whole composition subtree into the value even though
    the id is all that identifies it. A reference names the object and nothing more; a reader
    resolves it against the model it reads, and can tell when the object is not there instead of
    holding a detached copy.

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The object referred to.

    Returns
    -------
    dict
        ``{"dexpi_ref": obj.id, "dexpi_class": type(obj).__name__}``.
    """
    return {"dexpi_ref": obj.id, "dexpi_class": type(obj).__name__}


def is_ref(value: object) -> bool:
    """Return ``True`` if *value* is a reference written by :func:`encode_ref`."""
    return isinstance(value, dict) and isinstance(value.get("dexpi_ref"), str)


def is_envelope(value: object) -> bool:
    """Return ``True`` if *value* is an object envelope written by :func:`encode_value`."""
    return (
        isinstance(value, dict)
        and isinstance(value.get("dexpi_class"), str)
        and isinstance(value.get("data"), dict)
    )
