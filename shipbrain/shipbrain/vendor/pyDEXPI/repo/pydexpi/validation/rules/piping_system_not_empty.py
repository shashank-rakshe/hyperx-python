"""Validation rule for PipingNetworkSystem content."""

from pydexpi.pydexpi_classes.pydexpi_classes import PipingNetworkSystem
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class PipingSystemNotEmpty:
    """Validate that a PipingNetworkSystem contains at least one segment.

    Ensures that a PipingNetworkSystem has at least one segment, as an empty system
    cannot represent any physical piping assets.
    """

    id = "pydexpi_piping_system_not_empty"
    name = "System not empty"
    description = (
        "Validates that the piping network system contains at least one segment. "
        "Otherwise, it cannot represent any physical piping assets."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = PipingNetworkSystem
    scope = RuleScope.OBJECT

    def validate(self, obj: PipingNetworkSystem) -> list[ValidationIssue]:
        """Evaluate rule against given PipingNetworkSystem.

        Parameters
        ----------
        obj : PipingNetworkSystem
            System to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.segments:
            short_desc = f"{get_display_name(obj)} has no segments"
            long_desc = (
                f"{get_display_name(obj)} does not contain any segments and therefore does "
                f"not represent any physical piping assets."
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
