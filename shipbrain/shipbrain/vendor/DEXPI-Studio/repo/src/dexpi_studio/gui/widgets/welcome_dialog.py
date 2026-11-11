"""Welcome dialog shown on application start-up."""

from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QSpacerItem,
    QVBoxLayout,
    QWidget,
)

_RESOURCES = Path(__file__).parent.parent / "resources"
# In a PyInstaller bundle sys._MEIPASS is the extraction root where --add-data
# places files.  In development the data folder is five levels above this file
# (widgets/ → gui/ → dexpi_studio/ → src/ → project_root/).
if getattr(sys, "frozen", False):
    _DATA = Path(sys._MEIPASS) / "data"
else:
    _DATA = Path(__file__).parent.parent.parent.parent.parent / "data"


class WelcomeDialog(QDialog):
    """Start-up welcome screen for DEXPI Studio."""

    #: Set to True if the user chose to load the example file
    load_example: bool = False

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Welcome to DEXPI Studio")
        self.setMinimumWidth(620)
        self.setMinimumHeight(420)
        self.setSizeGripEnabled(False)
        self._build_ui()

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # ------------------------------------------------------------------ #
        # Top band — logos
        # ------------------------------------------------------------------ #
        top_band = QWidget()
        top_band.setStyleSheet("background-color: #FFFFFF; border-bottom: 1px solid #E0E0E0;")
        top_band.setFixedHeight(56)
        top_layout = QHBoxLayout(top_band)
        top_layout.setContentsMargins(20, 8, 20, 8)
        top_layout.setSpacing(16)

        for logo_file, height in [
            ("Process_Intelligence_Black_Horizontal.png", 36),
            ("pydexpi_logo.png", 32),
        ]:
            pix = QPixmap(str(_RESOURCES / logo_file))
            if not pix.isNull():
                lbl = QLabel()
                lbl.setPixmap(
                    pix.scaledToHeight(height, Qt.TransformationMode.SmoothTransformation)
                )
                top_layout.addWidget(lbl)

        top_layout.addStretch()
        root.addWidget(top_band)

        # ------------------------------------------------------------------ #
        # Body
        # ------------------------------------------------------------------ #
        body = QWidget()
        body.setStyleSheet("background-color: #F7F8FA;")
        body_layout = QHBoxLayout(body)
        body_layout.setContentsMargins(32, 28, 32, 24)
        body_layout.setSpacing(24)

        # Left: text + buttons
        left = QVBoxLayout()
        left.setSpacing(16)

        title = QLabel("Welcome to DEXPI Studio")
        title.setStyleSheet("font-size: 20px; font-weight: 700; color: #003499;")
        title.setWordWrap(True)
        left.addWidget(title)

        description = QLabel(
            "DEXPI Studio helps you open, inspect, validate, and understand "
            "DEXPI files locally by default.<br/><br/>"
            "Optional ChatP&amp;ID features may send user-selected context "
            "to the configured API provider.<br/><br/>"
            "Start by opening a DEXPI file, or explore the model structure, properties, "
            "validation results, and available "
            "<a href='https://github.com/process-intelligence-research/pyDEXPI'>pyDEXPI</a> "
            "exports once a file is loaded. pyDEXPI is built around the "
            "<a href='https://dexpi.org/'>DEXPI data model</a>.<br/><br/>"
            "A free academic tool from the "
            "<a href='https://www.pi-research.org/'>Process Intelligence Research</a> "
            "group at TU Delft, led by Artur Schweidtmann.<br/>"
        )
        description.setWordWrap(True)
        description.setStyleSheet("font-size: 13px; color: #333333; line-height: 1.5;")
        description.setOpenExternalLinks(True)
        description.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        left.addWidget(description)

        left.addSpacerItem(QSpacerItem(0, 8))

        # Buttons
        btn_open = QPushButton("📂  Open a DEXPI File…")
        btn_open.setFixedHeight(38)
        btn_open.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_open.setStyleSheet(
            "QPushButton {"
            "  background-color: #003499; color: white; border: none;"
            "  border-radius: 5px; font-size: 13px; font-weight: 600; padding: 0 20px;"
            "}"
            "QPushButton:hover { background-color: #00A6D6; }"
            "QPushButton:pressed { background-color: #0094C0; }"
        )
        btn_open.clicked.connect(self._on_open)
        left.addWidget(btn_open)

        btn_example = QPushButton("🔍  Explore Example File")
        btn_example.setFixedHeight(34)
        btn_example.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_example.setStyleSheet(
            "QPushButton {"
            "  background-color: transparent; color: #003499; border: 1.5px solid #003499;"
            "  border-radius: 5px; font-size: 13px; padding: 0 20px;"
            "}"
            "QPushButton:hover { background-color: #EEF3FF; }"
            "QPushButton:pressed { background-color: #D8E3FF; }"
        )
        btn_example.clicked.connect(self._on_example)

        # Grey out if reference file not found
        example_path = _DATA / "reference_pid.xml"
        if not example_path.exists():
            btn_example.setEnabled(False)
            btn_example.setToolTip("reference_pid.xml not found in data/")

        left.addWidget(btn_example)

        left.addStretch()
        body_layout.addLayout(left, stretch=3)

        # Right: author / personal branding block
        photo_path = _RESOURCES / "Schweidtmann_Photo_Head.jpg"
        pix = QPixmap(str(photo_path))
        if not pix.isNull():
            size = 104

            # Scale and crop to a square
            scaled = pix.scaled(
                size,
                size,
                Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                Qt.TransformationMode.SmoothTransformation,
            )

            x = (scaled.width() - size) // 2
            y = (scaled.height() - size) // 2
            cropped = scaled.copy(x, y, size, size)

            photo_lbl = QLabel()
            photo_lbl.setPixmap(cropped)
            photo_lbl.setFixedSize(size, size)
            photo_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            photo_lbl.setStyleSheet(
                f"""
                QLabel {{
                    border-radius: {size // 2}px;
                    border: 2px solid #E0E0E0;
                    background-color: white;
                }}
                """
            )

            caption = QLabel("Artur Schweidtmann\nProcess Intelligence Research\nTU Delft")
            caption.setAlignment(Qt.AlignmentFlag.AlignCenter)
            caption.setWordWrap(True)
            caption.setStyleSheet(
                """
                QLabel {
                    font-size: 11px;
                    color: #666666;
                    line-height: 1.3;
                }
                """
            )

            author_widget = QWidget()
            author_widget.setFixedWidth(150)
            author_widget.setSizePolicy(
                QSizePolicy.Policy.Fixed,
                QSizePolicy.Policy.Preferred,
            )

            author_layout = QVBoxLayout(author_widget)
            author_layout.setContentsMargins(0, 24, 0, 0)
            author_layout.setSpacing(8)
            author_layout.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignHCenter)

            author_layout.addWidget(photo_lbl, alignment=Qt.AlignmentFlag.AlignHCenter)
            author_layout.addWidget(caption, alignment=Qt.AlignmentFlag.AlignHCenter)

            body_layout.addWidget(
                author_widget,
                stretch=0,
                alignment=Qt.AlignmentFlag.AlignTop,
            )

        root.addWidget(body)

        # ------------------------------------------------------------------ #
        # Bottom bar — dismiss link
        # ------------------------------------------------------------------ #
        bottom = QWidget()
        bottom.setStyleSheet("background-color: #F0F0F0; border-top: 1px solid #E0E0E0;")
        bottom.setFixedHeight(40)
        bottom_layout = QHBoxLayout(bottom)
        bottom_layout.setContentsMargins(20, 0, 20, 0)
        bottom_layout.addStretch()

        btn_skip = QPushButton("Skip for now")
        btn_skip.setFlat(True)
        btn_skip.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_skip.setStyleSheet(
            "QPushButton { color: #888888; font-size: 12px; border: none; padding: 0 8px; }"
            "QPushButton:hover { color: #333333; }"
        )
        btn_skip.clicked.connect(self.reject)
        bottom_layout.addWidget(btn_skip)

        root.addWidget(bottom)

    # ------------------------------------------------------------------ #
    # Slots
    # ------------------------------------------------------------------ #

    def _on_open(self) -> None:
        self.load_example = False
        self.accept()

    def _on_example(self) -> None:
        self.load_example = True
        self.accept()

    @property
    def example_path(self) -> Path:
        """Absolute path to the bundled reference P&ID."""
        return _DATA / "reference_pid.xml"
