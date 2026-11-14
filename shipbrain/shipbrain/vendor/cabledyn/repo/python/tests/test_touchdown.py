# SPDX-License-Identifier: Apache-2.0
"""Touchdown-point time histories from line position files and node channels."""

from __future__ import annotations

import csv
import math

import numpy as np
import pytest
from _design_data import write_main

from cabledyn import TouchdownHistory, read_moordyn_line, read_output, touchdown_history

SEABED = -50.0
TOLERANCE = 0.5
X = np.arange(0.0, 101.0, 10.0)
TIMES = np.arange(0.0, 11.0, 1.0)
# A kink on a node puts the TDP a tenth of the way up the next 10 m x 5 m chord.
STEP = 0.1 * math.sqrt(125.0)


def _shape(kink: float) -> np.ndarray:
    """Grounded at z = -50 up to x = kink, then rising with slope 0.5 towards End B."""
    z = SEABED + 0.5 * np.clip(X - kink, 0.0, None)
    return np.column_stack([X, np.zeros_like(X), z])


def _frames(kinks=None) -> np.ndarray:
    kinks = 30.0 + TIMES if kinks is None else kinks
    return np.stack([_shape(kink) for kink in kinks])


def _expected(xyz: np.ndarray) -> tuple[float, np.ndarray]:
    """Straightforward scalar TDP: last grounded node from End A, then the crossing of the
    level by the parabola through that node and the next two, in chord arc, its curvature
    limited so that it rises monotonically over the first chord (on a straight rise this is the
    chord crossing)."""
    level = SEABED + TOLERANCE
    last = int(np.argmax(xyz[:, 2] > level)) - 1
    low, high = xyz[last], xyz[last + 1]
    chords = np.linalg.norm(np.diff(xyz, axis=0), axis=1)
    arcs = np.array([0.0, chords[last], chords[last] + chords[last + 1]])
    heights = xyz[last : last + 3, 2] - level
    curvature = np.polyfit(arcs, heights, 2)[0]
    rise = (heights[1] - heights[0]) / chords[last]
    curvature = float(np.clip(curvature, -rise / chords[last], rise / chords[last]))
    coefficients = [curvature, rise - curvature * chords[last], heights[0]]
    roots = [r.real for r in np.roots(coefficients) if abs(r.imag) < 1e-12]
    inside = [r for r in roots if -1e-9 <= r <= chords[last] * (1.0 + 1e-9)]
    fraction = max(inside) / chords[last]
    arc = float(np.sum(chords[:last]) + fraction * chords[last])
    point = low + fraction * (high - low)
    point[2] = level
    return arc, point


def _write_line(path, frames, times=TIMES):
    count = frames.shape[1]
    names = ["Time(s)"] + [f"Node{i + 1}{axis}(m)" for i in range(count) for axis in "XYZ"]
    rows = [
        "\t".join(f"{value:.12E}" for value in (t, *frame.ravel()))
        for t, frame in zip(times, frames, strict=True)
    ]
    path.write_text("# positions\n" + "\t".join(names) + "\n" + "\n".join(rows) + "\n")
    return read_output(path)


def _write_static(path, xyz):
    lines = ["static", "LineID Node ArcLength X Y Z", "(-) (-) (m) (m) (m) (m)"]
    arc = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(xyz, axis=0), axis=1))))
    for node, (point, length) in enumerate(zip(xyz, arc, strict=True), start=1):
        lines.append(f"1 {node} {length} {point[0]} {point[1]} {point[2]}")
    lines.append("2 1 0 0 0 0")
    lines.append("2 2 1 1 0 0")
    path.write_text("\n".join(lines) + "\n")
    return read_output(path)


def test_touchdown_history_from_a_line_position_file(tmp_path, plt):
    frames = _frames()
    history = touchdown_history(
        _write_line(tmp_path / "run.Line1.p.out", frames), seabed_z=SEABED, tolerance=TOLERANCE
    )
    assert isinstance(history, TouchdownHistory)
    assert history.grounded_end == "A" and bool(np.all(history.touching))
    for index, frame in enumerate(frames):
        arc, point = _expected(frame)
        assert history.arc_length[index] == pytest.approx(arc)
        np.testing.assert_allclose(history.coordinates[index], point)
    # At whole-node kinks the chord follows the line: TDP 1 m beyond the kink in x.
    assert history.arc_length[0] == pytest.approx(30.0 + STEP)
    assert history.arc_length[-1] == pytest.approx(40.0 + STEP)
    assert history.coordinates[0, 0] == pytest.approx(31.0)
    assert history.layback[0] == pytest.approx(69.0)
    assert history.excursion[-1] == pytest.approx(10.0)
    assert history.arc_excursion[-1] == pytest.approx(10.0)
    assert history.reference_arc_length == pytest.approx(30.0 + STEP)
    assert history.statistics("arc_length")[1] == pytest.approx(40.0 + STEP)
    assert history.plot("excursion").get_ylabel() == "TDP excursion [m]"
    target = history.export(tmp_path / "tdp.csv")
    rows = list(csv.reader(target.open(encoding="utf-8")))
    assert rows[0][:2] == ["Time_[s]", "ArcLength_[m]"] and len(rows) == 12
    with pytest.raises(FileExistsError):
        history.export(target)
    window = touchdown_history(
        read_output(tmp_path / "run.Line1.p.out"),
        seabed_z=SEABED,
        tolerance=TOLERANCE,
        start=5.0,
    )
    assert window.time[0] == 5.0 and window.excursion[0] == 0.0


def test_touchdown_history_grounded_at_end_b(tmp_path):
    frames = _frames()
    forward = touchdown_history(
        _write_line(tmp_path / "a.p.out", frames), seabed_z=SEABED, tolerance=TOLERANCE
    )
    backward = touchdown_history(
        _write_line(tmp_path / "b.p.out", frames[:, ::-1, :]), seabed_z=SEABED, tolerance=TOLERANCE
    )
    assert backward.grounded_end == "B"
    lengths = np.sum(np.linalg.norm(np.diff(frames, axis=1), axis=2), axis=1)
    np.testing.assert_allclose(backward.arc_length, lengths - forward.arc_length)
    np.testing.assert_allclose(backward.excursion, forward.excursion)
    np.testing.assert_allclose(backward.layback, forward.layback)


def test_touchdown_on_a_convex_stencil_takes_the_monotone_crossing(tmp_path):
    # Clearance above the onset height -0.005, 0.01, 1.0, 2.0 m on 1 m spacing: the line rises
    # sharply beyond node 2. The unlimited parabola dips below the onset height inside the
    # element; limited to rise monotonically it crosses once, at sqrt(0.005 / 0.015) of the chord,
    # beyond the chord crossing (a third of the way).
    level = SEABED + TOLERANCE
    z = level + np.array([-0.005, 0.01, 1.0, 2.0])
    frame = np.column_stack([np.arange(4.0), np.zeros(4), z])[None, :, :]
    history = touchdown_history(
        _write_line(tmp_path / "convex.p.out", frame, times=[0.0]),
        seabed_z=SEABED,
        tolerance=TOLERANCE,
    )
    arc, point = _expected(frame[0])
    assert history.arc_length[0] == pytest.approx(arc)
    np.testing.assert_allclose(history.coordinates[0], point)
    assert history.coordinates[0, 0] == pytest.approx(np.sqrt(0.005 / 0.015), abs=1e-6)
    # the same stencil with node 1 exactly at the onset height: the TDP is that node
    z = level + np.array([0.0, 0.01, 1.0, 2.0])
    frame = np.column_stack([np.arange(4.0), np.zeros(4), z])[None, :, :]
    history = touchdown_history(
        _write_line(tmp_path / "onset.p.out", frame, times=[0.0]),
        seabed_z=SEABED,
        tolerance=TOLERANCE,
    )
    assert history.coordinates[0, 0] == pytest.approx(0.0, abs=1e-6)
    # a node reaching the onset height maps to that node
    z = level + np.array([-0.5, 1e-12, 1.0, 2.0])
    frame = np.column_stack([np.arange(4.0), np.zeros(4), z])[None, :, :]
    history = touchdown_history(
        _write_line(tmp_path / "node.p.out", frame, times=[0.0]),
        seabed_z=SEABED,
        tolerance=TOLERANCE,
    )
    assert history.coordinates[0, 0] == pytest.approx(1.0, abs=1e-6)


def test_touchdown_is_continuous_as_a_node_grounds_on_a_steep_stencil(tmp_path):
    # Clearances -0.001, h, 0.01, 1, 2 m: node 2 grounds as h falls through zero while the line
    # rises sharply beyond node 3. The TDP reaches node 2 from either side, without the jump of
    # almost an element that the unlimited parabola makes when the grounded stencil changes.
    level = SEABED + TOLERANCE
    steps = 1.0e-6 * np.arange(40, -41, -1)
    frames = np.stack(
        [
            np.column_stack(
                [np.arange(5.0), np.zeros(5), level + np.array([-0.001, h, 0.01, 1.0, 2.0])]
            )
            for h in steps
        ]
    )
    history = touchdown_history(
        _write_line(tmp_path / "steep.p.out", frames, times=list(range(len(steps)))),
        seabed_z=SEABED,
        tolerance=TOLERANCE,
    )
    x = history.coordinates[:, 0]
    assert np.max(np.abs(np.diff(x))) < 0.05
    assert x[40] == pytest.approx(1.0, abs=1e-6)


def test_touchdown_history_from_main_output_node_channels(tmp_path):
    frames = _frames()
    times = np.linspace(0.0, 10.0, 201)
    kinks = 30.0 + times
    columns = {}
    for node in range(X.size):
        for axis, index in (("px", 0), ("py", 1), ("pz", 2)):
            columns[f"L1N{node + 1}{axis}"] = np.array([_shape(k)[node, index] for k in kinks])
    main = read_output(write_main(tmp_path / "run.out", columns))
    history = touchdown_history(main, seabed_z=SEABED, tolerance=TOLERANCE, line_id=1)
    assert history.arc_length[0] == pytest.approx(_expected(frames[0])[0])
    reference = _write_static(tmp_path / "ref.static.out", _shape(30.0))
    referenced = touchdown_history(
        main, seabed_z=SEABED, tolerance=TOLERANCE, line_id=1, reference=reference
    )
    assert referenced.excursion[0] == pytest.approx(0.0, abs=1.0e-9)
    del columns["L1N4pz"]
    partial = read_output(write_main(tmp_path / "partial.out", columns))
    with pytest.raises(ValueError, match=r"nodes \[4\] of line 1 lack"):
        touchdown_history(partial, seabed_z=SEABED, line_id=1)
    assert history.arc_length[-1] == pytest.approx(40.0 + STEP)


def test_touchdown_history_from_a_moordyn_line_file(tmp_path):
    frames = _frames()
    names = ["Time"] + [f"Node{i}{axis}" for i in range(X.size) for axis in ("px", "py", "pz")]
    rows = [
        " ".join(f"{value:.12E}" for value in (t, *frame.ravel()))
        for t, frame in zip(TIMES, frames, strict=True)
    ]
    path = tmp_path / "md.MD.Line1.out"
    path.write_text(" ".join(names) + "\n" + "\n".join(rows) + "\n")
    history = touchdown_history(read_moordyn_line(path), seabed_z=SEABED, tolerance=TOLERANCE)
    assert history.arc_length[-1] == pytest.approx(40.0 + STEP)
    tension_only = tmp_path / "ten.MD.Line1.out"
    tension_only.write_text("Time Seg1Ten Seg2Ten\n0 1 2\n1 1 2\n")
    with pytest.raises(KeyError, match="node position"):
        touchdown_history(read_moordyn_line(tension_only), seabed_z=SEABED)


def test_reference_profile_and_lost_touchdown(tmp_path):
    frames = _frames()
    lifted = frames.copy()
    lifted[-1, :, 2] = SEABED + 5.0  # fully suspended at the last sample
    reference = _write_static(tmp_path / "ref.static.out", _shape(35.0))
    history = touchdown_history(
        _write_line(tmp_path / "run.p.out", lifted),
        seabed_z=SEABED,
        tolerance=TOLERANCE,
        reference=reference.line(1),
    )
    ref_arc, ref_point = _expected(_shape(35.0))
    assert history.reference_arc_length == pytest.approx(ref_arc)
    assert history.excursion[0] == pytest.approx(31.0 - ref_point[0])
    assert not history.touching[-1] and math.isnan(history.arc_length[-1])
    minimum, maximum, mean = history.statistics("layback")
    assert minimum < mean < maximum
    rows = list(csv.reader(history.export(tmp_path / "t.csv").open(encoding="utf-8")))
    assert rows[-1][1:] == [""] * 7


def test_touchdown_history_errors(tmp_path):
    frames = _frames()
    line = _write_line(tmp_path / "run.p.out", frames)
    with pytest.raises(ValueError, match="tolerance"):
        touchdown_history(line, seabed_z=SEABED, tolerance=-1.0)
    with pytest.raises(ValueError, match="grounded_end must be"):
        touchdown_history(line, seabed_z=SEABED, grounded_end="C")
    with pytest.raises(ValueError, match="line_id does not apply"):
        touchdown_history(line, seabed_z=SEABED, line_id=1)
    with pytest.raises(ValueError, match="never touches down"):
        touchdown_history(line, seabed_z=SEABED, grounded_end="B")
    with pytest.raises(ValueError, match="cannot infer the grounded end"):
        touchdown_history(line, seabed_z=-200.0)
    with pytest.raises(ValueError, match="quantity must be"):
        touchdown_history(line, seabed_z=SEABED).statistics("depth")
    with pytest.raises(ValueError, match="quantity must be"):
        touchdown_history(line, seabed_z=SEABED).plot("depth")
    main = read_output(write_main(tmp_path / "run.out"))
    with pytest.raises(ValueError, match="needs line_id"):
        touchdown_history(main, seabed_z=SEABED)
    with pytest.raises(KeyError, match="L1N"):
        touchdown_history(main, seabed_z=SEABED, line_id=1)
    single = _write_line(tmp_path / "one.p.out", frames[:, :1, :])
    with pytest.raises(ValueError, match="at least two nodes"):
        touchdown_history(single, seabed_z=SEABED)
    doubled = frames.copy()
    doubled[:, 1] = doubled[:, 0]
    with pytest.raises(ValueError, match="must not coincide"):
        touchdown_history(_write_line(tmp_path / "dup.p.out", doubled), seabed_z=SEABED)
    reference = _write_static(tmp_path / "ref.static.out", _shape(35.0))
    with pytest.raises(ValueError, match="pass line_id"):
        touchdown_history(line, seabed_z=SEABED, reference=reference)
    suspended = _write_static(tmp_path / "up.static.out", _shape(35.0) + np.array([0.0, 0.0, 20.0]))
    with pytest.raises(ValueError, match="reference profile has no touchdown"):
        touchdown_history(line, seabed_z=SEABED, reference=suspended.line(1))
    vertical = np.array(
        [[0.0, 0.0, -50.0], [10.0, 0.0, -50.0], [20.0, 0.0, -50.0], [20.0, 0.0, -30.0]]
    )
    riser = _write_line(tmp_path / "riser.p.out", np.stack([vertical, vertical]), TIMES[:2])
    with pytest.raises(ValueError, match="excursion is undefined"):
        touchdown_history(riser, seabed_z=SEABED)


def test_touchdown_history_without_contact_and_plot_on_given_axes(tmp_path, plt):
    empty = TouchdownHistory(
        time=[0.0, 1.0],
        touching=[False, False],
        arc_length=[math.nan, math.nan],
        coordinates=np.full((2, 3), math.nan),
        layback=[math.nan, math.nan],
        excursion=[math.nan, math.nan],
        arc_excursion=[math.nan, math.nan],
        grounded_end="A",
        seabed_z=SEABED,
        tolerance=0.0,
        reference_arc_length=0.0,
        source=tmp_path / "x.out",
    )
    with pytest.raises(ValueError, match="never touches down"):
        empty.statistics("layback")
    _, ax = plt.subplots()
    assert empty.plot("layback", ax=ax) is ax
    assert not empty.touching.flags.writeable
