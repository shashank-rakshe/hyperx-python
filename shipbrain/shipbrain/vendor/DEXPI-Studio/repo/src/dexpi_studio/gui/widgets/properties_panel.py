"""Properties panel widget for displaying selected object properties."""

from __future__ import annotations

from typing import TYPE_CHECKING

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractScrollArea,
    QHeaderView,
    QLabel,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

if TYPE_CHECKING:
    from dexpi_studio.core.selection import PropertyItem


class PropertiesPanel(QWidget):
    """Widget showing properties of the currently selected DEXPI object."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the properties table."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        self._title_label = QLabel("No selection")
        self._title_label.setObjectName("PanelTitle")
        layout.addWidget(self._title_label)

        self._table = QTableWidget()
        self._table.setColumnCount(3)
        self._table.setHorizontalHeaderLabels(["Property", "Value", "Category"])
        header = self._table.horizontalHeader()
        header.setStretchLastSection(False)
        # A fixed, user-resizable name column: sized to its contents, a long attribute
        # name took the width the values need.
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Interactive)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self._table.setColumnWidth(0, 170)
        self._table.verticalHeader().setVisible(False)
        self._table.setAlternatingRowColors(True)
        self._table.setTextElideMode(Qt.TextElideMode.ElideRight)
        self._table.setWordWrap(False)
        self._table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self._table.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._table.setSizeAdjustPolicy(QAbstractScrollArea.SizeAdjustPolicy.AdjustToContents)
        layout.addWidget(self._table)

    def set_properties(self, properties: list[PropertyItem]) -> None:
        """Display a list of properties.

        Parameters
        ----------
        properties : list[PropertyItem]
            The properties to display.
        """
        self._table.setRowCount(0)

        if not properties:
            self._title_label.setText("No properties")
            return

        # Find the type from identity properties
        type_value = ""
        for prop in properties:
            if prop.name == "Type":
                type_value = prop.value
                break
        self._title_label.setText(type_value or "Selected Object")

        self._table.setRowCount(len(properties))
        for row, prop in enumerate(properties):
            name_item = QTableWidgetItem(prop.display_name)
            if prop.label:
                name_item.setToolTip(f"{prop.label}\nDEXPI attribute: {prop.name}")
            value_item = QTableWidgetItem(prop.value)
            value_item.setToolTip(prop.value)
            self._table.setItem(row, 0, name_item)
            self._table.setItem(row, 1, value_item)
            self._table.setItem(row, 2, QTableWidgetItem(prop.category))

    def clear(self) -> None:
        """Clear the properties display."""
        self._title_label.setText("No selection")
        self._table.setRowCount(0)
