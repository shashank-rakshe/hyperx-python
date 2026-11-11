"""Validation rule: a material state that holds fraction vectors is read against a template."""

from pydexpi.pydexpi_classes.pydexpi_classes import MaterialState, ProcessModel
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.process_materials import (
    pairings_of_state,
    streams_referencing,
    unordered_fractions,
)
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name

#: How many streams or templates an issue names before it counts the rest.
_NAMED = 5


def _named(objects: list) -> str:
    names = [referenced_object_name(obj) for obj in objects[:_NAMED]]
    more = len(objects) - len(names)
    return ", ".join(names) + (f" and {more} more" if more else "")


class ProcessFractionsReadAgainstTemplate:
    """Validate that every material state holding fraction vectors is read against a template.

    Value ``i`` of a ``Composition``'s ``massFractions`` or ``moleFractions`` belongs to
    component ``i`` of "the list of chemical components ... in the corresponding
    MaterialTemplate" (DEXPI 2.0.1, Process.py L16-26). DEXPI gives a ``MaterialState`` no
    template of its own: the two correspond through a stream that references both
    (``process_materials.pairings_of_state``: the stream's template, and its ports'). So a
    state holding fraction vectors that no stream pairs with a template -- or only with
    templates that lack their list of components, as a lenient load can keep one -- holds
    values nothing in the document assigns to a component. The other two material rules have
    nothing to check it against, and say nothing.

    The document stores no record of the list a state's fractions were written against, so a
    state no stream pairs with a template could later be paired with a template of any order
    and read as one consistent pairing, every value against another component. This rule is
    what reports such a state while nothing orders its fractions, whether it was never paired
    or its pairing is gone: the two cannot be told apart.

    RECOMMENDED: the specification says a vector's order is its template's, and states no
    multiplicity that makes a state without one invalid; reading the pairing through the
    streams is pyDEXPI's.

    Model-scoped: whether a state is read against a template depends on the streams
    referencing it.
    """

    id = "pydexpi_process_fractions_read_against_template"
    name = "Process fractions read against a template"
    description = (
        "Validates that every MaterialState holding mass or mole fraction vectors is read "
        "against a MaterialTemplate with its list of components, through a Stream referencing "
        "both: otherwise nothing says which component each value belongs to."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "DEXPI 2.0.1 Composition: a vector's order is the corresponding MaterialTemplate's "
        "component list (Process.py L16-26); the pairing through streams and ports is "
        "pyDEXPI's reading"
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
            One issue per material state that holds fraction vectors and is read against no
            template with a list of components.
        """
        issues: list[ValidationIssue] = []
        for state in obj.materialStates or []:
            vectors = unordered_fractions(obj, state)
            if not vectors:
                continue
            count = len(vectors)
            issues.append(
                ValidationIssue(
                    short_description=(
                        f"{get_display_name(state)} holds fractions no template orders"
                    ),
                    long_description=(
                        f"{get_display_name(state)} holds {count} fraction "
                        f"vector{'' if count == 1 else 's'}, and {self._why(obj, state)}. "
                        "Value i of a fraction vector belongs to component i of the template "
                        "its state is read against, so nothing in the document says which "
                        "component each of these values belongs to: a template the state is "
                        "paired with later is taken to give their order, whatever order they "
                        "were written in."
                    ),
                    applied_rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                    affected_component_ids=list(
                        dict.fromkeys(
                            [state.id, *(vector.qualified_value.id for vector in vectors)]
                        )
                    ),
                )
            )
        return issues

    @staticmethod
    def _why(process_model: ProcessModel, state: MaterialState) -> str:
        """Why *state* is read against no list: no stream, no template, or no list."""
        streams = streams_referencing(process_model, state)
        if not streams:
            return "no stream references it"
        templates = list(
            {
                id(pairing.template): pairing.template
                for pairing in pairings_of_state(process_model, state)
            }.values()
        )
        if not templates:
            one = len(streams) == 1
            return (
                f"{_named(streams)} reference{'s' if one else ''} it and "
                f"name{'s' if one else ''} no template, and neither do "
                f"{'its' if one else 'their'} ports"
            )
        return (
            f"the template{'' if len(templates) == 1 else 's'} it is paired with, "
            f"{_named(templates)}, "
            f"{'has' if len(templates) == 1 else 'have'} no list of components"
        )
