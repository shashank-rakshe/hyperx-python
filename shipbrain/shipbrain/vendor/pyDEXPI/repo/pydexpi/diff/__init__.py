"""Semantic diff functionality for comparing pyDEXPI models.

This package provides tools for comparing two pyDEXPI models and identifying
differences in their structure, attributes, and connectivity. The diff engine
matches objects using customizable semantic equality strategies and produces
structured diff results.

Key Components
--------------
PyDexpiDiffEngine : class
    Main engine for computing semantic diffs between two models.
DiffResult : class
    Container for all changes detected between two models. A versioned Pydantic model:
    ``result.model_dump(mode="json")`` is its machine-readable form.
ChangeDomain : type alias
    ``"conceptual"``, ``"graphics"`` or ``"metadata"`` -- what a change concerns.
SemanticEquality : type alias
    Type alias for semantic equality functions (Callable[[T, T], bool]).
id_equality : function
    Built-in function that matches objects by their stable id field.
TagEquality : class
    Built-in callable class that matches objects by their tag attributes.

Example
-------
>>> from pydexpi.diff import PyDexpiDiffEngine, id_equality
>>> engine = PyDexpiDiffEngine(id_equality)
>>> result = engine.diff(model1, model2)
>>> print(f"Found {len(result.added_objects)} new objects")

Or just:
>>> from pydexpi.diff import id_diff
>>> result = id_diff(model1, model2)
"""

from pydexpi.diff.default_diff import id_diff
from pydexpi.diff.domains import CHANGE_DOMAINS, ChangeDomain
from pydexpi.diff.engine import PyDexpiDiffEngine, SemanticEquality
from pydexpi.diff.ordering import is_order_significant
from pydexpi.diff.results import (
    DIFF_FORMAT_VERSION,
    AddedObject,
    AttributeChange,
    DiffEntry,
    DiffResult,
    Matching,
    ModifiedObject,
    MovedObject,
    RemovedObject,
)
from pydexpi.diff.scope import subtree_ids
from pydexpi.diff.semantic_equality import TagEquality, id_equality

__all__ = [
    "CHANGE_DOMAINS",
    "DIFF_FORMAT_VERSION",
    "AddedObject",
    "AttributeChange",
    "ChangeDomain",
    "DiffEntry",
    "DiffResult",
    "Matching",
    "ModifiedObject",
    "MovedObject",
    "PyDexpiDiffEngine",
    "RemovedObject",
    "SemanticEquality",
    "TagEquality",
    "id_diff",
    "id_equality",
    "is_order_significant",
    "subtree_ids",
]
