"""Tests for the model diff: the adapter call and the results dialog."""

from pathlib import Path

import pytest
from PySide6.QtWidgets import QTreeWidget, QTreeWidgetItemIterator

from dexpi_studio.core.pydexpi_adapter import run_diff
from dexpi_studio.gui.widgets.diff_dialog import DiffDialog

_REFERENCE_PID: Path = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture(scope="module")
def models():
    """The reference P&ID, a second load of it, and a load with one tag changed."""
    from pydexpi import load_xml_file
    from pydexpi.loaders.public import load_xml_bytes

    document = _REFERENCE_PID.read_bytes()
    assert document.count(b">H1007<") >= 1
    return (
        load_xml_file(_REFERENCE_PID),
        load_xml_file(_REFERENCE_PID),
        load_xml_bytes(document.replace(b">H1007<", b">H1007X<", 1)),
    )


def _texts(dialog: DiffDialog) -> list[str]:
    tree = dialog.findChild(QTreeWidget)
    assert tree is not None
    texts = []
    iterator = QTreeWidgetItemIterator(tree)
    while iterator.value():
        item = iterator.value()
        texts.extend(item.text(column) for column in range(2))
        iterator += 1
    return texts


def test_two_loads_of_one_xml_file_do_not_differ(models, qtbot):
    """Matching by tag is stable across XML loads, which mint new ids."""
    old, same, _ = models

    result = run_diff(old, same)

    assert not result.has_changes
    dialog = DiffDialog(result, "same.xml")
    qtbot.addWidget(dialog)
    assert dialog.findChild(QTreeWidget) is None


def test_a_changed_tag_is_shown_with_readable_values(models, qtbot):
    """A changed tag is a removed and an added object; values name objects by id."""
    old, _, changed = models

    result = run_diff(old, changed)

    assert [obj.tag for obj in result.added_objects] == ["H1007X"]
    assert [obj.tag for obj in result.removed_objects] == ["H1007"]
    dialog = DiffDialog(result, "changed.xml")
    qtbot.addWidget(dialog)
    texts = _texts(dialog)
    assert any("H1007X" in text for text in texts)
    assert not any("(id=" in text for text in texts), "a value printed a whole object"


def test_a_changed_value_is_shown_with_its_unit(qtbot):
    """A data change reads as the properties panel shows values: number and unit symbol."""
    from pydexpi import load_xml_file
    from pydexpi.loaders.public import load_xml_bytes

    document = _REFERENCE_PID.read_bytes()
    # The first 313.0 is H1007's design heat flow rate; later ones are other values.
    changed = load_xml_bytes(
        document.replace(b"<Double>313.0</Double>", b"<Double>350.0</Double>", 1)
    )

    result = run_diff(load_xml_file(_REFERENCE_PID), changed)
    dialog = DiffDialog(result, "changed.xml")
    qtbot.addWidget(dialog)

    assert [obj.tag for obj in result.modified_objects] == ["H1007"]
    texts = _texts(dialog)
    assert "Design heat flow rate" in texts
    assert "313 kW → 350 kW" in texts
