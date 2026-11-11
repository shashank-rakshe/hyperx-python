"""Regression tests for situations found on the real test drawings."""

from pidkg.build import build_graph
from pidkg.isa import parse_isa_tag
from pidkg.models import PageExtraction


def page(n, dn, **kw):
    return PageExtraction.model_validate({"page": n, "sheet": {"drawing_number": dn}, **kw})


def edges(kg, etype):
    return {(e.source, e.target) for e in kg.edges if e.type == etype}


def node(kg, nid):
    return next(n for n in kg.nodes if n.id == nid)


def codes(kg):
    return [i["code"] for i in kg.issues]


def test_off_page_pairing_is_one_to_one_and_respects_drawing_numbers():
    # Two outgoing flags on sheet A; only one points at sheet B. The other must stay unmatched.
    a = page(1, "PID-A",
             equipment=[{"id": "T1", "tag": "T-1", "kind": "tank"}],
             lines=[{"id": "L1", "line_number": "2-X-001", "from": "T1", "to": "O1"},
                    {"id": "L2", "line_number": "2-X-002", "from": "T1", "to": "O2"}],
             off_page_connectors=[{"id": "O1", "direction": "out", "other_drawing": "PID-B", "line_number": "2-X-001"},
                                  {"id": "O2", "direction": "out", "other_drawing": "PID-Z", "line_number": "2-X-002"}])
    b = page(2, "PID-B",
             equipment=[{"id": "T2", "tag": "T-2", "kind": "tank"}],
             lines=[{"id": "L1", "line_number": "2-X-001", "from": "I1", "to": "T2"}],
             off_page_connectors=[{"id": "I1", "direction": "in", "other_drawing": "PID-A", "line_number": "2-X-001"}])
    kg = build_graph([a, b], "t", "t")
    assert ("P01.O1", "P02.I1") in edges(kg, "FLOWS_TO")
    assert ("P01.O2", "P02.I1") not in edges(kg, "FLOWS_TO")
    unmatched = [i["node"] for i in kg.issues if i["code"] == "unmatched_off_page"]
    assert unmatched == ["P01.O2"]


def test_off_page_line_number_overrides_wrong_flag_and_is_flagged():
    a = page(1, "D-007-0", equipment=[{"id": "T1", "tag": "T-1", "kind": "tank"}],
             lines=[{"id": "L1", "line_number": "400-RWW-H1", "from": "T1", "to": "O1"}],
             off_page_connectors=[{"id": "O1", "direction": "out", "other_drawing": "D-099", "line_number": "400-RWW-H1"}])
    b = page(2, "D-009-0", equipment=[{"id": "T2", "tag": "T-2", "kind": "tank"}],
             lines=[{"id": "L1", "line_number": "400-RWW-H1", "from": "I1", "to": "T2"}],
             off_page_connectors=[{"id": "I1", "direction": "in", "other_drawing": "D-007", "line_number": "400-RWW-H1"}])
    kg = build_graph([a, b], "t", "t")
    assert ("T-1", "T-2") in edges(kg, "FEEDS")
    assert "off_page_reference_mismatch" in codes(kg)


def test_revision_suffix_matches_drawing_number():
    a = page(1, "D-007-0", equipment=[{"id": "T1", "tag": "T-1", "kind": "tank"}],
             lines=[{"id": "L1", "from": "T1", "to": "O1"}],
             off_page_connectors=[{"id": "O1", "direction": "out", "other_drawing": "D-009"}])
    b = page(2, "D-009-0", equipment=[{"id": "T2", "tag": "T-2", "kind": "tank"}],
             lines=[{"id": "L1", "from": "I1", "to": "T2"}],
             off_page_connectors=[{"id": "I1", "direction": "in", "other_drawing": "D-007"}])
    kg = build_graph([a, b], "t", "t")
    assert ("T-1", "T-2") in edges(kg, "FEEDS")
    assert "off_page_reference_mismatch" not in codes(kg)


def test_same_tag_on_two_sheets_measuring_different_equipment_is_kept_apart():
    def sheet(n, tank):
        return page(n, f"S-{n}", equipment=[{"id": tank, "tag": tank, "kind": "tank"}],
                    instruments=[{"id": "LIT", "tag": "LIT-0101", "measures": {"item": tank}}])
    kg = build_graph([sheet(1, "TK-1"), sheet(2, "TK-2")], "t", "t")
    lit = [n.id for n in kg.nodes if n.tag == "LIT-0101"]
    assert sorted(lit) == ["LIT-0101@S-1", "LIT-0101@S-2"]
    assert "tag_reused" in codes(kg)


def test_same_tag_on_two_sheets_for_same_item_merges():
    def sheet(n):
        return page(n, f"S-{n}", equipment=[{"id": "TK-1", "tag": "TK-1", "kind": "tank"}],
                    instruments=[{"id": "LIT", "tag": "LIT-0101", "measures": {"item": "TK-1"}}])
    kg = build_graph([sheet(1), sheet(2)], "t", "t")
    assert [n.id for n in kg.nodes if n.tag == "LIT-0101"] == ["LIT-0101"]


def test_duplicate_tag_on_one_sheet_gets_separate_nodes_and_loops():
    p = page(1, "S-1", equipment=[{"id": "P1", "tag": "P-1", "kind": "pump"}, {"id": "P2", "tag": "P-2", "kind": "pump"}],
             instruments=[{"id": "A", "tag": "PI-0502", "measures": {"item": "P1"}},
                          {"id": "B", "tag": "PI-0502", "measures": {"item": "P2"}}])
    kg = build_graph([p], "t", "t")
    assert {"PI-0502", "PI-0502#2"} <= {n.id for n in kg.nodes}
    assert "duplicate_tag" in codes(kg)
    assert not any(n.type == "ControlLoop" for n in kg.nodes)  # two lone gauges are not a loop


def test_part_of_equipment_is_not_unconnected():
    from pidkg.qa import run_qa

    p = page(1, "S-1", equipment=[{"id": "TK", "tag": "TK-1", "kind": "tank"},
                                  {"id": "AG", "tag": "AG-1", "kind": "agitator", "part_of": "TK"}],
             lines=[{"id": "L1", "from": "B1", "to": "TK"}], boundaries=[{"id": "B1", "name": "FEED", "direction": "source"}],
             instruments=[{"id": "HS", "tag": "HS-A1"}], signals=[{"from": "HS", "to": "AG", "purpose": "control"}])
    kg = build_graph([p], "t", "t")
    assert ("AG-1", "TK-1") in edges(kg, "PART_OF")
    assert not [i for i in run_qa(kg) if i["code"] == "equipment_not_connected"]
    loop = next(n for n in kg.nodes if n.type == "ControlLoop")
    assert loop.kind == "manual" and loop.attributes["final_elements"] == ["AG-1"]


def test_untagged_gauge_needs_function_not_invented_tag():
    p = page(1, "S-1", equipment=[{"id": "P1", "tag": "P-1", "kind": "pump"}],
             lines=[{"id": "L1", "from": "P1", "to": "B1"}], boundaries=[{"id": "B1", "name": "OUT", "direction": "sink"}],
             instruments=[{"id": "G", "function": "PI", "measures": {"line": "L1"}}])
    kg = build_graph([p], "t", "t")
    g = node(kg, "P01.G")
    assert g.tag is None and g.attributes["untagged"] is True and g.attributes["variable"] == "pressure"


def test_valve_type_codes_are_not_loop_members():
    p = page(1, "S-1", equipment=[{"id": "T", "tag": "T-1", "kind": "tank"}],
             components=[{"id": "K", "tag": "KGV-1201", "kind": "knife_gate_valve"},
                         {"id": "F", "tag": "FV-1201", "kind": "control_valve"}],
             lines=[{"id": "L1", "from": "B1", "to": "T", "path": ["K", "F"]}],
             boundaries=[{"id": "B1", "name": "IN", "direction": "source"}],
             instruments=[{"id": "FT", "tag": "FT-1201", "measures": {"line": "L1"}},
                          {"id": "FC", "tag": "FIC-1201", "location": "dcs"}],
             signals=[{"from": "FT", "to": "FC"}, {"from": "FC", "to": "F", "purpose": "control"}])
    kg = build_graph([p], "t", "t")
    loop = node(kg, "LOOP:F-1201")
    assert loop.attributes["final_elements"] == ["FV-1201"]
    assert "KGV-1201" not in {e.source for e in kg.edges if e.type == "MEMBER_OF"}


def test_panel_readouts_are_not_counted_as_sensors():
    p = page(1, "S-1", equipment=[{"id": "P", "tag": "PU-1", "kind": "pump"}],
             lines=[{"id": "L1", "from": "B1", "to": "P"}], boundaries=[{"id": "B1", "name": "IN", "direction": "source"}],
             instruments=[{"id": "SC", "tag": "SC-1"}, {"id": "YI", "tag": "SI-1", "location": "main_panel"}],
             signals=[{"from": "SC", "to": "P", "purpose": "control"}])
    kg = build_graph([p], "t", "t")
    loop = node(kg, "LOOP:S-1")
    assert loop.attributes["variable"] == "speed/frequency"
    assert loop.attributes.get("readouts") == ["SI-1"] and not loop.attributes.get("sensors")


def test_isa_state_suffix_and_alphanumeric_loop_numbers():
    zio = parse_isa_tag("ZIO-1002")
    assert zio.loop_key == "Z-1002" and "open" in zio.functions
    assert parse_isa_tag("XSC-1002").loop_key == "X-1002"
    assert parse_isa_tag("HS-R21").loop_key == "H-R21"
    assert parse_isa_tag("HS-R21").role == "hand_switch"


def test_pfd_flow_does_not_shadow_pid_detail():
    pfd = PageExtraction.model_validate({
        "page": 1, "sheet": {"drawing_number": "G-1", "drawing_type": "pfd"},
        "equipment": [{"id": "A", "tag": "TK-1", "kind": "tank"}, {"id": "PU", "kind": "pump"},
                      {"id": "B", "tag": "TK-2", "kind": "tank"}],
        "lines": [{"id": "L1", "from": "A", "to": "PU"}, {"id": "L2", "from": "PU", "to": "B"}]})
    pid = page(2, "P-1", equipment=[{"id": "A", "tag": "TK-1", "kind": "tank"}, {"id": "P", "tag": "P-1", "kind": "pump"},
                                    {"id": "B", "tag": "TK-2", "kind": "tank"}],
               lines=[{"id": "L1", "from": "A", "to": "P"}, {"id": "L2", "from": "P", "to": "B"}])
    kg = build_graph([pfd, pid], "t", "t")
    feeds = {(e.source, e.target): e.attributes.get("view") for e in kg.edges if e.type == "FEEDS"}
    assert ("TK-1", "P-1") in feeds and feeds[("TK-1", "P-1")] is None
    assert ("TK-1", "TK-2") not in feeds  # PFD shortcut already covered by the P&ID path
