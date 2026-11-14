"""Conversion of pyDEXPI model to tree data for the GUI.

This module builds a hierarchical tree structure from a loaded pyDEXPI
EngineeringModel, suitable for display in a collapsible tree widget.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel


@dataclass
class TreeNode:
    """A node in the model tree representation."""

    label: str
    type_name: str
    object_id: str | None = None
    tag_name: str | None = None
    dexpi_object: object | None = None
    children: list[TreeNode] = field(default_factory=list)
    #: A node grouping the objects of one composition attribute; ``type_name`` is the
    #: attribute and ``label`` its pyDEXPI label with the count.
    is_group: bool = False

    @property
    def display_text(self) -> str:
        """Text shown in the tree widget."""
        parts = [self.type_name]
        if self.tag_name:
            parts.append(f"[{self.tag_name}]")
        elif self.object_id:
            parts.append(f"({self.object_id})")
        if self.label and self.label != self.type_name:
            parts.append(f"- {self.label}")
        return " ".join(parts)


def build_model_tree(model: PyDexpiBaseModel) -> TreeNode:
    """Build a tree representation from a pyDEXPI EngineeringModel.

    Parameters
    ----------
    model : PyDexpiBaseModel
        The root model object (typically an EngineeringModel).

    Returns
    -------
    TreeNode
        Root node of the hierarchical tree.
    """
    from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel

    if isinstance(model, EngineeringModel):
        return _build_engineering_model_tree(model)
    return _build_generic_node(model)


def _build_engineering_model_tree(model) -> TreeNode:
    """Build tree specifically for EngineeringModel root."""

    root = TreeNode(
        label="Engineering Model",
        type_name="EngineeringModel",
        object_id=getattr(model, "id", None),
        dexpi_object=model,
    )

    # Conceptual model (plant model)
    if model.conceptualModel is not None:
        plant_node = _build_plant_model_tree(model.conceptualModel)
        root.children.append(plant_node)

    # Diagram
    if model.diagram is not None:
        diagram_node = TreeNode(
            label=getattr(model.diagram, "name", "Diagram") or "Diagram",
            type_name="Diagram",
            object_id=getattr(model.diagram, "id", None),
            dexpi_object=model.diagram,
        )
        root.children.append(diagram_node)

    # Shape catalogues
    if model.shapeCatalogues:
        for catalogue in model.shapeCatalogues:
            cat_node = TreeNode(
                label=getattr(catalogue, "name", "ShapeCatalogue") or "ShapeCatalogue",
                type_name="ShapeCatalogue",
                object_id=getattr(catalogue, "id", None),
                dexpi_object=catalogue,
            )
            root.children.append(cat_node)

    return root


def _build_plant_model_tree(plant_model) -> TreeNode:
    """Build tree for the PlantModel (conceptual model)."""
    from pydexpi.toolkits.base_model_utils import get_composition_attributes

    plant_node = TreeNode(
        label="Plant Model",
        type_name="PlantModel",
        object_id=getattr(plant_model, "id", None),
        dexpi_object=plant_model,
    )

    # Get composition attributes (child objects)
    comp_attrs = get_composition_attributes(plant_model)

    for attr_name, attr_value in comp_attrs.items():
        if attr_value is None:
            continue
        if isinstance(attr_value, list):
            if not attr_value:
                continue
            # Create a category node for the list
            category_node = _group_node(attr_name, len(attr_value))
            for item in attr_value:
                child = _build_generic_node(item)
                category_node.children.append(child)
            plant_node.children.append(category_node)
        else:
            child = _build_generic_node(attr_value)
            plant_node.children.append(child)

    return plant_node


def _group_node(attr_name: str, count: int) -> TreeNode:
    """The node grouping the *count* objects of composition attribute *attr_name*."""
    from pydexpi import attribute_label

    return TreeNode(
        label=f"{attribute_label(attr_name)} ({count})",
        type_name=attr_name,
        is_group=True,
    )


def _build_generic_node(obj: PyDexpiBaseModel, max_depth: int = 3) -> TreeNode:
    """Build a tree node from any pyDEXPI object.

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The pyDEXPI object.
    max_depth : int
        Maximum recursion depth to prevent infinite trees.

    Returns
    -------
    TreeNode
        The constructed tree node.
    """
    type_name = type(obj).__name__
    object_id = getattr(obj, "id", None)
    tag_name = getattr(obj, "tagName", None)
    label = tag_name or object_id or type_name

    node = TreeNode(
        label=label,
        type_name=type_name,
        object_id=object_id,
        tag_name=tag_name,
        dexpi_object=obj,
    )

    if max_depth <= 0:
        return node

    # Add children from composition attributes
    from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
    from pydexpi.toolkits.base_model_utils import get_composition_attributes

    try:
        comp_attrs = get_composition_attributes(obj)
    except Exception:
        return node

    for attr_name, attr_value in comp_attrs.items():
        if attr_value is None:
            continue
        if isinstance(attr_value, list):
            if not attr_value:
                continue
            # Only recurse into lists of PyDexpiBaseModel
            dexpi_items = [item for item in attr_value if isinstance(item, PyDexpiBaseModel)]
            if dexpi_items:
                category_node = _group_node(attr_name, len(dexpi_items))
                for item in dexpi_items:
                    child = _build_generic_node(item, max_depth=max_depth - 1)
                    category_node.children.append(child)
                node.children.append(category_node)
        elif isinstance(attr_value, PyDexpiBaseModel):
            child = _build_generic_node(attr_value, max_depth=max_depth - 1)
            node.children.append(child)

    return node
