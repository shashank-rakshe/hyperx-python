# SPDX-License-Identifier: Apache-2.0
"""Range graphs, the MBR bend check, and the tension-vs-MBL check."""

from __future__ import annotations

import csv
import math

import numpy as np
import pytest
from _design_data import ARC, TIME, node_channels, write_elements, write_main, write_static

from cabledyn import (
    API_RP_2SK_SAFETY_FACTORS,
    DNV_OS_E301_PARTIAL_FACTORS,
    BendLimits,
    RangeGraph,
    bend_check,
    element_range_graph,
    mbr_utilisation,
    node_range_graph,
    read_output,
    read_range_graph,
    read_range_graphs,
    static_range_graph,
    tension_check,
)
from cabledyn import ranges as ranges_module


@pytest.fixture
def files(tmp_path):
    return {
        "main": read_output(write_main(tmp_path / "run.out")),
        "static": read_output(write_static(tmp_path / "run.static.out")),
        "elements": read_output(write_elements(tmp_path / "run.elements.out")),
    }


def test_node_range_graph_envelopes(files, plt, tmp_path):
    graph = node_range_graph(files["main"], 1, "tension", arc_length=ARC)
    assert graph.location_kind == "ArcLength" and graph.unit == "N"
    np.testing.assert_allclose(graph.location, [0.0, 50.0, 100.0])
    np.testing.assert_allclose(graph.maximum, [1.1e6, 8.5e5, 6.0e5], rtol=1e-9)
    np.testing.assert_allclose(graph.minimum, [0.9e6, 7.5e5, 6.0e5], rtol=1e-9)
    np.testing.assert_allclose(graph.mean, [1.0e6, 8.0e5, 6.0e5], rtol=1e-6)
    assert graph.peak == pytest.approx(1.1e6) and graph.peak_location == 0.0
    assert graph.time_window == (0.0, 10.0)
    by_node = node_range_graph(files["main"], 1, "curvature", start=0.0, stop=2.0)
    assert by_node.location_kind == "Node" and by_node.unit == "1/m"
    np.testing.assert_allclose(by_node.location, [1.0, 3.0, 5.0])
    from_profile = node_range_graph(files["main"], 1, "bend_moment", arc_length=files["static"])
    np.testing.assert_allclose(from_profile.location, [0.0, 50.0, 100.0])
    assert from_profile.unit == "N-m"
    ax = graph.plot()
    static_range_graph(files["static"], 1, "tension").plot(ax=ax, label="static")
    assert ax.get_xlabel() == "Arc length [m]"
    assert by_node.plot().get_xlabel() == "Node [-]"
    target = graph.export(tmp_path / "range.csv")
    rows = list(csv.reader(target.open(encoding="utf-8")))
    assert rows[0] == ["ArcLength_[m]", "Minimum_[N]", "Maximum_[N]", "Mean_[N]"]
    assert len(rows) == 4
    with pytest.raises(FileExistsError):
        graph.export(target)


def test_static_and_element_range_graphs(files, plt, tmp_path):
    static = static_range_graph(files["static"], 1, "curvature")
    np.testing.assert_allclose(static.location, [0.0, 25.0, 50.0, 75.0, 100.0])
    assert static.peak == pytest.approx(0.04) and static.peak_location == 50.0
    assert static.unit == "1/m" and static.time_window is None
    moment = static_range_graph(files["static"], 1, "bend_moment")
    assert moment.unit == "N.m"
    peak = element_range_graph(files["elements"], 1, "curvature")
    np.testing.assert_allclose(peak.location, [45.0, 60.0])
    np.testing.assert_allclose(peak.maximum, [0.05, 0.08])
    assert peak.minimum is None and peak.mean is None
    assert element_range_graph(files["elements"], 1, "bend_moment").peak == 800.0
    axial = element_range_graph(files["elements"], 1, "axial_resultant")
    np.testing.assert_allclose(axial.location, [25.0, 75.0])
    np.testing.assert_allclose(axial.minimum, [100.0, -10.0])
    np.testing.assert_allclose(axial.maximum, [1000.0, 2000.0])
    assert peak.plot().get_ylabel() == "Curvature [1/m]"
    rows = list(csv.reader(peak.export(tmp_path / "peak.csv").open(encoding="utf-8")))
    assert rows[1] == ["45", "", "0.050000000000000003", ""]


def test_range_graph_errors(files):
    with pytest.raises(ValueError, match="quantity must be"):
        node_range_graph(files["main"], 1, "strain")
    with pytest.raises(ValueError, match="line_id"):
        node_range_graph(files["main"], 0, "tension")
    with pytest.raises(ValueError, match="line_id"):
        node_range_graph(files["main"], True, "tension")  # type: ignore[arg-type]
    with pytest.raises(KeyError, match="Curv2N"):
        node_range_graph(files["main"], 2, "curvature")
    with pytest.raises(KeyError, match="no arc length for nodes"):
        node_range_graph(files["main"], 1, "tension", arc_length={1: 0.0})
    with pytest.raises(ValueError, match="non-decreasing"):
        node_range_graph(files["main"], 1, "tension", arc_length={1: 5.0, 3: 1.0, 5: 9.0})
    with pytest.raises(ValueError, match="StaticProfile"):
        node_range_graph(files["main"], 1, "tension", arc_length=[0.0, 1.0])  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="not an element table"):
        element_range_graph(files["static"], 1, "curvature")
    with pytest.raises(KeyError, match="LineID 3"):
        element_range_graph(files["elements"], 3, "curvature")
    with pytest.raises(ValueError, match="axial_resultant"):
        element_range_graph(files["elements"], 1, "tension")


def _write_range_file(path, clearance=True, torsion=False):
    names = ["Tension", "Curvature", "BendMoment", "Declination"] + (
        ["Clearance"] if clearance else []
    )
    units = ["(N)", "(1/m)", "(N.m)", "(deg)", "(m)"][: len(names)]
    if torsion:
        names += ["Torque", "Twist"]
        units += ["(N.m)", "(deg)"]
    header = ["Node", "ArcLength"] + [f"{n}{s}" for n in names for s in ("Min", "Max", "Mean")]
    unit_row = ["(-)", "(m)"] + [u for u in units for _ in range(3)]
    rows = []
    for node, arc in enumerate((0.0, 5.0, 10.5), start=1):
        values = []
        for k in range(len(names)):
            low = 10.0 * (k + 1) + node
            values += [low, low + 2.0, low + 0.5]
        rows.append("\t".join([str(node), f"{arc:15.7E}"] + [f"{v:15.7E}" for v in values]))
    text = [
        "CableDyn range graph (line 3; 41 samples from t =  1.0000000000000000E+000 s to t =  "
        "3.0000000000000000E+000 s; public node order End A -> End B)",
        "\t".join(header),
        "\t".join(unit_row),
        *rows,
    ]
    path.write_text("\n".join(text) + "\n", encoding="utf-8")
    return path


def test_read_range_graphs_from_a_range_file(tmp_path):
    path = _write_range_file(tmp_path / "run.Line3.range.out")
    graphs = read_range_graphs(path)
    assert tuple(graphs) == ("tension", "curvature", "bend_moment", "declination", "clearance")
    tension = graphs["tension"]
    assert tension.line_id == 3 and tension.unit == "N" and tension.location_kind == "ArcLength"
    assert tension.time_window == (1.0, 3.0)
    assert np.allclose(tension.location, [0.0, 5.0, 10.5])
    assert np.allclose(tension.minimum, [11.0, 12.0, 13.0])
    assert np.allclose(tension.maximum, [13.0, 14.0, 15.0])
    assert np.allclose(tension.mean, [11.5, 12.5, 13.5])
    clearance = read_range_graph(read_output(path), "clearance")
    assert clearance.unit == "m" and np.allclose(clearance.minimum, [51.0, 52.0, 53.0])
    assert read_range_graph(path, "declination").unit == "deg"


def test_read_range_graphs_with_torsion(tmp_path):
    path = _write_range_file(tmp_path / "tw.Line3.range.out", clearance=False, torsion=True)
    graphs = read_range_graphs(path)
    assert tuple(graphs) == (
        "tension",
        "curvature",
        "bend_moment",
        "declination",
        "torque",
        "twist",
    )
    assert graphs["torque"].unit == "N.m"
    assert np.allclose(graphs["torque"].minimum, [51.0, 52.0, 53.0])
    twist = read_range_graph(path, "twist")
    assert twist.unit == "deg" and np.allclose(twist.maximum, [63.0, 64.0, 65.0])
    with pytest.raises(KeyError, match="no torque"):
        read_range_graph(_write_range_file(tmp_path / "plain.Line3.range.out"), "torque")


def test_read_range_graph_errors(files, tmp_path):
    path = _write_range_file(tmp_path / "flat.Line3.range.out", clearance=False)
    assert "clearance" not in read_range_graphs(path)
    with pytest.raises(KeyError, match="no clearance"):
        read_range_graph(path, "clearance")
    with pytest.raises(ValueError, match="quantity must be"):
        read_range_graph(path, "strain")
    with pytest.raises(ValueError, match="not a CableDyn range file"):
        read_range_graphs(files["static"])


def test_duplicate_node_channels_are_rejected(tmp_path):
    columns = node_channels()
    columns["Ten1N3"] = columns["Ten1N03"]
    columns["L1N1px"] = TIME
    columns["l1n01PX"] = TIME
    history = read_output(write_main(tmp_path / "dup.out", columns))
    with pytest.raises(ValueError, match="same node"):
        node_range_graph(history, 1, "tension")
    with pytest.raises(ValueError, match="same component"):
        ranges_module.node_position_channels(history, 1)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"location_kind": "Segment"}, "location_kind"),
        ({"location": []}, "non-empty"),
        ({"location": [1.0, 0.0]}, "non-decreasing"),
        ({"maximum": None}, "maximum is required"),
        ({"mean": [1.0]}, "mean must be finite"),
        ({"minimum": [5.0, 5.0]}, "must not exceed"),
    ],
)
def test_range_graph_validation(tmp_path, kwargs, message):
    fields = {
        "line_id": 1,
        "quantity": "tension",
        "unit": "N",
        "location_kind": "ArcLength",
        "location": [0.0, 1.0],
        "maximum": [2.0, 2.0],
        "minimum": [1.0, 1.0],
        "mean": None,
        "source": tmp_path / "x.out",
    }
    fields.update(kwargs)
    with pytest.raises(ValueError, match=message):
        RangeGraph(**fields)


def test_bend_check_from_a_time_history(files, plt, tmp_path):
    limits = BendLimits(storage_mbr=5.0, dynamic_mbr=12.0)
    check = bend_check(files["main"], limits, condition="dynamic", line_id=1, arc_length=ARC)
    assert check.mbr == 12.0 and check.condition == "dynamic"
    np.testing.assert_allclose(check.curvature, [0.015, 0.07, 0.02], rtol=1e-9)
    assert check.maximum_utilisation == pytest.approx(0.07 * 12.0)
    assert check.passed and check.critical_location == 50.0
    assert check.critical_time == pytest.approx(0.5)
    assert check.minimum_radius == pytest.approx(1.0 / 0.07)
    assert check.report().startswith("PASS: line 1 dynamic bend check")
    assert "arc 50.000 m at t = 0.5 s" in check.report()
    failing = bend_check(files["main"], 20.0, condition="dynamic", line_id=1)
    assert not failing.passed and "FAIL" in failing.report() and "node 3" in failing.report()
    assert check.plot().get_ylabel() == "MBR utilisation [-]"
    _, ax = plt.subplots()
    assert check.plot(ax=ax) is ax
    rows = list(csv.reader(check.export(tmp_path / "bend.csv").open(encoding="utf-8")))
    assert rows[0] == ["ArcLength_[m]", "Curvature_[1/m]", "Radius_[m]", "Utilisation_[-]"]
    windowed = bend_check(files["main"], limits, condition="dynamic", line_id=1, stop=0.2)
    assert windowed.maximum_utilisation < check.maximum_utilisation


def test_bend_check_from_static_and_element_sources(files, tmp_path):
    limits = BendLimits(storage_mbr=5.0, dynamic_mbr=12.0)
    static = bend_check(files["static"], limits, condition="storage", line_id=1)
    assert static.mbr == 5.0 and static.critical_time is None
    assert static.maximum_utilisation == pytest.approx(0.2)
    assert static.report().endswith("at arc 50.000 m")
    rows = list(csv.reader(static.export(tmp_path / "s.csv").open(encoding="utf-8")))
    assert rows[1][2] == "inf"
    element = bend_check(files["elements"], limits, condition="dynamic", line_id=1)
    assert element.maximum_utilisation == pytest.approx(0.96)
    straight = bend_check(files["static"], limits, condition="storage", line_id=2)
    assert straight.minimum_radius == math.inf
    with pytest.raises(ValueError, match="apply only to a time history"):
        bend_check(files["static"], limits, condition="storage", line_id=1, stop=1.0)
    with pytest.raises(ValueError, match="condition must be"):
        bend_check(files["static"], limits, condition="installation", line_id=1)
    with pytest.raises(ValueError, match="condition must be"):
        limits.mbr("installation")
    with pytest.raises(ValueError, match="mbr"):
        bend_check(files["static"], -1.0, condition="storage", line_id=1)
    with pytest.raises(ValueError, match="dynamic_mbr"):
        BendLimits(1.0, 0.0)
    with pytest.raises(ValueError, match="storage_mbr"):
        BendLimits(True, 1.0)  # type: ignore[arg-type]


def test_mbr_utilisation():
    np.testing.assert_allclose(mbr_utilisation([-0.1, 0.05], 10.0), [1.0, 0.5])
    with pytest.raises(ValueError, match="finite"):
        mbr_utilisation([math.inf], 1.0)


def test_api_tension_check(files):
    history = files["main"]
    intact = tension_check(history, ["FairTen1", "Ten1N03"], breaking_strength=2.0e6)
    assert intact.channel == "FairTen1" and intact.factors == (1.67,)
    assert intact.maximum_tension == pytest.approx(1.1e6)
    assert intact.time == pytest.approx(0.5)
    assert intact.capacity == pytest.approx(2.0e6 / 1.67)
    assert intact.utilisation == pytest.approx(1.1e6 * 1.67 / 2.0e6)
    assert intact.passed and intact.report().startswith("PASS: API RP 2SK intact")
    damaged = tension_check(
        history, "FairTen1", breaking_strength=2.0e6, condition="damaged", analysis="quasi-static"
    )
    assert damaged.factors == (API_RP_2SK_SAFETY_FACTORS[("damaged", "quasi-static")],)
    transient = tension_check(history, "FairTen1", breaking_strength=1.0e6, condition="transient")
    assert not transient.passed and transient.report().startswith("FAIL")
    custom = tension_check(
        history, "FairTen1", breaking_strength=3.0e6, standard="custom", safety_factor=2.5
    )
    assert custom.utilisation == pytest.approx(1.1e6 * 2.5 / 3.0e6)


def test_dnv_tension_check(files):
    history = files["main"]
    uls = tension_check(
        history, "FairTen1", breaking_strength=4.0e6, standard="DNV-OS-E301", consequence_class=2
    )
    gamma_mean, gamma_dyn = DNV_OS_E301_PARTIAL_FACTORS[("ULS", 2)]
    mean = float(np.mean(history.column("FairTen1")))
    assert uls.design_tension == pytest.approx(gamma_mean * mean + gamma_dyn * (1.1e6 - mean))
    assert uls.capacity == pytest.approx(0.95 * 4.0e6)
    als = tension_check(
        history, "FairTen1", breaking_strength=4.0e6, standard="DNV-OS-E301", condition="damaged"
    )
    assert als.factors == DNV_OS_E301_PARTIAL_FACTORS[("ALS", 1)]
    assert als.utilisation < uls.utilisation


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"channels": []}, "at least one"),
        ({"channels": "Time(s)"}, "time channel"),
        ({"breaking_strength": 0.0}, "breaking_strength"),
        ({"condition": "survival"}, "condition must be"),
        ({"safety_factor": 2.0}, "only to standard='custom'"),
        ({"analysis": "static"}, "analysis must be"),
        ({"standard": "DNV-OS-E301", "condition": "transient"}, "ULS"),
        ({"standard": "DNV-OS-E301", "consequence_class": 3}, "consequence_class"),
        ({"standard": "custom"}, "needs safety_factor"),
        ({"standard": "ISO"}, "standard must be"),
    ],
)
def test_tension_check_errors(files, kwargs, message):
    settings = {"channels": "FairTen1", "breaking_strength": 1.0e7, **kwargs}
    channels = settings.pop("channels")
    with pytest.raises(ValueError, match=message):
        tension_check(files["main"], channels, **settings)


def test_csv_writer_removes_its_temporary_file_on_failure(files, tmp_path, monkeypatch):
    from cabledyn import _csv

    graph = static_range_graph(files["static"], 1, "tension")

    def fail(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(_csv.os, "replace", fail)
    with pytest.raises(OSError, match="disk full"):
        graph.export(tmp_path / "out" / "range.csv")
    assert list((tmp_path / "out").iterdir()) == []


def test_dnv_strength_factor_is_selectable(files):
    from cabledyn import DNV_OS_E301_STRENGTH_FACTOR

    assert DNV_OS_E301_STRENGTH_FACTOR == 0.95
    history = files["main"]
    fibre = tension_check(
        history, "FairTen1", breaking_strength=4.0e6, standard="DNV-OS-E301", strength_factor=0.8
    )
    assert fibre.capacity == pytest.approx(0.8 * 4.0e6)
    with pytest.raises(ValueError, match=r"strength_factor must be in \(0, 1\]"):
        tension_check(
            history,
            "FairTen1",
            breaking_strength=4.0e6,
            standard="DNV-OS-E301",
            strength_factor=1.5,
        )


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"standard": "DNV-OS-E301", "analysis": "dynamic"}, "analysis applies only"),
        ({"standard": "custom", "safety_factor": 2.0, "analysis": "dynamic"}, "analysis applies"),
        ({"consequence_class": 1}, "consequence_class applies only"),
        ({"strength_factor": 0.9}, "strength_factor applies only"),
    ],
)
def test_tension_check_rejects_settings_of_another_standard(files, kwargs, message):
    with pytest.raises(ValueError, match=message):
        tension_check(files["main"], "FairTen1", breaking_strength=1.0e7, **kwargs)
