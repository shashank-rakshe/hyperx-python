# SPDX-License-Identifier: Apache-2.0
"""Line-to-seabed and line-to-line clearance, and the bathymetry reader."""

from __future__ import annotations

import csv
import math
import os
import shutil
from pathlib import Path

import numpy as np
import pytest

from cabledyn import CableDynDriver, read_output, read_range_graph
from cabledyn import clearance as clearance_module
from cabledyn.clearance import (
    Bathymetry,
    ClearanceMatrix,
    LineClearance,
    SeabedClearance,
    clearance_matrix,
    line_clearance,
    read_bathymetry,
    seabed_clearance,
    segment_distance,
)
from cabledyn.profiles import LinePositions, line_positions

TIMES = np.array([0.0, 1.0, 2.0])
NODES = 5
X = 10.0 * np.arange(NODES)


def _frames() -> np.ndarray:
    """Nodes 10 m apart in x; node i (from 0) sits t * i above z = -50."""
    return np.stack(
        [np.column_stack([X, np.zeros(NODES), -50.0 + t * np.arange(NODES)]) for t in TIMES]
    )


def _write_nodes(path: Path, frames: np.ndarray) -> object:
    names = ["Time(s)"] + [
        f"Node{i + 1}{axis}(m)" for i in range(frames.shape[1]) for axis in "XYZ"
    ]
    rows = [
        "\t".join(f"{v:.12E}" for v in (t, *f.ravel())) for t, f in zip(TIMES, frames, strict=True)
    ]
    path.write_text("# positions\n" + "\t".join(names) + "\n" + "\n".join(rows) + "\n")
    return read_output(path)


# --- segment distance -------------------------------------------------------------------------


def test_skew_segments_have_the_analytic_distance():
    distance, s, t = segment_distance([-1, 0, 0], [1, 0, 0], [0, -1, 2], [0, 1, 2])
    assert float(distance) == pytest.approx(2.0)
    assert float(s) == pytest.approx(0.5) and float(t) == pytest.approx(0.5)
    # skew but not crossing within the segments: the closest pair is end point to interior
    distance, s, t = segment_distance([0, 0, 0], [1, 0, 0], [3, -1, 1], [3, 1, 1])
    assert float(distance) == pytest.approx(math.sqrt(4.0 + 1.0))
    assert float(s) == 1.0 and float(t) == pytest.approx(0.5)


@pytest.mark.parametrize(
    ("p2", "q2", "expected"),
    [
        ([0.5, 1.0, 0.0], [2.0, 1.0, 0.0], 1.0),  # parallel, overlapping
        ([3.0, 1.0, 0.0], [4.0, 1.0, 0.0], math.sqrt(4.0 + 1.0)),  # parallel, apart
        ([-2.0, 1.0, 0.0], [-3.0, 5.0, 0.0], math.sqrt(4.0 + 1.0)),  # t clamps at 0
        ([-3.0, 5.0, 0.0], [-2.0, 1.0, 0.0], math.sqrt(4.0 + 1.0)),  # t clamps at 1
        ([0.5, 2.0, 0.0], [0.5, 2.0, 0.0], 2.0),  # second is a point
    ],
)
def test_segment_distance_edge_cases(p2, q2, expected):
    distance, _, _ = segment_distance([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], p2, q2)
    assert float(distance) == pytest.approx(expected)


def test_point_segments():
    distance, s, t = segment_distance([0.5, 2.0, 0.0], [0.5, 2.0, 0.0], [0, 0, 0], [1, 0, 0])
    assert float(distance) == pytest.approx(2.0) and float(s) == 0.0
    assert float(t) == pytest.approx(0.5)
    distance, s, t = segment_distance([0, 0, 0], [0, 0, 0], [3, 4, 0], [3, 4, 0])
    assert float(distance) == pytest.approx(5.0) and float(s) == 0.0 and float(t) == 0.0


def test_segment_distance_matches_a_brute_force_search():
    rng = np.random.default_rng(7)
    p1, q1, p2, q2 = (rng.normal(size=(200, 3)) for _ in range(4))
    distance, s, t = segment_distance(p1, q1, p2, q2)
    grid = np.linspace(0.0, 1.0, 201)
    a = p1[:, None, :] + grid[None, :, None] * (q1 - p1)[:, None, :]
    b = p2[:, None, :] + grid[None, :, None] * (q2 - p2)[:, None, :]
    brute = np.min(np.linalg.norm(a[:, :, None, :] - b[:, None, :, :], axis=3), axis=(1, 2))
    assert np.all(distance <= brute + 1e-12)
    assert np.all(distance >= brute - 0.02)
    closest = np.linalg.norm((p1 + s[:, None] * (q1 - p1)) - (p2 + t[:, None] * (q2 - p2)), axis=1)
    np.testing.assert_allclose(closest, distance, atol=1e-12)
    assert np.all((s >= 0.0) & (s <= 1.0) & (t >= 0.0) & (t <= 1.0))


def test_segment_distance_rejects_bad_points():
    with pytest.raises(ValueError, match="three coordinates"):
        segment_distance([0, 0], [1, 0], [0, 1], [1, 1])
    with pytest.raises(ValueError, match="finite"):
        segment_distance([0, 0, math.nan], [1, 0, 0], [0, 1, 0], [1, 1, 0])


# --- bathymetry --------------------------------------------------------------------------------


def _slope() -> Bathymetry:
    """Depth 50 m at x = 0 deepening 0.1 m per metre in x; flat in y."""
    x = np.array([0.0, 20.0, 50.0])
    y = np.array([-10.0, 10.0])
    return Bathymetry(x, y, np.column_stack([50.0 + 0.1 * x, 50.0 + 0.1 * x]))


def test_bathymetry_is_bilinear_and_clamped_outside_the_grid():
    bathymetry = _slope()
    np.testing.assert_allclose(bathymetry.floor([0.0, 10.0, 35.0], 0.0), [-50.0, -51.0, -53.5])
    np.testing.assert_allclose(bathymetry.depth_at(50.0, 10.0), 55.0)
    # outside the grid the value at the nearest edge is used
    np.testing.assert_allclose(bathymetry.floor([-5.0, 80.0], [0.0, 99.0]), [-50.0, -55.0])
    saddle = Bathymetry([0.0, 1.0], [0.0, 1.0], [[1.0, 2.0], [3.0, 4.0]])
    assert float(saddle.depth_at(0.25, 0.75)) == pytest.approx(
        0.75 * 0.25 * 1.0 + 0.75 * 0.75 * 2.0 + 0.25 * 0.25 * 3.0 + 0.25 * 0.75 * 4.0
    )
    with pytest.raises(ValueError, match="finite"):
        bathymetry.floor(math.nan, 0.0)


def test_bathymetry_rounds_the_creases_of_the_grid_as_the_solver():
    # a crease of slope jump J = -1 at x = 10 (level, then deepening 1 m per metre); the band
    # half-width is 5 % of the smaller spacing, 0.5 m, and the fillet J (delta - |u|)^3/(6 delta^2)
    crease = Bathymetry(
        [0.0, 10.0, 20.0], [0.0, 1.0], [[100.0, 100.0], [100.0, 100.0], [110.0, 110.0]]
    )
    np.testing.assert_allclose(
        crease.depth_at([10.0, 10.2, 9.6, 9.5, 5.0, 10.5], 0.3),
        [100.0 + 0.5 / 6.0, 100.218, 100.0 + 0.001 / 1.5, 100.0, 100.0, 100.5],
        rtol=0.0,
        atol=1e-12,
    )
    # continuous height and slope across the line and at the band edges
    for x0 in (10.0, 9.5, 10.5):
        a, b = crease.depth_at([x0 - 1e-7, x0 + 1e-7], 0.5)
        assert abs(a - b) < 2.1e-7  # the slope there is at most 1
        slope = crease.depth_at([x0 - 2e-4, x0 - 1e-4, x0 + 1e-4, x0 + 2e-4], 0.5)
        assert abs((slope[1] - slope[0]) - (slope[3] - slope[2])) < 1e-6
    # a planar grid (here written to six decimals) is not rounded: bit-identical bilinear
    x = np.array([0.0, 10.0, 25.0, 30.0])
    y = np.array([-5.0, 8.0, 20.0])
    plane = np.round(388.949782 + 0.0732 * x[:, None] - 0.0417 * y[None, :], 6)
    planar = Bathymetry(x, y, plane)
    qx, qy = np.meshgrid(np.linspace(-1.0, 31.0, 97), np.linspace(-6.0, 21.0, 55))
    ix = np.clip(np.searchsorted(x, qx, side="right") - 1, 0, x.size - 2)
    iy = np.clip(np.searchsorted(y, qy, side="right") - 1, 0, y.size - 2)
    tx = np.clip((qx - x[ix]) / (x[ix + 1] - x[ix]), 0.0, 1.0)
    ty = np.clip((qy - y[iy]) / (y[iy + 1] - y[iy]), 0.0, 1.0)
    bilinear = (
        (1.0 - tx) * (1.0 - ty) * plane[ix, iy]
        + tx * (1.0 - ty) * plane[ix + 1, iy]
        + (1.0 - tx) * ty * plane[ix, iy + 1]
        + tx * ty * plane[ix + 1, iy + 1]
    )
    assert np.array_equal(planar.depth_at(qx, qy), bilinear)


@pytest.mark.parametrize(
    ("x", "y", "depth", "message"),
    [
        ([0.0], [0.0, 1.0], [[1.0, 1.0]], ">= 2 points"),
        ([0.0, 0.0], [0.0, 1.0], np.ones((2, 2)), "strictly increasing"),
        ([0.0, 1.0], [0.0, 1.0], np.ones((2, 3)), "shape"),
        ([0.0, 1.0], [0.0, 1.0], [[1.0, 0.0], [1.0, 1.0]], "positive"),
    ],
)
def test_bathymetry_validation(x, y, depth, message):
    with pytest.raises(ValueError, match=message):
        Bathymetry(x, y, depth)


def test_read_bathymetry_file(tmp_path):
    path = tmp_path / "seabed.txt"
    path.write_text(
        "# x y depth\n"
        "\n"
        "20 10 52   ! comment\n"
        "0 -10 50\n"
        "50 -10 55 -- trailing note\n"
        "0 10 50\n"
        "20 -10 52\n"
        "5.0e1 1.0E+1 55\n",
        encoding="utf-8",
    )
    bathymetry = read_bathymetry(path)
    assert bathymetry.source == path.resolve()
    np.testing.assert_array_equal(bathymetry.x, [0.0, 20.0, 50.0])
    np.testing.assert_array_equal(bathymetry.y, [-10.0, 10.0])
    np.testing.assert_allclose(bathymetry.depth, _slope().depth)


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("0 0 1\n1 0 1\n0 1 1\n1 1\n", "plain numbers"),
        ("--- grid ---\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n", "plain numbers"),
        ("0 0 1\n1 0 1\n0 1 1\n1 1 nan\n", "plain numbers"),
        ("0 0 1\n1 0 1\n0 1 1\n", "2x2"),
        ("0 0 1\n1 0 1\n0 1 1\n1 1 1e999\n", "finite"),
        ("0 0 1\n1 0 1\n0 1 1\n1 1 0\n", "positive"),
        ("0 0 1\n1 0 1\n0 1 1\n2 1 1\n", "complete rectangular grid"),
        ("0 0 1\n1 0 1\n0 1 1\n0 1 2\n", "complete rectangular grid|duplicate"),
        ("0 0 1\n1 0 1\n0 1 1\n0 0 2\n1 1 1\n0 1 3\n", "complete rectangular grid|duplicate"),
    ],
)
def test_read_bathymetry_rejects_malformed_files(tmp_path, text, message):
    path = tmp_path / "bad.txt"
    path.write_text(text, encoding="utf-8")
    with pytest.raises(ValueError, match=message):
        read_bathymetry(path)


def test_read_bathymetry_duplicate_with_a_full_count(tmp_path):
    path = tmp_path / "dup.txt"
    # a repeated row and a missing one leave the row count of a complete 2 x 3 grid
    path.write_text("0 0 1\n1 0 1\n0 1 1\n1 1 1\n0 2 1\n0 2 1\n", encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate"):
        read_bathymetry(path)


# --- seabed clearance --------------------------------------------------------------------------


def test_flat_seabed_clearance_of_a_line_history(tmp_path, plt):
    history = _write_nodes(tmp_path / "run.Line1.p.out", _frames())
    result = seabed_clearance(history, -50.0)
    assert isinstance(result, SeabedClearance)
    expected = TIMES[:, None] * np.arange(NODES)[None, :]
    np.testing.assert_allclose(result.clearance, expected)
    assert result.minimum == 0.0 and result.minimum_index == (0, 0)
    assert result.minimum_time == 0.0 and result.minimum_node == 1
    assert result.minimum_arc_length == 0.0
    np.testing.assert_allclose(result.node_minimum, np.zeros(NODES))
    np.testing.assert_allclose(result.sample_minimum, np.zeros(3))
    lifted = seabed_clearance(history, -52.0, radius=0.5, start=1.0)
    assert lifted.minimum == pytest.approx(1.5) and lifted.minimum_time == 1.0
    assert lifted.radius == 0.5
    profile = lifted.profile(1.5)
    assert profile.quantity == "seabed_clearance" and profile.unit == "m"
    np.testing.assert_allclose(profile.values, 1.5 + 1.5 * np.arange(NODES))
    nearest = lifted.profile(1.5, interpolation="nearest")
    np.testing.assert_allclose(nearest.values, 1.5 + np.arange(NODES))
    graph = result.range_graph(line_id=3)
    assert graph.quantity == "clearance" and graph.line_id == 3 and graph.unit == "m"
    np.testing.assert_allclose(graph.maximum, 2.0 * np.arange(NODES))
    np.testing.assert_allclose(graph.mean, np.arange(NODES))
    np.testing.assert_allclose(graph.location, result.location)
    assert graph.time_window == (0.0, 2.0)
    ax = result.plot()
    assert ax.get_xlabel() == "Time [s]"
    with pytest.raises(ValueError, match="finite"):
        seabed_clearance(history, math.inf)
    with pytest.raises(ValueError, match="non-negative"):
        seabed_clearance(history, -50.0, radius=-1.0)


def test_bathymetry_clearance_of_a_static_line(plt):
    frame = _frames()[1]
    result = seabed_clearance(frame, _slope())
    assert result.time is None and result.minimum_time is None
    np.testing.assert_allclose(result.clearance[0], np.arange(NODES) + 0.1 * X)
    assert result.minimum_node == 1
    profile = result.profile()
    assert profile.time is None
    np.testing.assert_allclose(profile.values, np.arange(NODES) + 0.1 * X)
    with pytest.raises(ValueError, match="source result file"):
        result.range_graph()
    _, ax = plt.subplots()
    assert result.plot(ax=ax) is ax and ax.get_xlabel() == "Arc length [m]"


def test_seabed_clearance_validation():
    good = {"time": None, "node_ids": [1], "arc_length": [[0.0]], "clearance": [[1.0]]}
    SeabedClearance(**good, source="x.out")
    with pytest.raises(ValueError, match="non-empty"):
        SeabedClearance(**{**good, "clearance": [[math.nan]]})
    with pytest.raises(ValueError, match="arc_length"):
        SeabedClearance(**{**good, "arc_length": [[0.0, 1.0]]})
    with pytest.raises(ValueError, match="one identifier"):
        SeabedClearance(**{**good, "node_ids": [1, 2]})
    with pytest.raises(ValueError, match="one entry per sample"):
        SeabedClearance(**{**good, "time": [0.0, 1.0]})
    with pytest.raises(ValueError, match="exactly one sample"):
        SeabedClearance(None, [1], [[0.0], [0.0]], [[1.0], [2.0]])


# --- line-to-line clearance --------------------------------------------------------------------


def _crossing(heights: np.ndarray) -> tuple[LinePositions, LinePositions]:
    """Line a along x at z = 0; line b along y through x = 15, at z = heights(t)."""
    a = np.stack([np.column_stack([X, np.zeros(NODES), np.zeros(NODES)]) for _ in heights])
    y = np.array([-20.0, -5.0, 10.0])
    b = np.stack([np.column_stack([np.full(3, 15.0), y, np.full(3, h)]) for h in heights])
    stamps = np.arange(heights.size, dtype=float)
    return LinePositions(stamps, a, np.arange(1, NODES + 1)), LinePositions(stamps, b, [1, 2, 3])


def test_crossing_lines_have_the_analytic_clearance(tmp_path, plt):
    heights = np.array([4.0, 2.0, 3.0])
    a, b = _crossing(heights)
    result = line_clearance(a, b, radius_a=0.25, radius_b=0.5)
    assert isinstance(result, LineClearance)
    np.testing.assert_allclose(result.distance, heights)
    np.testing.assert_allclose(result.clearance, heights - 0.75)
    np.testing.assert_allclose(result.arc_length_a, 15.0)
    np.testing.assert_allclose(result.arc_length_b, 20.0)
    np.testing.assert_array_equal(result.segment_a, [2, 2, 2])
    np.testing.assert_array_equal(result.segment_b, [2, 2, 2])
    np.testing.assert_allclose(result.point_a[1], [15.0, 0.0, 0.0])
    np.testing.assert_allclose(result.point_b[1], [15.0, 0.0, 2.0])
    assert result.minimum == pytest.approx(1.25) and result.minimum_index == 1
    assert result.minimum_time == 1.0
    assert result.minimum_arc_length_a == pytest.approx(15.0)
    assert result.minimum_arc_length_b == pytest.approx(20.0)
    window = line_clearance(a, b, start=1.5)
    np.testing.assert_allclose(window.distance, [3.0])
    ax = result.plot(label="a-b")
    assert ax.get_legend() is not None
    result.plot(ax=ax)
    target = result.export(tmp_path / "ab.csv")
    rows = list(csv.reader(target.open(encoding="utf-8")))
    assert rows[0][:3] == ["Time_[s]", "Distance_[m]", "Clearance_[m]"]
    assert rows[2][:3] == ["1", "2", "1.25"] and rows[2][5:] == ["2", "2"]


def test_static_lines_broadcast_against_histories(tmp_path):
    heights = np.array([4.0, 2.0, 3.0])
    a, b = _crossing(heights)
    fixed = line_positions(a.positions[0])
    one_way = line_clearance(fixed, b)
    other_way = line_clearance(b, fixed)
    np.testing.assert_allclose(one_way.distance, heights)
    np.testing.assert_allclose(other_way.distance, heights)
    np.testing.assert_array_equal(one_way.time, b.time)
    both = line_clearance(fixed, b.positions[1])
    assert both.time is None and both.minimum_time is None
    np.testing.assert_allclose(both.distance, [2.0])
    with pytest.raises(ValueError, match="no time history"):
        both.plot()
    rows = list(csv.reader(both.export(tmp_path / "s.csv").open(encoding="utf-8")))
    assert rows[1][0] == ""
    shifted = LinePositions(b.time + 0.5, b.positions, b.node_ids)
    with pytest.raises(ValueError, match="share their sample times"):
        line_clearance(a, shifted)
    # a single node is a point
    point = line_clearance(a, np.array([[15.0, 3.0, 4.0]]))
    np.testing.assert_allclose(point.distance, 5.0)
    np.testing.assert_array_equal(point.segment_b, [1, 1, 1])


def test_line_clearance_chunks_long_histories(monkeypatch):
    heights = np.linspace(5.0, 1.0, 9)
    a, b = _crossing(heights)
    reference = line_clearance(a, b)
    monkeypatch.setattr(clearance_module, "_CHUNK", 1)
    chunked = line_clearance(a, b)
    np.testing.assert_array_equal(chunked.distance, reference.distance)
    np.testing.assert_allclose(chunked.distance, heights)


def test_line_clearance_validation():
    good = {
        "time": [0.0],
        "distance": [1.0],
        "arc_length_a": [0.0],
        "arc_length_b": [0.0],
        "segment_a": [1],
        "segment_b": [1],
        "point_a": [[0.0, 0.0, 0.0]],
        "point_b": [[0.0, 0.0, 1.0]],
    }
    assert LineClearance(**good).minimum == 1.0
    with pytest.raises(ValueError, match="non-empty"):
        LineClearance(**{**good, "distance": []})
    with pytest.raises(ValueError, match="point_a must match"):
        LineClearance(**{**good, "point_a": [0.0, 0.0, 0.0]})
    with pytest.raises(ValueError, match="one entry per sample"):
        LineClearance(**{**good, "time": [0.0, 1.0]})
    with pytest.raises(ValueError, match="exactly one sample"):
        LineClearance(
            **{
                **good,
                "time": None,
                "distance": [1.0, 2.0],
                "arc_length_a": [0.0, 0.0],
                "arc_length_b": [0.0, 0.0],
                "segment_a": [1, 1],
                "segment_b": [1, 1],
                "point_a": np.zeros((2, 3)),
                "point_b": np.zeros((2, 3)),
            }
        )
    with pytest.raises(ValueError, match="radius_b"):
        LineClearance(**good, radius_b=-1.0)


def test_clearance_matrix(tmp_path):
    heights = np.array([4.0, 2.0, 3.0])
    a, b = _crossing(heights)
    far = LinePositions(a.time, a.positions + np.array([0.0, 0.0, -10.0]), a.node_ids)
    matrix = clearance_matrix({"a": a, "b": b, "far": far}, radius={"b": 0.5})
    assert isinstance(matrix, ClearanceMatrix)
    assert matrix.names == ("a", "b", "far")
    assert math.isnan(matrix.minimum[0, 0])
    assert matrix.minimum[0, 1] == matrix.minimum[1, 0] == pytest.approx(1.5)
    assert matrix.minimum[1, 2] == pytest.approx(11.5)
    assert matrix.minimum[0, 2] == pytest.approx(10.0)
    first, second, history = matrix.governing
    assert (first, second) == ("a", "b") and history.minimum_time == 1.0
    assert matrix.pair("b", "a") is matrix.pair("a", "b")
    with pytest.raises(KeyError, match="no line pair"):
        matrix.pair("a", "a")
    rows = list(csv.reader(matrix.export(tmp_path / "m.csv").open(encoding="utf-8")))
    assert rows[0] == ["Line", "a", "b", "far"]
    assert rows[1][:3] == ["a", "", "1.5"]
    numbered = clearance_matrix([a, b], radius=0.25, start=1.0)
    assert numbered.names == ("1", "2")
    assert numbered.minimum[0, 1] == pytest.approx(1.5)
    with pytest.raises(ValueError, match="at least two lines"):
        clearance_matrix([a])
    with pytest.raises(ValueError, match="two distinct"):
        ClearanceMatrix(("a", "a"), np.zeros((2, 2)), {})
    with pytest.raises(ValueError, match="square"):
        ClearanceMatrix(("a", "b"), np.zeros((3, 3)), {})


# --- against the native solver -----------------------------------------------------------------

_DRIVER = (
    os.environ.get("CABLEDYN_TEST_DRIVER", "").strip()
    or os.environ.get("CABLEDYN_DRIVER", "").strip()
)
EXAMPLES = Path(__file__).resolve().parents[2] / "examples"


@pytest.mark.skipif(
    not _DRIVER or not Path(_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the solver comparison",
)
def test_seabed_clearance_reproduces_the_solver_range_graph(tmp_path):
    shutil.copytree(EXAMPLES / "data" / "range_tdp", tmp_path / "data" / "range_tdp")
    deck = tmp_path / "range.dat"
    text = (EXAMPLES / "chain_range_tdp.dat").read_text(encoding="utf-8")
    deck.write_text(text.replace("1     2       1       r", "1     2       1       rp"))
    result = CableDynDriver(_DRIVER).run(deck, "range", timeout=600)
    graph = read_range_graph(f"{result.output_root}.Line1.range.out", "clearance")
    positions = result.read_line_positions(1)
    assert graph.time_window is not None
    ours = seabed_clearance(positions, -50.0, start=graph.time_window[0], stop=graph.time_window[1])
    # the solver writes eight significant digits
    assert graph.minimum is not None and graph.mean is not None
    np.testing.assert_allclose(ours.node_minimum, graph.minimum, atol=1e-6)
    np.testing.assert_allclose(np.max(ours.clearance, axis=0), graph.maximum, atol=1e-6)
    np.testing.assert_allclose(np.mean(ours.clearance, axis=0), graph.mean, atol=1e-6)


def test_seabed_clearance_records_the_line_of_a_per_line_file(tmp_path):
    history = _write_nodes(tmp_path / "run.Line4.p.out", _frames())
    result = seabed_clearance(history, -50.0)
    assert result.line_id == 4 and result.range_graph().line_id == 4
    assert result.range_graph(line_id=2).line_id == 2
    unnamed = seabed_clearance(_frames()[1], -50.0)
    assert unnamed.line_id is None
