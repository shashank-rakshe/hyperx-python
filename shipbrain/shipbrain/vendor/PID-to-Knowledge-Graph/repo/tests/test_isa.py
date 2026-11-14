import pytest

from pidkg.isa import normalize_tag, parse_isa_tag


@pytest.mark.parametrize("raw, expected", [
    ("FIT 0502", "FIT-0502"),
    ("fit-0502", "FIT-0502"),
    ("FIT0502", "FIT-0502"),
    ("FIT_0502", "FIT-0502"),
    ("660 TK 004", "660-TK-004"),
    ("660-TK-004", "660-TK-004"),
    ("P-101A", "P-101A"),
    ("LIC – 200", "LIC-200"),
    ("  ", None),
    (None, None),
])
def test_normalize_tag(raw, expected):
    assert normalize_tag(raw) == expected


@pytest.mark.parametrize("tag, role, variable, loop", [
    ("FIT-0502", "transmitter", "flow", "F-0502"),
    ("FE-0502", "element", "flow", "F-0502"),
    ("FIC-101", "controller", "flow", "F-101"),
    ("FV-101", "final_element", "flow", "F-101"),
    ("FY-101", "relay", "flow", "F-101"),
    ("LSLL-201", "switch", "level", "L-201"),
    ("PI-102", "indicator", "pressure", "P-102"),
    ("PDIT-300", "transmitter", "differential pressure", "P-300"),
    ("FQI-12", "indicator", "integrate/totalize flow", "F-12"),
    ("PSV-7", "relief_device", "pressure", "P-7"),
    ("LAH-1201", "alarm", "level", "L-1201"),
    ("SIC-101", "controller", "speed/frequency", "S-101"),
    ("HS-1201", "hand_switch", "hand", "H-1201"),
    ("HS-R21", "hand_switch", "hand", "H-R21"),
    ("PI-A1", "indicator", "pressure", "P-A1"),
])
def test_parse_isa(tag, role, variable, loop):
    p = parse_isa_tag(tag)
    assert p is not None
    assert p.role == role
    assert p.variable == variable
    assert p.loop_key == loop


def test_parse_isa_with_area_prefix():
    p = parse_isa_tag("660-FIT-0502")
    assert p.prefix == "660"
    assert p.loop_key == "660-F-0502"


@pytest.mark.parametrize("tag", ["660-TK-004", "SB-1200X-Y-Z", "HELLO", "12345"])
def test_non_isa_or_ambiguous(tag):
    p = parse_isa_tag(tag)
    # Equipment tags may parse syntactically; what matters is they are never
    # parsed when they cannot be ISA tags at all.
    if tag in ("HELLO", "12345", "SB-1200X-Y-Z"):
        assert p is None
