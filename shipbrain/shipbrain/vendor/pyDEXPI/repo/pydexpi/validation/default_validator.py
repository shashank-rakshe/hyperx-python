"""Factory function for creating default validation engine with all inbuilt rules."""

from collections.abc import Iterable

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.validation import rules
from pydexpi.validation.engine import (
    ScopedValidationResult,
    ValidationEngine,
    ValidationIssue,
    ValidationRule,
)

# Dynamically instantiate inbuilt rule classes for default validator
INBUILT_RULES = [
    getattr(rules, rule_class_name)() for rule_class_name in rules.INBUILT_RULE_CLASSES
]


def default_validator_factory(
    additional_rules: list[ValidationRule] | None = None,
) -> ValidationEngine:
    """Create validation engine with all inbuilt validation rules.

    Parameters
    ----------
    additional_rules : list[ValidationRule] | None, optional
        Additional validation rules to include in the engine besides inbuilt rules.
        Default is None (no additional rules).

    Returns
    -------
    ValidationEngine
        Engine configured with all inbuilt validation rules.

    Raises
    ------
    ValueError
        If any additional rule ids conflict with inbuilt rule ids.
    """
    rule_instances = INBUILT_RULES.copy()
    if additional_rules:
        inbuilt_ids = {rule.id for rule in INBUILT_RULES}
        additional_ids = {rule.id for rule in additional_rules}
        if inbuilt_ids & additional_ids:
            conflicting = inbuilt_ids & additional_ids
            raise ValueError(
                f"Additional rules have ids that conflict with inbuilt rules: {conflicting}"
            )
        rule_instances.extend(additional_rules)
    return ValidationEngine(rules=rule_instances)


class _DefaultValidator:
    """Singleton holder for default validation engine instance."""

    _instance: ValidationEngine | None = None

    @classmethod
    def get_instance(cls) -> ValidationEngine:
        """Get singleton validation engine instance, lazy-initializing if needed.

        Returns
        -------
        ValidationEngine
            Singleton default validation engine.
        """
        if cls._instance is None:
            cls._instance = default_validator_factory()
        return cls._instance


def validate(model: PyDexpiBaseModel) -> list[ValidationIssue]:
    """Validate pyDEXPI model using default validation engine with all inbuilt rules.

    Lazy-initializes singleton engine on first call. Subsequent calls reuse same engine instance.

    Parameters
    ----------
    model : PyDexpiBaseModel
        PyDEXPI model to validate.

    Returns
    -------
    list[ValidationIssue]
        List of validation issues found.
    """
    return _DefaultValidator.get_instance().validate(model)


def validate_objects(objects: Iterable[PyDexpiBaseModel]) -> ScopedValidationResult:
    """Validate the given objects with the default validation engine.

    The object-scoped counterpart of :func:`validate`. It runs only the rules that
    can be evaluated from one object, and reports the rest in
    ``unchecked_rules`` -- for the default rule set those are
    ``pydexpi_model_composition_tree_unique``,
    ``pydexpi_model_references_in_composition_tree`` and
    ``pydexpi_instrument_in_at_most_one_loop``, all MANDATORY, and
    ``pydexpi_piping_node_single_connection`` and ``pydexpi_tee_nodes_connected``,
    RECOMMENDED, among others. A result
    from this function therefore never means "the model is fine"; it means "these
    rules found these issues on these objects".

    Lazy-initializes the singleton engine on first call, as :func:`validate` does,
    so the two share one engine and cannot disagree about which rules exist.

    Parameters
    ----------
    objects : Iterable[PyDexpiBaseModel]
        The objects to validate.

    Returns
    -------
    ScopedValidationResult
        The issues found, and the record of which rules did not run.
    """
    return _DefaultValidator.get_instance().validate_objects(objects)
