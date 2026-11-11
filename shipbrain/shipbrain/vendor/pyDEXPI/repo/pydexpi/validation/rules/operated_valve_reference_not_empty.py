"""Validation rule for OperatedValveReference content."""

from pydexpi.pydexpi_classes.pydexpi_classes import OperatedValveReference
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class OperatedValveReferenceNotEmpty:
    """Validate that an OperatedValveReference has a valve reference.

    Ensures that an OperatedValveReference has a valve reference, as a reference without
    a target cannot represent the actual valve it is intended to reference.
    """

    id = "pydexpi_operated_valve_reference_not_empty"
    name = "OperatedValveReference not empty"
    description = (
        "Validates that the OperatedValveReference has a valve reference. "
        "Otherwise, it cannot represent the actual valve it is intended to reference."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = OperatedValveReference
    scope = RuleScope.OBJECT

    def validate(self, obj: OperatedValveReference) -> list[ValidationIssue]:
        """Evaluate rule against given OperatedValveReference.

        Parameters
        ----------
        obj : OperatedValveReference
            OperatedValveReference to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if obj.valve is None:
            short_desc = f"{get_display_name(obj)} has no valve reference"
            long_desc = (
                f"{get_display_name(obj)} does not have a valve reference and "
                f"therefore does not represent the actual valve it is intended to reference."
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
