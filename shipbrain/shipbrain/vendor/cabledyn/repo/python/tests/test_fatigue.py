# SPDX-License-Identifier: Apache-2.0
"""Rainflow counting, damage-equivalent ranges, and fatigue result objects."""

from __future__ import annotations

import csv
import math
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    FatigueResult,
    LineSegmentHistory,
    RainflowCycle,
    RainflowHistogram,
    TimeHistory,
    cycle_histogram,
    damage_equivalent_range,
    rainflow_cycles,
    read_output,
)
from cabledyn import fatigue as fatigue_module

ASTM_REVERSALS = [-2, 1, -3, 5, -1, 3, -4, 4, -3, 1, -2, 3, 2, 6]
ASTM_CYCLES = (
    (0.5, 3.0, -0.5, 0, 1),
    (0.5, 4.0, -1.0, 1, 2),
    (1.0, 4.0, 1.0, 4, 5),
    (0.5, 8.0, 1.0, 2, 3),
    (1.0, 3.0, -0.5, 9, 10),
    (1.0, 1.0, 2.5, 11, 12),
    (1.0, 7.0, 0.5, 7, 8),
    (0.5, 9.0, 0.5, 3, 6),
    (0.5, 10.0, 1.0, 6, 13),
)


def _fatigue_history(tmp_path) -> TimeHistory:
    path = tmp_path / "fatigue.out"
    rows = "\n".join(f"{index} {value}" for index, value in enumerate(ASTM_REVERSALS))
    path.write_text(f"Time(s) FairTen1\n(s) (N)\n{rows}\n", encoding="ascii")
    result = read_output(path)
    assert isinstance(result, TimeHistory)
    return result


def _result(
    tmp_path: Path,
    *,
    timed: bool = True,
    unit: str | None = "N",
    bins: int | list[float] | None = None,
) -> FatigueResult:
    time = np.arange(len(ASTM_REVERSALS), dtype=np.float64) if timed else None
    cycles = rainflow_cycles(ASTM_REVERSALS, time=time)
    histogram = None if bins is None else cycle_histogram(cycles, bins)
    return FatigueResult(
        channel="FairTen1",
        source=tmp_path / "source.out",
        unit=unit,
        sample_count=len(ASTM_REVERSALS),
        start_time=0.0,
        end_time=13.0,
        duration=13.0,
        wohler_exponent=4.0,
        reference_cycles=13.0,
        equivalent_frequency=1.0,
        cycle_count=6.5,
        damage_equivalent_range=damage_equivalent_range(
            cycles,
            wohler_exponent=4.0,
            reference_cycles=13.0,
        ),
        cycles=cycles,
        histogram=histogram,
    )


def _read_rows(path: Path) -> list[list[str]]:
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.reader(stream))


# ---------------------------------------------------------------------------------- rainflow_cycles


def test_rainflow_matches_published_astm_example() -> None:
    # Reference cycle table: MathWorks ASTM E1049 rainflow documentation.
    cycles = rainflow_cycles(ASTM_REVERSALS)
    actual = tuple(
        (cycle.count, cycle.range, cycle.mean, cycle.start_index, cycle.end_index)
        for cycle in cycles
    )
    assert actual == ASTM_CYCLES


def test_rainflow_preserves_optional_nonuniform_physical_times() -> None:
    cycles = rainflow_cycles([0, 2, 0], time=[10.0, 10.25, 11.0])
    assert [(cycle.start_time, cycle.end_time) for cycle in cycles] == [
        (10.0, 10.25),
        (10.25, 11.0),
    ]
    with pytest.raises(ValueError, match="match"):
        rainflow_cycles([0, 2, 0], time=[0, 1])
    with pytest.raises(ValueError, match="increasing"):
        rainflow_cycles([0, 2, 0], time=[0, 1, 1])


def test_rainflow_handles_plateaus_monotonic_and_constant_histories() -> None:
    cycles = rainflow_cycles([0, 0, 2, 2, 0, 0])
    assert [(item.count, item.range, item.start_index, item.end_index) for item in cycles] == [
        (0.5, 2.0, 0, 3),
        (0.5, 2.0, 3, 5),
    ]
    assert [(item.count, item.range) for item in rainflow_cycles([0, 1, 2])] == [
        (0.5, 2.0),
    ]
    assert rainflow_cycles([7, 7, 7]) == ()
    assert rainflow_cycles(value for value in [0, 2, 0]) == (
        RainflowCycle(2.0, 1.0, 0.5, 0, 1),
        RainflowCycle(2.0, 1.0, 0.5, 1, 2),
    )


def test_rainflow_accepts_numpy_input_and_counts_single_ramp_as_half_cycle() -> None:
    cycles = rainflow_cycles(np.array([1.0, 4.0]), time=np.array([2.0, 2.5]))
    assert cycles == (RainflowCycle(3.0, 2.5, 0.5, 0, 1, 2.0, 2.5),)
    assert rainflow_cycles(np.array([5.0])) == ()


@pytest.mark.parametrize("values", [[], [[0, 1]], [0, float("nan")], [0, float("inf")]])
def test_rainflow_rejects_malformed_histories(values) -> None:
    with pytest.raises(ValueError):
        rainflow_cycles(values)


@pytest.mark.parametrize("values", [["a", "b"], None, [[1.0, 2.0], [3.0]]])
def test_rainflow_rejects_non_numeric_histories(values) -> None:
    with pytest.raises(ValueError, match="non-empty one-dimensional numeric sequence"):
        rainflow_cycles(values)


def test_rainflow_rejects_multidimensional_arrays() -> None:
    with pytest.raises(ValueError, match="non-empty one-dimensional sequence"):
        rainflow_cycles(np.zeros((2, 3)))


@pytest.mark.parametrize(
    ("time", "message"),
    [
        (["a", "b", "c"], "finite one-dimensional sequence"),
        (5.0, "finite one-dimensional sequence"),
        ([0.0, math.nan, 2.0], "finite and match"),
        (np.arange(6.0).reshape(3, 2), "finite and match"),
        ([0.0, 2.0, 1.0], "strictly increasing"),
    ],
)
def test_rainflow_rejects_malformed_time(time, message) -> None:
    with pytest.raises(ValueError, match=message):
        rainflow_cycles([0.0, 2.0, 0.0], time=time)


# ------------------------------------------------------------------------------------ RainflowCycle


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"range": True}, "must be numeric"),
        ({"count": False}, "must be numeric"),
        ({"range": math.nan}, "must be finite"),
        ({"mean": math.inf}, "must be finite"),
        ({"range": 0.0}, "range must be positive"),
        ({"range": -1.0}, "range must be positive"),
        ({"count": 0.25}, r"count must be 0\.5 or 1\.0"),
        ({"count": 2.0}, r"count must be 0\.5 or 1\.0"),
        ({"start_index": 1.5}, "start_index must be a non-negative integer"),
        ({"start_index": True}, "start_index must be a non-negative integer"),
        ({"start_index": -1}, "start_index must be a non-negative integer"),
        ({"end_index": "2"}, "end_index must be a non-negative integer"),
        ({"end_index": 0}, "end_index must be greater than start_index"),
        ({"start_index": 3, "end_index": 3}, "end_index must be greater than start_index"),
        ({"start_time": 0.0}, "supplied together"),
        ({"end_time": 1.0}, "supplied together"),
        ({"start_time": math.nan, "end_time": 1.0}, "cycle times must be finite"),
        ({"start_time": 0.0, "end_time": math.inf}, "cycle times must be finite"),
        ({"start_time": 2.0, "end_time": 2.0}, "end_time must be greater than start_time"),
        ({"start_time": 3.0, "end_time": 2.0}, "end_time must be greater than start_time"),
    ],
)
def test_rainflow_cycle_rejects_invalid_fields(kwargs, message) -> None:
    fields = {"range": 2.0, "mean": 1.0, "count": 1.0, "start_index": 0, "end_index": 1}
    fields.update(kwargs)
    with pytest.raises(ValueError, match=message):
        RainflowCycle(**fields)


def test_rainflow_cycle_normalizes_numpy_scalars_to_python_types() -> None:
    cycle = RainflowCycle(
        np.float32(2.5),
        np.int64(-1),
        1,
        np.int64(3),
        np.int32(7),
        np.float64(0.5),
        1,
    )
    assert cycle == RainflowCycle(2.5, -1.0, 1.0, 3, 7, 0.5, 1.0)
    for name, kind in (
        ("range", float),
        ("mean", float),
        ("count", float),
        ("start_index", int),
        ("end_index", int),
        ("start_time", float),
        ("end_time", float),
    ):
        assert type(getattr(cycle, name)) is kind


# ------------------------------------------------------------ cycle_histogram and RainflowHistogram


def test_weighted_cycle_histogram_is_complete_and_immutable() -> None:
    cycles = rainflow_cycles(ASTM_REVERSALS)
    histogram = cycle_histogram(cycles, 5)
    assert histogram.total_cycles == sum(cycle.count for cycle in cycles)
    assert histogram.bin_edges[0] == 0.0
    assert histogram.bin_edges[-1] == 10.0
    assert not histogram.counts.flags.writeable
    with pytest.raises(ValueError):
        histogram.counts[0] = 1.0
    with pytest.raises(ValueError, match="span"):
        cycle_histogram(cycles, [0.0, 5.0])
    with pytest.raises(ValueError, match="empty"):
        cycle_histogram((), 5)
    empty = cycle_histogram((), [0.0, 1.0, 2.0])
    assert np.array_equal(empty.counts, [0.0, 0.0])
    with pytest.raises(ValueError, match="positive integer or finite"):
        cycle_histogram(cycles, 2.5)


def test_cycle_histogram_explicit_edges_give_hand_counted_weights() -> None:
    # ASTM ranges (weight): 3(.5) 4(.5) 4(1) 8(.5) 3(1) 1(1) 7(1) 9(.5) 10(.5).
    histogram = cycle_histogram(rainflow_cycles(ASTM_REVERSALS), np.array([0.0, 5.0, 10.0]))
    assert np.array_equal(histogram.counts, [4.0, 2.5])
    assert histogram.total_cycles == 6.5
    counted = cycle_histogram(rainflow_cycles(ASTM_REVERSALS), np.int64(2))
    assert np.array_equal(counted.bin_edges, [0.0, 5.0, 10.0])
    assert np.array_equal(counted.counts, histogram.counts)


@pytest.mark.parametrize(
    ("bins", "message"),
    [
        (True, "positive integer or finite edge sequence"),
        (None, "positive integer or finite edge sequence"),
        ("ab", "positive integer or finite edge sequence"),
        ([1.0], "at least two finite values"),
        ([[0.0, 5.0], [5.0, 10.0]], "at least two finite values"),
        ([0.0, math.nan], "at least two finite values"),
        ([0.0, 5.0, 5.0, 10.0], "strictly increasing"),
        ([2.0, 20.0], "span every cycle range"),
        ([0.0, 9.5], "span every cycle range"),
        (0, "bins must be a positive integer"),
        (-3, "bins must be a positive integer"),
    ],
)
def test_cycle_histogram_rejects_invalid_bins(bins, message) -> None:
    with pytest.raises(ValueError, match=message):
        cycle_histogram(rainflow_cycles(ASTM_REVERSALS), bins)


def test_cycle_histogram_rejects_foreign_cycle_objects() -> None:
    with pytest.raises(ValueError, match="RainflowCycle values"):
        cycle_histogram([object()], 3)


@pytest.mark.parametrize(
    ("edges", "counts", "message"),
    [
        ([0.0], [], "at least two finite"),
        ([[0.0, 1.0], [1.0, 2.0]], [1.0], "at least two finite"),
        ([0.0, math.nan], [1.0], "at least two finite"),
        ([0.0, math.inf], [1.0], "at least two finite"),
        ([0.0, 1.0, 1.0], [1.0, 1.0], "strictly increasing"),
        ([2.0, 1.0], [1.0], "strictly increasing"),
        ([0.0, 1.0, 2.0], [1.0], "one value per bin"),
        ([0.0, 1.0], [[1.0]], "one value per bin"),
        ([0.0, 1.0], [math.nan], "one value per bin"),
        ([0.0, 1.0, 2.0], [1.0, -0.5], "must be non-negative"),
    ],
)
def test_rainflow_histogram_rejects_malformed_arrays(edges, counts, message) -> None:
    with pytest.raises(ValueError, match=message):
        RainflowHistogram(edges, counts)


def test_rainflow_histogram_copies_inputs_and_exposes_readonly_centres() -> None:
    edges = np.array([0.0, 2.0, 6.0])
    counts = np.array([1.5, 0.5])
    histogram = RainflowHistogram(edges, counts)
    edges[0] = -10.0
    counts[0] = 99.0
    assert np.array_equal(histogram.bin_edges, [0.0, 2.0, 6.0])
    assert np.array_equal(histogram.counts, [1.5, 0.5])
    centres = histogram.bin_centers
    assert np.array_equal(centres, [1.0, 4.0])
    assert not centres.flags.writeable
    assert histogram.total_cycles == 2.0
    assert type(histogram.total_cycles) is float


# -------------------------------------------------------------------------- damage_equivalent_range


def test_damage_equivalent_range_uses_exact_weighted_ranges() -> None:
    cycles = rainflow_cycles(ASTM_REVERSALS)
    exponent = 4.0
    reference = 13.0
    expected = (sum(cycle.count * cycle.range**exponent for cycle in cycles) / reference) ** (
        1.0 / exponent
    )
    assert damage_equivalent_range(
        cycles,
        wohler_exponent=exponent,
        reference_cycles=reference,
    ) == pytest.approx(expected)
    assert (
        damage_equivalent_range(
            (),
            wohler_exponent=exponent,
            reference_cycles=reference,
        )
        == 0.0
    )
    with pytest.raises(ValueError, match="numeric"):
        damage_equivalent_range(cycles, wohler_exponent=True, reference_cycles=reference)
    with pytest.raises(ValueError, match="positive"):
        damage_equivalent_range(cycles, wohler_exponent=exponent, reference_cycles=0.0)


def test_damage_equivalent_range_rejects_foreign_cycles_and_matches_closed_form() -> None:
    with pytest.raises(ValueError, match="RainflowCycle values"):
        damage_equivalent_range([object()], wohler_exponent=3.0, reference_cycles=1.0)
    cycles = [RainflowCycle(2.0, 0.0, 1.0, 0, 1), RainflowCycle(4.0, 0.0, 0.5, 1, 2)]
    # (1 * 2**3 + 0.5 * 4**3) / 2 = 20.
    assert damage_equivalent_range(
        iter(cycles),
        wohler_exponent=3.0,
        reference_cycles=2.0,
    ) == pytest.approx(20.0 ** (1.0 / 3.0), rel=1.0e-15)


def test_damage_equivalent_range_is_scaled_to_avoid_overflow() -> None:
    cycles = (RainflowCycle(1.0e200, 0.0, 1.0, 0, 1),)
    result = damage_equivalent_range(
        cycles,
        wohler_exponent=10.0,
        reference_cycles=1.0,
    )
    assert math.isfinite(result)
    assert result == pytest.approx(1.0e200)


@pytest.mark.parametrize(
    ("exponent", "reference", "message"),
    [
        (4.0, True, "must be numeric"),
        (math.nan, 1.0, "wohler_exponent must be finite and positive"),
        (math.inf, 1.0, "wohler_exponent must be finite and positive"),
        (0.0, 1.0, "wohler_exponent must be finite and positive"),
        (-3.0, 1.0, "wohler_exponent must be finite and positive"),
        (4.0, math.inf, "reference_cycles must be finite and positive"),
        (4.0, math.nan, "reference_cycles must be finite and positive"),
        (4.0, -1.0, "reference_cycles must be finite and positive"),
    ],
)
def test_damage_equivalent_range_rejects_invalid_parameters(exponent, reference, message) -> None:
    with pytest.raises(ValueError, match=message):
        damage_equivalent_range(
            rainflow_cycles(ASTM_REVERSALS),
            wohler_exponent=exponent,
            reference_cycles=reference,
        )


# ------------------------------------------------------------------------------ TimeHistory.fatigue


def test_time_history_fatigue_requires_explicit_reference_and_preserves_units(tmp_path) -> None:
    history = _fatigue_history(tmp_path)
    result = history.fatigue(
        "FairTen1",
        wohler_exponent=4.0,
        reference_frequency=1.0,
        bins=5,
    )
    assert result.channel == "FairTen1"
    assert result.source == history.path
    assert result.unit == "N"
    assert result.sample_count == 14
    assert result.start_time == 0.0
    assert result.end_time == 13.0
    assert result.duration == 13.0
    assert result.reference_cycles == 13.0
    assert result.equivalent_frequency == 1.0
    assert result.cycle_count == 6.5
    assert result.histogram is not None
    direct = history.fatigue(
        "FairTen1",
        wohler_exponent=4.0,
        reference_cycles=13.0,
    )
    assert direct.damage_equivalent_range == pytest.approx(result.damage_equivalent_range)
    with pytest.raises(ValueError, match="exactly one"):
        history.fatigue("FairTen1", wohler_exponent=4.0)
    with pytest.raises(ValueError, match="exactly one"):
        history.fatigue(
            "FairTen1",
            wohler_exponent=4.0,
            reference_cycles=13.0,
            reference_frequency=1.0,
        )
    with pytest.raises(ValueError, match="non-time"):
        history.fatigue("Time(s)", wohler_exponent=4.0, reference_cycles=13.0)
    with pytest.raises(ValueError, match="wohler_exponent"):
        history.fatigue("FairTen1", wohler_exponent=True, reference_cycles=13.0)
    with pytest.raises(ValueError, match="at least two"):
        history.fatigue(
            "FairTen1",
            start=1.0,
            stop=1.0,
            wohler_exponent=4.0,
            reference_cycles=1.0,
        )


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"reference_frequency": True}, "reference_frequency must be finite and positive"),
        ({"reference_frequency": 0.0}, "reference_frequency must be finite and positive"),
        ({"reference_frequency": math.nan}, "reference_frequency must be finite and positive"),
        ({"reference_cycles": True}, "reference_cycles must be finite and positive"),
        ({"reference_cycles": -1.0}, "reference_cycles must be finite and positive"),
        ({"reference_cycles": math.inf}, "reference_cycles must be finite and positive"),
    ],
)
def test_time_history_fatigue_rejects_invalid_reference_settings(
    tmp_path,
    kwargs,
    message,
) -> None:
    with pytest.raises(ValueError, match=message):
        _fatigue_history(tmp_path).fatigue("FairTen1", wohler_exponent=3.0, **kwargs)


def test_reference_frequency_is_converted_with_the_selected_duration(tmp_path) -> None:
    result = _fatigue_history(tmp_path).fatigue(
        "FairTen1",
        wohler_exponent=3.0,
        reference_frequency=10.0,
        start=0.0,
        stop=2.0,
    )
    assert result.duration == 2.0
    assert result.reference_cycles == 20.0
    assert result.equivalent_frequency == 10.0
    assert result.sample_count == 3
    assert result.unit == "N"


def test_constant_history_has_zero_del_without_inventing_cycles_or_bins(tmp_path) -> None:
    path = tmp_path / "constant.out"
    path.write_text(
        "Time(s) FairTen1\n(s) (N)\n0 10\n1 10\n2 10\n",
        encoding="ascii",
    )
    history = read_output(path)
    assert isinstance(history, TimeHistory)
    result = history.fatigue(
        "FairTen1",
        wohler_exponent=3.0,
        reference_frequency=1.0,
    )
    assert result.cycles == ()
    assert result.cycle_count == 0.0
    assert result.damage_equivalent_range == 0.0
    assert result.histogram is None
    with pytest.raises(ValueError, match="empty"):
        history.fatigue(
            "FairTen1",
            wohler_exponent=3.0,
            reference_frequency=1.0,
            bins=4,
        )


def test_dynamic_line_segment_channels_support_distributed_fatigue(tmp_path) -> None:
    path = tmp_path / "case.Line4.t.out"
    path.write_text(
        "Time(s) Segment1Tension(N) Segment2Tension(N)\n0 100 200\n1 300 400\n2 100 200\n",
        encoding="ascii",
    )
    history = read_output(path)
    assert isinstance(history, LineSegmentHistory)
    fatigue = history.fatigue(
        "Segment2Tension(N)",
        wohler_exponent=3.0,
        reference_cycles=1.0,
    )
    assert fatigue.unit == "N"
    assert fatigue.damage_equivalent_range == pytest.approx(200.0)


# ------------------------------------------------------------------------------------ FatigueResult


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"channel": ""}, "channel must be a non-empty string"),
        ({"channel": 3}, "channel must be a non-empty string"),
        ({"unit": 5}, "unit must be a string or None"),
        ({"sample_count": 2.5}, "sample_count must be an integer of at least two"),
        ({"sample_count": True}, "sample_count must be an integer of at least two"),
        ({"sample_count": 1}, "sample_count must be an integer of at least two"),
        ({"duration": True}, "fatigue scalar values must be numeric"),
        ({"damage_equivalent_range": False}, "fatigue scalar values must be numeric"),
        ({"start_time": math.inf}, "start_time must be finite"),
        ({"damage_equivalent_range": math.nan}, "damage_equivalent_range must be finite"),
        ({"duration": 0.0}, "duration and wohler_exponent must be positive"),
        ({"wohler_exponent": -4.0}, "duration and wohler_exponent must be positive"),
        ({"end_time": 12.0}, "start_time/end_time must define the reported duration"),
        (
            {"start_time": 13.0, "end_time": 0.0},
            "start_time/end_time must define the reported duration",
        ),
        ({"reference_cycles": 0.0}, "reference_cycles and equivalent_frequency must be positive"),
        (
            {"equivalent_frequency": -1.0},
            "reference_cycles and equivalent_frequency must be positive",
        ),
        ({"cycle_count": -1.0}, "cycle_count and damage_equivalent_range must be non-negative"),
        (
            {"damage_equivalent_range": -1.0},
            "cycle_count and damage_equivalent_range must be non-negative",
        ),
        ({"cycle_count": 6.0}, "cycle_count must equal the sum"),
        ({"histogram": "bins"}, "histogram must be a RainflowHistogram or None"),
    ],
)
def test_fatigue_result_rejects_inconsistent_fields(tmp_path, changes, message) -> None:
    base = _result(tmp_path, bins=5)
    with pytest.raises(ValueError, match=message):
        replace(base, **changes)


def test_fatigue_result_rejects_foreign_mixed_or_incomplete_cycle_sets(tmp_path) -> None:
    timed = _result(tmp_path)
    untimed = _result(tmp_path, timed=False)
    with pytest.raises(ValueError, match="RainflowCycle values"):
        replace(timed, cycles=(*timed.cycles[:-1], "cycle"))
    mixed = (timed.cycles[0], untimed.cycles[1])
    with pytest.raises(ValueError, match="one consistent time-coordinate convention"):
        replace(timed, cycles=mixed, cycle_count=1.0)
    partial = cycle_histogram(timed.cycles[:3], [0.0, 10.0])
    with pytest.raises(ValueError, match="histogram must contain every counted cycle"):
        replace(timed, histogram=partial)


def test_fatigue_result_normalizes_source_counts_and_cycle_container(tmp_path) -> None:
    base = _result(tmp_path)
    normalized = replace(
        base,
        source=str(tmp_path / "sub" / ".." / "source.out"),
        sample_count=np.int64(14),
        cycles=list(base.cycles),
    )
    assert normalized.source == (tmp_path / "source.out").resolve()
    assert type(normalized.sample_count) is int
    assert isinstance(normalized.cycles, tuple)
    assert normalized.cycles == base.cycles


# -------------------------------------------------------------------------------- exports and plots


def test_fatigue_histogram_export_and_plot(tmp_path, plt) -> None:
    result = _fatigue_history(tmp_path).fatigue(
        "FairTen1",
        wohler_exponent=3.0,
        reference_frequency=1.0,
        bins=4,
    )
    target = result.export_histogram(tmp_path / "cycles.csv")
    with target.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    assert len(rows) == 4
    assert sum(float(row["count_[-]"]) for row in rows) == result.cycle_count
    assert "range_center_[N]" in rows[0]
    exact = result.export_cycles(tmp_path / "exact_cycles.csv")
    with exact.open(newline="", encoding="utf-8") as stream:
        cycle_rows = list(csv.DictReader(stream))
    assert len(cycle_rows) == len(result.cycles)
    assert cycle_rows[0]["range_[N]"] == "3"
    assert cycle_rows[0]["count_[-]"] == "0.5"
    assert cycle_rows[0]["start_time_[s]"] == "0"
    assert cycle_rows[0]["end_time_[s]"] == "1"
    assert result.plot_histogram().get_ylabel() == "Cycle count [-]"
    with pytest.raises(FileExistsError):
        result.export_histogram(target)
    original = result.source.read_bytes()
    with pytest.raises(ValueError, match="source result"):
        result.export_cycles(result.source, overwrite=True)
    with pytest.raises(ValueError, match="source result"):
        result.export_histogram(result.source, overwrite=True)
    assert result.source.read_bytes() == original


def test_histogram_methods_require_a_histogram(tmp_path) -> None:
    result = _result(tmp_path)
    assert result.histogram is None
    with pytest.raises(ValueError, match="no histogram"):
        result.plot_histogram()
    with pytest.raises(ValueError, match="no histogram"):
        result.export_histogram(tmp_path / "histogram.csv")
    assert not (tmp_path / "histogram.csv").exists()


def test_export_histogram_writes_exact_rows_and_honours_overwrite(tmp_path) -> None:
    result = _result(tmp_path, unit=None, bins=[0.0, 5.0, 10.0])
    target = tmp_path / "nested" / "dir" / "histogram.csv"
    assert result.export_histogram(target) == target.resolve()
    assert _read_rows(target) == [
        ["range_lower", "range_upper", "range_center", "count_[-]"],
        ["0", "5", "2.5", "4"],
        ["5", "10", "7.5", "2.5"],
    ]
    target.write_text("stale\n", encoding="utf-8")
    with pytest.raises(FileExistsError, match="already exists"):
        result.export_histogram(target)
    assert target.read_text(encoding="utf-8") == "stale\n"
    result.export_histogram(target, overwrite=True)
    assert _read_rows(target)[1] == ["0", "5", "2.5", "4"]


def test_export_cycles_without_times_or_unit_omits_time_columns(tmp_path) -> None:
    result = _result(tmp_path, timed=False, unit=None)
    target = result.export_cycles(tmp_path / "cycles.csv")
    rows = _read_rows(target)
    assert rows[0] == ["count_[-]", "range", "mean", "start_index_[-]", "end_index_[-]"]
    assert rows[1:3] == [["0.5", "3", "-0.5", "0", "1"], ["0.5", "4", "-1", "1", "2"]]
    assert len(rows) == 1 + len(result.cycles)
    with pytest.raises(FileExistsError, match="already exists"):
        result.export_cycles(target)
    result.export_cycles(target, overwrite=True)
    assert _read_rows(target) == rows


def test_export_cycles_with_no_cycles_writes_only_the_untimed_header(tmp_path) -> None:
    empty = replace(_result(tmp_path), cycles=(), cycle_count=0.0, damage_equivalent_range=0.0)
    target = empty.export_cycles(tmp_path / "empty.csv")
    assert _read_rows(target) == [
        ["count_[-]", "range_[N]", "mean_[N]", "start_index_[-]", "end_index_[-]"],
    ]


@pytest.mark.parametrize("method", ["export_cycles", "export_histogram"])
def test_failed_export_removes_temporary_and_keeps_existing_target(
    tmp_path,
    monkeypatch,
    method,
) -> None:
    result = _result(tmp_path, bins=5)
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    target = out_dir / "result.csv"
    target.write_text("original\n", encoding="utf-8")

    def refuse(*_args, **_kwargs):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(fatigue_module.os, "replace", refuse)
    with pytest.raises(OSError, match="simulated replace failure"):
        getattr(result, method)(target, overwrite=True)
    monkeypatch.undo()
    assert target.read_text(encoding="utf-8") == "original\n"
    assert sorted(path.name for path in out_dir.iterdir()) == ["result.csv"]


def test_plot_histogram_draws_weighted_bars_on_supplied_axes(tmp_path, plt) -> None:
    result = _result(tmp_path, unit=None, bins=[0.0, 5.0, 10.0])
    figure, ax = plt.subplots()
    try:
        assert result.plot_histogram(ax=ax) is ax
        assert ax.get_xlabel() == "Cycle range"
        assert ax.get_ylabel() == "Cycle count [-]"
        heights = [patch.get_height() for patch in ax.patches]
        widths = [patch.get_width() for patch in ax.patches]
        lefts = [patch.get_x() for patch in ax.patches]
        assert heights == [4.0, 2.5]
        assert widths == [5.0, 5.0]
        assert lefts == [0.0, 5.0]
    finally:
        plt.close(figure)

    with_unit = _result(tmp_path, bins=5)
    ax = with_unit.plot_histogram()
    try:
        assert ax.get_xlabel() == "Cycle range [N]"
        assert sum(patch.get_height() for patch in ax.patches) == pytest.approx(6.5)
    finally:
        plt.close(ax.figure)
