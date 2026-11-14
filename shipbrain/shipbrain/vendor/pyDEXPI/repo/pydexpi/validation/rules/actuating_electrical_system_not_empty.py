"""Validation rule for ActuatingElectricalSystem content."""

from pydexpi.pydexpi_classes.pydexpi_classes import ActuatingElectricalSystem
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class ActuatingElectricalSystemNotEmpty:
    """Validate that an ActuatingElectricalSystem contains at least one component.

    Ensures that an ActuatingElectricalSystem has an electronicFrequencyConverter,
    as an empty system cannot represent any physical electrical actuating assets.
    """

    id = "pydexpi_actuating_electrical_system_not_empty"
    name = "ActuatingElectricalSystem not empty"
    description = (
        "Validates that the actuating electrical system contains an electronicFrequencyConverter. "
        "Otherwise, it cannot represent any physical electrical actuating assets."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = ActuatingElectricalSystem
    scope = RuleScope.OBJECT

    def validate(self, obj: ActuatingElectricalSystem) -> list[ValidationIssue]:
        """Evaluate rule against given ActuatingElectricalSystem.

        Parameters
        ----------
        obj : ActuatingElectricalSystem
            ActuatingElectricalSystem to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.electronicFrequencyConverter:
            short_desc = f"{get_display_name(obj)} has no electronicFrequencyConverter"
            long_desc = (
                f"{get_display_name(obj)} does not contain an "
                f"electronicFrequencyConverter and therefore does not represent any physical "
                f"electrical actuating assets."
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
