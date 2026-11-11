"""Main window for DEXPI Studio."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.query import ObjectNotFoundError, QueryEngine
from PySide6.QtCore import QEvent, QObject, QSettings, QSize, Qt, QTimer
from PySide6.QtGui import QCloseEvent, QIcon, QKeyEvent
from PySide6.QtSvgWidgets import QSvgWidget
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QDockWidget,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QStatusBar,
    QTabWidget,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from dexpi_studio import __version__
from dexpi_studio.core.capabilities import detect_capabilities
from dexpi_studio.core.issues import (
    IssueReport,
    issues_from_loading,
    status_text,
    validate as validate_model,
    write_csv,
)
from dexpi_studio.core.model_tree import TreeNode, build_model_tree
from dexpi_studio.core.pydexpi_adapter import (
    build_diagram_render_manifest,
    build_id_index,
    classify_ids,
    collect_highlight_ids,
    load_dexpi_file,
    load_file_with_report,
    model_summary,
    render_svg,
    run_diff,
    run_export,
)
from dexpi_studio.core.selection import extract_properties
from dexpi_studio.gui.actions import create_actions
from dexpi_studio.gui.diagram.view import DiagramView
from dexpi_studio.gui.selection_model import SelectionModel
from dexpi_studio.gui.widgets.assistant_panel import AssistantPanel
from dexpi_studio.gui.widgets.assistant_settings_dialog import AssistantSettingsDialog
from dexpi_studio.gui.widgets.export_dialog import ExportDialog
from dexpi_studio.gui.widgets.issues_panel import IssuesPanel
from dexpi_studio.gui.widgets.messages_panel import MessagesPanel
from dexpi_studio.gui.widgets.model_tree import ModelTreeWidget
from dexpi_studio.gui.widgets.properties_panel import PropertiesPanel
from dexpi_studio.gui.widgets.welcome_dialog import WelcomeDialog

if TYPE_CHECKING:
    from dexpi_studio.core.diagram_manifest import DiagramRenderManifest

_RESOURCES = Path(__file__).parent / "resources"
_RESULT_ROW_HEIGHT = 48
_MAX_VISIBLE_SEARCH_ROWS = 4
_SETTINGS_GEOMETRY_KEY = "ui/main_window_geometry"
_SETTINGS_STATE_KEY = "ui/main_window_state"
_SETTINGS_RIGHT_TAB_KEY = "ui/right_panel_tab_index"


class MainWindow(QMainWindow):
    """DEXPI Studio main application window."""

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("DEXPI Studio")
        self.resize(1400, 900)
        self.setWindowIcon(QIcon(str(_RESOURCES / "Process_Intelligence_Black_Mark.png")))

        self._model = None
        self._model_tree: TreeNode | None = None
        self._current_file: Path | None = None
        self._proteus = False
        self._lenient = False
        self._issue_report = IssueReport()
        self._capabilities = detect_capabilities()
        self._selection_model = SelectionModel(self)
        self._id_index: dict[str, object] = {}
        self._diagnostics_button: QPushButton | None = None
        self._assistant_popout: QDialog | None = None
        self._svg_popout: QDialog | None = None
        self._svg_popout_widget: QSvgWidget | None = None
        self._assistant_settings_dialog: AssistantSettingsDialog | None = None
        self._search_last_query: str = ""
        self._search_result_ids: list[str] = []
        self._search_result_index: int = -1

        self._setup_ui()
        self._setup_actions()
        self._restore_ui_preferences()
        self._update_ui_state()

        # Show welcome dialog after the window is fully painted
        QTimer.singleShot(0, self._show_welcome)

    def _show_welcome(self) -> None:
        """Show the welcome dialog on first launch."""
        dlg = WelcomeDialog(self)
        if dlg.exec():
            if dlg.load_example:
                self._load_file(dlg.example_path)
            else:
                self.open_file()

    def _setup_ui(self) -> None:
        """Create and arrange all widgets."""
        # Central diagram area: compact search bar + SVG viewer.
        self._center = QWidget(self)
        self._center_layout = QVBoxLayout(self._center)
        self._center_layout.setContentsMargins(0, 0, 0, 0)
        self._center_layout.setSpacing(0)

        self._search_bar = QWidget(self._center)
        self._search_bar.setObjectName("diagramSearchBar")
        self._search_bar.setVisible(True)
        self._search_bar.setStyleSheet(
            "QWidget#diagramSearchBar { background: #f8fafc; border-bottom: 1px solid #e2e8f0;}"
        )
        search_row = QHBoxLayout(self._search_bar)
        search_row.setContentsMargins(10, 6, 10, 6)
        search_row.setSpacing(8)

        search_label = QLabel("Search")
        search_label.setStyleSheet("color: #334155; font-weight: 600;")
        search_row.addWidget(search_label)

        self._search_input = QLineEdit(self._search_bar)
        self._search_input.setPlaceholderText(
            "Search current DEXPI model… e.g. H1007, valve, type:Pump"
        )
        self._search_input.returnPressed.connect(self._on_search_return_pressed)
        self._search_input.textChanged.connect(self._on_search_text_changed)
        self._search_input.installEventFilter(self)
        search_row.addWidget(self._search_input, stretch=1)

        self._search_status = QLabel("")
        self._search_status.setStyleSheet("color: #64748b;")
        search_row.addWidget(self._search_status)

        self._search_close_button = QPushButton("✕")
        self._search_close_button.setToolTip("Clear query")
        self._search_close_button.setFixedWidth(28)
        self._search_close_button.clicked.connect(self._clear_search_query)
        search_row.addWidget(self._search_close_button)

        self._center_layout.addWidget(self._search_bar)

        self._search_results_panel = QFrame(self._center)
        self._search_results_panel.setObjectName("diagramSearchResultsPanel")
        self._search_results_panel.setVisible(False)
        self._search_results_panel.setStyleSheet(
            "QFrame#diagramSearchResultsPanel {"
            " background: white;"
            " border: 1px solid #d7dde6;"
            " border-top: 0;"
            "}"
            "QListWidget {"
            " border: 0;"
            " background: white;"
            " outline: none;"
            "}"
            "QListWidget::item {"
            " padding: 8px 10px;"
            " border-bottom: 1px solid #eef2f7;"
            "}"
            "QListWidget::item:selected {"
            " background: #e8f1ff;"
            " color: #0f172a;"
            "}"
        )
        search_results_layout = QVBoxLayout(self._search_results_panel)
        search_results_layout.setContentsMargins(0, 0, 0, 0)
        search_results_layout.setSpacing(0)

        self._search_results_list = QListWidget(self._search_results_panel)
        self._search_results_list.setVerticalScrollMode(QListWidget.ScrollMode.ScrollPerPixel)
        self._search_results_list.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )
        self._search_results_list.itemClicked.connect(self._on_search_result_clicked)
        self._search_results_list.itemDoubleClicked.connect(self._on_search_result_double_clicked)
        self._search_results_list.itemSelectionChanged.connect(
            self._on_search_result_selection_changed
        )
        self._search_results_list.installEventFilter(self)
        search_results_layout.addWidget(self._search_results_list)

        self._center_layout.addWidget(self._search_results_panel)

        # Central SVG viewer
        self._svg_view = DiagramView()
        self._center_layout.addWidget(self._svg_view, stretch=1)
        self.setCentralWidget(self._center)
        # Main canvas should show only model-backed overlays, not full SVG background.
        self._svg_view.set_full_svg_background_visible(False)

        # Left dock: model tree
        self._tree_dock = QDockWidget("Model Tree", self)
        self._tree_dock.setObjectName("model_tree_dock")
        self._tree_widget = ModelTreeWidget()
        self._tree_dock.setWidget(self._tree_widget)
        self.addDockWidget(Qt.DockWidgetArea.LeftDockWidgetArea, self._tree_dock)

        # Right dock: properties + assistant
        self._props_dock = QDockWidget("Inspector", self)
        self._props_dock.setObjectName("properties_dock")
        self._right_tabs = QTabWidget()
        self._right_tabs.setObjectName("right_panel_tabs")
        self._props_panel = PropertiesPanel()
        self._assistant_panel = AssistantPanel()
        self._assistant_panel.set_context_provider(self._assistant_context)
        self._assistant_panel.set_settings_opener(self.show_assistant_settings)
        self._right_tabs.addTab(self._props_panel, "Properties")
        self._right_tabs.addTab(self._assistant_panel, "ChatP&ID")
        self._right_tabs.setCurrentIndex(0)

        corner = QWidget()
        corner_layout = QHBoxLayout(corner)
        corner_layout.setContentsMargins(0, 0, 0, 0)
        corner_layout.setSpacing(0)
        popout_btn = QToolButton()
        popout_btn.setText("↗")
        popout_btn.setToolTip("Pop out ChatP&ID")
        popout_btn.clicked.connect(self.pop_out_assistant)
        corner_layout.addWidget(popout_btn)
        self._right_tabs.setCornerWidget(corner, Qt.Corner.TopRightCorner)

        self._props_dock.setWidget(self._right_tabs)
        self.addDockWidget(Qt.DockWidgetArea.RightDockWidgetArea, self._props_dock)

        # Bottom dock: messages
        self._messages_dock = QDockWidget("Logs", self)
        self._messages_dock.setObjectName("messages_dock")
        self._messages_panel = MessagesPanel()
        self._messages_dock.setWidget(self._messages_panel)
        self._messages_dock.setMinimumHeight(110)
        self._messages_dock.setMaximumHeight(260)
        self.addDockWidget(Qt.DockWidgetArea.BottomDockWidgetArea, self._messages_dock)

        # Bottom dock, beside the logs: what loading and validation found.
        self._issues_dock = QDockWidget("Issues", self)
        self._issues_dock.setObjectName("issues_dock")
        self._issues_panel = IssuesPanel()
        self._issues_dock.setWidget(self._issues_panel)
        self._issues_dock.setMinimumHeight(140)
        self.addDockWidget(Qt.DockWidgetArea.BottomDockWidgetArea, self._issues_dock)
        self.tabifyDockWidget(self._messages_dock, self._issues_dock)
        self._issues_panel.objects_selected.connect(self._on_issue_objects_selected)
        self._issues_panel.zoom_requested.connect(self._on_focus_requested)
        self._issues_panel.revalidate_requested.connect(self.validate)
        self._issues_panel.lenient_reload_requested.connect(self.reload_leniently)
        self._issues_panel.export_requested.connect(self.export_issues)
        self._messages_dock.hide()
        self._issues_dock.hide()

        # Default layout balance: keep center canvas visually primary.
        self.resizeDocks(
            [self._tree_dock, self._props_dock],
            [260, 380],
            Qt.Orientation.Horizontal,
        )

        # Status bar
        self._status_bar = QStatusBar()
        self.setStatusBar(self._status_bar)
        self._setup_diagnostics_panel()
        self._status_bar.showMessage("Ready")

    def _setup_diagnostics_panel(self) -> None:
        """Create compact diagnostics summary in the status bar."""
        self._diagnostics_button = QPushButton(self)
        self._diagnostics_button.setObjectName("diagnosticsSummaryButton")
        self._diagnostics_button.setFlat(True)
        self._diagnostics_button.setCursor(Qt.CursorShape.PointingHandCursor)
        self._diagnostics_button.clicked.connect(self.toggle_messages)
        self._status_bar.addPermanentWidget(self._diagnostics_button)

        self._issues_button = QPushButton(self)
        self._issues_button.setObjectName("issuesSummaryButton")
        self._issues_button.setFlat(True)
        self._issues_button.setCursor(Qt.CursorShape.PointingHandCursor)
        self._issues_button.setToolTip("Show what loading and validation found")
        self._issues_button.clicked.connect(self.toggle_issues)
        self._issues_button.setVisible(False)
        self._status_bar.insertPermanentWidget(0, self._issues_button)

        self._messages_panel.counts_changed.connect(self._update_diagnostics_summary)
        info, warning, error = self._messages_panel.counts()
        self._update_diagnostics_summary(info, warning, error)

    def _setup_actions(self) -> None:
        """Create menus and toolbar actions."""
        create_actions(self)
        # Wire selection model ↔ SVG viewer ↔ model tree
        self._svg_view.object_selected.connect(self._selection_model.select)
        self._svg_view.focus_requested.connect(self._on_focus_requested)
        self._svg_view.assistant_requested.connect(self._on_assistant_requested)
        self._svg_view.empty_space_clicked.connect(self._selection_model.clear)
        self._selection_model.selection_changed.connect(self._on_selection_changed)
        self._tree_widget.set_selection_model(self._selection_model)
        self._tree_widget.focus_requested.connect(self._on_focus_requested)

    def _update_ui_state(self) -> None:
        """Enable/disable UI elements based on current state."""
        self._status_bar.showMessage(
            f"File: {self._current_file.name}" if self._current_file else "Ready"
        )

    def _restore_ui_preferences(self) -> None:
        """Restore persisted window geometry/state and active right panel tab."""
        settings = QSettings()

        geometry = settings.value(_SETTINGS_GEOMETRY_KEY)
        if geometry is not None:
            self.restoreGeometry(geometry)

        state = settings.value(_SETTINGS_STATE_KEY)
        if state is not None:
            self.restoreState(state)

        right_tab_index_raw = settings.value(_SETTINGS_RIGHT_TAB_KEY, 0)
        try:
            right_tab_index = int(str(right_tab_index_raw))
        except (TypeError, ValueError):
            right_tab_index = 0
        if 0 <= right_tab_index < self._right_tabs.count():
            self._right_tabs.setCurrentIndex(right_tab_index)

        # Keep startup search state deterministic.
        self._search_bar.setVisible(True)
        self._search_input.clear()
        self._clear_search_results()

    def _save_ui_preferences(self) -> None:
        """Persist window geometry/state and active right panel tab."""
        settings = QSettings()
        settings.setValue(_SETTINGS_GEOMETRY_KEY, self.saveGeometry())
        settings.setValue(_SETTINGS_STATE_KEY, self.saveState())
        settings.setValue(_SETTINGS_RIGHT_TAB_KEY, self._right_tabs.currentIndex())

    def closeEvent(self, event: QCloseEvent) -> None:
        """Persist window layout preferences before closing."""
        self._save_ui_preferences()
        super().closeEvent(event)

    # ------------------------------------------------------------------
    # Public slots / action handlers
    # ------------------------------------------------------------------

    def open_file(self) -> None:
        """Open a DEXPI XML/JSON file."""
        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Open DEXPI File",
            "",
            "DEXPI Files (*.xml *.json);;XML Files (*.xml);;JSON Files (*.json);;All Files (*)",
        )
        if not file_path:
            return
        self._load_file(Path(file_path))

    def open_proteus_file(self) -> None:
        """Show beta warning, then open a ProteusXML (DEXPI 1.3) file."""
        from dexpi_studio.gui.widgets.proteus_import_dialog import ProteusImportDialog

        dlg = ProteusImportDialog(self)
        if dlg.exec() != QDialog.DialogCode.Accepted:
            return
        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Open ProteusXML File",
            "",
            "ProteusXML Files (*.xml);;All Files (*)",
        )
        if not file_path:
            return
        self._load_file(Path(file_path), proteus=True)

    def reload_file(self) -> None:
        """Reload the currently open DEXPI file from disk."""
        if self._current_file is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return
        self._load_file(self._current_file, proteus=self._proteus, strict=not self._lenient)
        self._status_bar.showMessage(f"Reloaded: {self._current_file.name}", 2000)

    def reload_leniently(self) -> None:
        """Load the current file again with pyDEXPI's lenient setting."""
        if self._current_file is None:
            return
        self._load_file(self._current_file, proteus=self._proteus, strict=False)

    def close_file(self) -> None:
        """Close the currently loaded file."""
        self._model = None
        self._model_tree = None
        self._current_file = None
        self._svg_view.clear()
        self._tree_widget.clear()
        self._props_panel.clear()
        self._messages_panel.clear()
        self._issues_panel.clear()
        self._issues_button.setVisible(False)
        self._clear_search_results()
        self._update_ui_state()

    def export_file(self) -> None:
        """Open the export dialog."""
        if self._model is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return

        dialog = ExportDialog(self._capabilities.exports, self)
        if dialog.exec():
            export_name, output_path = dialog.get_selection()
            if export_name and output_path:
                self._run_export(export_name, Path(output_path))

    def _ask_export_options(self, export_name: str) -> dict[str, object] | None:
        """Ask for the export's options; ``None`` if the user cancelled.

        An export without options needs no dialog and gets an empty dict.
        """
        from dexpi_studio.core.export_options import options_for
        from dexpi_studio.gui.widgets.export_options_dialog import ExportOptionsDialog

        options = options_for(export_name)
        if not options:
            return {}
        dialog = ExportOptionsDialog(export_name, options, self)
        if not dialog.exec():
            return None
        return dialog.values()

    def _run_export(self, export_name: str, output_path: Path) -> None:
        """Ask for the export's options, run it and report the outcome."""
        assert self._model is not None
        options = self._ask_export_options(export_name)
        if options is None:
            return
        try:
            msg = run_export(self._model, export_name, output_path, options)
            self._post_message("info", msg, "Export")
            QMessageBox.information(self, "Export Complete", msg)
        except Exception as e:
            self._post_message("error", str(e), "Export")
            QMessageBox.critical(self, "Export Error", str(e))

    def export_format(self, export_name: str) -> None:
        """Export directly to a specific format, prompting for save location.

        Parameters
        ----------
        export_name : str
            The export format name (must match an ``ExportCapability.name``).
        """
        if self._model is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return

        cap = next((e for e in self._capabilities.exports if e.name == export_name), None)
        if cap is None:
            return

        ext = cap.file_extension or ""
        if ext:
            output_path, _ = QFileDialog.getSaveFileName(
                self,
                f"Export as {export_name}",
                "",
                f"{export_name} (*{ext});;All Files (*)",
            )
        else:
            # An export without an extension writes a folder of files (Neo4j CSV).
            output_path = QFileDialog.getExistingDirectory(self, f"Export {export_name} to folder")
        if not output_path:
            return

        self._run_export(export_name, Path(output_path))

    def show_summary(self) -> None:
        """Show the counts and tags of the loaded model."""
        if self._model is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return
        try:
            summary = model_summary(self._model)
        except Exception as e:
            QMessageBox.critical(self, "Summary Error", f"Summary failed:\n{e}")
            return
        from dexpi_studio.gui.widgets.summary_dialog import SummaryDialog

        name = self._current_file.name if self._current_file else "model"
        SummaryDialog(summary, name, self).show()

    def diff_file(self) -> None:
        """Compare the current model against a second DEXPI file."""
        if self._model is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return
        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Select File to Compare Against",
            "",
            "DEXPI Files (*.xml *.json);;XML Files (*.xml);;JSON Files (*.json);;All Files (*)",
        )
        if not file_path:
            return
        try:
            model_new = load_dexpi_file(Path(file_path))
        except Exception as e:
            QMessageBox.critical(self, "Load Error", f"Failed to load comparison file:\n{e}")
            return
        try:
            result = run_diff(self._model, model_new)
        except Exception as e:
            QMessageBox.critical(self, "Diff Error", f"Diff failed:\n{e}")
            return
        from dexpi_studio.gui.widgets.diff_dialog import DiffDialog

        dlg = DiffDialog(result, Path(file_path).name, self)
        dlg.show()

    def validate(self) -> None:
        """Validate the loaded model again and show what was found."""
        if self._model is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return
        if self._run_validation():
            self._show_issues()
            self._status_bar.showMessage(status_text(self._issue_report), 10000)

    def _run_validation(self) -> bool:
        """Validate the model into the issue report; False when validation itself failed."""
        self._status_bar.showMessage("Validating…")
        QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        try:
            self._issue_report.validation = validate_model(self._model)
        except Exception as e:
            self._status_bar.clearMessage()
            self._post_message("error", f"Validation failed: {e}", "Validation")
            QMessageBox.critical(self, "Validation Error", f"Validation failed:\n{e}")
            return False
        finally:
            QApplication.restoreOverrideCursor()
        self._issues_panel.set_report(
            self._issue_report, set(self._id_index), self._issue_object_names()
        )
        self._update_issues_button()
        return True

    def _issue_object_names(self) -> dict[str, str]:
        """The display name of every loaded object an issue is about."""
        from pydexpi import get_display_name

        report = self._issue_report
        names = {}
        for oid in {oid for i in report.loading + report.validation for oid in i.object_ids}:
            obj = self._id_index.get(oid)
            if obj is not None:
                names[oid] = get_display_name(obj)
        return names

    def _show_issues(self) -> None:
        """Bring the Issues panel to the front."""
        self._issues_dock.setVisible(True)
        self._issues_dock.raise_()
        self.resizeDocks([self._issues_dock], [230], Qt.Orientation.Vertical)

    def toggle_issues(self) -> None:
        """Show or hide the Issues panel."""
        if self._issues_dock.isVisible() and not self._issues_dock.visibleRegion().isEmpty():
            self._issues_dock.hide()
        else:
            self._show_issues()

    def _update_issues_button(self) -> None:
        report = self._issue_report
        lost = report.count("Error") + report.count("Critical")
        parts = []
        if lost:
            parts.append(f"{lost} loading errors")
        parts.append(f"{report.count('Mandatory')} mandatory")
        parts.append(f"{report.count('Recommended')} recommended")
        self._issues_button.setText("Issues  |  " + "  ".join(parts))
        colour = "#b91c1c" if report.needs_attention else "#334155"
        self._issues_button.setStyleSheet(f"color: {colour};")
        self._issues_button.setVisible(True)

    def export_issues(self) -> None:
        """Write the issues shown to a CSV file."""
        report = self._issue_report
        issues = report.validation + report.loading
        if not issues:
            return
        stem = self._current_file.stem if self._current_file else "model"
        file_path, _ = QFileDialog.getSaveFileName(
            self, "Export Issues", f"{stem}_issues.csv", "CSV Files (*.csv)"
        )
        if not file_path:
            return
        try:
            count = write_csv(issues, file_path)
        except OSError as e:
            QMessageBox.critical(self, "Export Error", f"Could not write the file:\n{e}")
            return
        self._status_bar.showMessage(f"Exported {count} issue(s) to {Path(file_path).name}", 5000)

    def _on_issue_objects_selected(self, object_ids: list[str]) -> None:
        """Select the first object an issue is about, and highlight all of them."""
        self._selection_model.select(object_ids[0])
        if len(object_ids) > 1:
            self._svg_view.highlight_ids(object_ids)

    def fit_to_window(self) -> None:
        """Fit the SVG view to the window."""
        self._svg_view.fit_to_window()

    def zoom_in(self) -> None:
        """Zoom in the SVG view."""
        self._svg_view.zoom_in()

    def zoom_out(self) -> None:
        """Zoom out the SVG view."""
        self._svg_view.zoom_out()

    def reset_zoom(self) -> None:
        """Reset zoom to default."""
        self._svg_view.reset_zoom()

    def toggle_model_tree(self) -> None:
        """Toggle visibility of the model tree dock."""
        self._tree_dock.setVisible(not self._tree_dock.isVisible())

    def toggle_properties(self) -> None:
        """Toggle/open properties tab in the right dock."""
        if self._props_dock.isVisible() and self._right_tabs.currentWidget() is self._props_panel:
            self._props_dock.hide()
            return
        self.show_properties_panel()

    def toggle_assistant(self) -> None:
        """Toggle/open assistant tab in the right dock."""
        if (
            self._props_dock.isVisible()
            and self._right_tabs.currentWidget() is self._assistant_panel
        ):
            self._props_dock.hide()
            return
        self.show_assistant_panel()

    def show_properties_panel(self) -> None:
        """Ensure right dock is visible and Properties tab is active."""
        self._props_dock.show()
        self._right_tabs.setCurrentWidget(self._props_panel)

    def show_assistant_panel(self) -> None:
        """Ensure right dock is visible and ChatP&ID tab is active."""
        self._props_dock.show()
        self._right_tabs.setCurrentWidget(self._assistant_panel)
        self._assistant_panel.focus_prompt()

    def show_assistant_settings(self) -> None:
        """Show the dedicated Assistant settings dialog."""
        if self._assistant_settings_dialog is None:
            self._assistant_settings_dialog = AssistantSettingsDialog(self)
        self._assistant_settings_dialog.show()
        self._assistant_settings_dialog.raise_()
        self._assistant_settings_dialog.activateWindow()

    def pop_out_assistant(self) -> None:
        """Open ChatP&ID in a detached floating window."""
        if self._assistant_popout is not None and self._assistant_popout.isVisible():
            self._assistant_popout.raise_()
            self._assistant_popout.activateWindow()
            return

        dlg = QDialog(self, Qt.WindowType.Window)
        dlg.setWindowTitle("ChatP&ID")
        dlg.resize(500, 650)
        layout = QVBoxLayout(dlg)
        layout.setContentsMargins(8, 8, 8, 8)
        detached = AssistantPanel(dlg)
        detached.set_context_provider(self._assistant_context)
        detached.set_settings_opener(self.show_assistant_settings)
        layout.addWidget(detached)

        def _clear_popout(_: int) -> None:
            self._assistant_popout = None

        dlg.finished.connect(_clear_popout)
        self._assistant_popout = dlg
        dlg.show()

    def toggle_messages(self) -> None:
        """Open/close the messages dock."""
        visible = not self._messages_dock.isVisible()
        self._messages_dock.setVisible(visible)
        if visible:
            self.resizeDocks([self._messages_dock], [170], Qt.Orientation.Vertical)

    def _assistant_context(self) -> dict[str, object]:
        """Return dynamic UI context used by Assistant requests."""
        return {
            "model": self._model,
            "selected_id": self._selection_model.selected_id,
            "current_file": str(self._current_file) if self._current_file is not None else None,
        }

    def export_current_chat_markdown(self) -> None:
        """Export currently selected ChatP&ID conversation as Markdown."""
        self.show_assistant_panel()
        self._assistant_panel.export_current_chat_markdown()

    def show_search_bar(self) -> None:
        """Focus the always-visible search input."""
        self._search_input.setFocus(Qt.FocusReason.ShortcutFocusReason)
        self._search_input.selectAll()

    def hide_search_bar(self) -> None:
        """Compatibility alias: clear query for always-visible search."""
        self._clear_search_query()

    def toggle_search_bar(self) -> None:
        """Toggle visibility of the compact search bar."""
        if self._search_bar.isVisible():
            self.hide_search_bar()
        else:
            self.show_search_bar()

    def run_search(self) -> None:
        """Execute a fresh search from the current search text."""
        self._apply_search(advance_if_same=False)

    def search_next_result(self) -> None:
        """Jump to the next search result; Enter triggers this."""
        self._apply_search(advance_if_same=True)

    def search_previous_result(self, *, close_dropdown: bool = False) -> None:
        """Jump to the previous search result; Shift+Enter triggers this."""
        query = self._search_input.text().strip()
        if not query:
            self._hide_search_results_panel()
            return

        if self._model is None:
            return

        if query != self._search_last_query:
            self.run_search()

        if not self._search_result_ids:
            return

        if self._search_result_index < 0:
            self._search_result_index = 0
        self._search_result_index = (self._search_result_index - 1) % len(self._search_result_ids)
        self._show_search_results_panel()
        self._select_search_result(self._search_result_index, close_dropdown=close_dropdown)

    def _on_search_text_changed(self, _text: str) -> None:
        """Run incremental search while typing and keep dropdown temporary."""
        self._search_last_query = ""
        self.run_search()

    def _on_search_return_pressed(self) -> None:
        """Enter selects current result and closes dropdown."""
        query = self._search_input.text().strip()
        if not query:
            self._hide_search_results_panel()
            return

        if query != self._search_last_query:
            self.run_search()

        if not self._search_result_ids:
            return

        if self._search_result_index < 0:
            self._search_result_index = 0
        self._select_search_result(self._search_result_index, close_dropdown=True)

    def _apply_search(self, *, advance_if_same: bool) -> None:
        query = self._search_input.text().strip()
        if not query:
            self._clear_search_results()
            return

        if self._model is None:
            QMessageBox.information(self, "Search", "Please open a DEXPI file first.")
            return

        if query != self._search_last_query:
            self._search_result_ids = self._query_object_ids(query)
            self._search_last_query = query
            self._search_result_index = 0 if self._search_result_ids else -1
        elif advance_if_same and self._search_result_ids:
            self._search_result_index = (self._search_result_index + 1) % len(
                self._search_result_ids
            )

        if not self._search_result_ids:
            self._search_status.setText("No results")
            self._search_results_list.clear()
            self._hide_search_results_panel()
            self._svg_view.highlight(None)
            return

        self._populate_search_results_list()
        self._show_search_results_panel()
        self._select_search_result(self._search_result_index, close_dropdown=False)

    def _clear_search_results(self) -> None:
        """Clear search cache and remove result highlights."""
        self._search_last_query = ""
        self._search_result_ids = []
        self._search_result_index = -1
        self._search_status.setText("")
        self._search_results_list.clear()
        self._hide_search_results_panel()
        self._svg_view.highlight(None)

    def _clear_search_query(self) -> None:
        """Clear query text and remove dropdown/result highlights."""
        self._search_input.clear()
        self._clear_search_results()

    def _show_search_results_panel(self) -> None:
        """Show temporary dropdown results panel."""
        self._search_results_panel.setVisible(bool(self._search_result_ids))

    def _hide_search_results_panel(self) -> None:
        """Hide temporary dropdown results panel."""
        self._search_results_panel.setVisible(False)

    def _populate_search_results_list(self) -> None:
        """Fill the dropdown with current query matches."""
        self._search_results_list.clear()
        for display_index, obj_id in enumerate(self._search_result_ids, start=1):
            title, subtitle = self._format_search_result(obj_id, display_index=display_index)
            item = QListWidgetItem()
            item.setData(Qt.ItemDataRole.UserRole, obj_id)
            item.setSizeHint(QSize(0, _RESULT_ROW_HEIGHT))
            self._search_results_list.addItem(item)
            self._search_results_list.setItemWidget(
                item,
                self._build_search_result_widget(title, subtitle),
            )

        self._update_search_results_panel_height()

        if self._search_result_ids:
            self._search_results_list.setCurrentRow(max(0, self._search_result_index))

    def _build_search_result_widget(self, title: str, subtitle: str) -> QWidget:
        """Create a compact two-line widget for one search hit row."""
        row = QWidget(self._search_results_list)
        row.setMinimumHeight(_RESULT_ROW_HEIGHT)
        row.setFixedHeight(_RESULT_ROW_HEIGHT)
        row.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        row_layout = QVBoxLayout(row)
        row_layout.setContentsMargins(12, 6, 12, 9)
        row_layout.setSpacing(2)

        title_label = QLabel(title, row)
        title_label.setMinimumHeight(16)
        title_label.setStyleSheet("font-size: 13px; font-weight: 600; color: #0f172a;")
        title_label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        row_layout.addWidget(title_label)

        subtitle_label = QLabel(subtitle, row)
        subtitle_label.setMinimumHeight(16)
        subtitle_label.setWordWrap(False)
        subtitle_label.setStyleSheet("font-size: 11.5px; color: #475569;")
        subtitle_label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        row_layout.addWidget(subtitle_label)

        return row

    def _update_search_results_panel_height(self) -> None:
        """Apply compact dropdown sizing based on result count."""
        result_count = len(self._search_result_ids)
        if result_count <= 0:
            self._search_results_panel.setFixedHeight(0)
            self._search_results_list.setFixedHeight(0)
            return

        row_height = _RESULT_ROW_HEIGHT
        max_visible_rows = _MAX_VISIBLE_SEARCH_ROWS
        panel_padding = 8
        visible_rows = min(result_count, max_visible_rows)
        panel_height = visible_rows * row_height + panel_padding

        self._search_results_panel.setFixedHeight(panel_height)
        self._search_results_list.setFixedHeight(max(1, panel_height - panel_padding))
        if result_count > max_visible_rows:
            self._search_results_list.setVerticalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAsNeeded
            )
        else:
            self._search_results_list.setVerticalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAlwaysOff
            )

    def _format_search_result(self, obj_id: str, *, display_index: int) -> tuple[str, str]:
        """Return two-line display text for a search result row."""
        obj = self._id_index.get(obj_id)
        short_id = self._short_id(obj_id)
        if obj is None:
            return short_id, f"Type: Unknown · ID: {short_id}"

        tag = str(getattr(obj, "tagName", "") or getattr(obj, "tag", "") or "").strip()
        component_name = str(
            getattr(obj, "componentName", "")
            or getattr(obj, "displayName", "")
            or getattr(obj, "name", "")
            or ""
        ).strip()
        class_name = type(obj).__name__
        type_label = class_name

        connection = self._connection_summary(obj)

        # Priority: Tag Name -> Component Name -> Label/Type + index -> short ID
        if tag:
            title = tag
        elif component_name:
            title = component_name
        elif connection and "pipe" in class_name.lower():
            title = "Pipe connection"
        elif type_label:
            title = f"{type_label} {display_index}"
        else:
            title = short_id

        details: list[str] = []
        details.append(f"Type: {type_label}")

        if tag and tag != title:
            details.append(f"Tag: {tag}")

        if connection:
            details.append(connection)
        else:
            if component_name and component_name != title:
                details.append(component_name)

        details.append(f"ID: {short_id}")
        return title, " · ".join(details)

    @staticmethod
    def _short_id(value: str, *, visible_chars: int = 11) -> str:
        """Shorten a long object ID for compact dropdown display."""
        text = str(value or "").strip()
        if len(text) <= visible_chars:
            return text
        return f"{text[:visible_chars]}…"

    def _connection_summary(self, obj: object) -> str:
        """Build `source -> target` summary for connection-like objects."""
        source = self._endpoint_label(
            getattr(obj, "source", None)
            or getattr(obj, "sourceObject", None)
            or getattr(obj, "fromObject", None)
            or getattr(obj, "startObject", None)
        )
        target = self._endpoint_label(
            getattr(obj, "target", None)
            or getattr(obj, "targetObject", None)
            or getattr(obj, "toObject", None)
            or getattr(obj, "endObject", None)
        )
        if source and target:
            return f"{source} → {target}"
        return ""

    def _endpoint_label(self, endpoint: object | None) -> str:
        """Resolve a human-readable endpoint label from an object or object ID."""
        if endpoint is None:
            return ""

        resolved = endpoint
        if isinstance(endpoint, str):
            resolved = self._id_index.get(endpoint, endpoint)

        if isinstance(resolved, str):
            return self._short_id(resolved)

        tag = str(
            getattr(resolved, "tagName", "")
            or getattr(resolved, "tag", "")
            or getattr(resolved, "displayName", "")
            or getattr(resolved, "name", "")
            or ""
        ).strip()
        if tag:
            return tag

        return type(resolved).__name__

    def _select_search_result(self, index: int, *, close_dropdown: bool) -> None:
        """Select/highlight one search result by index."""
        if index < 0 or index >= len(self._search_result_ids):
            return

        self._search_result_index = index
        obj_id = self._search_result_ids[index]
        self._svg_view.highlight(obj_id)
        self._selection_model.select(obj_id)

        count = len(self._search_result_ids)
        label = "result" if count == 1 else "results"
        self._search_status.setText(f"{index + 1}/{count} {label}")

        self._search_results_list.blockSignals(True)
        self._search_results_list.setCurrentRow(index)
        self._search_results_list.blockSignals(False)

        if close_dropdown:
            self._hide_search_results_panel()
            self._search_input.setFocus(Qt.FocusReason.ShortcutFocusReason)

    def _on_search_result_clicked(self, item: QListWidgetItem) -> None:
        """Single-click: select/highlight and keep dropdown open."""
        obj_id = str(item.data(Qt.ItemDataRole.UserRole) or "")
        if obj_id in self._search_result_ids:
            self._select_search_result(self._search_result_ids.index(obj_id), close_dropdown=False)

    def _on_search_result_double_clicked(self, item: QListWidgetItem) -> None:
        """Double-click: select/highlight and close dropdown."""
        obj_id = str(item.data(Qt.ItemDataRole.UserRole) or "")
        if obj_id in self._search_result_ids:
            self._select_search_result(self._search_result_ids.index(obj_id), close_dropdown=True)

    def _on_search_result_selection_changed(self) -> None:
        """Keyboard selection in results list updates active highlight/selection."""
        current_item = self._search_results_list.currentItem()
        if current_item is None:
            return
        obj_id = str(current_item.data(Qt.ItemDataRole.UserRole) or "")
        if obj_id in self._search_result_ids:
            self._select_search_result(self._search_result_ids.index(obj_id), close_dropdown=False)

    def eventFilter(self, watched: QObject, event: QEvent) -> bool:
        """Handle search keyboard interactions (Esc/Enter/Down) without dialogs."""
        if event.type() == QEvent.Type.KeyPress and isinstance(event, QKeyEvent):
            key_event = event
            if watched is self._search_input:
                if key_event.key() in {Qt.Key.Key_Return, Qt.Key.Key_Enter} and (
                    key_event.modifiers() & Qt.KeyboardModifier.ShiftModifier
                ):
                    self.search_previous_result(close_dropdown=True)
                    return True
                if key_event.key() == Qt.Key.Key_Escape:
                    self._hide_search_results_panel()
                    return True
                if key_event.key() == Qt.Key.Key_Down and self._search_results_panel.isVisible():
                    self._search_results_list.setFocus(Qt.FocusReason.ShortcutFocusReason)
                    if self._search_result_index >= 0:
                        self._search_results_list.setCurrentRow(self._search_result_index)
                    return True

            if watched is self._search_results_list:
                if key_event.key() == Qt.Key.Key_Escape:
                    self._hide_search_results_panel()
                    self._search_input.setFocus(Qt.FocusReason.ShortcutFocusReason)
                    return True
                if key_event.key() in {Qt.Key.Key_Return, Qt.Key.Key_Enter}:
                    current_item = self._search_results_list.currentItem()
                    if current_item is not None:
                        self._on_search_result_double_clicked(current_item)
                    return True

        return super().eventFilter(watched, event)

    def _query_object_ids(self, query: str) -> list[str]:
        """Resolve query to object IDs using pydexpi.query API."""
        if self._model is None:
            return []

        engine = QueryEngine(self._model)
        q = query.strip()
        q_lower = q.lower()
        objects: list[object] = []

        if q_lower.startswith("type:"):
            type_query = q.split(":", 1)[1].strip()
            if type_query:
                matched_types = [
                    t for t in engine.index.by_type.keys() if type_query.lower() in t.lower()
                ]
                for type_name in matched_types:
                    objects.extend(engine.find_all(type=type_name))
        elif q_lower.startswith("tag:"):
            tag_query = q.split(":", 1)[1].strip()
            if tag_query:
                objects.extend(engine.find_by_tag(tag_query))
        else:
            objects.extend(engine.find_by_tag(q))

            # Support quick lookups by ID and type fragments.
            try:
                objects.append(engine.get_by_id(q))
            except ObjectNotFoundError:
                pass

            matched_types = [t for t in engine.index.by_type.keys() if q_lower in t.lower()]
            for type_name in matched_types:
                objects.extend(engine.find_all(type=type_name))

        seen: set[str] = set()
        result_ids: list[str] = []
        for obj in objects:
            obj_id = str(getattr(obj, "id", "") or "").strip()
            if not obj_id or obj_id in seen:
                continue
            if obj_id not in self._id_index:
                continue
            seen.add(obj_id)
            result_ids.append(obj_id)

        return result_ids

    def open_external_svg_panel(self) -> None:
        """Open the original raw SVG in a detached external panel window."""
        if self._model is None:
            QMessageBox.warning(self, "No File", "Please open a DEXPI file first.")
            return

        if self._svg_popout is not None and self._svg_popout.isVisible():
            self._svg_popout.raise_()
            self._svg_popout.activateWindow()
            return

        dlg = QDialog(self, Qt.WindowType.Window)
        file_part = self._current_file.name if self._current_file is not None else "Rendered SVG"
        dlg.setWindowTitle(f"SVG Panel — {file_part}")
        dlg.resize(1200, 850)

        layout = QVBoxLayout(dlg)
        layout.setContentsMargins(0, 0, 0, 0)

        popout_svg = QSvgWidget(dlg)
        layout.addWidget(popout_svg)

        svg_content = self._build_svg_content()
        if not svg_content:
            QMessageBox.warning(self, "Render", "No SVG content available for this model.")
            dlg.deleteLater()
            return

        popout_svg.load(svg_content.encode("utf-8"))

        def _clear_svg_popout(_: int) -> None:
            self._svg_popout = None
            self._svg_popout_widget = None

        dlg.finished.connect(_clear_svg_popout)
        self._svg_popout = dlg
        self._svg_popout_widget = popout_svg
        dlg.show()

    def _post_message(self, level: str, message: str, source: str) -> None:
        """Add a message without forcing the messages panel to expand."""
        self._messages_panel.add_message(level, message, source)

    def _update_diagnostics_summary(self, info: int, warning: int, error: int) -> None:
        """Update compact diagnostics summary label text."""
        if self._diagnostics_button is None:
            return
        self._diagnostics_button.setText(
            f"Logs  |  {info} info  {warning} warnings  {error} errors"
        )

    def show_about(self) -> None:
        """Show the About dialog."""
        from pathlib import Path

        from PySide6.QtGui import QPixmap
        from PySide6.QtWidgets import (
            QApplication,
            QDialog,
            QDialogButtonBox,
            QHBoxLayout,
            QLabel,
            QPushButton,
            QVBoxLayout,
        )

        from dexpi_studio.gui.theme import TUD_CYAN, TUD_DARK_BLUE

        resources = Path(__file__).parent / "resources"

        dlg = QDialog(self)
        dlg.setWindowTitle("About DEXPI Studio")
        dlg.setMinimumWidth(520)

        layout = QVBoxLayout(dlg)
        layout.setSpacing(12)
        layout.setContentsMargins(24, 20, 24, 20)

        # Logo row
        logo_row = QHBoxLayout()
        logo_row.setSpacing(16)
        for logo_file, height in [
            ("pydexpi_logo.png", 42),
            ("Process_Intelligence_Black_Horizontal.png", 34),
        ]:
            pix = QPixmap(str(resources / logo_file))
            if not pix.isNull():
                lbl = QLabel()
                lbl.setPixmap(
                    pix.scaledToHeight(height, Qt.TransformationMode.SmoothTransformation)
                )
                logo_row.addWidget(lbl)
        logo_row.addStretch()
        layout.addLayout(logo_row)
        layout.addSpacing(6)

        bibtex = (
            "@InProceedings{pyDEXPI,\n"
            "  author    = {Goldstein, Dominik P. and Schulze Balhorn, Lukas and Alimin, "
            "Achmad Anggawirya and Schweidtmann, Artur M.},\n"
            "  booktitle = {Proceedings of the 35th European Symposium on Computer Aided "
            "Process Engineering (ESCAPE35)},\n"
            "  title     = {pyDEXPI:{A} {Python} framework for piping and instrumentation "
            "diagrams using the {DEXPI} information model},\n"
            "  year      = {2025},\n"
            "  address   = {Ghent, Belgium},\n"
            "  month     = {July},\n"
            "  doi       = {https://doi.org/10.69997/sct.139043},\n"
            "}\n"
        )

        # Text
        text = QLabel(
            f"<h2 style='color:{TUD_DARK_BLUE}; margin-bottom:4px;'>DEXPI Studio</h2>"
            f"<p style='color:{TUD_CYAN}; font-weight:600;'>Version {__version__}</p>"
            "<p>DEXPI Studio is a free desktop application for opening, inspecting, "
            "validating, and exporting DEXPI P&amp;ID files.</p>"
            "<p>It is built as a graphical companion for "
            "<a href='https://github.com/process-intelligence-research/pyDEXPI'>pyDEXPI</a>, "
            "a Python framework for working with piping and instrumentation diagrams "
            "using the <a href='https://dexpi.org/'>DEXPI information model</a>.</p>"
            "<p>DEXPI Studio is developed as a free academic tool to support research, "
            "teaching, and practical work with DEXPI P&amp;ID files.</p>"
            f"<p style='color:{TUD_DARK_BLUE};'><b>Local-first by design:</b><br/>"
            "DEXPI Studio runs locally by default. DEXPI files are not uploaded or shared "
            "by the core application. Optional Assistant features may send user-selected "
            "context to the configured API provider.</p>"
            "<p>Developed by the Process Intelligence Research group at TU Delft.<br/>"
            "<a href='https://www.pi-research.org/'>Process Intelligence Research</a></p>"
            "<p><b>License</b></p>"
            "<p>DEXPI Studio comes with absolutely no warranty. It is free software under the "
            "<a href='https://www.gnu.org/licenses/agpl-3.0.html'>GNU Affero General Public "
            "License v3</a>.<br/>"
            "<a href='https://github.com/process-intelligence-research/DEXPI-Studio'>Source "
            "code</a></p>"
            "<p><b>Citation</b></p>"
            "<p>If you use DEXPI Studio or pyDEXPI in academic work, please cite:</p>"
            "<p>Goldstein, D. P., Schulze Balhorn, L., Alimin, A. A., &amp; Schweidtmann, "
            "A. M. (2025).<br/>"
            "<i>pyDEXPI: A Python framework for piping and instrumentation diagrams using "
            "the DEXPI information model.</i><br/>"
            "Proceedings of ESCAPE35, Ghent, Belgium.<br/>"
            "<a href='https://doi.org/10.69997/sct.139043'>https://doi.org/10.69997/sct.139043</a></p>"
        )
        text.setWordWrap(True)
        text.setOpenExternalLinks(True)
        layout.addWidget(text)

        copy_bibtex = QPushButton("Copy BibTeX")
        copy_bibtex.setToolTip("Copy full BibTeX citation to clipboard")
        copy_bibtex.setFixedWidth(120)

        def _copy_bibtex() -> None:
            clipboard = QApplication.clipboard()
            if clipboard is not None:
                clipboard.setText(bibtex)
            self._status_bar.showMessage("BibTeX copied to clipboard", 2500)

        copy_bibtex.clicked.connect(_copy_bibtex)
        copy_row = QHBoxLayout()
        copy_row.addWidget(copy_bibtex)
        copy_row.addStretch()
        layout.addLayout(copy_row)

        # OK button
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok)
        buttons.accepted.connect(dlg.accept)
        layout.addWidget(buttons)

        dlg.exec()

    @property
    def has_model(self) -> bool:
        """Whether a model is currently loaded."""
        return self._model is not None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _load_file(self, path: Path, *, proteus: bool = False, strict: bool = True) -> None:
        """Load a file, report what the loader could not read, validate it and show it."""
        QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        try:
            model, entries = load_file_with_report(path, strict=strict, proteus=proteus)
        except Exception as e:
            QApplication.restoreOverrideCursor()
            self._report_load_failure(path, e, proteus=proteus, strict=strict)
            return
        QApplication.restoreOverrideCursor()
        self._model = model
        self._current_file = path
        self._proteus = proteus
        self._lenient = not strict and not proteus
        self._issue_report = IssueReport(
            loading=issues_from_loading(entries), lenient=self._lenient
        )

        self._messages_panel.clear()
        how = " (leniently)" if self._lenient else ""
        self._post_message("info", f"Loaded{how}: {path.name}", "File")

        # Render SVG
        try:
            payload = self._build_svg_payload()
            if payload is not None:
                svg_content, equipment_ids, piping_ids, render_manifest = payload
                self._svg_view.load_svg(
                    svg_content,
                    equipment_ids=equipment_ids,
                    piping_segment_ids=piping_ids,
                    render_manifest=render_manifest,
                )
                # Keep search result overlays up to date after reloading content.
                if self._search_bar.isVisible() and self._search_input.text().strip():
                    self._search_last_query = ""
                    self.run_search()
                if self._svg_popout_widget is not None:
                    self._svg_popout_widget.load(svg_content.encode("utf-8"))
            else:
                self._svg_view.clear()
                self._post_message(
                    "warning",
                    "No diagram data found — SVG rendering unavailable.",
                    "Render",
                )
        except Exception as e:
            self._svg_view.clear()
            self._post_message("warning", f"SVG rendering failed: {e}", "Render")

        # Build model tree
        try:
            self._model_tree = build_model_tree(self._model)
            self._tree_widget.set_tree(self._model_tree)
        except Exception as e:
            self._post_message("warning", f"Model tree construction failed: {e}", "Tree")

        # Build id → object index for selection
        try:
            self._id_index = build_id_index(self._model)
        except Exception as e:
            self._id_index = {}
            self._post_message("warning", f"ID index construction failed: {e}", "Selection")

        self._selection_model.clear()
        self._update_ui_state()

        # Validate straight away: a file pyDEXPI read in part, or one that breaks DEXPI, says
        # so as it opens rather than looking like a sound model.
        if self._run_validation():
            if self._issue_report.needs_attention:
                self._show_issues()
            self._status_bar.showMessage(status_text(self._issue_report), 10000)

    def _report_load_failure(
        self, path: Path, error: Exception, *, proteus: bool, strict: bool
    ) -> None:
        """Say why *path* could not be opened, and offer a lenient load where it may help."""
        from lxml import etree

        if isinstance(error, etree.XMLSyntaxError):
            QMessageBox.critical(
                self,
                "Load Error",
                f"{path.name} is not well-formed XML, so nothing could be read from it.\n\n{error}",
            )
            return
        if isinstance(error, ValueError) and strict and not proteus:
            box = QMessageBox(self)
            box.setIcon(QMessageBox.Icon.Warning)
            box.setWindowTitle("Load Error")
            box.setText(f"{path.name} could not be loaded strictly.")
            box.setInformativeText(
                "pyDEXPI refused the file because loading it would lose or change data. "
                "A lenient load reads what it can and lists everything it left out or "
                "copied in the Issues panel.\n\nOpen the file leniently?"
            )
            box.setDetailedText(str(error))
            box.setStandardButtons(
                QMessageBox.StandardButton.Open | QMessageBox.StandardButton.Cancel
            )
            box.button(QMessageBox.StandardButton.Open).setText("Open leniently")
            if box.exec() == QMessageBox.StandardButton.Open:
                self._load_file(path, proteus=proteus, strict=False)
            return
        QMessageBox.critical(self, "Load Error", f"Failed to load file:\n{path}\n\nError: {error}")

    def _build_svg_payload(
        self,
    ) -> tuple[str, set[str], set[str], DiagramRenderManifest] | None:
        """Build one SVG + manifest payload for any diagram view target."""
        if self._model is None:
            return None

        svg_content = self._build_svg_content()
        if not svg_content:
            return None

        equipment_ids, piping_ids = classify_ids(self._model)
        # Include the title block (PlantMetaData) so the canvas creates a clickable
        # hit-area over it. Its bounds are added to the manifest inside
        # build_diagram_render_manifest via the Label group's PolyLine primitives.
        try:
            meta = getattr(getattr(self._model, "conceptualModel", None), "metaData", None)
            meta_id = getattr(meta, "id", None)
            if meta_id:
                equipment_ids.add(str(meta_id))
        except (AttributeError, TypeError):
            pass
        render_manifest = build_diagram_render_manifest(
            self._model,
            equipment_ids=equipment_ids,
            piping_ids=piping_ids,
        )
        return (svg_content, equipment_ids, piping_ids, render_manifest)

    def _build_svg_content(self) -> str | None:
        """Render and return raw SVG content for the current model."""
        if self._model is None:
            return None
        return render_svg(self._model)

    def _on_focus_requested(self, obj_id: str) -> None:
        """Handle 'Highlight & Zoom In' from either the canvas or model tree."""
        self._selection_model.select(obj_id)
        self._svg_view.zoom_to(obj_id)

    def _on_assistant_requested(self, obj_id: str) -> None:
        """Handle context-menu request to ask ChatP&ID about an object."""
        self._selection_model.select(obj_id)
        self.show_assistant_panel()
        self._assistant_panel.focus_prompt()

    def _on_selection_changed(self, obj_id: str | None) -> None:
        """Handle a selection change from any source (SVG, tree, or programmatic).

        Updates the properties panel, the model tree highlight, and the SVG overlay.
        Uses :func:`collect_highlight_ids` to resolve the selected object to all
        SVG element IDs that should be highlighted — leaf nodes return their own
        ID while container nodes recursively aggregate their children.
        """
        search_active = (
            self._search_results_panel.isVisible()
            and bool(self._search_input.text().strip())
            and bool(self._search_result_ids)
        )

        if obj_id is None:
            self._assistant_panel.set_selected_object_context(
                selected_object_context=None,
                short_label=None,
                class_name=None,
            )
            self._props_panel.clear()
            self._svg_view.clear_selection()
            if search_active:
                self._svg_view.highlight(None)
            else:
                self._svg_view.highlight(None)
            return

        self.show_properties_panel()

        # Keep scene-level selected state in sync regardless of selection source
        # (canvas click, tree click, or programmatic). This prevents stale
        # previously-selected items from remaining visually selected.
        self._svg_view.select_object(obj_id)

        dexpi_object = self._id_index.get(obj_id)
        if dexpi_object is not None:
            tag = str(
                getattr(dexpi_object, "tagName", "") or getattr(dexpi_object, "tag", "") or ""
            )
            display_name = str(
                getattr(dexpi_object, "displayName", "") or getattr(dexpi_object, "name", "") or ""
            )
            class_name = type(dexpi_object).__name__
            short_label = tag or display_name or str(obj_id)

            available_ui_properties = "unknown"
            if isinstance(dexpi_object, PyDexpiBaseModel):
                prop_names = [p.name for p in extract_properties(dexpi_object)]
                if prop_names:
                    available_ui_properties = ", ".join(prop_names[:12])

            selected_object_context = {
                "dexpi_xml_id": str(getattr(dexpi_object, "id", "") or "unknown"),
                "display_name": display_name or "unknown",
                "tag": tag or "unknown",
                "class": class_name,
                "ui_object_id": str(obj_id or "unknown"),
                "available_ui_properties": available_ui_properties,
            }
            self._assistant_panel.set_selected_object_context(
                selected_object_context=selected_object_context,
                short_label=short_label,
                class_name=class_name,
            )
            if isinstance(dexpi_object, PyDexpiBaseModel):
                self._props_panel.set_properties(extract_properties(dexpi_object))
            else:
                self._props_panel.clear()

            if search_active:
                self._svg_view.highlight(obj_id)
            else:
                ids = collect_highlight_ids(dexpi_object)
                if len(ids) > 1:
                    self._svg_view.highlight_ids(ids)
                elif ids:
                    self._svg_view.highlight(ids[0])
                else:
                    self._svg_view.highlight(obj_id)
        else:
            self._assistant_panel.set_selected_object_context(
                selected_object_context={
                    "dexpi_xml_id": "unknown",
                    "display_name": "unknown",
                    "tag": "unknown",
                    "class": "unknown",
                    "ui_object_id": str(obj_id or "unknown"),
                    "available_ui_properties": "unknown",
                },
                short_label=str(obj_id),
                class_name="Unknown",
            )
            self._props_panel.clear()
            if search_active:
                self._svg_view.highlight(obj_id)
            else:
                self._svg_view.highlight(obj_id)

    def _on_tree_item_selected(self, dexpi_object: object) -> None:
        """Handle tree item selection — update properties panel."""
        if dexpi_object is None:
            self._props_panel.clear()
            return

        if isinstance(dexpi_object, PyDexpiBaseModel):
            properties = extract_properties(dexpi_object)
            self._props_panel.set_properties(properties)
        else:
            self._props_panel.clear()
