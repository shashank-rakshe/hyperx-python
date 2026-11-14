"""Public API for pyDEXPI validation module.

Provides tools for validating pyDEXPI models against DEXPI information model rules. At the core,
validation is handled by the ValidationEngine class, which applies a set of ValidationRule objects
to pyDEXPI objects. For flexibility, ValidationRules are configured during engine initialization
and can be added or removed by key dynamically. Common, inbuilt validation configuration can be
obtained via the default_validator_factory function, which creates an engine with all inbuilt rules.

The validate function provides a convenient way to validate a pyDEXPI model using a lazy-initialized
default validation engine with all inbuilt rules.

Custom validation rules can be added by implementing additional ValidationRule classes, which
implement the validate method and specify the type of pyDEXPI object they apply to. These can be
registered with an existing ValidationEngine or passed during custom initialization.

Examples
--------
>>> from pydexpi.validation import validate
>>>
>>> issues = validate(my_pydexpi_model)
>>> for issue in issues:
...     print(f"{issue.level_of_recommendation}: {issue.short_description}")
...     print(f"  Details: {issue.long_description}")
...     print(f"  Affected: {issue.affected_component_ids}")

To validate only some objects -- after an edit, say -- use ``validate_objects``.
It runs the rules that can be evaluated from a single object and *names the ones
it could not run*, so a partial check is never mistaken for a clean model:

>>> from pydexpi.validation import validate_objects
>>> result = validate_objects([edited_valve, its_segment])
>>> result.issues
[]
>>> [rule.id for rule in result.unchecked_mandatory_rules]
['pydexpi_instrument_in_at_most_one_loop', 'pydexpi_model_composition_tree_unique',
 'pydexpi_model_references_in_composition_tree']
"""

from pydexpi.validation.default_validator import (
    default_validator_factory,
    validate,
    validate_objects,
)
from pydexpi.validation.engine import (
    LevelOfRecommendation,
    RuleRef,
    RuleScope,
    ScopedValidationResult,
    ValidationEngine,
    ValidationIssue,
    ValidationRule,
)

__all__ = [
    "LevelOfRecommendation",
    "RuleRef",
    "RuleScope",
    "ScopedValidationResult",
    "ValidationEngine",
    "ValidationIssue",
    "ValidationRule",
    "default_validator_factory",
    "validate",
    "validate_objects",
]
