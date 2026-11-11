from abc import ABC, abstractmethod
from collections.abc import Callable, Sequence
from copy import deepcopy
from enum import Enum
from typing import Literal

import networkx as nx
from networkx import MultiDiGraph

import pydexpi.toolkits.base_model_utils as bmt
import pydexpi.toolkits.equipment_toolkit as et
import pydexpi.toolkits.model_toolkit as mt
from pydexpi.attribution import generator_string
from pydexpi.pydexpi_classes import (
    EngineeringModel,
    PhysicalQuantity,
    PhysicalQuantityVector,
    PyDexpiBaseModel,
    RepresentationGroup,
    RepresentationTypeGroup,
    ShapeUsage,
    pydexpi_classes as dexpi_classes,
)
from pydexpi.pydexpi_classes.pydexpi_classes import (
    InstrumentationActivity,
    InstrumentationSystemActivity,
    ProcessConnection,
    ProcessStep,
    ProcessStepDetail,
)
from pydexpi.toolkits.display_name import get_display_name, get_relationship_display_name
from pydexpi.toolkits.model_provenance import GENERATOR_KEY, get_model_provenance
from pydexpi.toolkits.scalar_coercion import coerce_for_graph

#: The name of every graph level, as accepted by ``graph_level`` arguments throughout pyDEXPI.
#: :data:`GRAPH_LEVELS` maps each to its builder; a test keeps the two in step.
GraphLevelName = Literal["complete", "process", "conceptual", "process_flow"]

#: Suffix of the companion attribute holding the unit of a split ``PhysicalQuantity``.
#: A quantity-typed DEXPI attribute ``foo`` becomes two graph attributes: ``foo`` (the
#: numeric value, a ``float``) and ``foo_unit`` (the ``PhysicalQuantityUnit`` literal, a
#: ``str``).  Exporters and consumers import this rather than hard-coding ``"_unit"``.
UNIT_ATTRIBUTE_SUFFIX = "_unit"

#: Graph attribute holding a DEXPI object's own ``label`` data attribute (the free-text name of a
#: DEXPI 2.0 process object). Every node's ``label`` is its class name -- label matching and the
#: Neo4j node label depend on that -- so the DEXPI attribute is written under this key instead of
#: being overwritten by it.
DEXPI_LABEL_ATTRIBUTE = "dexpiLabel"


def _quantity_attributes(attr_name: str, quantity: PhysicalQuantity) -> dict[str, float | str]:
    """Split a ``PhysicalQuantity`` into two scalar graph attributes.

    Returns ``{attr_name: <value>, attr_name + UNIT_ATTRIBUTE_SUFFIX: <unit>}``.

    The value stays a ``float`` rather than being folded into a string such as ``"1.0 Bar"``:
    GraphML then declares it ``attr.type="double"`` and Neo4j stores a numeric property, so
    range predicates like ``WHERE c.upperLimitDesignPressure > 5`` work.  Flattening
    discarded that structure at the earliest possible point and nothing downstream parsed it
    back apart.

    ``PhysicalQuantity.value`` is a required ``float`` and ``unit`` a required
    ``PhysicalQuantityUnit`` member, so the pair is atomic: both keys are always present
    together and neither can be ``None``.

    The unit is the enum *literal* (``"Bar"``, ``"Metre"``), not the typeset symbol.
    ``exports.table_export.get_attribute_value`` deliberately uses the symbols from
    ``exports.table_locale`` instead; the two vocabularies are separate and are not unified
    here.

    No normalisation happens: the value is exactly what the model carries, in the unit the
    model carries it in.  Canonical/SI conversion and quantity-kind validation are follow-ups
    and are not part of this contract.

    Parameters
    ----------
    attr_name : str
        Name of the DEXPI data attribute holding the quantity.
    quantity : PhysicalQuantity
        The quantity to split.

    Returns
    -------
    dict[str, float | str]
        The value keyed by ``attr_name`` and the unit keyed by
        ``attr_name + UNIT_ATTRIBUTE_SUFFIX``.
    """
    return {
        attr_name: quantity.value,
        f"{attr_name}{UNIT_ATTRIBUTE_SUFFIX}": quantity.unit.value,
    }


def vector_attribute_name(attr_name: str) -> str:
    """The graph attribute holding the values of a ``PhysicalQuantityVector`` in *attr_name*.

    ``values`` for ``QualifiedValue.value`` -- the one attribute DEXPI 2.0.1 puts a vector in,
    a ``Composition``'s fractions -- and ``<attr_name>_values`` for any other. Its unit is
    ``<that name>`` + :data:`UNIT_ATTRIBUTE_SUFFIX`, so ``values`` pairs with ``values_unit``.
    """
    return "values" if attr_name == "value" else f"{attr_name}_values"


def _vector_attributes(attr_name: str, vector: PhysicalQuantityVector) -> dict[str, str]:
    """Split a ``PhysicalQuantityVector`` into its values and its unit, as two graph attributes.

    Returns ``{vector_attribute_name(attr_name): <values>, ... + UNIT_ATTRIBUTE_SUFFIX: <unit>}``.

    The pair lives under its own name rather than ``attr_name``: a ``QualifiedValue``'s ``value``
    is a ``double`` wherever it holds a scalar quantity, and a vector there would be a ``string``
    under the same GraphML key (the type-mixing trap ``Undefined`` used to cause). The values are
    one JSON array, in their order -- position ``i`` is the template's ``i``-th component, and a
    graph attribute holds a scalar only -- with ``null`` for an ``Undefined`` value. The unit is
    the enum literal, as for a scalar quantity.

    Parameters
    ----------
    attr_name : str
        Name of the DEXPI data attribute holding the vector.
    vector : PhysicalQuantityVector
        The vector to split.

    Returns
    -------
    dict[str, str]
        The values and the unit, keyed as above.
    """
    name = vector_attribute_name(attr_name)
    values = coerce_for_graph(list(vector.values))
    attributes = {} if values is None else {name: str(values)}
    attributes[f"{name}{UNIT_ATTRIBUTE_SUFFIX}"] = vector.unit.value
    return attributes


def _merge_node_attributes(base: dict, override: dict) -> dict:
    """Merge two node attribute dicts, keeping value/unit pairs together.

    ``{**base, **override}`` is correct for independent attributes but can desynchronise a
    split ``PhysicalQuantity``.  ``QualifiedValue.value`` may be a bare number or a
    ``PhysicalQuantity``, so the same attribute name can be a bare number on one node and a
    value/unit pair on the other.  A plain merge would then leave the winner's *number*
    standing next to the loser's *unit* — a silently wrong quantity, and one that survives
    into Neo4j as a queryable property.

    The rule enforced here: whichever dict supplies ``<name>`` supplies
    ``<name>_unit`` too, or neither does.

    Parameters
    ----------
    base : dict
        Attributes of the node being collapsed away.
    override : dict
        Attributes of the surviving node; these take precedence.

    Returns
    -------
    dict
        The merged attributes, with every value/unit pair sourced from one dict.
    """
    merged = {**base, **override}
    for name in set(base) | set(override):
        if name.endswith(UNIT_ATTRIBUTE_SUFFIX):
            continue
        unit_key = f"{name}{UNIT_ATTRIBUTE_SUFFIX}"
        if unit_key not in merged:
            continue
        winner = override if name in override else base
        if unit_key in winner:
            merged[unit_key] = winner[unit_key]
        else:
            del merged[unit_key]
    return merged


class AbstractGraphLoader(ABC):
    """Abstract interface for loading a DexpiModel into a NetworkX MultiDiGraph."""

    @abstractmethod
    def dexpi_to_graph(self, dexpi_model: EngineeringModel) -> MultiDiGraph:
        """Parse a pyDEXPI model into a NetworkX graph representation."""

    @abstractmethod
    def graph_to_dexpi(self, graph: MultiDiGraph) -> EngineeringModel:
        """Parse a NetworkX graph back into a pyDEXPI model representation."""


class GraphLoaderPipeline(AbstractGraphLoader):
    """Standard pipeline for loading a DEXPI model to a Networkx graph, with optional abstraction.

    Wraps the functionality of GraphLoader and GraphAbstractor into a single pipeline for
    fast access.

    Attributes
    ----------"""

    def __init__(
        self,
        graph_level: GraphLevelName = "complete",
        embed_shape_usage: bool = False,
        shape_usage_mode: Literal["shapeusage", "position"] = "position",
        stamp_level: bool = True,
    ) -> None:
        """Initialize a new instance of GraphLoaderPipeline.

        Parameters
        ----------
        graph_level : GraphLevelName, default="complete"
            The level of abstraction for the graph representation for the abstractor, one of
            the keys of :data:`GRAPH_LEVELS`.
        embed_shape_usage : bool, default=False
            Whether to embed graphical shape-usage attributes into each node.
        shape_usage_mode : Literal["shapeusage", "position"], default="position"
            Controls how much shape information is embedded.  ``"position"``
            embeds only ``x``/``y``; ``"shapeusage"`` adds rotation, scale,
            mirror flag, shape name and registration number.  Matches the
            default of ``loaders.public.get_graph`` and of every exporter, so
            that omitting the mode behaves the same at every entry point.
        stamp_level : bool, default=True
            Whether to record *graph_level* on the resulting graph and on every
            one of its nodes and edges, via :func:`stamp_graph_level`.
        """
        self.graph_loader = GraphLoader()
        self.embed_shape_usage = embed_shape_usage
        self.shape_usage_mode = shape_usage_mode
        self.graph_level = graph_level
        self.stamp_level = stamp_level
        # Resolve and discard: rejects an invalid level at construction time rather
        # than at parse time. The result is not stored, because dexpi_to_graph
        # resolves through build_level and a second copy could go stale against
        # graph_level.
        resolve_abstraction(graph_level)

    def dexpi_to_graph(self, dexpi_model: EngineeringModel) -> MultiDiGraph:
        """Parse a pyDEXPI model into a NetworkX graph representation, with optional abstraction."""
        graph = self.graph_loader.dexpi_to_graph(dexpi_model)

        if self.embed_shape_usage:
            self.graph_loader.embed_shape_usage(shape_usage_mode=self.shape_usage_mode)
            graph = self.graph_loader.graph

        return build_level(graph, self.graph_level, stamp=self.stamp_level)

    def graph_to_dexpi(self, graph):
        """Parsing from graph back to pyDEXPI is not supported yet."""

        raise NotImplementedError("Parsing from graph back to pyDEXPI is not supported yet.")


class GraphLoader(AbstractGraphLoader):
    """Loads a DEXPI model instance into a NetworkX MultiDiGraph."""

    def dexpi_to_graph(self, dexpi_model: EngineeringModel) -> MultiDiGraph:
        """
        Parse a pyDEXPI model into a NetworkX graph representation.

        Parameters
        ----------
        dexpi_model : EngineeringModel
            The pyDEXPI model to be parsed into a NetworkX graph.

        Returns
        -------
        MultiDiGraph
            The parsed NetworkX graph representation of the pyDEXPI model.
        """
        # Reset plant graph and set dexpi model
        self.graph = MultiDiGraph()
        self.model = dexpi_model

        # Call and return parse to plant
        return self.parse_dexpi_to_graph(dexpi_model)

    def graph_to_dexpi(self, graph: MultiDiGraph) -> EngineeringModel:
        """Parsing the example graph back to pyDEXPI is not supported yet."""
        raise NotImplementedError

    def validate_graph_format(self, graph: MultiDiGraph):
        """Validate a graph against the graph format.

        This method is not yet implemented. The ``graph`` parameter is
        accepted to define the public API and will be used to perform
        validation in a future implementation.
        """
        _ = graph  # parameter is currently unused; kept for future validation logic
        raise NotImplementedError

    def parse_dexpi_to_graph(self, dexpi_model: EngineeringModel) -> nx.MultiDiGraph:
        """Parse a DEXPI model into a NetworkX multigraph.

        Parameters
        ----------
        dexpi_model : EngineeringModel
            The DEXPI model to parse. Must contain a ``conceptualModel`` attribute.

        Returns
        -------
        nx.MultiDiGraph
            Nodes are DEXPI instances; edges are labelled ``"composition"`` or
            ``"reference"``.

        Notes
        -----
        Updates ``self.model`` and ``self.graph`` as a side effect.
        All ``PyDexpiBaseModel`` instances are included.

        Model provenance (project, drawing, revision, originating system) is
        written to ``graph.graph``.  It cannot travel as nodes: the walk below
        starts at ``conceptualModel``, so the ``EngineeringModel`` attributes
        are out of reach, and every abstraction level deletes the ``MetaData``
        node.  The ``generator`` key is written alongside it, naming the software
        that produced the graph rather than the tool that authored the P&ID.
        """
        dexpi_graph = nx.MultiDiGraph()
        dexpi_graph.graph.update(get_model_provenance(dexpi_model))
        # Set after the provenance, not inside it: this names the software writing
        # the graph, whereas get_model_provenance reports facts about the model.
        dexpi_graph.graph[GENERATOR_KEY] = generator_string()

        # Collect all PyDexpiBaseModel instances
        all_instances = mt.get_all_instances_in_model(dexpi_model.conceptualModel, None)
        all_instances = [i for i in all_instances if isinstance(i, PyDexpiBaseModel)]

        # First pass: add nodes with attributes
        self._add_nodes(dexpi_graph, all_instances)

        # Second pass: add edges from composition and reference attributes
        self._add_edges(dexpi_graph, all_instances)

        self.model = dexpi_model
        self.graph = dexpi_graph

        return dexpi_graph

    def _add_nodes(self, dexpi_graph: nx.MultiDiGraph, instances: list) -> None:
        """Add nodes with attributes to the graph for each DEXPI instance.

        Iterates over all instances and builds a node attribute dictionary from
        data attributes and class metadata. Complex types
        (``PyDexpiDataTypeBaseModel``, ``Enum``, ``dict``, ``list``) are serialised
        to GraphML-compatible values. A derived ``displayName`` caption is added
        via :func:`~pydexpi.toolkits.display_name.get_display_name`. ``label`` is the class
        name; a DEXPI ``label`` data attribute is written as :data:`DEXPI_LABEL_ATTRIBUTE`.

        Parameters
        ----------
        dexpi_graph : nx.MultiDiGraph
            The graph to add nodes to.
        instances : list
            List of ``PyDexpiBaseModel`` instances to add as nodes.
        """
        for instance in instances:
            data = bmt.get_data_attributes(instance)
            node_attrs = {}
            for attr_name, attr in data.items():
                # A quantity is the one value that becomes *two* attributes -- a number and a
                # `<name>_unit` -- so it is split here rather than coerced to a single scalar.
                if isinstance(attr, PhysicalQuantity):
                    node_attrs.update(_quantity_attributes(attr_name, attr))
                    continue
                # A vector likewise, under its own name: values (in order) and their unit.
                if isinstance(attr, PhysicalQuantityVector):
                    node_attrs.update(_vector_attributes(attr_name, attr))
                    continue
                # Everything else goes through the one shared decision table. `None` back
                # means the attribute carries nothing and the key is omitted, which is how
                # `Undefined` -- the DEXPI "explicitly no value" marker -- stops becoming the
                # string "{}" under the same attr.name that otherwise holds a double.
                coerced = coerce_for_graph(attr)
                if coerced is not None:
                    node_attrs[attr_name] = coerced

            node_attrs["labels"] = ":".join(
                [cls.__name__ for cls in bmt.get_inheritance_from_dexpi_class(type(instance))]
            )

            # `label` is the class name below, so a DEXPI `label` data attribute -- the name every
            # process step, stream and material carries -- moves aside rather than being lost.
            if "label" in node_attrs:
                node_attrs[DEXPI_LABEL_ATTRIBUTE] = node_attrs.pop("label")
            node_attrs["label"] = instance.__class__.__name__

            # Derived, human-readable caption for graph visualisation. Set here
            # so that every exporter (GraphML, Neo4j CSV, LLM context, CLI)
            # receives the same value.
            node_attrs["displayName"] = get_display_name(instance)

            if instance.__class__.__doc__:
                node_attrs["label_description"] = instance.__class__.__doc__.strip()

            dexpi_graph.add_node(instance.id, **node_attrs)

    def _add_edges(self, dexpi_graph: nx.MultiDiGraph, instances: list) -> None:
        """Add composition and reference edges to the graph for each DEXPI instance.

        Iterates over all instances and creates directed edges for both
        composition attributes (structural containment) and reference attributes
        (cross-references between plant items).

        Parameters
        ----------
        dexpi_graph : nx.MultiDiGraph
            The graph to add edges to.
        instances : list
            List of ``PyDexpiBaseModel`` instances whose relationships are encoded
            as edges.
        """
        for instance in instances:
            for edge_label, get_attrs in [
                ("composition", bmt.get_composition_attributes),
                ("reference", bmt.get_reference_attributes),
            ]:
                for attr_name, attr_field in get_attrs(instance).items():
                    if isinstance(attr_field, PyDexpiBaseModel):
                        dexpi_graph.add_edge(
                            instance.id, attr_field.id, label=edge_label, attr_name=attr_name
                        )
                    elif isinstance(attr_field, list):
                        for i in attr_field:
                            dexpi_graph.add_edge(
                                instance.id, i.id, label=edge_label, attr_name=attr_name
                            )
                    elif attr_field is None:
                        pass
                    else:
                        raise TypeError(
                            f"Unexpected attribute field type {type(attr_field)!r} for "
                            f"attribute '{attr_name}' in instance {getattr(instance, 'id', '<no id>')}"
                        )

    def _find_shape_usage_in_groups(self, groups: list) -> ShapeUsage | None:
        """Recursively search for ShapeUsage in groups.

        Parameters
        ----------
        groups : list
            A list of group objects to search through.

        Returns
        -------
        ShapeUsage | None
            The first ShapeUsage found, or None if no ShapeUsage is found.
        """
        for group in groups:
            # Check if this is a RepresentationTypeGroup (Static, Symbol, etc.) with elements
            if isinstance(group, RepresentationTypeGroup) and hasattr(group, "elements"):
                for element in group.elements:
                    if isinstance(element, ShapeUsage):
                        return element

            # Recursively check nested groups in RepresentationGroup or other group types
            if hasattr(group, "groups"):
                shape_usage = self._find_shape_usage_in_groups(group.groups)
                if shape_usage:
                    return shape_usage

        return None

    def _search_for_representation(
        self, groups: list, target_instance: PyDexpiBaseModel
    ) -> ShapeUsage | None:
        """Search for RepresentationGroup representing the target instance.

        Recursively traverses a list of groups to find a RepresentationGroup
        whose 'represents' attribute matches the target_instance. Once found,
        delegates to _find_shape_usage_in_groups to locate the ShapeUsage within
        that group. Also traverses non-RepresentationGroup groups that contain
        nested groups.

        Parameters
        ----------
        groups : list
            A list of group objects to search through. May contain
            RepresentationGroup instances or other group types with nested
            'groups' attributes.
        target_instance : PyDexpiBaseModel
            The DEXPI instance to find representation for.

        Returns
        -------
        ShapeUsage | None
            The first ShapeUsage found within the matching RepresentationGroup,
            or None if no matching representation or ShapeUsage is found.
        """
        for group in groups:
            if isinstance(group, RepresentationGroup):
                # Check if this RepresentationGroup represents our target
                # Found the representation; its ShapeUsage is inside its own groups.
                if (
                    hasattr(group, "represents")
                    and group.represents == target_instance
                    and hasattr(group, "groups")
                ):
                    return self._find_shape_usage_in_groups(group.groups)

                # Recursively search nested RepresentationGroups
                if hasattr(group, "groups"):
                    result = self._search_for_representation(group.groups, target_instance)
                    if result:
                        return result

            # Also check Static groups and other group types that might contain nested structures
            elif hasattr(group, "groups"):
                result = self._search_for_representation(group.groups, target_instance)
                if result:
                    return result

        return None

    def get_shape_usage(
        self, node_id: str, mode: Literal["shapeusage", "position"] = "shapeusage"
    ) -> dict | None:
        """Extract ShapeUsage information for a given node.

        This function finds the RepresentationGroup associated with a DEXPI object (identified by
        node_id), extracts ShapeUsage information from the graphical representation, and returns
        it as a dictionary of attributes.

        The function searches through the model's diagram structure, looking for RepresentationGroups
        that represent the specified DEXPI object, then extracts ShapeUsage data from Static groups.

        Parameters
        ----------
        node_id : str
            The DEXPI ID of the node to extract ShapeUsage information for.
        mode : Literal["shapeusage", "position"], default="shapeusage"
            Controls which shape usage information to return:
            - ``"position"``: Only return position information as 'x' and 'y' attributes
            - ``"shapeusage"``: Return all shape usage information except shape_id (default)

        Returns
        -------
        dict | None
            A dictionary containing ShapeUsage attributes if found. Depending on mode:
            - position mode: Returns only 'x' and 'y' coordinates
            - shapeusage mode: Returns all attributes except shape_id:
              - shape_name: str - Name of the shape being used
              - position_x: float - X coordinate position
              - position_y: float - Y coordinate position
              - rotation: float - Rotation angle in radians
              - scale_x: float - Horizontal scale factor
              - scale_y: float - Vertical scale factor
              - is_mirrored: bool - Whether the shape is mirrored
              - symbol_registration_number: str | None - Shape's registration number if available
            Returns None if no ShapeUsage is found for this node.

        Examples
        --------
        >>> # Extract shape usage for a specific equipment node
        >>> shape_attrs = loader.get_shape_usage("equipment_123")
        >>> if shape_attrs:
        >>>     print(f"Shape: {shape_attrs['shape_name']}")
        >>>     print(f"Position: ({shape_attrs['position_x']}, {shape_attrs['position_y']})")

        >>> # Extract only position information
        >>> position_attrs = loader.get_shape_usage("equipment_123", mode="position")
        >>> if position_attrs:
        >>>     print(f"Position: ({position_attrs['x']}, {position_attrs['y']})")
        """

        # Check if node exists in graph
        if node_id not in self.graph.nodes:
            return None

        # Search through the diagram structure
        if not hasattr(self.model, "diagram") or self.model.diagram is None:
            return None

        # Get all instances to find the actual object for this node_id
        all_instances = mt.get_all_instances_in_model(self.model.conceptualModel, None)
        target_instance = None
        for instance in all_instances:
            if isinstance(instance, PyDexpiBaseModel) and instance.id == node_id:
                target_instance = instance
                break

        if target_instance is None:
            return None

        # Start search from diagram groups
        shape_usage = None
        if hasattr(self.model.diagram, "groups"):
            shape_usage = self._search_for_representation(
                self.model.diagram.groups, target_instance
            )

        # Extract attributes if ShapeUsage found
        if shape_usage is None:
            return None

        # Build attributes dictionary based on mode
        if mode == "position":
            # Only return position as 'x' and 'y'
            attrs = {
                "x": shape_usage.position.x,
                "y": shape_usage.position.y,
            }
        else:  # mode == "shapeusage" or any other value
            # Return all shape usage information except shape_id
            attrs = {
                "x": shape_usage.position.x,
                "y": shape_usage.position.y,
                "rotation": shape_usage.rotation,
                "scale_x": shape_usage.scaleX,
                "scale_y": shape_usage.scaleY,
                "is_mirrored": shape_usage.isMirrored,
            }

            # Add shape information (but exclude shape_id)
            if hasattr(shape_usage, "shape") and shape_usage.shape:
                if hasattr(shape_usage.shape, "name") and shape_usage.shape.name is not None:
                    attrs["shape_name"] = shape_usage.shape.name
                if (
                    hasattr(shape_usage.shape, "symbolRegistrationNumber")
                    and shape_usage.shape.symbolRegistrationNumber is not None
                ):
                    attrs["symbol_registration_number"] = shape_usage.shape.symbolRegistrationNumber

        # Filter out any None values to ensure GraphML compatibility
        attrs = {k: v for k, v in attrs.items() if v is not None}

        return attrs

    def embed_shape_usage(
        self,
        shape_usage_mode: Literal["shapeusage", "position"] = "shapeusage",
    ) -> dict[str, int]:
        """Embed ShapeUsage information as node attributes for all nodes in the graph.

        This method iterates through all nodes in the graph and embeds ShapeUsage information
        (position, rotation, scale, shape name, etc.) as node attributes.

        Parameters
        ----------
        shape_usage_mode : Literal["shapeusage", "position"], default="shapeusage"
            Controls which shape usage information to embed:
            - ``"position"``: Only embed position information as 'x' and 'y' attributes
            - ``"shapeusage"``: Embed all shape usage information except shape_id (default)

        Returns
        -------
        dict[str, int]
            A dictionary with statistics about the embedding operation:
            - "processed": Total number of nodes processed
            - "embedded": Number of nodes that had ShapeUsage successfully embedded
            - "skipped": Number of nodes skipped (no ShapeUsage found)

        """
        # Process all nodes
        nodes_to_process = list(self.graph.nodes())

        # Statistics
        processed = 0
        embedded = 0
        skipped = 0

        # Process each node
        for node_id in nodes_to_process:
            # Skip if node was removed (e.g., during graph transformations)
            if node_id not in self.graph.nodes:
                continue

            processed += 1

            # Get shape usage for this node
            shape_attrs = self.get_shape_usage(node_id, mode=shape_usage_mode)

            if shape_attrs:
                # Embed the shape attributes into the node
                self.graph.nodes[node_id].update(shape_attrs)
                embedded += 1
            else:
                skipped += 1

        return {
            "processed": processed,
            "embedded": embedded,
            "skipped": skipped,
        }


class GraphAbstractor:
    """Abstracts a NetworkX MultiDiGraph into a simplified MultiDiGraph."""

    def __init__(self, graph: MultiDiGraph | None = None) -> None:
        """Initialize a new instance of GraphAbstractor.

        Parameters
        ----------
        graph : MultiDiGraph or None, default=None
            The MultiDiGraph to abstract. If None, an empty MultiDiGraph is created.
        """
        self.graph = graph if graph is not None else MultiDiGraph()

    def get_nodes_by_label(self, label: str) -> list[str]:
        """
        Get node IDs that have a specific label in their label attribute.

        Parameters
        ----------
        label : str
            The label to search for in node attributes (case-insensitive exact match).
            Checks both 'label' (single value) and 'labels' (colon-separated inheritance chain).

        Returns
        -------
        list[str]
            A list of node IDs that match the label criteria.

        Examples
        --------
        >>> # Get all equipment nodes
        >>> equipment_nodes = loader.get_nodes_by_label("Equipment")
        >>> # Get all Pipe nodes (won't match PipeOffPageConnector)
        >>> pipe_nodes = loader.get_nodes_by_label("Pipe")
        """
        matching_nodes = []

        for node_id, node_data in self.graph.nodes(data=True):
            # Check 'label' attribute (single class name)
            node_label = node_data.get("label", "")
            if isinstance(node_label, str) and node_label.lower() == label.lower():
                matching_nodes.append(node_id)
                continue

            # Check 'labels' attribute (colon-separated inheritance chain)
            node_labels = node_data.get("labels", "")
            if isinstance(node_labels, str) and node_labels:
                # Split by colon and check for exact match in any of the labels
                labels_list = node_labels.split(":")
                if any(lbl.lower() == label.lower() for lbl in labels_list):
                    matching_nodes.append(node_id)

        return matching_nodes

    def _collapsed_edge_attributes(
        self,
        node_id: str,
        inherit_attributes: bool,
        inherited_edge_data: Sequence[dict] = (),
    ) -> dict:
        """
        Build the attributes of the edge that replaces a collapsed node.

        The collapsed node's class name becomes the edge ``label``. Its data
        attributes are copied over when requested, followed by the attributes of
        the edges it replaces. Finally, relationships whose class is registered in
        ``RELATIONSHIP_DISPLAY_NAMES`` get an engineer-facing ``displayName``
        instead of the class-name caption inherited from the node -- a collapsed
        ``MeasuringLineFunction`` reads ``Measurement`` rather than
        ``Measuring Line Function (MeasuringLineFunction1)``.

        Parameters
        ----------
        node_id : str
            The ID of the node being collapsed.
        inherit_attributes : bool
            If True, transfer the node's attributes to the edge, including the
            node's ID as ``collapsed_node_id``.
        inherited_edge_data : Sequence[dict], default=()
            Attribute dictionaries of the replaced edges, merged in order so that
            later entries take precedence.

        Returns
        -------
        dict
            The attributes for the new edge.
        """
        node_attributes = self.graph.nodes[node_id]
        new_edge_attrs = {}

        # Get the node's label attribute to use as the edge label
        node_label = node_attributes.get("label", "")
        if node_label:
            new_edge_attrs["label"] = node_label

        # Inherit node attributes if requested. A plain copy/update is safe for split
        # PhysicalQuantity pairs here -- unlike collapse_node_to_node, this copies one
        # node's dict wholesale, and the edge dicts merged in below never carry data
        # attributes of their own, so a value can never meet a foreign unit.
        if inherit_attributes:
            node_attrs = dict(node_attributes)
            # Add the node_id as an attribute to track the collapsed node
            node_attrs["collapsed_node_id"] = node_id
            new_edge_attrs.update(node_attrs)

        # Preserve original edge attributes if requested
        for edge_data in inherited_edge_data:
            new_edge_attrs.update(edge_data)

        # Set the caption last so that neither an inherited node caption nor the
        # caption of an already collapsed edge can override it.
        relationship_display_name = get_relationship_display_name(
            node_label, new_edge_attrs, node_attributes.get("labels", "")
        )
        if relationship_display_name is not None:
            new_edge_attrs["displayName"] = relationship_display_name

        return new_edge_attrs

    def collapse_node_to_edge(
        self,
        node_id: str,
        inherit_attributes: bool = False,
        inherit_connections: bool = False,
    ) -> None:
        """
        Collapse a node into an edge by removing it and creating an edge between predecessor and successor.

        This operation only works for nodes with exactly 1 incoming edge and 1 outgoing edge (1-to-1 connection).
        The node is removed and a direct connection (edge) is created between the predecessor and successor.
        Optionally, the collapsed node's attributes can be inherited by the new edge, and the original edge
        attributes can be preserved. The new edge is captioned by
        :func:`~pydexpi.toolkits.display_name.get_relationship_display_name`.

        Parameters
        ----------
        node_id : str
            The ID of the node to collapse.
        inherit_attributes : bool, default=False
            If True, transfer the node's attributes to the newly created edge as edge attributes.
            The node's ID will be included as an attribute.
        inherit_connections : bool, default=False
            If True, preserve and merge the original edge attributes from both incoming and outgoing edges.
            If False, only create a basic edge without preserving edge attributes.

        Raises
        ------
        ValueError
            If the node is not found in the graph, or if the node doesn't have exactly 1 incoming
            and 1 outgoing edge.

        Examples
        --------
        >>> # Collapse node to edge without inheritance
        >>> loader.collapse_node_to_edge("node_123")

        >>> # Collapse node to edge with node attributes inherited
        >>> loader.collapse_node_to_edge("node_123", inherit_attributes=True)

        >>> # Collapse node to edge with both node attributes and edge connections inherited
        >>> loader.collapse_node_to_edge("node_123", inherit_attributes=True, inherit_connections=True)
        """
        if node_id not in self.graph.nodes:
            raise ValueError(f"Node {node_id} not found in graph")

        # Get all incoming edges (predecessors)
        in_edges = list(self.graph.in_edges(node_id, keys=True, data=True))
        # Get all outgoing edges (successors)
        out_edges = list(self.graph.out_edges(node_id, keys=True, data=True))

        # Check if we have exactly 1-to-1 connection
        if len(in_edges) != 1 or len(out_edges) != 1:
            raise ValueError(
                f"Node {node_id} must have exactly 1 incoming and 1 outgoing edge. "
                f"Found {len(in_edges)} incoming and {len(out_edges)} outgoing edges."
            )

        # Get the single incoming and outgoing edges
        pred_node = in_edges[0][0]
        in_data = in_edges[0][3]
        succ_node = out_edges[0][1]
        out_data = out_edges[0][3]

        # Prepare edge attributes. When connections are inherited, in_data and
        # out_data are merged in that order, so out_data takes precedence.
        new_edge_attrs = self._collapsed_edge_attributes(
            node_id,
            inherit_attributes=inherit_attributes,
            inherited_edge_data=(in_data, out_data) if inherit_connections else (),
        )

        # Add the new edge between predecessor and successor
        # Use the removed node_id as the edge key
        self.graph.add_edge(pred_node, succ_node, key=node_id, **new_edge_attrs)

        # Remove structural edges left behind, preserving collapsed relationships.
        self._remove_parallel_edges(pred_node, succ_node, exclude_key=node_id)

        # Remove the node (this also removes all connected edges)
        self.graph.remove_node(node_id)

    def collapse_node_to_node(
        self,
        node_id: str,
        to_node_id: str,
        inherit_attributes: bool = False,
        inherit_connections: bool = False,
    ) -> None:
        """
        Collapse a node into another target node by merging their connections and attributes.

        This operation removes the source node and optionally transfers its edges and attributes
        to the target node. All edges connected to the source node can be redirected to the target node.

        Parameters
        ----------
        node_id : str
            The ID of the node to collapse (source node that will be removed).
        to_node_id : str
            The ID of the target node that will absorb the connections and optionally attributes.
        inherit_attributes : bool, default=False
            If True, transfer the source node's attributes to the target node.
            Attributes from the target node take precedence in case of conflicts.
        inherit_connections : bool, default=False
            If True, redirect all edges from the source node to the target node.
            If False, edges are simply removed with the source node.

        Examples
        --------
        >>> # Collapse node to another node (just remove without inheriting)
        >>> loader.collapse_node_to_node("node_123", "node_456")

        >>> # Collapse node with both attributes and connections
        >>> loader.collapse_node_to_node("node_123", "node_456", inherit_attributes=True, inherit_connections=True)

        >>> # Collapse node without inheriting connections (just remove)
        >>> loader.collapse_node_to_node("node_123", "node_456", inherit_connections=False)
        """
        if node_id not in self.graph.nodes:
            raise ValueError(f"Node {node_id} not found in graph")

        if to_node_id not in self.graph.nodes:
            raise ValueError(f"Target node {to_node_id} not found in graph")

        if node_id == to_node_id:
            raise ValueError("Source and target nodes cannot be the same")

        # Inherit attributes if requested
        if inherit_attributes:
            # Get source node attributes
            source_attrs = dict(self.graph.nodes[node_id])
            # Get target node attributes
            target_attrs = dict(self.graph.nodes[to_node_id])

            # Merge attributes: target attributes take precedence. The merge is
            # pair-aware so a split PhysicalQuantity cannot end up with one node's
            # value next to another node's unit -- see _merge_node_attributes.
            merged_attrs = _merge_node_attributes(source_attrs, target_attrs)

            # Add metadata about the collapsed node
            if "collapsed_from" in merged_attrs:
                # Handle multiple collapses - store as comma-separated string for GraphML compatibility
                existing = merged_attrs["collapsed_from"]
                if isinstance(existing, str):
                    # Convert existing string to list, add new node_id, then back to string
                    node_ids = [*existing.split(","), node_id]
                    merged_attrs["collapsed_from"] = ",".join(node_ids)
                else:
                    # If it's already some other type, convert to string
                    merged_attrs["collapsed_from"] = f"{existing},{node_id}"
            else:
                merged_attrs["collapsed_from"] = node_id

            # Update target node with merged attributes
            self.graph.nodes[to_node_id].update(merged_attrs)

        # Redirect connections if requested
        if inherit_connections:
            # Redirect all incoming edges from source to target
            in_edges = list(self.graph.in_edges(node_id, keys=True, data=True))
            for pred_node, _, key, edge_data in in_edges:
                if pred_node != to_node_id:  # Avoid self-loops unless they existed
                    self.graph.add_edge(pred_node, to_node_id, key=key, **edge_data)

            # Redirect all outgoing edges from source to target
            out_edges = list(self.graph.out_edges(node_id, keys=True, data=True))
            for _, succ_node, key, edge_data in out_edges:
                if succ_node != to_node_id:  # Avoid self-loops unless they existed
                    self.graph.add_edge(to_node_id, succ_node, key=key, **edge_data)

        # Remove the source node (this also removes all its connected edges)
        self.graph.remove_node(node_id)

    def remove_nodes_by_label(self, label: str | list[str], stitch: bool = False) -> int:
        """
        Remove all nodes that have a specific label or labels in their label attribute.

        Parameters
        ----------
        label : str or list[str]
            Single label (str) or list of labels to search for in node attributes
            (case-insensitive substring match). All nodes containing any of these
            labels will be removed.
        stitch : bool, default=False
            If True, nodes with exactly 2 connected edges (incoming + outgoing) will be
            stitched by creating a direct edge between their neighbors before removal.
            Edge type priority for stitching: other > reference > composition.

        Returns
        -------
        int
            The number of nodes removed.

        Examples
        --------
        >>> # Remove all piping nodes (single label)
        >>> count = loader.remove_nodes_by_label("PipingNode")
        >>> print(f"Removed {count} piping nodes")

        >>> # Remove multiple types of nodes at once
        >>> count = loader.remove_nodes_by_label(["PipingNode", "Equipment"])
        >>> print(f"Removed {count} nodes")

        >>> # Remove nodes and stitch their connections
        >>> count = loader.remove_nodes_by_label("PipingNode", stitch=True)
        >>> print(f"Removed and stitched {count} nodes")
        """
        # Normalize label to a list
        labels_list = [label] if isinstance(label, str) else label

        # Collect all nodes to remove
        nodes_to_remove = set()
        for lbl in labels_list:
            matching_nodes = self.get_nodes_by_label(lbl)
            nodes_to_remove.update(matching_nodes)

        # Remove each node
        for node_id in nodes_to_remove:
            if node_id not in self.graph.nodes:
                continue

            # If stitch is enabled, try to stitch nodes with exactly 2 edges
            if stitch:
                in_edges = list(self.graph.in_edges(node_id, keys=True, data=True))
                out_edges = list(self.graph.out_edges(node_id, keys=True, data=True))

                total_edges = len(in_edges) + len(out_edges)

                # Only stitch if node has exactly 2 connected edges
                if total_edges == 2:
                    # Collect all edges with their directions
                    all_edges = []
                    for source, target, key, data in in_edges:
                        all_edges.append(("in", source, target, key, data))
                    for source, target, key, data in out_edges:
                        all_edges.append(("out", source, target, key, data))

                    # Prioritize edges: other > reference > composition
                    def edge_priority(edge):
                        _, _, _, _, data = edge
                        edge_label = data.get("label", "").lower()
                        if edge_label == "composition":
                            return 0
                        elif edge_label == "reference":
                            return 1
                        else:
                            return 2  # other

                    # Sort edges by priority (highest first)
                    sorted_edges = sorted(all_edges, key=edge_priority, reverse=True)

                    # Take the highest priority edge for stitching
                    primary_edge = sorted_edges[0]
                    other_edge = sorted_edges[1]

                    direction1, source1, target1, _key1, data1 = primary_edge
                    direction2, source2, target2, _key2, _data2 = other_edge

                    # Determine the neighbors to stitch
                    if direction1 == "in" and direction2 == "in":
                        # Both incoming: stitch source1 -> source2
                        neighbor1, neighbor2 = source1, source2
                    elif direction1 == "in" and direction2 == "out":
                        # in and out: stitch source1 -> target2
                        neighbor1, neighbor2 = source1, target2
                    elif direction1 == "out" and direction2 == "in":
                        # out and in: stitch source2 -> target1
                        neighbor1, neighbor2 = source2, target1
                    else:  # both outgoing
                        # Both outgoing: stitch target1 -> target2
                        neighbor1, neighbor2 = target2, target1

                    # Create new edge with attributes from the primary edge
                    new_edge_attrs = dict(data1)
                    new_edge_attrs["stitched_from"] = node_id

                    # Add the stitching edge
                    self.graph.add_edge(neighbor1, neighbor2, key=node_id, **new_edge_attrs)

            # Remove the node
            self.graph.remove_node(node_id)

        return len(nodes_to_remove)

    def collapse_node_to_edge_by_label(
        self,
        label: str,
        inherit_attributes: bool = False,
        inherit_connections: bool = False,
    ) -> int:
        """
        Collapse nodes with a specific label to edges.

        This method finds all nodes matching the given label and collapses each one to an edge.
        It handles two cases:
        1. Standard 1-to-1 connection (1 incoming, 1 outgoing edge)
        2. Special case with 0 incoming and 2 outgoing edges, where attr_name determines direction.
           Supports both "sourceItem"/"targetItem" and "source"/"target" attribute name patterns.

        The resulting edges are captioned by
        :func:`~pydexpi.toolkits.display_name.get_relationship_display_name`.

        Parameters
        ----------
        label : str
            The label to search for in node attributes (case-insensitive substring match).
            All nodes containing this label will be collapsed to edges if they meet the criteria.
        inherit_attributes : bool, default=False
            If True, transfer the collapsed node's attributes to the newly created edge.
            The node's ID will be included as an attribute.
        inherit_connections : bool, default=False
            If True, preserve and merge the original edge attributes from both incoming and outgoing edges.
            If False, only create a basic edge without preserving edge attributes.

        Returns
        -------
        int
            The number of nodes successfully collapsed to edges.

        Examples
        --------
        >>> # Collapse all PipingNode nodes to edges (just remove without inheritance)
        >>> count = loader.collapse_node_to_edge_by_label("PipingNode")
        >>> print(f"Collapsed {count} nodes to edges")

        >>> # Collapse with node attributes inherited
        >>> count = loader.collapse_node_to_edge_by_label("PipingNode", inherit_attributes=True)

        >>> # Collapse with both node attributes and edge connections inherited
        >>> count = loader.collapse_node_to_edge_by_label("PipingNode", inherit_attributes=True, inherit_connections=True)
        """
        # Get all nodes with the specified label
        nodes_to_collapse = self.get_nodes_by_label(label)
        collapsed_count = 0

        for node_id in nodes_to_collapse:
            # Skip if node was already removed (e.g., as part of a previous collapse)
            if node_id not in self.graph.nodes:
                continue

            # Get incoming and outgoing edges
            in_edges = list(self.graph.in_edges(node_id, keys=True, data=True))
            out_edges = list(self.graph.out_edges(node_id, keys=True, data=True))

            # Case 1: Standard 1-to-1 connection
            if len(in_edges) == 1 and len(out_edges) == 1:
                self.collapse_node_to_edge(
                    node_id,
                    inherit_attributes=inherit_attributes,
                    inherit_connections=inherit_connections,
                )
                collapsed_count += 1

            # Case 2: Special case - 0 incoming, 2 outgoing edges
            elif len(in_edges) >= 0 and len(out_edges) >= 2:
                # Find sourceItem and targetItem based on attr_name
                source_node = None
                target_node = None
                source_edge_data = None
                target_edge_data = None

                for _, succ_node, _key, edge_data in out_edges:
                    attr_name = edge_data.get("attr_name", "")
                    # Check for both sourceItem/targetItem and source/target patterns
                    if attr_name in ("sourceItem", "source"):
                        source_node = succ_node
                        source_edge_data = edge_data
                    elif attr_name in ("targetItem", "target"):
                        target_node = succ_node
                        target_edge_data = edge_data

                # Only proceed if we found both source and target
                if source_node is not None and target_node is not None:
                    # Prepare edge attributes. When connections are inherited,
                    # source and target edge data are merged in that order, so
                    # the target takes precedence.
                    inherited_edge_data = ()
                    if inherit_connections:
                        inherited_edge_data = [
                            edge_data
                            for edge_data in (source_edge_data, target_edge_data)
                            if edge_data
                        ]

                    new_edge_attrs = self._collapsed_edge_attributes(
                        node_id,
                        inherit_attributes=inherit_attributes,
                        inherited_edge_data=inherited_edge_data,
                    )

                    # Create edge from sourceItem to targetItem
                    self.graph.add_edge(source_node, target_node, key=node_id, **new_edge_attrs)

                    # Remove structural edges left behind, preserving relationships.
                    self._remove_parallel_edges(source_node, target_node, exclude_key=node_id)

                    # Remove the collapsed node
                    self.graph.remove_node(node_id)
                    collapsed_count += 1

            # Case 3: Node with only 1 connected edge - just remove it
            elif len(in_edges) + len(out_edges) == 1:
                # Simply remove the node (impossible to create an edge with only 1 connection)
                self.graph.remove_node(node_id)
                collapsed_count += 1

        return collapsed_count

    def collapse_node_to_node_by_label(
        self,
        label: str,
        target_labels: str | list[str] | None = None,
        inherit_attributes: bool = False,
        inherit_connections: bool = False,
    ) -> int:
        """
        Collapse nodes with a specific label to connected nodes that match target labels.

        This method finds all nodes matching the given label and collapses each one to its
        connected nodes (either successors or predecessors) that match any of the target labels
        and are connected by composition edges. If target_labels is None, all composition-connected
        nodes are considered as targets. The attributes and connections of the collapsed node can
        optionally be inherited by the target nodes.

        The target label matching checks both the 'label' attribute (single value) and 'labels'
        attribute (colon-separated values like "BallValve:OperatedValve:PipingComponent").

        Parameters
        ----------
        label : str
            The label to search for in node attributes (case-insensitive substring match).
            All nodes containing this label will be collapsed.
        target_labels : str, list[str], or None, default=None
            Single label (str) or list of node labels to match for target nodes. Nodes will be
            collapsed to connected nodes (either successors or predecessors) that have labels
            matching the provided label(s). Matching is done against both 'label' and 'labels'
            attributes. If None, collapse to all composition-connected nodes regardless of their labels.
        inherit_attributes : bool, default=False
            If True, transfer the collapsed node's attributes to the target nodes.
            Attributes from the target nodes take precedence in case of conflicts.
        inherit_connections : bool, default=False
            If True, redirect all edges from the collapsed node to the target node.
            If False, edges are simply removed with the collapsed node.

        Returns
        -------
        int
            The number of nodes successfully collapsed.

        Examples
        --------
        >>> # Collapse to a single target label (string)
        >>> count = loader.collapse_node_to_node_by_label("ProcessInstrument", target_labels="Equipment")
        >>> print(f"Collapsed {count} nodes")

        >>> # Collapse all ProcessInstrument nodes to connected Equipment or Actuator nodes
        >>> count = loader.collapse_node_to_node_by_label("ProcessInstrument", target_labels=["Equipment", "Actuator"])
        >>> print(f"Collapsed {count} nodes")

        >>> # Collapse to all composition-connected nodes (no label filtering)
        >>> count = loader.collapse_node_to_node_by_label("ProcessInstrument", target_labels=None)

        >>> # Collapse to specific labels with both attributes and connections inherited
        >>> count = loader.collapse_node_to_node_by_label(
        ...     "ProcessInstrument",
        ...     target_labels=["Equipment"],
        ...     inherit_attributes=True,
        ...     inherit_connections=True
        ... )

        >>> # Collapse without inheriting connections (just remove nodes)
        >>> count = loader.collapse_node_to_node_by_label(
        ...     "ProcessInstrument",
        ...     target_labels="Equipment",
        ...     inherit_connections=False
        ... )
        """
        # Normalize target_labels to a list
        if target_labels is None:
            target_labels_list = None
        elif isinstance(target_labels, str):
            target_labels_list = [target_labels]
        else:
            target_labels_list = target_labels

        # Get all nodes with the specified label
        nodes_to_collapse = self.get_nodes_by_label(label)
        collapsed_count = 0

        for node_id in nodes_to_collapse:
            # Skip if node was already removed (e.g., as part of a previous collapse)
            if node_id not in self.graph.nodes:
                continue

            # Get all composition edges (both incoming and outgoing)
            in_edges = list(self.graph.in_edges(node_id, keys=True, data=True))
            out_edges = list(self.graph.out_edges(node_id, keys=True, data=True))

            # Filter for composition edges
            composition_in_edges = [
                (source, target, key, data) for source, target, key, data in in_edges
            ]
            composition_out_edges = [
                (source, target, key, data) for source, target, key, data in out_edges
            ]

            # Collect potential target nodes from both directions
            target_node_ids = []

            # From predecessors
            for source, _, _, _ in composition_in_edges:
                if source in self.graph.nodes and (
                    target_labels_list is None
                    or self._node_matches_any_label(source, target_labels_list)
                ):
                    target_node_ids.append(source)

            # From successors
            for _, target, _, _ in composition_out_edges:
                if target in self.graph.nodes and (
                    target_labels_list is None
                    or self._node_matches_any_label(target, target_labels_list)
                ):
                    target_node_ids.append(target)

            # Remove duplicates while preserving order
            target_node_ids = list(dict.fromkeys(target_node_ids))

            # Collapse to all matching target nodes (can be one or more)
            if len(target_node_ids) >= 1:
                # First, inherit attributes to ALL target nodes if requested
                if inherit_attributes:
                    source_attrs = dict(self.graph.nodes[node_id])
                    for target_node_id in target_node_ids:
                        if target_node_id == node_id:
                            continue  # Skip if target is the same as source

                        if target_node_id not in self.graph.nodes:
                            continue  # Skip if target node doesn't exist

                        # Get target node attributes
                        target_attrs = dict(self.graph.nodes[target_node_id])

                        # Merge attributes: target attributes take precedence, keeping
                        # value/unit pairs together (see _merge_node_attributes).
                        merged_attrs = _merge_node_attributes(source_attrs, target_attrs)

                        # Add metadata about the collapsed node
                        if "collapsed_from" in merged_attrs:
                            existing = merged_attrs["collapsed_from"]
                            if isinstance(existing, str):
                                node_ids = [*existing.split(","), node_id]
                                merged_attrs["collapsed_from"] = ",".join(node_ids)
                            else:
                                merged_attrs["collapsed_from"] = f"{existing},{node_id}"
                        else:
                            merged_attrs["collapsed_from"] = node_id

                        # Update target node with merged attributes
                        self.graph.nodes[target_node_id].update(merged_attrs)

                # Then, redirect connections to ALL target nodes if requested
                if inherit_connections:
                    in_edges = list(self.graph.in_edges(node_id, keys=True, data=True))
                    out_edges = list(self.graph.out_edges(node_id, keys=True, data=True))

                    for target_node_id in target_node_ids:
                        if target_node_id == node_id:
                            continue  # Skip if target is the same as source

                        if target_node_id not in self.graph.nodes:
                            continue  # Skip if target node doesn't exist

                        # Redirect all incoming edges from source to this target
                        for pred_node, _, key, edge_data in in_edges:
                            if pred_node != target_node_id:  # Avoid self-loops unless they existed
                                self.graph.add_edge(pred_node, target_node_id, key=key, **edge_data)

                        # Redirect all outgoing edges from source to this target
                        for _, succ_node, key, edge_data in out_edges:
                            if succ_node != target_node_id:  # Avoid self-loops unless they existed
                                self.graph.add_edge(target_node_id, succ_node, key=key, **edge_data)

                # Finally, remove the source node
                self.graph.remove_node(node_id)
                collapsed_count += 1

        return collapsed_count

    def _node_matches_any_label(self, node_id: str, target_labels: list[str]) -> bool:
        """
        Check if a node matches any of the target labels.

        This method checks both the 'label' attribute (single value) and 'labels' attribute
        (colon-separated values) to determine if any target label matches.

        Parameters
        ----------
        node_id : str
            The ID of the node to check.
        target_labels : list[str]
            List of labels to match against.

        Returns
        -------
        bool
            True if the node matches any target label, False otherwise.
        """
        if node_id not in self.graph.nodes:
            return False

        node_data = self.graph.nodes[node_id]

        # Check 'label' attribute (single value)
        node_label = node_data.get("label", "")
        if isinstance(node_label, str) and any(
            tl.lower() in node_label.lower() for tl in target_labels
        ):
            return True

        # Check 'labels' attribute (colon-separated values)
        node_labels = node_data.get("labels", "")
        if isinstance(node_labels, str) and node_labels:
            # Split by colon and check each label
            labels_list = node_labels.split(":")
            for label_item in labels_list:
                if any(tl.lower() in label_item.lower() for tl in target_labels):
                    return True

        return False

    def _remove_parallel_edges(self, source_node: str, target_node: str, exclude_key: str) -> None:
        """
        Remove parallel structural edges between two nodes (in both directions).

        Only composition/reference edges are redundant after a collapse. Edges
        representing engineering relationships survive, including reverse edges.
        The specified exclude_key is always preserved, also on self-loops.

        Parameters
        ----------
        source_node : str
            The source node of the main edge.
        target_node : str
            The target node of the main edge.
        exclude_key : str
            The edge key to exclude from removal (typically the newly created edge).
        """
        edges_to_remove = []

        # Remove parallel edges in the same direction (source_node -> target_node)
        if self.graph.has_edge(source_node, target_node):
            # Everything except the edge we want to keep.
            edges_to_remove.extend(
                (source_node, target_node, key)
                for key, data in self.graph[source_node][target_node].items()
                if key != exclude_key and data.get("label") in {"composition", "reference"}
            )

        # Remove parallel edges in the opposite direction (target_node -> source_node)
        if self.graph.has_edge(target_node, source_node):
            edges_to_remove.extend(
                (target_node, source_node, key)
                for key, data in self.graph[target_node][source_node].items()
                if key != exclude_key and data.get("label") in {"composition", "reference"}
            )

        # Remove all identified parallel edges
        for edge in dict.fromkeys(edges_to_remove):
            self.graph.remove_edge(*edge)

    @staticmethod
    def build_complete_graph(graph: MultiDiGraph) -> MultiDiGraph:
        """Builds a complete graph from the plant graph with minimal abstractions.

        This method creates a deep copy of the plant graph and only removes structural
        and metadata nodes (ConceptualModel and MetaData) which are typically not needed
        for analysis. All other nodes and their connections are preserved.

        Parameters
        ----------
        graph : MultiDiGraph
            The input graph to process.

        Returns
        -------
        MultiDiGraph
            The processed complete graph.
        """
        complete_loader = GraphAbstractor(
            graph=deepcopy(graph),
        )

        # Remove structural and metadata nodes
        complete_loader.remove_nodes_by_label(
            ["PlantModel", "ProcessModel", "MetaData"]
        )  # TODO: check if other highlevel classes need to be removed, e.g., Notes

        return complete_loader.graph

    @staticmethod
    def build_plant_process_graph(graph: MultiDiGraph) -> MultiDiGraph:
        """Builds the process graph for the PlantModel from the graph by filtering relevant nodes and edges.

        Parameters
        ----------
        graph : MultiDiGraph
            The input graph to process.

        Returns
        -------
        MultiDiGraph
            The processed process graph.
        """
        process_loader = GraphAbstractor(
            graph=deepcopy(graph),
        )

        # Remove structural and metadata nodes
        process_loader.remove_nodes_by_label(["PlantModel", "MetaData"])

        # Collapse PipingSystem
        process_loader.remove_nodes_by_label("PipingNode")
        process_loader.collapse_node_to_node_by_label(
            label="PipingNetworkSystem",
            target_labels="PipingNetworkSegment",
            inherit_attributes=True,
            inherit_connections=False,
        )
        process_loader.collapse_node_to_node_by_label(
            label="PipingNetworkSegment",
            target_labels=[
                "PipingComponent",
                "PipeOffPageConnector",
                "PropertyBreak",
                "PipingConnection",
            ],
            inherit_attributes=True,
            inherit_connections=False,
        )

        process_loader.collapse_node_to_edge_by_label(
            label="Pipe",
            inherit_attributes=True,
            inherit_connections=False,
        )

        process_loader.collapse_node_to_edge_by_label(
            label="DirectPipingConnection",
            inherit_attributes=True,
            inherit_connections=False,
        )

        # Collapse Equipment
        # No Equipment Collapsing

        # Collapse Instrumentation
        process_loader.collapse_node_to_node_by_label(
            label="ControlledActuator",
            target_labels="ActuatingSystem",
            inherit_attributes=True,
            inherit_connections=False,
        )

        process_loader.collapse_node_to_node_by_label(
            label="ActuatingSystem",
            target_labels="ActuatingFunction",
            inherit_attributes=True,
            inherit_connections=True,
        )

        process_loader.collapse_node_to_node_by_label(
            label="InstrumentationLoopFunction",
            target_labels="ProcessInstrumentationFunction",
            inherit_attributes=True,
            inherit_connections=False,
        )

        process_loader.collapse_node_to_edge_by_label(
            label="MeasuringLineFunction",
            inherit_attributes=True,
            inherit_connections=False,
        )

        process_loader.collapse_node_to_edge_by_label(
            label="OperatedValveReference",
            inherit_attributes=True,
            inherit_connections=False,
        )

        process_loader.collapse_node_to_edge_by_label(
            label="SignalConveyingFunction",
            inherit_attributes=True,
            inherit_connections=False,
        )

        return process_loader.graph

    @staticmethod
    def build_plant_conceptual_graph(graph: MultiDiGraph) -> MultiDiGraph:
        """Builds the conceptual graph of the PlantModel from the graph by filtering relevant nodes and edges.

        Parameters
        ----------
        graph : MultiDiGraph
            The input plant graph to process.

        Returns
        -------
        MultiDiGraph
            The processed conceptual graph.
        """
        conceptual_loader = GraphAbstractor(
            graph=deepcopy(graph),
        )

        # Remove structural and metadata nodes
        conceptual_loader.remove_nodes_by_label(["PlantModel", "MetaData"])

        # Collapse PipingSystem
        conceptual_loader.remove_nodes_by_label("PipingNode")
        conceptual_loader.collapse_node_to_node_by_label(
            label="PipingNetworkSystem",
            target_labels="PipingNetworkSegment",
            inherit_attributes=True,
            inherit_connections=False,
        )
        conceptual_loader.collapse_node_to_node_by_label(
            label="PipingNetworkSegment",
            target_labels=[
                "PipingComponent",
                "PipeOffPageConnector",
                "PropertyBreak",
                "PipingConnection",
            ],
            inherit_attributes=True,
            inherit_connections=False,
        )

        conceptual_loader.collapse_node_to_edge_by_label(
            label="Pipe",
            inherit_attributes=True,
            inherit_connections=False,
        )

        conceptual_loader.collapse_node_to_edge_by_label(
            label="DirectPipingConnection",
            inherit_attributes=True,
            inherit_connections=False,
        )

        # Collapse Equipment
        conceptual_loader.remove_nodes_by_label(
            label=[class_type.__name__ for class_type in et.get_equipment_internal_classes()]
        )
        conceptual_loader.remove_nodes_by_label("Nozzle", stitch=True)

        # Collapse Instrumentation
        conceptual_loader.collapse_node_to_node_by_label(
            label="ControlledActuator",
            target_labels="ActuatingSystem",
            inherit_attributes=True,
            inherit_connections=False,
        )

        conceptual_loader.collapse_node_to_node_by_label(
            label="ActuatingSystem",
            target_labels="ActuatingFunction",
            inherit_attributes=True,
            inherit_connections=True,
        )

        conceptual_loader.collapse_node_to_node_by_label(
            label="InstrumentationLoopFunction",
            target_labels="ProcessInstrumentationFunction",
            inherit_attributes=True,
            inherit_connections=False,
        )

        conceptual_loader.collapse_node_to_edge_by_label(
            label="MeasuringLineFunction",
            inherit_attributes=True,
            inherit_connections=False,
        )

        conceptual_loader.collapse_node_to_edge_by_label(
            label="OperatedValveReference",
            inherit_attributes=True,
            inherit_connections=False,
        )

        conceptual_loader.collapse_node_to_edge_by_label(
            label="SignalConveyingFunction",
            inherit_attributes=True,
            inherit_connections=False,
        )

        return conceptual_loader.graph


# ---------------------------------------------------------------------------
# The process-flow level: the steps and connections of a DEXPI ProcessModel
#
# Built directly from the raw graph's typed nodes and its composition/reference edges, never by
# chaining GraphAbstractor's P&ID collapses: process ports, delegated ports and step hierarchy
# have their own semantics. Parallel connections are keyed by their connection IDs; a port
# delegation and what a measurement measures are edges of kinds of their own, and an
# instrumentation system is a node over the activities it composes.
# ---------------------------------------------------------------------------

#: The graph level :func:`build_process_flow_graph` builds.
PROCESS_FLOW_LEVEL = "process_flow"

#: What a process-flow element stands for. On a node: ``"ProcessStep"``, ``"ProcessStepDetail"``,
#: ``"InstrumentationActivity"``, :data:`INSTRUMENTATION_SYSTEM_KIND`, or ``"Port"`` for a port no
#: object owns that an edge has to end at. On an edge: ``"ProcessConnection"``, ``"hierarchy"``,
#: :data:`DELEGATION_KIND` or :data:`MEASURES_KIND`. On a node and on a connection's edge
#: ``label`` stays the concrete class name, as at every other level.
KIND_ATTRIBUTE = "kind"

#: The ``kind`` of the node that stands for an ``InstrumentationSystemActivity``: a control
#: loop, which composes its ``InstrumentationActivity`` s and owns no port. It carries its own
#: data (``identifier``, ``dexpiLabel``, ``description``), what it composes
#: (``persistentIdentifiers``) and what it references (``performedRoles`` as role names,
#: ``referencedNotes``), and has one hierarchy edge to each activity it composes, keyed
#: ``"instrumentationActivities.<activity id>"``. It is not listed in
#: :data:`PORTLESS_ELEMENTS_ATTRIBUTE`: its class has no ports to be without.
INSTRUMENTATION_SYSTEM_KIND = "InstrumentationSystemActivity"

#: The ``kind`` -- and the ``label``, so the Neo4j relationship type -- of the edge that stands
#: for one port delegation: from the node owning the super port to the node owning the port that
#: delegates it (``Port.superReference``), keyed ``"delegation.<delegate port id>"``. It carries
#: :data:`SUPER_PORT_ATTRIBUTE`, :data:`SUB_PORT_ATTRIBUTE` and :data:`RECIPROCAL_ATTRIBUTE`.
DELEGATION_KIND = "delegation"

#: The ``kind`` and the ``label`` of an edge from a ``MeasuringProcessVariable`` to what it says it
#: measures: the step (``processStepReference``) or the detail (``processStepDetailReference``),
#: keyed ``"measures.<activity id>.<measured id>"``, or each of the two nodes a measured
#: connection (``connectionReference``) runs between, keyed ``"measures.<activity
#: id>.<connection id>.<end>"`` with the end ``source`` or ``target``. ``attr_name`` names the
#: reference the edge is drawn from.
MEASURES_KIND = "measures"

#: On a :data:`DELEGATION_KIND` edge: the id of the delegated port, a port of the edge's source.
SUPER_PORT_ATTRIBUTE = "superPort"

#: On a :data:`DELEGATION_KIND` edge: the id of the port that delegates it, a port of the edge's
#: target. It is the port whose ``superReference`` the edge is drawn from.
SUB_PORT_ATTRIBUTE = "subPort"

#: On a :data:`DELEGATION_KIND` edge: whether the super port lists the delegate back in its
#: ``subReference``. The edge is drawn from ``superReference`` alone, so it is there either way;
#: 2 of the CO2 terminal export's delegates are not listed back.
RECIPROCAL_ATTRIBUTE = "reciprocal"

#: On a :data:`MEASURES_KIND` edge drawn from ``connectionReference``: the id of the measured
#: connection, which is the key of its own edge. An edge cannot end at an edge, so the
#: measurement has one edge to each of the two nodes the connection runs between.
MEASURED_CONNECTION_ATTRIBUTE = "measuredConnection"

#: On a :data:`MEASURES_KIND` edge drawn from ``connectionReference``: which end of the measured
#: connection the edge's target is, ``"source"`` or ``"target"``.
CONNECTION_END_ATTRIBUTE = "connectionEnd"

#: On a :data:`MEASURES_KIND` edge: the property of the measured element that holds the value the
#: activity names in ``measuredVariableReference`` -- ``"pressure"``, ``"level"`` -- and so the
#: name its value has on that element in the graph (the edge's target, or the measured
#: connection's edge; ``<name>_items`` where the property holds several values). Left out where
#: the measured element does not compose that value, or composes it under an id several objects
#: share (:data:`SHARED_IDS_ATTRIBUTE`).
MEASURED_PROPERTY_ATTRIBUTE = "measuredProperty"

#: Node attribute naming the process step that owns the node: a sub-step's step, or a
#: ``ProcessStepDetail``'s. Absent on a top-level step. Every ``parent`` has a hierarchy edge.
PARENT_ATTRIBUTE = "parent"

#: Node attribute naming the ``InstrumentationSystemActivity`` that owns an
#: ``InstrumentationActivity`` node. No step owns an activity, so it has no ``parent``. The system
#: is a node of kind :data:`INSTRUMENTATION_SYSTEM_KIND`, and every
#: ``instrumentationSystemActivity`` has a hierarchy edge from it; the attribute is the form the
#: edge was added beside, and stays.
INSTRUMENTATION_SYSTEM_ATTRIBUTE = "instrumentationSystemActivity"

#: Edge attribute holding the id of the ``ProcessConnection`` an edge stands for, which is also
#: the edge's key.
CONNECTION_ID_ATTRIBUTE = "connectionId"

#: Graph attribute listing, as a JSON array, the connections that could not become an edge
#: because they name no ``source`` or no ``target`` port. Omitted when there are none.
UNPLACED_CONNECTIONS_ATTRIBUTE = "unplacedConnections"

#: Graph attribute listing, as a JSON array, the ids that several composed objects share. The raw
#: graph keys its nodes by DEXPI id, so such objects are one node there, holding the data of
#: whichever was written last; the raw Tennessee Eastman export shares 4 ids among 35
#: ``QualifiedValue`` s. Their data is flattened onto no owner, since it would put one object's
#: value on another's owner. Omitted when there are none.
SHARED_IDS_ATTRIBUTE = "sharedIds"

#: Graph attribute listing, as a JSON array in model order, the ``ProcessStepDetail`` s and
#: ``InstrumentationActivity`` s that own no port. No connection can end at one, so they
#: used to be no nodes and this list was their only trace; they are nodes now, like every other
#: detail and activity, and the list still names the same ids -- the CO2 terminal export's four
#: measurements own no port and name the step or connection they measure. An
#: ``InstrumentationSystemActivity`` is not listed: no system can own a port, so the list would
#: say nothing of one. Omitted when there are none.
PORTLESS_ELEMENTS_ATTRIBUTE = "portlessElements"

#: Node attribute listing, as a JSON array of ``{"port": id, "superPort": id, "superPortOwner":
#: id}`` in port order, the ports the node owns that delegate a port of an enclosing step
#: (``Port.superReference``). ``superPortOwner`` is the node owning the super port, left out
#: where no node does. Each delegate is also a :data:`DELEGATION_KIND` edge to this node,
#: from that owner; the list is the attribute form the edge was added beside, and stays.
DELEGATED_PORTS_ATTRIBUTE = "delegatedPorts"

#: Node attribute listing, as a JSON array in port order, the ports the node owns that are the
#: end of no edge: no placed connection names them as its ``source`` or ``target``. A port is
#: otherwise on the graph only folded into the edge it ends, so without this list such a port
#: would leave no trace at all -- 34 of the corrected CO2 terminal export's 283 ports, with their
#: ``nominalDirection``. Each entry is ``{"port": id, ...}`` with what the port says, under the
#: port's own attribute names: its data, the data of what it composes, the ids it references and
#: ``roles`` (role names). Omitted where every port of the node ends an edge.
UNCONNECTED_PORTS_ATTRIBUTE = "unconnectedPorts"

#: Suffix of the attribute that carries a property holding several composed objects -- typically
#: several ``QualifiedValue`` s, one per case or scope -- as a JSON array, in model order.
ITEMS_SUFFIX = "_items"

#: Composition attributes that hold an element's ports. A port becomes the end of an edge.
_PORT_ATTRIBUTES = ("ports", "informationPorts")

#: Composition attributes that place a node under a process step, as a hierarchy edge.
_HIERARCHY_ATTRIBUTES = ("subProcessSteps", "processStepDetails")

#: The composition attribute that places an activity under the instrumentation system that owns
#: it, as a hierarchy edge.
_SYSTEM_ACTIVITIES_ATTRIBUTE = "instrumentationActivities"

#: Compositions that are the graph's structure rather than an element's own data.
_STRUCTURAL_COMPOSITIONS = frozenset(
    (*_PORT_ATTRIBUTES, *_HIERARCHY_ATTRIBUTES, _SYSTEM_ACTIVITIES_ATTRIBUTE)
)

#: The kinds of node :data:`PORTLESS_ELEMENTS_ATTRIBUTE` lists when one owns no port: the two
#: whose class can own ports and need not. Every step is a node either way, and a system has
#: none to own.
_LISTED_WHEN_PORTLESS = frozenset({"ProcessStepDetail", "InstrumentationActivity"})

#: A connection's two ends, in edge direction.
_CONNECTION_ENDS = ("source", "target")

#: The reference attribute naming the ``Role`` s an object performs, written as role names.
_ROLES_ATTRIBUTE = "performedRoles"

#: A port's reference to the port it delegates, of an enclosing step.
_SUPER_PORT_ATTRIBUTE = "superReference"

#: A port's list of the ports delegating it.
_SUB_PORTS_ATTRIBUTE = "subReference"

#: The references through which a ``MeasuringProcessVariable`` names a node it measures. No
#: other reference of the generated classes joins two process-flow elements.
_MEASURED_NODE_REFERENCES = ("processStepReference", "processStepDetailReference")

#: The reference through which a ``MeasuringProcessVariable`` names a connection it measures.
_MEASURED_CONNECTION_REFERENCE = "connectionReference"

#: The reference through which it names the value it measures, a ``QualifiedValue``.
_MEASURED_VARIABLE_REFERENCE = "measuredVariableReference"

#: What an edge does not repeat of the port it collapses: the connection the port names is the
#: edge itself (and where it is not, the validation rules say so), and its roles are written as
#: names under ``<end>PortRoles``.
_PORT_REFERENCES_NOT_FOLDED = ("connectorReference", _ROLES_ATTRIBUTE)

#: What a raw node says about itself as a graph element rather than as DEXPI data. These are
#: not copied from a composed object onto the element that owns it.
_ELEMENT_KEYS = frozenset({"label", "labels", "displayName", "label_description"})


def _dexpi_class(attributes: dict) -> type[PyDexpiBaseModel] | None:
    """The DEXPI class a raw node stands for, from its ``label``; ``None`` for a bare node."""
    name = attributes.get("label")
    cls = getattr(dexpi_classes, name, None) if isinstance(name, str) else None
    return cls if isinstance(cls, type) and issubclass(cls, PyDexpiBaseModel) else None


def _related(raw: MultiDiGraph, node: str, edge_label: str) -> dict[str, list[str]]:
    """The objects *node* composes (``"composition"``) or references, by attribute, in order."""
    related: dict[str, list[str]] = {}
    for _, other, data in raw.out_edges(node, data=True):
        if data.get("label") == edge_label:
            related.setdefault(data.get("attr_name", ""), []).append(other)
    return related


def _is_list_field(cls: type[PyDexpiBaseModel] | None, name: str) -> bool | None:
    """Whether *cls* declares *name* a list; ``None`` when that cannot be told."""
    field = cls.model_fields.get(name) if cls is not None else None
    return None if field is None else field.default_factory is list


def _child_attribute_name(composition: str, attribute: str) -> str:
    """The name a composed object's data attribute takes on the element that owns it.

    A ``QualifiedValue`` in ``massFlow`` gives ``massFlow`` (its value) and ``massFlow_unit``,
    exactly as a quantity attribute splits at every other level, and its qualifiers come along
    as ``massFlow_scope``, ``massFlow_provenance`` and so on. A vector gives
    ``massFlow_values`` / ``massFlow_values_unit`` (:func:`vector_attribute_name`). Any other
    attribute ``a`` of any other composed object becomes ``<composition>_a``.
    """
    vector = vector_attribute_name("value")
    renamed = {
        "value": composition,
        f"value{UNIT_ATTRIBUTE_SUFFIX}": f"{composition}{UNIT_ATTRIBUTE_SUFFIX}",
        vector: vector_attribute_name(composition),
        f"{vector}{UNIT_ATTRIBUTE_SUFFIX}": f"{vector_attribute_name(composition)}"
        f"{UNIT_ATTRIBUTE_SUFFIX}",
        DEXPI_LABEL_ATTRIBUTE: f"{composition}_label",
    }
    return renamed.get(attribute, f"{composition}_{attribute}")


def _object_data(raw: MultiDiGraph, node: str) -> dict:
    """A raw node's DEXPI data, without what it says about itself as a graph element."""
    return {key: value for key, value in raw.nodes[node].items() if key not in _ELEMENT_KEYS}


def _shared_ids(raw: MultiDiGraph) -> set[str]:
    """The raw nodes composed more than once: in a model, every object has one owner."""
    return {
        node
        for node in raw.nodes
        if sum(
            1 for *_, data in raw.in_edges(node, data=True) if data.get("label") == "composition"
        )
        > 1
    }


def _flattened_compositions(raw: MultiDiGraph, node: str, shared: set[str]) -> dict:
    """The data of what *node* composes, as attributes of *node* (one level deep).

    A property holding one object -- the usual case: every ``QualifiedValue`` list on a step or
    a connection in the corpus holds one -- is flattened by :func:`_child_attribute_name`, so
    its value is a number a range query can use. A property holding several is written as one
    JSON array under ``<property>_items`` instead of picking one, and has no plain
    ``<property>`` attribute: a scalar standing for one of them would silently hide the others.
    Structural compositions (ports, sub-steps, details, a system's activities) are the graph's
    nodes and edges instead.
    A child whose id several objects share (*shared*, :data:`SHARED_IDS_ATTRIBUTE`) is left out:
    its raw node holds another object's data.
    """
    attributes: dict = {}
    for composition, composed in _related(raw, node, "composition").items():
        if composition in _STRUCTURAL_COMPOSITIONS:
            continue
        children = [child for child in composed if child not in shared]
        if not children:
            continue
        if len(children) == 1:
            for name, value in _object_data(raw, children[0]).items():
                attributes[_child_attribute_name(composition, name)] = value
        else:
            items = coerce_for_graph([_object_data(raw, child) for child in children])
            if items is not None:
                attributes[f"{composition}{ITEMS_SUFFIX}"] = items
    return attributes


def _role_names(raw: MultiDiGraph, roles: list[str]) -> list[str]:
    """The names of *roles*; a ``Role`` is identified by its name, not by its arbitrary id."""
    return [str(raw.nodes[role].get("name", role)) for role in roles]


def _flattened_references(
    raw: MultiDiGraph,
    node: str,
    cls: type[PyDexpiBaseModel] | None,
    skip: tuple[str, ...] = (),
) -> dict:
    """What *node* references, as attributes of *node*: the referenced ids, by attribute.

    A list-valued reference is a JSON array even when it holds one id, so one attribute has one
    type on every element. ``performedRoles`` carries role names rather than ids.
    """
    attributes: dict = {}
    for reference, targets in _related(raw, node, "reference").items():
        if reference in skip:
            continue
        values = _role_names(raw, targets) if reference == _ROLES_ATTRIBUTE else targets
        is_list = _is_list_field(cls, reference)
        if is_list is False or (is_list is None and len(values) == 1):
            attributes[reference] = values[0]
        else:
            coerced = coerce_for_graph(values)
            if coerced is not None:
                attributes[reference] = coerced
    return attributes


def _port_attribute_name(end: str, attribute: str) -> str:
    """The name a port's attribute takes on the edge that collapses the port.

    ``<end>Port`` and the attribute with its first letter raised: ``identifier`` at the source
    is ``sourcePortIdentifier``, ``nominalDirection`` at the target
    ``targetPortNominalDirection``.
    """
    return f"{end}Port{attribute[:1].upper()}{attribute[1:]}"


def _port_attributes(
    raw: MultiDiGraph,
    end: str,
    port: str,
    cls: type[PyDexpiBaseModel] | None,
    shared: set[str],
) -> dict:
    """What an edge keeps of the port it collapses: everything the port says.

    The port's id is ``<end>Port``. Its data attributes (``identifier``, ``nominalDirection``,
    ...), the data of what it composes (``persistentIdentifiers``) and the ids it references
    (``materialTemplateReference``, and for delegation ``superReference`` and the JSON array
    ``subReference``) follow under :func:`_port_attribute_name`, flattened exactly as a node's
    own are. The roles it performs are the JSON array of names ``<end>PortRoles``. Its
    ``connectorReference`` is not repeated: it is the edge.
    """
    attributes: dict = {f"{end}Port": port}
    folded = {
        **_object_data(raw, port),
        **_flattened_compositions(raw, port, shared),
        **_flattened_references(raw, port, cls, skip=_PORT_REFERENCES_NOT_FOLDED),
    }
    for name, value in folded.items():
        attributes[_port_attribute_name(end, name)] = value
    roles = _role_names(raw, _related(raw, port, "reference").get(_ROLES_ATTRIBUTE, []))
    if roles:
        attributes[f"{end}PortRoles"] = coerce_for_graph(roles)
    return attributes


def _delegated_ports(
    raw: MultiDiGraph, ports: list[str], port_owner: dict[str, str]
) -> list[dict[str, str]]:
    """Which of *ports* delegate a port of an enclosing step, each with that super port and the
    node owning it (*port_owner*; left out for a super port no node owns)."""
    delegated = []
    for port in ports:
        supers = _related(raw, port, "reference").get(_SUPER_PORT_ATTRIBUTE, [])
        if supers:
            entry = {"port": port, "superPort": supers[0]}
            if supers[0] in port_owner:
                entry["superPortOwner"] = port_owner[supers[0]]
            delegated.append(entry)
    return delegated


def _unconnected_port(
    raw: MultiDiGraph, port: str, cls: type[PyDexpiBaseModel] | None, shared: set[str]
) -> dict:
    """What a node keeps of a port that ends no edge: the entry of
    :data:`UNCONNECTED_PORTS_ATTRIBUTE`.

    The same things an edge keeps of a port it collapses (:func:`_port_attributes`), under the
    port's own attribute names since there is no end to prefix them with, and with referenced
    ids as plain values of the entry rather than JSON inside JSON. ``connectorReference`` is
    kept here: no edge stands for it.
    """
    entry: dict = {
        "port": port,
        **_object_data(raw, port),
        **_flattened_compositions(raw, port, shared),
    }
    for reference, targets in _related(raw, port, "reference").items():
        if reference == _ROLES_ATTRIBUTE:
            entry["roles"] = _role_names(raw, targets)
        elif _is_list_field(cls, reference) is False or (
            _is_list_field(cls, reference) is None and len(targets) == 1
        ):
            entry[reference] = targets[0]
        else:
            entry[reference] = list(targets)
    return entry


def _unowned_port_attributes(raw: MultiDiGraph, port: str) -> dict:
    """A node for a port no step, detail or activity owns, which an edge has to end at.

    In the CO2 terminal export, for example, three ``TransportingFluidsInPiping`` steps name a
    class DEXPI does not define and are not loaded, while the streams still reference their
    ports. The raw graph then holds those ports as bare nodes, with no attributes at all.
    """
    attributes = dict(raw.nodes[port])
    attributes.setdefault("label", "Port")
    attributes.setdefault("labels", attributes["label"])
    attributes.setdefault("displayName", f"Port ({port})")
    attributes[KIND_ATTRIBUTE] = "Port"
    return attributes


def _port_node(graph: MultiDiGraph, raw: MultiDiGraph, port: str) -> str:
    """The node that stands for *port* where no node owns it: the port itself, added once."""
    if port not in graph:
        graph.add_node(port, **_unowned_port_attributes(raw, port))
    return port


def _add_new_edge(graph: MultiDiGraph, source: str, target: str, key: str, **attributes) -> None:
    """Add an edge, refusing to overwrite one: ``add_edge`` on a taken key updates it silently."""
    if graph.has_edge(source, target, key):
        raise ValueError(
            f"Two process-flow edges from {source!r} to {target!r} would share the key {key!r}. "
            f"A connection's edge is keyed by the connection's id, a hierarchy edge by "
            f"'<attribute>.<child id>', a delegation edge by '{DELEGATION_KIND}.<port id>' and a "
            f"measures edge by '{MEASURES_KIND}.<activity id>.<measured id>'; rename the object "
            f"whose id collides."
        )
    graph.add_edge(source, target, key=key, **attributes)


def _add_delegation_edges(
    graph: MultiDiGraph,
    raw: MultiDiGraph,
    ports_of: dict[str, list[str]],
    port_owner: dict[str, str],
) -> None:
    """Add one :data:`DELEGATION_KIND` edge per port that names a ``superReference``.

    From the node owning the super port to the node owning the delegate: the way the port is
    handed down, and the way the hierarchy edge between the two steps runs. It is not the
    direction of flow, which an outlet's delegation runs against, and it carries no
    ``attr_name``: the reference it is drawn from points the other way. The edge is drawn from
    ``superReference`` alone: it is single-valued, so a delegate has exactly one edge and
    ``"delegation.<delegate port id>"`` is taken once. Whether the super port lists the delegate
    back in ``subReference`` is :data:`RECIPROCAL_ATTRIBUTE`; a ``subReference`` entry whose port
    names no ``superReference`` back draws no edge, and stays on the port that lists it. A super
    port no node owns becomes a node of kind ``"Port"``, as a connection's unowned end does.
    """
    for node, ports in ports_of.items():
        owned = [port for port in ports if port_owner[port] == node]
        for entry in _delegated_ports(raw, owned, port_owner):
            port, super_port = entry["port"], entry["superPort"]
            owner = entry.get("superPortOwner") or _port_node(graph, raw, super_port)
            listed = _related(raw, super_port, "reference").get(_SUB_PORTS_ATTRIBUTE, ())
            _add_new_edge(
                graph,
                owner,
                node,
                f"{DELEGATION_KIND}.{port}",
                label=DELEGATION_KIND,
                **{
                    KIND_ATTRIBUTE: DELEGATION_KIND,
                    SUPER_PORT_ATTRIBUTE: super_port,
                    SUB_PORT_ATTRIBUTE: port,
                    RECIPROCAL_ATTRIBUTE: port in listed,
                },
            )


def _measured_property(
    compositions: dict[str, dict[str, list[str]]],
    measured: str,
    variable: str | None,
    shared: set[str],
) -> dict[str, str]:
    """:data:`MEASURED_PROPERTY_ATTRIBUTE` for an edge to *measured*: the property under which
    it composes *variable*, the value the activity names. Nothing where it composes no such
    value, or one whose id several objects share (that value is flattened onto no owner)."""
    if variable is None or variable in shared:
        return {}
    for name, composed in compositions.get(measured, {}).items():
        if variable in composed:
            return {MEASURED_PROPERTY_ATTRIBUTE: name}
    return {}


def _add_measures_edges(
    graph: MultiDiGraph,
    raw: MultiDiGraph,
    kinds: dict[str, str],
    compositions: dict[str, dict[str, list[str]]],
    placed: dict[str, tuple[str, str]],
    shared: set[str],
) -> None:
    """Add the :data:`MEASURES_KIND` edges: from an activity to what it says it measures.

    ``processStepReference`` and ``processStepDetailReference`` name a node, so each is one
    edge to it. ``connectionReference`` names a connection, which is an edge, and an edge cannot
    end at an edge: the activity gets one edge to each of the two nodes the connection runs
    between (*placed*), naming the connection in :data:`MEASURED_CONNECTION_ATTRIBUTE` and the
    end in :data:`CONNECTION_END_ATTRIBUTE`. A reference to something that is no part of the
    graph -- a step that was not loaded, a connection that could not be placed -- draws no edge;
    the node keeps the reference as an attribute either way.
    """
    for node, kind in kinds.items():
        if kind != "InstrumentationActivity":
            continue
        references = _related(raw, node, "reference")
        variable = next(iter(references.get(_MEASURED_VARIABLE_REFERENCE, ())), None)
        for reference in _MEASURED_NODE_REFERENCES:
            for measured in references.get(reference, ()):
                if measured not in kinds:
                    continue
                _add_new_edge(
                    graph,
                    node,
                    measured,
                    f"{MEASURES_KIND}.{node}.{measured}",
                    label=MEASURES_KIND,
                    attr_name=reference,
                    **{KIND_ATTRIBUTE: MEASURES_KIND},
                    **_measured_property(compositions, measured, variable, shared),
                )
        for connection in references.get(_MEASURED_CONNECTION_REFERENCE, ()):
            if connection not in placed:
                continue
            for end, owner in zip(_CONNECTION_ENDS, placed[connection], strict=True):
                _add_new_edge(
                    graph,
                    node,
                    owner,
                    f"{MEASURES_KIND}.{node}.{connection}.{end}",
                    label=MEASURES_KIND,
                    attr_name=_MEASURED_CONNECTION_REFERENCE,
                    **{
                        KIND_ATTRIBUTE: MEASURES_KIND,
                        MEASURED_CONNECTION_ATTRIBUTE: connection,
                        CONNECTION_END_ATTRIBUTE: end,
                    },
                    **_measured_property(compositions, connection, variable, shared),
                )


def build_process_flow_graph(raw: MultiDiGraph) -> MultiDiGraph:
    """Build the process-flow graph of a DEXPI ``ProcessModel`` from the raw graph.

    **Nodes.** One per ``ProcessStep``, at every depth of ``subProcessSteps``, and one per
    ``ProcessStepDetail`` and ``InstrumentationActivity``, whether or not it owns ports. One
    that owns none can be the end of no connection, and is also listed in
    :data:`PORTLESS_ELEMENTS_ATTRIBUTE`; that list used to be all the graph had of it. And
    one per ``InstrumentationSystemActivity`` (:data:`INSTRUMENTATION_SYSTEM_KIND`), the
    control loop that composes activities: before it was a node, its id, in the attribute of
    each of its activities, was all the graph had of it, and its identifier and label were in no
    export.
    Each keeps every attribute the raw graph gives the object
    (its data attributes, ``label`` = class name, ``labels``, ``displayName``, and ``x``/``y``
    when shape usage was embedded) and gains :data:`KIND_ATTRIBUTE`, :data:`PARENT_ATTRIBUTE`
    (or :data:`INSTRUMENTATION_SYSTEM_ATTRIBUTE`), the data of the objects it composes
    (:func:`_flattened_compositions`: its ``QualifiedValue`` properties, split into value and
    unit) and the ids it references (role names for ``performedRoles``).

    **Edges.** One per ``ProcessConnection``, from the owner of its ``source`` port to the owner
    of its ``target`` port, **keyed by the connection's id** and carrying it again as
    :data:`CONNECTION_ID_ATTRIBUTE`: two streams between one pair of steps, a stream beside an
    energy or information flow, and a recycle back are distinct edges, and a connection between
    two ports of one step is a self-loop. ``label`` is the connection's class, so it is the
    Neo4j relationship type. The ports collapse into the edge (:func:`_port_attributes`):
    ``sourcePort`` / ``targetPort`` are their ids, and everything else each port says follows
    under ``sourcePort...`` / ``targetPort...`` -- ``...PortIdentifier``,
    ``...PortNominalDirection``, ``...PortRoles`` (role names),
    ``...PortMaterialTemplateReference``, ``...PortPersistentIdentifiers``. The connection's own
    quantities split as on a node (``massFlow`` / ``massFlow_unit``, ``duty`` / ``duty_unit``).
    The ends are the connection's own ``source`` and ``target``; ``Port.connectorReference`` is
    not consulted, and where the two disagree the validation rules report it.

    **A delegation is an edge of its own** (:data:`DELEGATION_KIND`). A delegated port
    (one with a ``superReference``) stands in for its super port inside a sub-step, and each is
    one edge from the node owning the super port to the node owning the delegate, keyed
    ``"delegation.<delegate port id>"`` and naming the two ports (:func:`_add_delegation_edges`).
    So a flow that ends at a step's port is followed into the sub-step in one hop, whether or
    not a connection ends at the delegate: none does in the corrected CO2 terminal export, whose
    11 delegates (8 in the export as delivered) only take part in their super ports'
    connections, and one always does in the bpmn2dexpi one, whose 18 delegates each end a
    connection *inside* the step, beside the one their super port ends outside it. The link is
    also still written where the ports are, as it was before the edge: the node owning a
    delegate lists it in :data:`DELEGATED_PORTS_ATTRIBUTE`, with its super port and the node
    owning that one, and a connection's edge carries ``...PortSuperReference`` (the port its
    end delegates) and ``...PortSubReference`` (a JSON array of that port's delegates)
    wherever the connection ends at such a port.

    **A measurement is joined to what it measures** (:data:`MEASURES_KIND`). A
    ``MeasuringProcessVariable`` names a step, a detail or a connection, and is the only class
    whose references join two elements of this graph. Each is an edge from the activity
    (:func:`_add_measures_edges`): one to the step or the detail, and for a connection, which is
    an edge and can end no edge, one to each of the two nodes it runs between.

    **A port that ends no connection is listed on its owner.** A port is on the graph in three
    ways only: folded into the edge of the connection it ends, named by a delegation edge and in
    :data:`DELEGATED_PORTS_ATTRIBUTE` (ids only), and, where it ends no connection, as an entry
    of the node attribute :data:`UNCONNECTED_PORTS_ATTRIBUTE` carrying what it says. It is never
    a node, unless no node owns it (below). The corrected CO2 terminal export has 48 such ports
    among its 283: its 11 delegates and 37 others.

    A **hierarchy edge** runs from a step to each sub-step and detail, and from an
    instrumentation system to each activity it composes, labelled ``composition`` with
    the ``attr_name`` of the raw graph (``subProcessSteps``, ``processStepDetails``,
    ``instrumentationActivities``), keyed ``"<attr_name>.<child id>"`` so that it cannot replace
    a connection edge between the same two nodes. The activities of one loop are thereby the
    out-neighbours of one node; a system that composes none is an isolated node.

    A port no node owns, where a connection ends at it or a delegate names it, becomes a node of
    kind ``"Port"`` (see :func:`_unowned_port_attributes`); a connection with no source or no
    target port at all cannot be drawn, and is listed in :data:`UNPLACED_CONNECTIONS_ATTRIBUTE`
    instead of being dropped silently. An id several composed objects share is listed in
    :data:`SHARED_IDS_ATTRIBUTE`, and those objects' data is flattened onto no owner.

    A ``PlantModel`` has no process steps, so its process-flow graph is empty apart from the
    provenance in ``graph.graph``.

    Parameters
    ----------
    raw : MultiDiGraph
        The unabstracted graph from :class:`GraphLoader`. Not modified.

    Returns
    -------
    MultiDiGraph
        The process-flow graph, a new graph sharing no attribute dict with *raw*.

    Raises
    ------
    ValueError
        If two edges between the same two nodes would share a key: a connection whose id is
        what a hierarchy, delegation or measures edge between them is keyed by.
    """
    graph: MultiDiGraph = MultiDiGraph()
    graph.graph.update(raw.graph)

    classes = {node: _dexpi_class(attributes) for node, attributes in raw.nodes(data=True)}
    compositions = {node: _related(raw, node, "composition") for node in raw.nodes}
    shared = _shared_ids(raw)

    kinds: dict[str, str] = {}
    connections: list[str] = []
    port_owner: dict[str, str] = {}
    ports_of: dict[str, list[str]] = {}
    portless: list[str] = []
    for node, cls in classes.items():
        if cls is None:
            continue
        if issubclass(cls, ProcessConnection):
            connections.append(node)
            continue
        if issubclass(cls, ProcessStep):
            kind = "ProcessStep"
        elif issubclass(cls, ProcessStepDetail):
            kind = "ProcessStepDetail"
        elif issubclass(cls, InstrumentationActivity):
            kind = "InstrumentationActivity"
        elif issubclass(cls, InstrumentationSystemActivity):
            kind = INSTRUMENTATION_SYSTEM_KIND
        else:
            continue
        ports = [p for attr in _PORT_ATTRIBUTES for p in compositions[node].get(attr, ())]
        kinds[node] = kind
        ports_of[node] = ports
        for port in ports:
            port_owner.setdefault(port, node)
        if not ports and kind in _LISTED_WHEN_PORTLESS:
            portless.append(node)

    parents: dict[str, tuple[str, str]] = {}
    systems: dict[str, str] = {}
    for node, cls in classes.items():
        if cls is not None and issubclass(cls, ProcessStep):
            for attr in _HIERARCHY_ATTRIBUTES:
                for child in compositions[node].get(attr, ()):
                    if child in kinds:
                        parents.setdefault(child, (node, attr))
        elif cls is not None and issubclass(cls, InstrumentationSystemActivity):
            for child in compositions[node].get(_SYSTEM_ACTIVITIES_ATTRIBUTE, ()):
                if child in kinds:
                    systems.setdefault(child, node)

    for node, kind in kinds.items():
        attributes = {
            **raw.nodes[node],
            **_flattened_compositions(raw, node, shared),
            **_flattened_references(raw, node, classes[node]),
            KIND_ATTRIBUTE: kind,
        }
        if node in parents:
            attributes[PARENT_ATTRIBUTE] = parents[node][0]
        if node in systems:
            attributes[INSTRUMENTATION_SYSTEM_ATTRIBUTE] = systems[node]
        delegated = _delegated_ports(raw, ports_of[node], port_owner)
        if delegated:
            attributes[DELEGATED_PORTS_ATTRIBUTE] = coerce_for_graph(delegated)
        graph.add_node(node, **attributes)

    # One hierarchy edge per owned node: an object has one owner in a model, and where the raw
    # graph merges two of one id the first owner stands, as it does in the attribute. So
    # "<attribute>.<child id>" is taken once in the whole graph.
    owned = [(parent, child, attr) for child, (parent, attr) in parents.items()]
    owned += [(system, child, _SYSTEM_ACTIVITIES_ATTRIBUTE) for child, system in systems.items()]
    for owner, child, attr in owned:
        _add_new_edge(
            graph,
            owner,
            child,
            f"{attr}.{child}",
            label="composition",
            attr_name=attr,
            **{KIND_ATTRIBUTE: "hierarchy"},
        )

    unplaced: list[str] = []
    placed: dict[str, tuple[str, str]] = {}
    ended: set[str] = set()
    for connection in connections:
        references = _related(raw, connection, "reference")
        end_ports = {end: references[end][0] for end in _CONNECTION_ENDS if references.get(end)}
        if len(end_ports) < len(_CONNECTION_ENDS):
            unplaced.append(connection)
            continue
        source, target = (
            port_owner.get(end_ports[end]) or _port_node(graph, raw, end_ports[end])
            for end in _CONNECTION_ENDS
        )
        attributes = {
            **raw.nodes[connection],
            **_flattened_compositions(raw, connection, shared),
            **_flattened_references(raw, connection, classes[connection], skip=_CONNECTION_ENDS),
            KIND_ATTRIBUTE: "ProcessConnection",
            CONNECTION_ID_ATTRIBUTE: connection,
        }
        for end in _CONNECTION_ENDS:
            port = end_ports[end]
            attributes.update(_port_attributes(raw, end, port, classes.get(port), shared))
        _add_new_edge(graph, source, target, connection, **attributes)
        placed[connection] = (source, target)
        ended.update(end_ports.values())

    _add_delegation_edges(graph, raw, ports_of, port_owner)
    _add_measures_edges(graph, raw, kinds, compositions, placed, shared)

    for node, ports in ports_of.items():
        unconnected = [
            _unconnected_port(raw, port, classes.get(port), shared)
            for port in ports
            if port not in ended and port_owner[port] == node
        ]
        if unconnected:
            graph.nodes[node][UNCONNECTED_PORTS_ATTRIBUTE] = coerce_for_graph(unconnected)

    if unplaced:
        graph.graph[UNPLACED_CONNECTIONS_ATTRIBUTE] = coerce_for_graph(unplaced)
    if portless:
        graph.graph[PORTLESS_ELEMENTS_ATTRIBUTE] = coerce_for_graph(portless)
    if shared:
        graph.graph[SHARED_IDS_ATTRIBUTE] = coerce_for_graph(sorted(shared))
    return graph


# ---------------------------------------------------------------------------
# Abstraction-level registry
#
# The single mapping from a level name to its builder.  GraphLoaderPipeline and
# pydexpi.loaders.public.get_graph/get_graphs all route through build_level, so
# the level cannot be recorded differently on the two paths.  Defined here, at
# the bottom of the module, because it references GraphAbstractor above.
# ---------------------------------------------------------------------------

#: Node, edge and graph attribute recording the abstraction level of a graph.
GRAPH_LEVEL_ATTRIBUTE = "graph_level"

#: ``complete``, ``process`` and ``conceptual`` abstract a P&ID (a ``PlantModel``) by collapsing
#: the raw graph; ``process_flow`` builds the step-and-connection graph of a ``ProcessModel``
#: directly (:func:`build_process_flow_graph`). ``process`` is the *P&ID* process level.
GRAPH_LEVELS: dict[str, Callable[[MultiDiGraph], MultiDiGraph]] = {
    "complete": GraphAbstractor.build_complete_graph,
    "process": GraphAbstractor.build_plant_process_graph,
    "conceptual": GraphAbstractor.build_plant_conceptual_graph,
    PROCESS_FLOW_LEVEL: build_process_flow_graph,
}


def resolve_abstraction(graph_level: str) -> Callable[[MultiDiGraph], MultiDiGraph]:
    """Return the abstraction builder for *graph_level*.

    Parameters
    ----------
    graph_level : str
        One of the keys of :data:`GRAPH_LEVELS`.

    Returns
    -------
    Callable[[MultiDiGraph], MultiDiGraph]
        The level's builder: a ``GraphAbstractor.build_*`` static method, or
        :func:`build_process_flow_graph` for ``process_flow``.

    Raises
    ------
    ValueError
        If *graph_level* is not a known level.
    """
    try:
        return GRAPH_LEVELS[graph_level]
    except KeyError:
        raise ValueError(
            f"Invalid graph_level={graph_level!r}. "
            f"Valid values: {', '.join(repr(key) for key in GRAPH_LEVELS)}."
        ) from None


def stamp_graph_level(graph: MultiDiGraph, graph_level: str) -> None:
    """Record *graph_level* on *graph* and on every one of its nodes and edges.

    The graph attribute is what GraphML and node-link JSON carry in their
    document header; the node and edge attributes are what make the level
    filterable in a graph database, which has no graph object to query
    (``MATCH (n {graph_level: 'process'})``).

    Parameters
    ----------
    graph : MultiDiGraph
        The graph to stamp, modified in place.
    graph_level : str
        The abstraction level to record. An ``Enum`` member is stored as its value: a
        ``StrEnum`` satisfies the ``str`` contract and reads back correctly everywhere, but
        ``nx.write_graphml`` dispatches on the exact type and would refuse the whole document,
        so what is stored is the plain string the annotation promises.
    """
    if isinstance(graph_level, Enum):
        graph_level = graph_level.value
    graph.graph[GRAPH_LEVEL_ATTRIBUTE] = graph_level
    for _, attrs in graph.nodes(data=True):
        attrs[GRAPH_LEVEL_ATTRIBUTE] = graph_level
    for _, _, attrs in graph.edges(data=True):
        attrs[GRAPH_LEVEL_ATTRIBUTE] = graph_level


def build_level(raw: MultiDiGraph, graph_level: str, *, stamp: bool = True) -> MultiDiGraph:
    """Abstract *raw* to *graph_level* and stamp the level onto the result.

    Stamping happens *after* abstraction so that nodes and edges synthesised by
    the collapsing and stitching passes are covered too.

    Parameters
    ----------
    raw : MultiDiGraph
        The unabstracted graph from :class:`GraphLoader`.  Left untouched: each
        P&ID builder works on its own deep copy, and :func:`build_process_flow_graph`
        builds a new graph from it.
    graph_level : str
        One of the keys of :data:`GRAPH_LEVELS`.
    stamp : bool, default ``True``
        Whether to record the level via :func:`stamp_graph_level`.

    Returns
    -------
    MultiDiGraph
        The abstracted graph.
    """
    graph = resolve_abstraction(graph_level)(raw)
    if stamp:
        stamp_graph_level(graph, graph_level)
    return graph
