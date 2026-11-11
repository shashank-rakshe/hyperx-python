"""Validation rule for MeasuringSystem content."""

from pydexpi.pydexpi_classes.pydexpi_classes import MeasuringSystem
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class MeasuringSystemNotEmpty:
    """Validate that a MeasuringSystem contains at least one component.

    Ensures that a MeasuringSystem has at least one of its compositional components
    (measuringElement, sensorwellReference, or transmitter), as an empty system
    cannot represent any measuring functionality.
    """

    id = "pydexpi_measuring_system_not_empty"
    name = "MeasuringSystem not empty"
    description = (
        "Validates that the measuring system contains at least one component "
        "(measuringElement, sensorwellReference, or transmitter). "
        "Otherwise, it cannot represent any measuring functionality."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = MeasuringSystem
    scope = RuleScope.OBJECT

    def validate(self, obj: MeasuringSystem) -> list[ValidationIssue]:
        """Evaluate rule against given MeasuringSystem.

        Parameters
        ----------
        obj : MeasuringSystem
            MeasuringSystem to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.measuringElement and not obj.sensorwellReference and not obj.transmitter:
            short_desc = f"{get_display_name(obj)} has no components"
            long_desc = (
                f"{get_display_name(obj)} does not contain any components "
                f"(measuringElement, sensorwellReference, or transmitter) and therefore does "
                f"not represent any measuring functionality."
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
