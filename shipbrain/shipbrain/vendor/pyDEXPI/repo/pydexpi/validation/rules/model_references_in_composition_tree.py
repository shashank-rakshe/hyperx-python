"""Validation rule ensuring referenced objects are present in the composition tree."""

from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, PyDexpiBaseModel
from pydexpi.toolkits import base_model_utils, model_toolkit
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class ModelReferencesInCompositionTree:
    """Validate that all referenced objects are present in the composition tree."""

    id = "pydexpi_model_references_in_composition_tree"
    name = "Model references in composition tree"
    description = (
        "Validates that every object referenced from the model is present in the composition tree."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = None
    applies_to = EngineeringModel
    # MODEL, explicitly rather than by default: this builds a model-wide
    # set of instances to test references against. Handed one object it
    # would report every reference leaving that object as missing.
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
        all_instances = model_toolkit.get_all_instances_in_model(obj)
        missing_references = self._find_missing_references(all_instances)
        return self._make_issues_for_missing_references(missing_references)

    @staticmethod
    def _find_missing_references(instances: list[PyDexpiBaseModel]) -> list[PyDexpiBaseModel]:
        """Find referenced instances that are not present in the composition tree.

        Membership is by identity (``id()``): a reference resolves to *that* object, so a
        same-id copy held outside the tree is missing even if it compares equal. Each missing
        object is reported once, in the order it is first met.
        """
        instance_ids = {id(instance) for instance in instances}
        missing_references: dict[int, PyDexpiBaseModel] = {}
        for instance in instances:
            ref_attrs = base_model_utils.get_reference_attributes(instance)
            for ref_attr in ref_attrs.values():
                refs = ref_attr if isinstance(ref_attr, list) else [ref_attr]
                for ref in refs:
                    if isinstance(ref, PyDexpiBaseModel) and id(ref) not in instance_ids:
                        missing_references.setdefault(id(ref), ref)

        return list(missing_references.values())

    @classmethod
    def _make_issues_for_missing_references(
        cls,
        missing_references: list[PyDexpiBaseModel],
    ) -> list[ValidationIssue]:
        """Create validation issues for each missing reference."""
        issues = []
        for missing_ref in missing_references:
            short_desc = f"Missing reference found: {get_display_name(missing_ref)}"
            long_desc = (
                f"{get_display_name(missing_ref)} is referenced "
                f"but not present in the composition tree. All referenced objects should be "
                f"present in the composition tree."
            )
            issues.append(
                ValidationIssue(
                    short_description=short_desc,
                    long_description=long_desc,
                    applied_rule_id=cls.id,
                    level_of_recommendation=cls.level_of_recommendation,
                    affected_component_ids=[missing_ref.id],
                )
            )
        return issues
