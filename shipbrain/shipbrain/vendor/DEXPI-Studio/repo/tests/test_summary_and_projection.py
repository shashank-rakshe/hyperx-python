"""Tests for the model summary and the Git projection export."""

from pathlib import Path

import pytest
from PySide6.QtWidgets import QLabel, QTableWidget, QTabWidget

from dexpi_studio.core.capabilities import detect_capabilities
from dexpi_studio.core.export_options import default_options
from dexpi_studio.core.pydexpi_adapter import (
    model_summary,
    model_summary_text,
    run_export,
    summary_counts,
)
from dexpi_studio.gui.widgets.summary_dialog import SummaryDialog

_REFERENCE_PID: Path = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture(scope="module")
def model():
    from pydexpi import load_xml_file

    return load_xml_file(_REFERENCE_PID)


def test_the_summary_counts_what_pydexpi_counts(model):
    from pydexpi.toolkits.model_summary import summarize_model

    summary = summarize_model(model)
    counts = dict(summary_counts(model_summary(model)))

    assert counts["Equipment"] == str(len(summary.equipment))
    assert counts["Instruments"] == str(len(summary.instruments))
    assert counts["Objects"] == str(summary.total_objects)
    assert "Process steps" not in counts, "a P&ID has no process section"


def test_the_copied_summary_pastes_as_columns(model):
    text = model_summary_text(model_summary(model))

    assert "Equipment\tTag\n" in text
    assert any(line.endswith("\tH1007") for line in text.splitlines())


def test_the_summary_dialog_shows_counts_and_tag_tables(model, qtbot):
    summary = model_summary(model)
    dialog = SummaryDialog(summary, "plant.xml")
    qtbot.addWidget(dialog)

    tabs = dialog.findChild(QTabWidget)
    assert [tabs.tabText(i) for i in range(tabs.count())] == [
        f"Equipment ({len(summary.equipment)})",
        f"Instruments ({len(summary.instruments)})",
    ]
    equipment = tabs.widget(0)
    assert isinstance(equipment, QTableWidget)
    tags = {equipment.item(row, 1).text() for row in range(equipment.rowCount())}
    assert "H1007" in tags
    labels = [label.text() for label in dialog.findChildren(QLabel)]
    assert f"<b>{summary.total_objects}</b>" in labels


def test_the_projection_is_an_export():
    assert "Git projection" in {export.name for export in detect_capabilities().exports}


def test_the_projection_is_what_pydexpi_projects(model, tmp_path):
    from pydexpi.versioning import model_to_projection

    out = tmp_path / "plant.txt"

    run_export(model, "Git projection", out, default_options("Git projection"))

    assert out.read_bytes() == model_to_projection(model).encode("utf-8")


def test_the_projection_can_leave_out_the_drawing(model, tmp_path):
    full, engineering = tmp_path / "full.txt", tmp_path / "engineering.txt"

    run_export(model, "Git projection", full, {"include_graphics": True})
    run_export(model, "Git projection", engineering, {"include_graphics": False})

    assert engineering.stat().st_size < full.stat().st_size
