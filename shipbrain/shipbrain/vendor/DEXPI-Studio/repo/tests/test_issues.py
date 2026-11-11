"""Tests for the issue report: what loading and validation say about a file."""

import csv
from pathlib import Path

import pytest

from dexpi_studio.core.issues import (
    IssueReport,
    issues_from_loading,
    status_text,
    summary_text,
    validate,
    write_csv,
)
from dexpi_studio.core.pydexpi_adapter import load_file_with_report

_REFERENCE_PID: Path = Path(__file__).parent.parent / "data" / "reference_pid.xml"


def defective_copy(tmp_path: Path, old: str, new: str) -> Path:
    """A copy of the reference P&ID with *old* replaced, once, by *new*."""
    text = _REFERENCE_PID.read_text(encoding="utf-8")
    assert old in text
    path = tmp_path / "defective.xml"
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    return path


@pytest.fixture
def unknown_class_file(tmp_path):
    """The heat exchanger's class is misspelt, so the loader cannot build it."""
    return defective_copy(
        tmp_path,
        'type="Plant/ProcessEquipment.PlateHeatExchanger"',
        'type="Plant/ProcessEquipment.PlateHeatExchangr"',
    )


def test_a_sound_file_reports_nothing():
    model, entries = load_file_with_report(_REFERENCE_PID)
    report = IssueReport(loading=issues_from_loading(entries), validation=validate(model))

    assert not report.data_lost
    assert not report.needs_attention
    assert status_text(report) == "Validation: no issues found."
    assert summary_text(report).startswith("Loaded: the whole file was read.")


def test_what_the_loader_left_out_is_reported(unknown_class_file):
    """The plain loaders discard this, so the file looked whole with 11 objects missing."""
    model, entries = load_file_with_report(unknown_class_file)
    report = IssueReport(loading=issues_from_loading(entries), validation=validate(model))

    assert report.data_lost
    assert report.needs_attention
    first = report.loading[0]
    assert first.severity == "Error"
    assert "PlateHeatExchangr" in first.title
    assert first.object_ids == ("PlateHeatExchanger1",)
    assert first.line is not None
    assert "part of the file was not loaded" in status_text(report)


def test_validation_issues_name_their_rule_and_objects():
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    model, _ = load_file_with_report(_REFERENCE_PID)
    # Two pipes ending on one node: a pyDEXPI convention, so a recommended issue.
    pipes = [
        o
        for o in get_all_instances_in_model(model)
        if type(o).__name__ == "Pipe" and o.targetNode is not None
    ]
    first, second = pipes[:2]
    second.__dict__["targetNode"] = first.targetNode

    issues = validate(model)

    shared = [i for i in issues if i.rule_id == "pydexpi_piping_node_single_connection"]
    assert shared
    issue = shared[0]
    assert issue.severity == "Recommended"
    assert issue.group  # the rule's name, not its id
    assert issue.group != issue.rule_id
    assert issue.rule_description
    assert first.id in issue.object_ids and second.id in issue.object_ids


def test_mandatory_issues_come_first():
    model, _ = load_file_with_report(_REFERENCE_PID)
    tank = model.conceptualModel.taggedPlantItems[0]
    # The same nozzle composed twice breaks DEXPI's composition tree: mandatory.
    tank.nozzles.append(tank.nozzles[0])

    severities = [i.severity for i in validate(model)]

    assert "Mandatory" in severities
    assert severities == sorted(severities, key=["Mandatory", "Recommended"].index)


def test_the_csv_holds_every_issue(unknown_class_file, tmp_path):
    model, entries = load_file_with_report(unknown_class_file)
    issues = issues_from_loading(entries) + validate(model)
    target = tmp_path / "issues.csv"

    count = write_csv(issues, target)

    with target.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert count == len(issues) == len(rows)
    assert rows[0]["severity"] == "Error"
    assert rows[0]["objects"] == "PlateHeatExchanger1"


def test_a_file_that_is_no_xml_raises(tmp_path):
    from lxml import etree

    path = tmp_path / "broken.xml"
    path.write_text(_REFERENCE_PID.read_text(encoding="utf-8")[:5000], encoding="utf-8")

    with pytest.raises(etree.XMLSyntaxError):
        load_file_with_report(path)


def test_a_file_read_in_part_still_draws(unknown_class_file):
    """The drawing group of the object that was not loaded is left out, not the drawing."""
    from dexpi_studio.core.pydexpi_adapter import render_svg

    model, _ = load_file_with_report(unknown_class_file)

    svg = render_svg(model)

    assert svg is not None and "<svg" in svg
