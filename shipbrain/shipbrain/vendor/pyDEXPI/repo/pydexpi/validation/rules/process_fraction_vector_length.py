"""Validation rule: a fraction vector has one value per component of the template it is read against."""

from pydexpi.pydexpi_classes.pydexpi_classes import ProcessModel
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.process_materials import (
    fraction_vectors,
    reading_template,
    state_component_order,
)
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessFractionVectorLength:
    """Validate that every fraction vector of a material state is as long as its template's list.

    Value ``i`` of a ``Composition``'s ``massFractions`` or ``moleFractions`` belongs to component
    ``i`` of the template the state is read against (DEXPI 2.0.1, Process.py L16-26), so a vector
    of another length cannot be read at all. A state is read against a template through the
    streams referencing it (``process_materials.pairings_of_state``); a state no template is
    paired with has no determinable length and is not reported, and neither is one whose templates
    disagree, which ``pydexpi_process_shared_state_component_order`` reports. That the values sum
    to their unit's full scale is ``pydexpi_composition_fractions``.

    RECOMMENDED: the length follows from the specification's text, the pairing is pyDEXPI's
    reading.

    Model-scoped: the template a state is read against depends on the streams referencing it.
    """

    id = "pydexpi_process_fraction_vector_length"
    name = "Process fraction vector length"
    description = (
        "Validates that every fraction vector of a MaterialState holds one value per component of "
        "the MaterialTemplate the state is read against through the streams referencing it."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "DEXPI 2.0.1 Composition: a vector's order is its template's component list "
        "(Process.py L16-26); the pairing through streams is pyDEXPI's reading"
    )
    applies_to = ProcessModel
    scope = RuleScope.MODEL

    def validate(self, obj: ProcessModel) -> list[ValidationIssue]:
        """Evaluate rule against given ProcessModel.

        Parameters
        ----------
        obj : ProcessModel
            The process model to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue per fraction vector whose length differs from its template's component
            count.
        """
        issues: list[ValidationIssue] = []
        for state in obj.materialStates or []:
            ids, conflicts = state_component_order(obj, state)
            if ids is None or conflicts:
                continue
            template = reading_template(obj, state)
            for vector in fraction_vectors(state):
                if vector.length is None or vector.length == len(ids):
                    continue
                issues.append(
                    ValidationIssue(
                        short_description=(
                            f"{get_display_name(state)}: a fraction vector has {vector.length} "
                            f"values for {len(ids)} components"
                        ),
                        long_description=(
                            f"{vector.describe()} in {get_display_name(state)} has "
                            f"{vector.length} values, and the state is read against "
                            f"{referenced_object_name(template)}, which lists {len(ids)} "
                            "components. A fraction vector holds one value per component, in "
                            "the template's order."
                        ),
                        applied_rule_id=self.id,
                        level_of_recommendation=self.level_of_recommendation,
                        affected_component_ids=[
                            state.id,
                            vector.composition.id,
                            vector.qualified_value.id,
                        ],
                    )
                )
        return issues
