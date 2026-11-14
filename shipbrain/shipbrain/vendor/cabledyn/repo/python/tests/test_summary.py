# SPDX-License-Identifier: Apache-2.0
"""Channel and line summary tables."""

from __future__ import annotations

import csv
import math
from dataclasses import dataclass

import numpy as np
import pytest
from _design_data import TIME, write_main, write_static

from cabledyn import read_output
from cabledyn.summary import (
    ChannelSummary,
    LineSummary,
    SummaryTable,
    channel_summary,
    line_summary,
)

TIMES = np.array([0.0, 1.0, 2.0])
NODES = 5


def _frames() -> np.ndarray:
    index = np.arange(NODES, dtype=float)
    return np.stack(
        [np.column_stack([10.0 * index, np.zeros(NODES), -50.0 + t * index]) for t in TIMES]
    )


def _chord(t: float) -> float:
    return math.sqrt(100.0 + t * t)


def _write_nodes(path):
    frames = _frames()
    names = ["Time(s)"] + [f"Node{i + 1}{axis}(m)" for i in range(NODES) for axis in "XYZ"]
    rows = [
        "\t".join(f"{v:.12E}" for v in (t, *f.ravel())) for t, f in zip(TIMES, frames, strict=True)
    ]
    path.write_text("# positions\n" + "\t".join(names) + "\n" + "\n".join(rows) + "\n")
    return read_output(path)


def _write_segments(path):
    names = ["Time(s)"] + [f"Segment{j}Tension(N)" for j in range(1, NODES)]
    rows = [
        "\t".join(f"{v:.12E}" for v in (t, *(1000.0 * j + 100.0 * t for j in range(1, NODES))))
        for t in TIMES
    ]
    path.write_text("# tensions\n" + "\t".join(names) + "\n" + "\n".join(rows) + "\n")
    return read_output(path)


def _main(path):
    columns = {
        "FairTen1": 1.0e6 + 1.0e5 * np.sin(2.0 * math.pi * 0.1 * TIME),
        "Curv1N1": 0.01 * TIME,
        "Curv1N3": np.full(TIME.shape, 0.02),
    }
    return read_output(write_main(path, columns))


def test_channel_summary_reports_the_time_of_each_extreme(tmp_path):
    history = _main(tmp_path / "run.out")
    table = channel_summary(history)
    assert isinstance(table, SummaryTable) and len(table) == 3
    record = table[0]
    assert isinstance(record, ChannelSummary)
    assert record.channel == "FairTen1" and record.unit == "N" and record.count == TIME.size
    assert record.maximum == pytest.approx(1.1e6) and record.maximum_time == pytest.approx(2.5)
    assert record.minimum == pytest.approx(0.9e6) and record.minimum_time == pytest.approx(7.5)
    data = history.column("FairTen1")
    assert record.mean == pytest.approx(np.mean(data))
    assert record.standard_deviation == pytest.approx(np.std(data))
    assert record.rms == pytest.approx(np.sqrt(np.mean(data**2)))
    single = channel_summary(history, "Curv1N1", start=2.0, stop=4.0)
    assert len(single) == 1 and single[0].minimum_time == 2.0 and single[0].maximum_time == 4.0
    pair = channel_summary(history, ["Curv1N3", "Curv1N1"])
    assert pair.column("channel") == ("Curv1N3", "Curv1N1")
    with pytest.raises(KeyError):
        channel_summary(history, "Missing")


def test_summary_table_conversions(tmp_path):
    table = channel_summary(_main(tmp_path / "run.out"), "FairTen1")
    assert table.columns[:4] == ("channel", "unit", "count", "minimum")
    assert list(table) == [table[0]]
    records = table.to_records()
    assert records[0]["channel"] == "FairTen1" and records[0]["count"] == TIME.size
    with pytest.raises(KeyError, match="not a column"):
        table.column("nope")
    target = table.export(tmp_path / "summary.csv")
    rows = list(csv.reader(target.open(encoding="utf-8")))
    assert rows[0] == list(table.columns)
    assert rows[1][:3] == ["FairTen1", "N", str(TIME.size)]
    assert float(rows[1][3]) == table[0].minimum
    with pytest.raises(FileExistsError):
        table.export(target)
    pytest.importorskip("pandas")
    frame = table.to_dataframe()
    assert list(frame.columns) == list(table.columns) and frame.shape == (1, 10)


def test_summary_table_of_other_records_and_validation(tmp_path):
    profile = read_output(write_static(tmp_path / "run.static.out"))
    table = SummaryTable(profile.summaries())
    assert table.column("line_id") == (1, 2)
    rows = list(csv.reader(table.export(tmp_path / "static.csv").open(encoding="utf-8")))
    assert rows[0][0] == "line_id" and len(rows) == 3
    empty: SummaryTable[ChannelSummary] = SummaryTable(())
    assert empty.columns == () and empty.to_records() == []
    with pytest.raises(ValueError, match="empty"):
        empty.export(tmp_path / "empty.csv")

    @dataclass(frozen=True)
    class Other:
        value: float | None

    with pytest.raises(TypeError, match="same type"):
        SummaryTable((Other(1.0), table[0]))
    with pytest.raises(TypeError, match="dataclass instances"):
        SummaryTable((1.0, 2.0))
    with pytest.raises(TypeError, match="dataclass instances"):
        SummaryTable((Other,))
    rows = list(csv.reader(SummaryTable((Other(None),)).export(tmp_path / "o.csv").open()))
    assert rows == [["value"], [""]]


def test_line_summary_from_line_files(tmp_path):
    nodes = _write_nodes(tmp_path / "run.Line1.p.out")
    segments = _write_segments(tmp_path / "run.Line1.t.out")
    summary = line_summary("L1", positions=nodes, tensions=segments, seabed=-50.0)
    assert isinstance(summary, LineSummary)
    assert (summary.start_time, summary.end_time, summary.sample_count) == (0.0, 2.0, 3)
    assert summary.maximum_tension == pytest.approx(4200.0)
    assert summary.maximum_tension_time == 2.0
    assert summary.maximum_tension_location == pytest.approx(3.5 * _chord(2.0))
    assert summary.minimum_tension == pytest.approx(1000.0)
    assert summary.minimum_tension_time == 0.0
    assert summary.minimum_tension_location == pytest.approx(5.0)
    assert summary.tension_location_kind == "ArcLength"
    assert summary.minimum_seabed_clearance == 0.0
    assert summary.minimum_seabed_clearance_time == 0.0
    assert summary.minimum_seabed_clearance_arc_length == 0.0
    assert summary.maximum_curvature is None and summary.minimum_bend_radius is None
    windowed = line_summary("L1", positions=nodes, tensions=segments, start=1.0, radius=0.5)
    assert windowed.minimum_tension == pytest.approx(1100.0) and windowed.sample_count == 2
    assert windowed.minimum_seabed_clearance is None
    unplaced = line_summary("L1", tensions=segments)
    assert unplaced.tension_location_kind == "Segment"
    assert unplaced.maximum_tension_location == 4.0 and unplaced.minimum_tension_location == 1.0
    only_positions = line_summary("L1", positions=nodes, stop=1.0)
    assert only_positions.sample_count == 2 and only_positions.maximum_tension is None
    table = SummaryTable((summary, unplaced))
    assert table.column("name") == ("L1", "L1")


def test_line_summary_from_main_output_and_static_profile(tmp_path):
    main = _main(tmp_path / "run.out")
    static = read_output(write_static(tmp_path / "run.static.out"))
    summary = line_summary("L1", curvature=main, positions=static, line_id=1)
    assert summary.maximum_curvature == pytest.approx(0.1)
    assert summary.maximum_curvature_time == pytest.approx(10.0)
    assert summary.maximum_curvature_location == 0.0
    assert summary.curvature_location_kind == "ArcLength"
    assert summary.minimum_bend_radius == pytest.approx(10.0)
    assert summary.sample_count == TIME.size
    static_summary = line_summary(
        "L1", tensions=static, curvature=static, positions=static, seabed=-100.0, line_id=1
    )
    assert static_summary.start_time is None and static_summary.sample_count == 1
    assert static_summary.maximum_tension == pytest.approx(5.0e5)
    assert static_summary.maximum_tension_location == pytest.approx(100.0)
    assert static_summary.maximum_tension_time is None
    assert static_summary.maximum_curvature == pytest.approx(0.04)
    assert static_summary.minimum_seabed_clearance == 0.0
    flat = line_summary("L2", curvature=static, line_id=2)
    assert flat.minimum_bend_radius == math.inf


def test_line_summary_argument_errors(tmp_path):
    with pytest.raises(ValueError, match="needs positions"):
        line_summary("L1")
    segments = _write_segments(tmp_path / "run.Line1.t.out")
    with pytest.raises(ValueError, match="needs the node positions"):
        line_summary("L1", tensions=segments, seabed=-50.0)
