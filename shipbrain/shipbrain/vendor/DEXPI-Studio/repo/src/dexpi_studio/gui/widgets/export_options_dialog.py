"""Dialog asking for the options of one export."""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QListWidget,
    QListWidgetItem,
    QVBoxLayout,
    QWidget,
)

from dexpi_studio.core.export_options import ExportOption


class ExportOptionsDialog(QDialog):
    """Shows one widget per option and returns the chosen values.

    A choice is a combo box, a multiple choice a checkable list (at least one item must
    stay checked), a flag a check box.
    """

    def __init__(self, export_name: str, options: list[ExportOption], parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle(f"{export_name} Options")
        self.setMinimumWidth(460)
        self._options = options
        self._widgets: dict[str, QWidget] = {}

        layout = QVBoxLayout(self)
        form = QFormLayout()
        for option in options:
            widget = self._widget_for(option)
            widget.setToolTip(option.help)
            self._widgets[option.key] = widget
            form.addRow(option.label, widget)
        layout.addLayout(form)

        self._buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        self._buttons.accepted.connect(self.accept)
        self._buttons.rejected.connect(self.reject)
        layout.addWidget(self._buttons)
        self._update_ok()

    def _widget_for(self, option: ExportOption) -> QWidget:
        if option.kind == "choice":
            combo = QComboBox()
            for value, label in option.choices:
                combo.addItem(label, value)
            combo.setCurrentIndex(max(combo.findData(option.default), 0))
            return combo
        if option.kind == "multi":
            checks = QListWidget()
            for value, label in option.choices:
                item = QListWidgetItem(label)
                item.setData(Qt.ItemDataRole.UserRole, value)
                item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
                checked = isinstance(option.default, tuple) and value in option.default
                item.setCheckState(Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked)
                checks.addItem(item)
            checks.setMaximumHeight(checks.sizeHintForRow(0) * len(option.choices) + 6)
            checks.itemChanged.connect(lambda _item: self._update_ok())
            return checks
        check = QCheckBox()
        check.setChecked(bool(option.default))
        return check

    def _update_ok(self) -> None:
        """Allow OK only while every multiple choice has something checked."""
        ok = self._buttons.button(QDialogButtonBox.StandardButton.Ok)
        ok.setEnabled(
            all(
                self._checked(self._widgets[option.key])
                for option in self._options
                if option.kind == "multi"
            )
        )

    @staticmethod
    def _checked(widget: QWidget) -> list[str]:
        assert isinstance(widget, QListWidget)
        return [
            widget.item(row).data(Qt.ItemDataRole.UserRole)
            for row in range(widget.count())
            if widget.item(row).checkState() == Qt.CheckState.Checked
        ]

    def values(self) -> dict[str, object]:
        """Return the chosen value of every option, keyed as the export takes it."""
        values: dict[str, object] = {}
        for option in self._options:
            widget = self._widgets[option.key]
            if option.kind == "choice":
                assert isinstance(widget, QComboBox)
                values[option.key] = widget.currentData()
            elif option.kind == "multi":
                values[option.key] = self._checked(widget)
            else:
                assert isinstance(widget, QCheckBox)
                values[option.key] = widget.isChecked()
        return values
