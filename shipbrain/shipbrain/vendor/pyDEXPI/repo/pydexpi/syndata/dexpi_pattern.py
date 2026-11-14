"""This module contains child classes for pattern and connectors to use
the synthetic data generator on DEXPI data."""

from __future__ import annotations

from pydexpi.pydexpi_classes import EngineeringModel
from pydexpi.pydexpi_classes.plant import piping
from pydexpi.syndata.pattern import Connector, Pattern
from pydexpi.toolkits import model_toolkit as mt, piping_toolkit as pt


class BasicPipingInConnector(Connector):
    """Extends the Connector for a basic piping in connection in DEXPI. For
    this, it wraps a PipingTargetItem and optionally an associated node.

    Inherited Attributes
    -------------------
    label : str
        The label for the connector, inherited from `Connector`.
    kwinfos : dict, optional
        Additional keyword arguments for the connector, inherited from
        `Connector`.

    Attributes
    ----------
    target_item : piping.PipingTargetItem
        The PipingTargetItem wrapped by the connection.
    target_node_index : int, optional
        The index of the target node in the PipingTargetItem. If None, no
        specific node is targeted and connections are established only via the
        item."""

    def __init__(
        self,
        label: str,
        target_item: piping.PipingTargetItem,
        target_node_index: int | None = None,
        kwinfos: dict | None = None,
    ) -> None:
        """
        Initializes a BasicPipingInConnector.

        Parameters
        ----------
        label : str
            The label for the connector.
        target_item : piping.PipingTargetItem
            The PipingTargetItem associated with the connection.
        target_node_index : int, optional
            The index of the target node in the PipingTargetItem. If None, no
            specific node is targeted.
        kwinfos : dict, optional
            Additional keyword arguments for the connector.

        Raises
        ------
        TypeError
            If `target_item` is not an instance of PipingTargetItem.
        IndexError
            If `target_node_index` is specified but is out of the range of the
            target item's nodes.
        """
        if not isinstance(target_item, piping.PipingTargetItem):
            raise TypeError("Reference object must be a DEPXI PipingTargetItem")
        if target_node_index is not None and target_node_index >= len(target_item.nodes):
            raise IndexError("Target node index is out of range")
        super().__init__(label, kwinfos)
        self.target_item = target_item
        self.target_node_index = target_node_index

    def assess_valid_counterpart(self, counterpart: Connector) -> bool:
        """Implement abstract method to check for counterpart compatibility.
        Counterpart is valid if it is a BasicPipingOutConnector

        Parameters
        ----------
        counterpart : Connector
            The candidate counterpart to be assessed for connection
            compatibility.

        Returns
        -------
        bool
            True if counterpart is suitable for connection, False otherwise
        """
        return isinstance(counterpart, BasicPipingOutConnector)

    def _implement_connection(self, counterpart: BasicPipingOutConnector) -> None:
        """
        Implements the connection with a counterpart connector.

        Parameters
        ----------
        counterpart : BasicPipingOutConnector
            The counterpart connector to connect with.

        Raises
        ------
        TypeError
            If `counterpart` is not an instance of BasicPipingOutConnector.
        """
        if not isinstance(counterpart, BasicPipingOutConnector):
            raise TypeError("Countertype needs to be a BasicPipingOutConnector")
        counterpart._implement_connection(self)


class BasicPipingOutConnector(Connector):
    """Extends the Connector for a basic piping out connection in DEXPI. For
    this, it wraps a PipingTargetItem.

    Inherited Attributes
    -------------------
    label : str
        The label for the connector, inherited from `Connector`.
    kwinfos : dict, optional
        Additional keyword arguments for the connector, inherited from
        `Connector`.

    Attributes
    ----------
    piping_network_segment : piping.PipingNetworkSegment
        The PipingNetworkSegment wrapped by the connection.

    """

    def __init__(
        self,
        label: str,
        piping_network_segment: piping.PipingNetworkSegment,
        kwinfos: dict | None = None,
    ) -> None:
        """
        Initializes a BasicPipingOutConnector.

        Parameters
        ----------
        label : str
            The label for the connector.
        piping_network_segment : piping.PipingNetworkSegment
            The PipingNetworkSegment associated with the connection.
        kwinfos : dict, optional
            Additional keyword arguments for the connector.

        Raises
        ------
        TypeError
            If `piping_network_segment` is not an instance of PipingNetworkSegment.
        """
        if not isinstance(piping_network_segment, piping.PipingNetworkSegment):
            raise TypeError("Reference object must be a DEPXI PipingNetworkSegment")
        super().__init__(label, kwinfos)
        self.piping_network_segment = piping_network_segment

    def assess_valid_counterpart(self, counterpart: Connector) -> bool:
        """Implement abstract method to check for counterpart compatibility.
        Counterpart is valid if it is a BasicPipingInConnector

        Parameters
        ----------
        counterpart : Connector
            The candidate counterpart to be assessed for connection
            compatibility.

        Returns
        -------
        bool
            True if counterpart is suitable for connection, False otherwise
        """
        return isinstance(counterpart, BasicPipingInConnector)

    def _implement_connection(self, counterpart: BasicPipingInConnector) -> None:
        """
        Implements the connection with a counterpart connector, using the
        pydexpi piping toolkit.

        Parameters
        ----------
        counterpart : BasicPipingInConnector
            The counterpart connector to connect with.

        Raises
        ------
        TypeError
            If `counterpart` is not an instance of BasicPipingInConnector.
        """
        if not isinstance(counterpart, BasicPipingInConnector):
            raise TypeError("Countertype needs to be a BasicPipingInConnector")
        pt.connect_piping_network_segment(
            self.piping_network_segment,
            counterpart.target_item,
            connector_node_index=counterpart.target_node_index,
        )


class DexpiPattern(Pattern):
    """
    Extends the Pattern class to represent a DEXPI pattern. This class wrapps a
    DEXPI model and extends functionality for connecting patterns and
    incorporating other DEXPI patterns.

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
    dexpi_model : EngineeringModel
        The DEXPI model associated with this pattern.
    """

    def __init__(
        self,
        label: str,
        connectors: dict[str, Connector],
        dexpi_model: EngineeringModel,
        observer_patterns: dict[str, Pattern] | None = None,
        kwinfos: dict | None = None,
    ) -> None:
        """
        Initializes a DexpiPattern with the given label, connectors, and DEXPI
        model.

        Parameters
        ----------
        label : str
            The label for the pattern.
        connectors : dict[str, Connector]
            A list of connectors associated with this pattern.
        dexpi_model : EngineeringModel
            The DEXPI model associated with this pattern.
        observer_patterns : dict[str, Pattern], optional
            A dictionary of observer Pattern objects. If None, no observer
            patterns are used.
        kwinfos : dict, optional
            Additional keyword information for the pattern.

        Raises
        ------
        TypeError
            If any of the connectors are not valid connector subtypes.
        """
        valid_connector_types = (
            BasicPipingInConnector,
            BasicPipingOutConnector,
        )
        # For backwards compatibility, cast a list of connectors to a dict
        if isinstance(connectors, list):
            connectors = {connector.label: connector for connector in connectors}

        for connector in connectors.values():
            if not isinstance(connector, valid_connector_types):
                raise TypeError(
                    "A connector in the passed connectors does nothave the correct type."
                )

        super().__init__(label, connectors, observer_patterns, kwinfos)
        self.dexpi_model = dexpi_model

    def _implement_incorporation(self, counterpart: DexpiPattern) -> None:
        """
        Incorporates the specified counterpart DexpiPattern into this pattern,
        using the pydexpi model toolkit.

        Parameters
        ----------
        counterpart : DexpiPattern
            The counterpart pattern to be incorporated.

        Raises
        ------
        TypeError
            If `counterpart` is not an instance of DexpiPattern.
        """
        if not isinstance(counterpart, DexpiPattern):
            raise TypeError("Counterpart must be a DexpiPattern")
        super()._implement_incorporation(counterpart)
        mt.import_model_contents_into_model(self.dexpi_model, [counterpart.dexpi_model])

    def _copy_content(self) -> DexpiPattern:
        """
        Creates a deep copy of this DexpiPattern, including its DEXPI model.

        Returns
        -------
        DexpiPattern
            A deep copy of this DexpiPattern, with fresh ids for every object in its model.
        """
        pattern = super()._copy_content()

        # Reassign ids
        mt.reassign_ids_in_model(pattern.dexpi_model)
        return pattern
