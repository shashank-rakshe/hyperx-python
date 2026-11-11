"""This module contains the class for the SyntheticPIDGenerator, which
generates synthetic P&IDs.

For this, P&ID patterns as defined in pattern.py are connected via their
connector interfaces, with a logic predefined in a given generator function.
"""

import logging

from pydexpi.syndata.connector_renaming import ConnectorRenamingConvention
from pydexpi.syndata.generation_history import GenerationHistory
from pydexpi.syndata.generator_function import CappingFunction, GeneratorFunction
from pydexpi.syndata.pattern import Pattern

logger = logging.getLogger(__name__)


class SyntheticPIDGenerator:
    """The generator contains mechanisms to connect patterns to a larger pattern
    and collect them in pattern distributions.

    Attributes
    ----------
    _current_pattern: Pattern
        This attribute stores the (partially) generated P&ID as a pattern.
    generator_function: GeneratorFunction
        The generator function that defines the generation strategy to be
        applied by this generator.
    capping_function: CappingFunction
        The capping function that defines the capping strategy to be applied by this generator.
    renaming_convention: ConnectorRenamingConvention
        The renaming convention that renames connectors of new patterns that are included.
    max_steps: int
        The maximum number of steps to take before early termination.
    _generation_history: GenerationHistory
        The generation history of the generator, which stores the steps taken
        during the generation process.
    _current_step: int
        Attribute keeping track of the current step the generator is in.
    _termination_flag: bool
        Internal flag that can be used to invoke termination of the current
        generation process.
    """

    def __init__(
        self,
        generator_function: GeneratorFunction,
        capping_function: CappingFunction = None,
        renaming_convention: ConnectorRenamingConvention = None,
        max_steps=100,
    ) -> None:
        """Constructor of a synthetic P&ID generator

        Parameters
        ----------
        generator_function : GeneratorFunction
            The function that defines the generation logic to be followed
        capping_function : CappingFunction, optional
            The function that defines the capping logic to be followed, by default None
        renaming_convention : ConnectorRenamingConvention, optional
            The function that defines the renaming logic to be followed, by default None
        max_steps : int, optional
            The maximum amount of steps to be taken before terminating the generation,
            by default 100
        """
        self._current_pattern: Pattern = None
        self.generator_function = generator_function
        self.capping_function = capping_function
        self.renaming_convention = renaming_convention or ConnectorRenamingConvention()
        if max_steps <= 0:
            raise ValueError("max_steps must be a positive integer.")
        self.max_steps = max_steps
        self._generation_history = GenerationHistory()
        self._current_step = 0
        self._termination_flag = False

    def generate_pattern(self, new_pattern_label: str) -> Pattern:
        """Top-level function to create a random dexpi flowsheet.

        For this, a pattern is first initialized according to the initialization
        defined by the generator_function. Then, while no stopping criteria are
        reached, the _current_pattern is aggregated iteratively with the
        next_step() function. Finally, unconnected connectors are dropped by
        calling drop_connector() on all connectors of the pattern, and the
        generated pattern is returned. The _current_pattern is reset to None
        for the next call of generate_pattern().

        Parameters
        ----------
        new_pattern_label : str
            The label the new pattern should have.

        Returns
        -------
        Pattern:
            The generated pattern.

        Raises
        ------
        AttributeError:
            If the _current_pattern was already initialized before the call of
            this method.
        """
        if self.max_steps <= 0:
            return

        # First, reset the SyntheticPIDGenerator
        self.reset()

        # Use new interface to initialize the pattern
        init_step = self.generator_function.initialize_pattern()
        self._current_step += 1
        self._generation_history.write_step(init_step)
        self._current_pattern = init_step.get_pattern()

        # Rename the new pattern before proceeding
        self._current_pattern.change_label(new_pattern_label)

        # Generate pattern as long as no stopping criterion are reached
        while self.continue_loop():
            self.next_step()
            self._current_step += 1

        # Read the stopping criterion before capping: cap_connectors() consumes the open
        # connectors, so `_current_pattern.connectors` afterwards no longer reflects the
        # state the loop actually exited on.
        stop_reason = self._stop_reason()

        # Cap off connectors according to the capping function
        if self.capping_function is not None:
            self.cap_connectors()

        # Generation is long-running and opaque: the caller gets one Pattern back and no
        # indication of how it was reached or which criterion ended the run.
        logger.debug(
            "Generated pattern '%s' in %d step(s) (max_steps=%d, stopped_on=%s)",
            new_pattern_label,
            self._current_step,
            self.max_steps,
            stop_reason,
        )

        return self._current_pattern

    def _stop_reason(self) -> str:
        """Name the stopping criterion that ended the generation loop.

        `continue_loop` ands three separate criteria together, so a single boolean cannot
        say which one stopped the run -- reporting only `_termination_flag` would render
        "ran out of open connectors" and "hit max_steps" identically. The checks are
        evaluated here in the same order `continue_loop` short-circuits them, so the
        reason returned is the one that actually ended the loop when several hold at once.
        """
        if not self._current_pattern.connectors:
            return "no_open_connectors"
        if self._current_step >= self.max_steps:
            return "max_steps_reached"
        if self._termination_flag:
            return "termination_flag"
        # Unreachable while this mirrors continue_loop; named rather than silently
        # reported as one of the real criteria if the two ever drift apart.
        return "unknown"

    def next_step(self) -> None:
        """Adds a further pattern to the P&ID, or performs an internal
        connection, by querying the generator function for the next step.

        Raises
        ------
        AttributeError:
            If the _current_pattern is not yet initialized and therefore None.
        """
        if self._current_pattern is None:
            msg = "Pattern not yet initialized"
            raise AttributeError(msg)

        # Get next step from generator function
        step = self.generator_function.get_next_step(self._current_pattern)

        # Write step to the generation history (Do this before renaming to preserve the state
        # at which the step was created by the generator function (Shouldnt make a difference
        # atm, but may make a difference in the future))
        self._generation_history.write_step(step)

        # Apply renaming, execute step, and check termination status
        step.apply_renaming_convention(self.renaming_convention)
        step.execute_on(self._current_pattern)
        self._termination_flag = step.get_termination_status()
        logger.debug(
            "Step %d: %s (termination_flag=%s)",
            self._current_step,
            type(step).__name__,
            self._termination_flag,
        )

    def continue_loop(self) -> bool:
        """Checks stopping criteria for P&ID generation. Stops if no open
        connectors are available or the maximum number of generation steps is
        reached.

        Returns
        -------
        bool:
            True if none of the stopping criteria are reached, False otherwise.
        """
        return bool(
            self._current_pattern.connectors
            and self._current_step < self.max_steps
            and not self._termination_flag
        )

    def cap_connectors(self) -> None:
        """Cap the connectors of the current pattern using the capping function."""
        if self._current_pattern is None:
            msg = "Pattern not yet initialized"
            raise AttributeError(msg)

        capping_steps = self.capping_function.get_capping_steps(self._current_pattern)
        for step in capping_steps:
            self._generation_history.write_step(step)
            step.execute_on(self._current_pattern)

    def get_generation_history(self) -> GenerationHistory:
        """Get the generation history of the generator.

        Returns
        -------
        GenerationHistory:
            The generation history of the generator.
        """
        return self._generation_history

    def reset(self) -> None:
        """Reset the attributes pattern, step counter, and termination flag
        to prepare generator to generate a new pattern.
        """
        self._current_pattern = None
        self._termination_flag = False
        self._current_step = 0

        # Reset the renaming convention and make a new generation history
        self.renaming_convention.reset()
        self._generation_history = GenerationHistory()
