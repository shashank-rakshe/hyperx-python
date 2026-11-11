"""Helpers for narrowing a diff to part of a model."""

from __future__ import annotations

from collections.abc import Iterable

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model, get_instances_by_ids

__all__ = ["subtree_ids"]


def subtree_ids(model: PyDexpiBaseModel, root_ids: str | Iterable[str]) -> set[str]:
    """Return the ids of the objects at and below the given objects in *model*.

    "Below" is composition: a piece of equipment's subtree holds its nozzles and chambers, a
    piping network system's its segments and their pipes, valves and nodes. Objects only
    *referenced* from the subtree are not in it.

    Parameters
    ----------
    model : PyDexpiBaseModel
        The model to look in.
    root_ids : str or iterable of str
        The id of the subtree root, or several.

    Returns
    -------
    set of str
        The ids of every root found and all its composition descendants. A root id that is not
        in the model contributes nothing -- in a diff, a scope root may exist on one side only.
    """
    wanted = [root_ids] if isinstance(root_ids, str) else list(root_ids)
    ids: set[str] = set()
    for root in get_instances_by_ids(model, wanted).values():
        ids.update(
            instance.id
            for instance in get_all_instances_in_model(root)
            if getattr(instance, "id", None) is not None
        )
    return ids
