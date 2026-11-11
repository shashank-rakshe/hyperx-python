"""Dataset preparers: download + convert-to-CIR, one per dataset.

A preparer is registered here keyed by its dataset's registry name. The
``datasets.prepare`` CLI looks one up and runs it. Add a new dataset by writing a
:class:`~datasets.preparers.base.DatasetPreparer` subclass and listing it in
``_PREPARERS`` below.
"""

from __future__ import annotations

from .base import DatasetPreparer, PrepareResult
from .delp import DELPPreparer
from .pidqa import PIDQAPreparer

_PREPARERS: dict[str, type[DatasetPreparer]] = {
    PIDQAPreparer.name: PIDQAPreparer,
    DELPPreparer.name: DELPPreparer,
}


def available_preparers() -> list[str]:
    """Names of datasets that have a download+convert preparer implemented."""
    return sorted(_PREPARERS)


def has_preparer(name: str) -> bool:
    """Whether a preparer exists for ``name`` (case-insensitive)."""
    return any(key.lower() == name.lower() for key in _PREPARERS)


def get_preparer_class(name: str) -> type[DatasetPreparer]:
    """Return the preparer class registered for ``name`` (case-insensitive)."""
    for key, cls in _PREPARERS.items():
        if key.lower() == name.lower():
            return cls
    raise KeyError(f"No preparer implemented for {name!r}. Available: {available_preparers()}.")


__all__ = [
    "DatasetPreparer",
    "PrepareResult",
    "PIDQAPreparer",
    "DELPPreparer",
    "available_preparers",
    "has_preparer",
    "get_preparer_class",
]
