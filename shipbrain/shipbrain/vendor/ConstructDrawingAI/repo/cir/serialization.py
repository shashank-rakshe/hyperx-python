"""(De)serialization of CIR documents.

Two interchange formats, each with a round-trip-stable codec pair:

* **JSON** — the human-readable canonical interchange (:func:`to_json` /
  :func:`from_json`).
* **Compact binary** — for storage/transport at scale. Two codecs:

  - **msgpack** (:func:`to_msgpack` / :func:`from_msgpack`) — the default compact
    binary form: small, fast, language-neutral. Requires the ``msgpack`` package
    (a core dependency).
  - **gzip-JSON** (:func:`to_gzip_json` / :func:`from_gzip_json`) — a
    dependency-free stdlib fallback (gzip-compressed UTF-8 JSON).

:func:`save` / :func:`load` dispatch on the file suffix (``.json``, ``.json.gz``,
``.cir`` / ``.msgpack`` / ``.mpk``). On load, the document's ``schema_version`` (if
present) is checked for compatibility before validation, so an incompatible
document fails with a clear :class:`~cir.exceptions.SchemaVersionError` rather than
a confusing field error.

All functions are generic over any pydantic model, so they work on a full
:class:`~cir.schema.DrawingSet` or any sub-model.
"""

from __future__ import annotations

import gzip
import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any, TypeVar

from pydantic import BaseModel

from .exceptions import SerializationError
from .version import check_compatible

T = TypeVar("T", bound=BaseModel)

#: File suffixes routed to the msgpack codec by :func:`save` / :func:`load`.
BINARY_SUFFIXES: frozenset[str] = frozenset({".cir", ".msgpack", ".mpk"})


def _maybe_check_version(data: Mapping[str, Any]) -> None:
    """Check ``schema_version`` for compatibility, if the payload carries one."""
    version = data.get("schema_version")
    if isinstance(version, str):
        check_compatible(version)


# ---------------------------------------------------------------------------
# dict / JSON
# ---------------------------------------------------------------------------
def to_dict(obj: BaseModel) -> dict[str, Any]:
    """Serialize ``obj`` to a JSON-compatible dict (enums→values, datetimes→ISO)."""
    return obj.model_dump(mode="json")


def from_dict(cls: type[T], data: Mapping[str, Any]) -> T:
    """Validate a JSON-compatible mapping back into a model of type ``cls``."""
    _maybe_check_version(data)
    return cls.model_validate(dict(data))


def to_json(obj: BaseModel, *, indent: int | None = None) -> str:
    """Serialize ``obj`` to a JSON string."""
    return obj.model_dump_json(indent=indent)


def from_json(cls: type[T], data: str | bytes) -> T:
    """Validate a JSON string/bytes back into a model of type ``cls``."""
    try:
        raw = json.loads(data)
    except json.JSONDecodeError as exc:
        raise SerializationError(f"Invalid JSON for {cls.__name__}: {exc}") from exc
    if not isinstance(raw, Mapping):
        raise SerializationError(
            f"Expected a JSON object for {cls.__name__}, got {type(raw).__name__}."
        )
    return from_dict(cls, raw)


# ---------------------------------------------------------------------------
# Compact binary: msgpack (default)
# ---------------------------------------------------------------------------
def _import_msgpack() -> Any:
    try:
        import msgpack
    except ImportError as exc:  # pragma: no cover - exercised only without the dep
        raise SerializationError(
            "The 'msgpack' package is required for binary CIR serialization. "
            "Install it with `pip install msgpack` (it is a core dependency)."
        ) from exc
    return msgpack


def to_msgpack(obj: BaseModel) -> bytes:
    """Serialize ``obj`` to the compact msgpack binary form."""
    msgpack = _import_msgpack()
    packed: bytes = msgpack.packb(obj.model_dump(mode="json"), use_bin_type=True)
    return packed


def from_msgpack(cls: type[T], data: bytes) -> T:
    """Validate msgpack bytes back into a model of type ``cls``."""
    msgpack = _import_msgpack()
    try:
        raw = msgpack.unpackb(data, raw=False)
    except Exception as exc:
        raise SerializationError(f"Invalid msgpack for {cls.__name__}: {exc}") from exc
    if not isinstance(raw, Mapping):
        raise SerializationError(
            f"Expected a mapping in msgpack for {cls.__name__}, got {type(raw).__name__}."
        )
    return from_dict(cls, raw)


# ---------------------------------------------------------------------------
# Compact binary: gzip-JSON (dependency-free fallback)
# ---------------------------------------------------------------------------
def to_gzip_json(obj: BaseModel, *, compresslevel: int = 9) -> bytes:
    """Serialize ``obj`` to gzip-compressed UTF-8 JSON bytes."""
    return gzip.compress(obj.model_dump_json().encode("utf-8"), compresslevel=compresslevel)


def from_gzip_json(cls: type[T], data: bytes) -> T:
    """Validate gzip-compressed UTF-8 JSON bytes back into a model of type ``cls``."""
    try:
        decompressed = gzip.decompress(data)
    except (OSError, EOFError) as exc:
        raise SerializationError(f"Invalid gzip stream for {cls.__name__}: {exc}") from exc
    return from_json(cls, decompressed)


# ---------------------------------------------------------------------------
# File save / load (suffix dispatch)
# ---------------------------------------------------------------------------
def save(obj: BaseModel, path: str | Path, *, indent: int | None = 2) -> Path:
    """Write ``obj`` to ``path``, choosing the codec from the suffix.

    * ``*.json``    → pretty JSON text
    * ``*.json.gz`` → gzip-JSON binary
    * ``*.cir`` / ``*.msgpack`` / ``*.mpk`` → msgpack binary
    """
    p = Path(path)
    name = p.name.lower()
    if name.endswith(".json.gz"):
        p.write_bytes(to_gzip_json(obj))
    elif p.suffix.lower() == ".json":
        p.write_text(to_json(obj, indent=indent), encoding="utf-8")
    elif p.suffix.lower() in BINARY_SUFFIXES:
        p.write_bytes(to_msgpack(obj))
    else:
        raise SerializationError(
            f"Cannot infer CIR format from path {p.name!r}; use one of: "
            f".json, .json.gz, {', '.join(sorted(BINARY_SUFFIXES))}."
        )
    return p


def load(cls: type[T], path: str | Path) -> T:
    """Read a model of type ``cls`` from ``path``, choosing the codec by suffix."""
    p = Path(path)
    name = p.name.lower()
    if name.endswith(".json.gz"):
        return from_gzip_json(cls, p.read_bytes())
    if p.suffix.lower() == ".json":
        return from_json(cls, p.read_text(encoding="utf-8"))
    if p.suffix.lower() in BINARY_SUFFIXES:
        return from_msgpack(cls, p.read_bytes())
    raise SerializationError(
        f"Cannot infer CIR format from path {p.name!r}; use one of: "
        f".json, .json.gz, {', '.join(sorted(BINARY_SUFFIXES))}."
    )
