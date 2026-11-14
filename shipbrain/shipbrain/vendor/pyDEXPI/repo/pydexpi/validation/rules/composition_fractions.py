"""Validation rule: a composition's fractions are finite, in range, and sum to their full scale."""

from pydexpi.pydexpi_classes.pydexpi_classes import Composition
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.qualified_values import FRACTION_PROPERTIES, check_fractions
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class CompositionFractions:
    """Validate that each fraction vector of a Composition sums to its unit's full scale.

    ``Composition.massFractions`` and ``.moleFractions`` hold ``PhysicalQuantityVector`` s in a
    ``RatioUnit``. Read as fractions of one material, every value is a finite number in
    ``[0, full scale]`` and they sum to the full scale -- 1 for ``Fraction``, 100 for ``Percent``,
    1e3 / 1e6 / 1e9 for parts per thousand / million / billion -- within
    ``qualified_values.FRACTION_SUM_RTOL``. A vector that sums to *another* literal's full scale
    is reported with that literal named: the Tennessee Eastman export's fractions sum to 1 and
    are labelled ``Percent``. Nothing is normalised or relabelled.

    RECOMMENDED, not MANDATORY: the specification binds the property to the vector type and the
    unit enumeration, which ``pydexpi_qualified_value_binding`` checks; that the values sum to
    their full scale is physics, not a DEXPI statement. The check is
    ``qualified_values.check_fractions``; whether a
    vector has one value per component of its template is ``pydexpi_process_fraction_vector_length``.
    """

    id = "pydexpi_composition_fractions"
    name = "Composition fractions"
    description = (
        "Validates that every mass or mole fraction vector of a Composition holds finite values "
        "in [0, full scale] that sum to the full scale of its RatioUnit literal (1 for Fraction, "
        "100 for Percent, ...), within a relative tolerance of 1e-6. Vectors are never normalised."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "pyDEXPI convention: fractions of one material sum to their unit's full scale "
        "(pydexpi.toolkits.qualified_values)"
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
            One issue per fraction vector that is out of range or off its full scale.
        """
        issues: list[ValidationIssue] = []
        owner = get_display_name(obj)
        for _holder, attribute in FRACTION_PROPERTIES:
            for qualified_value in obj.__dict__.get(attribute) or []:
                value = qualified_value.__dict__.get("value")
                problems = check_fractions(value, label=f"{owner} {attribute}")
                if not problems:
                    continue
                issues.append(
                    ValidationIssue(
                        short_description=f"{owner}: {attribute} do not add up to their unit",
                        long_description=" ".join(problem.message for problem in problems),
                        applied_rule_id=self.id,
                        level_of_recommendation=self.level_of_recommendation,
                        affected_component_ids=[obj.id, qualified_value.id],
                    )
                )
        return issues
