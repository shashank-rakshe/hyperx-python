"""Export dialog for choosing from available pyDEXPI exports."""

from __future__ import annotations

from typing import TYPE_CHECKING

from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

if TYPE_CHECKING:
    from dexpi_studio.core.capabilities import ExportCapability


class ExportDialog(QDialog):
    """Dialog for selecting an export format and output path."""

    def __init__(
        self,
        exports: list[ExportCapability],
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Export DEXPI Model")
        self.setMinimumWidth(450)

        self._exports = exports
        self._selected_export: str | None = None
        self._output_path: str | None = None

        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the dialog layout."""
        layout = QVBoxLayout(self)

        if not self._exports:
            layout.addWidget(QLabel("No export formats available."))
            buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Cancel)
            buttons.rejected.connect(self.reject)
            layout.addWidget(buttons)
            return

        form = QFormLayout()

        # Export format selector
        self._format_combo = QComboBox()
        for export in self._exports:
            self._format_combo.addItem(f"{export.name} — {export.description}", export.name)
        self._format_combo.currentIndexChanged.connect(self._on_format_changed)
        form.addRow("Format:", self._format_combo)

        # Output path
        path_layout = QVBoxLayout()
        self._path_input = QLineEdit()
        self._path_input.setPlaceholderText("Select output path...")
        path_layout.addWidget(self._path_input)

        browse_btn = QPushButton("Browse...")
        browse_btn.clicked.connect(self._browse_output)
        path_layout.addWidget(browse_btn)

        form.addRow("Output:", path_layout)

        layout.addLayout(form)

        # Buttons
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _on_format_changed(self, index: int) -> None:
        """Update description when format changes."""
        pass

    def _browse_output(self) -> None:
        """Open a file/directory browser for output path."""
        if not self._exports:
            return

        current_idx = self._format_combo.currentIndex()
        export = self._exports[current_idx]

        if export.file_extension:
            path, _ = QFileDialog.getSaveFileName(
                self,
                "Select Output File",
                "",
                f"{export.name} (*{export.file_extension});;All Files (*)",
            )
        else:
            path = QFileDialog.getExistingDirectory(self, "Select Output Directory")

        if path:
            self._path_input.setText(path)

    def get_selection(self) -> tuple[str | None, str | None]:
        """Get the selected export name and output path.

        Returns
        -------
        tuple[str | None, str | None]
            (export_name, output_path) or (None, None) if invalid.
        """
        if not self._exports:
            return None, None

        export_name = self._format_combo.currentData()
        output_path = self._path_input.text().strip()

        if not output_path:
            return None, None

        return export_name, output_path
