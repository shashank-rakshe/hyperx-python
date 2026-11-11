"""This module contains child classes for pattern and connectors to use
the synthetic data generator on GraphML graphs."""

from __future__ import annotations

import uuid

import networkx as nx

from pydexpi.syndata.pattern import Connector, Pattern


class GraphConnector(Connector):
    """Extends the Connector for a P&ID graph representation in networkx.

    Defines common attributes for graph connectors for graphs with unattributed
    edges. Edge attributes can be added in subclass implementations by
    overriding `get_edge_attrs()`. This design enables adding type
    information to edge attributes while maintaining extensibility for graph
    connection types.

    A graph connector can only connect to another connector of the same class
    with an opposite inlet flag. Subclasses provide a `get_edge_type()` method
    to determine specific edge types.

    Because NetworkX Stores connections on a graph level rather than a node
    level, the graph connector does not contain any connection functionality.
    Connection logic is performed in pattern with _connect_via_pattern.

    Inherited Attributes
    -------------------
    label : str
        The label for the connector, inherited from `Connector`.
    kwinfos : dict, optional
        Additional keyword arguments for the connector, inherited from
        `Connector`.

    Attributes
    ----------
    reference_node_id : str
        The id of the node referenced as connection interface
    is_inlet : bool
        If this connector is a source or a destination for the directed edge
    """

    def __init__(
        self,
        label: str,
        reference_node_id: str,
        is_inlet: bool,
        kwinfos: dict | None = None,
    ) -> None:
        """
        Initializes a GraphConnector.

        Parameters
        ----------
        label : str
            The label for the connector.
            reference_node_id : str
        The id of the node referenced as connection interface
        connector_type : ConnectorType
            The type of the connector, used to ensure valid connection
            combinations.
        kwinfos : dict, optional
            Additional keyword arguments for the connector.
        """
        super().__init__(label, kwinfos)
        self.reference_node_id = reference_node_id
        self.is_inlet = is_inlet

    def get_edge_attrs(self) -> dict:
        """Returns the connection type to be placed on the edge attributes of
        the graph. Implementation is specific to subclasses. Recommended
        implementation via static, class level dict attribute.

        Returns
        -------
        dict:
            The attribute kw args to be placed on any new edge."""
        return {}

    def assess_valid_counterpart(self, counterpart: GraphConnector) -> bool:
        """Assesses the validity of a counterpart graph connector. A graph
        connector is valid if it is of the same class and has the opposite
        is_inlet flag.

        Parameters
        ----------
        counterpart: GraphConnector
            The counterpart to be checked for validity.

        Returns
        -------
        bool:
            True if the counterpart is valid, False otherwise.
        """
        validity = isinstance(counterpart, self.__class__) and self.is_inlet ^ counterpart.is_inlet
        return validity

    def _implement_connection(self, counterpart: GraphConnector) -> None:
        """Empty implementation of _implement_connection. The implementation
        is empty, because connection is performed on pattern level via
        _connect_via_pattern."""


class GraphBasicPipingConnector(GraphConnector):
    """Simple implementation for attributed pipe edges.
    See GraphConnector for general behavior."""

    edge_type_key = "edge_type"
    edge_type = "PipingConnection"

    @classmethod
    def get_edge_attrs(cls) -> dict:
        return {cls.edge_type_key: cls.edge_type}


class GraphBasicSignalConnector(GraphConnector):
    """Simple implementation for attributed signal edges.
    See GraphConnector for general behavior."""

    edge_type_key = "edge_type"
    edge_type = "SignalConnection"

    @classmethod
    def get_edge_attrs(cls) -> dict:
        return {cls.edge_type_key: cls.edge_type}


class GraphPattern(Pattern):
    """
    Extends the Pattern class to represent a graph pattern. This class wrapps a
    networkx graph and extends functionality for connecting patterns and
    incorporating other graph patterns. To ensure unique hashability, each node
    is assigned a uuid as label, with any associated data to be placed in node
    data.

    Inherited Attributes
    ----------
    label : str
        The label for the pattern.
    connectors : list[Connector]
        A list of connectors associated with this pattern.
    observer_patterns : dict[str, Pattern], optional
        A dictionary of observer Pattern objects. If None, no observer
        patterns are used.
    kwinfos : dict, optional
        Additional keyword information for the pattern.

    Attributes
    ----------
    the_graph : nx.DiGraph
        The networkx graph associated with this pattern.
    """

    def __init__(
        self,
        label: str,
        the_graph: nx.DiGraph,
        connectors: dict[str, GraphConnector],
        observer_patterns: dict[str, Pattern] | None = None,
        kwinfos: dict | None = None,
    ) -> None:
        """
        Initializes a GraphPattern with the given label, connectors, and graph.

        Parameters
        ----------
        label : str
            The label for the pattern.
        connectors : list[Connector]
            A list of connectors associated with this pattern.
        the_graph : nx.DiGraph
        The networkx graph associated with this pattern.
        observer_patterns : dict[str, Pattern], optional
            A dictionary of observer Pattern objects. If None, no observer
            patterns are used.
        kwinfos : dict, optional
            Additional keyword information for the pattern.

        Raises
        ------
        ValueError
            If any connector reference not in the graph nodes.
        """
        # For backwards compatibility, cast a list of connectors to a dict
        if isinstance(connectors, list):
            connectors = {connector.label: connector for connector in connectors}

        # First, do some consistency checks
        for connector in connectors.values():
            if connector.reference_node_id not in the_graph.nodes:
                msg = (
                    f"The node {connector.reference_node_id} is not associated "
                    f"to graph {the_graph}. Pattern couldnt be created."
                )
                raise ValueError(msg)

        # Construct the object
        super().__init__(label, connectors, observer_patterns, kwinfos)
        self.the_graph = the_graph

    def _implement_incorporation(self, counterpart: GraphPattern) -> None:
        """Imports all nodes and edges of the counterpart into this patterns
        graph.

        Parameters
        ----------
        counterpart : GraphPattern
            The counterpart to be incorporated.

        Raises
        ------
        ValueError
            If any node or edge label of the counterpart is already found in
            this patterns graph.
        """
        # Check for overlapping nodes
        if set(self.the_graph.nodes).intersection(counterpart.the_graph.nodes):
            raise ValueError("Node overlap detected between G1 and G2.")

        # Check for overlapping edges
        if set(self.the_graph.edges).intersection(counterpart.the_graph.edges):
            raise ValueError("Edge overlap detected between G1 and G2.")

        super()._implement_incorporation(counterpart)

        # Import nodes and edges
        self.the_graph.add_nodes_from(counterpart.the_graph.nodes(data=True))
        self.the_graph.add_edges_from(counterpart.the_graph.edges(data=True))

    def _connect_via_pattern(
        self, connector: GraphConnector, counterpart_connector: GraphConnector
    ) -> None:
        """Connect the connectors by adding a new edge to this patterns graph
         object.

        Parameters
        ----------
        connector : GraphConnector
            The connector to be connected to counterpart
        counterpart_connector : GraphConnector
            The counterpart connector to be connected to the connector.
        """
        # Determine edge direction
        if counterpart_connector.is_inlet:
            source_id = connector.reference_node_id
            target_id = counterpart_connector.reference_node_id
        else:
            source_id = counterpart_connector.reference_node_id
            target_id = connector.reference_node_id

        # Determine edge label
        edge_kwargs = connector.get_edge_attrs()

        # Perform connection
        self.the_graph.add_edge(source_id, target_id, **edge_kwargs)

    def copy_pattern(self, *args, **kwargs):
        """Override parent copy method to assign a new UUID to the wrapped
        graph.

        Returns
        -------
        GraphPattern
            The deepcopied pattern
        """
        copied_pattern = super().copy_pattern(*args, **kwargs)
        new_label_map = {
            old_label: str(uuid.uuid4()) for old_label in copied_pattern.the_graph.nodes
        }
        copied_pattern.the_graph = nx.relabel_nodes(copied_pattern.the_graph, new_label_map)

        for connector in copied_pattern.connectors.values():
            connector.reference_node_id = new_label_map[connector.reference_node_id]
        return copied_pattern
