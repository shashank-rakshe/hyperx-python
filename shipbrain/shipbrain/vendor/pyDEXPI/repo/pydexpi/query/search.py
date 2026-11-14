"""Search API for pyDEXPI models.

Provides :func:`search_objects`, a ranked, paginated search over conceptual
DEXPI objects in an :class:`~pydexpi.pydexpi_classes.EngineeringModel`.

Quick start::

    from pydexpi.query import QueryEngine, search_objects

    # Standalone — useful in scripts and notebooks
    page = search_objects(model, "TK-101")
    for match in page.results:
        print(match.label, match.dexpi_type, match.score)

    # Via QueryEngine — reuses the cached index
    engine = QueryEngine(model)
    page = engine.search_objects("pump", scope="types")

Extensibility
-------------
The search loop is driven by :class:`SearchField` instances collected in
:data:`_SCOPE_FIELDS`.  To add a new searchable field (e.g. ``"property"``
values, sheet names, or fluid codes), subclass :class:`SearchField`, implement
:meth:`~SearchField.extract`, and add an instance to the relevant scope lists.
No other changes are needed.
"""

from __future__ import annotations

import difflib
from abc import ABC, abstractmethod

from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, PyDexpiBaseModel
from pydexpi.query.index import ModelIndex
from pydexpi.query.results import SearchMatch, SearchResultPage
from pydexpi.toolkits.display_name import get_display_name, get_tag

# ---------------------------------------------------------------------------
# SearchField — extensible field descriptor
# ---------------------------------------------------------------------------


class SearchField(ABC):
    """Describes one searchable field on a DEXPI object.

    Parameters
    ----------
    name : str
        Logical field name reported in :attr:`~pydexpi.query.results.SearchMatch.matched_field`.
    base_score : float
        Score assigned for an exact match on this field.  Prefix, substring,
        and fuzzy matches are fractions of this value.
    fuzzy_multiplier : float
        Fraction of ``base_score`` used as the ceiling for fuzzy matches.
        Should be set so that fuzzy scores fall strictly below substring scores.
    """

    def __init__(self, name: str, base_score: float, fuzzy_multiplier: float = 0.55) -> None:
        self.name = name
        self.base_score = base_score
        self.fuzzy_multiplier = fuzzy_multiplier

    @abstractmethod
    def extract(self, obj: PyDexpiBaseModel) -> str | None:
        """Return the string value to match against, or ``None`` to skip."""


class _TagField(SearchField):
    def extract(self, obj: PyDexpiBaseModel) -> str | None:
        return get_tag(obj)


class _TypeField(SearchField):
    def extract(self, obj: PyDexpiBaseModel) -> str | None:
        return type(obj).__name__


class _IdField(SearchField):
    def extract(self, obj: PyDexpiBaseModel) -> str | None:
        return obj.id


_TAG_FIELD = _TagField(
    name="tag_name",
    base_score=1.0,
    fuzzy_multiplier=0.55,  # max fuzzy tag = 0.55, below substring (0.6)
)
_TYPE_FIELD = _TypeField(
    name="dexpi_type",
    base_score=0.5,
    fuzzy_multiplier=0.50,  # max fuzzy type = 0.25, below substring (0.3)
)
_ID_FIELD = _IdField(
    name="object_id",
    base_score=0.25,
    fuzzy_multiplier=0.0,  # fuzzy on UUIDs is not meaningful — disabled
)

_SCOPE_FIELDS: dict[str, list[SearchField]] = {
    "all": [_TAG_FIELD, _TYPE_FIELD, _ID_FIELD],
    "tags": [_TAG_FIELD],
    "types": [_TYPE_FIELD],
    "ids": [_ID_FIELD],
}
_VALID_SCOPES: frozenset[str] = frozenset(_SCOPE_FIELDS)


# ---------------------------------------------------------------------------
# Scoring helpers
# ---------------------------------------------------------------------------


def _score_field(
    query_lower: str,
    value_lower: str,
    base_score: float,
    fuzzy_multiplier: float,
    fuzzy_threshold: float,
) -> tuple[float, str] | None:
    """Score ``query_lower`` against ``value_lower`` for one field.

    Returns ``(score, match_kind)`` or ``None`` if no match.

    Match kinds and their scores
    ----------------------------
    - ``"exact"``   → ``base_score``
    - ``"prefix"``  → ``base_score * 0.80``
    - ``"substr"``  → ``base_score * 0.60``
    - ``"fuzzy"``   → ``ratio * base_score * fuzzy_multiplier``
                        (only when ``fuzzy_multiplier > 0`` and ratio ≥ threshold)
    """
    if value_lower == query_lower:
        return base_score, "exact"
    if value_lower.startswith(query_lower):
        return base_score * 0.80, "prefix"
    if query_lower in value_lower:
        return base_score * 0.60, "substr"
    if fuzzy_multiplier > 0.0 and fuzzy_threshold > 0.0:
        ratio = difflib.SequenceMatcher(None, query_lower, value_lower).ratio()
        if ratio >= fuzzy_threshold:
            return ratio * base_score * fuzzy_multiplier, "fuzzy"
    return None


# ---------------------------------------------------------------------------
# Core implementation
# ---------------------------------------------------------------------------


def _search_objects_from_index(
    index: ModelIndex,
    query: str,
    *,
    scope: str,
    limit: int | None,
    offset: int,
    include_graphics: bool,
    fuzzy_threshold: float,
) -> SearchResultPage:
    """Run the search over a pre-built :class:`ModelIndex`."""
    query = query.strip()
    if not query:
        raise ValueError("Search query must not be empty or whitespace.")
    if scope not in _VALID_SCOPES:
        raise ValueError(f"Unknown scope {scope!r}. Allowed values: {sorted(_VALID_SCOPES)}")

    query_lower = query.lower()
    fields = _SCOPE_FIELDS[scope]
    gfx_index = index.graphics_by_semantic_id if include_graphics else {}

    scored: list[tuple[float, str, SearchMatch]] = []

    for obj in index.all_instances:
        best_score: float | None = None
        best_field_name: str | None = None
        best_value: str | None = None

        for sf in fields:
            raw_value = sf.extract(obj)
            if raw_value is None:
                continue
            result = _score_field(
                query_lower,
                raw_value.lower(),
                sf.base_score,
                sf.fuzzy_multiplier,
                fuzzy_threshold,
            )
            if result is None:
                continue
            score, _ = result
            if best_score is None or score > best_score:
                best_score = score
                best_field_name = sf.name
                best_value = raw_value

        if best_score is None:
            continue

        graphic_ids = [rg.id for rg in gfx_index.get(obj.id, [])]

        match = SearchMatch(
            object_id=obj.id,
            dexpi_type=type(obj).__name__,
            tag_name=get_tag(obj),
            label=get_display_name(obj),
            matched_field=best_field_name,
            matched_value=best_value,
            score=best_score,
            graphic_ids=graphic_ids,
        )
        # Sort key: (-score, object_id) for deterministic ordering
        scored.append((-best_score, obj.id, match))

    scored.sort(key=lambda t: (t[0], t[1]))
    all_matches = [t[2] for t in scored]

    total = len(all_matches)
    page = all_matches[offset : (offset + limit) if limit is not None else None]

    return SearchResultPage(
        query=query,
        total=total,
        limit=limit,
        offset=offset,
        results=page,
    )


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def search_objects(
    model: EngineeringModel,
    query: str,
    *,
    scope: str = "all",
    limit: int | None = 50,
    offset: int = 0,
    include_graphics: bool = False,
    fuzzy_threshold: float = 0.6,
) -> SearchResultPage:
    """Search conceptual DEXPI objects by tag name, type, or ID.

    This is the standalone entry point.  If you already have a
    :class:`~pydexpi.query.QueryEngine`, call
    :meth:`~pydexpi.query.QueryEngine.search_objects` instead so that the
    cached index is reused.

    Parameters
    ----------
    model : EngineeringModel
        The model to search.
    query : str
        The search string.  Case-insensitive; leading/trailing whitespace is
        trimmed automatically.
    scope : {"all", "tags", "types", "ids"}
        Which fields to match against.  ``"all"`` searches tag name, DEXPI
        type name, and object ID in that priority order.
    limit : int or None
        Maximum number of results in the returned page.  ``None`` returns all
        matching objects.
    offset : int
        Number of results to skip before the page starts (for pagination).
    include_graphics : bool
        When ``True``, populate :attr:`~pydexpi.query.results.SearchMatch.graphic_ids`
        from the model's diagram index.  If no diagram exists the list stays empty.
    fuzzy_threshold : float
        Minimum ``difflib.SequenceMatcher`` ratio (0–1) for a result to be
        considered a fuzzy match.  Set to ``0.0`` to disable fuzzy matching.

    Returns
    -------
    SearchResultPage
        Ranked, paginated results.  :attr:`SearchResultPage.total` is the
        count *before* pagination.

    Raises
    ------
    ValueError
        If *query* is empty or whitespace-only, or if *scope* is not one of
        the allowed values.

    Examples
    --------
    >>> page = search_objects(model, "TK-101")
    >>> page.total
    1
    >>> page.results[0].label
    'Tank (TK-101)'

    >>> page = search_objects(model, "pump", scope="types", limit=10)
    >>> [m.dexpi_type for m in page]
    ['CentrifugalPump', ...]
    """
    index = ModelIndex(model)
    return _search_objects_from_index(
        index,
        query,
        scope=scope,
        limit=limit,
        offset=offset,
        include_graphics=include_graphics,
        fuzzy_threshold=fuzzy_threshold,
    )
