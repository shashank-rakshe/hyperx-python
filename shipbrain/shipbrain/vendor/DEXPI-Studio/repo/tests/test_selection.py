"""Tests for selected object property extraction."""

from pathlib import Path

import pytest

from dexpi_studio.core.selection import PropertyItem, extract_properties

_REFERENCE_PID = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture
def sample_model():
    """Load the reference DEXPI model for testing."""
    from pydexpi import load_xml_file

    return load_xml_file(_REFERENCE_PID)


def test_extract_properties_none():
    """extract_properties(None) should return empty list."""
    result = extract_properties(None)
    assert result == []


def test_extract_properties_returns_list(sample_model):
    """extract_properties should return a list of PropertyItem."""
    props = extract_properties(sample_model)
    assert isinstance(props, list)
    assert all(isinstance(p, PropertyItem) for p in props)


def test_extract_properties_has_type(sample_model):
    """Properties should include the object type."""
    props = extract_properties(sample_model)
    type_props = [p for p in props if p.name == "Type"]
    assert len(type_props) == 1
    assert type_props[0].value == "EngineeringModel"


def test_extract_properties_equipment(sample_model):
    """Properties from equipment should have identity fields."""
    from pydexpi.pydexpi_classes import ProcessEquipment
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    equipment = get_all_instances_in_model(sample_model, (ProcessEquipment,))
    if not equipment:
        pytest.skip("No equipment in sample model")

    props = extract_properties(equipment[0])
    names = [p.name for p in props]
    assert "Type" in names


def test_property_item_fields():
    """PropertyItem should have expected fields."""
    prop = PropertyItem(name="test", value="val", category="data")
    assert prop.name == "test"
    assert prop.value == "val"
    assert prop.category == "data"
    assert prop.is_list is False
    assert prop.list_count == 0


def _first(model, class_name):
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    return next(o for o in get_all_instances_in_model(model) if type(o).__name__ == class_name)


def test_properties_are_labelled_and_formatted_as_pydexpi_labels_them(sample_model):
    """Names are pyDEXPI's attribute labels; a quantity shows its number and unit symbol."""
    props = {p.name: p for p in extract_properties(_first(sample_model, "PlateHeatExchanger"))}

    assert props["designHeatFlowRate"].display_name == "Design heat flow rate"
    assert props["designHeatFlowRate"].value == "313 kW"
    assert props["plateHeight"].value == "850 mm"
    assert props["nozzles"].value == "4 items"
    assert props["Type"].display_name == "Type", "identity rows keep their own names"


def test_a_referenced_object_is_shown_by_its_display_name(sample_model):
    from pydexpi import get_display_name

    function = _first(sample_model, "ProcessSignalGeneratingFunction")
    props = {p.name: p for p in extract_properties(function)}

    assert props["sensingLocation"].value == get_display_name(function.sensingLocation)


def test_format_value_of_unset_enum_and_undefined():
    from pydexpi import enum_value_label
    from pydexpi.pydexpi_classes.pydexpi_classes import FailActionClassification, Undefined

    from dexpi_studio.core.selection import format_value

    member = next(iter(FailActionClassification))
    assert format_value(None) == "—"
    assert format_value(Undefined()) == "Undefined"
    assert format_value(member) == enum_value_label(member)
