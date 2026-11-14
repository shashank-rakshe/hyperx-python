"""Helper functions for model validation rules."""

from pydexpi.pydexpi_classes.pydexpi_classes import ConceptualModel


def has_conceptual_model_content(obj: ConceptualModel) -> bool:
    """Check if ConceptualModel has base content (metadata, notes, or roles).

    Parameters
    ----------
    obj : ConceptualModel
        ConceptualModel to check.

    Returns
    -------
    bool
        True if model has metadata, notes, or roles.
    """
    return bool(obj.metaData or obj.notes or obj.roles)
