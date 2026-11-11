"""Validation rule for PipingNetworkSegment reference integrity."""

from pydexpi.pydexpi_classes.plant.piping import PipingNetworkSegment
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._reference_nodes_and_items_match import (
    create_reference_validation_issue,
    validate_reference_node_and_item,
)


class SegmentReferenceNodesAndItemsMatch:
    """Validate that source and target nodes of segment are in source and target items.

    Ensures that when a PipingNetworkSegment references source/target nodes, those nodes
    actually belong to the referenced source/target items.
    """

    id = "pydexpi_segment_reference_nodes_and_items_match"
    name = "Segment reference nodes and items match"
    description = "Validates that source/target nodes of PipingNetworkSegment belong to referenced source/target items"
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = "DEXPI 2.0.1 Specification"
    applies_to = PipingNetworkSegment
    scope = RuleScope.OBJECT

    def validate(self, segment: PipingNetworkSegment) -> list[ValidationIssue]:
        """Evaluate rule against given PipingNetworkSegment.

        Parameters
        ----------
        segment : PipingNetworkSegment
            Segment to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []

        # Validate source references
        source_error = validate_reference_node_and_item(segment, is_source=True)
        if source_error:
            issues.append(
                create_reference_validation_issue(
                    obj=segment,
                    error_type=source_error,
                    is_source=True,
                    rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                )
            )

        # Validate target references
        target_error = validate_reference_node_and_item(segment, is_source=False)
        if target_error:
            issues.append(
                create_reference_validation_issue(
                    obj=segment,
                    error_type=target_error,
                    is_source=False,
                    rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                )
            )

        return issues
