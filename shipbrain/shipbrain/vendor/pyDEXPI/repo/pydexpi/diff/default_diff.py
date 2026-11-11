from collections.abc import Iterable

from pydexpi.diff.engine import PyDexpiDiffEngine
from pydexpi.diff.results import DiffResult
from pydexpi.diff.scope import subtree_ids
from pydexpi.diff.semantic_equality import id_equality
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel


def id_diff(
    model1: EngineeringModel,
    model2: EngineeringModel,
    *,
    track_order: bool = False,
    scope: Iterable[str] | None = None,
) -> DiffResult:
    """Compute the diff between two models using ID-based equality.

    Every call builds its own ``PyDexpiDiffEngine``. The engine keeps its object and match maps
    as instance state for the duration of a diff, so an engine shared between calls -- this
    function used to reuse one module-wide instance -- is neither re-entrant nor thread-safe: two
    concurrent diffs would overwrite each other's maps. Building an engine is cheap; the diff
    itself dominates.

    Parameters
    ----------
    model1 : EngineeringModel
        The first model to compare.
    model2 : EngineeringModel
        The second model to compare.
    track_order : bool, optional
        Also report reorders of order-significant composition lists (z-order, a segment's flow
        order); see ``pydexpi.diff.ordering``. Off by default.
    scope : iterable of str, optional
        Ids of objects to restrict the result to, each with its composition subtree in either
        model -- one piece of equipment, a piping network system, a segment. This *filters* the
        whole-model diff: everything is still compared, so a valve moved out of a scoped segment
        is reported as moved, with its new parent outside the scope. To compare two subtrees on
        their own instead, use ``PyDexpiDiffEngine.diff_objects``.

    Returns
    -------
    DiffResult
        The result of the diff operation, containing all detected changes (within *scope*, if
        given).

    Raises
    ------
    ValueError
        If a *scope* id is in neither model -- more likely a typo than an intent.
    """
    result = PyDexpiDiffEngine(id_equality, track_order=track_order).diff(model1, model2)
    if scope is None:
        return result
    roots = [scope] if isinstance(scope, str) else list(scope)
    old_ids = subtree_ids(model1, roots)
    new_ids = subtree_ids(model2, roots)
    unknown = sorted(set(roots) - old_ids - new_ids)
    if unknown:
        raise ValueError(f"Scope ids found in neither model: {', '.join(unknown)}")
    return result.for_objects(old_ids | new_ids)
