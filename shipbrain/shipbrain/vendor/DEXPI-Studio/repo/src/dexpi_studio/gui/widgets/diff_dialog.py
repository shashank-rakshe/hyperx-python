"""Non-modal dialog for displaying DEXPI model diff results."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

from pydexpi import attribute_label
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QLabel,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
)

from dexpi_studio.core.selection import format_value

if TYPE_CHECKING:
    from pydexpi.diff import DiffResult


class DiffDialog(QDialog):
    """Shows the structured result of comparing two DEXPI models."""

    def __init__(self, result: DiffResult, filename: str, parent=None) -> None:
        super().__init__(parent, Qt.WindowType.Window)
        self.setWindowTitle(f"Diff Results: {filename}")
        self.setMinimumSize(560, 420)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)

        layout = QVBoxLayout(self)
        layout.setSpacing(8)

        if not result.has_changes:
            layout.addWidget(QLabel("No differences found between the two models."))
        else:
            summary = QLabel(
                f"<b>{len(result.added_objects)}</b> added, "
                f"<b>{len(result.removed_objects)}</b> removed, "
                f"<b>{len(result.modified_objects)}</b> modified, "
                f"<b>{len(result.moved_objects)}</b> moved"
            )
            summary.setTextFormat(Qt.TextFormat.RichText)
            layout.addWidget(summary)

            tree = QTreeWidget()
            tree.setHeaderLabels(["Object", "Detail"])
            tree.setColumnWidth(0, 380)
            tree.setAlternatingRowColors(True)
            tree.setUniformRowHeights(True)

            _add_section(
                tree,
                f"Added ({len(result.added_objects)})",
                [(_label(obj), "") for obj in result.added_objects],
            )
            _add_section(
                tree,
                f"Removed ({len(result.removed_objects)})",
                [(_label(obj), "") for obj in result.removed_objects],
            )

            mod_section = QTreeWidgetItem([f"Modified ({len(result.modified_objects)})"])
            tree.addTopLevelItem(mod_section)
            for obj in result.modified_objects:
                obj_item = QTreeWidgetItem([_label(obj), ""])
                for change in obj.changes:
                    child = QTreeWidgetItem(
                        [attribute_label(change.attribute_name), _change_text(change)]
                    )
                    child.setToolTip(0, f"DEXPI attribute: {change.attribute_name}")
                    obj_item.addChild(child)
                mod_section.addChild(obj_item)
            mod_section.setExpanded(bool(result.modified_objects))

            _add_section(
                tree,
                f"Moved ({len(result.moved_objects)})",
                [
                    (
                        _label(obj),
                        (
                            f"{obj.old_parent_id}.{obj.old_container_attribute}"
                            f" → {obj.new_parent_id}.{obj.new_container_attribute}"
                        ),
                    )
                    for obj in result.moved_objects
                ],
            )

            tree.expandAll()
            layout.addWidget(tree)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.rejected.connect(self.close)
        layout.addWidget(buttons)


def _label(entry) -> str:  # type: ignore[no-untyped-def]
    """Name an entry as ``pydexpi diff`` does: class, tag and id."""
    tag = f" {entry.tag}" if entry.tag else ""
    object_id = getattr(entry, "object_id", None) or entry.object_id_2
    return f"{entry.object_type}{tag} ({object_id})"


def _change_text(change) -> str:  # type: ignore[no-untyped-def]
    """``old → new`` for one attribute change.

    A data value is shown as the properties panel shows it (``313 kW``). A reference or
    a reordered list is shown in pyDEXPI's wire form, which names objects by id: the id
    is what tells two references apart, where the live value would print a whole object.
    """
    if change.category == "data":
        return f"{format_value(change.old_value)} → {format_value(change.new_value)}"
    wire = change.model_dump(mode="json")
    return f"{_value(wire['old_value'])} → {_value(wire['new_value'])}"


def _value(value: object) -> str:
    """Render a wire-form value: text as written, anything else as JSON."""
    if value is None:
        return "—"
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def _add_section(
    tree: QTreeWidget,
    title: str,
    rows: list[tuple[str, str]],
) -> None:
    section = QTreeWidgetItem([title])
    tree.addTopLevelItem(section)
    for name, detail in rows:
        section.addChild(QTreeWidgetItem([name, detail]))
    section.setExpanded(bool(rows))
