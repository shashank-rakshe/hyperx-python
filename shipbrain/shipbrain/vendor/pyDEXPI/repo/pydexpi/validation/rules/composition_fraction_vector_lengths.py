"""Validation rule: the fraction vectors of one composition hold the same number of values."""

from pydexpi.pydexpi_classes.pydexpi_classes import Composition
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.process_materials import (
    ONE_LENGTH,
    describe_lengths,
    fraction_lengths,
    lengths_disagree,
)
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class CompositionFractionVectorLengths:
    """Validate that a Composition's mass and mole fraction vectors are of one length.

    ``Composition.massFractions`` and ``.moleFractions`` list one value per component, "the
    order of items in the array ... determined by the list of chemical components ... in the
    corresponding MaterialTemplate" (DEXPI 2.0.1, Process.py L16-26). Both are read against
    that one list, so a composition whose vectors hold different numbers of values cannot be
    right whatever the list is: no template is needed to see it, and a state no stream pairs
    with a template is checked like any other. Every vector of either property counts, a
    property holding several included; a value that is no vector (``Undefined``) has no length.

    Whether the vectors are as long as the template's list is
    ``pydexpi_process_fraction_vector_length``, which needs the template; whether their values
    add up is ``pydexpi_composition_fractions``.

    RECOMMENDED: that the two vectors share a list follows from the specification's text, which
    states no multiplicity for it.

    Object-scoped: a composition's own vectors decide it.
    """

    id = "pydexpi_composition_fraction_vector_lengths"
    name = "Composition fraction vector lengths"
    description = (
        "Validates that every mass and mole fraction vector of one Composition holds the same "
        "number of values: both are read against the same list of components, one value per "
        "component."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "DEXPI 2.0.1 Composition: a vector's order is its template's component list "
        "(Process.py L16-26), which the vectors of one composition share"
    )
    applies_to = Composition
    scope = RuleScope.OBJECT

    def validate(self, obj: Composition) -> list[ValidationIssue]:
        """Evaluate rule against given Composition.

        Parameters
        ----------
        obj : Composition
            Composition to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue for a composition whose fraction vectors differ in length, naming each
            vector by its property and position, and none otherwise.
        """
        lengths = fraction_lengths(obj)
        if not lengths_disagree(lengths):
            return []
        owner = get_display_name(obj)
        vectors = [obj.__dict__[attribute][position].id for attribute, position, _count in lengths]
        return [
            ValidationIssue(
                short_description=f"{owner}: its fraction vectors differ in length",
                long_description=f"In {owner}, {describe_lengths(lengths)}. {ONE_LENGTH}",
                applied_rule_id=self.id,
                level_of_recommendation=self.level_of_recommendation,
                affected_component_ids=[obj.id, *vectors],
            )
        ]
