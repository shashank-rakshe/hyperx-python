"""This module contains the abstract classes of pattern and pattern connectors
for synthetic data generation. To use these, extend the abstract classes to
wrap the data classes of interest and define connection and incorporation logic.
"""

from __future__ import annotations

import copy
import pickle
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Self


class Connector(ABC):
    """
    Abstract base class for a connector that manages connection interfaces for
    synthetic data patterns, including connection logic. The class also manages
    a set of observer connectors for parallel generation.

    To implement this abstract class, define the data object to be wrapped by
    overriding the constructor and implement the connection logic in the
    abstract _implement_connection method.

    Attributes
    ----------
    label : str
        A label representing the connector.
    kwinfos : dict, optional
        Additional keyword information that can be accessed, manipulated, and
        referenced by the generator during generation.
    _is_active : bool
        Internal security flag indicating whether the connector is active or
        has been connected or deactivated.
    """

    def __init__(self, label: str, kwinfos: dict | None = None) -> None:
        """
        Initializes the connector object with a label and additional information
        as kwargs.

        Parameters
        ----------
        label : str
            A label for the connector instance.
        **kwinfos
            Additional keyword arguments representing metadata for the
            connector.
        """
        self.label = label
        self.kwinfos = kwinfos if kwinfos is not None else {}
        # Include a safety switch to make sure a connector is only connected once
        self._is_active = True

    @property
    def is_active(self) -> bool:
        """Returns the active status of the connector."""
        return self._is_active

    def connect_to_counterpart(self, counterpart: Connector) -> None:
        """
        Establishes the connection between this connector and a counterpart
        connector.

        This method first checks whether this connector is still active and
        raises a RuntimeError if not. Then, the method calls the subclass-
        specific logic defined in `_implement_connection()` to establish the
        primary connection.

        Parameters
        ----------
        counterpart : Connector
            The counterpart connector instance to which this connector
            will be connected.

        Raises
        ------
        RuntimeError
            If this connector is no longer active.
        ValueError
            If the counterpart is the same object as self or the counterpart is
            invalid.
        """
        # If this connector has been connected before, raise an Error
        if not self._is_active:
            msg = "Attempted to connect a connector object that was already deactivated."
            raise RuntimeError(msg)

        # Make sure connector is not connected to itself
        if counterpart == self:
            raise ValueError("Cannot connect a counterpart to itself.")

        # Make sure connector is valid
        if not self.assess_valid_counterpart(counterpart):
            raise ValueError("Counterpart connector is not valid for connection.")

        # Call subclass specific connection logic
        self._implement_connection(counterpart)

        # Set is_active tag to false after successful connection
        self._is_active = False
        counterpart._is_active = False

    def deactivate(self) -> None:
        """Deactivates an unconnected connector.

        Sets the active flag to False and calls optional subclass specific deactivation logic.

        Raises
        ------
        RuntimeError
            If this connector is no longer active.
        """
        # If this connector has been connected before, raise an Error
        if not self._is_active:
            msg = "Attempted to connect a connector object that was already deactivated."
            raise RuntimeError(msg)

        # Call subclass specific deactivation logic
        self._implement_deactivation()

        # Set is_active tag to false after successful deactivation
        self._is_active = False

    @abstractmethod
    def assess_valid_counterpart(self, counterpart: Connector) -> bool:
        """Abstract method to assess if a given Counterpart is valid for
        connection. Subclass-specific logic to be implemented by child classes.

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

    @abstractmethod
    def _implement_connection(self, counterpart: Connector) -> None:
        """
        Abstract method to implement the primary connection logic for a
        subclass.

        This method is intended to be overridden by subclasses to define how
        the main connection between this connector and the counterpart connector
        should be established, depending on the wrapped interface data
        structure. It is called after validation but before the observers
        are connected.

        Parameters
        ----------
        counterpart : Connector
            The counterpart connector instance to be connected to.
        """

    def _implement_deactivation(self) -> None:  # noqa: B027
        """Optional hook executed when the connector is deactivated without connection.

        Deliberately concrete and empty: a subclass overrides it only if it needs to.
        """


class Pattern(ABC):
    """
    Abstract base class for a pattern that wraps synthetic data patterns, and
    contains pattern interfaces via a list of connections. The class also
    manages a set of observer patterns for parallel generation.

    To implement this abstract class, define the data object to be wrapped by
    overriding the constructor and implement the incorporation logic in the
    abstract `_implement_incorporation method`. If, in an implementation of
    the Pattern, connections need to be performed on a Pattern level and not on
    a Connector level, the _connect_via_pattern method can be implemented.

    Attributes
    ----------
    label : str
        A label representing the pattern.
    connectors : dict[str, Connector]
        The connectors of the pattern defining the connection interfaces
    observer_patterns : dict, optional
        A dictionary of observer patterns, where keys are observer tags and
        values are pattern instances.
    kwinfos : dict, optional
        Additional keyword information that can be accessed, manipulated, and
        referenced by the generator during generation.
    _is_incorporated : bool
        Internal security flag indicating whether the pattern has been
        incorporated.
    """

    def __init__(
        self,
        label: str,
        connectors: dict[str, Connector],
        observer_patterns: dict[str, Pattern] | None = None,
        kwinfos: dict | None = None,
    ) -> None:
        self.label = label

        self._connectors = None
        self.connectors = connectors

        self.observer_patterns: dict[str, Pattern] = {}
        self._is_incorporated = False
        self.kwinfos = kwinfos if kwinfos is not None else {}
        if observer_patterns is not None:
            for tag, observer in observer_patterns.items():
                self.add_observer(tag, observer)

    @property
    def is_incorporated(self) -> bool:
        """Returns the incorporation status of the pattern."""
        return self._is_incorporated

    @property
    def connectors(self) -> dict[str, Connector]:
        """Returns the connectors of the pattern."""
        return self._connectors

    @connectors.setter
    def connectors(self, new_connectors: dict[str, Connector] | list[Connector]) -> None:
        """Sets the connectors of the pattern.

        This method can be used to update the connectors of the pattern. The new connectors can be
        provided as a dictionary where the keys are the labels and the values are the Connector
        objects. Alternatively, a list of Connector objects can be provided.


        Parameters
        ----------
        new_connectors : dict[str, Connector]|list[Connector]
            The new connectors to be set. Can be a list of Connector objects or
            a dictionary where keys are the labels and values are the Connector
            objects.

        Raises
        ------
        ValueError
            If the keys of the dictionary do not match the labels of the
            connectors.
        """
        if isinstance(new_connectors, list):
            self._connectors = {connector.label: connector for connector in new_connectors}
        elif isinstance(new_connectors, dict):
            if not all(key == value.label for key, value in new_connectors.items()):
                raise ValueError("Keys of the dictionary must match the labels of the connectors.")
            self._connectors = new_connectors

    def add_observer(self, observer_tag: str, new_observer: Pattern) -> None:
        """
        Adds a new observer pattern to this pattern instance. To ensure
        conceptual correctness in generation logic, observers must have the same
        string for their label attribute, and the labels of the observer's
        connectors must correspond to the labels of the subject connectors

        Parameters
        ----------
        observer_tag : str
            The identifier for the observer pattern.
        new_observer : Connector
            The new observer pattern to be added.

        Raises
        ------
        ValueError
            If the new observer's label does not match this subject's label, or
            if the connector's of the patterns do not correspond via their
            labels.
        RuntimeError
            If this pattern is already incorporated in another pattern.
        """
        if self._is_incorporated:
            raise RuntimeError("Pattern is already incorporated")
        # Check if observer label matches subect label
        if new_observer.label != self.label:
            msg = "Invalid observer pattern: Observer has a different label."
            raise ValueError(msg)
        # Check if observer has the same number of connectors
        if len(self.connectors) != len(new_observer.connectors):
            msg = "New observer does not have the same amount of connectors"
            raise ValueError(msg)
        # Check if observer connectors match the connectors
        for label, own_connector in self.connectors.items():
            observer_connector = new_observer.connectors.get(label)
            if observer_connector is None or own_connector.label != observer_connector.label:
                msg = "Connectors of the new observer do not match the subject connectors."
                raise ValueError(msg)

        # Add observer, and add each connector of observer as observer to
        # subject connectors
        self.observer_patterns[observer_tag] = new_observer

    def incorporate_pattern(
        self,
        own_connector: Connector,
        counterpart: Pattern,
        counterpart_connector: Connector,
    ) -> None:
        """
        Incorporates a counterpart pattern, including by connecting specified
        connectors and importing of data.

        This method first checks whether the connector arguments are part of
        the corresponding patterns. Then, the method calls the subclass-specific
        logic defined in `_implement_incorporation()` to import the data. Then
        connectors are connected via connect_to_counterpart in the Connectors or
        the alternative connection on pattern level defined in
        _connect_via_pattern. Once the connections are completed, the
        connectors involved in the connection (`own_connector` and
        `counterpart_connector`) are removed from the pattern, and every other
        open connector of the counterpart is added to this pattern under its
        label. After incorporation, the observers are notified to do the same.

        Connector labels key `connectors`, so they must stay unique. The label
        of `own_connector` is freed by the connection, so the counterpart may
        bring an open connector with that same label: it takes over the key.
        Any other clash between a remaining connector of this pattern
        and one of the counterpart is refused with a `ValueError` before
        anything is changed; nothing is renamed implicitly. To incorporate
        patterns whose labels clash, relabel first, for example with
        `ConnectorRenamingConvention`.

        Parameters
        ----------
        own_connector : Connector
            The connector instance associated with this pattern that will be
            responsible for the connection.
        counterpart : Pattern
            The counterpart pattern instance which will be incorporated.
        counterpart_connector : Connector
            The connector instance associated with the counterpart pattern that
            will be used for the connection.

        Raises
        ------
        ValueError
            If the connectors for the connection are not associated to the
            respective patterns, if the observers of the counterpart doesn't
            match with this object's observers, or if an open connector of the
            counterpart shares its label with a remaining connector of this
            pattern other than `own_connector`.
        ValueError
            From connector arguments: If the types of the connectors are an
            invalid combination.
        RuntimeError
            If this pattern is already incorporated in another pattern.
        """
        if self._is_incorporated:
            raise RuntimeError("Pattern is already incorporated")

        # Make sure that all counterpart connector keys are not already in the pattern connectors,
        # except for the own_connector and the counterpart_connector, that are removed in this
        # operation. A counterpart connector may therefore reuse the own_connector's label.
        for key, connector in counterpart.connectors.items():
            if connector == counterpart_connector:
                continue
            if key == own_connector.label:
                continue
            if key in self.connectors:
                raise ValueError(f"Key {key} already in this pattern's connectors.")

        # Make sure that connectors are correctly associated and valid
        if own_connector not in self.connectors.values():
            raise ValueError("Connector argument own_connector not in this pattern's connectors.")
        if counterpart_connector not in counterpart.connectors.values():
            raise ValueError(
                "Connector argument counterpart_connector not in the counterpart pattern's connectors."
            )
        if set(self.observer_patterns.keys()) != set(counterpart.observer_patterns.keys()):
            msg = "Pattern doesnt share the same observers with counterpart pattern."
            raise ValueError(msg)
        if not own_connector.assess_valid_counterpart(counterpart_connector):
            raise ValueError("Own and counterpart connector are not valid for connection.")

        # Perform subtype specific incorporation
        self._implement_incorporation(counterpart)

        # Connect the connectors via connectors, or alternatively via the
        # optional connection logic defined on a pattern level
        own_connector.connect_to_counterpart(counterpart_connector)
        self._connect_via_pattern(own_connector, counterpart_connector)

        # Manage connectors. First remove the own_connector from the pattern, then add all
        # connectors of the counterpart that are not the counterpart_connector. The order matters:
        # a counterpart connector that shares the own_connector's label would otherwise be
        # written over it and then deleted with it.
        del self.connectors[own_connector.label]
        for key, connector in counterpart.connectors.items():
            if connector != counterpart_connector:
                self.connectors[key] = connector

        # Inform observers
        for tag, observer in self.observer_patterns.items():
            counterpart_observer = counterpart.observer_patterns[tag]
            own_connector_observer = observer.connectors[own_connector.label]
            counterpart_connector_observer = counterpart_observer.connectors[
                counterpart_connector.label
            ]
            observer.incorporate_pattern(
                own_connector_observer,
                counterpart_observer,
                counterpart_connector_observer,
            )
        counterpart._is_incorporated = True

    def connect_internal(self, connector: Connector, counterpart: Connector) -> None:
        """Connects two connectors of the pattern internally, e.g., for recycle
        or auxiliary connections.

        First, ensures that both connector arguments are part of this pattern.
        Then, connects the connectors and removes them from this patterns open
        connectors. Finally, observers are informed and their connect_internal
        method is invoked.

        Parameters
        ----------
        connector : Connector
            The first connector to be connected.
        counterpart : Connector
            The second connector to be connected to the first.

        Raises
        ------
        RuntimeError
            If the pattern is already incorporated.
        ValueError
            If either of the connectors provided is not in this pattern's
            connectors.
        """
        # First make sure that this pattern has not yet been incorporated
        if self._is_incorporated:
            raise RuntimeError("Pattern is already incorporated.")

        # Make sure that connectors are correctly associated
        if (connector not in self.connectors.values()) or (
            counterpart not in self.connectors.values()
        ):
            raise ValueError("A connector argument is not in this patterns connectors.")

        # Perform connection via connectors and/or via pattern
        connector.connect_to_counterpart(counterpart)
        self._connect_via_pattern(connector, counterpart)

        # Drop the newly connected connectors
        del self.connectors[connector.label]
        del self.connectors[counterpart.label]

        # Inform observers
        for observer in self.observer_patterns.values():
            observer_connector = observer.connectors[connector.label]
            observer_counterpart = observer.connectors[counterpart.label]
            observer.connect_internal(observer_connector, observer_counterpart)

    def drop_connector(self, connector: Connector) -> None:
        """Removes and deactivates an active, unconnected connector from the pattern.

        First, the method checks if the pattern is not yet incorporated and if
        the connector part of this pattern. Then, it calls the deactivate method
        of the connector and removes it from this pattern's connectors. Finally,
        observers are informed to also drop the corresponding connector.

        Used e.g if connector unconnected at the end of the generation process

        Parameters
        ----------
        connector : Connector
            The connector to be dropped.

        Raises
        ------
        ValueError
            If the connector is not in this pattern's connectors.
        RuntimeError
            If this pattern is already incorporated.
        """
        # Make sure pattern is not incorporated and connector is part of
        # connectors
        if self._is_incorporated:
            raise RuntimeError("Pattern is already incorporated")
        if connector not in self.connectors.values():
            raise ValueError("Connector argument not in this patterns connectors")

        # Drop connector
        connector.deactivate()
        del self.connectors[connector.label]

        # Inform observers
        for observer in self.observer_patterns.values():
            observer_connector = observer.connectors[connector.label]
            observer.drop_connector(observer_connector)

    def relabel_connector(self, connector: Connector, new_label: str) -> None:
        """Relabels a connector and informs all observers to do the same.

        Parameters
        ----------
        connector : Connector
            The connector to be relabeled.
        new_label : str
            The new label for the connector. Relabelling a connector to the
            label it already has changes nothing.

        Raises
        ------
        ValueError
            If the connector is not in this pattern's connectors, if another
            connector of this pattern, or of one of its observers, already has
            `new_label`, or if an observer has no connector with the connector's
            current label. Nothing is changed in this pattern or its observers in
            any of these cases.
        """
        if connector not in self.connectors.values():
            raise ValueError("Connector argument not in this patterns connectors")
        old_label = connector.label
        if new_label == old_label:
            # Writing and then deleting the same key would drop the connector.
            return
        # Check the whole observer tree first, so a refusal leaves everything as it was.
        self._check_relabel(old_label, new_label)

        # Change label of the connector
        connector.label = new_label
        self.connectors[new_label] = connector
        del self.connectors[old_label]

        # Inform observers
        for observer in self.observer_patterns.values():
            observer_connector = observer.connectors[old_label]
            observer.relabel_connector(observer_connector, new_label)

    def _check_relabel(self, old_label: str, new_label: str) -> None:
        """Check that this pattern and all its observers can relabel `old_label`.

        Parameters
        ----------
        old_label : str
            The label of the connector to be relabelled.
        new_label : str
            The label the connector is to receive.

        Raises
        ------
        ValueError
            If this pattern or an observer, at any depth, has no connector labelled
            `old_label`, or already has a connector labelled `new_label`.
        """
        if old_label not in self.connectors:
            raise ValueError(f"Key {old_label} not in this pattern's connectors.")
        if new_label in self.connectors:
            raise ValueError(f"Key {new_label} already in this pattern's connectors.")
        for observer in self.observer_patterns.values():
            observer._check_relabel(old_label, new_label)

    def copy_pattern(self) -> Self:
        """Make a copy of the pattern.

        Copy operation to be applied when sampling and incorporating a Pattern, so that the
        template pattern can be sampled and used multiple times during generation.

        By default, patterns are deepcopied with copy.deepcopy, and `copy_pattern()` is invoked on
        the observers. If more or more complex operations are required for this, such as
        reassigning ids, the method, or copy_content, should be overridden appropriately.

        Returns
        -------
        Pattern
            The copied pattern
        """
        # Temporarily detach observers
        temp_observer_patterns = self.observer_patterns
        self.observer_patterns = {}

        # Copy pattern, but make sure to reattach observers in case of a problem
        try:
            the_copied_pattern = self._copy_content()
        finally:
            self.observer_patterns = temp_observer_patterns

        # Finally, invoke copy_pattern on all observers and add them as
        # observers to the copy

        for observer_tag, observer in temp_observer_patterns.items():
            copied_observer = observer.copy_pattern()
            the_copied_pattern.add_observer(observer_tag, copied_observer)

        return the_copied_pattern

    def _copy_content(self) -> Self:
        """Copy the content of the pattern without observers.

        This method can be overridden if the copy mechanism for the pattern should change but the
        mechanism of detatching and reattaching observers should remain the same. By default, this
        method deepcopies the Pattern."""
        return copy.deepcopy(self)

    def change_label(self, new_label: str) -> None:
        """This method updates the label of the object and notifies
        all observer patterns associated to also change the label.

        Parameters
        ----------
        new_label : str
            The new label to assign to the object.
        """
        # Change label
        self.label = new_label

        # Inform observers
        for observer in self.observer_patterns.values():
            observer.change_label(new_label)

        self.label = new_label

    def save(self, dir_path: Path, file_name: str) -> None:
        """
        Default saving behavior of an abstract pattern. Saves the current
        pattern to a pickle file.

        This method can be overridden by subclasses to provide more meaningful
        serializations based on the data structure enclosed by the subclass.

        Parameters
        ----------
        dir_path : Path
            The directory path where the pickle file will be saved.
        file_name : str
            The name of the pickle file. If the extension ".pkl" is not included,
            it will be appended automatically.
        """
        if not file_name.endswith(".pkl"):
            file_name += ".pkl"
        path = Path(dir_path) / file_name
        with open(path, "wb") as file:
            # Use pickle to serialize the object
            pickle.dump(self, file)

    @classmethod
    def load(cls, dir_path: Path, file_name: str) -> None:
        """
        Default loading behavior of an abstract pattern. Loads a pattern from a
        pickle file.

        This method can be overridden by subclasses to provide more meaningful
        deserializations based on the data structure enclosed by the subclass.

        Parameters
        ----------
        dir_path : Path
            The directory path where the pickle file is located.
        file_name : str
            The name of the pickle file. If the extension ".pkl" is not included,
            it will be appended automatically.

        Returns
        -------
        cls:
            The loaded pattern, if it is an instance of the expected class.

        Raises
        ------
        OSError:
            If the file does not contain a valid object of the expected class.
        """
        if not file_name.endswith(".pkl"):
            file_name += ".pkl"
        path = Path(dir_path) / file_name
        # Open the file in read-binary mode
        with open(path, "rb") as file:
            # Load the distribution object from the file
            the_pattern = pickle.load(file)

        if not isinstance(the_pattern, cls):
            msg = "Pickle file in path does not contain a valid pattern"
            raise OSError(msg)

        return the_pattern

    @abstractmethod
    def _implement_incorporation(
        self,
        counterpart: Pattern,
    ) -> None:
        """
        Abstract method to implement the primary incorporation logic for a
        subclass.

        This method is intended to be overridden by subclasses to handle the
        incorporation of the data of the counterpart into this pattern,
        depending on the wrapped data structure. It is called after validation
        but before the observers are connected.

        NOTE: The data from the counterpart is meant to be imported into the
        data of this pattern, not copied into a new pattern (therefore, no
        return). This ensures the continued validity of connector references.

        Parameters
        ----------
        counterpart : Pattern
            The counterpart pattern instance which will be incorporated.
        """

    def _connect_via_pattern(  # noqa: B027  -- optional hook, deliberately concrete
        self,
        connector: Connector,
        counterpart_connector: Connector,
    ) -> None:
        """This method offers an alternative mode to connect the connectors.
        It can (and should only) be used and implemented if the connection
        requires the pattern-level data structure.

        Parameters
        ----------
        connector : Connector
            The connector instance that should be connected to
            counterpart_connector.
        counterpart_connector : Connector
            The connector instance that should be connected to connector.
        """
