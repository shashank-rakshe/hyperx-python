"""Core validation engine for pyDEXPI models and objects."""

from collections.abc import Iterable
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol, TypeVar

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

T = TypeVar("T", bound=PyDexpiBaseModel)


class LevelOfRecommendation(StrEnum):
    """Level of recommendation to implement a rule.

    MANDATORY: Rule must be implemented for compliance with DEXPI specification.
    RECOMMENDED: Rule is recommended but not required for compliance. Violation could indicate a
                 potential semantic issue.
    OPTIONAL: Rule is optional. Violation does not indicate a violation or semantic issue, but
              could indicate additional best practices, alternatives, or information."""

    MANDATORY = "Mandatory"
    RECOMMENDED = "Recommended"
    OPTIONAL = "Optional"


class RuleScope(StrEnum):
    """Whether a rule can be evaluated from a single object alone.

    OBJECT: ``validate(obj)`` reads only ``obj`` and the objects it composes, so
            the rule is meaningful against an arbitrary subset of a model.
    MODEL:  ``validate(obj)`` needs the whole model -- it walks it, or builds a
            model-wide index -- so it is meaningless, and potentially wrong, on a
            subset. ``ModelReferencesInCompositionTree`` handed a single tank
            would report every reference leaving that tank as a missing object.
    """

    OBJECT = "object"
    MODEL = "model"


def rule_scope(rule: "ValidationRule") -> RuleScope:
    """The scope `rule` declares, defaulting to MODEL when it declares none.

    ``ValidationRule`` is a structural protocol and rules are plain classes, so
    rules written outside this repository cannot be required to carry a scope.
    They are read with ``getattr`` instead.

    The default is MODEL because a rule that has not declared its scope is a rule
    nobody has verified is object-local, and running it anyway would assert a
    property nobody checked. The two failure modes are not symmetric: defaulting
    to MODEL under-reports *visibly*, naming the rule in
    ``ScopedValidationResult.unchecked_rules`` until its author adds one line,
    whereas defaulting to OBJECT would mis-run the rule *silently* and feed the
    wrong answer into a caller's validity check.

    Raises
    ------
    ValueError
        If the rule declares a scope that is not a RuleScope. A typo would
        otherwise become a rule that is quietly never checked.
    """
    scope = getattr(rule, "scope", RuleScope.MODEL)
    try:
        return RuleScope(scope)
    except ValueError as exc:
        raise ValueError(
            f"Rule {rule.id!r} declares an unknown scope {scope!r}; "
            f"expected one of {[member.value for member in RuleScope]}."
        ) from exc


@dataclass
class ValidationIssue:
    """Represents an issue found during validation."""

    short_description: str
    long_description: str
    applied_rule_id: str
    level_of_recommendation: LevelOfRecommendation
    affected_component_ids: list[str]


@dataclass(frozen=True)
class RuleRef:
    """A rule named for reporting, without a live rule object.

    Plain data, so a result carrying it stays JSON-serializable through
    ``model_dump(mode="json")``.
    """

    id: str
    name: str
    level_of_recommendation: LevelOfRecommendation


@dataclass(frozen=True)
class ScopedValidationResult:
    """The outcome of validating a set of objects rather than a whole model.

    Deliberately **not** a ``list[ValidationIssue]``. A scoped run is a partial
    check, and a return type interchangeable with :meth:`ValidationEngine.validate`
    would let a caller substitute one for the other and silently discard the
    record of what was never checked -- which is the one thing this type exists
    to carry.

    Attributes
    ----------
    issues : list[ValidationIssue]
        Issues found by the rules that ran.
    checked_rules : tuple[RuleRef, ...]
        Every object-scoped rule in the engine. Included whether or not any
        object in scope matched its ``applies_to``: "applied to everything in
        scope" is the honest statement, and listing rules as "not applicable"
        would invite reading that as a defect.
    unchecked_rules : tuple[RuleRef, ...]
        Rules that did not run because they are not object-scoped. Their verdict
        is unknown for the whole model, including the objects in scope.
    validated_object_ids : tuple[str, ...]
        Exactly which objects were inspected. This is the second axis of
        incompleteness: a scoped result says nothing about any other object,
        even for a rule in ``checked_rules``.
    """

    issues: list[ValidationIssue]
    checked_rules: tuple[RuleRef, ...]
    unchecked_rules: tuple[RuleRef, ...]
    validated_object_ids: tuple[str, ...]

    @property
    def all_rules_checked(self) -> bool:
        """True when every rule in the engine was runnable in this mode.

        This says nothing about *coverage*. There is deliberately no
        ``is_complete`` here: a scoped result is never a complete validation of a
        model, so an engine carrying only object-scoped rules must not be able to
        report completeness after inspecting a single valve.
        """
        return not self.unchecked_rules

    @property
    def unchecked_mandatory_rules(self) -> tuple[RuleRef, ...]:
        """The unchecked rules that are MANDATORY -- the ones worth acting on."""
        return tuple(
            rule
            for rule in self.unchecked_rules
            if rule.level_of_recommendation is LevelOfRecommendation.MANDATORY
        )


class ValidationRule(Protocol[T]):
    """Protocol for validation rules.

    Impementations of this protocol should define a name for the rule, specify the type of pyDEXPI
    objects it applies to, and implement the validate method to perform the validation logic."""

    id: str
    name: str
    description: str
    level_of_recommendation: LevelOfRecommendation
    source: str | None
    applies_to: type[T]

    # `scope: RuleScope` is deliberately NOT a member here. It is optional at
    # runtime -- :func:`rule_scope` reads it with getattr and treats its absence
    # as MODEL -- and declaring it would make every rule written before it
    # existed fail static conformance for an attribute the engine does not
    # require. Rules *in this repository* must still declare one; AGENTS.md says
    # so and a test enforces it.

    def validate(self, obj: T) -> list[ValidationIssue]:
        """Validate the given object and return a list of validation issues.

        Parameters
        ----------
        obj : T
            The pyDEXPI object to validate.

        Returns
        -------
        list[ValidationIssue]
            A list of validation issues found during the validation process.
        """
        ...


def _rule_ref(rule: "ValidationRule") -> RuleRef:
    """Snapshot a rule as reportable data."""
    return RuleRef(id=rule.id, name=rule.name, level_of_recommendation=rule.level_of_recommendation)


class ValidationEngine:
    """Engine for validating pyDEXPI objects against a set of validation rules.

    Validates pyDEXPI models and objects against a set of validation rules passed during
    initialization. Organizes rules by the type of pyDEXPI objects they apply to, allowing for
    efficient validation.

    Attributes
    ----------
    rules : dict[str, ValidationRule]
        A dictionary of validation rules to apply during validation, keyed by rule ID.
    rules_by_type : dict[type[PyDexpiBaseModel], list[ValidationRule]]
        A dictionary mapping pyDEXPI object types to the validation rules that apply to them.
    object_scoped_rules_by_type : dict[type[PyDexpiBaseModel], list[ValidationRule]]
        The same mapping restricted to rules whose scope is ``RuleScope.OBJECT``. Kept as a
        second pre-expanded index rather than filtered per call, because the object-scoped path
        exists to be cheap and a per-object scope test would give that back.

    Not thread-safe. Rules are plain objects and may carry per-validation state on ``self``
    (none of the built-in ones does, but a caller's rule may), and the default
    engine is a process-wide singleton, so concurrent validation through one engine can
    interleave that state.
    """

    def __init__(self, rules: list[ValidationRule]) -> None:
        """Initialize the validation engine with a list of validation rules.

        Store rules as attribute and extract rules by type for efficient lookup during validation.
        Rules are stored in a dictionary keyed by their id attribute.

        Parameters
        ----------
        rules : list[ValidationRule]
            A list of validation rules to apply during validation.

        Raises
        ------
        ValueError
            If multiple rules have the same id.
        """
        # Build dictionary using rule.id as key
        self.rules: dict[str, ValidationRule] = {}
        for rule in rules:
            if rule.id in self.rules:
                raise ValueError(f"Duplicate rule id '{rule.id}' found.")
            self.rules[rule.id] = rule
        self._rebuild_indexes()

    def add_rule(self, rule: ValidationRule) -> None:
        """Add a new validation rule to the engine.

        Parameters
        ----------
        rule : ValidationRule
            The validation rule to add.

        Raises
        ------
        ValueError
            If a rule with the same id already exists.
        """
        if rule.id in self.rules:
            raise ValueError(f"Rule with id '{rule.id}' already exists in the engine.")
        rule_scope(rule)  # Reject an invalid scope before the engine is touched.
        self.rules[rule.id] = rule
        self._rebuild_indexes()

    def remove_rule(self, rule_id: str) -> None:
        """Remove a validation rule from the engine by its id.

        Parameters
        ----------
        rule_id : str
            The id of the validation rule to remove.

        Raises
        ------
        ValueError
            If no rule with the given id exists.
        """
        if rule_id not in self.rules:
            raise ValueError(f"Rule with id '{rule_id}' does not exist in the engine.")
        del self.rules[rule_id]
        self._rebuild_indexes()

    def _rebuild_indexes(self) -> None:
        """Rebuild both type indexes, so they can never disagree.

        Both go through ``_extract_rules_by_type``, which is what keeps the
        subclass pre-expansion identical between them. Do not replace the second
        one with a lazy filter over the first: the exact-type dict lookup with no
        per-object work is the whole value of the object-scoped path.

        Reading the scopes here means a rule declaring an invalid one fails when
        the engine is built, beside the duplicate-id check, rather than at
        validate time. Everything is computed before anything is assigned, so a
        rule that raises cannot leave one index describing a different rule set
        from another.
        """
        rules_by_type = self._extract_rules_by_type(self.rules)
        object_scoped = {
            rule_id: rule
            for rule_id, rule in self.rules.items()
            if rule_scope(rule) is RuleScope.OBJECT
        }
        object_scoped_rules_by_type = self._extract_rules_by_type(object_scoped)

        self.rules_by_type = rules_by_type
        self.object_scoped_rules_by_type = object_scoped_rules_by_type
        self._object_scoped_refs = tuple(_rule_ref(rule) for rule in object_scoped.values())
        self._not_object_scoped_refs = tuple(
            _rule_ref(rule) for rule_id, rule in self.rules.items() if rule_id not in object_scoped
        )

    def validate(self, model: PyDexpiBaseModel) -> list[ValidationIssue]:
        """Validate the given pyDEXPI object against all applicable validation rules.

        This method retrieves all objects in the compositional hierarchy of the given model. Then,
        for each object, it applies all validation rules that apply and collects any validation
        issues found. Finally, it returns a list of all validation issues.

        Parameters
        ----------
        model : PyDexpiBaseModel
            The pyDEXPI object to validate.

        Returns
        -------
        list[ValidationIssue]
            A list of validation issues found during the validation process.
        """
        return self._apply_rules(get_all_instances_in_model(model), self.rules_by_type)

    def validate_objects(self, objects: Iterable[PyDexpiBaseModel]) -> ScopedValidationResult:
        """Validate the given objects against the object-scoped rules only.

        Runs every rule whose scope is ``RuleScope.OBJECT`` and whose ``applies_to``
        matches an object in `objects`. Rules that are not object-scoped -- including
        any rule that does not declare a scope at all -- are not run and are reported
        in ``unchecked_rules`` rather than dropped.

        Each object is validated on its own; unlike :meth:`validate`, this does not
        descend into the objects they compose. Pass the children too if they matter.

        Takes objects rather than ids deliberately. Resolving ids would mean walking
        a model inside the one method whose value is being cheap, and would hide that
        cost from the call site. Callers holding only ids resolve them explicitly,
        with ``model_toolkit.get_instances_by_ids``.

        Not thread-safe; see the class docstring.

        Parameters
        ----------
        objects : Iterable[PyDexpiBaseModel]
            The objects to validate. Repeats are collapsed by identity.

        Returns
        -------
        ScopedValidationResult
            The issues found, plus the record of what was not checked.
        """
        # By identity, not hash: the caller's set is typically a union of two
        # overlapping id lists, and identity needs no assumption about __eq__.
        deduplicated = list({id(obj): obj for obj in objects}.values())
        return ScopedValidationResult(
            issues=self._apply_rules(deduplicated, self.object_scoped_rules_by_type),
            checked_rules=self._object_scoped_refs,
            unchecked_rules=self._not_object_scoped_refs,
            validated_object_ids=tuple(obj.id for obj in deduplicated),
        )

    @staticmethod
    def _apply_rules(
        objects: Iterable[PyDexpiBaseModel],
        rules_by_type: dict[type[PyDexpiBaseModel], list["ValidationRule"]],
    ) -> list[ValidationIssue]:
        """Run the rules indexed in `rules_by_type` over `objects`.

        The single dispatch site, shared by both entry points, so the two can
        never disagree about which rules apply to a type.
        """
        issues: list[ValidationIssue] = []
        for obj in objects:
            for rule in rules_by_type.get(type(obj), []):
                issues.extend(rule.validate(obj))
        return issues

    @staticmethod
    def _extract_rules_by_type(
        rules: dict[str, ValidationRule],
    ) -> dict[type[PyDexpiBaseModel], list[ValidationRule]]:
        """Organize rules by the type of pyDEXPI objects they apply to, accounting for inheritance."""
        # Use dict[rule_id, rule] during construction to prevent duplicates during propagation
        rules_by_type: dict[type[PyDexpiBaseModel], dict[str, ValidationRule]] = {}

        # Collect direct rules for each type
        for rule in rules.values():
            if rule.applies_to not in rules_by_type:
                rules_by_type[rule.applies_to] = {}
            rules_by_type[rule.applies_to][rule.id] = rule

        # Propagate base class rules to subclasses (dict prevents duplicates automatically)
        for base_type, base_rules in list(rules_by_type.items()):
            for subclass in ValidationEngine._get_all_subclasses(base_type):
                if subclass not in rules_by_type:
                    rules_by_type[subclass] = {}
                rules_by_type[subclass].update(base_rules)

        # Convert to dict[type, list[rule]]
        return {type_: list(rules_dict.values()) for type_, rules_dict in rules_by_type.items()}

    @staticmethod
    def _get_all_subclasses(parent_type: type[PyDexpiBaseModel]) -> set[type[PyDexpiBaseModel]]:
        """Recursively get all subclasses of a given class."""
        subclasses = set(parent_type.__subclasses__())
        for subclass in parent_type.__subclasses__():
            subclasses.update(ValidationEngine._get_all_subclasses(subclass))
        return subclasses
