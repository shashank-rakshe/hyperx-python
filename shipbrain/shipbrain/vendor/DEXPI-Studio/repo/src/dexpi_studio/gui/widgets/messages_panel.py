"""Messages panel for validation/check/export messages."""

from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QHeaderView,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)


class MessagesPanel(QWidget):
    """Widget showing validation, check, and export messages."""

    counts_changed = Signal(int, int, int)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._counts: dict[str, int] = {"info": 0, "warning": 0, "error": 0}
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the messages table."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        self._table = QTableWidget()
        self._table.setColumnCount(3)
        self._table.setHorizontalHeaderLabels(["Level", "Message", "Source"])
        self._table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self._table.setAlternatingRowColors(True)
        self._table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        layout.addWidget(self._table)

    def add_message(self, level: str, message: str, source: str) -> None:
        """Add a message to the panel.

        Parameters
        ----------
        level : str
            Message severity: "error", "warning", or "info".
        message : str
            The message text.
        source : str
            Where the message originated from.
        """
        normalized_level = self._normalize_level(level)

        row = self._table.rowCount()
        self._table.insertRow(row)

        level_item = QTableWidgetItem(normalized_level.upper())
        self._table.setItem(row, 0, level_item)
        self._table.setItem(row, 1, QTableWidgetItem(message))
        self._table.setItem(row, 2, QTableWidgetItem(source))

        self._counts[normalized_level] += 1
        self.counts_changed.emit(
            self._counts["info"],
            self._counts["warning"],
            self._counts["error"],
        )

    def clear(self) -> None:
        """Clear all messages."""
        self._table.setRowCount(0)
        self._counts = {"info": 0, "warning": 0, "error": 0}
        self.counts_changed.emit(0, 0, 0)

    def counts(self) -> tuple[int, int, int]:
        """Return severity counts as ``(info, warning, error)``."""
        return (self._counts["info"], self._counts["warning"], self._counts["error"])

    def _normalize_level(self, level: str) -> str:
        normalized = level.strip().lower()
        if normalized in {"info", "warning", "error"}:
            return normalized
        return "info"
