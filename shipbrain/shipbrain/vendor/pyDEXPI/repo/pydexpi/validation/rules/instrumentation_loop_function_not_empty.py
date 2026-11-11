"""Validation rule for InstrumentationLoopFunction content."""

from pydexpi.pydexpi_classes.pydexpi_classes import InstrumentationLoopFunction
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class InstrumentationLoopFunctionNotEmpty:
    """Validate that an InstrumentationLoopFunction contains at least one ProcessInstrumentationFunction.

    Ensures that an InstrumentationLoopFunction has at least one ProcessInstrumentationFunction,
    as an empty loop function cannot represent any meaningful instrumentation logic.
    """

    id = "pydexpi_instrumentation_loop_function_not_empty"
    name = "InstrumentationLoopFunction not empty"
    description = (
        "Validates that the instrumentation loop function contains at least one "
        "ProcessInstrumentationFunction. Otherwise, it cannot represent any meaningful "
        "instrumentation logic."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = InstrumentationLoopFunction
    scope = RuleScope.OBJECT

    def validate(self, obj: InstrumentationLoopFunction) -> list[ValidationIssue]:
        """Evaluate rule against given InstrumentationLoopFunction.

        Parameters
        ----------
        obj : InstrumentationLoopFunction
            InstrumentationLoopFunction to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.processInstrumentationFunctions:
            short_desc = f"{get_display_name(obj)} has no ProcessInstrumentationFunctions"
            long_desc = (
                f"{get_display_name(obj)} does not contain any "
                f"ProcessInstrumentationFunctions and therefore does not represent any meaningful "
                f"instrumentation logic."
            )
            issues.append(
                ValidationIssue(
                    short_description=short_desc,
                    long_description=long_desc,
                    applied_rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                    affected_component_ids=[obj.id],
                )
            )
        return issues
