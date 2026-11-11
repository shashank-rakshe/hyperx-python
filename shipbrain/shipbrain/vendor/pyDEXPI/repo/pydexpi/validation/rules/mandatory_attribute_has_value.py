"""Validation rule: every mandatory attribute of an object holds a value."""

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits.base_model_utils import absent_required_attributes
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class MandatoryAttributeHasValue:
    """Validate that no mandatory (1..1) attribute of an object is left without a value.

    The generated classes mark the 1..1 attributes they know of as required fields (not yet all
    of them: see below), and validation refuses ``None`` for one: no required field admits
    it. Three things leave one holding ``None`` anyway, past validation. A ``strict=False`` load
    keeps an object whose document omits the attribute, and registers an error for it; both
    process examples omit ``Identifier`` on most objects that require it. Code that assigns
    past validation can write ``None`` to one without a report. And the XML
    loader keeps a label fragment whose ``Object`` does not resolve, even under ``strict=True``,
    leaving that ``AttributeRepresentation.object`` empty. A strict load of a document
    written from such an object drops the object.

    One issue per object, listing every attribute of it that is empty, so a process file reports
    one per object rather than one per attribute. The attributes are found by
    ``base_model_utils.absent_required_attributes``.

    MANDATORY: DEXPI states the multiplicity. Object-scoped: it reads the object's own fields.

    **What it leaves to others.** ``Undefined`` is a value -- DEXPI's statement that the value is
    knowingly unknown -- and is not reported. A required reference to an object the model does not
    hold is ``pydexpi_model_references_in_composition_tree``'s. The values a data type holds, a
    ``PhysicalQuantity``'s unit say, are not objects of the model and are not read here. And it
    sees what the generated classes mark required, which is not yet every 1..1: the twelve
    properties DEXPI declares ``Undefined | X`` with multiplicity 1..1 are optional fields,
    so one left out is not reported.
    """

    id = "pydexpi_mandatory_attribute_has_value"
    name = "Mandatory attribute has value"
    description = (
        "Validates that every attribute the generated classes mark required holds a value: each "
        "is mandatory in DEXPI (multiplicity 1..1), though not every 1..1 is marked yet -- the "
        "1..1 properties typed Undefined | X are not, and are not checked. A strict=False "
        "load leaves one absent where the document omits it; a strict load of a document "
        "written from such an object drops the object."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = (
        "DEXPI 2.0.1 multiplicity 1..1, for each attribute its generated class marks required; "
        "the 1..1 properties typed Undefined | X are optional fields, so unchecked"
    )
    applies_to = PyDexpiBaseModel
    # OBJECT: an attribute's value is the object's own, and the check reads nothing else.
    scope = RuleScope.OBJECT

    def validate(self, obj: PyDexpiBaseModel) -> list[ValidationIssue]:
        """Evaluate rule against given object.

        Parameters
        ----------
        obj : PyDexpiBaseModel
            Any object; only one with a mandatory attribute can be reported.

        Returns
        -------
        list[ValidationIssue]
            One issue naming every mandatory attribute of `obj` that holds no value, or none.
        """
        absent = absent_required_attributes(obj)
        if not absent:
            return []
        owner = get_display_name(obj)
        noun, verb = ("attribute", "has") if len(absent) == 1 else ("attributes", "have")
        listing = ", ".join(absent)
        return [
            ValidationIssue(
                short_description=f"{owner}: mandatory {noun} {listing} {verb} no value",
                long_description=(
                    f"{owner} holds no value for the mandatory {noun} {listing}, which DEXPI "
                    "requires (multiplicity 1..1). A strict load of a document written from it "
                    "drops the object; strict=False keeps it, reporting the omission."
                ),
                applied_rule_id=self.id,
                level_of_recommendation=self.level_of_recommendation,
                affected_component_ids=[obj.id],
            )
        ]
