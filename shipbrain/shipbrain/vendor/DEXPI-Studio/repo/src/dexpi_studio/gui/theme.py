"""Theme constants and application-wide stylesheet for DEXPI Studio.

Includes TU Delft brand colours plus a low-risk modern Fusion/QSS polish
layer for core widgets (docks, toolbars, tables, tree, line edits, canvas).
"""

from __future__ import annotations

TUD_CYAN: str = "#00A6D6"
TUD_DARK_BLUE: str = "#003499"
TUD_TURQUOISE: str = "#2AEBBA"
TUD_SKY_BLUE: str = "#84F0E1"


def build_app_stylesheet() -> str:
    """Return the global application stylesheet used for UI polish."""
    return """
QMainWindow {
    background: #f8fafc;
}

QWidget {
    font-family: "Segoe UI", Arial, sans-serif;
    font-size: 13px;
    color: #0f172a;
}

QDockWidget {
    titlebar-close-icon: none;
    titlebar-normal-icon: none;
    border: 1px solid #d8dee9;
    border-radius: 8px;
    background: #f8fafc;
}

QDockWidget::title {
    background: #f1f5f9;
    color: #1e293b;
    padding: 7px 8px;
    font-weight: 700;
    border-bottom: 1px solid #d8dee9;
}

QToolBar {
    background: #f8fafc;
    border: none;
    border-bottom: 1px solid #d8dee9;
    spacing: 4px;
    padding: 4px 6px;
}

QToolButton {
    background: transparent;
    border: 1px solid transparent;
    border-radius: 8px;
    padding: 5px 8px;
}

QToolButton:hover {
    background: #e8f1ff;
    border: 1px solid #bae6fd;
    color: #1d4ed8;
}

QToolButton:pressed {
    background: #bfdbfe;
}

QLineEdit {
    background: white;
    border: 1px solid #cbd5e1;
    border-radius: 7px;
    padding: 6px 8px;
}

QLineEdit:focus {
    border: 1px solid #2563eb;
}

QTreeView, QTreeWidget, QTableView, QTableWidget {
    background: white;
    border: 1px solid #d8dee9;
    border-radius: 8px;
    selection-background-color: #dbeafe;
    selection-color: #0f172a;
    gridline-color: #e5eaf2;
}

QTableView, QTableWidget {
    alternate-background-color: #f8fafc;
}

QTreeView::item:selected,
QTreeWidget::item:selected,
QTableView::item:selected,
QTableWidget::item:selected {
    background: #dbeafe;
    color: #0f172a;
}

QHeaderView::section {
    background: #f1f5f9;
    color: #334155;
    padding: 7px;
    border: none;
    border-bottom: 1px solid #d8dee9;
    font-weight: 600;
}

QTabWidget#right_panel_tabs::pane {
    border: 1px solid #d8dee9;
    border-radius: 8px;
    background: white;
}

QTabWidget#right_panel_tabs QTabBar::tab {
    background: #f8fafc;
    color: #334155;
    border: 1px solid #d8dee9;
    border-bottom: none;
    padding: 7px 12px;
    margin-right: 2px;
    border-top-left-radius: 7px;
    border-top-right-radius: 7px;
}

QTabWidget#right_panel_tabs QTabBar::tab:selected {
    background: white;
    color: #003499;
    font-weight: 700;
    border-top: 3px solid #003499;
}

QTabWidget#right_panel_tabs QTabBar::tab:hover {
    background: #eef3ff;
}

QTextEdit {
    background: white;
    border: 1px solid #d8dee9;
    border-radius: 8px;
}

QLabel#PanelTitle {
    font-weight: 600;
    color: #1e293b;
    padding: 4px 6px;
}

QGraphicsView {
    background: #e5e7eb;
    border: none;
}

QPushButton#diagnosticsSummaryButton {
    border: 1px solid #d8dee9;
    border-radius: 6px;
    padding: 2px 8px;
    background: #f8fafc;
    color: #334155;
}

QPushButton#diagnosticsSummaryButton:hover {
    background: #eef2f7;
}

QMenuBar {
    background: #f8fafc;
    color: #334155;
    border-bottom: 1px solid #e2e8f0;
}

QMenuBar::item {
    padding: 4px 10px;
    border-radius: 4px;
}

QMenuBar::item:selected {
    background: #e2e8f0;
    color: #0f172a;
}
"""
