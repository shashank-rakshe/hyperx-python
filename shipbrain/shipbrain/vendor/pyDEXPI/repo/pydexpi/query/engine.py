"""The main Query API entry point for pyDEXPI models.

``QueryEngine`` provides a developer-friendly interface for looking up,
filtering, and navigating objects inside an ``EngineeringModel``.  It
reuses existing toolkit and NetworkX graph logic where possible.
"""

from __future__ import annotations

import networkx as nx
from pydantic import BaseModel

from pydexpi.loaders.graph_loader import AbstractGraphLoader, GraphLoaderPipeline
from pydexpi.pydexpi_classes.plant import piping
from pydexpi.pydexpi_classes.pydexpi_classes import (
    ConceptualObject,
    Diagram,
    EngineeringModel,
    PyDexpiBaseModel,
    RepresentationGroup,
)
from pydexpi.query.errors import AmbiguousTagError, ObjectNotFoundError
from pydexpi.query.index import ModelIndex
from pydexpi.query.resolver import Resolver
from pydexpi.query.results import (
    ConnectionResult,
    FreePort,
    NodeState,
    ObjectDescription,
    PathResult,
)
from pydexpi.query.search import SearchResultPage, _search_objects_from_index
from pydexpi.toolkits import base_model_utils as bmu
from pydexpi.toolkits.display_name import get_display_name, get_tag


def _is_empty(value: object) -> bool:
    """Whether a data value carries nothing: ``None``, an empty string or
    container, or a data model (e.g. a ``MultiLanguageString`` with no strings)
    whose every field is itself empty."""
    if value is None:
        return True
    if isinstance(value, str):
        return value == ""
    if isinstance(value, (list, tuple, set, dict)):
        return len(value) == 0
    if isinstance(value, BaseModel):
        return all(_is_empty(getattr(value, name)) for name in type(value).model_fields)
    return False


class QueryEngine:
    """High-level query layer over an ``EngineeringModel``.

    The engine lazily builds indexes and a NetworkX graph on first use
    and caches them for subsequent queries.

    Parameters
    ----------
    model : EngineeringModel
        The engineering model to query.
    graph_loader : Callable[[PyDexpiBaseModel], nx.MultiDiGraph], optional
        Custom function to convert the model into a NetworkX graph.  If not provided, a default
        loader is used.
    """

    def __init__(
        self,
        model: EngineeringModel,
        graph_loader: AbstractGraphLoader | None = None,
    ) -> None:
        self._model = model
        self._index: ModelIndex | None = None
        self._resolver: Resolver | None = None
        self._graph: nx.MultiDiGraph | None = None

        self._graph_loader = graph_loader or GraphLoaderPipeline("complete")

    # ------------------------------------------------------------------
    # Internals (lazy init)
    # ------------------------------------------------------------------

    @property
    def index(self) -> ModelIndex:
        """The underlying ``ModelIndex`` (lazily built)."""
        if self._index is None:
            self._index = ModelIndex(self._model)
        return self._index

    @property
    def resolver(self) -> Resolver:
        """The underlying ``Resolver`` (lazily built)."""
        if self._resolver is None:
            self._resolver = Resolver(self.index)
        return self._resolver

    @property
    def graph(self) -> nx.MultiDiGraph:
        """The full DEXPI graph (lazily built via ``GraphLoader``)."""
        if self._graph is None:
            self._graph = self._graph_loader.dexpi_to_graph(self._model)
        return self._graph

    # ------------------------------------------------------------------
    # Cache management
    # ------------------------------------------------------------------

    def invalidate(self) -> None:
        """Invalidate all cached indexes and graphs.

        Call this after mutating the model so that subsequent queries
        reflect the updated state.
        """
        if self._index is not None:
            self._index.invalidate()
        self._index = None
        self._resolver = None
        self._graph = None

    # ------------------------------------------------------------------
    # ID lookup
    # ------------------------------------------------------------------

    def get_by_id(self, object_id: str) -> PyDexpiBaseModel:
        """Return the unique object with the given ID.

        Parameters
        ----------
        object_id : str
            The ``id`` attribute of the desired object.

        Returns
        -------
        PyDexpiBaseModel
            The matching domain object.

        Raises
        ------
        ObjectNotFoundError
            If no object with that ID exists.
        """
        obj = self.index.by_id.get(object_id)
        if obj is None:
            raise ObjectNotFoundError(object_id, lookup_type="id")
        return obj

    # ------------------------------------------------------------------
    # Tag lookup
    # ------------------------------------------------------------------

    def find_by_tag(self, tag: str, *, type: str | None = None) -> list[PyDexpiBaseModel]:
        """Return all objects with the given tag.

        Parameters
        ----------
        tag : str
            The tag to search for, as :func:`pydexpi.toolkits.display_name.get_tag` resolves
            it: ``tagName`` for equipment, ``subTagName`` for nozzles, ``lineNumber`` for piping
            network systems, ``pipingComponentName`` for valves, ``identifier`` for the objects
            of a DEXPI 2.0 process model, and so on.
            Printed instrument tags (e.g. ``"PI-4712.01"``) are additional lookup keys.
        type : str, optional
            Case-sensitive concrete or DEXPI parent class name, as in :meth:`find_all`.
            Use this to distinguish an instrument number from its loop's number.

        Returns
        -------
        list[PyDexpiBaseModel]
            All matching objects (may be empty).
        """
        matches = list(self.index.by_tag.get(tag, []))
        if type is not None:
            allowed = {id(obj) for obj in self.index.by_type.get(type, [])}
            matches = [obj for obj in matches if id(obj) in allowed]
        return matches

    def get_by_tag(self, tag: str, *, type: str | None = None) -> PyDexpiBaseModel:
        """Return the unique object with the given tag.

        Parameters
        ----------
        tag : str
            The tag to search for, resolved as in :meth:`find_by_tag`.
        type : str, optional
            Case-sensitive concrete or DEXPI parent class name. Applied before checking
            uniqueness; multiple instruments of the requested type remain ambiguous.

        Returns
        -------
        PyDexpiBaseModel
            The single matching domain object.

        Raises
        ------
        ObjectNotFoundError
            If no object has the given tag.
        AmbiguousTagError
            If more than one object has the given tag. Process identifiers repeat in real
            files -- a stream and a material state both identified ``"1"`` -- so on a process
            model this is an expected answer, not a defect; use :meth:`find_by_tag` there.
        """
        matches = self.find_by_tag(tag, type=type)
        if len(matches) == 0:
            raise ObjectNotFoundError(tag, lookup_type="tag")
        if len(matches) > 1:
            raise AmbiguousTagError(tag, len(matches))
        return matches[0]

    # ------------------------------------------------------------------
    # Type filtering
    # ------------------------------------------------------------------

    def find_all(
        self,
        *,
        type: str | None = None,
        has_graphic: bool | None = None,
    ) -> list[PyDexpiBaseModel]:
        """Return objects matching the given filters.

        Starts from the most selective indexed set and applies remaining
        filters on top.

        Parameters
        ----------
        type : str, optional
            Filter by class name (case-sensitive, matches concrete class
            and DEXPI parent classes).
        has_graphic : bool, optional
            If ``True``, keep only objects that have at least one graphic
            representation.  If ``False``, keep only those without.

        Returns
        -------
        list[PyDexpiBaseModel]
            All matching objects.
        """
        # Start from the most selective candidate set
        if type is not None:
            candidates = list(self.index.by_type.get(type, []))
        else:
            candidates = list(self.index.all_instances)

        # Apply remaining filters
        if has_graphic is not None:
            gfx = self.index.graphics_by_semantic_id
            candidates = [obj for obj in candidates if (obj.id in gfx) == has_graphic]

        return candidates

    # ------------------------------------------------------------------
    # Connectivity / neighbor queries
    # ------------------------------------------------------------------

    def neighbors(self, ref: str | PyDexpiBaseModel) -> ConnectionResult:
        """Return immediate graph neighbors of the referenced object.

        Uses the full DEXPI graph (all edge types).

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            Object instance, ID, or tag.

        Returns
        -------
        ConnectionResult
            The source object and its neighbors.
        """
        obj = self.resolver.resolve_one(ref)
        g = self.graph
        if obj.id not in g:
            return ConnectionResult(source=obj, neighbors=[])

        neighbor_ids: set[str] = set()
        # Successors
        neighbor_ids.update(g.successors(obj.id))
        # Predecessors
        neighbor_ids.update(g.predecessors(obj.id))
        # Remove self-loops
        neighbor_ids.discard(obj.id)

        neighbor_objs = [self.index.by_id[nid] for nid in neighbor_ids if nid in self.index.by_id]
        return ConnectionResult(source=obj, neighbors=neighbor_objs)

    def find_connections(self, ref: str | PyDexpiBaseModel) -> ConnectionResult:
        """Return objects connected to the referenced object.

        This is an alias for ``neighbors`` kept for API discoverability.

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            Object instance, ID, or tag.

        Returns
        -------
        ConnectionResult
            The source object and its connected neighbors.
        """
        return self.neighbors(ref)

    # ------------------------------------------------------------------
    # Path queries
    # ------------------------------------------------------------------

    def find_paths(
        self,
        source_ref: str | PyDexpiBaseModel,
        target_ref: str | PyDexpiBaseModel,
        *,
        max_depth: int = 10,
        max_paths: int = 10,
    ) -> PathResult:
        """Find simple paths between two objects in the DEXPI graph.

        Uses ``nx.all_simple_paths`` on an undirected view of the graph
        so that paths are found regardless of edge direction.

        Parameters
        ----------
        source_ref : str or PyDexpiBaseModel
            Starting object (instance, ID, or tag).
        target_ref : str or PyDexpiBaseModel
            Ending object (instance, ID, or tag).
        max_depth : int, default 10
            Maximum path length (number of edges).
        max_paths : int, default 10
            Maximum number of paths to return.

        Returns
        -------
        PathResult
            The source, target, and discovered paths.
        """
        source = self.resolver.resolve_one(source_ref)
        target = self.resolver.resolve_one(target_ref)

        g = self.graph
        if source.id not in g or target.id not in g:
            return PathResult(source=source, target=target, paths=[])

        undirected = g.to_undirected(as_view=True)

        paths: list[list[PyDexpiBaseModel]] = []
        for raw_path in nx.all_simple_paths(undirected, source.id, target.id, cutoff=max_depth):
            obj_path = [self.index.by_id[nid] for nid in raw_path if nid in self.index.by_id]
            paths.append(obj_path)
            if len(paths) >= max_paths:
                break

        return PathResult(source=source, target=target, paths=paths)

    # ------------------------------------------------------------------
    # Inspection
    # ------------------------------------------------------------------

    def describe(self, ref: str | PyDexpiBaseModel) -> ObjectDescription:
        """Describe the referenced object: its data, where it sits, its nodes.

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            Object instance, ID, or tag.

        Returns
        -------
        ObjectDescription
            The object's type and tag, the data attributes that carry a value,
            its composition owners (nearest first), the piping segment and
            system it belongs to, and its own piping nodes with their
            connection state.

        Raises
        ------
        ObjectNotFoundError
            If *ref* matches nothing.
        AmbiguousTagError
            If *ref* is a tag shared by several objects.
        """
        obj = self.resolver.resolve_one(ref)
        owners: list[PyDexpiBaseModel] = []
        parent = self.index.parent_of(obj)
        while parent is not None:
            owners.append(parent)
            parent = self.index.parent_of(parent)
        attributes = {
            name: value
            for name, value in bmu.get_data_attributes(obj).items()
            if not _is_empty(value)
        }
        nodes = [
            NodeState(node=node, connected=self.index.is_node_connected(node))
            for node in getattr(obj, "nodes", None) or []
        ]
        return ObjectDescription(
            object=obj,
            object_id=obj.id,
            dexpi_type=type(obj).__name__,
            tag_name=get_tag(obj),
            display_name=get_display_name(obj),
            attributes=attributes,
            owners=owners,
            segment=next((o for o in owners if isinstance(o, piping.PipingNetworkSegment)), None),
            system=next((o for o in owners if isinstance(o, piping.PipingNetworkSystem)), None),
            nodes=nodes,
        )

    def free_ports(self, ref: str | PyDexpiBaseModel) -> list[FreePort]:
        """Return the piping nodes of the referenced object nothing connects to.

        For equipment the ports are its nozzles' nodes; for anything with
        nodes of its own (a nozzle, a valve, an off-page connector) they are
        those nodes.

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            Object instance, ID, or tag.

        Returns
        -------
        list[FreePort]
            Each unconnected node with the item that owns it, in model order.
        """
        obj = self.resolver.resolve_one(ref)
        items = [obj, *(getattr(obj, "nozzles", None) or [])]
        return [
            FreePort(item=item, node=node)
            for item in items
            for node in getattr(item, "nodes", None) or []
            if not self.index.is_node_connected(node)
        ]

    # ------------------------------------------------------------------
    # Graphic / representation queries
    # ------------------------------------------------------------------

    def find_graphics_for(self, ref: str | PyDexpiBaseModel) -> list[RepresentationGroup]:
        """Return all graphic representations for the referenced object.

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            Object instance, ID, or tag.

        Returns
        -------
        list[RepresentationGroup]
            Graphic groups representing the object (may be empty).
        """
        obj = self.resolver.resolve_one(ref)
        return list(self.index.graphics_by_semantic_id.get(obj.id, []))

    def find_semantic_for_graphic(self, graphic_id: str) -> ConceptualObject:
        """Return the conceptual object represented by a graphic group.

        Parameters
        ----------
        graphic_id : str
            The ID of a ``RepresentationGroup``.

        Returns
        -------
        ConceptualObject
            The represented conceptual object.

        Raises
        ------
        ObjectNotFoundError
            If no semantic mapping exists for the given graphic ID.
        """
        obj = self.index.semantic_by_graphic_id.get(graphic_id)
        if obj is None:
            raise ObjectNotFoundError(graphic_id, lookup_type="graphic_id")
        return obj

    # ------------------------------------------------------------------
    # Sheet queries
    # ------------------------------------------------------------------

    def find_on_sheet(self, sheet_name: str) -> list[PyDexpiBaseModel]:
        """Return all conceptual objects visible on the named diagram/sheet.

        Searches the diagram tree for ``RepresentationGroup`` nodes whose
        closest ancestor diagram has a matching ``name``.

        Parameters
        ----------
        sheet_name : str
            The name of the diagram / sheet.

        Returns
        -------
        list[PyDexpiBaseModel]
            Conceptual objects represented on that sheet.
        """
        if self._model.diagram is None:
            return []

        result_ids: set[str] = set()
        self._collect_objects_on_sheet(
            self._model.diagram, sheet_name, result_ids, is_on_sheet=False
        )

        return [self.index.by_id[oid] for oid in result_ids if oid in self.index.by_id]

    # ------------------------------------------------------------------
    # Search
    # ------------------------------------------------------------------

    def search_objects(
        self,
        query: str,
        *,
        scope: str = "all",
        limit: int | None = 50,
        offset: int = 0,
        include_graphics: bool = False,
        fuzzy_threshold: float = 0.6,
    ) -> SearchResultPage:
        """Search conceptual objects by tag name, type, or ID.

        Reuses the engine's cached index for efficiency.  See
        :func:`~pydexpi.query.search.search_objects` for full parameter docs.

        Parameters
        ----------
        query : str
            The search string (case-insensitive, whitespace-trimmed).
        scope : {"all", "tags", "types", "ids"}
            Which fields to match against.
        limit : int or None
            Maximum results per page.  ``None`` returns all matches.
        offset : int
            Number of results to skip (for pagination).
        include_graphics : bool
            Populate :attr:`~pydexpi.query.search.SearchMatch.graphic_ids`
            from the diagram index when ``True``.
        fuzzy_threshold : float
            Minimum similarity ratio for fuzzy matches.  ``0.0`` disables
            fuzzy matching.

        Returns
        -------
        SearchResultPage
            Ranked, paginated results with pre-pagination ``total``.

        Raises
        ------
        ValueError
            If *query* is empty/whitespace or *scope* is unknown.
        """
        return _search_objects_from_index(
            self.index,
            query,
            scope=scope,
            limit=limit,
            offset=offset,
            include_graphics=include_graphics,
            fuzzy_threshold=fuzzy_threshold,
        )

    def _collect_objects_on_sheet(
        self,
        group: PyDexpiBaseModel,
        sheet_name: str,
        result_ids: set[str],
        is_on_sheet: bool,
    ) -> None:
        """Recursively walk diagram groups to find objects on a sheet."""

        # Check if this group is the matching Diagram
        if isinstance(group, Diagram) and getattr(group, "name", None) == sheet_name:
            is_on_sheet = True

        # If we're on the target sheet and this is a RepresentationGroup with
        # a semantic reference, record it.
        if is_on_sheet and isinstance(group, RepresentationGroup) and group.represents is not None:
            result_ids.add(group.represents.id)

        # Recurse into children
        if hasattr(group, "groups") and isinstance(group.groups, list):
            for child in group.groups:
                self._collect_objects_on_sheet(child, sheet_name, result_ids, is_on_sheet)
