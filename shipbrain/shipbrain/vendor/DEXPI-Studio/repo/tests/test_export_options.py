"""Tests for export options: what is offered, what reaches pyDEXPI, and the dialog."""

from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QCheckBox, QComboBox, QDialogButtonBox, QListWidget

from dexpi_studio.core.export_options import default_options, options_for
from dexpi_studio.core.pydexpi_adapter import run_export
from dexpi_studio.gui.widgets.export_options_dialog import ExportOptionsDialog

_REFERENCE_PID: Path = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture(scope="module")
def model():
    from pydexpi import load_xml_file

    return load_xml_file(_REFERENCE_PID)


def test_every_graph_level_of_pydexpi_is_offered():
    from pydexpi.loaders.graph_loader import GRAPH_LEVELS

    for export_name in ("GraphML", "Neo4j CSV", "LLM Context"):
        (level,) = [o for o in options_for(export_name) if o.key == "graph_level"]
        assert [value for value, _ in level.choices] == list(GRAPH_LEVELS)


def test_every_table_language_of_pydexpi_is_offered():
    from pydexpi.exports.table_locale import SUPPORTED_LANGUAGES

    (language,) = [o for o in options_for("Tables") if o.key == "language"]
    assert [value for value, _ in language.choices] == list(SUPPORTED_LANGUAGES)


def test_an_export_without_options_has_none():
    assert options_for("Image SVG") == []
    assert default_options("DEXPI 2.0.1 XML") == {}


@pytest.mark.parametrize("level", ["complete", "process", "conceptual", "process_flow"])
def test_graphml_writes_the_chosen_level(model, tmp_path, level):
    out = tmp_path / "graph.graphml"

    run_export(model, "GraphML", out, {"graph_level": level})

    assert f">{level}<" in out.read_text(encoding="utf-8")


def test_llm_context_takes_level_and_mode(model, tmp_path):
    graph, topology = tmp_path / "graph.txt", tmp_path / "topology.txt"

    run_export(model, "LLM Context", graph, {"graph_level": "conceptual", "mode": "graph"})
    run_export(model, "LLM Context", topology, {"graph_level": "conceptual", "mode": "topology"})

    assert len(topology.read_text(encoding="utf-8")) < len(graph.read_text(encoding="utf-8"))


def test_neo4j_csv_takes_the_level(model, tmp_path):
    run_export(model, "Neo4j CSV", tmp_path / "neo4j", {"graph_level": "process"})

    assert "process:" in (tmp_path / "neo4j" / "nodes.csv").read_text(encoding="utf-8")


def test_all_tables_go_into_one_file_per_format(model, tmp_path):
    options = default_options("Tables") | {"formats": [".xlsx", ".json"]}

    run_export(model, "Tables", tmp_path / "plant.xlsx", options)

    assert sorted(p.name for p in tmp_path.iterdir()) == ["plant.json", "plant.xlsx"]


def test_some_tables_go_into_a_file_each(model, tmp_path):
    options = default_options("Tables") | {"lists": ["equipment", "valve"], "language": "de"}

    run_export(model, "Tables", tmp_path / "plant.xlsx", options)

    assert sorted(p.name for p in tmp_path.iterdir()) == [
        "plant_equipment.xlsx",
        "plant_valve.xlsx",
    ]


def test_the_dialog_starts_at_the_defaults(qtbot):
    for export_name in ("GraphML", "LLM Context", "Tables"):
        dialog = ExportOptionsDialog(export_name, options_for(export_name))
        qtbot.addWidget(dialog)
        assert dialog.values() == {
            key: list(value) if isinstance(value, tuple) else value
            for key, value in default_options(export_name).items()
        }


def test_the_dialog_returns_what_was_chosen(qtbot):
    dialog = ExportOptionsDialog("Tables", options_for("Tables"))
    qtbot.addWidget(dialog)
    lists, formats = dialog.findChildren(QListWidget)
    language = dialog.findChild(QComboBox)
    styled = dialog.findChild(QCheckBox)
    ok = dialog.findChild(QDialogButtonBox).button(QDialogButtonBox.StandardButton.Ok)

    for row in range(1, lists.count()):
        lists.item(row).setCheckState(Qt.CheckState.Unchecked)
    formats.item(1).setCheckState(Qt.CheckState.Checked)
    language.setCurrentIndex(language.findData("nl"))
    styled.setChecked(False)

    assert dialog.values() == {
        "lists": ["equipment"],
        "formats": [".xlsx", ".csv"],
        "language": "nl",
        "styled": False,
    }
    assert ok.isEnabled()
    lists.item(0).setCheckState(Qt.CheckState.Unchecked)
    assert not ok.isEnabled(), "an export with no table selected cannot be started"
