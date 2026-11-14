"""Generator function that encapsulates the logic of the P&ID generation.

This module contains the abstract definition of a generator function used
by the synthetic data generator, following a strategy design pattern.
A particular logic may be defined in a child class of the generator function.
It also contains a sample implementation called RandomGeneratorFunction that
performs all actions completely at random."""

import random
from abc import ABC, abstractmethod

from pydexpi.syndata.generation_history import GenerationHistory
from pydexpi.syndata.generator_step import (
    AddPatternStep,
    CappingStep,
    GeneratorStep,
    InitializationStep,
    InternalConnectionStep,
    TerminationStep,
)
from pydexpi.syndata.pattern import (
    Pattern,
)
from pydexpi.syndata.pattern_distribution import PatternDistribution


class GeneratorFunction(ABC):
    """Abstract class for the generator function. Generator function contains
    the logic of determining the next pattern to be connected, in accordance
    with the strategy design pattern. The logic follows:

    current_pattern_connection,
    next_pattern,
    next_pattern_connection = f(current_pattern)

    A recycle can be produced by returning two connectors of the current pattern
    and no next pattern.

    Attributes
    ----------
    distribution_range: dict[str, PatternDistribution]
        This functions range of possible PatternDistributions to
        sample from.
    """

    def __init__(self, distribution_range: dict[str, PatternDistribution]) -> None:
        """Constructor for an abstract generator function class.

        Takes the distribution range as argument, which is the range of possible
        distributions this generator function samples from. The dictionary must
        have the distribution names as keys.

        Parameters
        ----------
        distribution_range : dict[str, PatternDistribution]
            The range of possible PatternDistributions to sample from.

        Raises
        ------
        ValueError
            If the names of the distributions don't match the keys of the
            distribution_range dictionary argument.
        """
        for the_name, the_distribution in distribution_range.items():
            if the_distribution.name != the_name:
                msg = "Distribution names dont match range keys"
                raise ValueError(msg)

        self.distribution_range = distribution_range

    @abstractmethod
    def get_next_step(self, current_pattern: Pattern) -> GeneratorStep:
        """Dictates the next operation to be performed in the generation process.

        For this, the current pattern is passed as argument and the next
        operation is returned as a GeneratorStep.
        """

    @abstractmethod
    def initialize_pattern(self) -> InitializationStep:
        """Initializes the P&ID generation with a seed pattern.

        Returns
        -------
        InitializationStep
            Initialization step containing the seed pattern and distribution name.
        """


class CappingFunction:
    """Abstract class for the capping function.

    Capping function is used to define how to cap the pattern's remaining, unconnected connectors at
    the end of the generation process. Default implementation is to cap all connectors with a
    default capping step.

    Attributes
    ----------
    distribution_range: dict[str, PatternDistribution]|None
        The range of possible PatternDistributions to sample from. Can be None if not used.

    """

    def __init__(self, distribution_range: dict[str, PatternDistribution] | None = None) -> None:
        """Constructor for the capping function.

        Takes the distribution range as argument, which is the range of possible
        distributions this generator function samples from. The dictionary must
        have the distribution names as keys.

        Parameters
        ----------
        distribution_range : dict[str, PatternDistribution] | None, optional
            The range of possible PatternDistributions to sample from, by default None.
        """
        if distribution_range:
            for distribution in distribution_range.values():
                if len(distribution.connector_labels) != 1:
                    msg = "CappingFunction should only use distributions with one connector label"
                    raise ValueError(msg)

        self.distribution_range = distribution_range

    def get_capping_steps(self, current_pattern: Pattern) -> list[CappingStep]:
        """Returns a list of capping steps for the given pattern.

        Retrieves the capping steps from the subclass-specific method _make_capping_steps, and
        performs some consistency checks on the result.

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to be capped.

        Returns
        -------
        list[GeneratorStep]
            A list of capping steps, one for each connector in the current pattern.

        Raises
        ------
        RuntimeError
            If not all connectors are capped in the capping steps.
        """
        capping_steps = self._make_capping_steps(current_pattern)
        if {step.own_connector for step in capping_steps} != set(
            current_pattern.connectors.values()
        ):
            raise RuntimeError("Connectors of the CappingSteps do not match the current pattern.")
        return capping_steps

    def _make_capping_steps(self, current_pattern: Pattern) -> list[CappingStep]:
        """Generates capping steps for the given pattern.

        This method produces the CappingSteps for the given pattern. It is intended to be overridden
        by subclasses with more complex capping mechanisms. By default, it creates a default capping
        step for each connector (Without incorporating any further elements).

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to be capped.

        Returns
        -------
        list[GeneratorStep]
            A list of capping steps, one for each connector in the current pattern.
        """
        return [CappingStep(connector) for connector in current_pattern.connectors.values()]


class RandomGeneratorFunction(GeneratorFunction):
    """Generator function that selects next patterns and connectors fully at
    random.

    Inherited attributes
    ----------
    distribution_range: dict[str, PatternDistribution]
        This functions range of possible PatternDistributions to
        sample from.

    Attributes
    ----------
    p_connect_internal: float
        The probability to attempt to connect a recycle at each step. If no
        valid recycle connections are found, a new pattern is sampled instead.
    use_distribution_probabilities: bool
        If false, the patterns are sampled from the distribution at random
        instead of using the distribution probabilities.
    """

    def __init__(
        self,
        distribution_range: dict[str, PatternDistribution],
        p_connect_internal: float = 0.0,
        use_distribution_probabilities: bool = True,
    ) -> None:
        """Constructor for a generator function class that selects patterns
        and connectors completely at random.

        Takes the distribution range as argument, which is the range of possible
        distributions this generator function samples from. The dictionary must
        have the distribution names as keys.

        Parameters
        ----------
        distribution_range : dict[str, PatternDistribution]
            The range of possible PatternDistributions to sample from.
        p_connect_internal : float
            The probability that a recycle connection is attempted at each step.
            Must be between 0 and 1.
        use_distribution_probabilities : bool, optional
            Whether to use the pattern distribution probabilities while
            sampling. If False, patterns are sampled fully at random.
            By default True

        Raises
        ------
        ValueError
            If the names of the distributions don't match the keys of the
            distribution_range dictionary argument.

        """
        super().__init__(distribution_range)
        self.p_connect_internal = None
        self.set_p_connect_internal(p_connect_internal)
        self.use_distr_probs = use_distribution_probabilities

    def get_next_step(self, current_pattern: Pattern) -> GeneratorStep:
        """Implements the generator function to decide the next operation.

        First, a decision is made whether to connect a recycle or sample a new
        pattern. If a recycle is to be connected, a random internal connection is obtained from
        select_internal_connector. If no valid internal connection is found or the decision is
        made to sample a new pattern, the select_next_pattern function is called.

        Parameters
        ----------
        current_pattern : Pattern
            Current state of the P&ID.

        Returns
        -------
        GeneratorStep
            The next step to be performed
        """
        connect_internal = random.choices(
            [True, False],
            weights=[self.p_connect_internal, 1 - self.p_connect_internal],
        )[0]
        if connect_internal:
            # Select random internal connectors
            internal_connection_step = self.select_internal_connector(current_pattern)
            # If no compatible, internal connectors are found, default to sampling a new pattern
            if internal_connection_step is None:
                return self.select_next_pattern(current_pattern)
            else:
                return internal_connection_step
        else:
            return self.select_next_pattern(current_pattern)

    def initialize_pattern(self) -> InitializationStep:
        """Initializes the P&ID generation with a seed pattern that is selected
        at random.

        Returns
        -------
        InitializationStep
            Initialization step containing the seed pattern and distribution name.
        """
        # Randomly choose a distribution
        next_distribution = random.choice(list(self.distribution_range.values()))

        # Randomly choose a pattern
        init_pattern, _ = (
            next_distribution.sample_pattern()
            if self.use_distr_probs
            else next_distribution.random_pattern()
        )

        return InitializationStep(
            init_pattern=init_pattern,
            sampled_distribution_name=next_distribution.name,
        )

    def select_next_pattern(self, current_pattern: Pattern) -> AddPatternStep | TerminationStep:
        """Selects the next pattern and connectors at random.

        For this, a random connector is selected in the current pattern. Then,
        a random pattern distribution is selected and a pattern sampled from it.
        A suitable connector is selected at random in the next pattern, and the
        sampled connectors and pattern are returned. If no suitable connector is
        available in the patterns of the selected distribution, a different
        distribution is selected randomly. If no distributions fit, a different
        own_connector is selected for the next step, and the connector is
        labeled as unconnectable for future steps.

        If no further connectable connectors remain, return None, None, None

        Parameters
        ----------
        current_pattern : Pattern
            Current state of the P&ID.

        Returns
        -------
        AddPatternStep|TerminationStep
            The next step to be performed. If no further connectable connectors are found,
            a TerminationStep is returned. Otherwise, an AddPatternStep is returned.
        """
        visited_connectors = set()
        while visited_connectors != set(current_pattern.connectors):
            own_conn_choices = [
                conn for conn in current_pattern.connectors if conn not in visited_connectors
            ]
            if not own_conn_choices:
                break

            own_connector_key = random.choice(own_conn_choices)
            visited_connectors.add(own_connector_key)
            own_connector = current_pattern.connectors[own_connector_key]

            if "Connectable" in own_connector.kwinfos and not own_connector.kwinfos["Connectable"]:
                continue

            pattern_found = False
            visited_distributions = set()
            while visited_distributions != set(self.distribution_range.values()):
                distr_choices = [
                    distr
                    for distr in self.distribution_range.values()
                    if distr not in visited_distributions
                ]

                next_distribution = random.choice(distr_choices)
                visited_distributions.add(next_distribution)

                next_pattern, _ = (
                    next_distribution.sample_pattern()
                    if self.use_distr_probs
                    else next_distribution.random_pattern()
                )

                next_conn_choices = [
                    label
                    for label, conn in next_pattern.connectors.items()
                    if own_connector.assess_valid_counterpart(conn)
                ]
                if next_conn_choices:
                    next_connector_key = random.choice(next_conn_choices)
                    next_connector = next_pattern.connectors[next_connector_key]
                    next_step = AddPatternStep(
                        own_connector=own_connector,
                        next_pattern=next_pattern,
                        next_connector=next_connector,
                        sampled_distribution_name=next_distribution.name,
                    )
                    pattern_found = True
                    return next_step

            if not pattern_found:
                own_connector.kwinfos["Connectable"] = False

        return TerminationStep()

    def select_internal_connector(self, current_pattern: Pattern) -> InternalConnectionStep | None:
        """Selects the internal connectors for internal connector at random.

        For this, a random connector is selected in the current pattern. Then
        a second connector is selected randomly from valid counterparts in the
        current pattern. If no valid counterparts are found, a different
        first_connector is selected for the next step.

        If no connector pairs are found in current pattern, return None, None

        Parameters
        ----------
        current_pattern : Pattern
            Current state of the P&ID.

        Returns
        -------
        InternalConnectionStep|None
            The next step to be performed. If no further connectable connectors are found,
            None is returned.

        """
        visited_connectors = set()
        while visited_connectors != set(current_pattern.connectors):
            first_conn_choices = [
                conn for conn in current_pattern.connectors if conn not in visited_connectors
            ]

            first_connector_key = random.choice(first_conn_choices)
            visited_connectors.add(first_connector_key)
            first_connector = current_pattern.connectors[first_connector_key]

            if (
                "Connectable" in first_connector.kwinfos
                and not first_connector.kwinfos["Connectable"]
            ):
                continue

            scnd_conn_choices = [
                label
                for label, conn in current_pattern.connectors.items()
                if first_connector.assess_valid_counterpart(conn)
                and conn not in visited_connectors
                and conn != first_connector
            ]
            if scnd_conn_choices:
                scnd_connector_key = random.choice(scnd_conn_choices)
                scnd_connector = current_pattern.connectors[scnd_connector_key]
                return InternalConnectionStep(
                    own_connector=first_connector,
                    next_connector=scnd_connector,
                )

        return None

    def set_p_connect_internal(self, p_connect_internal: float) -> None:
        """
        Sets the internal connection probability. Raises ValueError if the
        probability is out of the bounds [0,1].

        Parameters
        ----------
        p_connect_internal : float
            The new probability of internal connection, between 0 and 1 (incl).

        Raises
        ------
        ValueError
            If `p_connect_internal` is not within the range [0, 1].
        """
        if not 0 <= p_connect_internal <= 1:
            msg = "Parameter p_connect_internal needs to be between 0 and 1."
            raise ValueError(msg)
        self.p_connect_internal = p_connect_internal


class ReconstructionGeneratorFunction(GeneratorFunction):
    """Generator function that reconstructs a data point from a generation history object."""

    def __init__(
        self,
        distribution_range: dict[str, PatternDistribution],
        generation_history: GenerationHistory | None = None,
    ) -> None:
        """Constructor for the reconstruction generator function.

        Parameters
        ----------
        distribution_range : dict[str, PatternDistribution]
            The range of possible PatternDistributions to sample from.
        """
        super().__init__(distribution_range)
        self.generation_history = generation_history
        self._current_step = 0

    def get_next_step(self, current_pattern: Pattern) -> GeneratorStep:
        """Implements the generator function to decide the next operation based on the history.

        The next step is determined by looking at the generation history and
        reconstructing the steps that were taken to generate the pattern.

        Parameters
        ----------
        current_pattern : Pattern
            Current state of the synthetic data point.

        Returns
        -------
        GeneratorStep
            The next step to be performed.

        Raises
        ------
        AttributeError
            If the generation history is not set.
        RuntimeError
            If an unexpected step sequence is encountered or if the history does not match the
            current state or the specified distribution range.
        """
        if self.generation_history is None:
            raise AttributeError("Generation history is not set.")
        if self._current_step == 0:
            raise RuntimeError("Initialization step not yet performed, step counter still at 0")

        # Get the last step from the generation history
        last_step = self.generation_history.history[self._current_step]
        sampled_distribution_name = last_step["sampled_distribution_name"]
        own_connector_label = last_step["own_connector"]
        next_pattern_label = last_step["next_pattern"]
        next_connector_label = last_step["next_connector"]

        # Create the appropriate step based on the last step type
        match last_step["generator_step_type"]:
            case "initialization":
                raise RuntimeError("Cannot encounter an initialization step after the first step.")
            case "add_pattern":
                # Retrieve the pattern
                try:
                    the_distribution = self.distribution_range[sampled_distribution_name]
                except KeyError as exc:
                    raise RuntimeError(
                        f"Unknown distribution name: {sampled_distribution_name}"
                    ) from exc
                try:
                    next_pattern = the_distribution.patterns[next_pattern_label]
                except KeyError as exc:
                    raise RuntimeError(f"Unknown pattern label: {next_pattern_label}") from exc
                # Retrieve the connectors
                try:
                    own_connector = current_pattern.connectors[own_connector_label]
                except KeyError as exc:
                    raise RuntimeError(
                        f"Unknown connector label in current_pattern: {own_connector_label}"
                    ) from exc
                try:
                    next_connector = next_pattern.connectors[next_connector_label]
                except KeyError as exc:
                    raise RuntimeError(
                        f"Unknown connector label in next_pattern: {next_connector_label}"
                    ) from exc
                the_step = AddPatternStep(
                    own_connector=own_connector,
                    next_pattern=next_pattern,
                    next_connector=next_connector,
                    sampled_distribution_name=sampled_distribution_name,
                )
            case "internal_connection":
                # Retrieve the connectors
                try:
                    own_connector = current_pattern.connectors[own_connector_label]
                except KeyError as exc:
                    raise RuntimeError(
                        f"Unknown connector label in current_pattern: {own_connector_label}"
                    ) from exc
                try:
                    next_connector = current_pattern.connectors[next_connector_label]
                except KeyError as exc:
                    raise RuntimeError(
                        f"Unknown connector label in current_pattern: {next_connector_label}"
                    ) from exc
                the_step = InternalConnectionStep(
                    own_connector=own_connector,
                    next_connector=next_connector,
                )
            case "termination":
                the_step = TerminationStep()
            case "capping":
                raise RuntimeError("Cannot encounter a capping step before Termination.")
            case _:
                raise ValueError(f"Unknown step type: {last_step['generator_step_type']}")

        # Increment the step counter and return the step
        self._current_step += 1
        return the_step

    def initialize_pattern(self) -> InitializationStep:
        """Initializes the P&ID generation with the pattern at the beginning of the history.

        Returns
        -------
        InitializationStep
            Initialization step containing the seed pattern and distribution name.
        """

        if self.generation_history is None:
            raise AttributeError("Generation history is not set.")
        if self._current_step > 0:
            msg = "Cannot get initialization step after the first step. Reset function first."
            raise RuntimeError(msg)

        # Get the first step from the generation history
        first_step = self.generation_history.history[0]
        # Create the initialization step
        try:
            the_distribution = self.distribution_range[first_step["sampled_distribution_name"]]
        except KeyError as exc:
            raise RuntimeError(
                f"Unknown distribution name: {first_step['sampled_distribution_name']}"
            ) from exc
        try:
            init_pattern = the_distribution.patterns[first_step["next_pattern"]]
        except KeyError as exc:
            raise RuntimeError(f"Unknown pattern label: {first_step['next_pattern']}") from exc
        # Create the initialization step
        the_step = InitializationStep(
            init_pattern=init_pattern,
            sampled_distribution_name=first_step["sampled_distribution_name"],
        )
        # Increment the step counter
        self._current_step += 1
        return the_step

    def set_generation_history(self, generation_history: GenerationHistory) -> None:
        """Set the generation history for the reconstruction generator function.

        Parameters
        ----------
        generation_history : GenerationHistory
            The generation history to set.
        """
        self.generation_history = generation_history
        self.reset()

    def reset(self) -> None:
        """Reset the generator function counter."""
        self._current_step = 0


class ReconstructionCappingFunction(CappingFunction):
    """Capping function for the reconstruction generator function.

    This class is used to cap the connectors of a pattern based on the generation history.
    It inherits from the CappingFunction class and overrides the _make_capping_steps method.

    Attributes
    ----------
    distribution_range: dict[str, PatternDistribution]|None
        The range of possible PatternDistributions to sample from. Can be None if not used.
    """

    def __init__(
        self,
        distribution_range: dict[str, PatternDistribution],
        generation_history: GenerationHistory | None = None,
    ) -> None:
        """Constructor for the reconstruction generator function.

        Parameters
        ----------
        distribution_range : dict[str, PatternDistribution]
            The range of possible PatternDistributions to sample from.
        """
        super().__init__(distribution_range)
        self.generation_history = generation_history

    def _make_capping_steps(self, current_pattern: Pattern) -> list[CappingStep]:
        """Generates capping steps for the given pattern based on the generation history.

        This method produces the CappingSteps for the given pattern. It is intended to be overridden
        by subclasses with more complex capping mechanisms. By default, it creates a default capping
        step for each connector (Without incorporating any further elements).

        Parameters
        ----------
        current_pattern : Pattern
            The current pattern to be capped.

        Returns
        -------
        list[GeneratorStep]
            A list of capping steps, one for each connector in the current pattern.
        """
        capping_steps = []
        for i in self.generation_history:
            if i["generator_step_type"] != "capping":
                pattern_distribution_name = i["sampled_distribution_name"]
                own_connector_label = i["own_connector"]
                next_pattern = i["next_pattern"]
                next_connector_label = i["next_connector"]

                # Case: Capping step involves a pattern incorporation
                if pattern_distribution_name is None:
                    if next_pattern is not None or next_connector_label is not None:
                        raise RuntimeError(
                            "Corrupt capping step encountered: next_pattern or "
                            "next_connector should be None if pattern_distribution_name is None."
                        )
                    else:
                        the_distribution = self.distribution_range[i["sampled_distribution_name"]]
                        try:
                            next_pattern = the_distribution.patterns[next_pattern]
                        except KeyError as exc:
                            raise RuntimeError(f"Unknown pattern label: {next_pattern}") from exc
                        try:
                            own_connector = current_pattern.connectors[own_connector_label]
                        except KeyError as exc:
                            raise RuntimeError(
                                f"Unknown connector label in current_pattern: {own_connector_label}"
                            ) from exc
                        try:
                            next_connector = next_pattern.connectors[next_connector_label]
                        except KeyError as exc:
                            raise RuntimeError(
                                f"Unknown connector label in next_pattern: {next_connector_label}"
                            ) from exc

                        the_step = CappingStep(
                            own_connector=own_connector,
                            next_pattern=next_pattern,
                            next_connector=next_connector,
                            sampled_distribution_name=pattern_distribution_name,
                        )

                # Case: Capping step only involves dropping the connector
                else:
                    try:
                        own_connector = current_pattern.connectors[own_connector_label]
                    except KeyError as exc:
                        raise RuntimeError(
                            f"Unknown connector label in current_pattern: {own_connector_label}"
                        ) from exc
                    the_step = CappingStep(
                        own_connector=own_connector,
                    )
                # Append this connectors capping step
                capping_steps.append(the_step)

        # Check if all connectors have been assigned a capping step
        if len(capping_steps) != len(current_pattern.connectors):
            raise RuntimeError("Not all connectors have a capping step in the history.")

        return capping_steps

    def set_generation_history(self, generation_history: GenerationHistory) -> None:
        """Set the generation history for the reconstruction capping function.

        Parameters
        ----------
        generation_history : GenerationHistory
            The generation history to set.
        """
        self.generation_history = generation_history
