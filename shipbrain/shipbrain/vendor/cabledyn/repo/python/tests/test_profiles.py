# SPDX-License-Identifier: Apache-2.0
"""Line positions, per-location fields, and arc-length profiles at one time."""

from __future__ import annotations

import csv
import math

import numpy as np
import pytest
from _design_data import TIME, write_main, write_static

from cabledyn import node_range_graph, read_moordyn_line, read_output
from cabledyn.profiles import (
    ArcProfile,
    LineField,
    LinePositions,
    available_quantities,
    line_field,
    line_positions,
    line_range_graph,
    profile_at,
    profiles_at,
)

TIMES = np.array([0.0, 1.0, 2.0])
NODES = 5


def _frame(t: float) -> np.ndarray:
    """Nodes 10 m apart in x; node i (from 0) rises by t * i."""
    index = np.arange(NODES, dtype=float)
    return np.column_stack([10.0 * index, np.zeros(NODES), -50.0 + t * index])


FRAMES = np.stack([_frame(t) for t in TIMES])


def _chord(t: float) -> float:
    return math.sqrt(100.0 + t * t)


def _write_nodes(path, frames=FRAMES, times=TIMES):
    names = ["Time(s)"] + [
        f"Node{i + 1}{axis}(m)" for i in range(frames.shape[1]) for axis in "XYZ"
    ]
    rows = [
        "\t".join(f"{v:.12E}" for v in (t, *f.ravel())) for t, f in zip(times, frames, strict=True)
    ]
    path.write_text("# positions\n" + "\t".join(names) + "\n" + "\n".join(rows) + "\n")
    return read_output(path)


def _tension(t: float, segment: int) -> float:
    return 1000.0 * segment + 100.0 * t


def _write_segments(path, segments=NODES - 1, times=TIMES):
    names = ["Time(s)"] + [f"Segment{j}Tension(N)" for j in range(1, segments + 1)]
    rows = [
        "\t".join(f"{v:.12E}" for v in (t, *(_tension(t, j) for j in range(1, segments + 1))))
        for t in times
    ]
    path.write_text("# tensions\n" + "\t".join(names) + "\n" + "\n".join(rows) + "\n")
    return read_output(path)


def _write_moordyn(path, *, positions=True):
    names = ["Time"]
    if positions:
        names += [f"Node{i}{axis}" for i in range(NODES) for axis in ("px", "py", "pz")]
    names += [f"Node{i}vx" for i in range(NODES)] + [f"Node{i}Vx" for i in range(NODES)]
    names += [f"Node{i}{c}" for i in range(NODES) for c in ("vy", "vz", "Vy", "Vz")]
    names += [f"Seg{j}Ten" for j in range(1, NODES)]
    lines = [" ".join(names)]
    for t, frame in zip(TIMES, FRAMES, strict=True):
        values = [t]
        if positions:
            values += list(frame.ravel())
        values += [float(i) for i in range(NODES)] + [-float(i) for i in range(NODES)]
        values += [0.0] * (4 * NODES)
        values += [_tension(t, j) for j in range(1, NODES)]
        lines.append(" ".join(f"{v:.12E}" for v in values))
    path.write_text("\n".join(lines) + "\n")
    return read_moordyn_line(path)


def _write_main_output(path):
    columns = {
        "FairTen1": np.full(TIME.shape, 1.0),
        "Ten1N1": 1.0e6 + TIME,
        "Ten1N3": 8.0e5 + TIME,
        "Curv1N3": 0.01 * TIME,
        "L1N1px": np.zeros(TIME.shape),
        "L1N1py": np.zeros(TIME.shape),
        "L1N1pz": -TIME,
        "L1N3px": np.full(TIME.shape, 30.0),
        "L1N3py": np.zeros(TIME.shape),
        "L1N3pz": np.full(TIME.shape, 40.0),
        "Ten2N1": np.full(TIME.shape, 5.0),
    }
    return read_output(write_main(path, columns))


def test_line_positions_from_a_node_file(tmp_path):
    history = _write_nodes(tmp_path / "run.Line1.p.out")
    positions = line_positions(history)
    assert isinstance(positions, LinePositions)
    assert positions.sample_count == 3 and positions.node_count == NODES
    assert not positions.static and positions.source == history.path
    np.testing.assert_array_equal(positions.node_ids, np.arange(1, NODES + 1))
    np.testing.assert_allclose(positions.positions, FRAMES)
    np.testing.assert_allclose(positions.arc_length[2], _chord(2.0) * np.arange(NODES))
    np.testing.assert_allclose(positions.at(0.5), 0.5 * (FRAMES[0] + FRAMES[1]))
    np.testing.assert_allclose(positions.at(0.5, interpolation="nearest"), FRAMES[0])
    np.testing.assert_allclose(positions.at(2.0), FRAMES[2])
    assert positions.period() is positions
    window = positions.period(0.5, 2.0)
    np.testing.assert_array_equal(window.time, [1.0, 2.0])
    np.testing.assert_array_equal(positions.period(None, 1.0).time, [0.0, 1.0])
    np.testing.assert_allclose(positions.arc_length_at(1.5), _chord(1.5) * np.arange(NODES))
    assert line_positions(positions) is positions
    with pytest.raises(ValueError, match="does not apply"):
        line_positions(history, line_id=1)
    with pytest.raises(ValueError, match="only to a position array"):
        line_positions(history, time=[0.0])


def test_line_positions_from_arrays_and_static_tables(tmp_path):
    static = line_positions(FRAMES[0])
    assert static.static and static.time is None and static.sample_count == 1
    np.testing.assert_array_equal(static.node_ids, np.arange(1, NODES + 1))
    np.testing.assert_allclose(static.at(), FRAMES[0])
    assert static.period(0.0, 1.0) is static
    dynamic = line_positions(FRAMES, time=TIMES)
    np.testing.assert_allclose(dynamic.at(1.0), FRAMES[1])
    with pytest.raises(ValueError, match="needs the sample times"):
        line_positions(FRAMES)
    with pytest.raises(ValueError, match="only to a"):
        line_positions(FRAMES[0], time=[0.0])
    with pytest.raises(ValueError, match="positions must be"):
        line_positions(np.zeros(3))
    with pytest.raises(ValueError, match="does not apply"):
        line_positions(FRAMES[0], line_id=1)
    profile = read_output(write_static(tmp_path / "run.static.out"))
    with pytest.raises(ValueError, match="pass line_id"):
        line_positions(profile)
    line = line_positions(profile, line_id=1)
    assert line.static and line.node_count == 5
    np.testing.assert_allclose(line.positions[0, :, 0], 25.0 * np.arange(5))
    table = tmp_path / "st.Line1.p.out"
    table.write_text("# static\nNode\tX(m)\tY(m)\tZ(m)\n1\t0\t0\t0\n2\t3\t0\t-4\n")
    node_table = line_positions(read_output(table))
    assert node_table.static
    z_profile = profile_at(read_output(table), "z")
    np.testing.assert_allclose(z_profile.location, [0.0, 5.0])
    single = tmp_path / "single.static.out"
    single.write_text("static\nLineID Node ArcLength X Y Z\n1 1 0 0 0 0\n1 2 2 0 0 2\n")
    assert line_positions(read_output(single)).node_count == 2
    np.testing.assert_allclose(node_table.arc_length, [[0.0, 5.0]])
    segments = tmp_path / "st.Line1.t.out"
    segments.write_text("# static\nSegment\tTension(N)\n1\t5\n")
    with pytest.raises(KeyError, match="no line node positions"):
        line_positions(read_output(segments))
    with pytest.raises(ValueError, match="does not apply"):
        line_positions(read_output(table), line_id=1)


def test_line_positions_from_main_output_and_moordyn(tmp_path):
    main = _write_main_output(tmp_path / "run.out")
    with pytest.raises(ValueError, match="needs line_id"):
        line_positions(main)
    with pytest.raises(ValueError, match="positive integer"):
        line_positions(main, line_id=0)
    positions = line_positions(main, line_id=1)
    np.testing.assert_array_equal(positions.node_ids, [1, 3])
    np.testing.assert_allclose(positions.at(10.0), [[0.0, 0.0, -10.0], [30.0, 0.0, 40.0]])
    with pytest.raises(KeyError, match="no L2N"):
        line_positions(main, line_id=2)
    partial = dict.fromkeys(("L1N1px", "L1N1py", "L1N1pz", "L1N2px"), np.zeros(TIME.shape))
    with pytest.raises(ValueError, match="lack a px"):
        line_positions(read_output(write_main(tmp_path / "partial.out", partial)), line_id=1)
    moordyn = _write_moordyn(tmp_path / "run.MD.Line1.out")
    md = line_positions(moordyn)
    np.testing.assert_array_equal(md.node_ids, np.arange(NODES))
    np.testing.assert_allclose(md.positions, FRAMES)
    with pytest.raises(KeyError, match="no node position channels"):
        line_positions(_write_moordyn(tmp_path / "nop.MD.Line1.out", positions=False))


def test_line_positions_validation():
    with pytest.raises(ValueError, match="non-empty"):
        LinePositions(None, np.zeros((1, 0, 3)), np.zeros(0))
    with pytest.raises(ValueError, match="finite"):
        LinePositions(None, np.full((1, 2, 3), np.nan), [1, 2])
    with pytest.raises(ValueError, match="exactly one sample"):
        LinePositions(None, FRAMES, np.arange(NODES))
    with pytest.raises(ValueError, match="one entry per sample"):
        LinePositions([0.0], FRAMES, np.arange(NODES))
    with pytest.raises(ValueError, match="strictly increasing"):
        LinePositions([0.0, 2.0, 1.0], FRAMES, np.arange(NODES))
    with pytest.raises(ValueError, match="one identifier per node"):
        LinePositions(TIMES, FRAMES, [1])
    positions = LinePositions(TIMES, FRAMES, np.arange(NODES))
    with pytest.raises(ValueError, match="needs the time"):
        positions.at()
    with pytest.raises(ValueError, match="outside"):
        positions.at(3.0)
    with pytest.raises(ValueError, match="finite"):
        positions.at(math.nan)
    with pytest.raises(ValueError, match="interpolation"):
        positions.at(1.0, interpolation="cubic")  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="does not apply"):
        LinePositions(None, FRAMES[:1], np.arange(NODES)).at(1.0)
    with pytest.raises(ValueError, match="must not exceed"):
        positions.period(2.0, 1.0)
    with pytest.raises(ValueError, match="no sample"):
        positions.period(0.2, 0.8)
    single = LinePositions([4.0], FRAMES[:1], np.arange(NODES))
    np.testing.assert_allclose(single.at(4.0), FRAMES[0])


def test_line_fields_of_every_source(tmp_path):
    nodes = _write_nodes(tmp_path / "run.Line1.p.out")
    segments = _write_segments(tmp_path / "run.Line1.t.out")
    assert available_quantities(nodes) == ("x", "y", "z")
    assert available_quantities(segments) == ("tension",)
    z = line_field(nodes, "Z")
    assert z.location_kind == "Node" and z.unit == "m" and z.source == nodes.path
    np.testing.assert_allclose(z.values, FRAMES[:, :, 2])
    tension = line_field(segments, "tension")
    assert tension.location_kind == "Segment" and tension.unit == "N"
    np.testing.assert_array_equal(tension.ids, [1, 2, 3, 4])
    np.testing.assert_allclose(tension.at(1.5), [_tension(1.5, j) for j in range(1, 5)])
    np.testing.assert_allclose(
        tension.at(1.5, interpolation="nearest"), [_tension(1.0, j) for j in range(1, 5)]
    )
    window = tension.period(1.0, None)
    np.testing.assert_array_equal(window.time, [1.0, 2.0])
    assert tension.period() is tension
    with pytest.raises(KeyError, match="available: tension"):
        line_field(segments, "curvature")
    with pytest.raises(ValueError, match="does not apply"):
        line_field(segments, "tension", line_id=1)

    main = _write_main_output(tmp_path / "run.out")
    assert set(available_quantities(main, line_id=1)) == {"tension", "curvature", "x", "y", "z"}
    assert available_quantities(main, line_id=2) == ("tension",)
    main_tension = line_field(main, "tension", line_id=1)
    np.testing.assert_array_equal(main_tension.ids, [1, 3])
    assert main_tension.unit == "N"
    assert line_field(main, "curvature", line_id=1).unit == "1/m"
    with pytest.raises(ValueError, match="needs line_id"):
        line_field(main, "tension")
    duplicate = {"Ten1N1": TIME, "Ten1N01": TIME}
    with pytest.raises(ValueError, match="same node"):
        line_field(read_output(write_main(tmp_path / "dup.out", duplicate)), "tension", line_id=1)

    moordyn = _write_moordyn(tmp_path / "run.MD.Line1.out")
    names = available_quantities(moordyn)
    assert {"x", "y", "z", "tension", "vx", "Vx"} <= set(names)
    np.testing.assert_allclose(line_field(moordyn, "vx").values[0], np.arange(NODES))
    np.testing.assert_allclose(line_field(moordyn, "Vx").values[0], -np.arange(NODES))
    with pytest.raises(ValueError, match="ambiguous"):
        line_field(moordyn, "VX")
    assert line_field(moordyn, "tension").location_kind == "Segment"

    profile = read_output(write_static(tmp_path / "run.static.out"))
    assert available_quantities(profile, line_id=1) == (
        "x",
        "y",
        "z",
        "tension",
        "curvature",
        "bend_moment",
    )
    moment = line_field(profile, "BendMoment", line_id=1)
    assert moment.static and moment.unit == "N.m"
    np.testing.assert_allclose(moment.at(), 1.0e4 * np.array([0.0, 0.01, 0.04, 0.02, 0.0]))

    positions = line_positions(FRAMES, time=TIMES)
    assert available_quantities(positions) == ("x", "y", "z")
    assert available_quantities(FRAMES[0]) == ("x", "y", "z")
    with pytest.raises(ValueError, match="does not apply"):
        available_quantities(positions, line_id=1)

    table = tmp_path / "st.Line1.t.out"
    table.write_text("# static\nSegment\tTension(N)\n1\t5\n2\t7\n")
    static_tension = line_field(read_output(table), "tension")
    assert static_tension.static and static_tension.location_kind == "Segment"
    np.testing.assert_allclose(static_tension.at(), [5.0, 7.0])
    node_table = tmp_path / "st.Line1.p.out"
    node_table.write_text("# static\nNode\tX(m)\tY(m)\tZ(m)\n1\t0\t0\t0\n2\t3\t0\t-4\n")
    assert available_quantities(read_output(node_table)) == ("x", "y", "z")
    other = tmp_path / "other.out"
    other.write_text("Node\tValue\n1\t2\n")
    with pytest.raises(ValueError, match="not a line result"):
        line_field(read_output(other), "value")


def test_line_field_validation():
    with pytest.raises(ValueError, match="location_kind"):
        LineField("q", None, "Element", [1], None, [[1.0]])
    with pytest.raises(ValueError, match="finite"):
        LineField("q", None, "Node", [1], None, [[math.inf]])
    with pytest.raises(ValueError, match="one identifier per location"):
        LineField("q", None, "Node", [1, 2], None, [[1.0]])
    field = LineField("q", None, "Node", [1], None, [[1.0]], source="x.out")
    assert field.source is not None and field.source.is_absolute()


def test_segment_profile_at_mid_arc_between_samples(tmp_path):
    nodes = _write_nodes(tmp_path / "run.Line1.p.out")
    segments = _write_segments(tmp_path / "run.Line1.t.out")
    profile = profile_at(segments, "tension", 1.5, positions=nodes)
    assert isinstance(profile, ArcProfile)
    assert profile.location_kind == "ArcLength" and profile.time == 1.5 and profile.unit == "N"
    assert profile.id_kind == "Segment"
    header = next(csv.reader(profile.export(tmp_path / "t.csv").open(encoding="utf-8")))
    assert header == ["ArcLength_[m]", "SegmentId", "tension_[N]"]
    # the positions are interpolated at the same time: the chords are the mean of samples 1 and 2
    frame = 0.5 * (FRAMES[1] + FRAMES[2])
    chord = float(np.linalg.norm(frame[1] - frame[0]))
    np.testing.assert_allclose(profile.location, chord * (np.arange(1, 5) - 0.5))
    np.testing.assert_allclose(profile.values, [_tension(1.5, j) for j in range(1, 5)])
    assert profile.maximum == pytest.approx(_tension(1.5, 4))
    assert profile.minimum == pytest.approx(_tension(1.5, 1))
    nearest = profile_at(segments, "tension", 1.5, positions=nodes, interpolation="nearest")
    np.testing.assert_allclose(nearest.location, _chord(1.0) * (np.arange(1, 5) - 0.5))
    np.testing.assert_allclose(nearest.values, [_tension(1.0, j) for j in range(1, 5)])
    by_number = profile_at(segments, "tension", 1.0)
    assert by_number.location_kind == "Segment"
    np.testing.assert_array_equal(by_number.location, [1.0, 2.0, 3.0, 4.0])
    with pytest.raises(ValueError, match="needs the time"):
        profile_at(segments, "tension")
    with pytest.raises(ValueError, match="outside"):
        profile_at(segments, "tension", 5.0)
    with pytest.raises(ValueError, match="cannot place segment"):
        profile_at(segments, "tension", 1.0, positions={1: 0.0, 2: 1.0})
    short = _write_segments(tmp_path / "short.Line1.t.out", segments=2)
    with pytest.raises(ValueError, match="need 3 nodes"):
        profile_at(short, "tension", 1.0, positions=nodes)


def test_node_profiles_from_positions_and_other_sources(tmp_path):
    nodes = _write_nodes(tmp_path / "run.Line1.p.out")
    profiles = profiles_at(nodes, ["z", "X"], 2.0)
    assert set(profiles) == {"z", "X"}
    np.testing.assert_allclose(profiles["z"].location, _chord(2.0) * np.arange(NODES))
    np.testing.assert_allclose(profiles["z"].values, FRAMES[2, :, 2])
    np.testing.assert_allclose(profiles["X"].values, FRAMES[2, :, 0])
    array = profile_at(FRAMES[1], "z")
    assert array.time is None and array.location_kind == "ArcLength"
    np.testing.assert_allclose(array.location, _chord(1.0) * np.arange(NODES))
    moordyn = _write_moordyn(tmp_path / "run.MD.Line1.out")
    md = profile_at(moordyn, "tension", 1.0)
    np.testing.assert_allclose(md.location, _chord(1.0) * (np.arange(1, 5) - 0.5))
    no_positions = _write_moordyn(tmp_path / "nop.MD.Line1.out", positions=False)
    assert profile_at(no_positions, "tension", 1.0).location_kind == "Segment"
    static = read_output(write_static(tmp_path / "run.static.out"))
    tension = profile_at(static, "tension", line_id=1)
    assert tension.time is None
    np.testing.assert_allclose(tension.location, 25.0 * np.arange(5))
    np.testing.assert_allclose(tension.values, 1.0e5 * np.arange(1, 6))
    with pytest.raises(ValueError, match="does not apply"):
        profile_at(static, "tension", 1.0, line_id=1)


def test_main_output_profiles_are_placed_by_static_arc_or_mapping(tmp_path):
    main = _write_main_output(tmp_path / "run.out")
    static = read_output(write_static(tmp_path / "run.static.out"))
    by_static = profile_at(main, "tension", 10.0, line_id=1, positions=static)
    np.testing.assert_allclose(by_static.location, [0.0, 50.0])
    np.testing.assert_allclose(by_static.values, [1.0e6 + 10.0, 8.0e5 + 10.0])
    by_mapping = profile_at(main, "tension", 5.0, line_id=1, positions={3: 7.0, 1: 2.0})
    np.testing.assert_allclose(by_mapping.location, [2.0, 7.0])
    by_number = profile_at(main, "tension", 5.0, line_id=1)
    assert by_number.location_kind == "Node"
    np.testing.assert_array_equal(by_number.ids, [1, 3])
    # the main output's own position channels place the nodes by their chord arc
    by_channels = profile_at(main, "tension", 0.0, line_id=1, positions=main)
    np.testing.assert_allclose(by_channels.location, [0.0, 50.0])
    with pytest.raises(KeyError, match=r"no arc length for nodes \[3\]"):
        profile_at(main, "tension", 5.0, line_id=1, positions={1: 0.0})
    # a static position source ignores the requested time
    frame = line_positions(np.array([[0.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 0.0, 3.0]]))
    by_frame = profile_at(main, "tension", 5.0, line_id=1, positions=frame)
    np.testing.assert_allclose(by_frame.location, [0.0, 3.0])


def test_arc_profile_plot_export_and_validation(tmp_path, plt):
    profile = ArcProfile("tension", "N", "ArcLength", [0.0, 5.0], [1, 2], [3.0, 4.0], 1.0, "a.out")
    assert profile.source is not None and profile.source.is_absolute()
    ax = profile.plot()
    assert ax.get_xlabel() == "Arc length [m]" and ax.get_ylabel() == "Tension [N]"
    assert "t = 1 s" in ax.get_legend().get_texts()[0].get_text()
    ArcProfile("q", None, "Node", [1.0], [1], [2.0], None).plot(ax=ax, label="static")
    target = profile.export(tmp_path / "profile.csv")
    with target.open(encoding="utf-8") as stream:
        rows = list(csv.reader(stream))
    assert rows[0] == ["ArcLength_[m]", "NodeId", "tension_[N]"]
    assert rows[2] == ["5", "2", "4"]
    with pytest.raises(FileExistsError):
        profile.export(target)
    segment = ArcProfile("q", None, "Segment", [1.0], [1], [2.0], None, id_kind="Segment")
    rows = list(csv.reader(segment.export(tmp_path / "s.csv").open(encoding="utf-8")))
    assert rows[0] == ["Segment_[-]", "SegmentId", "q"]
    with pytest.raises(ValueError, match="location_kind"):
        ArcProfile("q", None, "Element", [1.0], [1], [2.0], None)
    with pytest.raises(ValueError, match="id_kind must be"):
        ArcProfile("q", None, "ArcLength", [1.0], [1], [2.0], None, id_kind="Element")
    with pytest.raises(ValueError, match="id_kind must match"):
        ArcProfile("q", None, "Segment", [1.0], [1], [2.0], None)
    with pytest.raises(ValueError, match="non-empty"):
        ArcProfile("q", None, "Node", [], [], [], None)
    with pytest.raises(ValueError, match="match location"):
        ArcProfile("q", None, "Node", [1.0], [1], [2.0, 3.0], None)
    with pytest.raises(ValueError, match="finite"):
        ArcProfile("q", None, "Node", [1.0], [1], [math.nan], None)
    with pytest.raises(ValueError, match="non-decreasing"):
        ArcProfile("q", None, "Node", [2.0, 1.0], [1, 2], [0.0, 0.0], None)


def test_line_range_graph_of_segment_tension_and_node_variables(tmp_path):
    nodes = _write_nodes(tmp_path / "run.Line1.p.out")
    segments = _write_segments(tmp_path / "run.Line1.t.out")
    graph = line_range_graph(segments, "tension", positions=nodes)
    assert graph.quantity == "tension" and graph.unit == "N" and graph.line_id == 1
    assert graph.location_kind == "ArcLength" and graph.time_window == (0.0, 2.0)
    assert graph.source == segments.path
    mean_chord = np.mean([_chord(t) for t in TIMES])
    np.testing.assert_allclose(graph.location, mean_chord * (np.arange(1, 5) - 0.5))
    np.testing.assert_allclose(graph.minimum, 1000.0 * np.arange(1, 5))
    np.testing.assert_allclose(graph.maximum, 1000.0 * np.arange(1, 5) + 200.0)
    np.testing.assert_allclose(graph.mean, 1000.0 * np.arange(1, 5) + 100.0)
    late = line_range_graph(nodes, "z", start=1.0)
    assert late.time_window == (1.0, 2.0)
    np.testing.assert_allclose(late.location, np.mean([_chord(1.0), _chord(2.0)]) * np.arange(5))
    np.testing.assert_allclose(late.maximum - late.minimum, np.arange(5))
    with pytest.raises(ValueError, match="needs node positions"):
        line_range_graph(segments, "tension")
    with pytest.raises(ValueError, match="cannot place segment"):
        line_range_graph(segments, "tension", positions={1: 0.0})
    with pytest.raises(ValueError, match="result file"):
        line_range_graph(FRAMES[0], "z")


def test_line_range_graph_of_main_output_and_static_profile(tmp_path):
    main = _write_main_output(tmp_path / "run.out")
    static = read_output(write_static(tmp_path / "run.static.out"))
    placed = line_range_graph(main, "tension", line_id=1, positions=static, start=5.0)
    np.testing.assert_allclose(placed.location, [0.0, 50.0])
    np.testing.assert_allclose(placed.maximum, [1.0e6 + 10.0, 8.0e5 + 10.0])
    np.testing.assert_allclose(placed.minimum, [1.0e6 + 5.0, 8.0e5 + 5.0])
    by_node = line_range_graph(main, "curvature", line_id=1)
    assert by_node.location_kind == "Node" and by_node.line_id == 1
    np.testing.assert_allclose(by_node.location, [3.0])
    own = line_range_graph(main, "tension", line_id=1, positions=main, stop=0.0)
    np.testing.assert_allclose(own.location, [0.0, 50.0])
    moment = line_range_graph(static, "bend_moment", line_id=1)
    assert moment.time_window is None
    np.testing.assert_allclose(moment.location, 25.0 * np.arange(5))
    np.testing.assert_array_equal(moment.minimum, moment.maximum)


def _write_refined_static(path):
    """Line 1 refined twice: deck nodes 1, 2, 3 are mesh nodes 1, 3, 5 (25 m apart)."""
    lines = [
        "CableDyn standalone static configuration (deformed arc; public node order End A -> End B)",
        "LineID\tNode\tArcLength\tX\tY\tZ\tTension\tCurvature\tBendMoment\tDeckNode",
        "(-)\t(-)\t(m)\t(m)\t(m)\t(m)\t(N)\t(1/m)\t(N.m)\t(-)",
    ]
    for node in range(1, 6):
        deck = (node + 1) // 2 if node % 2 else 0
        lines.append(f"1\t{node}\t{25.0 * (node - 1)}\t0\t0\t-50\t{1.0e5 * node}\t0\t0\t{deck}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return read_output(path)


def test_main_output_node_channels_are_deck_nodes_on_a_refined_line(tmp_path):
    # Ten1N3 names deck node 3 (End B), mesh node 5 of the refined line
    main = _write_main_output(tmp_path / "run.out")
    refined = _write_refined_static(tmp_path / "run.static.out")
    assert "deck_node" not in available_quantities(refined, line_id=1)
    by_static = profile_at(main, "tension", 10.0, line_id=1, positions=refined)
    np.testing.assert_allclose(by_static.location, [0.0, 100.0])
    graph = line_range_graph(main, "tension", line_id=1, positions=refined)
    np.testing.assert_allclose(graph.location, [0.0, 100.0])
    by_channels = node_range_graph(main, 1, "tension", arc_length=refined)
    np.testing.assert_allclose(by_channels.location, [0.0, 100.0])
    # the static profile's own fields stay on its mesh nodes
    own = profile_at(refined, "tension", line_id=1)
    np.testing.assert_allclose(own.location, 25.0 * np.arange(5))
    # a per-line position file lists the refined mesh: the profile beside it locates the deck nodes
    nodes = _write_nodes(tmp_path / "run.Line1.p.out")
    by_file = profile_at(main, "tension", 1.0, line_id=1, positions=nodes)
    np.testing.assert_allclose(by_file.location, [0.0, 4.0 * _chord(1.0)])
    by_file_graph = line_range_graph(main, "tension", line_id=1, positions=nodes)
    mean_arc = np.mean([4.0 * _chord(t) for t in TIMES])
    np.testing.assert_allclose(by_file_graph.location, [0.0, mean_arc])
    alone = tmp_path / "alone"
    alone.mkdir()
    unrefined = _write_nodes(alone / "run.Line1.p.out")
    by_alone = profile_at(main, "tension", 1.0, line_id=1, positions=unrefined)
    np.testing.assert_allclose(by_alone.location, [0.0, 2.0 * _chord(1.0)])


def test_line_positions_of_a_multi_line_refined_profile_keep_their_line(tmp_path):
    # line 2 is meshed as the deck; line 1 is refined (deck nodes 1, 2, 3 are mesh nodes 1, 3, 5)
    path = tmp_path / "run.static.out"
    rows = [
        "CableDyn standalone static configuration (deformed arc; public node order End A -> End B)",
        "LineID\tNode\tArcLength\tX\tY\tZ\tTension\tCurvature\tBendMoment\tDeckNode",
        "(-)\t(-)\t(m)\t(m)\t(m)\t(m)\t(N)\t(1/m)\t(N.m)\t(-)",
    ]
    for node in range(1, 6):
        deck = (node + 1) // 2 if node % 2 else 0
        arc = 25.0 * (node - 1)
        rows.append(f"1\t{node}\t{arc}\t{arc}\t0\t-50\t{1.0e5 * node}\t0\t0\t{deck}")
    for node in range(1, 4):
        arc = 50.0 * (node - 1)
        rows.append(f"2\t{node}\t{arc}\t{arc}\t10\t-50\t1e5\t0\t0\t{node}")
    path.write_text("\n".join(rows) + "\n", encoding="ascii")
    profile = read_output(path)
    main = _write_main_output(tmp_path / "run.out")
    positions = line_positions(profile, line_id=1)
    assert positions.line_id == 1
    placed = profile_at(main, "tension", 10.0, line_id=1, positions=positions)
    np.testing.assert_allclose(placed.location, [0.0, 100.0])
    # without the selected line the multi-line profile cannot name one map
    ambiguous = LinePositions(None, positions.positions, positions.node_ids, positions.source)
    with pytest.raises(ValueError, match="several lines"):
        profile_at(main, "tension", 10.0, line_id=1, positions=ambiguous)


def test_per_line_range_graph_takes_its_line_id_from_the_file_name(tmp_path):
    nodes = _write_nodes(tmp_path / "run.Line3.p.out")
    assert line_range_graph(nodes, "z").line_id == 3
    renamed = _write_nodes(tmp_path / "positions.out")
    assert line_range_graph(renamed, "z").line_id is None


def test_moordyn_quantities_keep_their_moordyn_spelling(tmp_path):
    names = ["Time"]
    for node in range(3):
        names += [f"Node{node}v{axis}" for axis in "xyz"]
        names += [f"Node{node}V{axis}" for axis in "xyz"]
    rows = "\n".join(" ".join(["0"] + ["1"] * (len(names) - 1)) for _ in range(1))
    path = tmp_path / "run.MD.Line2.out"
    path.write_text(" ".join(names) + "\n" + rows + "\n1" + " 1" * (len(names) - 1) + "\n")
    line = read_moordyn_line(path)
    assert line_field(line, "vx").quantity == "vx"
    assert line_field(line, "Vx").quantity == "Vx"
    with pytest.raises(ValueError, match="ambiguous"):
        line_field(line, "VX")
