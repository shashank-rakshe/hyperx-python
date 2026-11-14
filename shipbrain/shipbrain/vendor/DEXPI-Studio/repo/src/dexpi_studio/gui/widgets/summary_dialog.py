"""Non-modal dialog showing a summary of the model: counts, then the tags."""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import (
    QAbstractItemView,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHeaderView,
    QLabel,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QVBoxLayout,
)

from dexpi_studio.core.pydexpi_adapter import model_summary_text, summary_counts


class SummaryDialog(QDialog):
    """Shows ``pydexpi info``'s summary: a form of counts and a sortable table of tags.

    Copy puts the same content on the clipboard as tab-separated text, which pastes
    into a spreadsheet as columns.
    """

    def __init__(self, summary, filename: str, parent=None) -> None:  # type: ignore[no-untyped-def]
        super().__init__(parent, Qt.WindowType.Window)
        self.setWindowTitle(f"Summary: {filename}")
        self.setMinimumSize(520, 560)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)

        layout = QVBoxLayout(self)
        counts = QFormLayout()
        counts.setLabelAlignment(Qt.AlignmentFlag.AlignLeft)
        for label, value in summary_counts(summary):
            value_label = QLabel(f"<b>{value}</b>")
            value_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            counts.addRow(f"{label}:", value_label)
        layout.addLayout(counts)

        tabs = QTabWidget()
        for title, entries in (
            ("Equipment", summary.equipment),
            ("Instruments", summary.instruments),
        ):
            tabs.addTab(_tag_table(entries), f"{title} ({len(entries)})")
        layout.addWidget(tabs, 1)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        copy = QPushButton("Copy")
        text = model_summary_text(summary)
        copy.clicked.connect(lambda: QGuiApplication.clipboard().setText(text))
        buttons.addButton(copy, QDialogButtonBox.ButtonRole.ActionRole)
        buttons.rejected.connect(self.close)
        layout.addWidget(buttons)


def _tag_table(entries) -> QTableWidget:  # type: ignore[no-untyped-def]
    """A read-only, sortable table of the entries' type and tag."""
    table = QTableWidget(len(entries), 2)
    table.setHorizontalHeaderLabels(["Type", "Tag"])
    table.verticalHeader().setVisible(False)
    table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
    table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
    table.setAlternatingRowColors(True)
    from pydexpi.toolkits.display_name import humanize_class_name

    for row, entry in enumerate(entries):
        type_item = QTableWidgetItem(humanize_class_name(entry.type))
        type_item.setToolTip(f"DEXPI class: {entry.type}")
        table.setItem(row, 0, type_item)
        table.setItem(row, 1, QTableWidgetItem(entry.tag or "—"))
    header = table.horizontalHeader()
    header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
    header.setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
    table.setSortingEnabled(True)
    return table
