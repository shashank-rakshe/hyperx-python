"""Validation rule for EngineeringModel content."""

from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class EngineeringModelNotEmpty:
    """Validate that an EngineeringModel contains at least a ConceptualModel or Diagram.

    Ensures that an EngineeringModel has at least a ConceptualModel or Diagram, as an empty
    engineering model cannot represent any engineering information.
    """

    id = "pydexpi_engineering_model_not_empty"
    name = "EngineeringModel not empty"
    description = (
        "Validates that the engineering model contains at least a ConceptualModel or Diagram. "
        "Otherwise, it cannot represent any engineering information."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = EngineeringModel
    scope = RuleScope.OBJECT

    def validate(self, obj: EngineeringModel) -> list[ValidationIssue]:
        """Evaluate rule against given EngineeringModel.

        Parameters
        ----------
        obj : EngineeringModel
            EngineeringModel to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        if not obj.conceptualModel and not obj.diagram:
            short_desc = f"{get_display_name(obj)} has no ConceptualModel or Diagram"
            long_desc = (
                f"{get_display_name(obj)} does not contain a ConceptualModel or Diagram and "
                f"therefore does not represent any engineering information."
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
