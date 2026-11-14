"""Validation rule for ActuatingSystem content."""

from pydexpi.pydexpi_classes.pydexpi_classes import ActuatingSystem
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class ActuatingSystemNotEmpty:
    """Validate that an ActuatingSystem contains at least one component.

    Ensures that an ActuatingSystem has at least one of its compositional components
    (controlledActuator, operatedValveReference, or positioner), as an empty system
    cannot represent any physical actuating assets.
    """

    id = "pydexpi_actuating_system_not_empty"
    name = "ActuatingSystem not empty"
    description = (
        "Validates that the actuating system contains at least one component "
        "(controlledActuator, operatedValveReference, or positioner). "
        "Otherwise, it cannot represent any physical actuating assets."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = ActuatingSystem
    scope = RuleScope.OBJECT

    def validate(self, obj: ActuatingSystem) -> list[ValidationIssue]:
        """Evaluate rule against given ActuatingSystem.

        Parameters
        ----------
        obj : ActuatingSystem
            ActuatingSystem to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.controlledActuator and not obj.operatedValveReference and not obj.positioner:
            short_desc = f"{get_display_name(obj)} has no components"
            long_desc = (
                f"{get_display_name(obj)} does not contain any components "
                f"(controlledActuator, operatedValveReference, or positioner) and therefore does "
                f"not represent any physical actuating assets."
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
