"""Tests for MessagesPanel severity counting and normalization."""

from __future__ import annotations

import pytest

pytest.importorskip("PySide6")

from dexpi_studio.gui.widgets.messages_panel import MessagesPanel


def test_initial_counts_are_zero(qtbot: object) -> None:
    panel = MessagesPanel()
    qtbot.addWidget(panel)  # type: ignore[attr-defined]

    assert panel.counts() == (0, 0, 0)


def test_counts_update_per_severity_and_reset(qtbot: object) -> None:
    panel = MessagesPanel()
    qtbot.addWidget(panel)  # type: ignore[attr-defined]

    panel.add_message("info", "Loaded: reference_pid.xml", "File")
    panel.add_message("warning", "Model tree construction failed", "Tree")
    panel.add_message("error", "Export failed", "Export")

    assert panel.counts() == (1, 1, 1)

    panel.clear()
    assert panel.counts() == (0, 0, 0)


def test_unknown_level_is_treated_as_info(qtbot: object) -> None:
    panel = MessagesPanel()
    qtbot.addWidget(panel)  # type: ignore[attr-defined]

    panel.add_message("debug", "Diagnostic text", "Internal")

    assert panel.counts() == (1, 0, 0)
