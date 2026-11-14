"""Validation rule for PlantModel content."""

from pydexpi.pydexpi_classes.pydexpi_classes import PlantModel
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._conceptual_model_not_empty import (
    has_conceptual_model_content,
)


class PlantModelNotEmpty:
    """Validate that a PlantModel contains at least one plant component.

    Ensures that a PlantModel has at least one component in any of its compositional lists,
    as an empty plant model doesn't represent any physical plant assets.
    """

    id = "pydexpi_plant_model_not_empty"
    name = "PlantModel not empty"
    description = (
        "Validates that the plant model contains at least one component in any of its "
        "compositional lists (actuating systems, instrumentation, piping networks, plant items, "
        "etc.) or has base ConceptualModel content (metadata, notes, or roles). Otherwise, it "
        "doesn't represent any physical plant assets or engineering content."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = PlantModel
    scope = RuleScope.OBJECT

    def validate(self, obj: PlantModel) -> list[ValidationIssue]:
        """Evaluate rule against given PlantModel.

        Parameters
        ----------
        obj : PlantModel
            PlantModel to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        has_base_content = has_conceptual_model_content(obj)
        has_plant_content = (
            obj.actuatingElectricalSystems
            or obj.actuatingSystems
            or obj.instrumentationLoopFunctions
            or obj.measuringSystems
            or obj.pipingNetworkSystems
            or obj.plantStructureItems
            or obj.processInstrumentationFunctions
            or obj.taggedPlantItems
        )

        if not has_base_content and not has_plant_content:
            short_desc = f"{get_display_name(obj)} has no content"
            long_desc = (
                f"{get_display_name(obj)} does not contain any plant-specific components "
                f"(actuating systems, instrumentation, piping networks, plant items, etc.) "
                f"nor base ConceptualModel content (metadata, notes, or roles) and therefore "
                f"does not represent any physical plant assets or engineering content."
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
