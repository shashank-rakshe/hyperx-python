# SPDX-License-Identifier: Apache-2.0
"""Gates for the programmatic deck writer and the cabledyn-deck command line."""

from __future__ import annotations

import math
from pathlib import Path

import pytest

from cabledyn import DeckFile, DeckFormatError, DeckWriter
from cabledyn.deck_cli import main as deck_main

ROOT = Path(__file__).resolve().parents[2]
CHAIN = ROOT / "examples/chain_catenary_r3_100m.dat"


def _writer(title: str = "single grounded chain") -> DeckWriter:
    deck = DeckWriter(title=title)
    deck.add_line_type(
        "main", diam=0.333, mass=685.0, ea=3.27e9, ba=-1.0, cdn=2.0, cdt=0.4, can=0.82, cat=0.27
    )
    deck.add_point(1, "Vessel", -58.0, 0.0, -14.0)
    deck.add_point(2, "Fixed", -837.6, 0.0, -200.0)
    deck.add_line(1, node_a=1, node_b=2)
    deck.add_section(line_id=1, line_type="main", length=850.0, num_segs=20)
    return deck


def _finite_ei_writer() -> DeckWriter:
    """A valid finite-EI hang-off, the only line kind that admits END CONNECTIONS."""
    deck = DeckWriter(title="finite-EI hang-off")
    deck.add_line_type(
        "cable",
        diam=0.2,
        mass=100.0,
        ea=1.0e9,
        ba=-1.0,
        ei=1.0e4,
        cdn=1.2,
        cdt=0.2,
        can=1.0,
        cat=0.0,
    )
    deck.add_point(1, "Vessel", 0.0, 0.0, -10.0)
    deck.add_point(2, "Fixed", 300.0, 0.0, -100.0)
    deck.add_line(1, node_a=1, node_b=2)
    deck.add_section(line_id=1, line_type="cable", length=350.0, num_segs=10)
    deck.set_option(0.1, "dtM")
    deck.set_option(10.0, "TMax")
    return deck


def test_writer_output_validates_and_round_trips(tmp_path):
    deck = _writer()
    deck.set_option(9.80665, "g", "Gravitational acceleration (m/s^2)")
    deck.set_option("200.0", "WtrDpth")
    deck.set_option(False, "adaptive_mesh")
    deck.add_output("FairTen1")
    path = deck.write(tmp_path / "writer.dat")
    parsed = DeckFile.read(path)
    assert parsed.option("g").values == ("9.80665",)
    assert parsed.option("g").description == "Gravitational acceleration (m/s^2)"
    assert parsed.outputs == ("FairTen1",)
    assert path.read_text(encoding="ascii") == deck.text()


def test_writer_accepts_static_friction_rows(tmp_path):
    deck = _writer()
    deck.set_option("asLaid", "staticsFriction", "Statics seabed friction policy")
    deck.set_option(45.0, "layAzimuth")
    deck.set_option(180.0, "layAzimuth1")
    deck.set_option(2.0e5, "asLaidTension1")
    parsed = DeckFile.read(deck.write(tmp_path / "friction.dat"))
    assert parsed.option("staticsFriction").values == ("asLaid",)
    assert parsed.option("layAzimuth").values == ("45.0",)
    assert parsed.option("LAYAZIMUTH1").values == ("180.0",)
    assert parsed.option("asLaidTension1").values == ("200000.0",)
    with pytest.raises(ValueError, match="unknown option keyword 'layAzimuth1x'"):
        deck.set_option(1.0, "layAzimuth1x")
    bad = _writer()
    bad.set_option(30.0, "layAzimuth7")
    with pytest.raises(DeckFormatError, match="names no LINE"):
        bad.text()


def test_set_option_rejects_swapped_value_and_keyword():
    deck = _writer()
    with pytest.raises(TypeError, match="set_option\\(value, keyword"):
        deck.set_option("dtM", 0.05)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match=r"unknown option keyword '0\.05'"):
        deck.set_option("dtM", "0.05")
    with pytest.raises(ValueError, match="unknown option keyword"):
        deck.set_option("1.0", "not_a_keyword")


@pytest.mark.parametrize(
    "title",
    [
        "section --- header",
        "uses # a comment",
        "bang ! comment",
        "two\nrows",
    ],
)
def test_title_text_that_the_native_reader_would_misparse_is_rejected(title):
    with pytest.raises(ValueError):
        _writer(title=title).text()


@pytest.mark.parametrize("description", ["a --- b", "units # m", "note ! x", "a\rb"])
def test_option_descriptions_that_would_be_misparsed_are_rejected(description):
    with pytest.raises(ValueError):
        _writer().set_option(0.1, "dtM", description)


@pytest.mark.parametrize("channel", ["Fair#1", "Fair!1", "FairTen1,AnchTen1", "a/b", "--x"])
def test_output_channels_with_native_separators_are_rejected(channel):
    with pytest.raises(ValueError):
        _writer().add_output(channel)


@pytest.mark.parametrize("name", ["R4/chain", "R4,chain", "has space", "q'uote", "c#1"])
def test_line_type_names_must_be_plain_tokens(name):
    with pytest.raises(ValueError):
        _writer().add_line_type(name, diam=0.1, mass=10.0, ea=1.0e8)


def test_text_and_write_validate_the_generated_deck(tmp_path):
    below = DeckWriter()
    below.add_line_type("main", diam=0.333, mass=685.0, ea=3.27e9)
    below.add_point(1, "Vessel", 0.0, 0.0, -300.0)
    below.add_point(2, "Fixed", 800.0, 0.0, -200.0)
    below.add_line(1, node_a=1, node_b=2)
    below.add_section(line_id=1, line_type="main", length=850.0, num_segs=20)
    with pytest.raises(DeckFormatError, match="fairlead must not be below"):
        below.text()
    with pytest.raises(DeckFormatError):
        below.write(tmp_path / "below.dat")
    assert not (tmp_path / "below.dat").exists()

    bad_value = _writer()
    bad_value.set_option("abc", "WtrDpth")
    with pytest.raises(DeckFormatError, match="WtrDpth must be numeric"):
        bad_value.text()

    unknown_channel = _writer()
    unknown_channel.add_output("Bogus1")
    with pytest.raises(DeckFormatError, match="unsupported OUTPUT channel"):
        unknown_channel.text()


def test_caller_driven_validation_route_is_selectable():
    deck = _writer()
    deck.set_option(0.1, "dtM")
    with pytest.raises(DeckFormatError, match="both dtM and TMax"):
        deck.text()
    assert "0.1 dtM" in deck.text(caller_driven=True)


def test_empty_writer_refuses_to_render_an_incomplete_deck():
    with pytest.raises(ValueError, match="at least one LINE TYPE, POINT, LINE, and SECTION"):
        DeckWriter().text()


def test_non_string_title_and_name_raise_type_error():
    with pytest.raises(TypeError, match="title must be a string"):
        _writer(title=42).text()  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="line-type name must be a string"):
        DeckWriter().add_line_type(7, diam=0.1, mass=1.0, ea=1.0)  # type: ignore[arg-type]


@pytest.mark.parametrize("ptype", ["Anchor", "Body1", 3])
def test_add_point_rejects_types_outside_the_writer_vocabulary(ptype):
    with pytest.raises(ValueError, match="unknown point type"):
        DeckWriter().add_point(1, ptype, 0.0, 0.0, 0.0)  # type: ignore[arg-type]


@pytest.mark.parametrize("num_segs", [0, -3])
def test_add_section_requires_at_least_one_segment(num_segs):
    with pytest.raises(ValueError, match="num_segs must be >= 1"):
        DeckWriter().add_section(line_id=1, line_type="cable", length=1.0, num_segs=num_segs)


@pytest.mark.parametrize(
    ("line_id", "end", "stiffness", "direction", "message"),
    [
        (0, "A", "Pinned", (1.0, 0.0, 0.0), "line_id must be positive"),
        (1, "C", "Pinned", (1.0, 0.0, 0.0), "end must be A or B"),
        (1, "A", True, (1.0, 0.0, 0.0), "non-negative, Pinned, or Rigid"),
        (1, "A", "stiff", (1.0, 0.0, 0.0), "non-negative, Pinned, or Rigid"),
        (1, "A", None, (1.0, 0.0, 0.0), "non-negative, Pinned, or Rigid"),
        (1, "A", -1.0, (1.0, 0.0, 0.0), "finite and non-negative"),
        (1, "A", math.inf, (1.0, 0.0, 0.0), "finite and non-negative"),
        (1, "A", 1.0e4, "xyz", "exactly three numeric components"),
        (1, "A", 1.0e4, (1.0, "x", 0.0), "exactly three numeric components"),
        (1, "A", 1.0e4, (1.0, 0.0), "exactly three numeric components"),
        (1, "A", 1.0e4, (1.0, math.nan, 0.0), "components must be finite"),
        (1, "A", 1.0e4, (0.0, 0.0, 0.0), "direction must be non-zero"),
    ],
)
def test_add_end_connection_rejects_invalid_arguments_without_recording_them(
    line_id, end, stiffness, direction, message
):
    deck = _finite_ei_writer()
    with pytest.raises(ValueError, match=message):
        deck.add_end_connection(line_id, end, stiffness, direction)
    assert DeckFile.from_text(deck.text()).end_connections == ()


def test_add_end_connection_writes_numeric_and_alias_stiffness():
    deck = _finite_ei_writer()
    deck.add_end_connection(1, "end_a", 2.5e4, (0.0, 0.0, -2.0))
    deck.add_end_connection(1, "B", "Free", (3.0, 0.0, 4.0))
    with pytest.raises(ValueError, match="already has a connection"):
        deck.add_end_connection(1, "endb", "Rigid", (1.0, 0.0, 0.0))
    parsed = DeckFile.from_text(deck.text())
    assert [row.tokens for row in parsed.end_connections] == [
        ("1", "A", "25000", "0", "0", "-1"),
        ("1", "B", "Pinned", "0.59999999999999998", "0", "0.80000000000000004"),
    ]


def test_set_option_rejects_container_values_and_drops_blank_descriptions():
    deck = _writer()
    with pytest.raises(TypeError, match="value must be a string, number, or Boolean"):
        deck.set_option([0.1], "dtM")  # type: ignore[arg-type]
    deck.set_option(9.81, "g", "   ")
    assert "9.81 g\n" in deck.text()
    assert DeckFile.from_text(deck.text()).option("g").description is None


# ---------------------------------------------------------------------------
# cabledyn-deck
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["-1e-3", "-15", "-.5", "-2.5E+1"])
def test_cli_accepts_negative_numbers_as_values(tmp_path, value):
    edited = tmp_path / "edited.dat"
    assert deck_main(["set", str(CHAIN), str(edited), "point.2.z", value]) == 0
    assert float(DeckFile.read(edited).points[1].tokens[4]) == float(value)


def _cli_error(capsys, argv):
    with pytest.raises(SystemExit) as raised:
        deck_main(argv)
    assert raised.value.code == 1
    return capsys.readouterr().err


def test_cli_rejects_json_null_and_objects(tmp_path, capsys):
    target = str(tmp_path / "out.dat")
    assert "not null" in _cli_error(capsys, ["set", str(CHAIN), target, "point.2.z", "null"])
    assert "not null" in _cli_error(capsys, ["set", str(CHAIN), target, "point.2.z", '{"a": 1}'])
    assert not (tmp_path / "out.dat").exists()


def test_cli_reports_missing_records_without_repr_quotes(tmp_path, capsys):
    err = _cli_error(capsys, ["set", str(CHAIN), str(tmp_path / "o.dat"), "point.9.z", "1"])
    assert err == "cabledyn-deck: point 9 does not exist\n"


def test_cli_labels_errors_in_the_edited_deck(tmp_path, capsys):
    err = _cli_error(capsys, ["set", str(CHAIN), str(tmp_path / "o.dat"), "point.2.z", "-200"])
    assert err.startswith("cabledyn-deck: edited copy of ")
    assert "fairlead must not be below its anchor" in err


def test_cli_rejects_case_insensitive_duplicate_selectors(tmp_path, capsys):
    spec = tmp_path / "spec.json"
    spec.write_text('{"deep": {"point.2.z": -15, "Point.2.Z": -16}}', encoding="utf-8")
    err = _cli_error(capsys, ["generate", str(CHAIN), str(spec), str(tmp_path / "cases")])
    assert "address the same deck field" in err
    assert not (tmp_path / "cases" / "deep.dat").exists()


def test_cli_rejects_duplicate_json_keys_in_case_spec(tmp_path, capsys):
    spec = tmp_path / "spec.json"
    spec.write_text('{"deep": {"point.2.z": -15, "point.2.z": -16}}', encoding="utf-8")
    err = _cli_error(capsys, ["generate", str(CHAIN), str(spec), str(tmp_path / "cases")])
    assert "duplicate key 'point.2.z'" in err


@pytest.mark.parametrize(
    ("call", "message"),
    [
        (lambda deck: deck.add_point(1.7, "Fixed", 0.0, 0.0, -50.0), "point_id"),
        (lambda deck: deck.add_line(1, node_a=2.0, node_b=1), "node_a"),
        (
            lambda deck: deck.add_section(line_id=1, line_type="c", length=1.0, num_segs=2.5),
            "num_segs",
        ),
        (lambda deck: deck.add_end_connection(True, "A", 0.0, (0, 0, 1)), "line_id"),
    ],
)
def test_writer_ids_must_be_integers(call, message):
    from cabledyn import DeckWriter

    with pytest.raises(TypeError, match=message):
        call(DeckWriter("t"))


def test_writer_units_row_names_the_damping_and_bending_units():
    from cabledyn import DeckWriter

    deck = DeckWriter("t")
    deck.add_line_type("c", diam=0.1, mass=20.0, ea=1.0e9, ba=-1.0)
    deck.add_point(1, "Fixed", 400.0, 0.0, -50.0)
    deck.add_point(2, "Vessel", 0.0, 0.0, 0.0)
    deck.add_line(1, node_a=2, node_b=1)
    deck.add_section(line_id=1, line_type="c", length=410.0, num_segs=10)
    deck.set_option(50.0, "WtrDpth")
    assert "(-) (m) (kg/m) (N) (N-s) (N-m^2) (-) (-) (-) (-)" in deck.text()
