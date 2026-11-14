"""GUI entry point for DEXPI Studio.

Launch the PySide6 desktop application.
"""

import os
import sys

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication

from dexpi_studio.gui.main_window import MainWindow
from dexpi_studio.gui.theme import build_app_stylesheet


def main() -> None:
    """Launch DEXPI Studio GUI."""
    # The strict fallback mode is a developer diagnostic path. If it is left
    # enabled in a shell profile, normal GUI usage can appear "blank" because
    # rendering aborts on the first fallback warning. Keep GUI launches robust
    # by forcing non-strict behavior here.
    os.environ["DEXPI_STUDIO_STRICT_RENDER_FALLBACK"] = "0"

    app = QApplication(sys.argv)
    app.setApplicationName("DEXPI Studio")
    app.setOrganizationName("Process Intelligence Research")
    app.setStyle("Fusion")
    app.styleHints().setColorScheme(Qt.ColorScheme.Light)
    app.setStyleSheet(build_app_stylesheet())

    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
