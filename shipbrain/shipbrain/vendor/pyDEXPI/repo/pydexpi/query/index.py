"""Cached indexes over a pyDEXPI ``EngineeringModel``.

The ``ModelIndex`` builds several dictionaries on first access and caches
them so that repeated lookups are O(1) on average.
"""

from __future__ import annotations

import logging
from collections import defaultdict

from pydexpi.pydexpi_classes.plant import piping
from pydexpi.pydexpi_classes.pydexpi_classes import (
    ConceptualObject,
    EngineeringModel,
    GraphicsGroup,
    ProcessInstrumentationFunction,
    PyDexpiBaseModel,
    RepresentationGroup,
)
from pydexpi.toolkits import base_model_utils as bmu, model_toolkit as mt
from pydexpi.toolkits.display_name import get_tag, instrument_tag

logger = logging.getLogger(__name__)


class ModelIndex:
    """Pre-computed lookup indexes for a pyDEXPI model.

    Parameters
    ----------
    model : EngineeringModel
        The engineering model to index.
    """

    def __init__(self, model: EngineeringModel) -> None:
        self._model = model
        self._by_id: dict[str, PyDexpiBaseModel] | None = None
        self._by_tag: dict[str, list[PyDexpiBaseModel]] | None = None
        self._by_type: dict[str, list[PyDexpiBaseModel]] | None = None
        self._graphics_by_semantic_id: dict[str, list[RepresentationGroup]] | None = None
        self._semantic_by_graphic_id: dict[str, ConceptualObject] | None = None
        self._all_instances: list[PyDexpiBaseModel] | None = None
        self._parent_by_identity: dict[int, PyDexpiBaseModel] | None = None
        self._connected_nodes: set[int] | None = None

    # ------------------------------------------------------------------
    # Public accessors (lazy-built)
    # ------------------------------------------------------------------

    @property
    def all_instances(self) -> list[PyDexpiBaseModel]:
        """Return all ``PyDexpiBaseModel`` instances in the conceptual model."""
        if self._all_instances is None:
            self._build_instance_cache()
        return self._all_instances  # type: ignore[return-value]

    @property
    def by_id(self) -> dict[str, PyDexpiBaseModel]:
        """Map from object ID to the domain object."""
        if self._by_id is None:
            self._build_id_index()
        return self._by_id  # type: ignore[return-value]

    @property
    def by_tag(self) -> dict[str, list[PyDexpiBaseModel]]:
        """Map from tag (as :func:`~pydexpi.toolkits.display_name.get_tag` resolves it) to the
        matching objects (may be >1)."""
        if self._by_tag is None:
            self._build_tag_index()
        return self._by_tag  # type: ignore[return-value]

    @property
    def by_type(self) -> dict[str, list[PyDexpiBaseModel]]:
        """Map from class name to objects of that type."""
        if self._by_type is None:
            self._build_type_index()
        return self._by_type  # type: ignore[return-value]

    @property
    def graphics_by_semantic_id(self) -> dict[str, list[RepresentationGroup]]:
        """Map from conceptual object ID to its graphic representation(s)."""
        if self._graphics_by_semantic_id is None:
            self._build_graphics_index()
        return self._graphics_by_semantic_id  # type: ignore[return-value]

    @property
    def semantic_by_graphic_id(self) -> dict[str, ConceptualObject]:
        """Map from graphic group ID to the conceptual object it represents."""
        if self._semantic_by_graphic_id is None:
            self._build_graphics_index()
        return self._semantic_by_graphic_id  # type: ignore[return-value]

    def parent_of(self, obj: PyDexpiBaseModel) -> PyDexpiBaseModel | None:
        """The object that composes *obj*, by identity, or ``None`` at the root."""
        if self._parent_by_identity is None:
            self._build_parent_index()
        return self._parent_by_identity.get(id(obj))  # type: ignore[union-attr]

    def is_node_connected(self, node: PyDexpiBaseModel) -> bool:
        """Whether a piping connection, or a segment end from outside the
        segment, uses *node* (by identity)."""
        if self._connected_nodes is None:
            self._build_connected_nodes()
        return id(node) in self._connected_nodes  # type: ignore[operator]

    # ------------------------------------------------------------------
    # Cache invalidation
    # ------------------------------------------------------------------

    def invalidate(self) -> None:
        """Drop all cached indexes so they will be rebuilt on next access."""
        self._by_id = None
        self._by_tag = None
        self._by_type = None
        self._graphics_by_semantic_id = None
        self._semantic_by_graphic_id = None
        self._all_instances = None
        self._parent_by_identity = None
        self._connected_nodes = None

    # ------------------------------------------------------------------
    # Internal builders
    # ------------------------------------------------------------------

    def _build_instance_cache(self) -> None:
        """Collect all ``PyDexpiBaseModel`` instances from the conceptual model."""
        if self._model.conceptualModel is None:
            self._all_instances = []
            return
        raw = mt.get_all_instances_in_model(self._model.conceptualModel, None)
        self._all_instances = [i for i in raw if isinstance(i, PyDexpiBaseModel)]
        logger.debug(
            "Built instance cache: %d of %d walked objects are PyDexpiBaseModel instances",
            len(self._all_instances),
            len(raw),
        )

    def _build_parent_index(self) -> None:
        """Map each composed object (by identity) to the object composing it."""
        parents: dict[int, PyDexpiBaseModel] = {}
        for instance in self.all_instances:
            for value in bmu.get_composition_attributes(instance).values():
                children = value if isinstance(value, list) else [value]
                for child in children:
                    if isinstance(child, PyDexpiBaseModel):
                        parents.setdefault(id(child), instance)
        self._parent_by_identity = parents

    def _build_connected_nodes(self) -> None:
        """Collect the identities of every piping node a connection uses.

        A connection's ``sourceNode``/``targetNode`` always count. A segment's
        end node counts too, except when the segment starts or ends at one of
        its own items: that names the item's node without connecting anything
        to it. An end node whose item is unset still counts.
        """
        connected: set[int] = set()
        # Annotated, because the two branches below disagree on length: a connection always has
        # exactly two ends, while a segment contributes only the ends that are not its own items.
        # Without this mypy fixes the type from the first branch and rejects the second.
        ends: tuple[piping.PipingNode | None, ...]
        for instance in self.all_instances:
            if isinstance(instance, piping.PipingConnection):
                ends = (instance.sourceNode, instance.targetNode)
            elif isinstance(instance, piping.PipingNetworkSegment):
                own_items = {id(item) for item in instance.items}
                ends = tuple(
                    node
                    for item, node in (
                        (instance.sourceItem, instance.sourceNode),
                        (instance.targetItem, instance.targetNode),
                    )
                    if item is None or id(item) not in own_items
                )
            else:
                continue
            connected.update(id(node) for node in ends if node is not None)
        self._connected_nodes = connected

    def _build_id_index(self) -> None:
        """Build the ``by_id`` dictionary."""
        self._by_id = {}
        for instance in self.all_instances:
            self._by_id[instance.id] = instance

    def _build_tag_index(self) -> None:
        """Build the ``by_tag`` dictionary (tag -> list of objects).

        Tags come from :func:`pydexpi.toolkits.display_name.get_tag`, the same resolution the
        display name and the diff use. Instrumentation functions also have their printed
        :func:`~pydexpi.toolkits.display_name.instrument_tag` as an additional lookup key;
        their canonical number and every collision on either key are preserved.
        """
        tag_map: dict[str, list[PyDexpiBaseModel]] = defaultdict(list)
        untagged = 0
        for instance in self.all_instances:
            tag = get_tag(instance)
            if tag is not None:
                tag_map[tag].append(instance)
            else:
                untagged += 1
            if isinstance(instance, ProcessInstrumentationFunction):
                printed_tag = instrument_tag(instance)
                if printed_tag is not None and printed_tag != tag:
                    tag_map[printed_tag].append(instance)
        self._by_tag = dict(tag_map)
        # How many objects `get_tag` could not tag is the single most useful number when a
        # tag search comes back empty, and it is otherwise invisible to the caller.
        logger.debug(
            "Built tag index: %d distinct tags, %d objects without a canonical tag",
            len(self._by_tag),
            untagged,
        )

    def _build_type_index(self) -> None:
        """Build the ``by_type`` dictionary (class name -> list of objects)."""
        type_map: dict[str, list[PyDexpiBaseModel]] = defaultdict(list)
        for instance in self.all_instances:
            # Index by the concrete class name
            type_map[type(instance).__name__].append(instance)
            # Also index by all parent class names in the DEXPI hierarchy
            for cls in type(instance).__mro__:
                cls_name = cls.__name__
                if cls_name in (
                    "PyDexpiBaseModel",
                    "PyDexpiDataTypeBaseModel",
                    "ABC",
                    "BaseModel",
                    "object",
                ):
                    break
                if cls_name != type(instance).__name__:
                    type_map[cls_name].append(instance)
        self._by_type = dict(type_map)

    def _build_graphics_index(self) -> None:
        """Build the graphic <-> semantic mappings from the diagram tree."""
        graphics_map: dict[str, list[RepresentationGroup]] = defaultdict(list)
        semantic_map: dict[str, ConceptualObject] = {}

        if self._model.diagram is not None:
            self._walk_graphics_groups(self._model.diagram.groups, graphics_map, semantic_map)

        self._graphics_by_semantic_id = dict(graphics_map)
        self._semantic_by_graphic_id = semantic_map

    def _walk_graphics_groups(
        self,
        groups: list[GraphicsGroup],
        graphics_map: dict[str, list[RepresentationGroup]],
        semantic_map: dict[str, ConceptualObject],
    ) -> None:
        """Recursively walk the diagram group tree to populate graphic indexes."""
        for group in groups:
            if isinstance(group, RepresentationGroup):
                if group.represents is not None:
                    sem_id = group.represents.id
                    graphics_map[sem_id].append(group)
                    semantic_map[group.id] = group.represents
                # Recurse into nested groups
                if hasattr(group, "groups") and group.groups:
                    self._walk_graphics_groups(group.groups, graphics_map, semantic_map)
            elif hasattr(group, "groups") and isinstance(getattr(group, "groups", None), list):
                self._walk_graphics_groups(group.groups, graphics_map, semantic_map)
