"""Validation rule: a value fits the binding of the property that holds it."""

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel, QualifiedValue
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.qualified_values import BindingProblem, bindings_of_class, check_value
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class QualifiedValueBinding:
    """Validate that each quantity value has the shape and unit its property is bound to.

    DEXPI binds every property that holds ``QualifiedValue`` s to the kinds of value it admits
    (``PhysicalQuantity``, ``PhysicalQuantityVector``, a Double or an Integer, each with
    ``Undefined``) and, for a quantity, to a unit enumeration; it binds every data attribute typed
    ``PhysicalQuantity`` to a unit enumeration. pyDEXPI's ``QualifiedValue.value`` is the union of
    all of them (the ``QV-VALUE-UNION`` deviation), so the class cannot tell a vector where a
    scalar belongs, or a pressure where a length belongs; the binding, recorded on the owning
    field, can. This rule reports every value that does not fit it, through the shared validator
    ``pydexpi.toolkits.qualified_values``.

    MANDATORY: the binding is the specification's type for the property.

    **What it leaves to others.** A unit that is missing, or not a ``PhysicalQuantityUnit``
    literal at all, is not reported by this rule: pydantic rejects it when the value is built, and
    a lenient load reports it. (A rule for it was drafted as VAL-007 and closed unmerged; if one
    is added, the two must never report one defect.) Whether a fraction vector's values sum to
    their full scale is ``pydexpi_composition_fractions`` (RECOMMENDED): that is physics, not the
    specification's type. A missing ``QualifiedValue.value`` is a missing mandatory attribute, which
    ``pydexpi_mandatory_attribute_has_value`` reports.

    Applies to the object that owns the property, because a ``QualifiedValue`` does not know which
    property holds it. Object-scoped: it reads the object's own fields and the values it composes
    or references directly.
    """

    id = "pydexpi_qualified_value_binding"
    name = "Qualified value binding"
    description = (
        "Validates that every QualifiedValue held by a bound property, and every PhysicalQuantity "
        "data attribute, has a value shape and unit enumeration the property's binding admits. A "
        "missing or unrecognised unit is not reported by this rule (pydantic rejects it on "
        "construction, and a lenient load reports it), and fraction sums are left to "
        "pydexpi_composition_fractions."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = (
        "DEXPI 2.0.1 DataTypeBinding of each property (generated value_types / unit_type); "
        "missing or unrecognised units are not reported by this rule: pydantic rejects them on "
        "construction, and a lenient load reports them"
    )
    applies_to = PyDexpiBaseModel
    # OBJECT: the binding is on the object's own field, and the values are its own children (or,
    # for MeasuringProcessVariable.measuredVariableReference, the one object it references).
    scope = RuleScope.OBJECT

    def validate(self, obj: PyDexpiBaseModel) -> list[ValidationIssue]:
        """Evaluate rule against given object.

        Parameters
        ----------
        obj : PyDexpiBaseModel
            Any object; only one with bound properties can be reported.

        Returns
        -------
        list[ValidationIssue]
            One issue per value that does not fit its binding.
        """
        issues: list[ValidationIssue] = []
        for binding in bindings_of_class(type(obj)):
            held = obj.__dict__.get(binding.attribute)
            values = held if isinstance(held, list) else [held]
            for value in values:
                if value is None:
                    continue
                problems = check_value(obj, binding.attribute, value, fractions=False)
                if problems:
                    issues.append(self._issue(obj, binding.attribute, value, problems))
        return issues

    @classmethod
    def _issue(
        cls,
        obj: PyDexpiBaseModel,
        attribute: str,
        value: object,
        problems: list[BindingProblem],
    ) -> ValidationIssue:
        owner = get_display_name(obj)
        affected = [obj.id]
        if isinstance(value, QualifiedValue):
            affected.append(value.id)
        what = "its unit" if all(p.kind == "unit" for p in problems) else "its value"
        return ValidationIssue(
            short_description=f"{owner}: {attribute} does not fit its binding ({what})",
            long_description=f"{owner}: " + " ".join(problem.message for problem in problems),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=affected,
        )
