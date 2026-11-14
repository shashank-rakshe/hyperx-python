"""Validation rule: an instrument is a member of at most one instrumentation loop."""

from pydexpi.pydexpi_classes.pydexpi_classes import (
    InstrumentationLoopFunction,
    PlantModel,
    ProcessInstrumentationFunction,
)
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class InstrumentInAtMostOneLoop:
    """Validate that no ProcessInstrumentationFunction is held by the loops more than once.

    DEXPI 2.0.1 gives ``InstrumentationLoopFunction.ProcessInstrumentationFunctions`` an
    opposite multiplicity of ``0..1``: an instrument belongs to at most one loop.

    **Memberships are counted, not loops.** One loop listing an instrument twice holds it twice,
    and is reported like two loops holding it: seen from the instrument, that loop is then there
    twice, which the upper bound of 1 does not admit. (The model declares every reference
    property non-unique, so nothing else in it rules a repeat out.) Counted by identity, as an
    instrument is one object: two distinct objects with equal fields are two instruments.

    **A loop is read once, however often it is composed.** A loop composed twice in the
    ``PlantModel`` lists its instruments no more often for it, and is
    ``pydexpi_model_composition_tree_unique``'s to report; reading it twice here would add a false
    "listed twice" for each of its members.

    One issue per instrument, however many loops hold it, naming the instrument and every loop
    holding it by display name, with their ids in ``affected_component_ids``. The fix it names is
    to keep the instrument in the one loop it belongs in, listed once, and to take it out of
    every other.

    Applies to the ``PlantModel``, the one object DEXPI composes loops in, so it reads every loop
    without a walk of its own. MODEL nevertheless: the bound is on the *instrument*, which is
    held from outside itself, and the edit that breaks it changes a loop's member list, never the
    ``PlantModel`` -- a scoped run over the objects an edit changed would not reach this rule, and
    reports it unchecked rather than checked, as for ``pydexpi_piping_node_single_connection``.
    """

    id = "pydexpi_instrument_in_at_most_one_loop"
    name = "Instrument in at most one loop"
    description = (
        "Validates that every ProcessInstrumentationFunction is a member of at most one "
        "InstrumentationLoopFunction, and is listed by it once."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = (
        "DEXPI 2.0.1, InstrumentationLoopFunction.ProcessInstrumentationFunctions: opposite "
        "multiplicity 0..1"
    )
    applies_to = PlantModel
    # MODEL, not OBJECT, although every loop is the PlantModel's own child: see the docstring.
    scope = RuleScope.MODEL

    def validate(self, obj: PlantModel) -> list[ValidationIssue]:
        """Evaluate rule against given PlantModel.

        Parameters
        ----------
        obj : PlantModel
            PlantModel whose instrumentation loops to check.

        Returns
        -------
        list[ValidationIssue]
            One issue per instrument held more than once, by several loops or by one.
        """
        # Keyed by identity, never `in`, which is pydantic's deep equality. Each loop once: one
        # composed twice is a duplicated object, not a loop listing its members twice.
        loops = {id(loop): loop for loop in obj.instrumentationLoopFunctions}
        held: dict[int, tuple[ProcessInstrumentationFunction, list]] = {}
        for loop in loops.values():
            for function in loop.processInstrumentationFunctions:
                held.setdefault(id(function), (function, []))[1].append(loop)
        return [
            self._issue(function, holders)
            for function, holders in held.values()
            if len(holders) > 1
        ]

    @classmethod
    def _issue(
        cls,
        function: ProcessInstrumentationFunction,
        holders: list[InstrumentationLoopFunction],
    ) -> ValidationIssue:
        # Each loop once, in the order it first holds the instrument, with how often it does.
        loops: dict[int, tuple[InstrumentationLoopFunction, int]] = {}
        for loop in holders:
            count = loops.get(id(loop), (loop, 0))[1]
            loops[id(loop)] = (loop, count + 1)
        instrument = get_display_name(function)
        if len(loops) == 1:
            ((loop, _count),) = loops.values()
            short = f"{instrument} is listed {_times(len(holders))} by {get_display_name(loop)}"
        else:
            short = f"{instrument} is a member of {len(loops)} instrumentation loops"
        listing = ", ".join(
            f"{_times(count)} by {get_display_name(loop)}" for loop, count in loops.values()
        )
        return ValidationIssue(
            short_description=short,
            long_description=(
                f"{instrument} is held {_times(len(holders))}: {listing}. An instrument belongs to "
                "at most one instrumentation loop, which lists it once. Keep it in the one "
                "loop it belongs to, listed once, and remove it from the others."
            ),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=[function.id, *(loop.id for loop, _count in loops.values())],
        )


def _times(count: int) -> str:
    """How often, in words: "once", "twice", "3 times"."""
    return {1: "once", 2: "twice"}.get(count, f"{count} times")
