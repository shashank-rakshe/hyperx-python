"""Element type string ↔ element class / dimension / order registry.

TensorMesh follows the meshio convention of tagging every cell block with an
*element type string* — ``"triangle"``, ``"hexahedron27"``, ``"wedge"``, … —
that encodes both the reference shape and the basis-node count. This module
exposes the lookup tables that translate those strings into the corresponding
:class:`~tensormesh.Element` subclass, spatial dimension, and polynomial order:

* :data:`element_types` — list of every recognized string.
* :data:`element_type2dimension` — string → spatial dimension (1, 2, or 3).
* :data:`element_type2order` — string → polynomial order.
* :func:`element_type2element` — string → :class:`~tensormesh.Element` subclass.
"""
import re
from typing import List, Type

from .element import (
    Element,
    Line,
    Triangle,
    Quadrilateral,
    Tetrahedron,
    Hexahedron,
    Prism,
    Pyramid,
)
from .element_type2dimension import element_type2dimension
from .element_type2order import element_type2order

__all__ = [
    "element_types",
    "element_type2dimension",
    "element_type2order",
    "element_type2element",
]

element_types: List[str] = list(element_type2dimension.keys())


def element_type2element(x: str) -> Type[Element]:
    """Resolve an element type string to its :class:`~tensormesh.Element` subclass.

    The alphabetic prefix of ``x`` determines the shape (``"triangle6"`` →
    :class:`~tensormesh.Triangle`, ``"hexahedron27"`` →
    :class:`~tensormesh.Hexahedron`, etc.); the trailing digits — which encode
    the basis-node count — are ignored here and instead consumed by
    :data:`element_type2order`.

    Parameters
    ----------
    x : str
        Element type string. Must start with one of the supported prefixes:
        ``"line"``, ``"triangle"``, ``"quad"``, ``"tetra"``, ``"hexahedron"``,
        ``"pyramid"``, or ``"wedge"``.

    Returns
    -------
    Type[Element]
        The :class:`~tensormesh.Element` subclass corresponding to ``x``.
    """
    element_prefix = re.findall(r'[a-zA-Z]+', x)[0]
    return {
        'line': Line,
        'triangle': Triangle,
        'quad': Quadrilateral,
        'tetra': Tetrahedron,
        'hexahedron': Hexahedron,
        'pyramid': Pyramid,
        'wedge': Prism,
    }[element_prefix]

