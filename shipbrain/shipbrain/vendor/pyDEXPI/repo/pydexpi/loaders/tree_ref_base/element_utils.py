"""Shared helpers for tree-reference element traversal.

Both the exporter and the format converter walk attribute values that may be a single object,
a list of objects, or `None`. This module holds the traversal helper they have in common."""

from collections.abc import Callable
from typing import Any


def call_on_list_or_object_or_none(
    func: Callable, obj: Any, sort_list: bool = False, sorting_key: Callable | None = None
) -> Any:
    """Call a function on an object, list of objects, or return None if the object is None.

    Parameters
    ----------
    func : Callable
        The function to call on the object.
    obj : Any
        The object to process, which can be a list, a single object, or None.
    sort_list : bool, optional
        Whether to sort the list before applying the function, by default False.
    sorting_key : callable, optional
        The key function to use for sorting if sort_list is True, by default None.

    Returns
    -------
    Any
        The result of the function call on the object, a list of results if the input
        was a list, or None if the input was None.
    """
    if obj is None:
        return None
    elif isinstance(obj, list):
        if sort_list:
            obj = sorted(obj, key=sorting_key)
        return [func(item) for item in obj]
    else:
        return func(obj)
