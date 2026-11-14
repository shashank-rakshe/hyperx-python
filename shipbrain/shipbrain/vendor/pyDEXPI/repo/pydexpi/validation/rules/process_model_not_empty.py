"""Validation rule for ProcessModel content."""

from pydexpi.pydexpi_classes.pydexpi_classes import ProcessModel
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._conceptual_model_not_empty import (
    has_conceptual_model_content,
)


class ProcessModelNotEmpty:
    """Validate that a ProcessModel contains at least one process component.

    Ensures that a ProcessModel has at least one component in any of its compositional lists,
    as an empty process model doesn't represent any process information.
    """

    id = "pydexpi_process_model_not_empty"
    name = "ProcessModel not empty"
    description = (
        "Validates that the process model contains at least one component in any of its "
        "compositional lists (instrumentation activities, material components, material states, "
        "process connections, process steps, etc.) or has base ConceptualModel content (metadata, "
        "notes, or roles). Otherwise, it doesn't represent any process information or engineering "
        "content."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = None
    applies_to = ProcessModel
    scope = RuleScope.OBJECT

    def validate(self, obj: ProcessModel) -> list[ValidationIssue]:
        """Evaluate rule against given ProcessModel.

        Parameters
        ----------
        obj : ProcessModel
            ProcessModel to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        issues = []
        has_base_content = has_conceptual_model_content(obj)
        # DEXPI 2.0.1 removed ProcessModel.compositions and .materialStateTypes: a Composition
        # is owned by its MaterialStateType, and a MaterialStateType by its MaterialState.
        has_process_content = (
            obj.instrumentationSystemActivities
            or obj.listsOfMaterialComponents
            or obj.materialComponents
            or obj.materialStates
            or obj.materialTemplates
            or obj.processConnections
            or obj.processSteps
        )

        if not has_base_content and not has_process_content:
            short_desc = f"{get_display_name(obj)} has no content"
            long_desc = (
                f"{get_display_name(obj)} does not contain any process-specific components "
                f"(instrumentation activities, material components, material states, process "
                f"connections, process steps, etc.) nor base ConceptualModel content (metadata, "
                f"notes, or roles) and therefore does not represent any process information or "
                f"engineering content."
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
