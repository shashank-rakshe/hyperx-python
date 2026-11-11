"""Versioning: models under version control.

``model_to_projection(model)`` renders a model as stable text for review in Git. See
``docs/mkdocs/versioning.md`` and ADR 0002.
"""

from pydexpi.versioning.projection import PROJECTION_FORMAT_VERSION, IdPolicy, model_to_projection

__all__ = [
    "PROJECTION_FORMAT_VERSION",
    "IdPolicy",
    "model_to_projection",
]
