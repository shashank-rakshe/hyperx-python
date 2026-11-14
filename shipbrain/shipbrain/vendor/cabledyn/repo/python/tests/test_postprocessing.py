# SPDX-License-Identifier: Apache-2.0
"""Comparison, filtering, extreme-value, geometry, and sweep utilities."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    GumbelFit,
    LineNodeHistory,
    StaticProfile,
    TimeHistory,
    WeibullFit,
    block_maxima,
    compare_histories,
    fft_filter,
    fit_gumbel,
    fit_weibull,
    generate_deck_cases,
    line_geometry,
    moving_average,
    parameter_grid,
    resample,
    upcrossing_maxima,
)
from cabledyn.formats import read_moordyn_line

ROOT = Path(__file__).resolve().parents[2]


def _history(
    time, columns: dict[str, np.ndarray], *, units=None, path: str = "run.out"
) -> TimeHistory:
    channels = ("Time(s)", *columns)
    values = np.column_stack([time, *columns.values()])
    return TimeHistory(Path(path), "", channels, units, values)


# ---------------------------------------------------------------------------
# compare_histories
# ---------------------------------------------------------------------------


def test_identical_grids_give_exact_metrics():
    time = np.linspace(0.0, 10.0, 101)
    reference = _history(time, {"FairTen1": 100.0 + np.sin(time), "Other": np.cos(time)})
    candidate = _history(
        time, {"FairTen1": 101.0 + np.sin(time), "Other": np.cos(time)}, path="b.out"
    )
    result = compare_histories(reference, candidate, percentile=50.0)
    tension = result.channel("FairTen1")
    assert tension.count == 101
    assert tension.max_abs_difference == pytest.approx(1.0)
    assert tension.mean_difference == pytest.approx(1.0)
    assert tension.rms_difference == pytest.approx(1.0)
    assert tension.normalized_rms_difference == pytest.approx(1.0 / np.std(np.sin(time)))
    assert tension.correlation == pytest.approx(1.0)
    assert tension.maximum_delta == pytest.approx(1.0)
    assert tension.percentile_delta == pytest.approx(1.0)
    other = result.channel("Other")
    assert other.max_abs_difference == 0.0
    assert result.worst(1)[0].channel == "FairTen1"
    assert (result.start_time, result.end_time) == (0.0, 10.0)
    with pytest.raises(KeyError, match="was not compared"):
        result.channel("Missing")


def test_candidate_is_interpolated_onto_the_reference_overlap_without_extrapolation():
    reference = _history(np.linspace(0.0, 10.0, 11), {"A": np.linspace(0.0, 10.0, 11)})
    candidate = _history(
        np.linspace(2.0, 12.0, 21), {"A": np.linspace(2.0, 12.0, 21)}, path="b.out"
    )
    result = compare_histories(reference, candidate)
    assert np.array_equal(result.time, np.arange(2.0, 11.0))
    assert result.channel("A").max_abs_difference == pytest.approx(0.0, abs=1e-12)
    reverse = compare_histories(reference, candidate, grid="candidate", start=3.0, stop=5.0)
    assert np.allclose(reverse.time, np.arange(3.0, 5.01, 0.5))
    assert not result.time.flags.writeable


def test_channel_mapping_units_and_constant_signals():
    time = np.linspace(0.0, 1.0, 5)
    reference = _history(time, {"FairTen1": np.full(5, 2.0)}, units=("(s)", "(N)"))
    candidate = _history(time, {"FAIRTEN1": np.full(5, 3.0)}, units=("(s)", "N"), path="md.out")
    result = compare_histories(reference, candidate, channels={"FairTen1": "FAIRTEN1"})
    item = result.channel("FairTen1")
    assert item.candidate_channel == "FAIRTEN1"
    assert item.unit == "N"
    assert math.isnan(item.correlation)
    assert math.isnan(item.normalized_rms_difference)
    assert item.relative_max_difference == pytest.approx(0.5)
    wrong = _history(time, {"FAIRTEN1": np.full(5, 3.0)}, units=("(s)", "(kN)"))
    with pytest.raises(ValueError, match="unit mismatch"):
        compare_histories(reference, wrong, channels={"FairTen1": "FAIRTEN1"})
    assert (
        compare_histories(reference, wrong, channels={"FairTen1": "FAIRTEN1"}, check_units=False)
        .channel("FairTen1")
        .mean_delta
        == 1.0
    )


@pytest.mark.parametrize(
    ("kwargs", "error", "message"),
    [
        ({"grid": "union"}, ValueError, "grid must be"),
        ({"percentile": 120.0}, ValueError, "percentile"),
        ({"percentile": True}, ValueError, "percentile"),
        ({"start": float("nan")}, ValueError, "start must be finite"),
        ({"channels": []}, ValueError, "must not be empty"),
        ({"channels": ["A", "A"]}, ValueError, "unique"),
        ({"channels": "Time(s)"}, ValueError, "time channel"),
        ({"channels": "Missing"}, KeyError, "Missing"),
        ({"start": 20.0}, ValueError, "do not overlap"),
        ({"start": 9.95}, ValueError, "at least two samples"),
    ],
)
def test_comparison_arguments_are_validated(kwargs, error, message):
    time = np.linspace(0.0, 10.0, 11)
    reference = _history(time, {"A": time})
    with pytest.raises(error, match=message):
        compare_histories(reference, reference, **kwargs)


def test_comparison_requires_histories_and_shared_names(tmp_path):
    time = np.linspace(0.0, 1.0, 3)
    first = _history(time, {"A": time})
    second = _history(time, {"B": time})
    with pytest.raises(TypeError):
        compare_histories(first, "b.out")  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="share no channel names"):
        compare_histories(first, second)
    result = compare_histories(first, second, channels={"A": "B"})
    with pytest.raises(ValueError, match="not a numeric"):
        result.worst(metric="unit")
    with pytest.raises(ValueError, match="positive integer"):
        result.worst(0)


def test_comparison_export_and_worst_ordering(tmp_path):
    time = np.linspace(0.0, 1.0, 11)
    reference = _history(time, {"A": time, "B": np.ones(11), "C": time})
    candidate = _history(
        time, {"A": time + 0.1, "B": np.ones(11) * 2, "C": time + 1.0}, path="b.out"
    )
    result = compare_histories(reference, candidate)
    ranked = result.worst(3)
    assert [item.channel for item in ranked] == ["C", "A", "B"]  # nan (constant B) last
    target = result.export(tmp_path / "compare.csv")
    lines = target.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 4 and lines[0].startswith("channel,candidate_channel,unit,count")
    with pytest.raises(FileExistsError):
        result.export(target)
    result.export(target, overwrite=True)
    with pytest.raises(ValueError, match="compared result"):
        result.export(reference.path)


def test_comparison_export_removes_temporary_on_failure(tmp_path, monkeypatch):
    time = np.linspace(0.0, 1.0, 3)
    result = compare_histories(_history(time, {"A": time}), _history(time, {"A": time}))
    monkeypatch.setattr("cabledyn.compare.os.replace", _raise_os_error)
    with pytest.raises(OSError):
        result.export(tmp_path / "x.csv")
    assert list(tmp_path.iterdir()) == []


def _raise_os_error(*args, **kwargs):
    raise OSError("disk full")


# ---------------------------------------------------------------------------
# resample / moving_average / fft_filter
# ---------------------------------------------------------------------------


def test_resample_uniform_and_explicit_times():
    history = _history(np.array([0.0, 0.3, 1.0, 2.0]), {"A": np.array([0.0, 3.0, 10.0, 20.0])})
    uniform = resample(history, step=0.5)
    assert np.allclose(uniform.time, [0.0, 0.5, 1.0, 1.5, 2.0])
    assert np.allclose(uniform.column("A"), 10.0 * uniform.time)
    window = resample(history, step=0.25, start=0.5, stop=1.0)
    assert np.allclose(window.time, [0.5, 0.75, 1.0])
    explicit = resample(history, times=[0.1, 1.9])
    assert np.allclose(explicit.column("A"), [1.0, 19.0])
    assert type(explicit) is TimeHistory
    assert history.values.shape == (4, 2)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({}, "exactly one"),
        ({"step": 0.1, "times": [0.0]}, "exactly one"),
        ({"step": 0.0}, "finite and positive"),
        ({"step": True}, "finite number"),
        ({"step": 0.1, "start": 1.5, "stop": 1.0}, "must not exceed"),
        ({"step": 0.1, "start": -1.0}, "inside the recorded interval"),
        ({"times": [0.0, 3.0]}, "inside the recorded interval"),
        ({"times": [[0.0]]}, "one-dimensional"),
        ({"times": [1.0, 0.5]}, "strictly increasing"),
        ({"times": [0.5], "start": 0.0}, "only to a uniform step"),
        ({"step": 0.1, "stop": float("inf")}, "finite number"),
    ],
)
def test_resample_arguments_are_validated(kwargs, message):
    history = _history(np.array([0.0, 1.0, 2.0]), {"A": np.array([0.0, 1.0, 2.0])})
    with pytest.raises(ValueError, match=message):
        resample(history, **kwargs)


def test_resample_keeps_specialised_history_types():
    path = Path("run.Line1.p.out")
    history = LineNodeHistory(
        path,
        "",
        ("Time(s)", "Node1X(m)", "Node1Y(m)", "Node1Z(m)"),
        None,
        np.array([[0.0, 0.0, 0.0, 0.0], [1.0, 1.0, 2.0, 3.0]]),
    )
    resampled = resample(history, step=0.5)
    assert isinstance(resampled, LineNodeHistory)
    assert np.allclose(resampled.coordinates(0.5), [[0.5, 1.0, 1.5]])


def test_moving_average_trims_the_half_window_and_leaves_other_channels():
    time = np.arange(0.0, 1.0, 0.1)
    history = _history(time, {"A": np.arange(10.0), "B": np.arange(10.0) ** 2})
    smoothed = moving_average(history, 3, channels="B")
    assert np.allclose(smoothed.time, time[1:-1])
    assert np.allclose(smoothed.column("A"), np.arange(1.0, 9.0))
    expected = [(a * a + (a + 1) ** 2 + (a + 2) ** 2) / 3.0 for a in range(8)]
    assert np.allclose(smoothed.column("B"), expected)
    assert np.allclose(moving_average(history, 1).values, history.values)


@pytest.mark.parametrize(
    ("window", "channels", "message"),
    [
        (2, None, "odd positive"),
        (0, None, "odd positive"),
        (True, None, "odd positive"),
        ("3", None, "odd positive"),
        (11, None, "longer than the record"),
        (3, [], "at least one channel"),
        (3, ["Time(s)"], "time channel"),
    ],
)
def test_moving_average_validation(window, channels, message):
    history = _history(np.arange(0.0, 1.0, 0.1), {"A": np.arange(10.0)})
    with pytest.raises(ValueError, match=message):
        moving_average(history, window, channels=channels)


def test_filters_require_uniform_sampling():
    history = _history(np.array([0.0, 0.1, 0.3, 0.4]), {"A": np.zeros(4)})
    with pytest.raises(ValueError, match="resample"):
        moving_average(history, 3)
    with pytest.raises(ValueError, match="resample"):
        fft_filter(history, high=1.0)
    single = _history(np.array([0.0]), {"A": np.zeros(1)})
    with pytest.raises(ValueError, match="at least two samples"):
        fft_filter(single, high=1.0)


def test_fft_filter_separates_bin_centred_components():
    step, count = 0.1, 400  # 40 s record, 0.025 Hz resolution
    time = step * np.arange(count)
    slow = 2.0 * np.sin(2 * np.pi * 0.1 * time)
    fast = 0.5 * np.sin(2 * np.pi * 2.0 * time)
    trend = 3.0 + 0.05 * time
    periodic = _history(time, {"A": slow + fast, "B": fast})
    low = fft_filter(periodic, high=0.5, channels="A", detrend="none")
    assert np.allclose(low.column("A"), slow, atol=1e-10)
    assert np.array_equal(low.column("B"), periodic.column("B"))
    high = fft_filter(periodic, low=1.0, detrend="none")
    assert np.allclose(high.column("A"), fast, atol=1e-10)
    band = fft_filter(periodic, low=0.05, high=0.5, channels=["B"], detrend="none")
    assert np.allclose(band.column("B"), 0.0, atol=1e-10)
    # A drifting record: the restored linear trend keeps the low-pass result
    # on the slow signal away from the record ends.
    drifting = _history(time, {"A": slow + fast + trend})
    interior = slice(count // 5, -count // 5)
    low_drift = fft_filter(drifting, high=0.5).column("A")
    assert np.max(np.abs(low_drift - slow - trend)[interior]) < 0.05
    high_drift = fft_filter(drifting, low=1.0).column("A")
    assert np.max(np.abs(high_drift - fast)[interior]) < 0.05


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({}, "give low, high"),
        ({"low": -1.0}, "must be positive"),
        ({"low": 2.0, "high": 1.0}, "below high"),
        ({"high": 5.0}, "Nyquist"),
        ({"low": 4.9, "high": 4.95}, "no frequency bins"),
        ({"high": float("nan")}, "finite number"),
        ({"high": 1.0, "detrend": "mean"}, "detrend must be"),
    ],
)
def test_fft_filter_validation(kwargs, message):
    history = _history(0.1 * np.arange(20), {"A": np.arange(20.0)})
    with pytest.raises(ValueError, match=message):
        fft_filter(history, **kwargs)


# ---------------------------------------------------------------------------
# Extremes
# ---------------------------------------------------------------------------


def test_block_maxima_and_minima():
    time = np.arange(0.0, 10.01, 1.0)
    history = _history(time, {"A": np.array([0, 5, 1, 7, 2, 9, 3, 4, 8, 6, 10.0])})
    assert np.array_equal(block_maxima(history, "A", block_duration=5.0), [7.0, 10.0])
    assert np.array_equal(block_maxima(history, "A", block_duration=4.0), [7.0, 9.0])
    assert np.array_equal(block_maxima(history, "A", block_duration=5.0, minima=True), [0.0, 3.0])
    assert np.array_equal(
        block_maxima(history, "A", block_duration=2.0, start=2.0, stop=6.0), [7.0, 9.0]
    )
    with pytest.raises(ValueError, match="shorter than one block"):
        block_maxima(history, "A", block_duration=20.0)
    with pytest.raises(ValueError, match="finite and positive"):
        block_maxima(history, "A", block_duration=0.0)
    with pytest.raises(ValueError, match="non-time"):
        block_maxima(history, "Time(s)", block_duration=1.0)
    sparse = _history(np.array([0.0, 0.1, 5.0]), {"A": np.array([1.0, 2.0, 3.0])})
    with pytest.raises(ValueError, match="contains no samples"):
        block_maxima(sparse, "A", block_duration=1.0)


def test_upcrossing_maxima_counts_complete_cycles():
    time = np.linspace(0.0, 4.0, 401)
    signal = np.sin(2 * np.pi * time) * np.array([1.0 + 0.1 * np.floor(t) for t in time])
    # Up-crossings near t = 1, 2, 3 bound two complete cycles; the partial
    # cycles before the first and after the last crossing are ignored.
    peaks = upcrossing_maxima(signal, level=0.0)
    assert np.allclose(peaks, [1.1, 1.2], atol=1e-3)
    assert np.allclose(upcrossing_maxima(signal + 5.0), [6.1, 6.2], atol=1e-2)
    with pytest.raises(ValueError, match="fewer than two"):
        upcrossing_maxima([0.0, 1.0, 0.0])
    with pytest.raises(ValueError, match="three finite"):
        upcrossing_maxima([0.0, 1.0])
    with pytest.raises(ValueError, match="level must be finite"):
        upcrossing_maxima(signal, level=float("inf"))


def test_gumbel_fits_recover_known_parameters():
    rng = np.random.default_rng(20260924)
    sample = rng.gumbel(loc=5.0e6, scale=2.0e5, size=20000)
    mle = fit_gumbel(sample)
    moments = fit_gumbel(sample, method="moments")
    for fit in (mle, moments):
        assert fit.location == pytest.approx(5.0e6, rel=5e-3)
        assert fit.scale == pytest.approx(2.0e5, rel=3e-2)
        assert fit.sample_count == 20000
    assert mle.method == "mle"
    assert mle.quantile(math.exp(-1.0)) == pytest.approx(mle.location)
    assert mle.cdf(mle.location) == pytest.approx(math.exp(-1.0))
    assert mle.most_probable_maximum() == mle.location
    assert mle.most_probable_maximum(10.0) == pytest.approx(
        mle.location + mle.scale * math.log(10.0)
    )
    assert mle.return_level(100.0) == pytest.approx(mle.quantile(0.99))


def test_gumbel_mle_matches_scipy_when_available():
    stats = pytest.importorskip("scipy.stats")
    sample = np.array([1.2, 2.3, 0.7, 3.1, 1.9, 2.8, 1.4, 2.2, 5.0, 1.1])
    location, scale = stats.gumbel_r.fit(sample)
    fit = fit_gumbel(sample)
    assert fit.location == pytest.approx(location, rel=1e-5)
    assert fit.scale == pytest.approx(scale, rel=1e-5)


def test_weibull_fit_recovers_known_parameters_and_matches_scipy():
    rng = np.random.default_rng(7)
    sample = 3.0e5 * rng.weibull(1.8, size=20000)
    fit = fit_weibull(sample)
    assert fit.shape == pytest.approx(1.8, rel=2e-2)
    assert fit.scale == pytest.approx(3.0e5, rel=2e-2)
    assert fit.quantile(1.0 - math.exp(-1.0)) == pytest.approx(fit.scale)
    assert fit.cdf([-1.0, fit.scale]) == pytest.approx([0.0, 1.0 - math.exp(-1.0)])
    stats = pytest.importorskip("scipy.stats")
    small = sample[:50]
    shape, _, scale = stats.weibull_min.fit(small, floc=0.0)
    reference = fit_weibull(small)
    assert reference.shape == pytest.approx(shape, rel=1e-4)
    assert reference.scale == pytest.approx(scale, rel=1e-4)


@pytest.mark.parametrize(
    ("function", "sample", "message"),
    [
        (fit_gumbel, [1.0], "at least two"),
        (fit_gumbel, [1.0, float("nan")], "at least two finite"),
        (fit_gumbel, [2.0, 2.0, 2.0], "not all equal"),
        (fit_weibull, [1.0, -2.0], "strictly positive"),
    ],
)
def test_fit_inputs_are_validated(function, sample, message):
    with pytest.raises(ValueError, match=message):
        function(sample)


def test_fit_objects_validate_parameters_and_probabilities():
    with pytest.raises(ValueError, match="method"):
        fit_gumbel([1.0, 2.0], method="lmoments")  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        GumbelFit(0.0, 0.0, 2, "mle")
    with pytest.raises(ValueError):
        WeibullFit(-1.0, 1.0, 2)
    fit = GumbelFit(0.0, 1.0, 2, "mle")
    for bad in (0.0, 1.0, True):
        with pytest.raises(ValueError, match="strictly between"):
            fit.quantile(bad)
    with pytest.raises(ValueError, match="at least 1"):
        fit.most_probable_maximum(0.5)
    with pytest.raises(ValueError, match="greater than 1"):
        fit.return_level(1.0)
    with pytest.raises(ValueError, match="strictly between"):
        WeibullFit(1.0, 1.0, 2).quantile(1.0)


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------


def _catenary_like(seabed=-100.0):
    x = np.linspace(0.0, 300.0, 31)
    z = np.where(x < 100.0, seabed, seabed + 0.002 * (x - 100.0) ** 2)
    return np.column_stack((x, np.zeros_like(x), z))


def test_geometry_of_a_circle_arc_and_straight_line():
    angle = np.linspace(0.0, np.pi / 2, 91)
    radius = 50.0
    arc = np.column_stack((radius * np.cos(angle), np.zeros_like(angle), radius * np.sin(angle)))
    geometry = line_geometry(arc)
    assert np.allclose(geometry.curvature[1:-1], 1.0 / radius, rtol=1e-3)
    assert math.isnan(geometry.curvature[0]) and math.isnan(geometry.curvature[-1])
    assert geometry.length == pytest.approx(radius * np.pi / 2, rel=1e-4)
    assert geometry.minimum_bend_radius == pytest.approx(radius, rel=1e-3)
    assert geometry.inclination[0] == pytest.approx(90.0, abs=1.0)
    straight = line_geometry([[0.0, 0.0, 0.0], [3.0, 4.0, 0.0]])
    assert straight.length == 5.0 and straight.horizontal_span == 5.0
    assert straight.vertical_span == 0.0
    assert straight.minimum_bend_radius == math.inf
    assert not geometry.coordinates.flags.writeable


def test_touchdown_from_either_grounded_end(tmp_path):
    geometry = line_geometry(_catenary_like())
    touchdown = geometry.touchdown(-100.0)
    assert touchdown is not None
    assert touchdown.grounded_end == "A"
    assert touchdown.node == 10
    assert touchdown.arc_length == pytest.approx(100.0)
    assert touchdown.grounded_length == pytest.approx(100.0)
    assert touchdown.layback == pytest.approx(200.0)
    assert touchdown.suspended_length == pytest.approx(geometry.length - 100.0)
    reverse = line_geometry(_catenary_like()[::-1]).touchdown(-100.0)
    assert reverse is not None and reverse.grounded_end == "B" and reverse.node == 20
    assert reverse.grounded_length == pytest.approx(100.0)
    assert geometry.touchdown(-200.0) is None
    assert line_geometry([[0, 0, -100.0], [1, 0, -100.0]]).touchdown(-100.0) is None
    target = geometry.export(tmp_path / "geometry.csv")
    rows = target.read_text(encoding="utf-8").splitlines()
    assert rows[0].startswith("Node_[-],ArcLength_[m]") and len(rows) == 32
    with pytest.raises(FileExistsError):
        geometry.export(target)


def test_touchdown_with_both_ends_grounded_needs_an_end():
    xyz = np.column_stack((np.arange(5.0), np.zeros(5), [-10.0, -10.0, -5.0, -10.0, -10.0]))
    geometry = line_geometry(xyz)
    with pytest.raises(ValueError, match="both ends are grounded"):
        geometry.touchdown(-10.0)
    assert geometry.touchdown(-10.0, grounded_end="a").node == 1  # type: ignore[union-attr]
    assert geometry.touchdown(-10.0, grounded_end="B").node == 3  # type: ignore[union-attr]
    with pytest.raises(ValueError, match="'A' or 'B'"):
        geometry.touchdown(-10.0, grounded_end="C")
    with pytest.raises(ValueError, match="tolerance"):
        geometry.touchdown(-10.0, tolerance=-1.0)


def test_geometry_from_result_tables(tmp_path):
    profile = StaticProfile(
        tmp_path / "run.static.out",
        "",
        ("LineID", "Node", "ArcLength", "X", "Y", "Z"),
        None,
        np.array(
            [[1, 1, 0, 0, 0, -10], [1, 2, 5, 3, 0, -6], [2, 1, 0, 0, 0, 0], [2, 2, 1, 1, 0, 0]],
            dtype=float,
        ),
    )
    assert line_geometry(profile, line_id=1).length == pytest.approx(5.0)
    with pytest.raises(ValueError, match="pass line_id"):
        line_geometry(profile)
    with pytest.raises(ValueError, match="time does not apply"):
        line_geometry(profile.line(1), time=0.0)
    single = line_geometry(profile.line(2))
    assert single.length == 1.0
    history = LineNodeHistory(
        tmp_path / "run.Line1.p.out",
        "",
        ("Time(s)", "Node1X(m)", "Node1Y(m)", "Node1Z(m)", "Node2X(m)", "Node2Y(m)", "Node2Z(m)"),
        None,
        np.array([[0.0, 0, 0, 0, 1, 0, 0], [1.0, 0, 0, 0, 3, 0, 0]]),
    )
    assert line_geometry(history, time=0.5).length == pytest.approx(2.0)
    with pytest.raises(ValueError, match="snapshot time"):
        line_geometry(history)
    with pytest.raises(ValueError, match="line_id does not apply"):
        line_geometry(history, line_id=1, time=0.0)
    with pytest.raises(ValueError, match="apply only to result tables"):
        line_geometry([[0, 0, 0], [1, 0, 0]], time=0.0)
    moordyn = tmp_path / "run.MD.Line1.out"
    moordyn.write_text(
        "Time Node0px Node0py Node0pz Node1px Node1py Node1pz\n0 0 0 0 0 0 4\n", encoding="utf-8"
    )
    assert line_geometry(read_moordyn_line(moordyn), time=0.0).vertical_span == 4.0


@pytest.mark.parametrize(
    "xyz",
    [
        [[0.0, 0.0, 0.0]],
        [[0.0, 0.0], [1.0, 1.0]],
        [[0, 0, 0], [0, 0, 0]],
        [[0, 0, 0], [1, 0, float("nan")]],
    ],
)
def test_geometry_rejects_degenerate_coordinates(xyz):
    with pytest.raises(ValueError):
        line_geometry(xyz)


def test_geometry_export_cleans_up_on_failure(tmp_path, monkeypatch):
    geometry = line_geometry([[0, 0, 0], [1, 0, 0]])
    monkeypatch.setattr("cabledyn.geometry.os.replace", _raise_os_error)
    with pytest.raises(OSError):
        geometry.export(tmp_path / "g.csv")
    assert list(tmp_path.iterdir()) == []


# ---------------------------------------------------------------------------
# parameter_grid
# ---------------------------------------------------------------------------


def test_parameter_grid_product_and_zip():
    grid = parameter_grid({"option.dtM": [0.01, 0.02], "option.kBot": [1e5, 2e5, 3e5]})
    assert list(grid) == [f"case{index:03d}" for index in range(6)]
    assert grid["case001"] == {"option.dtM": 0.01, "option.kBot": 2e5}
    paired = parameter_grid({"a": [1, 2], "b": [3, 4]}, mode="zip", prefix="run_")
    assert paired == {"run_000": {"a": 1, "b": 3}, "run_001": {"a": 2, "b": 4}}
    large = parameter_grid({"a": list(range(1500))})
    assert "case1499" in large and "case0000" in large


@pytest.mark.parametrize(
    ("parameters", "kwargs", "message"),
    [
        ({}, {}, "at least one selector"),
        ({"a": []}, {}, "non-empty sequence"),
        ({"a": "12"}, {}, "non-empty sequence"),
        ({"": [1]}, {}, "non-empty strings"),
        ({"a": [1]}, {"prefix": "bad name"}, "prefix"),
        ({"a": [1]}, {"mode": "grid"}, "mode"),
        ({"a": [1], "b": [1, 2]}, {"mode": "zip"}, "equal length"),
    ],
)
def test_parameter_grid_validation(parameters, kwargs, message):
    with pytest.raises(ValueError, match=message):
        parameter_grid(parameters, **kwargs)


def test_parameter_grid_feeds_case_generation(tmp_path):
    cases = parameter_grid({"option.kBot": [1.0e5, 2.0e5]})
    generated = generate_deck_cases(
        ROOT / "examples" / "chain_catenary_r3_100m.dat", tmp_path, cases
    )
    assert [case.name for case in generated] == ["case000", "case001"]
