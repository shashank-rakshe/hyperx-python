"""Tell a pickle written by other classes from one these classes can read back.

Unpickling restores each object's ``__dict__`` and validates nothing, so a model pickled under
other pyDEXPI classes -- an earlier DEXPI version, another builder output -- comes back without an
error, holding fields its class no longer has and lacking ones it has gained. It fails later, with
an ``AttributeError`` from whatever reads a missing field first. This module finds that out at
load time instead, in two ways:

- **a stamp**, which `PickleSerializer.save` appends to the file: the DEXPI version, the pyDEXPI
  version and, for every model class and enumeration the pickle holds, a signature of the class.
  It is read *before* anything is unpickled, and a pickle of another DEXPI version, or holding a
  class that is gone or has changed, is refused naming it;
- **a structural check** for a pickle without a stamp, such as one an earlier pyDEXPI wrote: once
  unpickled, every object's ``__dict__`` is compared with the fields of its class.

The stamp follows the pickle's own end, which a pickle reader never looks past, so the file is
still a plain pickle of the model: ``pickle.load`` and an earlier pyDEXPI read it as before.

Neither check is a security measure. Unpickling runs code the file names, the stamp is only what
the file says about itself, and the structural check runs after that code has run. Unpickle only a
file you wrote, or trust as you would trust code.
"""

from __future__ import annotations

import hashlib
import importlib
import io
import json
import pickle
import re
from collections import deque
from collections.abc import Iterable, Iterator
from enum import Enum
from functools import cached_property
from typing import Any

from pydantic import BaseModel

from pydexpi.attribution import get_version
from pydexpi.pydexpi_classes._spec_info import DEXPI_SPEC_VERSION

#: What a stamp calls itself, and the layout of the one written here.
STAMP_FORMAT = "pydexpi-pickle"
STAMP_VERSION = 1

#: The signature recorded for an enumeration: that it is one. Members are unpickled by value, and
#: one that is gone fails there, so a new member does not make an old pickle another class's.
ENUM_SIGNATURE = "enum"

# The file's last line: the marker, then the length of the JSON stamp on the line before it.
_MARKER = b"pydexpi-pickle-stamp:"
_TAIL = re.compile(rb"\n" + _MARKER + rb"(\d{12})\n")
_TAIL_LENGTH = 1 + len(_MARKER) + 12 + 1

#: Exceptions an unpickle raises when a class the pickle names is not there to restore it: the
#: class or its module is gone, an enumeration lost the value, or the state has another shape.
RESTORE_ERRORS = (AttributeError, ImportError, KeyError, TypeError, ValueError)

# How ``pickle`` starts the ValueError for a protocol this Python does not read. That is about the
# Python, not the classes, so it is passed on as it is.
_UNSUPPORTED_PROTOCOL = "unsupported pickle protocol"

# How many classes or fields an error lists before it counts the rest.
_LISTED = 5


class IncompatiblePickleError(ValueError):
    """A pickle cannot be read back by these classes: it was written by other ones.

    A pickle is tied to the classes that wrote it and is never converted. Read the model from its
    DEXPI XML or JSON source, which pyDEXPI converts from an earlier DEXPI version, and pickle it
    again.
    """


_ADVICE = (
    "A pickle is read back by the classes that wrote it and is never converted: load the model "
    "from its DEXPI XML or JSON source, which pyDEXPI converts, and pickle it again."
)


def class_key(cls: type) -> str:
    """How a stamp names *cls*: its module and qualified name, as a pickle refers to it."""
    return f"{cls.__module__}:{cls.__qualname__}"


def class_signature(cls: type) -> str | None:
    """What of *cls* a pickled object depends on, or None for a class that is not stamped.

    A model class is its field names, each with its DEXPI attribute category: the names are the
    keys of the ``__dict__`` an unpickle restores, and the category is whether a value is owned or
    referred to, which a field can change while keeping its name (``Port.subReference`` did). A
    field's type is deliberately left out: its spelling differs between Python versions, and a
    pickle is read back by another Python as long as the classes are the same.
    """
    if issubclass(cls, Enum):
        return ENUM_SIGNATURE
    if not issubclass(cls, BaseModel):
        return None
    fields = sorted(
        (name, _attribute_category(field.json_schema_extra))
        for name, field in cls.model_fields.items()
    )
    return hashlib.sha256(json.dumps(fields).encode()).hexdigest()[:16]


def _attribute_category(extra: Any) -> str:
    category = extra.get("attribute_category") if isinstance(extra, dict) else None
    return category if isinstance(category, str) else ""


class _ClassRecordingPickler(pickle.Pickler):
    """A pickler that notes every model class and enumeration it writes an object of."""

    def __init__(self, file: io.BytesIO) -> None:
        super().__init__(file)
        self.classes: dict[str, str] = {}
        self._seen: set[type] = set()

    def reducer_override(self, obj: Any) -> Any:
        """Record the class of *obj*, and leave pickling it to the default."""
        cls = obj if isinstance(obj, type) else type(obj)
        if cls not in self._seen:
            self._seen.add(cls)
            signature = class_signature(cls)
            if signature is not None:
                self.classes[class_key(cls)] = signature
        return NotImplemented


def dumps(obj: Any) -> bytes:
    """Pickle *obj* and append the stamp of the classes that wrote it.

    Returns
    -------
    bytes
        A pickle of *obj*, which ``pickle.loads`` reads as it is, followed by the stamp.
    """
    buffer = io.BytesIO()
    pickler = _ClassRecordingPickler(buffer)
    pickler.dump(obj)
    stamp = json.dumps(
        {
            "format": STAMP_FORMAT,
            "stamp_version": STAMP_VERSION,
            "dexpi_version": DEXPI_SPEC_VERSION,
            "pydexpi_version": get_version(),
            "classes": dict(sorted(pickler.classes.items())),
        }
    ).encode()
    return buffer.getvalue() + b"\n" + stamp + b"\n" + _MARKER + b"%012d\n" % len(stamp)


def read_stamp(data: bytes) -> dict[str, Any] | None:
    """The stamp at the end of *data*, or None when it carries none this module can read.

    A damaged stamp, or one of a layout a later pyDEXPI introduces, is none: such a pickle is
    checked object by object like any other without a stamp.
    """
    tail = _TAIL.fullmatch(data[-_TAIL_LENGTH:])
    if tail is None:
        return None
    end = len(data) - _TAIL_LENGTH
    start = end - int(tail.group(1))
    if start < 1 or data[start - 1 : start] != b"\n":
        return None
    try:
        stamp = json.loads(data[start:end])
    except ValueError:
        return None
    if not isinstance(stamp, dict) or stamp.get("format") != STAMP_FORMAT:
        return None
    return stamp if stamp.get("stamp_version") == STAMP_VERSION else None


def loads(data: bytes, source: str = "the pickle") -> Any:
    """Unpickle *data*, refusing a pickle written by other classes than the ones loaded now.

    Only for data you trust: unpickling runs code the data names, and no check here changes that.

    Parameters
    ----------
    data : bytes
        A pickle, with or without a stamp.
    source : str, optional
        What to call it in an error, e.g. its path.

    Returns
    -------
    Any
        The unpickled object.

    Raises
    ------
    IncompatiblePickleError
        If the stamp names another DEXPI version or a class that is gone or has changed; if the
        pickle cannot be restored for want of a class; or, for a pickle without a stamp, if an
        object does not hold exactly the fields of its class.
    """
    stamp = read_stamp(data)
    if stamp is not None:
        _check_stamp(stamp, source)
    try:
        obj = pickle.loads(data)
    except RESTORE_ERRORS as error:
        if isinstance(error, ValueError) and str(error).startswith(_UNSUPPORTED_PROTOCOL):
            # This Python cannot read the pickle at all, whatever classes wrote it.
            raise
        raise IncompatiblePickleError(
            f"Cannot load {source}: {_written_by(stamp)}, and these classes (pyDEXPI "
            f"{get_version()}, DEXPI {DEXPI_SPEC_VERSION}) cannot restore it: "
            f"{type(error).__name__}: {error}. {_ADVICE}"
        ) from error
    if stamp is None:
        _check_structure(obj, source)
    return obj


def _written_by(stamp: dict[str, Any] | None) -> str:
    if stamp is None:
        return "it carries no stamp of the classes that wrote it"
    return (
        f"it was written by pyDEXPI {stamp.get('pydexpi_version')} for DEXPI "
        f"{stamp.get('dexpi_version')}"
    )


def _check_stamp(stamp: dict[str, Any], source: str) -> None:
    """Refuse a stamp of another DEXPI version, or naming a class that is gone or has changed."""
    if stamp.get("dexpi_version") != DEXPI_SPEC_VERSION:
        raise IncompatiblePickleError(
            f"Cannot load {source}: {_written_by(stamp)}, and this is pyDEXPI {get_version()} "
            f"for DEXPI {DEXPI_SPEC_VERSION}. {_ADVICE}"
        )
    classes = stamp.get("classes")
    if not isinstance(classes, dict):
        raise IncompatiblePickleError(
            f"Cannot load {source}: its stamp does not list the classes it holds. {_ADVICE}"
        )
    differing = [
        f"{key.rpartition(':')[2]} ({problem})"
        for key, signature in classes.items()
        if (problem := _class_problem(key, signature)) is not None
    ]
    if differing:
        raise IncompatiblePickleError(
            f"Cannot load {source}: {_written_by(stamp)}, and {len(differing)} of the "
            f"{len(classes)} classes it holds are not those classes in this pyDEXPI "
            f"{get_version()}: {_some(differing)}. {_ADVICE}"
        )


def _class_problem(key: str, signature: object) -> str | None:
    """Why the class a stamp names *key* is not the one it stamped, or None when it is."""
    module_name, _, qualified_name = key.partition(":")
    try:
        found: Any = importlib.import_module(module_name)
        for part in qualified_name.split("."):
            found = getattr(found, part)
    except (ImportError, AttributeError, TypeError, ValueError):
        # TypeError: a relative module name, which only a hand-made or damaged stamp carries.
        return "gone"
    if not isinstance(found, type):
        return "no longer a class"
    return None if class_signature(found) == signature else "its fields changed"


def _check_structure(root: Any, source: str) -> None:
    """Refuse an unpickled graph holding an object whose fields are not those of its class.

    A value a ``functools.cached_property`` of the class stored in ``__dict__`` is not a field and
    is not counted. An object built without validation (``model_construct`` with fields left out)
    looks the same as one other classes wrote, which is why the error names both.
    """
    mismatches = [
        (obj, extra, missing)
        for obj in _models(root)
        if (extra := obj.__dict__.keys() - type(obj).model_fields.keys() - _cached_names(type(obj)))
        | (missing := type(obj).model_fields.keys() - obj.__dict__.keys())
    ]
    if not mismatches:
        return
    first, extra, missing = mismatches[0]
    object_id = first.__dict__.get("id")
    details = [
        f"holds {_some(map(repr, sorted(extra)))}, which the class does not have" if extra else "",
        f"lacks {_some(map(repr, sorted(missing)))}, which the class has" if missing else "",
    ]
    classes = {type(obj).__name__ for obj, _, _ in mismatches}
    raise IncompatiblePickleError(
        f"Cannot load {source}: it carries no stamp of the classes that wrote it, and "
        f"{len(mismatches)} object(s) of {len(classes)} class(es) in it do not hold the fields of "
        f"their class in this pyDEXPI {get_version()} (DEXPI {DEXPI_SPEC_VERSION}), so it was "
        f"written by other classes, or holds objects built without validation. The first is {type(first).__name__}"
        f"{f' {object_id!r}' if isinstance(object_id, str) else ''}, which "
        f"{' and '.join(detail for detail in details if detail)}; the classes are "
        f"{_some(sorted(classes))}. {_ADVICE}"
    )


def _cached_names(cls: type) -> set[str]:
    """The ``functools.cached_property`` attributes of *cls*, which store their value in ``__dict__``."""
    return {
        name
        for base in cls.__mro__
        for name, value in vars(base).items()
        if isinstance(value, cached_property)
    }


def _models(root: Any) -> Iterator[BaseModel]:
    """Every pydantic model reachable from *root* through fields and containers, once each.

    Breadth first, so the first mismatch reported is the one nearest the root.
    """
    seen: set[int] = set()
    pending = deque([root])
    while pending:
        obj = pending.popleft()
        if id(obj) in seen:
            continue
        seen.add(id(obj))
        if isinstance(obj, BaseModel):
            yield obj
            pending.extend(obj.__dict__.values())
        elif isinstance(obj, dict):
            pending.extend(obj.values())
        elif isinstance(obj, (list, tuple, set, frozenset)):
            pending.extend(obj)


def _some(names: Iterable[str]) -> str:
    """*names* as a list, the first few spelled out and the rest counted."""
    names = list(names)
    listed = ", ".join(names[:_LISTED])
    return listed if len(names) <= _LISTED else f"{listed} and {len(names) - _LISTED} more"
