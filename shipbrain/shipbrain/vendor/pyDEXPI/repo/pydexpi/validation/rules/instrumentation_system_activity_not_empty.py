"""Validation rule: an instrumentation system of a process model holds an activity."""

from pydexpi.pydexpi_classes.pydexpi_classes import InstrumentationSystemActivity
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class InstrumentationSystemActivityNotEmpty:
    """Validate that an InstrumentationSystemActivity holds at least one InstrumentationActivity.

    DEXPI 2.0.1 defines an ``InstrumentationSystemActivity`` as "a collection of related
    InstrumentationActivity instances that together perform a specified function", and gives
    its ``InstrumentationActivities`` the multiplicity 1..* (``lower=1``,
    ``src/model/Process/Process/Process.py`` L399-402 at tag ``V2.0.1`` of
    https://gitlab.com/dexpi/Specification). The generated class holds them in a plain list,
    which cannot say so, and an empty one loads and saves without a word.

    MANDATORY: the specification states the multiplicity. Object-scoped: it reads the system's
    own list, which nothing but the system composes.

    A loaded document can hold one; adding an activity to it, or removing it, mends
    it. No corpus file has one: the CO2
    terminal's three systems hold 2, 1 and 1 activities, the synthetic 2.0.1 fixture's one.
    """

    id = "pydexpi_instrumentation_system_activity_not_empty"
    name = "InstrumentationSystemActivity not empty"
    description = (
        "Validates that an instrumentation system of a process model holds at least one "
        "instrumentation activity: DEXPI 2.0.1 gives InstrumentationSystemActivity."
        "InstrumentationActivities the multiplicity 1..*. An empty one is mended by adding an "
        "activity to it, or by removing it."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = (
        "DEXPI 2.0.1 InstrumentationSystemActivity.InstrumentationActivities, multiplicity 1..* "
        "(https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/"
        "Process.py L399-402)"
    )
    applies_to = InstrumentationSystemActivity
    # OBJECT: the bound is on what the system composes itself, and nothing else holds an activity.
    scope = RuleScope.OBJECT

    def validate(self, obj: InstrumentationSystemActivity) -> list[ValidationIssue]:
        """Evaluate rule against given InstrumentationSystemActivity.

        Parameters
        ----------
        obj : InstrumentationSystemActivity
            The instrumentation system to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue for a system that holds no activity, or none.
        """
        if obj.instrumentationActivities:
            return []
        owner = get_display_name(obj)
        return [
            ValidationIssue(
                short_description=f"{owner} holds no instrumentation activity",
                long_description=(
                    f"{owner} holds no InstrumentationActivity, and DEXPI requires an "
                    "instrumentation system to hold at least one (multiplicity 1..*): it is the "
                    "group of activities that together perform one function. Add an activity "
                    "to it, or remove the system."
                ),
                applied_rule_id=self.id,
                level_of_recommendation=self.level_of_recommendation,
                affected_component_ids=[obj.id],
            )
        ]
