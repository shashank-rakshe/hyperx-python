"""Selected object/property extraction for the properties panel.

Extracts properties from a pyDEXPI model object for display in the GUI.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel


@dataclass
class PropertyItem:
    """A single property to display in the properties panel."""

    name: str
    value: str
    category: str = "general"
    is_list: bool = False
    list_count: int = 0
    #: What the panel shows for the name: pyDEXPI's ``attribute_label`` of an attribute
    #: ("Design heat flow rate"), or the name itself when empty.
    label: str = ""

    @property
    def display_name(self) -> str:
        return self.label or self.name


def extract_properties(obj: PyDexpiBaseModel) -> list[PropertyItem]:
    """Extract displayable properties from a pyDEXPI object.

    Uses pyDEXPI's Pydantic model introspection to gather all relevant
    attributes categorized by their type (data, composition, reference).

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The pyDEXPI model object to inspect.

    Returns
    -------
    list[PropertyItem]
        List of properties suitable for display.
    """
    if obj is None:
        return []

    properties: list[PropertyItem] = []

    # Basic identity
    type_name = type(obj).__name__
    properties.append(PropertyItem(name="Type", value=type_name, category="identity"))

    obj_id = getattr(obj, "id", None)
    if obj_id:
        properties.append(PropertyItem(name="ID", value=str(obj_id), category="identity"))

    tag_name = getattr(obj, "tagName", None)
    if tag_name:
        properties.append(PropertyItem(name="Tag Name", value=str(tag_name), category="identity"))

    # Data attributes from pyDEXPI categorization
    from pydexpi.toolkits.base_model_utils import (
        get_composition_attributes,
        get_data_attributes,
        get_reference_attributes,
    )

    try:
        data_attrs = get_data_attributes(obj)
        for name, value in data_attrs.items():
            if name in ("id", "tagName"):
                continue
            properties.append(_make_property(name, value, "data"))
    except Exception:
        pass

    try:
        ref_attrs = get_reference_attributes(obj)
        for name, value in ref_attrs.items():
            properties.append(_make_property(name, value, "reference"))
    except Exception:
        pass

    try:
        comp_attrs = get_composition_attributes(obj)
        for name, value in comp_attrs.items():
            properties.append(_make_property(name, value, "composition"))
    except Exception:
        pass

    return properties


def _make_property(name: str, value: object, category: str) -> PropertyItem:
    """Create a PropertyItem from a field name and value, labelled as pyDEXPI labels them."""
    from pydexpi import attribute_label

    label = attribute_label(name)
    if isinstance(value, list):
        return PropertyItem(
            name=name,
            value=f"{len(value)} item" + ("" if len(value) == 1 else "s"),
            category=category,
            is_list=True,
            list_count=len(value),
            label=label,
        )
    str_value = format_value(value)
    if len(str_value) > 200:
        str_value = str_value[:200] + "..."
    return PropertyItem(name=name, value=str_value, category=category, label=label)


def format_value(value: object) -> str:
    """Render one attribute value for a person, with pyDEXPI's labels.

    A quantity is its number and unit symbol (``313 kW``), an enumeration value its
    label (``Fail close``), a DEXPI object its display name (``Tank T4750``), a
    multi-language string its first text. Unset is ``—``.
    """
    from enum import Enum

    from pydexpi import enum_value_label, get_display_name
    from pydexpi.pydexpi_classes.pydexpi_classes import (
        MultiLanguageString,
        PhysicalQuantity,
        PyDexpiBaseModel,
        Undefined,
    )
    from pydexpi.toolkits.quantity_format import float_to_str, unit_symbol, value_with_symbol

    if value is None:
        return "—"
    if isinstance(value, Undefined):
        return "Undefined"
    if isinstance(value, PhysicalQuantity):
        number = float_to_str(value.value) if isinstance(value.value, float) else str(value.value)
        return value_with_symbol(number, unit_symbol(value.unit, qualify_pressure_reference=True))
    if isinstance(value, Enum):
        return enum_value_label(value)
    if isinstance(value, MultiLanguageString):
        texts = [s.value for s in value.singleLanguageStrings or [] if s.value]
        return texts[0] if texts else "—"
    if isinstance(value, PyDexpiBaseModel):
        return get_display_name(value)
    return str(value)
