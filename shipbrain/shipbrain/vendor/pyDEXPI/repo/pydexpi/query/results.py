"""Typed result objects returned by the Query API."""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel


@dataclass(frozen=True)
class ConnectionResult:
    """Result of a connectivity query.

    Parameters
    ----------
    source : PyDexpiBaseModel
        The object whose connections were queried.
    neighbors : list[PyDexpiBaseModel]
        The connected neighbor objects.
    """

    source: PyDexpiBaseModel
    neighbors: list[PyDexpiBaseModel] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.neighbors)

    def __iter__(self) -> Iterator[PyDexpiBaseModel]:
        return iter(self.neighbors)

    def __bool__(self) -> bool:
        return bool(self.neighbors)


@dataclass(frozen=True)
class PathResult:
    """Result of a path query between two objects.

    Parameters
    ----------
    source : PyDexpiBaseModel
        The starting object.
    target : PyDexpiBaseModel
        The ending object.
    paths : list[list[PyDexpiBaseModel]]
        Each inner list is a sequence of domain objects forming a path.
    """

    source: PyDexpiBaseModel
    target: PyDexpiBaseModel
    paths: list[list[PyDexpiBaseModel]] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.paths)

    def __iter__(self) -> Iterator[list[PyDexpiBaseModel]]:
        return iter(self.paths)

    def __bool__(self) -> bool:
        return bool(self.paths)


@dataclass(frozen=True)
class SearchMatch:
    """A single object that matched a search query.

    Parameters
    ----------
    object_id : str
        The ``id`` of the matched DEXPI object.
    dexpi_type : str
        The concrete class name of the object (e.g. ``"CentrifugalPump"``).
    tag_name : str or None
        The tag of the object as :func:`pydexpi.toolkits.display_name.get_tag`
        resolves it, or ``None`` when it carries none.
    label : str
        The object's display name, from
        :func:`pydexpi.toolkits.display_name.get_display_name`, e.g.
        ``"Tank (TK-101)"``. Never the raw object id unless the model chose
        that id itself; ``object_id`` carries the id.
    matched_field : str or None
        The field that produced the winning score (``"tag_name"``,
        ``"dexpi_type"``, or ``"object_id"``).
    matched_value : str or None
        The raw field value that was matched against the query.
    score : float or None
        Relevance score in the range ``(0, 1]``.  Higher is better.
    graphic_ids : list[str]
        IDs of :class:`~pydexpi.pydexpi_classes.RepresentationGroup` objects
        that represent this conceptual object.  Empty when
        ``include_graphics=False`` or when no graphics exist.
    """

    object_id: str
    dexpi_type: str
    tag_name: str | None
    label: str
    matched_field: str | None
    matched_value: str | None
    score: float | None
    graphic_ids: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class SearchResultPage:
    """Paginated, ranked search results.

    Parameters
    ----------
    query : str
        The (trimmed) query string that produced these results.
    total : int
        Total number of matching objects *before* pagination.
    limit : int or None
        The ``limit`` that was applied.
    offset : int
        The ``offset`` that was applied.
    results : list[SearchMatch]
        The slice of matches for this page.
    """

    query: str
    total: int
    limit: int | None
    offset: int
    results: list[SearchMatch] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.results)

    def __iter__(self) -> Iterator[SearchMatch]:
        return iter(self.results)

    def __bool__(self) -> bool:
        return bool(self.results)


@dataclass(frozen=True)
class NodeState:
    """One piping node of an object, and whether a connection uses it.

    Parameters
    ----------
    node : PyDexpiBaseModel
        The ``PipingNode``.
    connected : bool
        ``True`` when a ``PipingConnection`` starts or ends at the node, or a
        segment starts or ends at it from outside the segment.
    """

    node: PyDexpiBaseModel
    connected: bool


@dataclass(frozen=True)
class FreePort:
    """A piping node nothing connects to yet, and the item that owns it.

    Parameters
    ----------
    item : PyDexpiBaseModel
        The node's owner: a nozzle for equipment, else the object itself.
    node : PyDexpiBaseModel
        The unconnected ``PipingNode``.
    """

    item: PyDexpiBaseModel
    node: PyDexpiBaseModel


@dataclass(frozen=True)
class ObjectDescription:
    """What an object is, where it sits, and what it holds.

    Parameters
    ----------
    object : PyDexpiBaseModel
        The described object.
    object_id : str
        Its ``id``.
    dexpi_type : str
        Its concrete class name.
    tag_name : str or None
        Its tag as :func:`pydexpi.toolkits.display_name.get_tag` resolves it,
        or ``None``.
    display_name : str
        Its caption from :func:`pydexpi.toolkits.display_name.get_display_name`,
        e.g. ``"Globe Valve (66KL21)"``.
    attributes : dict[str, Any]
        The data attributes that carry a value (``None`` and empty values are
        left out), as the model holds them.
    owners : list[PyDexpiBaseModel]
        The composition chain above the object, nearest first, ending at the
        conceptual model's root.
    segment : PyDexpiBaseModel or None
        The ``PipingNetworkSegment`` the object belongs to, if any.
    system : PyDexpiBaseModel or None
        The ``PipingNetworkSystem`` the object belongs to, if any.
    nodes : list[NodeState]
        The object's own piping nodes and whether each is connected. Empty
        for an object without nodes (use :meth:`QueryEngine.free_ports` for
        equipment, whose ports are its nozzles' nodes).
    """

    object: PyDexpiBaseModel
    object_id: str
    dexpi_type: str
    tag_name: str | None
    attributes: dict[str, Any] = field(default_factory=dict)
    owners: list[PyDexpiBaseModel] = field(default_factory=list)
    segment: PyDexpiBaseModel | None = None
    system: PyDexpiBaseModel | None = None
    nodes: list[NodeState] = field(default_factory=list)
    # Keyword-only, so constructors that pass the earlier fields positionally keep working.
    display_name: str = field(kw_only=True)
