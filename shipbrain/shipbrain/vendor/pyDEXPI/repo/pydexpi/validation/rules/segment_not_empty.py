"""Validation rule for PipingNetworkSegment content."""

from pydexpi.pydexpi_classes.plant.piping import PipingNetworkSegment
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class SegmentNotEmpty:
    """Validate that a PipingNetworkSegment contains at least one item or connection.

    Ensures that a PipingNetworkSegment has at least one item or connection, as an empty
    segment cannot represent any physical piping assets.
    """

    id = "pydexpi_segment_not_empty"
    name = "Segment not empty"
    description = (
        "Validates that the piping network segment contains at least one item or connection. "
        "Otherwise, it cannot represent any physical piping assets."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = PipingNetworkSegment
    scope = RuleScope.OBJECT

    def validate(self, obj: PipingNetworkSegment) -> list[ValidationIssue]:
        """Evaluate rule against given PipingNetworkSegment.

        Parameters
        ----------
        obj : PipingNetworkSegment
            Segment to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.items and not obj.connections:
            short_desc = f"{get_display_name(obj)} has no items or connections"
            long_desc = (
                f"{get_display_name(obj)} does not contain any items or connections and "
                f"therefore does not represent any physical piping assets."
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
