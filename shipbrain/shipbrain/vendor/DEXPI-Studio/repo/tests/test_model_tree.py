"""Tests for model tree data extraction."""

from pathlib import Path

import pytest

from dexpi_studio.core.model_tree import TreeNode, build_model_tree

_REFERENCE_PID = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture
def sample_model():
    """Load the reference DEXPI model for testing."""
    from pydexpi import load_xml_file

    return load_xml_file(_REFERENCE_PID)


def test_tree_node_display_text():
    """TreeNode.display_text should format correctly."""
    node = TreeNode(label="Test", type_name="Vessel", tag_name="V-101")
    assert "Vessel" in node.display_text
    assert "V-101" in node.display_text


def test_tree_node_display_text_no_tag():
    """TreeNode without tag shows ID."""
    node = TreeNode(label="Test", type_name="Pipe", object_id="pipe-001")
    assert "Pipe" in node.display_text
    assert "pipe-001" in node.display_text


def test_tree_node_display_text_minimal():
    """TreeNode with only type_name."""
    node = TreeNode(label="Vessel", type_name="Vessel")
    assert node.display_text == "Vessel"


def test_build_model_tree_returns_root(sample_model):
    """build_model_tree should return a TreeNode root."""
    tree = build_model_tree(sample_model)
    assert isinstance(tree, TreeNode)
    assert tree.type_name == "EngineeringModel"


def test_build_model_tree_has_children(sample_model):
    """The model tree should have at least one child node."""
    tree = build_model_tree(sample_model)
    assert len(tree.children) > 0


def test_build_model_tree_has_plant_model(sample_model):
    """The tree should contain a PlantModel node."""
    tree = build_model_tree(sample_model)
    type_names = [child.type_name for child in tree.children]
    assert "PlantModel" in type_names


def test_tree_nodes_have_dexpi_object(sample_model):
    """Root node should reference the original dexpi object."""
    tree = build_model_tree(sample_model)
    assert tree.dexpi_object is sample_model


def test_plant_model_node_has_plant_metadata_child(sample_model):
    """Plant Model node should have a PlantMetaData child (title block metadata)."""
    tree = build_model_tree(sample_model)
    plant_nodes = [c for c in tree.children if c.type_name == "PlantModel"]
    assert plant_nodes, "Expected a PlantModel node in the model tree"
    plant_node = plant_nodes[0]
    meta_children = [c for c in plant_node.children if c.type_name == "PlantMetaData"]
    assert meta_children, "Expected a PlantMetaData child under the PlantModel node"
    meta_node = meta_children[0]
    assert meta_node.object_id is not None, "PlantMetaData node should have an object_id"
    assert meta_node.dexpi_object is not None, "PlantMetaData node should reference the object"
    assert meta_node.label, "PlantMetaData node should have a non-empty label"


def test_group_nodes_carry_pydexpi_attribute_labels_and_counts(sample_model):
    from pydexpi import attribute_label

    tree = build_model_tree(sample_model)
    plant = next(child for child in tree.children if child.type_name == "PlantModel")
    groups = [child for child in plant.children if child.is_group]

    assert groups
    for group in groups:
        assert group.label == f"{attribute_label(group.type_name)} ({len(group.children)})"
    assert any(group.label.startswith("Tagged plant items (") for group in groups)
