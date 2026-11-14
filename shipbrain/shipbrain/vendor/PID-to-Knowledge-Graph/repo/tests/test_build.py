import json

import pytest

from pidkg.build import BuildError, build_graph, load_extractions
from pidkg.models import KnowledgeGraph, PageExtraction


def edges(kg, etype):
    return {(e.source, e.target) for e in kg.edges if e.type == etype}


def node(kg, nid):
    return next(n for n in kg.nodes if n.id == nid)


def test_graph_validates_against_model(mini_kg):
    KnowledgeGraph.model_validate_json(mini_kg.model_dump_json())


def test_no_build_errors(mini_kg):
    assert not [i for i in mini_kg.issues if i["severity"] == "error"]


def test_equipment_level_flow(mini_kg):
    feeds = edges(mini_kg, "FEEDS")
    assert ("TK-100", "P-101") in feeds
    assert ("P-101", "TK-200") in feeds          # crosses sheets via off-page connectors
    assert ("P-101", "TK-100") in feeds          # minimum-flow recycle through a tee
    assert ("BOUNDARY:RAW WATER SUPPLY", "TK-100") in feeds
    assert ("TK-200", "BOUNDARY:TO DISTRIBUTION") in feeds


def test_off_page_connectors_paired(mini_kg):
    flows = edges(mini_kg, "FLOWS_TO")
    assert ("P01.OPC1", "P02.OPC1") in flows
    assert node(mini_kg, "P01.OPC1").attributes["linked_to"] == "P02.OPC1"


def test_line_expansion_and_tee(mini_kg):
    # L2: P-101 -> seg1 -> V2 -> seg2 -> FT-101 -> seg3 -> FV-101 -> seg4 -> OPC1
    flows = edges(mini_kg, "FLOWS_TO")
    assert ("P-101", "P01.L2.1") in flows
    assert ("P01.L2.2", "FT-101") in flows
    assert ("FV-101", "P01.L2.4") in flows
    # The recycle line tees off the segment after V2.
    assert ("P01.L2.2", "P01.L3.1") in flows


def test_measurements(mini_kg):
    meas = edges(mini_kg, "MEASURES")
    assert ("LT-200", "TK-100") in meas
    assert ("PI-102", "P01.L2.2") in meas
    assert ("FT-101", "P01.L2.2") in meas        # in-line: measures segment upstream
    assert node(mini_kg, "FT-101").attributes["inline"] is True


def test_tag_normalized_and_merged(mini_kg):
    ids = {n.id for n in mini_kg.nodes}
    assert "FIC-101" in ids and "FIC 101" not in ids
    # TK-100 is referenced from sheet 2 by tag and must not be duplicated.
    assert sum(1 for n in mini_kg.nodes if n.tag == "TK-100") == 1


def test_control_loop_with_relay(mini_kg):
    loop = node(mini_kg, "LOOP:F-101")
    a = loop.attributes
    assert loop.kind == "control"
    assert a["sensors"] == ["FT-101"]
    assert a["controllers"] == ["FIC-101"]
    assert a["final_elements"] == ["FV-101"]
    assert a["relays"] == ["FY-101"]
    assert ("FIC-101", "FV-101") in edges(mini_kg, "ACTUATES")


def test_cascade(mini_kg):
    assert ("LOOP:L-200", "LOOP:F-101") in edges(mini_kg, "CASCADES_TO")
    assert node(mini_kg, "LOOP:F-101").attributes["cascade_master"] == "LOOP:L-200"


def test_interlock_and_vfd(mini_kg):
    trip = node(mini_kg, "LOOP:L-201")
    assert trip.kind == "interlock"
    assert ("LSLL-201", "P-101") in edges(mini_kg, "TRIPS")
    vfd = node(mini_kg, "LOOP:S-101")
    assert vfd.attributes["final_elements"] == ["P-101"]


def test_single_instruments_are_not_loops(mini_kg):
    ids = {n.id for n in mini_kg.nodes}
    assert "LOOP:P-102" not in ids
    assert "LOOP:T-210" not in ids


def test_unresolved_reference_is_reported():
    page = PageExtraction.model_validate({
        "page": 1,
        "equipment": [{"id": "TK-1", "tag": "TK-1", "kind": "tank"}],
        "lines": [{"id": "L1", "from": "TK-1", "to": "P-999"}],
    })
    kg = build_graph([page], "x", "x")
    codes = [i["code"] for i in kg.issues if i["severity"] == "error"]
    assert codes == ["unresolved_reference"]


def test_signal_to_undeclared_bubble_creates_flagged_instrument():
    page = PageExtraction.model_validate({
        "page": 1,
        "instruments": [{"id": "LT-1", "tag": "LT-1", "measures": None}],
        "signals": [{"from": "LT-1", "to": "LIC-1"}],
    })
    kg = build_graph([page], "x", "x")
    assert any(n.id == "LIC-1" and n.confidence == 0.5 for n in kg.nodes)
    assert any(i["code"] == "implicit_instrument" for i in kg.issues)


def test_schema_rejects_bad_extractions():
    with pytest.raises(Exception):
        PageExtraction.model_validate({"page": 1, "lines": [{"id": "L1", "from": {"item": "A", "line": "B"}, "to": "C"}]})
    with pytest.raises(Exception):
        PageExtraction.model_validate({"page": 1, "equipment": [
            {"id": "A", "kind": "tank"}, {"id": "A", "kind": "pump"}]})
    with pytest.raises(Exception):
        PageExtraction.model_validate({"page": 1, "equipment": [
            {"id": "A", "kind": "tank", "bbox": [0, 0, 2, 2]}]})


def test_load_reports_all_files(tmp_path):
    (tmp_path / "page_01.json").write_text(json.dumps({"page": 1, "equipment": [{"id": "A"}]}))
    (tmp_path / "page_02.json").write_text("{not json")
    with pytest.raises(BuildError) as exc:
        load_extractions(tmp_path)
    msg = str(exc.value)
    assert "page_01.json" in msg and "page_02.json" in msg
