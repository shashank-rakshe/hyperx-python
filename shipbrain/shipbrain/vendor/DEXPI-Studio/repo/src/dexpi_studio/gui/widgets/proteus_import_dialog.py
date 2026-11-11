"""Beta-warning dialog shown before opening a ProteusXML (DEXPI 1.3) file."""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QDialog, QDialogButtonBox, QLabel, QVBoxLayout


class ProteusImportDialog(QDialog):
    """Inform the user about ProteusXML import limitations before proceeding."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Open ProteusXML (DEXPI 1.3) — Beta")
        self.setMinimumWidth(480)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        text = QLabel(
            "<b>ProteusXML import is an experimental beta feature.</b><br><br>"
            "DEXPI Studio will parse the ProteusXML file and map its contents to the "
            "DEXPI 2.0 data model. Because the two formats are not fully equivalent, "
            "<b>some information may be lost or approximated</b> during the conversion.<br><br>"
            "After loading, you can inspect the resulting model and export it to "
            "<b>DEXPI 2.0.1 XML or JSON</b> using the export options in the ribbon.",
            self,
        )
        text.setWordWrap(True)
        text.setTextFormat(Qt.TextFormat.RichText)
        layout.addWidget(text)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel,
            self,
        )
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("Continue")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)
