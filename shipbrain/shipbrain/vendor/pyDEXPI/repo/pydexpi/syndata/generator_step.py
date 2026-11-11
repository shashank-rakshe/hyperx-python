"""Step classes for the generator.

These classes define the steps that can be taken during the generation process."""

from abc import ABC, abstractmethod
from typing import Protocol, TypedDict

from pydexpi.syndata.connector_renaming import ConnectorRenamingConvention
from pydexpi.syndata.pattern import Connector, Pattern


class GeneratorStepDict(TypedDict):
    """Typed dictionary for the GeneratorStep class."""

    generator_step_type: str
    own_connector: str | None
    next_pattern: str | None
    next_connector: str | None
    sampled_distribution_name: str | None


class WriteableStep(Protocol):
    """Protocol for a step that can be written to a dictionary."""

    def to_dict(self) -> GeneratorStepDict:
        """Converts the step to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the step.
        """


class GeneratorStep(ABC):
    """Abstract base class for a generator step."""

    @abstractmethod
    def to_dict(self) -> GeneratorStepDict:
        """Converts the GeneratorStep to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the generator step.
        """

    @abstractmethod
    def execute_on(self, current_pattern: Pattern) -> None:
        """Executes the generator step.

        This method should be overridden in subclasses to provide specific functionality for each
        generator step.

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to which the generator step is applied.
        """

    @abstractmethod
    def get_termination_status(self) -> bool:
        """Checks if the generator step has reached a termination status.

        Returns
        -------
        bool
            True if the generator step has encodes a termination, False otherwise.
        """

    @abstractmethod
    def apply_renaming_convention(self, renaming_convention: ConnectorRenamingConvention) -> None:
        """Applies the renaming convention to the generator step.

        Parameters
        ----------
        renaming_convention : ConnectorRenamingConvention
            The renaming convention to apply.
        """


class AddPatternStep(GeneratorStep):
    """Generator step for selecting the next pattern.

    Attributes
    ----------
    own_connector : Connector
        The connector of the current pattern to participate in connection.
    next_pattern : Pattern
        The next pattern to be incorporated.
    next_connector : Connector
        The connector of the next pattern to be used in connection.
    sampled_distribution_name : str
        The name of the distribution that was selected for this step and that was sampled from.
    """

    def __init__(
        self,
        own_connector: Connector,
        next_pattern: Pattern,
        next_connector: Connector,
        sampled_distribution_name: str,
    ) -> None:
        """
        Initializes a generator step with the specified connectors, pattern, and distribution name.

        Parameters
        ----------
        own_connector : Connector
            The connector associated with the current step.
        next_pattern : Pattern
            The pattern to be used for the next step.
        next_connector : Connector
            The connector associated with the next step.
        sampled_distribution_name : str
            The name of the sampled distribution for this step.
        """
        super().__init__()
        if next_connector not in next_pattern.connectors.values():
            msg = (
                f"The connector {next_connector.label} is not associated "
                f"with the next pattern {next_pattern.label}."
            )
            raise ValueError(msg)
        self.own_connector = own_connector
        self.next_pattern = next_pattern
        self.next_connector = next_connector
        self.sampled_distribution_name = sampled_distribution_name

    def to_dict(self) -> GeneratorStepDict:
        """Converts the GeneratorStep to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the generator step.
        """
        return {
            "generator_step_type": "add_pattern",
            "own_connector": self.own_connector.label,
            "next_pattern": self.next_pattern.label,
            "next_connector": self.next_connector.label,
            "sampled_distribution_name": self.sampled_distribution_name,
        }

    def execute_on(self, current_pattern: Pattern) -> None:
        """Executes the generator step by incorporating the next pattern.

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to which the generator step is applied.
        """
        if self.own_connector not in current_pattern.connectors.values():
            msg = (
                f"The connector {self.own_connector.label} is not associated "
                f"with the current pattern {current_pattern.label}."
            )
            raise RuntimeError(msg)
        current_pattern.incorporate_pattern(
            self.own_connector, self.next_pattern, self.next_connector
        )

    def get_termination_status(self) -> bool:
        """Checks if the generator step has reached a termination status.

        Returns
        -------
        bool
            True if the generator step has encodes a termination, False otherwise.
            Always returns False for AddPatternStep.
        """
        return False

    def apply_renaming_convention(self, renaming_convention: ConnectorRenamingConvention) -> None:
        """Applies the renaming convention to the generator step.

        Renames all connectors in the next pattern, except for the next connector (Which will be
        connected to the current pattern, thus not being part of the aggregated pattern).

        Parameters
        ----------
        renaming_convention : ConnectorRenamingConvention
            The renaming convention to apply.
        """
        renaming_convention.rename_connectors(self.next_pattern, [self.next_connector])


class InternalConnectionStep(GeneratorStep):
    """Generator step for internal connections.

    Attribute names are chosen to be consistent with the AddPatternStep class.

    Attributes
    ----------
    own_connector : Connector
        The first connector in the internal connection.
    next_connector : Connector
        The second connector in the internal connection.
    """

    def __init__(self, own_connector: Connector, next_connector: Connector):
        """
        Initializes a new instance of the class.
        Parameters
        ----------
        own_connector : Connector
            The connector associated with the current instance.
        next_connector : Connector
            The second, internal connector to be connected.

        Raises
        ------
        ValueError
            If the own_connector and next_connector are the same.
        """
        super().__init__()
        if own_connector == next_connector:
            msg = f"The connector {own_connector.label} cannot be connected to itself."
            raise ValueError(msg)
        self.own_connector = own_connector
        self.next_connector = next_connector

    def to_dict(self) -> GeneratorStepDict:
        """Converts the GeneratorStep to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the generator step.
        """
        return {
            "generator_step_type": "internal_connection",
            "own_connector": self.own_connector.label,
            "next_pattern": None,
            "next_connector": self.next_connector.label,
            "sampled_distribution_name": None,
        }

    def execute_on(self, current_pattern: Pattern) -> None:
        """Executes the generator step by performing an internal connection.

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to which the generator step is applied.

        Raises
        ------
        RuntimeError
            If the connectors are not associated with the current pattern.
        """
        if self.own_connector not in current_pattern.connectors.values():
            msg = (
                f"The connector {self.own_connector.label} is not associated "
                f"with the current pattern {current_pattern.label}."
            )
            raise RuntimeError(msg)
        if self.next_connector not in current_pattern.connectors.values():
            msg = (
                f"The connector {self.next_connector.label} is not associated "
                f"with the current pattern {current_pattern.label}."
            )
            raise RuntimeError(msg)
        current_pattern.connect_internal(self.own_connector, self.next_connector)

    def get_termination_status(self) -> bool:
        """Checks if the generator step has reached a termination status.

        Returns
        -------
        bool
            True if the generator step has encodes a termination, False otherwise.
            Always returns False for InternalConnectionStep.
        """
        return False

    def apply_renaming_convention(self, renaming_convention: ConnectorRenamingConvention) -> None:
        """Applies the renaming convention to the generator step. Does nothing for this step.

        Parameters
        ----------
        renaming_convention : ConnectorRenamingConvention
            The renaming convention to apply.
        """


class TerminationStep(GeneratorStep):
    """Generator step for termination."""

    def __init__(self) -> None:
        """Initializes the TerminationStep."""
        super().__init__()

    def to_dict(self) -> GeneratorStepDict:
        """Converts the GeneratorStep to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the generator step.
        """
        return {
            "generator_step_type": "termination",
            "own_connector": None,
            "next_pattern": None,
            "next_connector": None,
            "sampled_distribution_name": None,
        }

    def execute_on(self, current_pattern: Pattern) -> None:
        """Executes the termination step on the given pattern, does nothing for this step.

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to which the termination is applied.
        """

    def get_termination_status(self) -> bool:
        """Checks if the generator step has reached a termination status.

        Returns
        -------
        bool
            True if the generator step has encodes a termination, False otherwise.
            Always returns True for TerminationStep.
        """
        return True

    def apply_renaming_convention(self, renaming_convention: ConnectorRenamingConvention) -> None:
        """Applies the renaming convention to the generator step. Does nothing for this step.

        Parameters
        ----------
        renaming_convention : ConnectorRenamingConvention
            The renaming convention to apply.
        """


class InitializationStep:
    """Generator step for initialization.

    Attributes
    ----------
    next_pattern : Pattern
        The initial pattern to start the generation process.
    sampled_distribution_name : str
        The name of the distribution that was selected for this step.
    """

    def __init__(self, init_pattern: Pattern, sampled_distribution_name: str) -> None:
        """Initializes the InitializationStep.

        Parameters
        ----------
        init_pattern : Pattern
            The initial pattern to start the generation process.
        sampled_distribution_name : str
            The name of the distribution that was selected for this step.
        """
        self.init_pattern = init_pattern
        self.sampled_distribution_name = sampled_distribution_name

    def to_dict(self) -> GeneratorStepDict:
        """Converts the GeneratorStep to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the generator step.
        """
        return {
            "generator_step_type": "initialization",
            "own_connector": None,
            "next_pattern": self.init_pattern.label,
            "next_connector": None,
            "sampled_distribution_name": self.sampled_distribution_name,
        }

    def get_pattern(self) -> Pattern:
        """Executes the generator step by initializing the pattern.

        Returns
        -------
        Pattern
            The initialized pattern.
        """
        return self.init_pattern


class CappingStep:
    """Step for capping a connector on a pattern.

    It incorporates a capping pattern if next_pattern and next_connectors are specified in the step.
    If none is specified, drop_connector is called.

    Attributes
    ----------
    own_connector : Connector
        The connector of the current pattern to be capped.
    next_pattern : Pattern
        The next pattern to be incorporated.
    next_connector : Connector
        The connector of the next pattern to be used in connection.
    sampled_distribution_name : str
        The name of the distribution that was selected for this step and that was sampled from.
    """

    def __init__(
        self,
        own_connector: Connector,
        next_pattern: Pattern | None = None,
        next_connector: Connector | None = None,
        sampled_distribution_name: str | None = None,
    ) -> None:
        """
        Initializes a capping step with the specified connectors, pattern, and distribution name.

        Parameters
        ----------
        own_connector : Connector
            The connector associated with the current step.
        next_pattern : Pattern, optional
            The pattern to be used for the next step.
        next_connector : Connector, optional
            The connector associated with the next step.
        sampled_distribution_name : str, optional
            The name of the sampled distribution for this step.

        Raises
        ------
        ValueError
            If the next connector is not associated with the next pattern or if the next pattern has more than one connector.
        """
        super().__init__()
        if next_pattern is not None:
            if next_connector not in next_pattern.connectors.values():
                msg = (
                    f"The connector {next_connector.label} is not associated "
                    f"with the next pattern {next_pattern.label}."
                )
                raise ValueError(msg)
            if len(next_pattern.connectors) != 1:
                msg = f"The next pattern {next_pattern.label} has more than one connector. Invalid capping connector."
                raise ValueError(msg)
        self.own_connector = own_connector
        self.next_pattern = next_pattern
        self.next_connector = next_connector
        self.sampled_distribution_name = sampled_distribution_name

    def to_dict(self) -> GeneratorStepDict:
        """Converts the CappingStep to a dictionary.

        Returns
        -------
        GeneratorStepDict
            Dictionary representation of the generator step.
        """
        return {
            "generator_step_type": "capping",
            "own_connector": self.own_connector.label,
            "next_pattern": self.next_pattern.label if self.next_pattern else None,
            "next_connector": self.next_connector.label if self.next_connector else None,
            "sampled_distribution_name": self.sampled_distribution_name,
        }

    def execute_on(self, current_pattern: Pattern) -> None:
        """Executes the Capping step by incorporating the next pattern.

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to which the generator step is applied.
        """
        if self.next_pattern is not None:
            if self.own_connector not in current_pattern.connectors.values():
                msg = (
                    f"The connector {self.own_connector.label} is not associated "
                    f"with the current pattern {current_pattern.label}."
                )
                raise RuntimeError(msg)
            current_pattern.incorporate_pattern(
                self.own_connector, self.next_pattern, self.next_connector
            )
        else:
            current_pattern.drop_connector(self.own_connector)
