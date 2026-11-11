"""Tests for the main window's Tools commands: what the user sees after a click."""

from pathlib import Path

import pytest

from dexpi_studio.gui.main_window import MainWindow

_REFERENCE_PID: Path = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture
def window(qtbot, monkeypatch, tmp_path):
    from PySide6.QtCore import QSettings

    # The window saves its layout through QSettings(); keep that out of the user's settings.
    QSettings.setDefaultFormat(QSettings.Format.IniFormat)
    QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, str(tmp_path))
    # The welcome dialog runs modally from the event loop and would block the test.
    monkeypatch.setattr(MainWindow, "_show_welcome", lambda self: None)
    window = MainWindow()
    qtbot.addWidget(window)
    window.show()
    window._load_file(_REFERENCE_PID)
    assert window._model is not None
    return window


def _issue(severity, title, object_ids=()):
    from dexpi_studio.core.issues import Issue

    return Issue(
        origin="validation",
        severity=severity,
        title=title,
        object_ids=tuple(object_ids),
        group="A rule",
        rule_id="rule_a",
    )


def test_validate_shows_its_results(window, monkeypatch):
    """The results go to the Issues panel, which starts hidden: validating opens it."""
    monkeypatch.setattr(
        "dexpi_studio.gui.main_window.validate_model",
        lambda model: [_issue("Mandatory", "broken"), _issue("Recommended", "odd")],
    )
    window._issues_dock.hide()

    window.validate()

    assert window._issues_dock.isVisible()
    assert "1 mandatory and 1 recommended" in window._status_bar.currentMessage()
    titles = [item.text(0) for item in window._issues_panel.issue_items()]
    assert titles == ["broken", "odd"]


def test_validate_says_when_there_is_nothing_to_report(window, monkeypatch):
    monkeypatch.setattr("dexpi_studio.gui.main_window.validate_model", lambda model: [])

    window.validate()

    assert window._issues_dock.isVisible()
    assert window._status_bar.currentMessage() == "Validation: no issues found."


def test_validate_runs_pydexpi_on_the_loaded_model(window):
    window.validate()

    assert window._issues_dock.isVisible()
    assert window._status_bar.currentMessage().startswith("Validation: ")


def test_a_sound_file_opens_without_the_issues_panel(window):
    """The reference P&ID is validated as it opens and has nothing to report."""
    assert not window._issues_dock.isVisible()
    assert window._status_bar.currentMessage() == "Validation: no issues found."
    assert window._issues_button.isVisible()


def test_a_file_read_in_part_says_so_as_it_opens(window, tmp_path):
    text = _REFERENCE_PID.read_text(encoding="utf-8")
    broken = tmp_path / "unknown_class.xml"
    broken.write_text(
        text.replace(
            'type="Plant/ProcessEquipment.PlateHeatExchanger"',
            'type="Plant/ProcessEquipment.PlateHeatExchangr"',
            1,
        ),
        encoding="utf-8",
    )

    window._load_file(broken)

    assert window._issues_dock.isVisible()
    assert "part of the file was not loaded" in window._status_bar.currentMessage()
    assert window._issues_panel._lenient_button.isVisibleTo(window._issues_panel)
    first = window._issues_panel.issue_items()
    assert any("PlateHeatExchangr" in item.text(0) for item in first)


def test_selecting_an_issue_selects_its_object(window, monkeypatch):
    target = next(iter(window._id_index))
    monkeypatch.setattr(
        "dexpi_studio.gui.main_window.validate_model",
        lambda model: [_issue("Mandatory", "broken", [target, "not_in_the_model"])],
    )
    window.validate()
    item = window._issues_panel.issue_items()[0]

    window._issues_panel._tree.setCurrentItem(item)

    assert window._selection_model.selected_id == target
    assert "not in the loaded model" in window._issues_panel._detail.toPlainText()


def test_a_refused_file_can_be_opened_leniently(window, monkeypatch):
    """A strict load pyDEXPI refuses offers the lenient one, which then opens the file."""
    from PySide6.QtWidgets import QMessageBox

    from dexpi_studio.core import pydexpi_adapter

    real = pydexpi_adapter.load_file_with_report
    calls = []

    def load(path, *, strict=True, proteus=False):
        calls.append(strict)
        if strict:
            raise ValueError("Not loaded: refused")
        return real(path, strict=strict, proteus=proteus)

    monkeypatch.setattr("dexpi_studio.gui.main_window.load_file_with_report", load)
    monkeypatch.setattr(QMessageBox, "exec", lambda self: QMessageBox.StandardButton.Open)

    window._load_file(_REFERENCE_PID)

    assert calls == [True, False]
    assert window._lenient
    assert "Loaded leniently" in window._issues_panel._summary.text()


def test_a_file_that_is_no_xml_says_so(window, monkeypatch, tmp_path):
    from PySide6.QtWidgets import QMessageBox

    shown = []
    monkeypatch.setattr(QMessageBox, "critical", lambda *args: shown.append(args[2]))
    broken = tmp_path / "broken.xml"
    broken.write_text(_REFERENCE_PID.read_text(encoding="utf-8")[:5000], encoding="utf-8")

    window._load_file(broken)

    assert shown and "not well-formed XML" in shown[0]
