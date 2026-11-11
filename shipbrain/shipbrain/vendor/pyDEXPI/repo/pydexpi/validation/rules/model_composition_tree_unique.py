"""Validation rule ensuring that every object in the model occurs once in the composition tree."""

from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, PyDexpiBaseModel
from pydexpi.toolkits import base_model_utils
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class ModelCompositionTreeUnique:
    """Validate that every object in the model occurs once in the composition tree.

    Ensures that every object in the model is found once and only once in the composition tree.
    Multiple occurrences lead to ambiguous model structure. An object is told by its id, as in a
    serialized document, so two distinct objects that share an id are reported as well.
    """

    id = "pydexpi_model_composition_tree_unique"
    name = "Model composition tree unique"
    description = (
        "Validates that every object in the model occurs exactly once in the composition tree. "
        "Multiple references to the same object can lead to ambiguity and inconsistencies."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = None
    applies_to = EngineeringModel
    # MODEL, explicitly rather than by default: this walks the whole
    # composition tree with one shared `seen` set, and 'appears twice in
    # the tree' is undefined for a single object.
    scope = RuleScope.MODEL

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

        duplicates = self._find_duplicates(obj, set(), {})

        # Make an issue for each duplicate found
        issues.extend(self._make_issues_for_duplicates(list(duplicates.values())))

        return issues

    @classmethod
    def _find_duplicates(
        cls,
        model: PyDexpiBaseModel,
        seen: set[str | int],
        duplicates: dict[str | int, PyDexpiBaseModel],
    ) -> dict[str | int, PyDexpiBaseModel]:
        """Find the ids reached more than once in the composition tree.

        Keyed on the DEXPI id, alone and not with the class, because an XML ``xs:ID`` is unique
        across the whole document: the same object composed twice and two distinct objects that
        share an id both write one id twice. An object without an id falls back to ``id()``.
        Never ``==``: pydantic's comparison is deep per lookup, and two distinct same-id objects
        compare unequal as soon as any field differs.
        """
        marker = getattr(model, "id", None) or id(model)
        if marker in seen:
            duplicates.setdefault(marker, model)
        else:
            seen.add(marker)

        # Recursively check all compositional attributes
        for attr_value in base_model_utils.get_composition_attributes(model).values():
            if isinstance(attr_value, PyDexpiBaseModel):
                cls._find_duplicates(attr_value, seen, duplicates)
            elif isinstance(attr_value, list):
                for item in attr_value:
                    if isinstance(item, PyDexpiBaseModel):
                        cls._find_duplicates(item, seen, duplicates)

        return duplicates

    @classmethod
    def _make_issues_for_duplicates(
        cls,
        duplicates: list[PyDexpiBaseModel],
    ) -> list[ValidationIssue]:
        """Create validation issues for each duplicate instance."""
        issues = []
        for duplicate in duplicates:
            short_desc = f"Duplicate instance found: {get_display_name(duplicate)}"
            long_desc = (
                f"{get_display_name(duplicate)} occurs multiple "
                f"times in the composition tree. Each object should occur exactly once."
            )
            issues.append(
                ValidationIssue(
                    short_description=short_desc,
                    long_description=long_desc,
                    applied_rule_id=cls.id,
                    level_of_recommendation=cls.level_of_recommendation,
                    affected_component_ids=[duplicate.id],
                )
            )
        return issues
