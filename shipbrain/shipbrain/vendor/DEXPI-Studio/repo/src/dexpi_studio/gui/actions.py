"""Menu bar and ribbon toolbar actions for DEXPI Studio."""

from __future__ import annotations

from typing import TYPE_CHECKING

from PySide6.QtCore import Qt
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import QMenu, QMenuBar, QSizePolicy, QToolBar

from dexpi_studio.gui.widgets.ribbon import RibbonWidget

if TYPE_CHECKING:
    from dexpi_studio.gui.main_window import MainWindow


def create_actions(window: MainWindow) -> None:
    """Create the menu bar and ribbon toolbar for the main window."""
    _create_menus(window)
    _create_ribbon_toolbar(window)


def _create_menus(window: MainWindow) -> None:
    """Create the menu bar."""
    menu_bar: QMenuBar = window.menuBar()

    # File menu
    file_menu: QMenu = menu_bar.addMenu("&File")

    open_action = QAction("&Open DEXPI File...", window)
    open_action.setShortcut(QKeySequence.StandardKey.Open)
    open_action.triggered.connect(window.open_file)
    file_menu.addAction(open_action)

    reload_action = QAction("&Reload File", window)
    reload_action.setShortcut(QKeySequence.StandardKey.Refresh)
    reload_action.triggered.connect(window.reload_file)
    file_menu.addAction(reload_action)

    export_action = QAction("&Export...", window)
    export_action.setShortcut(QKeySequence("Ctrl+E"))
    export_action.triggered.connect(window.export_file)
    file_menu.addAction(export_action)

    file_menu.addSeparator()

    close_action = QAction("&Close File", window)
    close_action.setShortcut(QKeySequence("Ctrl+W"))
    close_action.triggered.connect(window.close_file)
    file_menu.addAction(close_action)

    file_menu.addSeparator()

    exit_action = QAction("E&xit", window)
    exit_action.setShortcut(QKeySequence("Ctrl+Q"))
    exit_action.triggered.connect(window.close)
    file_menu.addAction(exit_action)

    # View menu
    view_menu: QMenu = menu_bar.addMenu("&View")

    search_action = QAction("&Search...", window)
    search_action.setShortcut(QKeySequence.StandardKey.Find)
    search_action.triggered.connect(window.show_search_bar)
    view_menu.addAction(search_action)

    search_next_action = QAction("Search &Next", window)
    search_next_action.setShortcut(QKeySequence("F3"))
    search_next_action.triggered.connect(window.search_next_result)
    view_menu.addAction(search_next_action)

    view_menu.addSeparator()

    fit_action = QAction("&Fit to Window", window)
    fit_action.setShortcut(QKeySequence("Ctrl+0"))
    fit_action.triggered.connect(window.fit_to_window)
    view_menu.addAction(fit_action)

    zoom_in_action = QAction("Zoom &In", window)
    zoom_in_action.setShortcut(QKeySequence.StandardKey.ZoomIn)
    zoom_in_action.triggered.connect(window.zoom_in)
    view_menu.addAction(zoom_in_action)

    zoom_out_action = QAction("Zoom &Out", window)
    zoom_out_action.setShortcut(QKeySequence.StandardKey.ZoomOut)
    zoom_out_action.triggered.connect(window.zoom_out)
    view_menu.addAction(zoom_out_action)

    reset_zoom_action = QAction("&Reset Zoom", window)
    reset_zoom_action.setShortcut(QKeySequence("Ctrl+1"))
    reset_zoom_action.triggered.connect(window.reset_zoom)
    view_menu.addAction(reset_zoom_action)

    view_menu.addSeparator()

    toggle_tree_action = QAction("Toggle &Model Tree", window)
    toggle_tree_action.triggered.connect(window.toggle_model_tree)
    view_menu.addAction(toggle_tree_action)

    toggle_props_action = QAction("Toggle &Properties", window)
    toggle_props_action.triggered.connect(window.toggle_properties)
    view_menu.addAction(toggle_props_action)

    toggle_assistant_action = QAction("Toggle &ChatP&ID", window)
    toggle_assistant_action.triggered.connect(window.toggle_assistant)
    view_menu.addAction(toggle_assistant_action)

    toggle_issues_action = QAction("Toggle &Issues", window)
    toggle_issues_action.triggered.connect(window.toggle_issues)
    view_menu.addAction(toggle_issues_action)

    toggle_messages_action = QAction("Toggle &Logs", window)
    toggle_messages_action.triggered.connect(window.toggle_messages)
    view_menu.addAction(toggle_messages_action)

    open_svg_panel_action = QAction("Open &SVG Panel", window)
    open_svg_panel_action.triggered.connect(window.open_external_svg_panel)
    view_menu.addAction(open_svg_panel_action)

    # Tools menu
    tools_menu: QMenu = menu_bar.addMenu("&Tools")

    validate_action = QAction("&Validate / Check", window)
    validate_action.setShortcut(QKeySequence("Ctrl+Shift+V"))
    validate_action.triggered.connect(window.validate)
    tools_menu.addAction(validate_action)

    chat_menu = tools_menu.addMenu("ChatP&ID")

    ask_assistant_action = QAction("Ask &ChatP&ID", window)
    ask_assistant_action.setShortcut(QKeySequence("Ctrl+Shift+A"))
    ask_assistant_action.triggered.connect(window.show_assistant_panel)
    chat_menu.addAction(ask_assistant_action)

    export_chat_markdown_action = QAction("Export current chat as &Markdown...", window)
    export_chat_markdown_action.triggered.connect(window.export_current_chat_markdown)
    chat_menu.addAction(export_chat_markdown_action)

    assistant_settings_action = QAction("ChatP&ID &Settings", window)
    assistant_settings_action.triggered.connect(window.show_assistant_settings)
    chat_menu.addAction(assistant_settings_action)

    # Help menu
    help_menu: QMenu = menu_bar.addMenu("&Help")

    about_action = QAction("&About", window)
    about_action.triggered.connect(window.show_about)
    help_menu.addAction(about_action)


def _create_ribbon_toolbar(window: MainWindow) -> None:
    """Create the ribbon tab-toolbar and attach it below the menu bar."""
    toolbar: QToolBar = window.addToolBar("Ribbon")
    toolbar.setObjectName("ribbon_toolbar")
    toolbar.setMovable(False)
    toolbar.setFloatable(False)
    toolbar.setContextMenuPolicy(Qt.ContextMenuPolicy.PreventContextMenu)

    ribbon = RibbonWidget(window, toolbar)
    ribbon.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
    toolbar.addWidget(ribbon)
