"""Collapsible DEXPI model tree widget."""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from PySide6.QtCore import QPoint, Qt, Signal
from PySide6.QtWidgets import (
    QApplication,
    QLineEdit,
    QMenu,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

if TYPE_CHECKING:
    from dexpi_studio.core.model_tree import TreeNode
    from dexpi_studio.gui.selection_model import SelectionModel

# Custom roles for storing node data
_OBJECT_ROLE = 1000
_OBJECT_ID_ROLE = 1001

_CAMEL_RE = re.compile(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")


def _human_type_name(type_name: str) -> str:
    """Convert a CamelCase DEXPI type name to a spaced human-readable form.

    Examples
    --------
    >>> _human_type_name("PipingNetworkSystem")
    'Piping Network System'
    >>> _human_type_name("PlantMetaData")
    'Plant Meta Data'
    """
    return _CAMEL_RE.sub(" ", type_name)


class ModelTreeWidget(QWidget):
    """Widget showing the DEXPI model structure as a collapsible tree."""

    item_selected = Signal(object)
    # Emitted when the user picks "Highlight & Zoom In" from the context menu.
    focus_requested = Signal(str)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._selection_model: SelectionModel | None = None
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the tree widget and search filter."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        # Search/filter box
        self._filter_input = QLineEdit()
        self._filter_input.setPlaceholderText("Filter...")
        self._filter_input.textChanged.connect(self._on_filter_changed)
        layout.addWidget(self._filter_input)

        # Tree widget
        self._tree = QTreeWidget()
        self._tree.setHeaderHidden(True)
        self._tree.setColumnCount(1)
        self._tree.itemSelectionChanged.connect(self._on_selection_changed)
        self._tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self._tree.customContextMenuRequested.connect(self._on_context_menu)
        layout.addWidget(self._tree)

    def set_tree(self, root: TreeNode) -> None:
        """Populate the tree widget from a TreeNode hierarchy.

        Parameters
        ----------
        root : TreeNode
            The root of the model tree.
        """
        self._tree.clear()
        self._add_node(root, None)
        self._tree.expandToDepth(1)
        self._tree.resizeColumnToContents(0)

    def clear(self) -> None:
        """Clear the tree."""
        self._tree.clear()
        self._filter_input.clear()

    def _add_node(self, node: TreeNode, parent_item: QTreeWidgetItem | None) -> None:
        """Recursively add a TreeNode to the QTreeWidget."""
        if parent_item is None:
            item = QTreeWidgetItem(self._tree)
        else:
            item = QTreeWidgetItem(parent_item)

        # Set display text: prefer tag name, fall back to human-readable type name.
        # Never show raw UUIDs as the primary label.
        raw_type = node.type_name or ""
        if node.is_group:
            # An attribute, labelled by pyDEXPI, with its count: "Actuating systems (3)".
            item.setText(0, node.label)
            item.setToolTip(0, f"DEXPI attribute: {raw_type}")
            for child in node.children:
                self._add_node(child, item)
            return
        human_type = _human_type_name(raw_type) if raw_type else ""
        display = node.tag_name or human_type or node.label
        item.setText(0, display)

        # Tooltip: show human type, DEXPI class name, and ID.
        if node.object_id:
            tooltip_lines = []
            if raw_type:
                tooltip_lines.append(f"Type: {human_type} (DEXPI Name: {raw_type})")
            tooltip_lines.append(f"ID: {node.object_id}")
            item.setToolTip(0, "\n".join(tooltip_lines))
        elif raw_type and raw_type != human_type:
            item.setToolTip(0, f"Type: {human_type} (DEXPI Name: {raw_type})")
        item.setData(0, _OBJECT_ROLE, node.dexpi_object)
        item.setData(0, _OBJECT_ID_ROLE, node.object_id)

        # Recurse children
        for child in node.children:
            self._add_node(child, item)

    def _on_selection_changed(self) -> None:
        """Emit the selected dexpi object when tree selection changes."""
        items = self._tree.selectedItems()
        if items:
            obj = items[0].data(0, _OBJECT_ROLE)
            obj_id: str | None = items[0].data(0, _OBJECT_ID_ROLE)
            self.item_selected.emit(obj)
        else:
            obj_id = None
            self.item_selected.emit(None)
        if self._selection_model is not None:
            self._selection_model.select(obj_id)

    def set_selection_model(self, sel: SelectionModel) -> None:
        """Connect this tree to a shared SelectionModel.

        Parameters
        ----------
        sel : SelectionModel
            The shared selection model to synchronise with.
        """
        self._selection_model = sel
        sel.selection_changed.connect(self.select_by_id)

    def select_by_id(self, object_id: str | None) -> None:
        """Programmatically select the tree item whose object_id matches.

        Parameters
        ----------
        object_id : str | None
            The DEXPI object ID to select, or None to clear the selection.
        """
        if object_id is None:
            self._tree.clearSelection()
            return

        # Block our own signal to avoid re-entrancy
        self._tree.blockSignals(True)
        try:
            item = self._find_item_by_id(self._tree.invisibleRootItem(), object_id)
            if item is not None:
                self._tree.setCurrentItem(item)
                self._tree.scrollToItem(item)
        finally:
            self._tree.blockSignals(False)

    def _find_item_by_id(self, parent: QTreeWidgetItem, object_id: str) -> QTreeWidgetItem | None:
        """Recursively search for an item with the given object_id."""
        for i in range(parent.childCount()):
            child = parent.child(i)
            if child.data(0, _OBJECT_ID_ROLE) == object_id:
                return child
            found = self._find_item_by_id(child, object_id)
            if found is not None:
                return found
        return None

    def _on_context_menu(self, pos: QPoint) -> None:
        """Show a context menu for the item under the cursor."""
        item = self._tree.itemAt(pos)
        if item is None:
            return
        obj_id: str | None = item.data(0, _OBJECT_ID_ROLE)
        if obj_id is None:
            return

        menu = QMenu(self)
        action_focus = menu.addAction("🔍  Highlight && Zoom In")
        action_copy_id = menu.addAction("📋  Copy ID")
        chosen = menu.exec(self._tree.viewport().mapToGlobal(pos))
        if chosen is action_focus:
            self.focus_requested.emit(obj_id)
        elif chosen is action_copy_id:
            QApplication.clipboard().setText(obj_id)

    def _on_filter_changed(self, text: str) -> None:
        """Filter tree items based on search text."""
        self._filter_items(self._tree.invisibleRootItem(), text.lower())

    def _filter_items(self, item: QTreeWidgetItem, text: str) -> bool:
        """Recursively filter tree items. Returns True if item or children match."""
        if not text:
            item.setHidden(False)
            for i in range(item.childCount()):
                self._filter_items(item.child(i), text)
            return True

        # Check if this item matches
        item_text = item.text(0).lower()
        matches = text in item_text

        # Check children
        any_child_matches = False
        for i in range(item.childCount()):
            child_matches = self._filter_items(item.child(i), text)
            any_child_matches = any_child_matches or child_matches

        visible = matches or any_child_matches
        item.setHidden(not visible)

        if any_child_matches:
            item.setExpanded(True)

        return visible
