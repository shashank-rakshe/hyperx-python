# SPDX-License-Identifier: Apache-2.0
"""Typed CableDyn result tables: reading, statistics, validation, export, and plotting."""

from __future__ import annotations

import csv
import functools
import math
import os
import time
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    LineNodeHistory,
    LineSegmentHistory,
    OutputFormatError,
    OutputTable,
    SpatialStatistics,
    StaticProfile,
    TimeHistory,
    read_output,
    read_table,
)
from cabledyn import results as results_module
from cabledyn._paths import windows_device_component
from cabledyn.results import _label


def _write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="ascii")
    return path


def _history(tmp_path):
    path = tmp_path / "case.out"
    path.write_text(
        "CableDyn history\n"
        "Time(s) FairTen1 FairIncl1\n"
        "(s) (N) (deg)\n"
        "0.0 1.0 2.0\n0.1 3.0 4.0\n0.2 5.0 6.0\n",
        encoding="ascii",
    )
    return read_output(path)


def _bare_history(tmp_path: Path) -> TimeHistory:
    """Five samples, no units row, and a channel without an inferable unit."""
    table = read_output(
        _write(
            tmp_path / "case.out",
            "CableDyn history\nTime(s) FairTen1 Other\n"
            "0.0 1.0 2.0\n0.1 3.0 4.0\n0.2 5.0 6.0\n0.3 1.0 2.0\n0.4 3.0 4.0\n",
        )
    )
    assert isinstance(table, TimeHistory)
    return table


def _profile(tmp_path):
    path = tmp_path / "case.static.out"
    path.write_text(
        "CableDyn static profile\n"
        "LineID Node ArcLength X Y Z Tension Curvature BendMoment\n"
        "(-) (-) (m) (m) (m) (m) (N) (1/m) (N-m)\n"
        "1 1 0 0 0 -5 100 0.0 0\n"
        "1 2 2 2 0 -6 120 0.5 -8\n"
        "2 1 0 0 1 -5 200 0.0 0\n"
        "2 2 3 3 1 -7 240 0.25 12\n",
        encoding="ascii",
    )
    return read_output(path)


def _bare_profile(tmp_path: Path, *, curvature: bool = True) -> StaticProfile:
    """Two two-node lines, no units row; the optional curvature is zero on line 2."""
    extra = " Curvature" if curvature else ""
    rows = (
        ("1 1 0 0 0 -5 100", " 0.0"),
        ("1 2 2 2 0 -6 120", " 0.5"),
        ("2 1 0 0 1 -5 200", " 0.0"),
        ("2 2 3 3 1 -7 240", " 0.0"),
    )
    body = "".join(row + (curv if curvature else "") + "\n" for row, curv in rows)
    table = read_output(
        _write(
            tmp_path / "case.static.out",
            f"Static\nLineID Node ArcLength X Y Z Tension{extra}\n{body}",
        )
    )
    assert isinstance(table, StaticProfile)
    return table


def _line_positions(tmp_path):
    path = tmp_path / "case.Line4.p.out"
    path.write_text(
        "# CableDyn dynamic line node positions\n"
        "Time(s) Node1X(m) Node1Y(m) Node1Z(m) Node2X(m) Node2Y(m) Node2Z(m)\n"
        "0.0 0 0 -1 3 0 -5\n"
        "1.0 2 0 -1 8 0 -9\n",
        encoding="ascii",
    )
    return read_output(path)


def _out_of_plane_positions(tmp_path: Path) -> LineNodeHistory:
    """Two nodes whose chord leaves the XZ plane at t = 0."""
    table = read_output(
        _write(
            tmp_path / "case.Line1.p.out",
            "Time(s) Node1X(m) Node1Y(m) Node1Z(m) Node2X(m) Node2Y(m) Node2Z(m)\n"
            "0.0 0 0 -1 3 4 -5\n1.0 2 0 -1 8 0 -9\n",
        )
    )
    assert isinstance(table, LineNodeHistory)
    return table


def _line_tensions(tmp_path):
    path = tmp_path / "case.Line4.t.out"
    path.write_text(
        "# CableDyn dynamic line segment tensions\n"
        "Time(s) Segment1Tension(N) Segment2Tension(N)\n"
        "0.0 100 200\n"
        "1.0 300 600\n"
        "2.0 500 400\n",
        encoding="ascii",
    )
    return read_output(path)


def _spatial(**overrides):
    kwargs = {
        "location_kind": "Segment",
        "location_ids": [1, 2],
        "quantity": "Tension",
        "unit": "N",
        "count": 3,
        "minimum": [1.0, 2.0],
        "maximum": [3.0, 4.0],
        "mean": [2.0, 3.0],
        "standard_deviation": [0.5, 0.5],
        "rms": [2.1, 3.1],
    }
    kwargs.update(overrides)
    return SpatialStatistics(**kwargs)


# -------------------------------------------------------------------------------------- read_output


def test_read_output_reports_unreadable_and_empty_files(tmp_path):
    with pytest.raises(OutputFormatError, match="cannot read"):
        read_output(tmp_path / "missing.out")
    with pytest.raises(OutputFormatError, match="empty output"):
        read_output(_write(tmp_path / "empty.out", ""))
    with pytest.raises(OutputFormatError, match="no recognized Time"):
        read_output(_write(tmp_path / "noheader.out", "title only\n1 2 3\n"))


def test_read_output_rejects_non_utf8_bytes_as_a_format_error(tmp_path):
    path = tmp_path / "latin.out"
    path.write_bytes(b"Time(s) A\n(s) (N)\n0 1\n1 \xff\xfe\n")
    with pytest.raises(OutputFormatError, match="cannot read") as caught:
        read_output(path)
    assert isinstance(caught.value.__cause__, UnicodeDecodeError)
    with pytest.raises(OutputFormatError, match="cannot read"):
        read_table(path)


def test_reserved_windows_device_names_are_rejected_before_opening(tmp_path, monkeypatch):
    monkeypatch.setattr(
        results_module,
        "windows_device_component",
        functools.partial(windows_device_component, windows=True),
    )
    for name in ("con", "NUL.out", "Aux.MD.out", "lpt1.txt"):
        with pytest.raises(OutputFormatError, match="reserved Windows device name"):
            read_output(tmp_path / name)
    with pytest.raises(OutputFormatError, match="reserved Windows device name"):
        read_table(tmp_path / "com1" / "run.out")


def test_header_search_is_linear_in_many_candidate_rows(tmp_path):
    # Every row looks like a header whose next row has a different width, so
    # the search settles on the last row and finds no data after it.
    path = _write(tmp_path / "many.out", "Time\nTime x\n" * 40000)
    start = time.perf_counter()
    with pytest.raises(OutputFormatError, match="no data rows"):
        read_output(path)
    assert time.perf_counter() - start < 10.0


def test_non_ascii_digits_are_not_numbers(tmp_path):
    path = tmp_path / "arabic.out"
    path.write_text("Time(s) A\n0 ١\n", encoding="utf-8")
    with pytest.raises(OutputFormatError, match="nonnumeric value"):
        read_output(path)


def test_huge_line_channel_indices_fail_closed(tmp_path):
    digits = "1" * 5000
    with pytest.raises(OutputFormatError, match="malformed dynamic line-node channels"):
        read_output(_write(tmp_path / "n.out", f"Time Node{digits}X(m)\n0 1\n"))
    with pytest.raises(OutputFormatError, match="malformed dynamic line-segment channels"):
        read_output(
            _write(
                tmp_path / "s.out", f"Time Segment1Tension(N) Segment{digits}Tension(N)\n0 1 2\n"
            )
        )


def test_read_output_header_without_rows(tmp_path):
    with pytest.raises(OutputFormatError, match="table has no data rows"):
        read_output(_write(tmp_path / "h.out", "Time(s) A"))
    with pytest.raises(OutputFormatError, match="table has no data rows"):
        read_output(_write(tmp_path / "u.out", "Time(s) A\n(s) (N)\n\n"))


def test_read_output_keeps_repeated_time_channels_and_rejects_other_duplicates(tmp_path):
    with pytest.warns(UserWarning, match=r"dup\.out:2: .*A -> A_2"):
        table = read_output(_write(tmp_path / "dup.out", "title\nTime(s) A A\n0 1 2\n1 3 4\n"))
    assert table.channels == ("Time(s)", "A", "A_2")
    assert list(table.column("A")) == [1.0, 3.0]
    assert list(table.column("A_2")) == [2.0, 4.0]
    with pytest.raises(OutputFormatError, match=r"prof\.out:1: duplicate channel name"):
        read_output(_write(tmp_path / "prof.out", "LineID Node X X\n1 1 0 0\n"))


def test_read_output_rejects_a_short_units_row(tmp_path):
    with pytest.raises(OutputFormatError, match=r"u\.out:2: expected 2 units, got 1"):
        read_output(_write(tmp_path / "u.out", "Time(s) A\n(s)\n0 1\n"))


def test_read_output_skips_blank_rows_and_parses_fortran_reals(tmp_path):
    table = read_output(
        _write(
            tmp_path / "f.out",
            "Time(s) A\n\n0 1.0D+02\n   \n1 1.0000000-100\n2 .5E1\n",
        )
    )
    assert np.array_equal(table.column("A"), [100.0, 1.0e-100, 5.0])


def test_reader_accepts_fortran_exponents_without_a_letter(tmp_path):
    path = tmp_path / "tiny.out"
    path.write_text("Time(s) A B\n0.0 1.0000000-100 2.5D+03\n", encoding="ascii")
    table = read_output(path)
    assert table.values[0, 1] == pytest.approx(1.0e-100)
    assert table.values[0, 2] == 2500.0


@pytest.mark.parametrize("token", ["1_000", "nan", "Infinity", "0x10", "1e", "--1"])
def test_reader_rejects_tokens_outside_the_fortran_number_grammar(tmp_path, token):
    path = tmp_path / "bad.out"
    path.write_text(f"Time(s) A\n0.0 {token}\n", encoding="ascii")
    with pytest.raises(OutputFormatError):
        read_output(path)


def test_read_output_rejects_non_finite_and_bad_tokens(tmp_path):
    with pytest.raises(OutputFormatError, match=r"n\.out:2: non-finite value '1e999'"):
        read_output(_write(tmp_path / "n.out", "Time(s) A\n0 1e999\n"))
    with pytest.raises(OutputFormatError, match=r"o\.out:2: overflowed field"):
        read_output(_write(tmp_path / "o.out", "Time(s) A\n0 ****\n"))
    with pytest.raises(OutputFormatError, match="nonnumeric value 'abc'"):
        read_output(_write(tmp_path / "x.out", "Time(s) A\n0 abc\n"))
    with pytest.raises(OutputFormatError, match="expected 2 fields, got 3"):
        read_output(_write(tmp_path / "w.out", "Time(s) A\n0 1 2\n"))


def test_read_output_plain_table_and_title_that_starts_with_time(tmp_path):
    plain = read_output(_write(tmp_path / "plain.out", "Node X Y\n1 2 3\n2 4 5\n"))
    assert type(plain) is OutputTable
    assert plain.channels == ("Node", "X", "Y")
    table = read_output(
        _write(
            tmp_path / "titled.out",
            "Time series of a mooring line\nTime(s) A\n0 1\n1 2\n",
        )
    )
    assert isinstance(table, TimeHistory)
    assert table.channels == ("Time(s)", "A")
    assert table.title == "Time series of a mooring line"


def test_time_must_be_strictly_increasing(tmp_path):
    path = tmp_path / "bad.out"
    path.write_text("Time(s) A\n0 1\n0 2\n", encoding="ascii")
    with pytest.raises(OutputFormatError, match="strictly increasing"):
        read_output(path)


@pytest.mark.parametrize(
    ("channel", "unit"),
    [
        ("FairTen1", "N"),
        ("AnchFz1", "N"),
        ("AnchFH2", "N"),
        ("anchfh02", "N"),
        ("AnchIncl2", "deg"),
        ("Ten3N4", "N"),
        ("Curv3N4", "1/m"),
        ("BendMom3N4", "N-m"),
        ("Torq3N4", "N-m"),
        ("Twist3N4", "deg"),
        ("Twist3", "deg"),
        ("L3N4px", "m"),
        ("L3N4vy", "m/s"),
        ("L3N4az", "m/s^2"),
        ("L3N4Dec", "deg"),
        ("Point2px", "m"),
        ("Con2pz", "m"),
        ("fairten1", "N"),
        ("l3n4PX", "m"),
        ("ANCHANGLE2", "deg"),
        # ids with leading zeros, as the native channel parser reads them
        ("FairTen01", "N"),
        ("Ten01N004", "N"),
        ("Torq03N004", "N-m"),
        ("Twist03N4", "deg"),
        ("Twist03", "deg"),
        ("L03N04pz", "m"),
        # an all-zero id is no channel
        ("Twist0", None),
        ("Torq0N1", None),
        ("AnchFz0", None),
        ("Unknown", None),
    ],
)
def test_native_main_channel_units_are_inferred(tmp_path, channel, unit):
    path = tmp_path / "unit.out"
    path.write_text(f"Time(s) {channel}\n0 1\n", encoding="ascii")
    assert read_output(path).unit(channel) == unit


# --------------------------------------------------------------------------- OutputTable and export


def test_output_table_owns_an_immutable_finite_copy(tmp_path):
    source = np.asarray([[1.0]])
    table = OutputTable(tmp_path / "table.out", "", ("A",), None, source)
    source[0, 0] = 2.0
    assert table.values[0, 0] == 1.0
    with pytest.raises(ValueError):
        table.values[0, 0] = 3.0
    with pytest.raises(ValueError, match="finite"):
        OutputTable(tmp_path / "bad.out", "", ("A",), None, np.asarray([[np.inf]]))


def test_output_table_rejects_shape_and_unit_mismatches(tmp_path):
    with pytest.raises(ValueError, match="2-D array matching channels"):
        OutputTable(tmp_path / "a.out", "", ("A",), None, np.asarray([1.0, 2.0]))
    with pytest.raises(ValueError, match="2-D array matching channels"):
        OutputTable(tmp_path / "a.out", "", ("A",), None, np.zeros((2, 2)))
    with pytest.raises(ValueError, match="units must match channels"):
        OutputTable(tmp_path / "a.out", "", ("A", "B"), ("(m)",), np.zeros((1, 2)))


def test_unit_of_unknown_channel_names_the_available_channels(tmp_path):
    table = _bare_history(tmp_path)
    with pytest.raises(KeyError, match=r"'Nope' is not in case\.out; available: Time"):
        table.unit("Nope")


def test_label_uses_parenthesized_unit_when_no_unit_is_given():
    assert _label("Node1X(m)", None) == "Node1X_[m]"
    assert _label("Plain", None) == "Plain"
    assert _label("Node1X(m)", "[km]") == "Node1X_[km]"


def test_relative_source_is_anchored_before_working_directory_changes(tmp_path, monkeypatch):
    source = tmp_path / "native.out"
    source.write_text("native solver record\n", encoding="ascii")
    monkeypatch.chdir(tmp_path)
    table = OutputTable(Path("native.out"), "", ("A",), None, np.asarray([[1.0]]))
    assert table.path == source.resolve()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)
    with pytest.raises(ValueError, match="source result"):
        table.export_pydatview(source, overwrite=True)
    assert source.read_text(encoding="ascii") == "native solver record\n"


def test_inferred_native_units_are_used_in_interchange_labels(tmp_path):
    path = tmp_path / "unit.out"
    path.write_text("Time(s) FairTen1 FairAngle1 Unknown\n0 1 2 3\n", encoding="ascii")
    exported = read_output(path).export_pydatview(tmp_path / "normalized.csv")
    assert exported.read_text(encoding="utf-8").splitlines()[0] == (
        "Time_[s],FairTen1_[N],FairAngle1_[deg],Unknown"
    )


def test_pydatview_export_is_atomic_explicit_and_round_trippable(tmp_path):
    profile = _profile(tmp_path).line(1)
    target = tmp_path / "profile.csv"
    assert profile.export_pydatview(target) == target.resolve()
    with target.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.reader(stream))
    assert rows[0] == [
        "LineID_[-]",
        "Node_[-]",
        "ArcLength_[m]",
        "X_[m]",
        "Y_[m]",
        "Z_[m]",
        "Tension_[N]",
        "Curvature_[1/m]",
        "BendMoment_[N-m]",
    ]
    assert np.allclose(np.asarray(rows[1:], dtype=float), profile.values)
    assert not any(label.startswith("Time") for label in rows[0])
    with pytest.raises(FileExistsError):
        profile.export_pydatview(target)


def test_pydatview_export_never_overwrites_native_source(tmp_path):
    profile = _profile(tmp_path)
    original = profile.path.read_bytes()
    with pytest.raises(ValueError, match="source result"):
        profile.export_pydatview(profile.path, overwrite=True)
    assert profile.path.read_bytes() == original


def test_export_honours_an_explicit_delimiter(tmp_path):
    table = _bare_history(tmp_path)
    target = table.export_pydatview(tmp_path / "out" / "case.csv", delimiter=";")
    lines = target.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "Time_[s];FairTen1_[N];Other"
    assert lines[1] == "0;1;2"
    with pytest.raises(ValueError, match="delimiter must be one character"):
        table.export_pydatview(tmp_path / "other.txt", delimiter="::")
    assert not (tmp_path / "other.txt").exists()


def test_export_rejects_the_source_file(tmp_path):
    table = _bare_history(tmp_path)
    with pytest.raises(ValueError, match="must not be the source result file"):
        table.export_pydatview(table.path, overwrite=True)


def test_export_removes_its_temporary_file_when_the_rename_fails(tmp_path, monkeypatch):
    table = _bare_history(tmp_path)
    target = tmp_path / "export" / "case.txt"

    def fail(*_args, **_kwargs):
        raise OSError("synthetic rename failure")

    monkeypatch.setattr(os, "replace", fail)
    with pytest.raises(OSError, match="synthetic rename failure"):
        table.export_pydatview(target)
    assert list(target.parent.iterdir()) == []


def test_dataframe_can_keep_bare_channel_names(tmp_path):
    pytest.importorskip("pandas")
    table = _bare_history(tmp_path)
    frame = table.to_dataframe(units_in_columns=False)
    assert list(frame.columns) == ["Time(s)", "FairTen1", "Other"]
    assert list(table.to_dataframe().columns) == ["Time_[s]", "FairTen1_[N]", "Other"]
    frame.iloc[0, 1] = -1.0
    assert table.values[0, 1] == 1.0


# -------------------------------------------------------------------------------------- TimeHistory


def test_time_period_statistics_and_units(tmp_path):
    table = _history(tmp_path)
    assert isinstance(table, TimeHistory)
    view = table.period(0.1, 0.2)
    assert np.allclose(view.time, [0.1, 0.2])
    result = table.statistics("FairTen1")[0]
    assert result.count == 3
    assert result.unit == "N"
    assert result.minimum == 1.0
    assert result.maximum == 5.0
    assert result.mean == 3.0
    assert result.standard_deviation == pytest.approx(np.sqrt(8.0 / 3.0))
    assert result.rms == pytest.approx(np.sqrt(35.0 / 3.0))
    with pytest.raises(ValueError, match="start"):
        table.period(0.2, 0.1)
    with pytest.raises(ValueError, match="no samples"):
        table.period(1.0, 2.0)
    with pytest.raises(ValueError, match="finite"):
        table.period(float("nan"), 0.2)


def test_open_ended_periods(tmp_path):
    table = _bare_history(tmp_path)
    assert np.allclose(table.period(start=0.25).time, [0.3, 0.4])
    assert np.allclose(table.period(stop=0.15).time, [0.0, 0.1])
    with pytest.raises(ValueError, match="period stop must be finite"):
        table.period(stop=float("inf"))


def test_statistics_accepts_an_iterable_of_channels(tmp_path):
    table = _bare_history(tmp_path)
    stats = table.statistics(iter(["Other", "FairTen1"]))
    assert [item.channel for item in stats] == ["Other", "FairTen1"]
    assert stats[0].unit is None
    assert stats[1].maximum == 5.0


def test_time_history_requires_a_time_channel(tmp_path):
    with pytest.raises(OutputFormatError, match="time-history table has no time channel"):
        TimeHistory(tmp_path / "t.out", "", ("A", "B"), None, np.zeros((2, 2)))


def test_time_history_accepts_a_bare_time_channel(tmp_path):
    table = TimeHistory(
        tmp_path / "t.out", "", ("A", "time"), None, np.asarray([[5.0, 0.0], [6.0, 1.0]])
    )
    assert table.time_channel == "time"
    assert np.array_equal(table.time, [0.0, 1.0])


def test_coherence_and_spectrum_reject_the_time_channel(tmp_path):
    table = _bare_history(tmp_path)
    with pytest.raises(ValueError, match="coherence requires two non-time channels"):
        table.coherence("Time(s)", "FairTen1", segment_length=2)
    with pytest.raises(ValueError, match="coherence requires two distinct channels"):
        table.coherence("FairTen1", "FairTen1", segment_length=2)
    with pytest.raises(ValueError, match="power spectrum requires a non-time channel"):
        table.spectrum("Time(s)", segment_length=2)


# ---------------------------------------------------------------------------------- LineNodeHistory


def test_dynamic_line_positions_are_typed_and_interpolated(tmp_path):
    history = _line_positions(tmp_path)
    assert isinstance(history, LineNodeHistory)
    assert history.node_ids == (1, 2)
    assert np.allclose(history.coordinates(0.5), [[1, 0, -1], [5.5, 0, -7]])
    assert np.allclose(history.arc_length(0.5), [0, 7.5])
    assert not history.coordinates(0.5).flags.writeable
    with pytest.raises(ValueError, match="outside"):
        history.coordinates(-0.1)


def test_line_node_coordinates_are_read_only_and_time_is_validated(tmp_path):
    table = _out_of_plane_positions(tmp_path)
    xyz = table.coordinates(0.5)
    assert np.allclose(xyz, [[1.0, 0.0, -1.0], [5.5, 2.0, -7.0]])
    assert not xyz.flags.writeable
    with pytest.raises(ValueError, match="sample time must be finite"):
        table.coordinates(float("nan"))
    assert table.arc_length(0.0)[-1] == pytest.approx(math.sqrt(9 + 16 + 16))


@pytest.mark.parametrize("deck_nodes", [False, True])
def test_viv_lift_file_is_read_as_a_time_history(tmp_path, deck_nodes):
    # <root>.Line<L>.V.out (LINES Outputs flag V): Node<i>LiftX/Y/Z(N), no units row
    channels = [f"Node{i}Lift{axis}(N)" for i in (1, 2) for axis in "XYZ"]
    text = "# CableDyn dynamic line VIV lift force at the nodes; public node order EndA -> EndB\n"
    if deck_nodes:
        text += "# DeckNode\t1\t0\n"
    text += "\t".join(["Time(s)", *channels]) + "\n"
    text += "0.0\t0\t0\t0\t0\t0\t0\n0.1\t0\t1.5\t0\t0\t-2.5\t0\n"
    path = tmp_path / "run.Line1.V.out"
    path.write_text(text, encoding="ascii")
    table = read_output(path)
    assert type(table) is TimeHistory
    assert table.channels == ("Time(s)", *channels)
    assert table.values.shape == (2, 7)
    assert table.values[1, 2] == 1.5


def test_line_node_history_rejects_bad_channels(tmp_path):
    with pytest.raises(OutputFormatError, match="malformed dynamic line-node channels"):
        LineNodeHistory(tmp_path / "p.out", "", ("Time(s)",), None, np.zeros((1, 1)))
    with pytest.raises(OutputFormatError, match="contiguous Node1X/Y/Z"):
        LineNodeHistory(
            tmp_path / "p.out",
            "",
            ("Time(s)", "Node1X(m)", "Node1Z(m)", "Node1Y(m)"),
            None,
            np.zeros((1, 4)),
        )
    with pytest.raises(OutputFormatError, match="must use metres"):
        LineNodeHistory(
            tmp_path / "p.out",
            "",
            ("Time(s)", "Node1X(ft)", "Node1Y(ft)", "Node1Z(ft)"),
            None,
            np.zeros((1, 4)),
        )


@pytest.mark.parametrize(
    "channels",
    [
        "Time(s) Node1X(m) Node1Y(m)",
        "Time(s) Node1X(m) Node1Y(m) Node1Z(m) Node3X(m) Node3Y(m) Node3Z(m)",
        "Time(s) Segment2Tension(N)",
        "Time(s) Segment1Tension(N) Segment2Tension(kN)",
        "Time(s) Node1X(m) Node1Y(m) Node1Z(ft)",
        "Time(s) Node1X(m) Other",
        "Time(s) Segment1Tension(N) Other",
    ],
)
def test_dynamic_line_channels_fail_closed(tmp_path, channels):
    path = tmp_path / "malformed.out"
    fields = len(channels.split())
    path.write_text(f"{channels}\n{' '.join('0' for _ in range(fields))}\n", encoding="ascii")
    with pytest.raises(OutputFormatError):
        read_output(path)


# --------------------------------------------------------- LineSegmentHistory and SpatialStatistics


def test_dynamic_line_tension_range_and_envelope(tmp_path):
    history = _line_tensions(tmp_path)
    assert isinstance(history, LineSegmentHistory)
    assert history.segment_ids == (1, 2)
    assert np.allclose(history.tensions(0.5), [200, 400])
    statistics = history.spatial_statistics(1.0, 2.0)
    assert statistics.location_kind == "Segment"
    assert statistics.quantity == "Tension"
    assert statistics.unit == "N"
    assert statistics.count == 2
    assert np.allclose(statistics.minimum, [300, 400])
    assert np.allclose(statistics.maximum, [500, 600])
    assert np.allclose(statistics.mean, [400, 500])
    assert not statistics.maximum.flags.writeable


def test_segment_history_rejects_bad_channels(tmp_path):
    with pytest.raises(OutputFormatError, match="malformed dynamic line-segment channels"):
        LineSegmentHistory(tmp_path / "t.out", "", ("Time(s)", "Seg1(N)"), None, np.zeros((1, 2)))
    with pytest.raises(OutputFormatError, match="contiguous Segment1 through Segment1"):
        LineSegmentHistory(
            tmp_path / "t.out", "", ("Time(s)", "Segment2Tension(N)"), None, np.zeros((1, 2))
        )
    with pytest.raises(OutputFormatError, match="must use newtons"):
        LineSegmentHistory(
            tmp_path / "t.out", "", ("Time(s)", "Segment1Tension(kN)"), None, np.zeros((1, 2))
        )


def test_spatial_statistics_normalizes_and_freezes_arrays():
    stats = _spatial(count=np.int64(3))
    assert type(stats.count) is int and stats.count == 3
    assert stats.location_ids.dtype == np.int64
    for name in ("location_ids", "minimum", "maximum", "mean", "standard_deviation", "rms"):
        array = getattr(stats, name)
        assert not array.flags.writeable
        with pytest.raises(ValueError):
            array[0] = 9


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"location_kind": ""}, "location_kind and quantity must be non-empty"),
        ({"quantity": ""}, "location_kind and quantity must be non-empty"),
        ({"count": 2.5}, "count must be a positive integer"),
        ({"count": True}, "count must be a positive integer"),
        ({"count": 0}, "count must be a positive integer"),
        ({"location_ids": []}, "non-empty one-dimensional"),
        ({"location_ids": [[1, 2]]}, "non-empty one-dimensional"),
        ({"location_ids": [0, 1]}, "positive and strictly increasing"),
        ({"location_ids": [2, 1]}, "positive and strictly increasing"),
        ({"mean": [1.0]}, "mean must be finite and match location_ids"),
        ({"rms": [1.0, np.nan]}, "rms must be finite and match location_ids"),
        ({"minimum": [5.0, 2.0]}, "minimum must not exceed maximum"),
        ({"standard_deviation": [-1.0, 0.0]}, "must be non-negative"),
        ({"rms": [1.0, -1.0]}, "must be non-negative"),
    ],
)
def test_spatial_statistics_rejects_invalid_fields(overrides, message):
    with pytest.raises(ValueError, match=message):
        _spatial(**overrides)


# ------------------------------------------------------------------------------------ StaticProfile


def test_static_lines_summaries_and_validation(tmp_path):
    profile = _profile(tmp_path)
    assert isinstance(profile, StaticProfile)
    assert profile.line_ids == (1, 2)
    assert profile.line(2).values.shape == (2, 9)
    summary = profile.summary(1)
    assert summary.node_count == 2
    assert summary.deformed_length == 2.0
    assert summary.minimum_tension == 100.0
    assert summary.maximum_tension == 120.0
    assert summary.maximum_curvature == 0.5
    assert summary.minimum_bend_radius == 2.0
    assert summary.maximum_bend_moment == 8.0
    with pytest.raises(KeyError, match="LineID 9"):
        profile.line(9)

    path = tmp_path / "reverse.static.out"
    path.write_text("LineID Node ArcLength\n(-) (-) (m)\n1 1 1\n1 2 0\n", encoding="ascii")
    with pytest.raises(OutputFormatError, match="not monotonic"):
        read_output(path)

    path = tmp_path / "interleaved.static.out"
    path.write_text("LineID Node ArcLength\n(-) (-) (m)\n1 1 0\n2 1 0\n1 2 1\n", encoding="ascii")
    with pytest.raises(OutputFormatError, match="not contiguous"):
        read_output(path)


def test_static_summary_without_curvature_and_with_zero_curvature(tmp_path):
    bare = _bare_profile(tmp_path, curvature=False).summary(1)
    assert bare.maximum_curvature is None
    assert bare.minimum_bend_radius is None
    assert bare.maximum_bend_moment is None
    assert bare.minimum_tension == 100.0
    summaries = _bare_profile(tmp_path).summaries()
    assert [item.line_id for item in summaries] == [1, 2]
    assert summaries[0].minimum_bend_radius == pytest.approx(2.0)
    assert summaries[1].maximum_curvature == 0.0
    assert summaries[1].minimum_bend_radius == math.inf
    assert summaries[1].deformed_length == 3.0
    with pytest.raises(KeyError, match=r"LineID 7 is not in case\.static\.out"):
        _bare_profile(tmp_path).summary(7)


@pytest.mark.parametrize(
    ("channels", "rows", "message"),
    [
        (("LineID", "Node"), [[1, 1]], "static profile missing ArcLength"),
        (("LineID", "Node", "ArcLength"), [[1.5, 1, 0]], "LineID values must be positive integers"),
        (("LineID", "Node", "ArcLength"), [[1, 0, 0]], "Node values must be positive integers"),
        (("LineID", "Node", "ArcLength"), [[1, 1, -1.0]], "LineID 1 arc length is negative"),
        (
            ("LineID", "Node", "ArcLength"),
            [[1, 1, 2.0], [1, 2, 1.0]],
            "LineID 1 arc length is not monotonic",
        ),
        (
            ("LineID", "Node", "ArcLength"),
            [[1, 2, 0.0], [1, 1, 1.0]],
            "LineID 1 node order is not increasing",
        ),
        (
            ("LineID", "Node", "ArcLength"),
            [[1, 1, 0.0], [2, 1, 0.0], [1, 2, 1.0]],
            "LineID 1 rows are not contiguous",
        ),
        (
            ("LineID", "Node", "ArcLength", "DeckNode"),
            [[1, 1, 0.0, 1], [1, 2, 1.0, 0.5]],
            "DeckNode values must be non-negative integers",
        ),
        (
            ("LineID", "Node", "ArcLength", "DeckNode"),
            [[1, 1, 0.0, 1], [1, 2, 1.0, 0], [1, 3, 2.0, 3]],
            "LineID 1 DeckNode does not number the deck nodes",
        ),
        (
            ("LineID", "Node", "ArcLength", "DeckNode"),
            [[1, 1, 0.0, 1], [1, 2, 1.0, 2], [1, 3, 2.0, 0]],
            "LineID 1 DeckNode does not number the deck nodes",
        ),
    ],
)
def test_static_profile_validation(tmp_path, channels, rows, message):
    with pytest.raises(OutputFormatError, match=message):
        StaticProfile(tmp_path / "s.out", "", channels, None, np.asarray(rows, dtype=float))


def test_static_profile_deck_node_arc_lengths(tmp_path):
    # line 1 refined twice: deck nodes 1, 2, 3 are mesh nodes 1, 3, 5; line 2 is the deck mesh
    channels = ("LineID", "Node", "ArcLength", "DeckNode")
    rows = [[1, n, 10.0 * (n - 1), (n + 1) // 2 if n % 2 else 0] for n in range(1, 6)]
    rows += [[2, 1, 0.0, 1], [2, 2, 4.0, 2]]
    profile = StaticProfile(tmp_path / "s.out", "", channels, None, np.asarray(rows, dtype=float))
    assert profile.deck_node_arc_lengths(1) == {1: 0.0, 2: 20.0, 3: 40.0}
    assert profile.deck_node_arc_lengths(2) == {1: 0.0, 2: 4.0}
    plain = StaticProfile(
        tmp_path / "p.out", "", channels[:3], None, np.asarray([[1, 1, 0.0], [1, 2, 3.0]])
    )
    assert plain.deck_node_arc_lengths(1) == {1: 0.0, 2: 3.0}
    with pytest.raises(KeyError, match="LineID 3"):
        profile.deck_node_arc_lengths(3)


# ---------------------------------------------------------------------------- plots and data frames


def test_dataframe_and_plots_are_optional_but_operational(tmp_path, plt):
    pytest.importorskip("pandas")
    history = _history(tmp_path)
    profile = _profile(tmp_path)
    assert history.to_dataframe().columns.tolist() == [
        "Time_[s]",
        "FairTen1_[N]",
        "FairIncl1_[deg]",
    ]
    assert history.plot("FairTen1").get_xlabel() == "Time [s]"
    assert profile.plot("Tension", line_id=1).get_xlabel() == "ArcLength [m]"
    assert profile.plot_geometry(line_id=1).get_ylabel() == "Z [m]"
    assert _line_positions(tmp_path).plot_geometry(0.5).get_xlabel() == "X [m]"
    assert _line_tensions(tmp_path).plot_range(0.5).get_xlabel() == "Segment [-]"
    assert _line_tensions(tmp_path).plot_envelope(0.5, 2.0).get_ylabel() == "Tension [N]"


def test_time_history_plot_on_given_axes_with_legend(tmp_path, plt):
    table = _bare_history(tmp_path)
    _, given = plt.subplots()
    ax = table.plot("FairTen1", "Other", ax=given, start=0.1, stop=0.3)
    assert ax is given
    assert ax.get_xlabel() == "Time [s]"
    assert ax.get_ylabel() == ""
    assert [text.get_text() for text in ax.get_legend().get_texts()] == ["FairTen1", "Other"]
    assert np.allclose(ax.get_lines()[0].get_xdata(), [0.1, 0.2, 0.3])


def test_time_history_plot_ylabel_with_and_without_unit(tmp_path, plt):
    table = _bare_history(tmp_path)
    assert table.plot("FairTen1").get_ylabel() == "FairTen1 [N]"
    assert table.plot("Other").get_ylabel() == "Other"


def test_time_history_plot_with_no_data_channels(tmp_path, plt):
    table = read_output(_write(tmp_path / "t.out", "Time(s)\n0\n1\n"))
    assert isinstance(table, TimeHistory)
    ax = table.plot()
    assert ax.get_lines() == []
    assert ax.get_ylabel() == ""
    assert ax.get_legend() is None


def test_line_node_geometry_planes(tmp_path, plt):
    table = _out_of_plane_positions(tmp_path)
    with pytest.raises(ValueError, match="plane must be 'xy', 'xz', 'yz', or '3d'"):
        table.plot_geometry(0.0, plane="xx")
    ax3 = table.plot_geometry(1.0, plane="3D")
    assert ax3.name == "3d"
    assert (ax3.get_xlabel(), ax3.get_ylabel(), ax3.get_zlabel()) == ("X [m]", "Y [m]", "Z [m]")
    assert ax3.get_title() == "t = 1 s"
    _, given = plt.subplots()
    ax = table.plot_geometry(0.0, plane="yz", ax=given)
    assert ax is given
    assert (ax.get_xlabel(), ax.get_ylabel()) == ("Y [m]", "Z [m]")
    assert np.allclose(ax.get_lines()[0].get_xdata(), [0.0, 4.0])
    assert np.allclose(ax.get_lines()[0].get_ydata(), [-1.0, -5.0])


def test_segment_plots_on_given_axes(tmp_path, plt):
    table = _line_tensions(tmp_path)
    _, given = plt.subplots()
    ax = table.plot_range(0.5, ax=given)
    assert ax is given
    assert ax.get_ylabel() == "Tension [N]"
    assert ax.get_title() == "t = 0.5 s"
    assert np.allclose(ax.get_lines()[0].get_ydata(), [200.0, 400.0])
    _, other = plt.subplots()
    envelope = table.plot_envelope(1.0, 2.0, ax=other)
    assert envelope is other
    assert np.allclose(envelope.get_lines()[0].get_ydata(), [400.0, 500.0])
    assert [text.get_text() for text in envelope.get_legend().get_texts()] == ["min-max", "mean"]


def test_static_plot_every_line_on_given_axes(tmp_path, plt):
    table = _bare_profile(tmp_path)
    _, given = plt.subplots()
    ax = table.plot("Tension", x="X", ax=given)
    assert ax is given
    assert ax.get_xlabel() == "X"
    assert ax.get_ylabel() == "Tension"
    assert [text.get_text() for text in ax.get_legend().get_texts()] == ["Line 1", "Line 2"]
    single = table.plot("Tension", line_id=2)
    assert single.get_legend() is None
    assert np.allclose(single.get_lines()[0].get_ydata(), [200.0, 240.0])


def test_static_plot_labels_units_from_the_units_row(tmp_path, plt):
    table = read_output(
        _write(
            tmp_path / "u.static.out",
            "LineID Node ArcLength Tension\n(-) (-) (m) (kN)\n1 1 0 5\n1 2 1 6\n",
        )
    )
    ax = table.plot("Tension")
    assert (ax.get_xlabel(), ax.get_ylabel()) == ("ArcLength [m]", "Tension [kN]")


def test_static_geometry_planes(tmp_path, plt):
    table = _bare_profile(tmp_path)
    with pytest.raises(ValueError, match="plane must be 'xy', 'xz', 'yz', or '3d'"):
        table.plot_geometry(plane="zz")
    ax3 = table.plot_geometry(plane="3d")
    assert ax3.name == "3d"
    assert (ax3.get_xlabel(), ax3.get_ylabel(), ax3.get_zlabel()) == ("X [m]", "Y [m]", "Z [m]")
    assert [text.get_text() for text in ax3.get_legend().get_texts()] == ["Line 1", "Line 2"]
    _, given = plt.subplots()
    ax = table.plot_geometry(plane="xy", line_id=1, ax=given)
    assert ax is given
    assert (ax.get_xlabel(), ax.get_ylabel()) == ("X [m]", "Y [m]")
    assert ax.get_legend() is None
    assert np.allclose(ax.get_lines()[0].get_xdata(), [0.0, 2.0])
