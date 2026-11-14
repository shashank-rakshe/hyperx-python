"""Which lists carry meaning in their order, as the diff reads them.

The definition lives in ``pydexpi.toolkits.list_order`` -- the serializers need it too, and must
not import the diff -- and is re-exported here under the names the diff has always used. Two
sources make a list ordered:

- the **specification** (``is_ordered`` on the generated field: the drawing's geometry and
  z-order, a vector's values, ``ListOfMaterialComponents.component``). ``id_diff`` always compares
  these by position: a reorder of a composition list is an
  ``AttributeChange(category="composition")``, of a reference list a ``"reference"`` change, and
  inside a data value a ``"data"`` change;
- **pyDEXPI's reading** (:data:`ORDERED_COMPOSITION`: a segment's flow order). Its reorders are
  reported only when asked (``track_order=True``), as before: most comparisons are about content.
"""

from __future__ import annotations

from pydexpi.toolkits.list_order import (
    ORDERED_BY_CONVENTION,
    is_convention_ordered,
    is_ordered,
    is_spec_ordered,
)

__all__ = [
    "ORDERED_COMPOSITION",
    "is_convention_ordered",
    "is_order_significant",
    "is_spec_ordered",
]

#: ``(class, composition attribute)`` pairs whose order pyDEXPI gives meaning beyond the
#: specification, matched with ``isinstance``: ``items`` and ``connections`` of a
#: ``PipingNetworkSegment`` (flow order). A ``Diagram``'s and a ``RepresentationGroup``'s
#: ``groups`` (z-order) were listed here until the DEXPI 2.0.1 metadata declared them ordered.
ORDERED_COMPOSITION = ORDERED_BY_CONVENTION

#: Whether reordering a list is a change: ordered by the specification or by pyDEXPI.
is_order_significant = is_ordered
