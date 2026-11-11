"""Helper functions shared across validation rules."""

from enum import Enum

from pydexpi.pydexpi_classes.plant.piping import PipingConnection, PipingNetworkSegment
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ReferenceValidationError(Enum):
    """Error types for reference node and item validation."""

    NODE_WITHOUT_ITEM = "node_without_item"
    NODE_NOT_IN_ITEM = "node_not_in_item"


def validate_reference_node_and_item(
    obj: PipingConnection | PipingNetworkSegment,
    is_source: bool,
) -> ReferenceValidationError | None:
    """Validate that a reference node belongs to its reference item.

    This rule applies both to piping connections and piping network segments.

    Parameters
    ----------
    obj : PipingConnection | PipingNetworkSegment
        Object to validate.
    is_source : bool
        If True, validate source references; if False, validate target references.

    Returns
    -------
    ReferenceValidationError | None
        None if validation passes, or ReferenceValidationError enum if validation fails.
    """
    if is_source:
        node = obj.sourceNode
        item = obj.sourceItem
    else:
        node = obj.targetNode
        item = obj.targetItem

    if node and not item:
        return ReferenceValidationError.NODE_WITHOUT_ITEM
    elif item and node and node not in item.nodes:
        return ReferenceValidationError.NODE_NOT_IN_ITEM

    return None


def create_reference_validation_issue(
    obj: PipingConnection | PipingNetworkSegment,
    error_type: ReferenceValidationError,
    is_source: bool,
    rule_id: str,
    level_of_recommendation: LevelOfRecommendation,
) -> ValidationIssue:
    """Create a ValidationIssue for reference node and item validation errors.

    Parameters
    ----------
    obj : PipingConnection | PipingNetworkSegment
        Object that failed validation.
    error_type : ReferenceValidationError
        Type of validation error.
    is_source : bool
        If True, error is for source references; if False, for target references.
    rule_id : str
        ID of the validation rule.
    level_of_recommendation : LevelOfRecommendation
        Level of recommendation for the rule.

    Returns
    -------
    ValidationIssue
        Validation issue with appropriate description.
    """
    obj_name = get_display_name(obj)
    direction = "source" if is_source else "target"
    node = obj.sourceNode if is_source else obj.targetNode
    item = obj.sourceItem if is_source else obj.targetItem

    if error_type == ReferenceValidationError.NODE_WITHOUT_ITEM:
        short_desc = f"{obj_name} has {direction}Node but no {direction}Item"
        long_desc = (
            f"{obj_name} has {direction}Node {referenced_object_name(node)} but no {direction}Item "
            "reference."
        )
    else:  # NODE_NOT_IN_ITEM
        short_desc = f"{obj_name} {direction}Node not in {direction}Item"
        long_desc = (
            f"{obj_name} has {direction}Node {referenced_object_name(node)} "
            f"that is not in {direction}Item {referenced_object_name(item)}."
        )

    return ValidationIssue(
        short_description=short_desc,
        long_description=long_desc,
        applied_rule_id=rule_id,
        level_of_recommendation=level_of_recommendation,
        affected_component_ids=[obj.id],
    )
