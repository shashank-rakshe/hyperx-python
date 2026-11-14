"""The one classification of a change as conceptual, graphics or document metadata.

A reviewer usually wants to see engineering changes apart from layout changes, and both apart from
the bookkeeping every save may touch (the modification date, the exporting tool). This module is the
single place that decides which is which, so the diff's ``has_*_changes`` helpers, its filters and
the Git projection's categories cannot disagree.

The classification is by **where an object lives** in the model, not by its class:

==========================================================  ============
Location                                                    Domain
==========================================================  ============
the ``EngineeringModel`` itself (export date, tool, ...)    metadata
anything under ``conceptualModel.metaData``                 metadata
anything under ``diagram`` or ``shapeCatalogues``           graphics
anything else under ``conceptualModel``                     conceptual
==========================================================  ============

Location rather than class, because the class is ambiguous: ``MetaData`` is defined in a diagram
module, so ``base_model_utils.is_graphics_type`` calls it graphics, although it is the document's
title block data and every save may stamp it. When no location is known -- an object compared
outside a whole model -- :func:`domain_of_class` falls back to the class.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Literal

from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, MetaData, PyDexpiBaseModel
from pydexpi.toolkits.base_model_utils import is_graphics_type

__all__ = ["CHANGE_DOMAINS", "ChangeDomain", "domain_of_class", "domain_of_location"]

ChangeDomain = Literal["conceptual", "graphics", "metadata"]
"""What a change concerns: the engineering content, the drawing, or document bookkeeping."""

#: Every domain, in the order reports list them.
CHANGE_DOMAINS: tuple[ChangeDomain, ...] = ("conceptual", "graphics", "metadata")

#: ``EngineeringModel`` attributes whose whole subtree is drawing.
_GRAPHICS_ROOT_ATTRIBUTES = frozenset({"diagram", "shapeCatalogues"})


def domain_of_location(
    root: PyDexpiBaseModel, path: Sequence[str], obj: PyDexpiBaseModel
) -> ChangeDomain:
    """Classify *obj* by where it lives below *root*.

    Parameters
    ----------
    root : PyDexpiBaseModel
        The root of the compared tree -- normally the ``EngineeringModel``.
    path : sequence of str
        The composition attribute names leading from *root* down to *obj*: ``()`` for the root
        itself, ``("conceptualModel", "taggedPlantItems")`` for a piece of equipment.
    obj : PyDexpiBaseModel
        The object classified, used when *root* is not an ``EngineeringModel``.

    Returns
    -------
    ChangeDomain
        The domain.
    """
    if not isinstance(root, EngineeringModel):
        return domain_of_class(obj)
    if not path:
        return "metadata"
    if path[0] in _GRAPHICS_ROOT_ATTRIBUTES:
        return "graphics"
    if path[0] == "conceptualModel" and len(path) > 1 and path[1] == "metaData":
        return "metadata"
    return "conceptual"


def domain_of_class(obj: PyDexpiBaseModel | type[PyDexpiBaseModel] | str) -> ChangeDomain:
    """Classify an object by its class alone, for when its location is unknown.

    Parameters
    ----------
    obj : PyDexpiBaseModel, type or str
        The object, its class, or its class name.

    Returns
    -------
    ChangeDomain
        ``"metadata"`` for ``EngineeringModel``, ``MetaData`` and their subclasses (such as
        ``PlantMetaData``), ``"graphics"`` for diagram classes, ``"conceptual"`` otherwise.
    """
    if isinstance(obj, str):
        cls = getattr(pydexpi_classes, obj, None)
        name = obj
    else:
        cls = obj if isinstance(obj, type) else type(obj)
        name = cls.__name__
    # issubclass, not a name check: PlantMetaData is a MetaData.
    if isinstance(cls, type) and issubclass(cls, (EngineeringModel, MetaData)):
        return "metadata"
    if is_graphics_type(name):
        return "graphics"
    return "conceptual"
