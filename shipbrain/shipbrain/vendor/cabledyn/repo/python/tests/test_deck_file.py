# SPDX-License-Identifier: Apache-2.0
"""Gates for loss-aware deck editing and case generation."""

from __future__ import annotations

import json
import math
import os
import re
import shutil
from pathlib import Path

import pytest

from cabledyn import DeckFile, DeckFormatError, DeckWriter, generate_deck_cases
from cabledyn.deck_cli import main as deck_main

ROOT = Path(__file__).resolve().parents[2]


def _minimal_chain_source() -> str:
    """Return the stable mutation fixture derived from the public deck.

    The maintained example intentionally lists every default. Parser unit tests
    that inject one option need a minimal OPTIONS block so native last-row-wins
    semantics do not make an unrelated documented default override the fixture.
    """
    text = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    remove = {
        "cbot",
        "rhoinf",
        "modified_newton",
        "adaptive_mesh",
        "cable_load_feedback",
        "dynamic_solver",
        "frictionmu",
        "current",
        "waves",
        "waterkin",
    }
    result: list[str] = []
    in_options = False
    for line in text.splitlines(keepends=True):
        if "OPTIONS" in line and line.lstrip().startswith("-"):
            in_options = True
        elif "OUTPUTS" in line and line.lstrip().startswith("-"):
            in_options = False
        if in_options:
            visible = line.split(" - ", 1)[0].split()
            keyword = ""
            if visible:
                keyword = (
                    visible[0]
                    if visible[0].lower() == "dynamic_solver"
                    else (visible[1] if len(visible) > 1 else "")
                )
            if keyword.lower() in remove or line.lstrip().startswith("-- Complete option"):
                continue
            line = re.sub(r" \[default:[^\]]*\](?=\r?\n?$)", "", line)
        result.append(line)
    return "".join(result)


def _end_connection_source() -> str:
    source = (ROOT / "examples/lozon_gomex80_power_cable.dat").read_text(encoding="utf-8")
    section = (
        "--------------------- END CONNECTIONS ---------------------------------------\n"
        "LineID End Stiffness EzX EzY EzZ\n"
        "(-) (-) (N-m/rad) (-) (-) (-)\n"
        "1 EndA 2.0e4 -0.25 0.0 -0.97\n"
    )
    return source.replace(
        "--------------------- OPTIONS -----------------------------------------------\n",
        section + "--------------------- OPTIONS -----------------------------------------------\n",
        1,
    )


@pytest.mark.parametrize(
    ("relative", "caller_driven"),
    [
        ("examples/chain_catenary_r3_100m.dat", False),
        ("examples/syrope_polyester_mooring.dat", False),
        ("examples/iea15mw_umaine_mixed_cabledyn.dat", True),
    ],
)
def test_production_decks_parse_and_round_trip_without_edits(relative, caller_driven):
    path = ROOT / relative
    deck = DeckFile.read(path, caller_driven=caller_driven)
    assert deck.text() == path.read_text(encoding="utf-8")
    assert deck.line_types and deck.points and deck.lines and deck.sections


def test_end_connections_round_trip_edit_and_cli_inventory(tmp_path, capsys):
    path = tmp_path / "end-connection.dat"
    path.write_text(_end_connection_source(), encoding="utf-8")
    deck = DeckFile.read(path)
    assert len(deck.end_connections) == 1
    assert deck.end_connections[0].tokens == (
        "1",
        "EndA",
        "2.0e4",
        "-0.25",
        "0.0",
        "-0.97",
    )

    deck.apply_many(
        {
            "end_connection.1.A.stiffness": "Rigid",
            "end_connection.1.EndA.ezx": -1.0,
            "end_connection.1.end_a.ezy": 0.0,
            "end_connection.1.a.ezz": 0.0,
        }
    )
    target = deck.write(tmp_path / "edited-end-connection.dat")
    edited = DeckFile.read(target)
    assert edited.end_connections[0].tokens == ("1", "EndA", "Rigid", "-1", "0", "0")

    assert deck_main(["show", str(target)]) == 0
    assert "end_connections: 1" in capsys.readouterr().out


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 C 2.0e4 -0.25 0.0 -0.97", "End must be A or B"),
        ("1 A -1 -0.25 0.0 -0.97", "stiffness must be finite and non-negative, Pinned, or Rigid"),
        ("1 A nan -0.25 0.0 -0.97", "stiffness must be finite"),
        ("1 A 2.0e4 0 0 0", "direction must be non-zero"),
        ("9 A 2.0e4 -0.25 0.0 -0.97", "references an undefined line"),
    ],
)
def test_end_connection_invalid_rows_fail_python_preflight(tmp_path, row, message):
    source = _end_connection_source().replace(
        "1 EndA 2.0e4 -0.25 0.0 -0.97",
        row,
    )
    path = tmp_path / "invalid-end-connection.dat"
    path.write_text(source, encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


def test_end_connection_duplicate_and_unsupported_topology_fail_preflight(tmp_path):
    source = _end_connection_source().replace(
        "1 EndA 2.0e4 -0.25 0.0 -0.97\n",
        "1 EndA 2.0e4 -0.25 0.0 -0.97\n1 a Rigid -1 0 0\n",
    )
    duplicate = tmp_path / "duplicate-end-connection.dat"
    duplicate.write_text(source, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="duplicate END CONNECTIONS"):
        DeckFile.read(duplicate)

    moving_source = _end_connection_source().replace(
        "2   Fixed    125.0   0.0  -80.0",
        "2   Connect  125.0   0.0  -80.0",
    )
    moving = tmp_path / "moving-end-connection.dat"
    moving.write_text(moving_source, encoding="utf-8")
    # a Connect End B can neither hold the connection nor drive it (a Coupled/Vessel one can)
    with pytest.raises(DeckFormatError, match="need End B on a Fixed, Coupled or Vessel point"):
        DeckFile.read(moving)


def test_deck_writer_authors_normalized_end_connections(tmp_path):
    writer = DeckWriter(title="finite-EI cable with a rigid hang-off")
    writer.add_line_type(
        "cable",
        diam=0.2,
        mass=250.0,
        ea=8.0e8,
        ei=2.0e5,
        cdn=1.0,
        cdt=0.1,
        can=1.0,
        cat=0.0,
    )
    writer.add_point(1, "Coupled", 0.0, 0.0, -10.0)
    writer.add_point(2, "Fixed", 100.0, 0.0, -80.0)
    writer.add_line(1, node_a=1, node_b=2)
    writer.add_section(line_id=1, line_type="cable", length=130.0, num_segs=40)
    writer.add_end_connection(1, "EndA", "Infinity", (0.0, 0.0, -2.0))
    writer.set_option(0.05, "dtM")
    writer.set_option(0.0, "TMax")
    path = writer.write(tmp_path / "writer-end-connection.dat")

    parsed = DeckFile.read(path)
    assert parsed.end_connections[0].tokens == ("1", "A", "Rigid", "0", "0", "-1")
    with pytest.raises(ValueError, match="already has a connection"):
        writer.add_end_connection(1, "A", 1.0e4, (1.0, 0.0, 0.0))
    with pytest.raises(ValueError, match="non-zero"):
        DeckWriter().add_end_connection(1, "A", "Pinned", (0.0, 0.0, 0.0))
    with pytest.raises(ValueError, match="exactly three"):
        DeckWriter().add_end_connection(1, "A", "Pinned", None)  # type: ignore[arg-type]


def test_editors_change_only_selected_rows_and_preserve_comments(tmp_path):
    source = ROOT / "examples/chain_catenary_r3_100m.dat"
    deck = DeckFile.read(source)
    original_lines = deck.text().splitlines()
    deck.set_option("WtrDpth", 120.0)
    deck.set_point(2, z=-5.0)
    deck.set_line_type("chainR3", ea=1.7e9)
    deck.set_section(1, length=560.0, numsegs=56)
    target = deck.write(tmp_path / "edited.dat")
    edited = target.read_text(encoding="utf-8")
    assert "120 WtrDpth   - Water depth (m)" in edited
    assert "2 Coupled 0.0 0.0 -5" in edited
    assert float(DeckFile.read(target).line_types[0].tokens[3]) == 1.7e9
    assert "1 chainR3 560 56" in edited
    changed = sum(a != b for a, b in zip(original_lines, edited.splitlines(), strict=True))
    assert changed == 4
    assert "-- R3 studless chain" in edited


def test_crlf_round_trips_and_native_whitespace_tokens_fail_closed(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    crlf = source.replace("\n", "\r\n")
    path = tmp_path / "windows.dat"
    path.write_bytes(crlf.encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.text().encode("utf-8") == path.read_bytes()
    with pytest.raises(ValueError, match="cannot contain quotes or line breaks"):
        deck.set_line_type("chainR3", ea='SYROPE:data/my"settings.dat|1.0|2.0')
    # The native static route has no Syrope model, so the edit is rejected and
    # rolled back on this static deck.
    with pytest.raises(DeckFormatError, match="Syrope line has no static output"):
        deck.set_line_type(
            "chainR3",
            ea="SYROPE:data/my_settings.dat|1.0|2.0",
            ba="1.0|1.0",
        )
    assert deck.text().encode("utf-8") == path.read_bytes()
    deck.set_line_type("chainR3", ea="2.5e9|3.0e9")
    target = deck.write(tmp_path / "edited.dat")
    written = target.read_bytes()
    assert written.count(b"\r\n") == crlf.count("\r\n")
    assert b"2.5e9|3.0e9" in written


def test_syrope_tokens_and_positional_wave_option_are_preserved(tmp_path):
    source = ROOT / "examples/syrope_polyester_mooring.dat"
    deck = DeckFile.read(source)
    assert deck.line_types[0].tokens[3].startswith("SYROPE:")
    deck.set_option("dtM", 0.025)
    target = deck.write(tmp_path / "syrope.dat")
    assert "SYROPE:data/syrope/syrope_settings.dat" in target.read_text(encoding="utf-8")

    deck.set_line_type("rope", cdt=0.2)
    assert '"SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"' in deck.text()

    wave_source = ROOT / "examples/dynamic_chain_waves.dat"
    waves = DeckFile.read(wave_source)
    waves.set_option("waves", ("airy", 3.0, 9.0, 15.0))
    assert waves.option("waves").values == ("airy", "3", "9", "15")


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ("|1.53e8|23.12", "|0|23.12", "alpha and beta must be positive"),
        ("|1.53e8|23.12", "|1.53e8|-1", "alpha and beta must be positive"),
        ("5.0e10|1.0e5", "0|0", "non-negative with a positive sum"),
        ("5.0e10|1.0e5", "-1|1", "non-negative with a positive sum"),
    ],
)
def test_syrope_constitutive_ranges_match_native_parser(tmp_path, old, new, message):
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    path = tmp_path / "invalid-syrope-constants.dat"
    path.write_text(source.replace(old, new), encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


def test_native_section_aliases_and_stock_hydro_columns_are_not_mislabelled(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("LINE TYPES", "LINE DICTIONARY", 1)
    source = source.replace("OPTIONS", "SOLVER OPTIONS", 1)
    source = source.replace("OUTPUTS", "OUTPUT", 1)
    source = source.replace("Cd_n  Cd_t  Ca_n  Ca_t", "Cd_n  Ca_n  CdAx  CaAx")
    path = tmp_path / "aliases.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    assert deck.option("WtrDpth").values == ("100.0",)
    deck.set_line_type("chainR3", cdax=0.25)
    assert deck.line_types[0].tokens[8] == "0.25"
    with pytest.raises(KeyError, match="unknown field"):
        deck.set_line_type("chainR3", cdt=0.25)


def test_hydro_column_order_tracks_each_line_type_header(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0",
        "chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0\n"
        "Name Diam Mass EA BA EI Cd Ca CdAx CaAx\n"
        "wire 0.1 10 1e8 0 0 1.2 1.0 0.2 0.0",
    )
    path = tmp_path / "mixed-hydro-headers.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)

    deck.set_line_type("chainR3", cdt=0.7)
    deck.set_line_type("wire", cdax=0.5)
    assert float(deck.line_types[0].tokens[7]) == pytest.approx(0.7)
    assert float(deck.line_types[1].tokens[7]) == pytest.approx(1.0)
    assert float(deck.line_types[1].tokens[8]) == pytest.approx(0.5)


def test_descriptive_table_header_with_apostrophe_is_skipped_before_tokenization(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "TypeName   Diam",
        "CableDyn's descriptive coefficient header\nTypeName   Diam",
        1,
    )
    path = tmp_path / "apostrophe-header.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    assert deck.line_types[0].tokens[0] == "chainR3"
    deck.set_line_type("chainR3", cdt=0.75)
    assert deck.line_types[0].tokens[7] == "0.75"


def test_finite_ei_hydro_edit_does_not_overwrite_structural_columns(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "TypeName   Diam     MassDenInAir   EA         BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t",
        "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat",
    ).replace(
        "chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0",
        "chainR3 0.2466 373.5 1.607e9 -1.0 2e4 3e8 4e4 5.0 6.0 1.37 0.64 1.0 0.0",
    )
    path = tmp_path / "finite-ei.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path, caller_driven=True)
    deck.set_line_type("chainR3", cdn=2.25)
    tokens = deck.line_types[0].tokens
    assert tokens[6:10] == ("3e8", "4e4", "5.0", "6.0")
    assert tokens[10] == "2.25"


def test_hydro_column_sniffing_uses_last_visible_header_not_comments(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    cable_order = source.replace(
        "TypeName   Diam",
        "# migration note: old order was Cd Ca CdAx CaAx\nTypeName   Diam",
    )
    cable_path = tmp_path / "cable-order.dat"
    cable_path.write_text(cable_order, encoding="utf-8")
    cable = DeckFile.read(cable_path)
    cable.set_line_type("chainR3", cdt=0.75)
    assert cable.line_types[0].tokens[7] == "0.75"

    stock_order = source.replace(
        "TypeName   Diam     MassDenInAir   EA         BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t",
        "! CableDyn Cdt note\nTypeName Diam Mass EA BA EI Cd Ca CdAx CaAx",
    )
    stock_path = tmp_path / "stock-order.dat"
    stock_path.write_text(stock_order, encoding="utf-8")
    stock = DeckFile.read(stock_path)
    stock.set_line_type("chainR3", cdax=0.25)
    assert stock.line_types[0].tokens[8] == "0.25"


def test_three_column_and_stock_seven_column_lines_match_native_contract(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    three = source.replace("1     2       1       -", "1 2 1")
    three_path = tmp_path / "three.dat"
    three_path.write_text(three, encoding="utf-8")
    assert len(DeckFile.read(three_path).lines[0].tokens) == 3

    start = source.index("--------------------- LINES")
    stop = source.index("--------------------- OPTIONS")
    stock_block = (
        "--------------------- LINES --------------------------------------------\n"
        "ID LineType AttachA AttachB UnstrLen NumSegs Outputs\n"
        "(-) (-) (-) (-) (m) (-) (-)\n"
        "1 chainR3 2 1 550.0 55 -\n"
    )
    stock = source[:start] + stock_block + source[stop:]
    stock_path = tmp_path / "stock.dat"
    stock_path.write_text(stock, encoding="utf-8")
    parsed = DeckFile.read(stock_path)
    assert not parsed.sections
    assert len(parsed.lines[0].tokens) == 7
    parsed.set_section(1, length=600.0, numsegs=60)
    assert parsed.lines[0].tokens[4:6] == ("600", "60")

    before = parsed.text()
    with pytest.raises(DeckFormatError, match="LINE Outputs accepts only"):
        parsed.set_section(1, outputs="x")
    assert parsed.text() == before

    invalid_explicit = tmp_path / "invalid-explicit-output.dat"
    invalid_explicit.write_text(
        source.replace("1     2       1       -", "1     2       1       x"),
        encoding="utf-8",
    )
    with pytest.raises(DeckFormatError, match="LINE Outputs accepts only"):
        DeckFile.read(invalid_explicit)

    valid_flags = tmp_path / "valid-output-flags.dat"
    valid_flags.write_text(
        source.replace("1     2       1       -", "1     2       1       PtT"),
        encoding="utf-8",
    )
    DeckFile.read(valid_flags)


def test_fortran_d_exponent_lengths_match_native_parser(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    explicit_path = tmp_path / "explicit-d.dat"
    explicit_path.write_text(
        source.replace("1        chainR3    550.0    55", "1 chainR3 5.5D+2 55"),
        encoding="utf-8",
    )
    assert DeckFile.read(explicit_path).sections[0].tokens[2] == "5.5D+2"

    start = source.index("--------------------- LINES")
    stop = source.index("--------------------- OPTIONS")
    stock_block = (
        "--------------------- LINES --------------------------------------------\n"
        "ID LineType AttachA AttachB UnstrLen NumSegs Outputs\n"
        "(-) (-) (-) (-) (m) (-) (-)\n"
        "1 chainR3 2 1 5.5d+2 55 -\n"
    )
    stock_path = tmp_path / "stock-d.dat"
    stock_path.write_text(source[:start] + stock_block + source[stop:], encoding="utf-8")
    assert DeckFile.read(stock_path).lines[0].tokens[4] == "5.5d+2"


def test_numsegs_native_ceiling_applies_to_explicit_and_stock_rows(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    explicit_path = tmp_path / "explicit-too-many.dat"
    explicit_path.write_text(
        source.replace("1        chainR3    550.0    55", "1 chainR3 550.0 1000001"),
        encoding="utf-8",
    )
    with pytest.raises(DeckFormatError, match="between 1 and 1000000"):
        DeckFile.read(explicit_path)

    start = source.index("--------------------- LINES")
    stop = source.index("--------------------- OPTIONS")
    stock_block = (
        "--------------------- LINES --------------------------------------------\n"
        "ID LineType AttachA AttachB UnstrLen NumSegs Outputs\n"
        "(-) (-) (-) (-) (m) (-) (-)\n"
        "1 chainR3 2 1 550.0 1000001 -\n"
    )
    stock_path = tmp_path / "stock-too-many.dat"
    stock_path.write_text(source[:start] + stock_block + source[stop:], encoding="utf-8")
    with pytest.raises(DeckFormatError, match="between 1 and 1000000"):
        DeckFile.read(stock_path)

    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(DeckFormatError, match="between 1 and 1000000"):
        deck.set_section(1, numsegs=1_000_001)
    assert deck.text() == before


def test_nonstandard_table_headers_and_singular_wave_alias_are_native_compatible(tmp_path):
    source = (ROOT / "examples/dynamic_chain_waves.dat").read_text(encoding="utf-8")
    source = source.replace("ID    NodeA   NodeB   Outputs", "LineID NodeA NodeB Outputs")
    source = source.replace("airy 2.0 8.0 0.0     waves", "airy 2.0 8.0 0.0 wave")
    path = tmp_path / "native-aliases.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    assert deck.option("wave").values == ("airy", "2.0", "8.0", "0.0")
    deck.set_option("wave", ("airy", 3.0, 9.0, 15.0))
    assert deck.option("wave").values == ("airy", "3", "9", "15")


@pytest.mark.parametrize("comment", ["# coefficient columns", "! coefficient columns"])
def test_annotated_section_headers_match_native_scanning(tmp_path, comment):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "--------------------- LINE TYPES --------------------------------------",
        "--------------------- LINE TYPES -------------------------------------- " + comment,
    )
    path = tmp_path / "annotated-header.dat"
    path.write_bytes(source.encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.line_types
    assert deck.text() == source


def test_section_scanner_rejects_unknown_and_accepts_native_optional_alias(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    optional = source.replace(
        "--------------------- OPTIONS ------------------------------------------",
        "--------------------- BODY ---------------------------------------------\n"
        "--------------------- OPTIONS ------------------------------------------",
    )
    optional_path = tmp_path / "optional-body.dat"
    optional_path.write_text(optional, encoding="utf-8")
    assert DeckFile.read(optional_path).lines

    unknown_path = tmp_path / "unknown-section.dat"
    unknown_path.write_text(
        source.replace(
            "OPTIONS ------------------------------------------",
            "OPTION -------------------------------------------",
        ),
        encoding="utf-8",
    )
    with pytest.raises(DeckFormatError, match="unknown deck section 'OPTION'"):
        DeckFile.read(unknown_path)


def test_open_ended_native_section_header_is_accepted(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "--------------------- LINE TYPES --------------------------------------",
        "--- LINE TYPES",
    )
    path = tmp_path / "open-header.dat"
    path.write_bytes(source.encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.line_types
    assert deck.text() == source


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ("100.0        WtrDpth", "orphan", "malformed OPTIONS row"),
        ('"FairTen1"', '"FairTen1' + "x" * 60, "longer than 64 characters"),
        ('"FairTen1"', "FairTen1;AnchTen1", "unsupported OUTPUT channel"),
    ],
)
def test_optional_sections_are_parsed_during_validation(tmp_path, old, new, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "malformed-optional.dat"
    path.write_text(source.replace(old, new), encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


@pytest.mark.parametrize("value", ["data#1.dat", "data!1.dat", "--disabled", "foo---bar.dat"])
def test_rendered_tokens_reject_native_comment_and_header_markers(tmp_path, value):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("100.0        WtrDpth", "data/wk.dat WaterKin")
    path = tmp_path / "waterkin.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    before = deck.text()
    with pytest.raises(ValueError, match="comment/header markers"):
        deck.set_option("WaterKin", value)
    assert deck.text() == before


def test_direct_body_attachment_is_rejected(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "body-attachment.dat"
    path.write_text(source.replace("1     2       1       -", "1 Body1 1 -"), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="must be a point id"):
        DeckFile.read(path)


def test_inline_comments_and_stock_outputs_end_follow_native_syntax(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("1     2       1       -", "1 2 1 - -- fairlead connection")
    source = source.replace(
        '"AnchIncl1"',
        '"AnchIncl1" # final channel\nEND\nThis "unterminated footer is ignored',
    )
    path = tmp_path / "comments.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    assert deck.lines[0].tokens == ("1", "2", "1", "-")
    assert deck.outputs == ("FairTen1", "AnchTen1", "FairIncl1", "AnchIncl1")
    native = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    assert native.outputs == ("FairTen1", "AnchTen1", "FairIncl1", "AnchIncl1")


def test_windows_paths_retain_backslashes_during_parse_and_generation(tmp_path):
    source = _minimal_chain_source()
    source = source.replace("100.0        WtrDpth", r"C:\data\water.dat WaterKin")
    path = tmp_path / "windows-path.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    assert deck.option("WaterKin").values == (r"C:\data\water.dat",)
    deck.set_option("WaterKin", r"D:\case_data\water.dat")
    assert deck.option("WaterKin").values == (r"D:\case_data\water.dat",)


def test_repeated_options_follow_native_last_row_wins(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth",
        "80.0 WtrDpth\n100.0 WtrDpth",
    )
    path = tmp_path / "repeated-option.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    assert deck.option("WtrDpth").values == ("100.0",)
    deck.set_option("WtrDpth", 120.0)
    assert [row.values for row in deck.options if row.keyword.lower() == "wtrdpth"] == [
        ("80.0",),
        ("120",),
    ]


def test_scalar_option_prose_does_not_become_a_positional_option(tmp_path):
    source = _minimal_chain_source()
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0 WtrDpth\n0 WaveKin no current\n0.05 dtM before waves\n1.0 TMax",
    )
    path = tmp_path / "scalar-prose.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    assert deck.option("WaveKin").values == ("0",)
    assert deck.option("WaveKin").trailing == ("no", "current")
    assert deck.option("dtM").values == ("0.05",)
    assert deck.option("dtM").trailing == ("before", "waves")


def test_unknown_scalar_option_keyword_fails_closed(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("100.0        WtrDpth", "100.0        WtrDpht")
    path = tmp_path / "unknown-option.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match=r"unknown OPTION keyword 'WtrDpht'"):
        DeckFile.read(path)


@pytest.mark.parametrize(
    "value, keyword, message",
    [
        ("bad", "WtrDpth", "must be numeric"),
        ("NaN", "rhoW", "must be finite"),
        ("maybe", "modified_newton", "native boolean"),
        ("maybe", "cable_load_feedback", "native boolean"),
        ("maybe", "tensile_safety", "False, warn, or True"),
        ("-1e-6", "tensile_strain_tolerance", "must be >= 0"),
        ("3", "recovery_max_substeps", r"integer in \[4, 65536\]"),
        ("4.5", "recovery_max_substeps", r"integer in \[4, 65536\]"),
        ("NaN", "recovery_max_substeps", r"integer in \[4, 65536\]"),
        ("65537", "recovery_max_substeps", r"integer in \[4, 65536\]"),
        ("2.5", "axial_quadrature_order", r"integer in \[1, 6\]"),
        ("7", "bending_quadrature_order", r"integer in \[1, 6\]"),
        ("dynamic", "ICmode", "delete the ICmode row"),
        ("static", "ICmode", "always solves the static equilibrium directly"),
        ("relaxed", "bodyIC", "must be static or deck"),
        ("implicit", "bodyScheme", "monolithic or staggered"),
        ("fast", "bodySubstep", "none or accuracy"),
        ("x", "dtWave", "must be numeric"),
        ("0", "WvHiCOff", "must be positive"),
        ("off", "WvHiCOff", "must be numeric"),
        ("3", "Currents", "no current source in MoorDyn-C v2.7.1"),
        ("4", "Currents", "no current source in MoorDyn-C v2.7.1"),
        ("6", "Currents", "supports only mode 0, 1, 2 or 5"),
        ("1.5", "Currents", "supports only mode 0, 1, 2 or 5"),
        ("4", "WaterKin", "numeric mode 0, 3 or 7"),
        ("1", "WaterKin", "numeric mode 0"),
        ("1e0", "WaterKin", "numeric mode 0"),
        ("-0.1", "frictionMu", "must be >= 0"),
        ("-1", "rampTime", "must be >= 0"),
        ("NaN", "maxStrain", "must be finite"),
        ("-0.1", "max_strain", "must be >= 0"),
        ("0", "WaveSeed", r"integer in \[1, 2147483646\]"),
        ("seven", "WaveSeed", r"integer in \[1, 2147483646\]"),
        ("2147483647", "WaveSeed", r"integer in \[1, 2147483646\]"),
        ("1.5", "wave_seed", "must be an integer"),
        ("maybe", "alpha_force_blend", "native boolean"),
        ("relaxed", "cable_statics", "continuation or sequenced"),
        ("random", "VIVphaseSeed", "spread or zero"),
        ("0", "viv_phase_seed", "spread or zero"),
        ("nodal", "OutputRecovery", "equilibrium or element"),
        ("mode2", "axialDampingRatio", "segment or mode1"),
        ("element", "axial_damping_ratio", "segment or mode1"),
        ("on", "ei0_substeps", "auto or off"),
        ("0", "ei0_substep_angle", r"\(0, 90\] deg"),
        ("91", "ei0SubstepAngle", r"\(0, 90\] deg"),
        ("NaN", "ei0_substep_angle", r"\(0, 90\] deg"),
        ("1", "ei0_substep_max", r"integer in \[2, 1024\]"),
        ("2.5", "ei0_substep_max", r"integer in \[2, 1024\]"),
        ("1025", "ei0SubstepMax", r"integer in \[2, 1024\]"),
        ("2048.5", "ei0_substep_max", r"integer in \[2, 1024\]"),
    ],
)
def test_invalid_scalar_option_values_fail_closed(tmp_path, value, keyword, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("100.0        WtrDpth", f"{value} {keyword}")
    path = tmp_path / "invalid-option-value.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


def test_invalid_scalar_option_edit_is_transactional():
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(DeckFormatError, match="must be numeric"):
        deck.set_option("WtrDpth", "bad")
    assert deck.text() == before


def test_zero_e_exponent_waterkin_mode_is_accepted(tmp_path):
    source = _minimal_chain_source()
    source = source.replace("100.0        WtrDpth", "0e0 WaterKin")
    path = tmp_path / "zero-waterkin-mode.dat"
    path.write_text(source, encoding="utf-8")
    assert DeckFile.read(path).option("WaterKin").values == ("0e0",)


@pytest.mark.parametrize(
    "row",
    [
        "static bodyIC",
        "deck bodyIC",
        "staggered bodyScheme",
        "monolithic bodyScheme",
        "none bodySubstep",
        "accuracy bodySubstep",
        "0.25 dtWave",
        "6.283 WvHiCOff",
        "none WvHiCOff",
        "60 TMax",
        "motion.dat motionFile",
        "RK4 tScheme",
        "2.0 dtIC",
        "60 TMaxIC",
        "4 CdScaleIC",
        "0.01 ThreshIC",
        "1 WriteLog",
        "0.1 dtOut",
        "0 Currents",
        "1 Currents",
        "True tensile_safety",
        "False tensileSafety",
        "warn tensile_safety",
        "True cable_load_feedback",
        "False cableLoadFeedback",
        "5e-6 tensile_strain_tolerance",
        "1024 recovery_max_substeps",
        "4 axial_quadrature_order",
        "3 axialQuadratureOrder",
        "2 axial_quadrature",
        "4 bending_quadrature_order",
        "3 bendingQuadratureOrder",
        "2 bending_quadrature",
        "20 rampTime",
        "20 ramp_time",
        "20 tRamp",
        "0.25 maxStrain",
        "0 max_strain",
        "7 WaveSeed",
        "2147483646 wave_seed",
        "False alpha_force_blend",
        "True alphaForceBlend",
        "continuation cable_statics",
        "sequenced cableStatics",
        "spread VIVphaseSeed",
        "ZERO viv_phase_seed",
        "equilibrium OutputRecovery",
        "element output_recovery",
        "segment axialDampingRatio",
        "mode1 axial_damping_ratio",
        "MODE1 AXIALDAMPINGRATIO",
        "auto ei0_substeps",
        "off ei0Substeps",
        "0.5 ei0_substep_angle",
        "90 ei0SubstepAngle",
        "2 ei0_substep_max",
        "1024 ei0SubstepMax",
        "1.9999999999999998 ei0_substep_max",
    ],
)
def test_native_scalar_option_vocabulary_is_accepted(tmp_path, row):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    if row == "60 TMax":
        row = "0.1 dtM\n" + row
    elif row.endswith("motionFile") or row == "1 Currents":
        # a prescribed motion and a Currents 1 profile both need a dynamic deck
        row = "0.1 dtM\n1.0 TMax\n" + row
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n" + row,
    )
    path = tmp_path / "supported-option.dat"
    path.write_text(source, encoding="utf-8")

    value, keyword = row.splitlines()[-1].split()
    assert DeckFile.read(path).option(keyword).values == (value,)


@pytest.mark.parametrize(
    "filename",
    [
        "lozon_gomex80_power_cable.dat",
        "lozon_gomaine200_power_cable.dat",
        "lozon_humboldt800_power_cable.dat",
        "lozon_gomex80_power_cable_motion.dat",
    ],
)
def test_maintained_lozon_power_cable_decks_parse_and_round_trip(filename):
    path = ROOT / "examples" / filename
    deck = DeckFile.read(path)
    assert deck.text() == path.read_text(encoding="utf-8")
    assert deck.line_types and deck.points and deck.lines and deck.sections


@pytest.mark.parametrize("value", ["0", "none", "NONE"])
def test_disabled_motion_file_does_not_enable_prescribed_motion(tmp_path, value):
    source = _minimal_chain_source().replace(
        "100.0        WtrDpth   - Water depth (m)",
        f"100.0 WtrDpth\n{value} motionFile",
    )
    path = tmp_path / "disabled-motion.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    assert deck.option("motionFile").values == (value,)


def test_motion_file_disable_token_obeys_last_row_wins(tmp_path):
    source = _minimal_chain_source().replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0 WtrDpth\nmissing-motion.dat motionFile\nnone motionFile",
    )
    path = tmp_path / "disabled-motion-override.dat"
    path.write_text(source, encoding="utf-8")

    assert DeckFile.read(path).option("motionFile").values == ("none",)


def _vessel_source(rows: str) -> str:
    return _minimal_chain_source().replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0 WtrDpth\n0.1 dtM\n1.0 TMax\n" + rows,
    )


def test_vessel_motion_options_parse_and_rebase(tmp_path):
    source = _vessel_source("vessel.dat vesselMotion\n80.0|0.0|-10.0 vesselRef")
    path = tmp_path / "deck.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    assert deck.option("vesselMotion").values == ("vessel.dat",)
    assert deck.option("vesselRef").values == ("80.0|0.0|-10.0",)
    rao = _vessel_source("airy 2.0 10.0 0.0 waves\nrao.dat vesselRAO")
    (tmp_path / "rao-deck.dat").write_text(rao, encoding="utf-8")
    assert DeckFile.read(tmp_path / "rao-deck.dat").option("vesselRAO").values == ("rao.dat",)


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        ("vessel.dat vesselMotion\nmotion.dat motionFile", "alternative prescribed-motion"),
        ("motion.dat motionFile\nrao.dat vesselRAO", "alternative prescribed-motion"),
        ("rao.dat vesselRAO", "vesselRAO needs deck waves"),
        ("stream 2.0 10.0 0.0 waves\nrao.dat vesselRAO", "stream-function wave"),
        ("vessel.dat vesselMotion\n1|2 vesselRef", "vesselRef must be x|y|z"),
        ("vessel.dat vesselMotion\n1|2|nan vesselRef", "vesselRef must be finite"),
    ],
)
def test_vessel_motion_options_fail_closed_like_the_native_reader(tmp_path, rows, message):
    path = tmp_path / "vessel-bad.dat"
    path.write_text(_vessel_source(rows), encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


_ATTACHMENT_DECK = """lazy-wave cable with buoyancy modules
--- LINE TYPES ---
Name Diam Mass EA BA EI Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)
bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0
chain 0.1 20.0 1.0e8 0.0 0.0 1.2 0.1 1.0 0.0
--- POINTS ---
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Fixed 0.0 0.0 -56.0
2 Coupled 90.0 0.0 -14.0
3 Fixed 200.0 0.0 -56.0
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 2 1 -
2 2 3 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 bare 145.0 80
2 chain 120.0 20
--- ATTACHMENTS ---
LineID ArcLength Mass Volume CdA Ca
(-) (m) (kg) (m^3) (m^2) (-)
{rows}
--- OPTIONS ---
0.05 dtM
0.0 TMax
{options}
--- OUTPUTS ---
FairTen1
END
"""


def test_attachments_section_parses_series_and_aliases(tmp_path):
    path = tmp_path / "attachments.dat"
    rows = "1 42.5:5:87.5 114.15 0.2297 0.78 1.0\n1 20.0 500 0 0.5 0"
    text = _ATTACHMENT_DECK.format(rows=rows, options="")
    path.write_bytes(text.encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.text() == text
    alias = tmp_path / "clumps.dat"
    alias.write_bytes(text.replace("--- ATTACHMENTS ---", "--- CLUMPS ---").encode("utf-8"))
    DeckFile.read(alias)


@pytest.mark.parametrize(
    ("row", "options", "message"),
    [
        ("1 60.0 0 0 0 1.0", "", "positive Mass, Volume, CdA or CdAx"),
        ("1 60.0 100 0.1 0.1 1.0 0.2 7", "", "LineID ArcLength Mass Volume CdA Ca"),
        ("1 60.0 100 0.1 0.1 1.0 -0.2", "", "finite and >= 0"),
        ("1 60:0:70 100 0.1 0.1 1.0", "", "pitch > 0"),
        ("1 70:5:60 100 0.1 0.1 1.0", "", "first <= last"),
        ("1 60.0 100 0.1 0.1", "", "LineID ArcLength Mass Volume CdA Ca"),
        ("9 60.0 100 0.1 0.1 1.0", "", "undefined LINE"),
        ("2 60.0 100 0.1 0.1 1.0", "", "not a finite-EI line"),
        ("1 60.0 -1 0.1 0.1 1.0", "", "finite and >= 0"),
    ],
)
def test_attachments_fail_closed_like_the_native_reader(tmp_path, row, options, message):
    path = tmp_path / "attachments-bad.dat"
    path.write_text(_ATTACHMENT_DECK.format(rows=row, options=options), encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


def test_attachments_accept_an_axial_drag_area_and_a_deck_current(tmp_path):
    text = _ATTACHMENT_DECK.format(
        rows="1 42.5:5:87.5 114.15 0.2297 0.78 1.0 0.2042", options="uniform 0.5 0 0 current"
    )
    path = tmp_path / "attachments-current.dat"
    # all finite-EI lines: the deck driver takes a deck current
    path.write_text(text.replace("1.0e8 0.0 0.0 1.2", "1.0e8 0.0 1.0e3 1.2"), encoding="utf-8")
    DeckFile.read(path)
    # a mixed EI=0/finite-EI deck runs on the aggregate in its current too
    DeckFile.from_text(text)


def test_viv_lift_flag_is_upper_case_and_standalone():
    # V writes the VIV lift file; as MoorDyn's line flags it is case-sensitive (v, MoorDyn's
    # node velocities, is not written)
    deck = DeckFile.from_text(_edit(_DYNAMIC, ("1 2 1 -\n", "1 2 1 pV\n")))
    assert deck.lines[0].tokens[3] == "pV"
    with pytest.raises(DeckFormatError, match="accepts only '-', 'p', 't', 'r', and 'V'"):
        DeckFile.from_text(_edit(_DYNAMIC, ("1 2 1 -\n", "1 2 1 pv\n")))
    # a mixed EI=0/finite-EI deck writes no per-line files
    mixed = _ATTACHMENT_DECK.format(rows="1 60.0 100 0.1 0.1 1.0", options="")
    with pytest.raises(DeckFormatError, match="flags p, t and V"):
        DeckFile.from_text(mixed.replace("1 2 1 -\n", "1 2 1 V\n"))


def test_attachments_are_accepted_on_the_coupled_route(tmp_path):
    path = tmp_path / "attachments-coupled.dat"
    path.write_text(
        _ATTACHMENT_DECK.format(rows="1 60.0 100 0.1 0.1 1.0", options=""), encoding="utf-8"
    )
    DeckFile.read(path, caller_driven=True)


def test_vessel_motion_disable_row_clears_only_its_own_source(tmp_path):
    path = tmp_path / "vessel-toggle.dat"
    path.write_text(
        _vessel_source("motion.dat motionFile\nnone motionFile\nvessel.dat vesselMotion"),
        encoding="utf-8",
    )
    assert DeckFile.read(path).option("vesselMotion").values == ("vessel.dat",)
    path.write_text(
        _vessel_source("vessel.dat vesselMotion\nnone motionFile\nmotion.dat motionFile"),
        encoding="utf-8",
    )
    with pytest.raises(DeckFormatError, match="alternative prescribed-motion"):
        DeckFile.read(path)


def test_new_scalar_options_round_trip_through_edits(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n"
        "static bodyIC\n0.5 maxStrain - strain limit\n3 WaveSeed\n10 rampTime\n"
        "True alpha_force_blend\ncontinuation cable_statics",
    )
    path = tmp_path / "new-options.dat"
    path.write_bytes(source.encode("utf-8"))

    deck = DeckFile.read(path)
    assert deck.text() == source
    deck.set_option("bodyIC", "deck")
    deck.set_option("max_strain", 0.25)
    deck.set_option("WaveSeed", 11)
    deck.set_option("tRamp", 0)
    deck.set_option("alphaForceBlend", "False")
    deck.set_option("cable_statics", "sequenced")
    edited = tmp_path / "new-options-edited.dat"
    deck.write(edited)
    reread = DeckFile.read(edited)
    assert reread.option("bodyic").values == ("deck",)
    assert reread.option("maxStrain").values == ("0.25",)
    assert "0.25 maxStrain - strain limit" in reread.text()
    assert reread.option("wave_seed").values == ("11",)
    assert reread.option("rampTime").values == ("0",)
    assert reread.option("alpha_force_blend").values == ("False",)
    assert reread.option("cablestatics").values == ("sequenced",)
    with pytest.raises(DeckFormatError, match="continuation or sequenced"):
        reread.set_option("cable_statics", "fast")
    assert reread.option("cable_statics").values == ("sequenced",)


def test_option_aliases_share_native_last_row_wins_identity(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "150 WtrDpth\n160 water_depth - Effective native alias row",
    )
    path = tmp_path / "option-aliases.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    assert deck.option("WtrDpth").values == ("160",)
    deck.set_option("WtrDpth", 180)
    assert deck.option("water_depth").values == ("180",)
    assert "150 WtrDpth" in deck.text()
    assert "180 water_depth - Effective native alias row" in deck.text()


def test_point_editing_normalizes_native_integer_ids(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "1     Fixed     500.0",
        "01    Fixed     500.0",
    )
    path = tmp_path / "leading-zero-point.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    deck.set_point(1, z=-95.0)
    assert deck.points[0].tokens[0] == "01"
    assert deck.points[0].tokens[4] == "-95"
    deck.apply("point.1.z", -90.0)
    assert deck.points[0].tokens[0] == "01"
    assert deck.points[0].tokens[4] == "-90"


@pytest.mark.parametrize(
    "values",
    [
        ("1e-7", "1e-3", "20", "4"),
        ("1e-7", "1e-3", "20", "4", "0.4"),
    ],
)
def test_keyword_first_dynamic_solver_option_is_editable(tmp_path, values):
    source = _minimal_chain_source()
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n"
        "dynamic_solver 1e-6 1e-2 12 2 - Nonlinear solve controls",
    )
    path = tmp_path / "dynamic-solver.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    record = deck.option("dynamic_solver")
    assert record.values == ("1e-6", "1e-2", "12", "2")
    assert record.keyword_first

    deck.set_option("dynamic_solver", values)
    updated = deck.option("dynamic_solver")
    assert updated.values == values
    assert updated.keyword_first
    assert deck.text().split("dynamic_solver", 1)[1].startswith(" " + " ".join(values))
    assert " - Nonlinear solve controls" in deck.text()

    with pytest.raises(ValueError, match="positive finite tolerances"):
        deck.set_option("dynamic_solver", ("1e-7", "1e-3"))


@pytest.mark.parametrize(
    "values",
    [
        ("bad", "1e-3", "20", "4"),
        ("1e-7", "1e-3", "0", "4"),
        ("1e-7", "1e-3", "20", "-1"),
        ("1e-7", "1e-3", "20", "4", "1.1"),
    ],
)
def test_dynamic_solver_edits_enforce_native_numeric_contract(tmp_path, values):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n"
        "dynamic_solver 1e-6 1e-2 12 2 - Nonlinear solve controls",
    )
    path = tmp_path / "dynamic-solver-invalid.dat"
    path.write_text(source, encoding="utf-8")
    deck = DeckFile.read(path)
    before = deck.text()
    with pytest.raises(ValueError, match="positive finite tolerances"):
        deck.set_option("dynamic_solver", values)
    assert deck.text() == before


@pytest.mark.parametrize("keyword", ["motionFile", "WaterKin"])
def test_dynamic_solver_basename_remains_a_scalar_path_value(tmp_path, keyword):
    source = _minimal_chain_source()
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        f"100.0        WtrDpth   - Water depth (m)\n0.1 dtM\n1.0 TMax\ndynamic_solver {keyword}",
    )
    path = tmp_path / "dynamic-solver-basename.dat"
    path.write_text(source, encoding="utf-8")

    record = DeckFile.read(path).option(keyword)
    assert record.values == ("dynamic_solver",)
    assert not record.keyword_first


@pytest.mark.parametrize(
    "row",
    [
        "airy 0 8 0 waves",
        "airy 2 0 0 waves",
        "jonswap 2 8 0.9 0 waves",
    ],
)
def test_positional_wave_ranges_match_native_finalizer(tmp_path, row):
    source = _minimal_chain_source()
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n0.1 dtM\n1.0 TMax\n" + row,
    )
    path = tmp_path / "invalid-waves.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match="positive height/period"):
        DeckFile.read(path)


@pytest.mark.parametrize("depths", [(0.0, 0.0), (0.0, 1.0e-15)])
def test_current_profile_depths_must_be_distinct_after_native_normalization(tmp_path, depths):
    source = (ROOT / "examples/dynamic_chain_current.dat").read_text(encoding="utf-8")
    row = f"profile {depths[0]} 1 0 0 {depths[1]} 0 0 0 current"
    source = source.replace("uniform 1.0 0.0 0.0  current", row)
    path = tmp_path / "unordered-current-profile.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match="depths must be strictly increasing"):
        DeckFile.read(path)


def test_current_profile_edit_rejects_equal_depths_without_mutation():
    deck = DeckFile.read(ROOT / "examples/dynamic_chain_current.dat")
    before = deck.text()
    with pytest.raises(ValueError, match="depths must be strictly increasing"):
        deck.set_option("current", ("profile", 0, 1, 0, 0, 0, 0, 0, 0))
    assert deck.text() == before


def test_descending_current_profile_matches_native_normalization(tmp_path):
    source = (ROOT / "examples/dynamic_chain_current.dat").read_text(encoding="utf-8")
    row = "profile 10 1 0 0 -10 0 0 0 current"
    path = tmp_path / "descending-current-profile.dat"
    path.write_text(source.replace("uniform 1.0 0.0 0.0  current", row), encoding="utf-8")
    assert DeckFile.read(path).option("current").values == tuple(row.split()[:-1])

    deck = DeckFile.read(ROOT / "examples/dynamic_chain_current.dat")
    deck.set_option("current", ("profile", 10, 1, 0, 0, -10, 0, 0, 0))
    assert deck.option("current").values[1] == "10"
    assert deck.option("current").values[5] == "-10"


def test_dotted_line_type_name_is_preserved_in_generation_selector(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "dotted-type.dat"
    path.write_text(source.replace("chainR3", "chain.R3"), encoding="utf-8")

    (case,) = generate_deck_cases(
        path,
        tmp_path / "cases",
        {"stiffer": {"line_type.chain.R3.ea": 1.8e9}},
    )
    generated = DeckFile.read(case.deck)
    assert generated.line_types[0].tokens[0] == "chain.R3"
    assert float(generated.line_types[0].tokens[3]) == 1.8e9


def test_case_generation_stages_coordinated_cross_reference_edits(tmp_path):
    source = ROOT / "examples/chain_catenary_r3_100m.dat"
    changes = {
        "line_type.chainR3.name": "newchain",
        "line_type.chainR3.ea": 1.8e9,
        "section.1.1.linetype": "newchain",
    }
    (case,) = generate_deck_cases(source, tmp_path / "cases", {"renamed": changes})
    generated = DeckFile.read(case.deck)
    assert generated.line_types[0].tokens[0] == "newchain"
    assert float(generated.line_types[0].tokens[3]) == 1.8e9
    assert generated.sections[0].tokens[1] == "newchain"

    deck = DeckFile.read(source)
    before = deck.text()
    with pytest.raises(DeckFormatError, match="missing line type"):
        deck.apply_many({"section.1.1.linetype": "missing"})
    assert deck.text() == before


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ("1        chainR3    550.0    55", "1 chainR3 550.0 55 extra", "SECTIONS"),
        (
            "chainR3    0.2466   373.5          1.607e9    -1.0       0.0"
            "      1.37  0.64  1.0   0.0",
            "chainR3 0.2466 373.5 1.607e9 -1.0 0.0 1.37 0.64 1.0 0.0 extra",
            "LINE TYPES",
        ),
    ],
)
def test_native_table_widths_fail_closed(tmp_path, old, new, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "extra-column.dat"
    path.write_text(source.replace(old, new), encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


@pytest.mark.parametrize(
    ("start", "stop", "section"),
    [
        ("chainR3    0.2466", "--------------------- POINTS", "LINE TYPES"),
        ("1     Fixed", "--------------------- LINES", "POINTS"),
        ("1     2       1", "--------------------- SECTIONS", "LINES"),
    ],
)
def test_required_native_tables_must_contain_data(tmp_path, start, stop, section):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    first = source.index(start)
    last = source.index(stop, first)
    path = tmp_path / f"empty-{section.lower().replace(' ', '-')}.dat"
    path.write_text(source[:first] + source[last:], encoding="utf-8")
    with pytest.raises(DeckFormatError, match=f"{section} section has no data rows"):
        DeckFile.read(path)


def test_invalid_edit_rolls_back_document():
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(DeckFormatError, match="positive"):
        deck.set_section(1, numsegs=0)
    assert deck.text() == before


@pytest.mark.parametrize(
    "editor",
    [
        lambda deck: deck.set_point(2, x="bad"),
        lambda deck: deck.set_line_type("chainR3", diam="bad"),
        lambda deck: deck.set_line_type("chainR3", ea="1|2", ba="1|bad"),
    ],
)
def test_nonnumeric_table_edits_fail_closed_and_roll_back(editor):
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(DeckFormatError, match="numeric"):
        editor(deck)
    assert deck.text() == before


@pytest.mark.parametrize(
    "keyword, values",
    [
        ("waves", ("airy", 3.0, 9.0)),
        ("waves", ("airy", "bad", 9.0, 0.0)),
        ("waves", ("uniform", 1.0, 2.0, 3.0)),
        ("current", ("uniform", 1.0, 2.0)),
        ("current", ("airy", 3.0, 9.0, 0.0)),
    ],
)
def test_malformed_positional_option_edits_fail_before_writing(keyword, values):
    source = "dynamic_chain_waves.dat" if keyword == "waves" else "dynamic_chain_current.dat"
    deck = DeckFile.read(ROOT / "examples" / source)
    before = deck.text()
    with pytest.raises(ValueError, match="native none/uniform/profile/airy/jonswap"):
        deck.set_option(keyword, values)
    assert deck.text() == before


def test_missing_cross_reference_fails_closed(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "bad.dat"
    path.write_text(
        source.replace("1        chainR3    550.0", "1        missing    550.0"), encoding="utf-8"
    )
    with pytest.raises(DeckFormatError, match="missing line type"):
        DeckFile.read(path)


def test_unknown_point_type_and_self_connected_line_fail_closed(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    bad_type = tmp_path / "bad-point-type.dat"
    bad_type.write_text(source.replace("2     Coupled", "2     Couppled"), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="unknown POINT type"):
        DeckFile.read(bad_type)

    self_connected = tmp_path / "self-connected.dat"
    self_connected.write_text(
        source.replace("1     2       1", "1     2       02"), encoding="utf-8"
    )
    with pytest.raises(DeckFormatError, match="NodeA and NodeB must differ"):
        DeckFile.read(self_connected)


def test_syrope_ic_optional_section_references_are_validated(tmp_path):
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    path = tmp_path / "bad-syrope-ic.dat"
    path.write_text(
        source.replace("1       2.0e6   1.5e6", "99      2.0e6   1.5e6"), encoding="utf-8"
    )
    with pytest.raises(DeckFormatError, match="undefined line"):
        DeckFile.read(path)

    duplicate = tmp_path / "duplicate-syrope-ic.dat"
    duplicate.write_text(
        source.replace("1       2.0e6   1.5e6", "1,1     2.0e6   1.5e6"),
        encoding="utf-8",
    )
    with pytest.raises(DeckFormatError, match="duplicate SYROPE IC line assignment"):
        DeckFile.read(duplicate)


def test_syrope_ic_accepts_spaces_after_id_commas(tmp_path):
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    source = (
        source.replace(
            "2     Vessel    20.5     0.0    0.0       0       0       0      0",
            "2     Vessel    20.5     0.0    0.0       0       0       0      0\n"
            "3     Fixed     0.0      1.0    0.0       0       0       0      0\n"
            "4     Vessel    20.5     1.0    0.0       0       0       0      0",
        )
        .replace(
            "1     2       1       -",
            "1     2       1       -\n2     4       3       -",
        )
        .replace(
            "1       2.0e6   1.5e6",
            "1, 2    2.0e6   1.5e6",
        )
        .replace(
            "1        rope       20.0     8",
            "1        rope       20.0     8\n2        rope       20.0     8",
        )
    )
    path = tmp_path / "spaced-syrope-list.dat"
    path.write_text(source, encoding="utf-8")

    deck = DeckFile.read(path)
    assert [row.tokens[0] for row in deck.lines] == ["1", "2"]
    assert deck.text() == path.read_bytes().decode("utf-8")


def test_syrope_ic_requires_a_syrope_section(tmp_path):
    chain = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    chain = chain.replace(
        "--------------------- SECTIONS -----------------------------------------",
        "--------------------- SYROPE IC ----------------------------------------\n"
        "1 2.0e6 1.5e6\n"
        "--------------------- SECTIONS -----------------------------------------",
    )
    non_syrope = tmp_path / "non-syrope-ic.dat"
    non_syrope.write_text(chain, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="line with a Syrope section"):
        DeckFile.read(non_syrope)

    # a composite line with a Syrope section takes the history (every Syrope section's)
    syrope = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    syrope = syrope.replace(
        "1        rope       20.0     8",
        "1        rope       10.0     4\n1        rope       10.0     4",
    )
    composite = tmp_path / "composite-syrope-ic.dat"
    composite.write_text(syrope, encoding="utf-8")
    DeckFile.read(composite)

    DeckFile.read(ROOT / "examples/syrope_polyester_mooring.dat")


def test_syrope_ic_must_follow_referenced_line_definitions(tmp_path):
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    syrope_start = source.index("--------------------- SYROPE IC")
    syrope_end = source.index("--------------------- SECTIONS", syrope_start)
    block = source[syrope_start:syrope_end]
    source = source[:syrope_start] + source[syrope_end:]
    lines_start = source.index("--------------------- LINES")
    source = source[:lines_start] + block + source[lines_start:]
    path = tmp_path / "early-syrope-ic.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match=r"must follow.*LINE definitions"):
        DeckFile.read(path)


@pytest.mark.parametrize(
    "heading, row, message",
    [
        ("CONTROL", "1 99", "known lines"),
        ("EQUIVALENT BUOYANCY", "missing 0.2 100", "missing line type"),
        ("BODIES", "1 Fixed 0 0", "15 or 18 fields"),
        ("ROD TYPES", "rod 0.2 bad 1 1 1 1", "numeric"),
    ],
)
def test_recognized_optional_sections_fail_closed(tmp_path, heading, row, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    insertion = f"--------------------- {heading} ----------------------------------------\n{row}\n"
    source = source.replace(
        "--------------------- SECTIONS -----------------------------------------",
        insertion + "--------------------- SECTIONS -----------------------------------------",
    )
    path = tmp_path / f"bad-{heading.lower().replace(' ', '-')}.dat"
    path.write_text(source, encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


def test_body_type_vocabulary_matches_native_parser(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    point3_row = "1 Point3 0 0 0 0 0 0 1 1 0 0 0 1 1"
    rigid6_row = "1 Rigid6 0 0 0 0 0 0 1 1 0 0 0 1 1 2 3 4"

    for body_type, body_row in (("Point3", point3_row), ("Rigid6", rigid6_row)):
        path = tmp_path / f"valid-{body_type.lower()}.dat"
        block = "--------------------- BODIES -------------------------------------------\n"
        path.write_text(
            source.replace(marker, block + body_row + "\n" + marker),
            encoding="utf-8",
        )
        with pytest.raises(DeckFormatError, match="BODIES require dtM and TMax"):
            DeckFile.read(path)
        DeckFile.read(path, caller_driven=True)

    invalid = tmp_path / "invalid-body-type.dat"
    block = "--------------------- BODIES -------------------------------------------\n"
    invalid.write_text(
        source.replace(marker, block + point3_row.replace("Point3", "Rigdi6") + "\n" + marker),
        encoding="utf-8",
    )
    with pytest.raises(DeckFormatError, match="BODY type must be Point3, Rigid6"):
        DeckFile.read(invalid, caller_driven=True)


@pytest.mark.parametrize(
    "row, message",
    [
        ("1 Rigid6 0 0 0 0 0 0 1 1 0 0 0 1 1", "requires Ixx, Iyy, and Izz"),
        ("1 Rigid6 0 0 0 0 0 0 1 1 0 0 0 1 1 2 0 4", "inertias must be positive"),
        ("1 Point3 0 0 0 0 0 0 0 1 0 0 0 1 1", "Mass > 0"),
    ],
)
def test_body_physical_requirements_match_native_parser(tmp_path, row, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    block = "--------------------- BODIES -------------------------------------------\n"
    path = tmp_path / "invalid-body.dat"
    path.write_text(source.replace(marker, block + row + "\n" + marker), encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path, caller_driven=True)


@pytest.mark.parametrize("rod_kind", ["Free", "Fixed", "Coupled", "Vessel"])
@pytest.mark.parametrize("outputs", ["-", "p", "PP"])
def test_rod_type_and_output_vocabulary_matches_native_parser(tmp_path, rod_kind, outputs):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    if rod_kind in {"Coupled", "Vessel"}:
        source = source.replace(
            "--------------------- OPTIONS ------------------------------------------",
            "--------------------- OPTIONS ------------------------------------------\n"
            "0.1 dtM - CableDyn internal time step\n"
            '"motion.dat" motionFile - Prescribed endpoint motion file',
        )
    marker = "--------------------- POINTS -------------------------------------------"
    block = (
        "--------------------- ROD TYPES ----------------------------------------\n"
        "rod 0.2 1 1 1 1 1\n"
        "--------------------- RODS ---------------------------------------------\n"
        f"1 rod {rod_kind} 0 0 0 1 0 0 1 {outputs}\n"
    )
    path = tmp_path / f"valid-rod-{rod_kind.lower()}-{outputs.lower()}.dat"
    source = source.replace(
        "--------------------- LINES --------------------------------------------",
        "3 Rod1A 0 0 0\n4 Rod1B 1 0 0\n"
        "--------------------- LINES --------------------------------------------",
    )
    path.write_text(source.replace(marker, block + marker), encoding="utf-8")

    with pytest.raises(
        DeckFormatError,
        match=r"(?:RODS require|requires both|dynamic POINT types require) dtM and TMax",
    ):
        DeckFile.read(path)
    # the coupled host drives Coupled/Vessel rods and takes no deck motionFile
    coupled = path.read_text(encoding="utf-8").replace(
        '"motion.dat" motionFile - Prescribed endpoint motion file\n', ""
    )
    DeckFile.from_text(coupled, caller_driven=True)


def test_coupled_rods_and_bodies_need_a_motion_file_or_a_coupled_host(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    rods = (
        "--------------------- ROD TYPES ----------------------------------------\n"
        "rod 0.2 1 1 1 1 1\n"
        "--------------------- RODS ---------------------------------------------\n"
        "1 rod Coupled 0 0 0 1 0 0 1 -\n"
    )
    bodies = "--------------------- BODIES -------------------------------------------\n"
    blocks = (
        rods,
        bodies + "1 Coupled 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
        bodies + "1 Vessel 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
        bodies + "1 Coupled 0 0 -20 0 0 0 0 0 0 0 0 0\n",
    )
    for k, block in enumerate(blocks):
        path = tmp_path / f"host-{k}.dat"
        path.write_text(source.replace(marker, block + marker), encoding="utf-8")
        with pytest.raises(DeckFormatError, match="requires a motionFile"):
            DeckFile.read(path)
        DeckFile.read(path, caller_driven=True)
    path = tmp_path / "host-invalid.dat"
    for row, message in (
        ("1 Coupled 0 0 0 0 0 0 -1 0 0 0 0 0 0\n", "requires non-negative"),
        ("1 Coupled 0 0 -20 0 0 0 -1 0 0 0 0 0\n", "requires non-negative"),
    ):
        path.write_text(source.replace(marker, bodies + row + marker), encoding="utf-8")
        with pytest.raises(DeckFormatError, match=message):
            DeckFile.read(path, caller_driven=True)


@pytest.mark.parametrize("kind", ["CoupledPinned", "CpldPin", "VesselPinned", "VesPin"])
def test_coupled_pinned_bodies_need_a_coupled_host_and_inertia(tmp_path, kind):
    # native finalize_checks: the host moves the reference point of a CoupledPinned body and
    # its rotation is integrated, so the standalone driver refuses it and the coupled route
    # takes it with positive inertias (18- and 14-column rows)
    static = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    clock = "--------------------- OUTPUTS ------------------------------------------"
    dynamic = static.replace(clock, "0.01 dtM\n1.0 TMax\n" + clock)
    bodies = "--------------------- BODIES -------------------------------------------\n"
    path = tmp_path / "pinned.dat"
    for row in (
        f"1 {kind} 0 0 -20 0 0 0 10 0 0 0 0 0 0 1 1 1\n",
        f"1 {kind} 0 0 -20 0 0 0 10 0|0|-1 1|2|3 0 0 0\n",
    ):
        path.write_text(dynamic.replace(marker, bodies + row + marker), encoding="utf-8")
        with pytest.raises(DeckFormatError, match="requires a coupled host"):
            DeckFile.read(path)
        DeckFile.read(path, caller_driven=True)
        # without a clock the native Rigid6 dynamic-deck rule comes first
        path.write_text(static.replace(marker, bodies + row + marker), encoding="utf-8")
        with pytest.raises(DeckFormatError, match="Rigid6 BODY requires a dynamic deck"):
            DeckFile.read(path)
        DeckFile.read(path, caller_driven=True)
    source = dynamic
    for row in (
        f"1 {kind} 0 0 -20 0 0 0 10 0 0 0 0 0 0\n",
        f"1 {kind} 0 0 -20 0 0 0 10 0 0 0 0 0 0 1 0 1\n",
        f"1 {kind} 0 0 -20 0 0 0 -1 0 0 0 0 0 0 1 1 1\n",
        f"1 {kind} 0 0 -20 0 0 0 10 0 0 0 0 0\n",
    ):
        path.write_text(source.replace(marker, bodies + row + marker), encoding="utf-8")
        with pytest.raises(DeckFormatError, match=r"requires Ixx/Iyy/Izz > 0"):
            DeckFile.read(path, caller_driven=True)


@pytest.mark.parametrize(
    "value, accepted", [("1", True), ("1.0", True), ("0", False), ("2", False)]
)
def test_moordyn_inertial_f_option(tmp_path, value, accepted):
    # native apply_option: CableDyn always returns the coupled objects' inertia (inertialF 1)
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    clock = "--------------------- OUTPUTS ------------------------------------------"
    path = tmp_path / "inertial.dat"
    text = source.replace(clock, f"{value} inertialF\n30.0 inertialF_rampT\n" + clock)
    path.write_text(text, encoding="utf-8")
    if accepted:
        DeckFile.read(path)
    else:
        with pytest.raises(DeckFormatError, match=r"inertialF 0 \(MoorDyn-F's default"):
            DeckFile.read(path)


@pytest.mark.parametrize(
    "rod_row, message",
    [
        ("1 rod Fre 0 0 0 1 0 0 1 -", "ROD type must be"),
        ("1 rod Free 0 0 0 1 0 0 1 x", "ROD Outputs accepts only"),
        ("1 rod Free 0 0 0 0 0 0 1 -", "positive length"),
    ],
)
def test_invalid_rod_vocabulary_and_geometry_fail_closed(tmp_path, rod_row, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    if " Coupled " in rod_row:
        source = source.replace(
            "--------------------- OPTIONS ------------------------------------------",
            "--------------------- OPTIONS ------------------------------------------\n"
            "none motionFile",
        )
    marker = "--------------------- POINTS -------------------------------------------"
    block = (
        "--------------------- ROD TYPES ----------------------------------------\n"
        "rod 0.2 1 1 1 1 1\n"
        "--------------------- RODS ---------------------------------------------\n"
        f"{rod_row}\n"
    )
    path = tmp_path / "invalid-rod.dat"
    path.write_text(source.replace(marker, block + marker), encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path, caller_driven=True)


def test_rods_allow_at_most_one_point_for_each_end(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    block = (
        "--------------------- ROD TYPES ----------------------------------------\n"
        "rod 0.2 1 1 1 1 1\n"
        "--------------------- RODS ---------------------------------------------\n"
        "1 rod Free 0 0 0 1 0 0 1 -\n"
    )
    path = tmp_path / "rod-without-end-points.dat"
    path.write_text(source.replace(marker, block + marker), encoding="utf-8")
    DeckFile.read(path, caller_driven=True)
    doubled = source.replace(
        "--------------------- LINES --------------------------------------------",
        "3 Rod1A 0 0 0\n4 Rod1A 1 0 0\n"
        "--------------------- LINES --------------------------------------------",
    )
    path.write_text(doubled.replace(marker, block + marker), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="more than one Rod<N>A or Rod<N>B"):
        DeckFile.read(path, caller_driven=True)


@pytest.mark.parametrize(
    ("rod_row", "lines_row", "ok"),
    [
        ("1 rod Pinned 0 0 0 1 0 0 1 -", None, True),
        ("1 rod Body1 0 0 0 1 0 0 1 -", None, False),
        ("1 rod Free 0 0 0 1 0 0 1 -", "9 chainR3 R1A 1 10 2 -", True),
        ("1 rod Free 0 0 0 1 0 0 1 -", "9 chainR3 1 1 10 2 -", False),
    ],
)
def test_rod_attachments(tmp_path, rod_row, lines_row, ok):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    block = (
        "--------------------- ROD TYPES ----------------------------------------\n"
        "rod 0.2 1 1 1 1 1\n"
        "--------------------- RODS ---------------------------------------------\n"
        f"{rod_row}\n"
    )
    source = source.replace(marker, block + marker)
    if lines_row:
        heading = "--------------------- LINES --------------------------------------------"
        rows = source.split(heading, 1)
        lines_block = rows[1].split("\n---", 1)
        source = rows[0] + heading + lines_block[0] + "\n" + lines_row + "\n---" + lines_block[1]
    path = tmp_path / "rod-attachments.dat"
    path.write_text(source, encoding="utf-8")
    if ok:
        DeckFile.read(path, caller_driven=True)
    else:
        with pytest.raises(DeckFormatError):
            DeckFile.read(path, caller_driven=True)


def test_bodies_and_rods_without_lines():
    text = (
        "title\n"
        "---------------------- ROD TYPES -------------------------------------\n"
        "spar 8 5000 0.8 1 0.6 0.6\n"
        "---------------------- BODIES ----------------------------------------\n"
        "1 Free 0 0 1 0 0 0 3.67e6 0|0|-70.0 1.37e8|1.37e8|2.94e7 0 0 0\n"
        "---------------------- RODS ------------------------------------------\n"
        "1 spar Body1 0 0 -80 0 0 10 45 -\n"
        "--------------------- OPTIONS ------------------------------------------\n"
        "200 WtrDpth\n0.1 dtM\n1 TMax\nmoordyn rodHydro\n"
        "--------------------- OUTPUTS ------------------------------------------\n"
        '"Body1Pz"\n"Body1Ry"\n"Rod1N45Pz"\n'
        "--------------------- need this line -----------------------------------\n"
    )
    DeckFile.from_text(text)
    with pytest.raises(DeckFormatError, match="unknown rod"):
        DeckFile.from_text(text.replace('"Rod1N45Pz"', '"Rod2Pz"'))
    with pytest.raises(DeckFormatError, match="unknown body"):
        DeckFile.from_text(text.replace('"Body1Pz"', '"Body3Pz"'))
    with pytest.raises(DeckFormatError, match="must be exact or moordyn"):
        DeckFile.from_text(text.replace("moordyn rodHydro", "fancy rodHydro"))


_MIXED_DECK = (
    "title\n"
    "---------------------- LINE TYPES ------------------------------------\n"
    "nylon 0.124 13.76 2.5e6 -0.8 0 1.6 0.05 1.0 0\n"
    "cable 0.15 30 5.0e8 -0.8 1.0e4 1.2 0.01 1.0 0\n"
    "---------------------- ROD TYPES -------------------------------------\n"
    "arm 0.5 600 1.0 1.0 0 0\n"
    "knot 0.3 100 1.0 1.0 0.6 0.6\n"
    "---------------------- BODIES ----------------------------------------\n"
    "1 Free 0 0 -15 0 0 0 1.5e5 0 2e6 160 20|0 0.5\n"
    "---------------------- RODS ------------------------------------------\n"
    "1 arm Body1Pinned 0 0 -2 0 0 -12 5 -\n"
    "2 arm Pin 10 0 -20 10 0 -30 5 -\n"
    "3 knot Free -30 0 -40 -30 0 -40 0 -\n"
    "---------------------- POINTS ----------------------------------------\n"
    "1 Body1 3 0 0 0 0 0 0\n"
    "2 Fixed 150 0 -70 0 0 0 0\n"
    "3 Fixed 0 0 -70 0 0 0 0\n"
    "4 Fixed -60 0 -70 0 0 0 0\n"
    "5 Body1 0 3 -2 0 0 0 0\n"
    "6 Fixed 0 60 -70 0 0 0 0\n"
    "---------------------- LINES -----------------------------------------\n"
    "1 nylon 1 2 150 20 -\n"
    "2 nylon R1B 3 42 8 -\n"
    "3 nylon R2B 4 60 8 -\n"
    "4 nylon R3A 4 40 8 -\n"
    "5 nylon 1 R3B 40 8 -\n"
    "6 cable 5 6 90 30 -\n"
    "--------------------- OPTIONS ------------------------------------------\n"
    "70 WtrDpth\n0.01 dtM\n1 TMax\n"
    "--------------------- OUTPUTS ------------------------------------------\n"
    '"Body1Fx"\n"Body1My"\n"Body1RAz"\n"Rod1TenB"\n"Rod1Sub"\n"Rod2Rx"\n"Rod2Mz"\n"Point6FH"\n'
    "--------------------- need this line -----------------------------------\n"
)


def test_pinned_zero_length_and_mixed_rods():
    DeckFile.from_text(_MIXED_DECK)
    # MoorDyn alias Body<N>Pin
    DeckFile.from_text(_MIXED_DECK.replace("Body1Pinned", "Body1Pin"))
    with pytest.raises(DeckFormatError, match="must name a Rigid6"):
        DeckFile.from_text(_MIXED_DECK.replace("Body1Pinned", "Body2Pinned"))
    # coincident ends need NumSegs 0
    with pytest.raises(DeckFormatError, match="declared with NumSegs 0"):
        DeckFile.from_text(
            _MIXED_DECK.replace("-30 0 -40 -30 0 -40 0 -", "-30 0 -40 -30 0 -40 2 -")
        )
    # a zero-length rod reports through Point channels
    with pytest.raises(DeckFormatError, match="zero length"):
        DeckFile.from_text(_MIXED_DECK.replace('"Rod2Rx"', '"Rod3Px"'))
    # rods have no yaw angle; bodies no TenA
    with pytest.raises(DeckFormatError, match="unsupported OUTPUT"):
        DeckFile.from_text(_MIXED_DECK.replace('"Rod2Rx"', '"Rod2Rz"'))
    with pytest.raises(DeckFormatError, match="unsupported OUTPUT"):
        DeckFile.from_text(_MIXED_DECK.replace('"Body1Fx"', '"Body1TenA"'))


@pytest.mark.parametrize(
    "replacement, message",
    [
        (
            "chainR3    0.2466   373.5          1.607e9|1.607e9 -1.0 0.0 1.37 0.64 1.0 0.0",
            "Ed must exceed Es",
        ),
        (
            "chainR3    0.2466   373.5          1.607e9|1.8e9 -1.0|-0.1 0.0 1.37 0.64 1.0 0.0",
            "Bd must be non-negative",
        ),
        (
            "chainR3    0.0      373.5          1.607e9 -1.0 0.0 1.37 0.64 1.0 0.0",
            "requires Diam > 0",
        ),
        (
            "chainR3    0.2466   373.5          1.607e9 -1.0 -1.0 1.37 0.64 1.0 0.0",
            "requires EI >= 0",
        ),
    ],
)
def test_used_line_type_physics_match_native_finalizer(tmp_path, replacement, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    original = (
        "chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0"
    )
    path = tmp_path / "invalid-line-type.dat"
    path.write_text(source.replace(original, replacement), encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


def test_held_points_reject_dynamic_load_columns(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "1     Fixed     500.0    0.0    -100.0    0       0       0      0",
        "1     Fixed     500.0    0.0    -100.0    1       0       0      0",
    )
    path = tmp_path / "loaded-fixed-point.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match="held POINT must not carry"):
        DeckFile.read(path)


def test_equivalent_buoyancy_rows_are_unique_and_positive(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    marker = "--------------------- POINTS -------------------------------------------"
    block = (
        "--------------------- EQUIVALENT BUOYANCY ------------------------------\n"
        "chainR3 0.3 100\n"
        "CHAINR3 0.4 120\n"
    )
    duplicate = tmp_path / "duplicate-equivalent.dat"
    duplicate.write_text(source.replace(marker, block + marker), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="duplicate EQUIVALENT BUOYANCY"):
        DeckFile.read(duplicate)

    nonpositive = tmp_path / "nonpositive-equivalent.dat"
    block = (
        "--------------------- EQUIVALENT BUOYANCY ------------------------------\nchainR3 0 100\n"
    )
    nonpositive.write_text(source.replace(marker, block + marker), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="diameter must be positive"):
        DeckFile.read(nonpositive)

    negative_mass = tmp_path / "negative-equivalent-mass.dat"
    block = (
        "--------------------- EQUIVALENT BUOYANCY ------------------------------\n"
        "chainR3 0.1 -1000\n"
    )
    negative_mass.write_text(source.replace(marker, block + marker), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="negative dry mass"):
        DeckFile.read(negative_mass)


@pytest.mark.parametrize(
    "option_rows, message",
    [
        ('"bed.dat" bathymetryFile', "mutually exclusive"),
        ("0.3 dtM\n1.0 TMax", "integer multiple"),
    ],
)
def test_cross_option_native_contracts_fail_closed(tmp_path, option_rows, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n" + option_rows,
    )
    path = tmp_path / "invalid-option-combination.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


@pytest.mark.parametrize("clock_row", ["0.1 dtM", "1.0 TMax"])
def test_standalone_clock_pair_and_caller_driven_exception_match_native(tmp_path, clock_row):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n" + clock_row,
    )
    path = tmp_path / "route-clock.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match="requires both dtM and TMax"):
        DeckFile.read(path)
    assert DeckFile.read(path, caller_driven=True).caller_driven


def test_active_friction_clock_dependency_is_route_aware(tmp_path):
    source = _minimal_chain_source()
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n0.3 frictionMu",
    )
    path = tmp_path / "route-friction.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match=r"frictionMu requires dtM and TMax.*TMax = 0"):
        DeckFile.read(path)
    DeckFile.read(path, caller_driven=True)


@pytest.mark.parametrize("caller_driven", [False, True])
def test_dynamic_points_with_friction_fail_closed_on_every_route(tmp_path, caller_driven):
    source = _minimal_chain_source()
    source = source.replace("2     Coupled", "2     Connect")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n0.3 frictionMu\n0.1 dtM\n1.0 TMax",
    )
    path = tmp_path / "dynamic-friction.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match="dynamic POINT types do not support seabed friction"):
        DeckFile.read(path, caller_driven=caller_driven)


@pytest.mark.parametrize(
    ("option_row", "message"),
    [
        ('"motion.dat" motionFile', "motionFile requires dtM"),
        ("airy 2 8 0 waves", "waves requires dtM"),
    ],
)
def test_host_route_does_not_relax_deck_owned_kinematics_clock(tmp_path, option_row, message):
    source = _minimal_chain_source()
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n" + option_row,
    )
    path = tmp_path / "route-owned-kinematics.dat"
    path.write_text(source, encoding="utf-8")

    for caller_driven in (False, True):
        with pytest.raises(DeckFormatError, match=message) as err:
            DeckFile.read(path, caller_driven=caller_driven)
        # the standalone error says how to check the deck's static start; the host route's not
        assert ("give TMax = 0" in str(err.value)) is not caller_driven


def test_current_needs_the_deck_clock_only_on_the_standalone_route(tmp_path):
    source = _minimal_chain_source().replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\nuniform 1 0 0 current",
    )
    path = tmp_path / "current.dat"
    path.write_text(source, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="standalone OPTION current requires dtM and TMax"):
        DeckFile.read(path)
    assert DeckFile.read(path, caller_driven=True).option("current").values[0] == "uniform"


def test_caller_driven_argument_must_be_boolean():
    with pytest.raises(TypeError, match="must be a Boolean"):
        DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat", caller_driven="yes")


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ("2     Coupled", "2     Connect", "dynamic POINT types require"),
        ("-1.0       0.0      1.37", "-1.0       2.0e4    1.37", "finite-EI sections require"),
    ],
)
def test_dynamic_feature_clock_dependencies_are_route_aware(tmp_path, old, new, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "route-dynamic-feature.dat"
    path.write_text(source.replace(old, new), encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)
    DeckFile.read(path, caller_driven=True)


def test_zero_kbot_is_allowed_only_without_a_seabed(tmp_path):
    source = _minimal_chain_source()
    zero = source.replace("1.0e5        kBot", "0             kBot")
    suspended = zero.replace("100.0        WtrDpth   - Water depth (m)\n", "")
    valid = tmp_path / "suspended-zero-kbot.dat"
    valid.write_text(suspended, encoding="utf-8")
    DeckFile.read(valid)

    contact = tmp_path / "contact-zero-kbot.dat"
    contact.write_text(zero, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="kBot must be positive"):
        DeckFile.read(contact)


@pytest.mark.parametrize(
    ("keyword", "message"),
    [
        ("kBot", "kBot must be positive"),
        ("cBot", "cBot must be non-negative"),
    ],
)
def test_contact_penalty_signs_are_conditional_on_seabed(tmp_path, keyword, message):
    source = _minimal_chain_source()
    if keyword == "kBot":
        source = source.replace("1.0e5        kBot", "-1            kBot")
    else:
        source = source.replace(
            "100.0        WtrDpth   - Water depth (m)",
            "100.0        WtrDpth   - Water depth (m)\n-1 cBot",
        )

    active_path = tmp_path / f"active-{keyword.lower()}.dat"
    active_path.write_text(source, encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(active_path)

    suspended_path = tmp_path / f"suspended-{keyword.lower()}.dat"
    suspended_path.write_text(
        source.replace("100.0        WtrDpth   - Water depth (m)\n", ""),
        encoding="utf-8",
    )
    DeckFile.read(suspended_path)


def test_zero_friction_is_an_inactive_suspended_option(tmp_path):
    source = _minimal_chain_source()
    suspended = source.replace("100.0        WtrDpth   - Water depth (m)\n", "")
    suspended = suspended.replace(
        "1.0e5        kBot      - Seabed penalty stiffness base (Pa/m)",
        "0 frictionMu - Disabled seabed friction",
    )
    path = tmp_path / "suspended-zero-friction.dat"
    path.write_text(suspended, encoding="utf-8")

    deck = DeckFile.read(path)
    assert deck.option("frictionMu").values == ("0",)
    with pytest.raises(KeyError):
        deck.option("WtrDpth")


@pytest.mark.parametrize("option", ["bathymetryFile", "motionFile", "WaterKin"])
def test_empty_path_options_fail_closed(tmp_path, option):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        f'"" {option}',
    )
    path = tmp_path / "empty-path-option.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match="non-empty path"):
        DeckFile.read(path)


def test_static_line_endpoint_topology_matches_native_normalization(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    fixed_fixed = source.replace("2     Coupled", "2     Fixed  ")
    invalid = tmp_path / "fixed-fixed-line.dat"
    invalid.write_text(fixed_fixed, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="End A must be Coupled/Vessel"):
        DeckFile.read(invalid)

    stock_order = source.replace("1     2       1       -", "1     1       2       -")
    valid = tmp_path / "stock-endpoint-order.dat"
    valid.write_text(stock_order, encoding="utf-8")
    DeckFile.read(valid)

    below = source.replace(
        "2     Coupled   0.0      0.0    0.0",
        "2     Coupled   0.0      0.0    -101.0",
    )
    invalid = tmp_path / "fairlead-below-anchor.dat"
    invalid.write_text(below, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="fairlead must not be below"):
        DeckFile.read(invalid)


@pytest.mark.parametrize(
    "channel",
    [
        "FairTen1",
        "AnchAngle1",
        "FairDecl1",
        "Point2px",
        "Ten1N56",
        "Curv1N1",
        "BendMom1N20",
        "L1N3px",
        "L1N4vy",
        "L1N5az",
        "L1N6Dec",
        "L1N7Azi",
        "TDP1s",
        "TDP1x",
        "tdp1Y",
        "TDP1z",
        "TDP1Lay",
        "TDP1Exc",
        "TDP1Grd",
        "AnchFz1",
        "AnchFH1",
        "anchfz01",
    ],
)
def test_output_channel_vocabulary_matches_native_parser(tmp_path, channel):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace('"FairTen1"', f'"{channel}"')
    path = tmp_path / "valid-output-channel.dat"
    path.write_text(source, encoding="utf-8")

    assert channel in DeckFile.read(path).outputs


@pytest.mark.parametrize(
    "channel, message",
    [
        ("FairTen2", "unknown line"),
        ("Point3px", "unknown point"),
        ("Ten1N57", "node exceeds"),
        ("Point2px_raw", "unsupported OUTPUT"),
        ("CableTension1", "unsupported OUTPUT"),
        ("TDP2s", "unknown line"),
        ("TDP1q", "unsupported OUTPUT"),
        ("TDP1sx", "unsupported OUTPUT"),
        ("TDP1Grdx", "unsupported OUTPUT"),
        ("AnchFz2", "unknown line"),
        ("AnchFH0", "unknown line"),
        ("AnchFz1x", "unsupported OUTPUT"),
        ("AnchFy1", "unsupported OUTPUT"),
    ],
)
def test_invalid_output_channels_fail_before_case_generation(tmp_path, channel, message):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace('"FairTen1"', f'"{channel}"')
    path = tmp_path / "invalid-output-channel.dat"
    path.write_text(source, encoding="utf-8")

    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)


@pytest.mark.parametrize("channel", ["FairTen1", "AnchFz1", "AnchFH1"])
def test_finite_ei_cable_shared_by_two_turbines_runs_coupled(tmp_path, channel):
    # native build_one_hermite_cable: the coupled aggregate drives a finite-EI cable between two
    # turbines at both ends (End B on its own moving column), end-force channels included
    path = _chain_variant(
        tmp_path,
        ("1.607e9    -1.0       0.0 ", "1.607e9    -1.0       2.0e5 "),
        ("1     Fixed     500.0", "1     Turbine2  500.0"),
        ("2     Coupled   0.0", "2     Turbine1  0.0"),
        ('"FairTen1"', f'"{channel}"'),
    )
    assert channel in DeckFile.read(path, caller_driven=True).outputs


def test_ei0_line_shared_by_two_turbines_keeps_its_end_force_channels(tmp_path):
    path = _chain_variant(
        tmp_path,
        ("1     Fixed     500.0", "1     Turbine2  500.0"),
        ("2     Coupled   0.0", "2     Turbine1  0.0"),
        ('"FairTen1"', '"AnchFz1"'),
    )
    assert "AnchFz1" in DeckFile.read(path, caller_driven=True).outputs


def test_case_generation_records_changes_hashes_and_working_directory(tmp_path):
    source = ROOT / "examples/chain_catenary_r3_100m.dat"
    cases = generate_deck_cases(
        source,
        tmp_path,
        {
            "depth_180": {"option.WtrDpth": 180.0},
            "mesh_70": {"section.1.1.NumSegs": 70},
        },
    )
    assert [case.name for case in cases] == ["depth_180", "mesh_70"]
    assert all(case.working_directory == tmp_path.resolve() for case in cases)
    assert DeckFile.read(cases[0].deck).option("WtrDpth").values == ("180",)
    manifest = json.loads((tmp_path / "cases.json").read_text(encoding="utf-8"))
    assert manifest["schema"] == "cabledyn-deck-cases-v1"
    assert manifest["source_directory"] == str(source.parent.resolve())
    assert manifest["working_directory"] == str(tmp_path.resolve())
    assert len(manifest["source_sha256"]) == 64
    assert manifest["cases"][1]["changes"] == {"section.1.1.NumSegs": 70}
    assert manifest["cases"][0]["sha256"] == cases[0].sha256
    with pytest.raises(FileExistsError):
        generate_deck_cases(source, tmp_path, {"again": {"option.WtrDpth": 190.0}})


def test_case_manifest_cannot_replace_source_deck(tmp_path):
    source = tmp_path / "cases.json"
    original = (ROOT / "examples/chain_catenary_r3_100m.dat").read_bytes()
    source.write_bytes(original)

    with pytest.raises(ValueError, match="must not replace the source"):
        generate_deck_cases(
            source,
            tmp_path,
            {"base": {"option.WtrDpth": 190.0}},
            overwrite=True,
        )
    assert source.read_bytes() == original
    assert not (tmp_path / "base.dat").exists()


def test_case_generation_rebases_relative_ancillary_paths(tmp_path):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "syrope.dat"
    source.write_text(
        (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    destination = tmp_path / "cases"
    (case,) = generate_deck_cases(source, destination, {"base": {"option.dtM": 0.025}})
    deck = DeckFile.read(case.deck)
    ea = deck.line_types[0].tokens[3]
    relative = ea[len("SYROPE:") :].split("|", 1)[0]
    assert re.search(
        r'"SYROPE:[^"\r\n]+\|1\.53e8\|23\.12"',
        case.deck.read_text(encoding="utf-8"),
    )
    assert (case.deck.parent / relative).resolve() == (
        source_directory / "data/syrope/syrope_settings.dat"
    ).resolve()
    assert case.working_directory == destination.resolve()

    bathymetry = source_directory / "data" / "bathy_profile.dat"
    bathymetry.parent.mkdir()
    bathymetry.write_text(
        "".join(f"{x} {y} 100.0\n" for x in (-2000.0, 2000.0) for y in (-2000.0, 2000.0)),
        encoding="utf-8",
    )
    deck_text = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    deck_text = deck_text.replace("100.0        WtrDpth", "data/bathy_profile.dat bathymetryFile")
    deck_path = source_directory / "base.dat"
    deck_path.write_text(deck_text, encoding="utf-8")
    (option_case,) = generate_deck_cases(
        deck_path, destination / "options", {"base": {"option.kBot": 2.0e5}}
    )
    rewritten = DeckFile.read(option_case.deck).option("bathymetryFile").values[0]
    assert (option_case.deck.parent / rewritten).resolve() == bathymetry.resolve()

    windows_text = deck_text.replace(
        "data/bathy_profile.dat bathymetryFile",
        r"C:\data\bathy.dat bathymetryFile",
    )
    windows_path = source_directory / "windows-absolute.dat"
    windows_path.write_text(windows_text, encoding="utf-8")
    (windows_case,) = generate_deck_cases(
        windows_path, destination / "windows", {"base": {"option.kBot": 3.0e5}}
    )
    assert DeckFile.read(windows_case.deck).option("bathymetryFile").values == (
        r"C:\data\bathy.dat",
    )


@pytest.mark.parametrize("native_relative", ["~/bed.dat", "~engineer/bed.dat"])
def test_case_generation_treats_tilde_paths_as_native_relative(tmp_path, native_relative):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "tilde-path.dat"
    text = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source.write_text(
        text.replace("100.0        WtrDpth", f"{native_relative} bathymetryFile"),
        encoding="utf-8",
    )

    (case,) = generate_deck_cases(
        source,
        tmp_path / "cases",
        {"base": {"option.kBot": 2.0e5}},
    )
    rewritten = DeckFile.read(case.deck).option("bathymetryFile").values[0]
    expected = Path(
        os.path.relpath(source_directory / native_relative, case.deck.parent)
    ).as_posix()
    assert rewritten == expected


def test_numeric_path_exemption_is_limited_to_waterkin_modes(tmp_path):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    text = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    text = text.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "123 bathymetryFile\n0.1 dtM\n1.0 TMax\n456 motionFile\n0 WaterKin",
    )
    source = source_directory / "numeric-paths.dat"
    source.write_text(text, encoding="utf-8")

    (case,) = generate_deck_cases(
        source,
        tmp_path / "cases",
        {"base": {"option.kBot": 2.0e5}},
    )
    generated = DeckFile.read(case.deck)
    bathymetry = generated.option("bathymetryFile").values[0]
    motion = generated.option("motionFile").values[0]
    assert (case.deck.parent / bathymetry).resolve() == (source_directory / "123").resolve()
    assert (case.deck.parent / motion).resolve() == (source_directory / "456").resolve()
    assert generated.option("WaterKin").values == ("0",)


def test_case_generation_accepts_long_rebased_syrope_token(tmp_path):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "syrope.dat"
    source.write_text(
        (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    # The native EA column holds a 512-character settings reference, so a rebased
    # path longer than the former 63-character limit is valid.
    destination = tmp_path / ("nested_" + "a" * 30) / ("cases_" + "b" * 30)
    (case,) = generate_deck_cases(source, destination, {"base": {"option.dtM": 0.025}})
    ea = DeckFile.read(case.deck).line_types[0].tokens[3]
    assert len(ea) > 63
    assert (case.deck.parent / ea[len("SYROPE:") :].split("|")[0]).resolve() == (
        source_directory / "data/syrope/syrope_settings.dat"
    ).resolve()


def test_case_generation_rejects_rebased_row_beyond_native_record_length(
    tmp_path,
    monkeypatch,
):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "syrope.dat"
    source.write_text(
        (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    destination = tmp_path / "cases"
    # A relocation whose relative settings path no 512-character record can hold.
    monkeypatch.setattr(
        "cabledyn.deck_file.os.path.relpath",
        lambda *_: "../" * 200 + "settings.dat",
    )
    with pytest.raises(DeckFormatError, match="longer than 512 characters"):
        generate_deck_cases(source, destination, {"base": {"option.dtM": 0.025}})
    assert not list(destination.glob("*.dat"))
    assert not (destination / "cases.json").exists()


def test_case_generation_preserves_last_row_disabled_path_option(tmp_path):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "disabled-waterkin.dat"
    text = _minimal_chain_source()
    source.write_text(
        text.replace(
            "100.0        WtrDpth   - Water depth (m)",
            "100.0 WtrDpth\ndata/wk.dat WaterKin\n0 WaveKin",
        ),
        encoding="utf-8",
    )
    (case,) = generate_deck_cases(
        source,
        tmp_path / "cases",
        {"base": {"option.kBot": 2.0e5}},
    )
    generated = DeckFile.read(case.deck)
    waterkin = [
        record for record in generated.options if record.keyword.lower() in {"waterkin", "wavekin"}
    ]
    assert [record.values for record in waterkin] == [("data/wk.dat",), ("0",)]


@pytest.mark.parametrize("disabled", ["0", "none"])
def test_case_generation_does_not_rebase_disabled_motion_file(tmp_path, disabled):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "disabled-motion.dat"
    source.write_text(
        _minimal_chain_source().replace(
            "100.0        WtrDpth   - Water depth (m)",
            f"100.0 WtrDpth\n{disabled} motionFile",
        ),
        encoding="utf-8",
    )

    (case,) = generate_deck_cases(
        source,
        tmp_path / "cases",
        {"base": {"option.kBot": 2.0e5}},
    )
    assert DeckFile.read(case.deck).option("motionFile").values == (disabled,)


def test_case_generation_rebases_scalar_path_with_undelimited_trailing_prose(tmp_path):
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    source = source_directory / "waterkin-prose.dat"
    text = _minimal_chain_source()
    source.write_text(
        text.replace(
            "100.0        WtrDpth   - Water depth (m)",
            "100.0 WtrDpth\ndata/wk.dat WaterKin water kinematics file",
        ),
        encoding="utf-8",
    )
    destination = tmp_path / "cases"
    (case,) = generate_deck_cases(
        source,
        destination,
        {"base": {"option.kBot": 2.0e5}},
    )
    record = DeckFile.read(case.deck).option("WaterKin")
    assert len(record.values) == 1
    assert record.trailing == ("water", "kinematics", "file")
    assert (case.deck.parent / record.values[0]).resolve() == (
        source_directory / "data/wk.dat"
    ).resolve()
    assert "WaterKin water kinematics file" in case.deck.read_text(encoding="utf-8")


def test_unknown_selector_and_case_name_fail_before_writing(tmp_path):
    source = ROOT / "examples/chain_catenary_r3_100m.dat"
    with pytest.raises(ValueError, match="selector"):
        generate_deck_cases(source, tmp_path, {"bad": {"line.1.NodeA": 2}})
    assert not list(tmp_path.glob("*.dat"))
    with pytest.raises(ValueError, match="case name"):
        generate_deck_cases(source, tmp_path, {"../escape": {"option.WtrDpth": 190.0}})
    with pytest.raises(ValueError, match="must not be empty"):
        generate_deck_cases(source, tmp_path, {})


def test_case_generation_cannot_replace_source_even_with_overwrite(tmp_path):
    source = tmp_path / "base.dat"
    source.write_bytes((ROOT / "examples/chain_catenary_r3_100m.dat").read_bytes())
    original = source.read_bytes()
    with pytest.raises(ValueError, match="source deck"):
        generate_deck_cases(source, tmp_path, {"base": {"option.WtrDpth": 190.0}}, overwrite=True)
    assert source.read_bytes() == original


def test_deck_cli_validate_set_and_generate(tmp_path, capsys):
    source = ROOT / "examples/chain_catenary_r3_100m.dat"
    assert deck_main(["validate", str(source)]) == 0
    assert "valid:" in capsys.readouterr().out
    edited = tmp_path / "edited.dat"
    assert deck_main(["set", str(source), str(edited), "option.WtrDpth", "175.0"]) == 0
    assert DeckFile.read(edited).option("WtrDpth").values == ("175",)
    spec = tmp_path / "cases-spec.json"
    spec.write_text(json.dumps({"coarse": {"section.1.1.NumSegs": 30}}), encoding="utf-8")
    case_dir = tmp_path / "cases"
    assert deck_main(["generate", str(source), str(spec), str(case_dir)]) == 0
    assert DeckFile.read(case_dir / "coarse.dat").sections[0].tokens[3] == "30"


def test_dual_use_mixed_static_and_caller_driven_generation_preserve_route_contract(
    tmp_path, capsys
):
    source = ROOT / "examples/iea15mw_umaine_mixed_cabledyn.dat"
    standalone = DeckFile.read(source)
    assert not standalone.caller_driven
    assert standalone.option("TMax").values == ("0.0",)

    assert deck_main(["validate", str(source), "--caller-driven"]) == 0
    assert "valid:" in capsys.readouterr().out
    (case,) = generate_deck_cases(
        source,
        tmp_path / "coupled-cases",
        {"base": {"option.dtM": 0.025}},
        caller_driven=True,
    )
    assert DeckFile.read(case.deck, caller_driven=True).caller_driven
    manifest = json.loads((case.deck.parent / "cases.json").read_text(encoding="utf-8"))
    assert manifest["caller_driven"] is True


# ---------------------------------------------------------------------------
# In-memory reference decks for single-edit contracts
# ---------------------------------------------------------------------------

# One small deck per route (static EI=0, dynamic finite-EI), so that each native reader
# contract is exercised by one targeted edit.

_BAR = "-" * 21
_STATIC = f"""\
{_BAR} CableDyn Input File {_BAR}
in-memory fixture: one grounded chain line
{_BAR} LINE TYPES {_BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0
{_BAR} POINTS {_BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Fixed 400.0 0.0 -50.0 0 0 0 0
2 Coupled 0.0 0.0 0.0 0 0 0 0
{_BAR} LINES {_BAR}
ID NodeA NodeB Outputs
1 2 1 -
{_BAR} SECTIONS {_BAR}
LineID LineType Length NumSegs
1 chain 410.0 41
{_BAR} OPTIONS {_BAR}
9.80665 g
1025.0 rhoW
50.0 WtrDpth
{_BAR} OUTPUTS {_BAR}
FairTen1
{_BAR} need this line {_BAR}
"""
_OPTIONS_HEADING = f"{_BAR} OPTIONS {_BAR}\n"


def _edit(base: str, *edits: tuple[str, str]) -> str:
    """Apply exact, once-only text replacements, failing on a stale fixture."""
    text = base
    for old, new in edits:
        assert old in text, old
        text = text.replace(old, new, 1)
    return text


def _with_section(base: str, heading: str, *rows: str) -> str:
    """Insert an optional section, with its rows, before OPTIONS."""
    block = f"{_BAR} {heading} {_BAR}\n" + "".join(f"{row}\n" for row in rows)
    return _edit(base, (_OPTIONS_HEADING, block + _OPTIONS_HEADING))


def _example(name: str, *edits: tuple[str, str]) -> str:
    return _edit((ROOT / "examples" / name).read_text(encoding="utf-8"), *edits)


# Dynamic route with a finite-EI line type (EI > 0 needs dtM/TMax standalone).
_DYNAMIC = _edit(
    _STATIC,
    ("50.0 WtrDpth\n", "50.0 WtrDpth\n0.1 dtM\n10.0 TMax\n"),
    ("1.674e9 -1.0 0.0 1.37", "1.674e9 -1.0 1.0e4 1.37"),
)
# The static fixture with a dynamic clock (EI = 0 line).
_TIMED = _edit(_STATIC, ("50.0 WtrDpth\n", "50.0 WtrDpth\n0.1 dtM\n10.0 TMax\n"))
_END_HEADER = "LineID End Stiffness EzX EzY EzZ"
_CHAIN = "chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0"
_ANCHOR = "1 Fixed 400.0 0.0 -50.0 0 0 0 0"
_FAIRLEAD = "2 Coupled 0.0 0.0 0.0 0 0 0 0"


def test_range_flag_and_range_start_follow_native_rules():
    ranged = _edit(
        _DYNAMIC, ("1 2 1 -\n", "1 2 1 pR\n"), ("10.0 TMax\n", "10.0 TMax\n2.5 RangeStart\n")
    )
    deck = DeckFile.from_text(ranged)
    assert deck.option("RangeStart").values == ("2.5",)
    with pytest.raises(DeckFormatError, match="needs a line with the LINES Outputs flag r"):
        DeckFile.from_text(_edit(_DYNAMIC, ("10.0 TMax\n", "10.0 TMax\n2.5 RangeStart\n")))
    with pytest.raises(DeckFormatError, match="exceeds TMax"):
        DeckFile.from_text(_edit(ranged, ("2.5 RangeStart", "12.0 RangeStart")))
    # TMax = 0 checks the static start of the dynamic deck: its range graphs hold the t = 0 row
    zero = DeckFile.from_text(_edit(ranged, ("10.0 TMax", "0.0 TMax")))
    assert zero.option("RangeStart").values == ("2.5",)
    with pytest.raises(DeckFormatError, match="must be >= 0"):
        DeckFile.from_text(_edit(ranged, ("2.5 RangeStart", "-1.0 RangeStart")))
    with pytest.raises(DeckFormatError, match="needs a dynamic deck"):
        DeckFile.from_text(
            _edit(
                _STATIC,
                ("1 2 1 -\n", "1 2 1 r\n"),
                ("50.0 WtrDpth\n", "50.0 WtrDpth\n0 RangeStart\n"),
            )
        )
    with pytest.raises(DeckFormatError, match="accepts only '-', 'p', 't', 'r', and 'V'"):
        DeckFile.from_text(_edit(_STATIC, ("1 2 1 -\n", "1 2 1 rx\n")))
    assert DeckFile.from_text(_edit(_STATIC, ("1 2 1 -\n", "1 2 1 r\n"))).lines[0].tokens[3] == "r"


def test_coupled_range_flag_and_range_start_take_the_host_clock():
    # the host owns the run time: no deck TMax is needed, and one is not a bound on RangeStart
    no_tmax = _edit(
        _STATIC,
        ("1 2 1 -\n", "1 2 1 r\n"),
        ("50.0 WtrDpth\n", "50.0 WtrDpth\n100.0 RangeStart\n"),
    )
    deck = DeckFile.from_text(no_tmax, caller_driven=True)
    assert deck.option("RangeStart").values == ("100.0",)
    assert deck.lines[0].tokens[3] == "r"
    deck_tmax = _edit(
        _DYNAMIC, ("1 2 1 -\n", "1 2 1 r\n"), ("10.0 TMax\n", "10.0 TMax\n12.0 RangeStart\n")
    )
    with pytest.raises(DeckFormatError, match="exceeds TMax"):
        DeckFile.from_text(deck_tmax)
    assert DeckFile.from_text(deck_tmax, caller_driven=True).option("RangeStart").values == (
        "12.0",
    )
    # the flag is still what RangeStart needs
    with pytest.raises(DeckFormatError, match="needs a line with the LINES Outputs flag r"):
        DeckFile.from_text(_edit(no_tmax, ("1 2 1 r\n", "1 2 1 -\n")), caller_driven=True)


def test_fixtures_are_valid_decks():
    static = DeckFile.from_text(_STATIC)
    dynamic = DeckFile.from_text(_DYNAMIC)
    assert static.line_types[0].tokens[5] == "0.0"
    assert dynamic.option("dtM").values == ("0.1",)
    assert static.outputs == dynamic.outputs == ("FairTen1",)


# ---------------------------------------------------------------------------
# Native tokenization, quoting, and number grammar
# ---------------------------------------------------------------------------

_CHAIN_ROW = (
    "chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0"
)
_ANCHOR_ROW = "1     Fixed     500.0    0.0    -100.0    0       0       0      0"
_OPTIONS_HEADER = "--------------------- OPTIONS ------------------------------------------\n"


def _chain_variant(tmp_path, *replacements, name="variant.dat", count=1):
    text = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    for old, new in replacements:
        assert old in text, old
        text = text.replace(old, new, count)
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ("1.607e9    -1.0", "1e300    -1.0", "outside the admissible range"),
        ("1.607e9    -1.0", "1.0000001e15    -1.0", "outside the admissible range"),
        ("0.2466   373.5", "0.2466   1.5e6", "outside the admissible range"),
        ("0.2466   373.5", "1000.5   373.5", "outside the admissible range"),
        ("chainR3    550.0    55", "chainR3    1e300    55", "at most 1e6 m"),
        ("chainR3    550.0    55", "chainR3    1e-300   55", "segments of at least 1e-6 m"),
        ("chainR3    550.0    55", "chainR3    5.0e-5   55", "segments of at least 1e-6 m"),
    ],
)
def test_native_magnitude_limits_are_mirrored(tmp_path, old, new, message):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(_chain_variant(tmp_path, (old, new)))


def test_native_magnitude_limits_admit_their_bounds(tmp_path):
    deck = DeckFile.read(
        _chain_variant(
            tmp_path,
            ("1.607e9    -1.0", "1.0e15    -1.0"),
            ("chainR3    550.0    55", "chainR3    6.0e-5   55"),
        )
    )
    assert deck.line_types[0].tokens[3] == "1.0e15"


def test_stock_line_rows_share_the_section_length_limit(tmp_path):
    path = _chain_variant(
        tmp_path,
        ("1     2       1       -", "1 chainR3 2 1 1.5e6 25 -"),
    )
    text = path.read_text(encoding="utf-8")
    start = text.index("--------------------- SECTIONS")
    end = text.index("--------------------- OPTIONS")
    path.write_text(text[:start] + text[end:], encoding="utf-8")
    with pytest.raises(DeckFormatError, match="at most 1e6 m"):
        DeckFile.read(path)


@pytest.mark.parametrize(
    ("old", "new", "message"),
    [
        ("9.80665      g ", '"9.80665"      g ', "g must be numeric"),
        ("9.80665      g ", '9.80665      "g" ', "unknown OPTION keyword"),
        ("False     adaptive_mesh", '"False"     adaptive_mesh', "adaptive_mesh must be"),
        ("500.0    0.0    -100.0", '"500.0"    0.0    -100.0', "must be an unquoted number"),
        ("0.2466   373.5 ", '0.2466   "373.5" ', "must be an unquoted number"),
        ("1.0   0.0\n", "1.0   0.0,\n", "list-directed separator"),
        ("0.2466   373.5 ", "0.2466   373/5 ", "list-directed separator"),
        ("0.2466   373.5 ", "0.2466   1*373.5 ", "repeat count"),
    ],
)
def test_quoted_numbers_keywords_and_list_separators_fail_like_native(
    tmp_path,
    old,
    new,
    message,
):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(_chain_variant(tmp_path, (old, new)))


@pytest.mark.parametrize("name", ["R4/chain", "R4,chain", "R4;chain"])
def test_line_type_names_with_list_separators_must_be_quoted(tmp_path, name):
    with pytest.raises(DeckFormatError, match="list-directed separator"):
        DeckFile.read(_chain_variant(tmp_path, ("chainR3", name), count=2))
    quoted = DeckFile.read(
        _chain_variant(tmp_path, ("chainR3", f'"{name}"'), count=2, name="quoted.dat")
    )
    assert quoted.line_types[0].tokens[0] == name
    assert quoted.line_types[0].quoted[0] is True


def test_unquoted_syrope_settings_path_is_read_whole_like_native(tmp_path):
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    path = tmp_path / "unquoted-syrope.dat"
    path.write_text(
        source.replace(
            '"SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"',
            "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12",
        ),
        encoding="utf-8",
    )
    deck = DeckFile.read(path)
    row = deck.line_types[0]
    assert row.tokens[3] == "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"
    assert row.quoted[3] is False


@pytest.mark.parametrize("ba", ["-0.8/2", "1,5", "2*0.1"])
def test_unquoted_separators_outside_the_ea_column_still_fail(tmp_path, ba):
    with pytest.raises(DeckFormatError, match="column 5"):
        DeckFile.read(_chain_variant(tmp_path, ("1.607e9    -1.0", f"1.607e9    {ba}")))


def test_quoted_table_token_may_contain_whitespace_like_native(tmp_path):
    path = _chain_variant(tmp_path, ("chainR3", '"chain R3"'), count=2)
    deck = DeckFile.read(path)
    assert deck.line_types[0].tokens[0] == "chain R3"
    assert deck.sections[0].tokens[1] == "chain R3"
    # Editing a later column keeps the multi-word quoted token intact.
    deck.set_line_type("chain R3", mass=380.0)
    assert '"chain R3" 0.2466 380 ' in deck.text()
    assert DeckFile.from_text(deck.text()).line_types[0].tokens[:3] == ("chain R3", "0.2466", "380")


def test_unterminated_quote_in_a_table_row_fails_closed(tmp_path):
    # The unterminated quote runs to the end of the row, like the native token_bounds.
    with pytest.raises(DeckFormatError, match="invalid quoting"):
        DeckFile.read(
            _chain_variant(
                tmp_path, ("1        chainR3    550.0    55", '1        "chainR3    550.0    55')
            )
        )
    with pytest.raises(DeckFormatError, match="longer than 64 characters"):
        DeckFile.read(_chain_variant(tmp_path, ("chainR3", '"chainR3'), count=1, name="long.dat"))


@pytest.mark.parametrize(
    ("old", "new", "accepted"),
    [
        ("chainR3", "c" * 64, True),
        ("chainR3", "c" * 65, False),
        ("chainR3", '"' + "c" * 64 + '"', True),
        ("Fixed", "F" * 65, False),
        ("500.0    0.0    -100.0", "500." + "0" * 61 + "    0.0    -100.0", False),
    ],
)
def test_table_tokens_longer_than_64_characters_fail_like_native(tmp_path, old, new, accepted):
    path = _chain_variant(tmp_path, (old, new), count=2 if old == "chainR3" else 1)
    if accepted:
        assert DeckFile.read(path).line_types[0].tokens[0] == new.strip('"')
    else:
        with pytest.raises(DeckFormatError, match="longer than 64 characters"):
            DeckFile.read(path)


def test_outputs_split_on_commas_and_strip_quotes_like_native(tmp_path):
    path = _chain_variant(tmp_path, ('"FairTen1"', "FairTen1,Point2px 'Con2pz'"))
    deck = DeckFile.read(path)
    assert deck.outputs[:3] == ("FairTen1", "Point2px", "Con2pz")


def test_con_point_channel_alias_is_checked_like_point(tmp_path):
    with pytest.raises(DeckFormatError, match="unknown point"):
        DeckFile.read(_chain_variant(tmp_path, ('"FairTen1"', "Con9px")))


@pytest.mark.parametrize(
    ("ids", "accepted"),
    [
        ("1,2", True),
        ("1, 2", True),
        ("1 ,2", True),
        ("1 2", False),
        ("1,,2", False),
    ],
)
def test_syrope_ic_line_lists_follow_native_comma_rule(ids, accepted):
    deck_path = ROOT / "examples/syrope_polyester_mooring.dat"
    text = deck_path.read_text(encoding="utf-8")
    for old, new in (
        (
            "2     Vessel    20.5     0.0    0.0       0       0       0      0\n",
            "2     Vessel    20.5     0.0    0.0       0       0       0      0\n"
            "3     Vessel    0.0      20.5   0.0       0       0       0      0\n",
        ),
        ("1     2       1       -\n", "1     2       1       -\n2     3       1       -\n"),
        (
            "1        rope       20.0     8\n",
            "1        rope       20.0     8\n2        rope       20.0     8\n",
        ),
        ("1       2.0e6   1.5e6\n", f"{ids} 2.0e6 1.5e6\n"),
    ):
        assert old in text
        text = text.replace(old, new, 1)
    if accepted:
        deck = DeckFile.from_text(text, path=deck_path)
        assert len(deck.lines) == 2
    else:
        with pytest.raises(DeckFormatError, match=r"separated by commas|malformed SYROPE IC"):
            DeckFile.from_text(text, path=deck_path)


def test_rendered_names_are_quoted_when_they_need_it(tmp_path):
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    deck.apply_many({"line_type.chainR3.name": "R4/chain", "section.1.1.linetype": "R4/chain"})
    assert '"R4/chain" 0.2466' in deck.text()
    assert '1 "R4/chain" 550.0 55' in deck.text()
    reread = DeckFile.read(deck.write(tmp_path / "renamed.dat"))
    assert reread.line_types[0].tokens[0] == "R4/chain"

    before = deck.text()
    with pytest.raises(DeckFormatError, match="missing line type"):
        deck.apply_many({"line_type.R4/chain.name": "R5,chain"})
    assert deck.text() == before


@pytest.mark.parametrize("value", [None, {"a": 1}, ["x"], "two words", 'q"uote'])
def test_unrenderable_values_raise_value_error_without_mutation(value):
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(ValueError):
        deck.set_point(2, z=value)
    assert deck.text() == before


@pytest.mark.parametrize(
    "token",
    [
        "3.735Q2",
        "3.735d2",
        "3.735D+02",
        "373.",
        ".3735E3",
        "+373.5",
        "3.735E+02",
    ],
)
def test_fortran_real_forms_accepted_natively_are_accepted(tmp_path, token):
    deck = DeckFile.read(_chain_variant(tmp_path, ("0.2466   373.5 ", f"0.2466   {token} ")))
    assert deck.line_types[0].tokens[2] == token


@pytest.mark.parametrize(
    "token", ["3_73.5", "373.5e", "0x10", "373.5.0", ".", "3.735+2", "37350-2"]
)
def test_fortran_real_forms_rejected_natively_are_rejected(tmp_path, token):
    # a sign inside the mantissa ("3.735+2") is not the list-directed exponent natively
    with pytest.raises(DeckFormatError, match=r"must be numeric|is not a plain number"):
        DeckFile.read(_chain_variant(tmp_path, ("0.2466   373.5 ", f"0.2466   {token} ")))


@pytest.mark.parametrize(
    ("token", "valid"),
    [
        ("+55", True),
        ("055", True),
        ("5_5", False),
        ("55.0", False),
        ("5e1", False),
    ],
)
def test_integer_columns_follow_fortran_integer_grammar(tmp_path, token, valid):
    path = _chain_variant(tmp_path, ("550.0    55", f"550.0    {token}"))
    if valid:
        assert DeckFile.read(path).sections[0].tokens[3] == token
    else:
        with pytest.raises(DeckFormatError, match="NumSegs is invalid"):
            DeckFile.read(path)


def test_integer_ids_must_fit_32_bits(tmp_path):
    fits = _chain_variant(
        tmp_path,
        ("1     2       1       -", "1     2       2147483647       -"),
        (_ANCHOR_ROW, _ANCHOR_ROW.replace("1     Fixed", "2147483647     Fixed")),
    )
    assert DeckFile.read(fits).points[0].tokens[0] == "2147483647"
    overflow = _chain_variant(
        tmp_path,
        ("1     2       1       -", "1     2       2147483648       -"),
        (_ANCHOR_ROW, _ANCHOR_ROW.replace("1     Fixed", "2147483648     Fixed")),
        name="overflow.dat",
    )
    with pytest.raises(DeckFormatError, match="point id must be an integer"):
        DeckFile.read(overflow)


@pytest.mark.parametrize("name", ["Name", "TypeName", "(-)", "id"])
def test_line_type_named_like_a_header_word_is_data(tmp_path, name):
    deck = DeckFile.read(_chain_variant(tmp_path, ("chainR3", name), count=2))
    assert [row.tokens[0] for row in deck.line_types] == [name]


@pytest.mark.parametrize(
    ("token", "header"), [("/", True), (",", True), ("2*", True), ("NaN", False)]
)
def test_header_rows_are_rows_without_a_number_shaped_token(tmp_path, token, header):
    # native has_numeric_token: only a token spelled as a number makes a row data
    path = _chain_variant(
        tmp_path,
        ("(-)        (m)      (kg/m)", f"(-)  {token}  (m)      (kg/m)"),
    )
    if header:
        assert len(DeckFile.read(path).line_types) == 1
    else:
        with pytest.raises(DeckFormatError):
            DeckFile.read(path)


def test_header_row_with_plain_words_and_units_is_skipped(tmp_path):
    path = _chain_variant(tmp_path, ("(-)        (m)      (kg/m)", "(-)  -  T  (m)      (kg/m)"))
    assert len(DeckFile.read(path).line_types) == 1


# ---------------------------------------------------------------------------
# Native records, repeated sections, commentary, and encodings
# ---------------------------------------------------------------------------


def test_repeated_section_headers_append_rows_like_native(tmp_path):
    path = _chain_variant(
        tmp_path,
        ("2     Coupled   0.0", "--------------------- POINTS ---\n2     Coupled   0.0"),
        (_CHAIN_ROW, _CHAIN_ROW + "\n--- LINE TYPES ---\nwire 0.1 10 1e8 0 0 1.2 1.0 0.2 0.0"),
        ("100.0        WtrDpth", "--- OPTIONS ---\n100.0        WtrDpth"),
    )
    deck = DeckFile.read(path)
    assert [row.tokens[0] for row in deck.points] == ["1", "2"]
    assert [row.tokens[0] for row in deck.line_types] == ["chainR3", "wire"]
    assert deck.option("WtrDpth").values == ("100.0",)
    deck.set_point(2, z=-1.0)
    assert "2 Coupled 0.0 0.0 -1" in deck.text()


def test_option_commentary_with_apostrophes_is_ignored_like_native(tmp_path):
    path = _chain_variant(
        tmp_path,
        (
            "1025.0       rhoW      - Water density (kg/m^3)",
            "1025.0       rhoW  water's density - Water density (kg/m^3)",
        ),
    )
    deck = DeckFile.read(path)
    assert deck.option("rhoW").trailing == ("water's", "density")
    deck.set_option("rhoW", 1030.0)
    assert "1030 rhoW  water's density - Water density (kg/m^3)" in deck.text()


def test_bare_exponent_option_value_is_rejected(tmp_path):
    # a sign inside the mantissa is not a number natively ("1.0+5" is not 1.0e5)
    path = _chain_variant(tmp_path, ("1.0e5        kBot", "1.0+5        kBot"))
    with pytest.raises(DeckFormatError, match="kBot must be numeric"):
        DeckFile.read(path)


def test_non_utf8_comment_bytes_round_trip_exactly(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_bytes()
    payload = source.replace(b"-- R3 studless chain", b"-- R3 studless chain caf\xe9", 1)
    path = tmp_path / "latin1.dat"
    path.write_bytes(payload)
    deck = DeckFile.read(path)
    assert deck.text().encode("utf-8", "surrogateescape") == payload
    deck.set_point(2, z=-1.0)
    written = deck.write(tmp_path / "latin1-edited.dat").read_bytes()
    assert b"caf\xe9" in written


@pytest.mark.parametrize("separator", ["\x0c", " ", "\x85", "\x1c", "\x1d", "\x1e"])
def test_only_native_record_terminators_split_rows(tmp_path, separator):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    # Splitting at the separator would turn "garbage" into a malformed OPTIONS row.
    text = source.replace("100.0        WtrDpth", f"100.0 WtrDpth # note{separator}garbage", 1)
    path = tmp_path / "separator.dat"
    path.write_bytes(text.encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.text() == text

    inside_row = source.replace("100.0        WtrDpth", f"100.0{separator}        WtrDpth", 1)
    bad = tmp_path / "separator-in-row.dat"
    bad.write_bytes(inside_row.encode("utf-8"))
    if separator == "\x0c":
        # FF is ASCII whitespace: a token separator, as in the native reader.
        assert DeckFile.read(bad).option("WtrDpth").values == ("100.0",)
        return
    with pytest.raises(DeckFormatError):
        DeckFile.read(bad)


def test_lone_carriage_return_records_round_trip(tmp_path):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    path = tmp_path / "classic-mac.dat"
    path.write_bytes(source.replace("\n", "\r").encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.text().encode("utf-8") == path.read_bytes()


def test_records_longer_than_native_buffer_fail_unless_the_excess_is_comment(tmp_path):
    long_data = _chain_variant(tmp_path, ("0.4       rhoInf", "0.4 " + " " * 520 + "rhoInf"))
    with pytest.raises(DeckFormatError, match="longer than 512"):
        DeckFile.read(long_data)
    long_comment = _chain_variant(
        tmp_path,
        ("0.4       rhoInf", "0.4 rhoInf # " + "x" * 600),
        name="comment.dat",
    )
    DeckFile.read(long_comment)
    trailing_blanks = _chain_variant(
        tmp_path,
        (
            "0.4       rhoInf           - Generalised-alpha spectral radius {0<=rhoInf<=1} "
            "[default: 0.4]",
            "0.4 rhoInf" + " " * 600,
        ),
        name="blanks.dat",
    )
    DeckFile.read(trailing_blanks)


def test_edits_preserve_inline_comments_and_option_suffixes(tmp_path):
    path = _chain_variant(tmp_path, (_ANCHOR_ROW, _ANCHOR_ROW + "   # anchor pile"))
    deck = DeckFile.read(path)
    deck.set_point(1, x=510.0)
    assert "1 Fixed 510 0.0 -100.0 0 0 0 0   # anchor pile" in deck.text()
    deck.set_option("WtrDpth", 110.0)
    assert (
        "110 WtrDpth   - Water depth (m) [default: absent standalone; host-owned OpenFAST]"
        in deck.text()
    )
    deck.set_option("dynamic_solver", (0.25, 0.125, 20, 8))
    assert "dynamic_solver 0.25 0.125 20 8 - Relative tolerance, absolute tolerance" in deck.text()


def test_double_dash_inside_a_token_is_data_and_a_spaced_one_is_a_comment():
    deck = DeckFile.from_text(
        _edit(
            _STATIC,
            ("chain 0.252", "chain--r3 0.252"),
            ("1 chain 410.0 41", "1 chain--r3 410.0 41 -- stock inline comment"),
        )
    )
    assert deck.line_types[0].tokens[0] == "chain--r3"
    assert deck.sections[0].tokens == ("1", "chain--r3", "410.0", "41")


def test_final_record_without_terminator_round_trips():
    text = _STATIC.rstrip("\n")
    deck = DeckFile.from_text(text)
    assert deck.text() == text
    assert not deck.text().endswith("\n")


@pytest.mark.parametrize("token", ["2*", "2*390.0"])
def test_repeat_count_does_not_make_a_header_row_data(token):
    text = _edit(_STATIC, ("Name Diam Mass", f"Name {token} Mass"))
    assert len(DeckFile.from_text(text).line_types) == 1


def test_blank_and_comment_rows_inside_outputs_are_skipped():
    deck = DeckFile.from_text(_edit(_STATIC, ("FairTen1\n", "FairTen1\n\n   # note\nAnchTen1\n")))
    assert deck.outputs == ("FairTen1", "AnchTen1")


def test_constructor_and_reader_contracts(tmp_path):
    with pytest.raises(ValueError, match="same length"):
        DeckFile(tmp_path / "deck.dat", ["x"], [])
    missing = tmp_path / "absent.dat"
    with pytest.raises(DeckFormatError, match="cannot read"):
        DeckFile.read(missing)


def test_missing_required_section_is_named():
    text = _edit(_STATIC, (f"{_BAR} LINES {_BAR}\n", ""))
    with pytest.raises(DeckFormatError, match=r"missing LINES section\(s\)"):
        DeckFile.from_text(text)


# ---------------------------------------------------------------------------
# Native finalizer rules
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("mass", ["40.0", "48.95"])
def test_net_buoyant_ei0_line_type_fails_like_native(tmp_path, mass):
    path = _chain_variant(tmp_path, ("0.2466   373.5 ", f"0.2466   {mass} "))
    with pytest.raises(DeckFormatError, match="net-buoyant"):
        DeckFile.read(path)


@pytest.mark.parametrize(
    ("scale", "ei", "message"),
    [
        # inside the neutral band below the displaced mass: named weightless (EI = 0 only)
        (1.0 - 1.0e-7, "0.0", "neutrally buoyant .* weightless and slack"),
        (1.0 - 9.0e-7, "0.0", "neutrally buoyant .* weightless and slack"),
        # below the band: the net-buoyant rejection
        (1.0 - 2.0e-6, "0.0", r"net-buoyant \(dry mass <="),
        # above the displaced mass the gate admits the type, as it always did
        (1.0 + 1.0e-7, "0.0", None),
        # a dynamic finite-EI type is admitted on either side of the displaced mass
        (1.0 - 1.0e-7, "1.0e4", None),
        (1.0 + 1.0e-7, "1.0e4", None),
    ],
)
def test_neutral_buoyancy_band_keeps_the_rejection_rule(tmp_path, scale, ei, message):
    # The gate rejects mass <= displaced mass, unchanged; only the wording of an EI=0 type
    # within a relative 1e-6 below the displaced mass says it is weightless.
    mass = 1025.0 * math.pi / 4.0 * 0.2466**2 * scale
    replacements = [
        (
            "0.2466   373.5          1.607e9    -1.0       0.0 ",
            f"0.2466   {mass:.9f}          1.607e9    -1.0       {ei} ",
        )
    ]
    if ei != "0.0":
        replacements.append((_OPTIONS_HEADER, _OPTIONS_HEADER + "0.1 dtM\n1.0 TMax\n"))
    path = _chain_variant(tmp_path, *replacements)
    if message is None:
        DeckFile.read(path)
        return
    with pytest.raises(DeckFormatError, match=message) as caught:
        DeckFile.read(path)
    if "dry mass <=" in message:
        assert "weightless" not in str(caught.value)


@pytest.mark.parametrize(("weight", "buoyant"), [("100.0", False), ("-100.0", True)])
def test_net_buoyancy_uses_the_equivalent_buoyancy_conversion(tmp_path, weight, buoyant):
    section = (
        "--------------------- EQUIVALENT BUOYANCY ---\n"
        "LineType Diam SubmergedWeight\n"
        f"chainR3 0.3 {weight}\n"
    )
    path = _chain_variant(tmp_path, (_OPTIONS_HEADER, section + _OPTIONS_HEADER))
    if buoyant:
        with pytest.raises(DeckFormatError, match="net-buoyant"):
            DeckFile.read(path)
    else:
        DeckFile.read(path)


@pytest.mark.parametrize("point_type", ["T1", "Turbine1", "turbine2", "T01"])
def test_turbine_points_are_accepted_only_on_the_caller_driven_route(tmp_path, point_type):
    path = _chain_variant(tmp_path, ("2     Coupled   0.0", f"2     {point_type}   0.0"))
    with pytest.raises(DeckFormatError, match="CompMooring=5"):
        DeckFile.read(path)
    assert DeckFile.read(path, caller_driven=True).points[1].tokens[1] == point_type


@pytest.mark.parametrize("point_type", ["T0", "Turbine0", "TurbineX", "Turbine99999999999"])
def test_turbine_points_need_a_positive_32_bit_number(tmp_path, point_type):
    path = _chain_variant(tmp_path, ("2     Coupled   0.0", f"2     {point_type}   0.0"))
    with pytest.raises(DeckFormatError, match="positive 32-bit turbine number"):
        DeckFile.read(path, caller_driven=True)


def _mixed_stock_source(sections_first):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("1     2       1       -", "1 chainR3 2 1 275.0 25 -")
    source = source.replace("1        chainR3    550.0    55", "1        chainR3    275.0    30")
    if sections_first:
        lines_start = source.index("--------------------- LINES")
        sections_start = source.index("--------------------- SECTIONS")
        options_start = source.index("--------------------- OPTIONS")
        source = (
            source[:lines_start]
            + source[sections_start:options_start]
            + source[lines_start:sections_start]
            + source[options_start:]
        )
    return source


@pytest.mark.parametrize("sections_first", [False, True])
def test_stock_line_row_combined_with_sections_is_rejected_like_native(
    tmp_path,
    sections_first,
):
    path = tmp_path / "mixed.dat"
    path.write_text(_mixed_stock_source(sections_first), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="LINE 1 is defined by a 7-column LINES row"):
        DeckFile.read(path)


def test_stock_line_row_is_the_single_section_occurrence(tmp_path):
    source = _mixed_stock_source(False)
    start = source.index("--------------------- SECTIONS")
    stop = source.index("--------------------- OPTIONS")
    path = tmp_path / "stock.dat"
    path.write_text(source[:start] + source[stop:], encoding="utf-8")
    deck = DeckFile.read(path)
    deck.set_section(1, 1, numsegs=41)
    assert deck.lines[0].tokens[5] == "41"
    with pytest.raises(KeyError, match="occurrence 2"):
        deck.set_section(1, 2, numsegs=5)


# ---------------------------------------------------------------------------
# Table validation contracts
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("0 g", "OPTION g must be positive"),
        ("1.5 rhoInf", "OPTION rhoInf must be <= 1"),
        ("abc recovery_max_substeps", "must be an integer in [4, 65536]"),
        ("abc axial_quadrature_order", "must be an integer in [1, 6]"),
        ("inf bending_quadrature_order", "must be an integer in [1, 6]"),
        ("5 current", "OPTION current requires a supported positional mode"),
        ("abc currents", "OPTION currents must be numeric"),
        ("1e WaterKin", "requires 0/none, SEASTATE, or a filename"),
        ("dynamic_solver 0 1e-14 30 12", "dynamic_solver needs positive finite tolerances"),
        ("uniform inf 0 0 current", "positional option values must be finite plain numbers"),
        ("airy 2 x 0 waves", "positional option values must be finite plain numbers"),
    ],
)
def test_invalid_option_rows_fail_closed(row, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(_DYNAMIC, ("9.80665 g\n", f"9.80665 g\n{row}\n")))


def test_active_friction_requires_a_seabed():
    text = _edit(_DYNAMIC, ("50.0 WtrDpth\n", "0.5 frictionMu\n"))
    with pytest.raises(DeckFormatError, match="frictionMu requires WtrDpth or bathymetryFile"):
        DeckFile.from_text(text)


@pytest.mark.parametrize(
    ("row", "message"),
    [
        (
            "chain 0.252 390.0 SYROPE:rope.dat|1.5e8 5e10|1e5 0.0 1.37 0.64 1.0 0.0",
            "Syrope EA needs SYROPE:<file>|alpha|beta",
        ),
        (
            "chain 0.252 390.0 SYROPE:rope.dat|1.5e8|23 5e10 0.0 1.37 0.64 1.0 0.0",
            "Syrope BA needs BA_s|BA_d",
        ),
        (
            "chain 0.252 390.0 1e9|2e9|3|4 -1.0 0.0 1.37 0.64 1.0 0.0",
            "EA accepts one to three values",
        ),
        (
            "chain 0.252 390.0 1e9|0|1 -1.0 0.0 1.37 0.64 1.0 0.0",
            "load-dependent alphaMBL/vbeta must be positive",
        ),
        (
            "chain 0.252 390.0 1.674e9 -1.0|0 0.0 1.37 0.64 1.0 0.0",
            "BA has too many bar-separated values",
        ),
        (
            "chain 0.252 390.0 1e9|2e9 -1.0 1.0e4 1.37 0.64 1.0 0.0",
            "viscoelastic stiffness is not supported with EI > 0",
        ),
        (
            "chain 0.252 390.0 SYROPE:rope.dat|1.5e8|23 5e10|1e5 1.0e4 1.37 0.64 1.0 0.0",
            "Syrope is not supported with EI > 0",
        ),
        (
            "chain 0.252 390.0 1.674e9 -1.0 1e4 1e9 0 1 1 1.37 0.64 1.0 0.0",
            "explicit GAs/GJ/Irt/Irn must all be positive",
        ),
        (
            "chain 0.252 390.0 0.0 -1.0 0.0 1.37 0.64 1.0 0.0",
            "used LINE TYPE 'chain' requires EA > 0",
        ),
        (f"{_CHAIN}\n{_CHAIN}", "duplicate line type identifier"),
    ],
)
def test_line_type_constitutive_contracts(row, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(_DYNAMIC, (_CHAIN.replace(" 0.0 1.37", " 1.0e4 1.37"), row)))


def test_fourteen_column_row_under_stock_hydro_header_fails_closed():
    text = _edit(
        _STATIC,
        ("Name Diam Mass EA BA EI Cdn Cdt Can Cat", "Name Diam Mass EA BA EI Cd Ca CdAx CaAx"),
        (_CHAIN, "chain 0.252 390.0 1.674e9 -1.0 0.0 0 0 0 0 1.37 0.64 1.0 0.0"),
    )
    with pytest.raises(DeckFormatError, match="require CableDyn hydro-column order"):
        DeckFile.from_text(text)


@pytest.mark.parametrize(
    ("edits", "message"),
    [
        (
            ((_ANCHOR, f"{_ANCHOR}\n3 Connect 0 0 -10 -5 0 0 0"),),
            "Connect/Free POINT loads must be non-negative",
        ),
        (
            ((_ANCHOR, f"{_ANCHOR}\n3 Body1 0 0 -10 5 0 0 0"),),
            "Body/Rod POINT must not carry Mass/Vol/CdA/Ca",
        ),
        (((_ANCHOR, "0 Fixed 400.0 0.0 -50.0 0 0 0 0"),), "point id must be positive"),
        (((_FAIRLEAD, f"{_FAIRLEAD}\n01 Fixed 1 0 -50 0 0 0 0"),), "duplicate point identifier"),
        (((_ANCHOR, "1 Coupled 400.0 0.0 -50.0 0 0 0 0"),), "static LINE End B must be Fixed"),
        ((("1 2 1 -", "1 2 9 -"),), "line references missing point 9"),
        ((("1 2 1 -", "1 steel 2 1 410.0 41 -"),), "line references missing line type steel"),
        ((("1 2 1 -", "1 chain 2 1 abc 41 -"),), "stock line length/NumSegs is invalid"),
        ((("1 chain 410.0 41", "x chain 410.0 41"),), "section line id must be an integer"),
        ((("1 chain 410.0 41", "7 chain 410.0 41"),), "section references missing line 7"),
        ((("1 2 1 -", "1 2 1 -\n2 2 1 -"),), "lines without SECTIONS rows: 2"),
        ((("FairTen1", "Ten9N1"),), "OUTPUT 'Ten9N1' references an unknown line"),
    ],
)
def test_point_line_and_section_references(edits, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(_STATIC, *edits))


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 A 2.0e4 0 0", "END CONNECTIONS row needs 6 columns"),
        ("x A 2.0e4 0 0 -1", "END CONNECTIONS LineID must be an integer"),
        ("0 A 2.0e4 0 0 -1", "END CONNECTIONS LineID must be positive"),
    ],
)
def test_end_connection_row_shape(row, message):
    text = _with_section(_DYNAMIC, "END CONNECTIONS", _END_HEADER, row)
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(text)


def test_pinned_end_connection_is_accepted_even_on_an_ei0_line():
    deck = DeckFile.from_text(
        _with_section(_STATIC, "END CONNECTIONS", _END_HEADER, "1 A Pinned 0 0 -1")
    )
    assert deck.end_connections[0].tokens == ("1", "A", "Pinned", "0", "0", "-1")
    with pytest.raises(DeckFormatError, match="requires a finite-EI line"):
        deck.set_end_connection(1, "A", stiffness=2.0e4)
    assert deck.end_connections[0].tokens[2] == "Pinned"


_ROD_TYPE = "spar     1.0     300.0    0.8    1.0    0.0    0.0    0.2    0.0"
_ROD_TYPE_HEADER = "Name     Diam    Mass     Cd     Ca     CdEnd  CaEnd  CdAx   CaAx"
_ROD = "1    spar      Free   0.0   0.0   -30.0   0.0   0.0   -20.0   1         p"
_BODY = (
    "1   Rigid6  0.0  0.0  -20.0  0.0   0.0    0.0   2.0e4   40.0  0.0  0.0  0.0  8.0   0.5"
    "  3.5e4   3.5e4   3.5e4"
)


@pytest.mark.parametrize(
    ("deck", "edit", "message"),
    [
        (
            "rod_moored_spar.dat",
            (_ROD_TYPE, "spar 1.0 300.0 0.8 1.0 0.2"),
            "ROD TYPES row needs 7 or 9 fields",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD_TYPE, "spar 1.0 300.0 0.8 1.0 0.0 0.0 0.2"),
            "ROD TYPES row needs 7 or 9 fields",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD_TYPE_HEADER, "Name Diam Mass Cd Ca CdAx CaAx"),
            "ROD TYPES header names axial coefficients (CdAx CaAx) in columns 6-7",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD_TYPE, "spar 1.0 300.0 0.8 1.0 0.0 0.0 -0.2 0.0"),
            "ROD TYPE requires Diam/Mass > 0",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD_TYPE, "spar 0 300.0 0.8 1.0 0.2 0.0"),
            "ROD TYPE requires Diam/Mass > 0",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD, "1 spar Free 0 0 -30 0 0 -20"),
            "RODS row needs 10 or 11 fields",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD, "1 pole Free 0 0 -30 0 0 -20 1 p"),
            "rod references missing rod type pole",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD, "1 spar Free 0 0 -30 0 0 -20 1.5 p"),
            "rod NumSegs must be an integer",
        ),
        (
            "rod_moored_spar.dat",
            (_ROD, "1 spar Free 0 0 -30 0 0 -20 -1 p"),
            "rod NumSegs must be 0 or positive",
        ),
        (
            "rod_moored_spar.dat",
            ("2     Rod1B", "2     Rod2B"),
            "POINT type references an undefined ROD",
        ),
        (
            "rigid6_buoy.dat",
            ("1     Body1     1.5", "1     Body2     1.5"),
            "POINT type references an undefined BODY",
        ),
        (
            "rigid6_buoy.dat",
            (_BODY, _BODY.replace("Rigid6", "Point3").rsplit("  3.5e4", 3)[0]),
            "Point3 BODY 1 requires exactly one Body<N> POINT",
        ),
    ],
)
def test_body_and_rod_tables(deck, edit, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_example(deck, edit))


_MD_BODY = "1 Free 0 0 -20 0 0 0 2.0e4 0|0|-0.5 3.5e4 40 8|0 0.5"


@pytest.mark.parametrize(
    ("channel", "ok"),
    [("Point2Fx", True), ("Point2FH", True), ("point2fz", True), ("Point9Fx", False)],
)
def test_point_force_channels(channel, ok):
    text = _example("rigid6_buoy.dat", ('"FairTen1"', f'"FairTen1"\n"{channel}"'))
    if ok:
        DeckFile.from_text(text)
    else:
        with pytest.raises(DeckFormatError, match="unknown point"):
            DeckFile.from_text(text)


@pytest.mark.parametrize(
    "row",
    [
        _MD_BODY,
        "1 free 0 0 -20 0 0 0 2.0e4 -0.5 3.5e4|3.5e4|3.0e4 40 8|8|8 0.5|0.5|0.5",
        "1 Free 0 0 -20 0 0 0 2.0e4 0 3.5e4 40 8|8|8|0|0|0 0.5",
    ],
)
def test_moordyn_body_rows_are_accepted(row):
    DeckFile.from_text(_example("rigid6_buoy.dat", (_BODY, row)))


@pytest.mark.parametrize(
    ("row", "message"),
    [
        (_MD_BODY.replace("Free", "Fixed"), "Free, Coupled, Vessel, CoupledPinned or VesselPinned"),
        (_MD_BODY.replace("Free", "Coupled"), "Coupled/Vessel BODY requires a motionFile"),
        (_MD_BODY.replace("0|0|-0.5", "0|-0.5"), "BODIES CG has 2 entries"),
        (_MD_BODY.replace("8|0", "8|1"), "isotropic without rotational drag"),
        (_MD_BODY.replace("8|0", "8|7|8"), "isotropic without rotational drag"),
        (_MD_BODY.replace(" 0.5", " 0.5|0.4|0.5"), "BODIES Ca must be isotropic"),
        (_MD_BODY.replace("2.0e4", "0"), "BODY requires Mass > 0"),
        (_MD_BODY.replace("3.5e4", "0"), "inertias must be positive"),
    ],
)
def test_moordyn_body_rows_fail_closed(row, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_example("rigid6_buoy.dat", (_BODY, row)))


@pytest.mark.parametrize(
    ("option", "ok"),
    [
        ("moordyn bodyWetting", True),
        ("sphere bodyWetting", True),
        ("cube bodyWetting", False),
        ("moordyn bodyHydro", True),
        ("morison bodyHydro", True),
        ("none bodyHydro", False),
    ],
)
def test_body_hydro_options(option, ok):
    heading = "--------------------- OPTIONS ------------------------------------------\n"
    text = _example("rigid6_buoy.dat", (heading, heading + option + "\n"))
    if ok:
        DeckFile.from_text(text)
    else:
        with pytest.raises(DeckFormatError, match="must be"):
            DeckFile.from_text(text)


@pytest.mark.parametrize(
    "edits",
    [
        # MoorDyn header and 7-column row: columns 6-7 are CdEnd CaEnd.
        (
            (_ROD_TYPE_HEADER, "Name Diam Mass Cd Ca CdEnd CaEnd"),
            (_ROD_TYPE, "spar 1.0 300.0 0.8 1.0 0.6 0.6"),
        ),
        # No recognisable name in columns 6-7: MoorDyn meaning.
        ((_ROD_TYPE_HEADER, "Name Diam Mass"), (_ROD_TYPE, "spar 1.0 300.0 0.8 1.0 0.6 0.6")),
        # A later MoorDyn header clears a legacy one.
        (
            (
                _ROD_TYPE_HEADER,
                "Name Diam Mass Cd Ca CdAx CaAx\nName Diam Mass Cd Ca CdEnd CaEnd",
            ),
            (_ROD_TYPE, "spar 1.0 300.0 0.8 1.0 0.6 0.6"),
        ),
    ],
)
def test_rod_types_moordyn_end_columns(edits):
    deck = DeckFile.from_text(_example("rod_moored_spar.dat", *edits))
    assert len(deck.points) > 0


@pytest.mark.parametrize(
    ("name", "attachment"),
    [
        ("rod_moored_spar.dat", "rod"),
        ("rigid6_buoy.dat", "body"),
    ],
)
def test_body_and_rod_examples_round_trip_with_their_attachment_points(name, attachment):
    path = ROOT / "examples" / name
    deck = DeckFile.read(path)
    assert deck.text() == path.read_text(encoding="utf-8")
    assert any(row.tokens[1].lower().startswith(attachment) for row in deck.points)


def test_equivalent_buoyancy_row_width():
    text = _with_section(_STATIC, "EQUIVALENT BUOYANCY", "LineType Diam SubWeight", "chain 0.3")
    with pytest.raises(DeckFormatError, match="EQUIVALENT BUOYANCY row needs 3 fields"):
        DeckFile.from_text(text)


_SYROPE_IC = "1       2.0e6   1.5e6"


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 2.0e6", "SYROPE IC row needs Line(s), Tmax0, Tmean0"),
        ("99999999999 2.0e6 1.5e6", "SYROPE IC line list must contain integers"),
        ("1 1.0e6 1.5e6", "SYROPE IC needs Tmax0 >= Tmean0 >= 0 and Tmax0 > 0"),
        ("1 0 0", "SYROPE IC needs Tmax0 >= Tmean0 >= 0 and Tmax0 > 0"),
        (f"{_SYROPE_IC}\n{_SYROPE_IC}", "duplicate SYROPE IC line assignment"),
    ],
)
def test_syrope_ic_rows(row, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_example("syrope_polyester_mooring.dat", (_SYROPE_IC, row)))


_FAILURE_HEADER = "ID Point Lines FailTime FailTen"


def test_failure_rows_accept_plain_and_p_prefixed_points():
    text = _with_section(_TIMED, "FAILURE", _FAILURE_HEADER, "1 1 1 10.0 0", "2 p2 1 0 5.0e5")
    assert DeckFile.from_text(text).text() == text


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 1 1 10.0", "FAILURE row needs 5 fields"),
        ("1 r1 1 10.0 0", "malformed FAILURE identifiers"),
        ("1 1 1,x 10.0 0", "malformed FAILURE identifiers"),
        ("2 1 1 10.0 0", "FAILURE IDs must be sequential and reference a point"),
        ("1 9 1 10.0 0", "FAILURE IDs must be sequential and reference a point"),
        ("1 1 1 0 0", "FAILURE needs FailTime > 0 or FailTen > 0"),
        ("1 1 5 10.0 0", "FAILURE line must exist and attach to its point"),
    ],
)
def test_failure_rows_fail_closed(row, message):
    text = _with_section(_TIMED, "FAILURE", _FAILURE_HEADER, row)
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(text)


def test_control_rows_accept_repeated_assignment_to_one_channel():
    text = _with_section(_STATIC, "CONTROL", "Channel Lines", "1 1", "1 1")
    assert DeckFile.from_text(text).text() == text


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        (("1 1 2",), "CONTROL row needs 2 fields"),
        (("x 1",), "malformed CONTROL identifiers"),
        (("1 1", "2 1"), "line assigned to multiple CONTROL channels"),
    ],
)
def test_control_rows_fail_closed(rows, message):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(_with_section(_STATIC, "CONTROL", "Channel Lines", *rows))


def test_control_rows_may_name_finite_ei_cables_on_the_coupled_route():
    # native CD_Init_Deck_Aggregate controls the fairlead-side segment of a finite-EI cable
    # too, alone or on one channel with EI = 0 lines (line 4 is the mixed deck's cable)
    marker = "--------------------------- OPTIONS"
    block = (
        "--------------------------- CONTROL -------------------------------------------\n"
        "ChannelID Lines\n(-) (-)\n1 4\n2 1,3\n"
    )
    text = (ROOT / "examples/iea15mw_umaine_mixed_cabledyn.dat").read_text(encoding="utf-8")
    deck = DeckFile.from_text(text.replace(marker, block + marker, 1), caller_driven=True)
    assert [row.tokens for row in deck._rows("CONTROL")] == [("1", "4"), ("2", "1,3")]


@pytest.mark.parametrize(
    "example", ["syrope_polyester_mooring.dat", "ve_polyester_catenary_mooring.dat"]
)
def test_control_rows_may_name_syrope_and_viscoelastic_lines_on_the_coupled_route(example):
    # native CD_Init_Deck_Aggregate controls a Syrope or viscoelastic segment too (its slow
    # stretch carries over the length change, as in MoorDyn-F/C), so the mirror accepts the row
    source = (ROOT / "examples" / example).read_text(encoding="utf-8")
    marker = "--------------------- OPTIONS"
    assert source.count(marker) == 1
    block = (
        "--------------------- CONTROL ----------------------------------------\n"
        "ChannelID Lines\n(-) (-)\n1 1\n"
    )
    deck = DeckFile.from_text(source.replace(marker, block + marker, 1), caller_driven=True)
    assert [row.tokens for row in deck._rows("CONTROL")] == [("1", "1")]


# ---------------------------------------------------------------------------
# Editing API error contract
# ---------------------------------------------------------------------------


def test_editing_error_types_follow_the_documented_contract():
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(KeyError, match="unknown field"):
        deck.apply("point.2.q", 1.0)
    with pytest.raises(KeyError, match="point 9 does not exist"):
        deck.apply("point.9.z", 1.0)
    with pytest.raises(KeyError, match="option 'dtM' is not in"):
        deck.apply("option.dtM", 0.1)
    with pytest.raises(ValueError, match="point id must be an integer, got 'x'"):
        deck.apply("point.x.z", 1.0)
    with pytest.raises(ValueError, match="section occurrence must be an integer"):
        deck.apply("section.1.first.length", 1.0)
    with pytest.raises(ValueError, match="unsupported deck selector"):
        deck.apply("points.2.z", 1.0)
    assert deck.text() == before

    short = DeckFile.from_text(before.replace(_ANCHOR_ROW, "1 Fixed 500.0 0.0 -100.0"))
    with pytest.raises(KeyError, match="has no mass column"):
        short.set_point(1, mass=1.0)


def test_duplicate_selectors_for_one_field_or_option_are_rejected():
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    before = deck.text()
    with pytest.raises(ValueError, match="address the same deck field"):
        deck.apply_many({"point.2.z": -15.0, "Point.2.Z": -16.0})
    with pytest.raises(ValueError, match="address the same deck field"):
        deck.apply_many({"line_type.chainR3.ea": 1.0e9, "line_type.CHAINR3.EA": 2.0e9})
    with pytest.raises(ValueError, match="address the same option"):
        deck.apply_many({"option.g": 9.8, "option.gravity": 9.81})
    assert deck.text() == before


def test_errors_after_an_edit_name_the_edited_copy(tmp_path):
    deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
    with pytest.raises(DeckFormatError, match=r"^edited copy of .*chain_catenary_r3_100m\.dat:18:"):
        deck.set_point(2, z=-200.0)
    with pytest.raises(DeckFormatError) as unedited:
        DeckFile.read(_chain_variant(tmp_path, ("0.2466   373.5 ", "0.2466   x ")))
    assert not str(unedited.value).startswith("edited copy")


def test_written_files_get_default_new_file_permissions(tmp_path, monkeypatch):
    import cabledyn.deck_file as deck_file

    modes: list[int] = []
    real_chmod = deck_file.os.chmod

    def recording_chmod(path, mode):
        modes.append(mode)
        real_chmod(path, mode)

    monkeypatch.setattr(deck_file.os, "chmod", recording_chmod)
    previous = os.umask(0o022)
    effective = os.umask(0o022)  # the platform may keep only some umask bits
    expected = 0o666 & ~effective
    try:
        deck = DeckFile.read(ROOT / "examples/chain_catenary_r3_100m.dat")
        target = deck.write(tmp_path / "written.dat")
        generate_deck_cases(target, tmp_path / "cases", {"a": {"option.WtrDpth": 190.0}})
    finally:
        os.umask(previous)
    assert modes == [expected, expected, expected]
    if os.name != "nt":
        assert target.stat().st_mode & 0o777 == expected
        assert (tmp_path / "cases" / "cases.json").stat().st_mode & 0o777 == expected


def test_set_end_connection_edits_the_selected_row_only():
    deck = DeckFile.from_text(
        _with_section(_DYNAMIC, "END CONNECTIONS", _END_HEADER, "1 EndA 2.0e4 0 0 -1   # hang-off")
    )
    deck.set_end_connection("1", "a", stiffness="Rigid", ezx=-0.5)
    assert deck.end_connections[0].tokens == ("1", "EndA", "Rigid", "-0.5", "0", "-1")
    assert deck.text().count("1 EndA Rigid -0.5 0 -1   # hang-off\n") == 1
    with pytest.raises(KeyError, match="End B connection does not exist"):
        deck.set_end_connection(1, "B", stiffness=0.0)
    with pytest.raises(KeyError, match="End B connection does not exist"):
        deck.apply("end_connection.1.B.stiffness", 0.0)


def test_boolean_option_edit_renders_native_boolean():
    deck = DeckFile.from_text(
        _edit(_STATIC, ("50.0 WtrDpth\n", "50.0 WtrDpth\nFalse modified_newton\n"))
    )
    deck.set_option("modified_newton", True)
    assert deck.option("modified_newton").values == ("True",)
    assert "True modified_newton\n" in deck.text()


@pytest.mark.parametrize(
    ("call", "exception", "message"),
    [
        (lambda deck: deck.set_point(2, x=""), ValueError, "must not be empty"),
        (lambda deck: deck.set_point(True, z=1.0), ValueError, "point id must be an integer"),
        (lambda deck: deck.set_point(1.5, z=1.0), ValueError, "point id must be an integer"),
        (lambda deck: deck.apply(123, 1.0), ValueError, "selectors must be strings"),
        (lambda deck: deck.apply("line_type.chain", 1.0), ValueError, "unsupported deck selector"),
        (lambda deck: deck.apply("line_type..diam", 1.0), ValueError, "unsupported deck selector"),
        (lambda deck: deck.set_option("g", (1.0, 2.0)), ValueError, "accepts one value"),
        (lambda deck: deck.set_line_type("wire", diam=0.1), KeyError, "line type 'wire' does not"),
        (
            lambda deck: deck.set_end_connection(1, "A", ezx=1.0),
            KeyError,
            "End A connection does not exist",
        ),
    ],
)
def test_editor_argument_errors_leave_the_deck_unchanged(call, exception, message):
    deck = DeckFile.from_text(_STATIC)
    before = deck.text()
    with pytest.raises(exception, match=message):
        call(deck)
    assert deck.text() == before


def test_positional_wave_edit_keeps_scalar_commentary_as_description():
    deck = DeckFile.from_text(_edit(_DYNAMIC, ("10.0 TMax\n", "10.0 TMax\nnone waves old prose\n")))
    assert deck.option("waves").trailing == ("old", "prose")
    deck.set_option("waves", ("airy", 2.0, 8.0, 0.0))
    record = deck.option("waves")
    assert record.values == ("airy", "2", "8", "0")
    assert record.description == "old prose"
    assert "airy 2 8 0 waves - old prose\n" in deck.text()


@pytest.mark.parametrize(
    "ea",
    [
        "SYROPE:data/other/settings.dat|1.6e8|23.12",  # quoted for its list-directed '/'
        "SYROPE:settings.dat|1.6e8|23.12",  # quoted because it is a Syrope settings path
    ],
)
def test_syrope_ea_edit_is_quoted_for_list_directed_input(ea):
    deck = DeckFile.read(ROOT / "examples/syrope_polyester_mooring.dat")
    deck.set_line_type("rope", ea=ea)
    assert f' "{ea}" ' in deck.text()
    assert deck.line_types[0].tokens[3] == ea
    assert deck.line_types[0].quoted[3] is True


# ---------------------------------------------------------------------------
# Writing and case generation
# ---------------------------------------------------------------------------


def test_write_refuses_to_replace_without_overwrite(tmp_path):
    deck = DeckFile.from_text(_STATIC)
    target = deck.write(tmp_path / "deck.dat")
    deck.set_point(2, z=-1.0)
    with pytest.raises(FileExistsError, match="deck already exists"):
        deck.write(target)
    assert target.read_text(encoding="utf-8") == _STATIC
    deck.write(target, overwrite=True)
    assert DeckFile.read(target).points[1].tokens[4] == "-1"


def test_failed_atomic_write_removes_its_temporary_file(tmp_path, monkeypatch):
    deck = DeckFile.from_text(_STATIC)

    def refuse(source, destination):
        raise OSError("simulated rename failure")

    monkeypatch.setattr(os, "replace", refuse)
    with pytest.raises(OSError, match="simulated rename failure"):
        deck.write(tmp_path / "deck.dat")
    assert list(tmp_path.iterdir()) == []


def test_case_generation_keeps_seastate_waterkin_selector(tmp_path):
    base = tmp_path / "base.dat"
    base.write_text(
        _edit(_STATIC, ("50.0 WtrDpth\n", "50.0 WtrDpth\nSEASTATE WaterKin\n")), encoding="utf-8"
    )
    (case,) = generate_deck_cases(base, tmp_path / "out", {"g981": {"option.g": 9.81}})
    generated = DeckFile.read(case.deck)
    assert generated.option("WaterKin").values == ("SEASTATE",)
    assert float(generated.option("g").values[0]) == 9.81


def test_case_generation_falls_back_to_absolute_path_across_drives(tmp_path, monkeypatch):
    base = tmp_path / "base.dat"
    base.write_text(
        _edit(_DYNAMIC, ("10.0 TMax\n", "10.0 TMax\nmotion.txt motionFile\n")), encoding="utf-8"
    )

    def no_relative_path(path, start=None):
        raise ValueError("path is on mount 'C:', start on mount 'D:'")

    monkeypatch.setattr(os.path, "relpath", no_relative_path)
    (case,) = generate_deck_cases(base, tmp_path / "out", {"moved": {"option.g": 9.81}})
    monkeypatch.undo()
    assert DeckFile.read(case.deck).option("motionFile").values == (
        (tmp_path / "motion.txt").resolve().as_posix(),
    )


def test_case_generation_tolerates_unqueryable_existing_outputs(tmp_path, monkeypatch):
    base = tmp_path / "base.dat"
    base.write_text(_STATIC, encoding="utf-8")
    output = tmp_path / "out"
    output.mkdir()
    (output / "case1.dat").write_text("stale", encoding="utf-8")

    def unqueryable(first, second):
        raise OSError("stat failed")

    monkeypatch.setattr(os.path, "samefile", unqueryable)
    with pytest.raises(FileExistsError, match="already exist"):
        generate_deck_cases(base, output, {"case1": {"option.g": 9.81}})
    (case,) = generate_deck_cases(base, output, {"case1": {"option.g": 9.81}}, overwrite=True)
    assert float(DeckFile.read(case.deck).option("g").values[0]) == 9.81


# ---------------------------------------------------------------------------
# Native duplicate-channel identity, anchor-below-seabed, and endpoint order
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("first", "second"),
    [
        ("FairTen1", "fairten01"),
        ("AnchTen2", "ANCHTEN2"),
        ("FairIncl1", "fairincl01"),
        ("FairAngle1", "FairDecl1"),
        ("AnchDecl1", "anchangle01"),
        ("Con2pz", "Point2pz"),
        ("Point02px", "point2PX"),
        ("Ten1N3", "ten01n03"),
        ("Curv1N2", "CURV1n2"),
        ("BendMom1N2", "bendmom1N02"),
        ("L1N3px", "l01n3PX"),
        ("L1N3Dec", "L1N03dec"),
        ("L1N3Azi", "l1n3azi"),
        ("L1N3va", "L1N3va"),
        ("TDP1s", "tdp01S"),
        ("TDP1Lay", "TDP1LAY"),
        ("TDP1Grd", "tdp01GRD"),
        ("AnchFz1", "anchfz01"),
        ("AnchFH1", "ANCHFH1"),
    ],
)
def test_duplicate_output_channels_fail_like_native(first, second):
    text = _edit(_STATIC, ("FairTen1\n", f"{first}\n{second}\n"))
    line_number = text.splitlines().index(first) + 2
    with pytest.raises(
        DeckFormatError,
        match=re.escape(
            f"<in-memory deck>:{line_number}: OUTPUTS channel {second!r} duplicates the "
            f"earlier channel {first!r}",
        ),
    ):
        DeckFile.from_text(text)


def test_duplicate_output_channel_on_one_row_and_across_sections_fails():
    with pytest.raises(DeckFormatError, match="'FairTen1' duplicates"):
        DeckFile.from_text(_edit(_STATIC, ("FairTen1\n", "FairTen1, 'FairTen1'\n")))
    repeated = _edit(_STATIC, ("FairTen1\n", f"FairTen1\n{_BAR} OUTPUTS {_BAR}\nFAIRTEN1\n"))
    with pytest.raises(DeckFormatError, match="'FAIRTEN1' duplicates the earlier channel"):
        DeckFile.from_text(repeated)


def test_distinct_output_channels_are_not_collapsed():
    channels = (
        "FairTen1 AnchTen1 AnchFz1 AnchFH1 FairIncl1 AnchIncl1 FairDecl1 AnchDecl1 Point1px "
        "Point1py Point2px Ten1N1 Ten1N2 Curv1N1 BendMom1N1 L1N1px L1N1vx L1N1ax L1N1Dec L1N1Azi"
    )
    deck = DeckFile.from_text(_edit(_STATIC, ("FairTen1\n", channels + "\n")))
    assert deck.outputs == tuple(channels.split())


@pytest.mark.parametrize(
    ("channel", "key"),
    [
        ("FairTen01", "fairten:1"),
        ("FairTen0", "fairten0"),
        ("AnchTen", "anchten"),
        ("FairAngle01", "fairdecl:1"),
        ("AnchDecl2", "anchdecl:2"),
        ("AnchIncl3", "anchincl:3"),
        ("FairInclX", "fairinclx"),
        ("Con2pz", "point:2:3"),
        ("Point2pw", "point2pw"),
        ("Pointpx", "pointpx"),
        ("Point2px_raw", "point2px_raw"),
        ("Point0px", "point0px"),
        ("Con", "con"),
        ("Ten1N3", "node:1:3:3:0"),
        ("Ten", "ten"),
        ("TenX", "tenx"),
        ("Ten1N", "ten1n"),
        ("Ten0N1", "ten0n1"),
        ("Curv1N2", "node:1:2:5:0"),
        ("BendMom1N2", "node:1:2:6:0"),
        ("L1N3px", "node:1:3:1:1"),
        ("L1N3vy", "node:1:3:2:2"),
        ("L1N3az", "node:1:3:4:3"),
        ("L1N3pw", "l1n3pw"),
        ("L1N3qx", "l1n3qx"),
        ("L1N3Dec", "node:1:3:7:0"),
        ("L1N3Azi", "node:1:3:8:0"),
        ("L0N3Dec", "l0n3dec"),
        ("L0N3px", "l0n3px"),
        ("TDP01Lay", "tdp:1:5"),
        ("TDP2s", "tdp:2:1"),
        ("TDP0s", "tdp0s"),
        ("TDP1", "tdp1"),
        ("TDP3Grd", "tdp:3:7"),
        ("AnchFz01", "anchfz:1"),
        ("AnchFH2", "anchfh:2"),
        ("AnchFz", "anchfz"),
        ("AnchFz0", "anchfz0"),
        ("Lxyz", "lxyz"),
        ("Other1", "other1"),
    ],
)
def test_channel_identity_key_mirrors_native(channel, key):
    from cabledyn.deck_file import _channel_identity_key

    assert _channel_identity_key(channel) == key


@pytest.mark.parametrize(
    ("depth", "anchor_z", "accepted"),
    [
        ("50.0", "-50.0", True),
        ("50.0", "-50.0009", True),  # within the 1 mm floor of max(1 mm, 1e-5 |z|)
        ("50.0", "-50.0011", False),
        ("200.0", "-200.0015", True),  # within 1e-5 * 200 m = 2 mm
        ("200.0", "-200.0021", False),
        ("0.5", "-0.501", True),  # exactly one tolerance off stays inside
        ("0.5", "-0.5011", False),
        ("49.0", "-50.0", False),
    ],
)
def test_fixed_point_below_flat_seabed_fails_like_native(depth, anchor_z, accepted):
    text = _edit(
        _STATIC,
        ("50.0 WtrDpth", f"{depth} WtrDpth"),
        (_ANCHOR, f"1 Fixed 400.0 0.0 {anchor_z} 0 0 0 0"),
    )
    if accepted:
        DeckFile.from_text(text)
        return
    with pytest.raises(
        DeckFormatError,
        match=re.escape(
            f"POINT 1 (Fixed) lies below the seabed: z = {float(anchor_z):.10g} m is under the "
            f"flat seabed z = -WtrDpth = {-float(depth):.10g} m by more than the",
        ),
    ):
        DeckFile.from_text(text)


def test_anchor_seabed_check_is_skipped_without_depth_and_on_host_route():
    deep = _edit(_STATIC, (_ANCHOR, "1 Fixed 400.0 0.0 -80.0 0 0 0 0"))
    with pytest.raises(DeckFormatError, match="lies below the seabed"):
        DeckFile.from_text(deep)
    # The host owns the effective depth of a caller-driven deck.
    DeckFile.from_text(deep, caller_driven=True)
    # No WtrDpth: the line solves suspended, whatever the anchor depth.
    DeckFile.from_text(_edit(deep, ("50.0 WtrDpth\n", "")))


def _free_leg_deck(fixed_z: str, free_z: str) -> str:
    """Finite-EI deck with a second line from a Fixed NodeA to a Free NodeB."""
    return _with_section(
        _edit(
            _DYNAMIC,
            (
                _FAIRLEAD,
                f"{_FAIRLEAD}\n3 Free 200.0 0.0 {free_z} 100 0 0 0\n"
                f"4 Fixed 200.0 0.0 {fixed_z} 0 0 0 0",
            ),
            ("1 2 1 -\n", "1 2 1 -\n2 4 3 -\n"),
            ("1 chain 410.0 41\n", "1 chain 410.0 41\n2 chain 20.0 4\n"),
        ),
        "END CONNECTIONS",
        _END_HEADER,
        "2 A Rigid 0.0 0.0 1.0",
    )


def test_stock_anchor_to_free_swap_needs_the_free_point_at_or_above_the_anchor():
    # Fixed NodeA at or below the Free NodeB: a stock anchor-first leg, swapped so the
    # Fixed anchor becomes End B and a bending connection is supported.
    DeckFile.from_text(_free_leg_deck("-50.0", "-30.0"))
    DeckFile.from_text(_free_leg_deck("-30.0", "-30.0"))
    # Fixed NodeA above the Free NodeB: an elevated hang-off already written upper end
    # first, so End B stays the Free point.
    with pytest.raises(DeckFormatError, match="need End B on a Fixed, Coupled or Vessel point"):
        DeckFile.from_text(_free_leg_deck("-10.0", "-30.0"))


def _chain_example() -> str:
    return (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")


def test_byte_order_mark_is_not_deck_text_and_round_trips(tmp_path):
    source = "﻿" + _chain_example()
    path = tmp_path / "bom.dat"
    path.write_bytes(source.encode("utf-8"))
    deck = DeckFile.read(path)
    assert deck.text() == source
    deck.set_point(1, z=-99.0)
    assert deck.write(tmp_path / "bom-edited.dat").read_bytes().startswith(b"\xef\xbb\xbf")
    # Line 1 is read without the mark: a section header there is recognized.
    headed = "﻿--------------------- LINE TYPES ---\n" + _chain_example().split("\n", 6)[6]
    assert DeckFile.from_text(headed).line_types[0].tokens[0] == "chainR3"


@pytest.mark.parametrize("blank", ["\t", " \t ", "\f", "\v", "\t\f\v "])
def test_ascii_whitespace_only_rows_are_blank(blank):
    text = _chain_example().replace("100.0        WtrDpth", f"{blank}\n100.0        WtrDpth", 1)
    assert DeckFile.from_text(text).option("WtrDpth").values == ("100.0",)


def test_vertical_tab_separates_tokens_like_native():
    text = _chain_example().replace("100.0        WtrDpth", "100.0\vWtrDpth", 1)
    assert DeckFile.from_text(text).option("WtrDpth").values == ("100.0",)


@pytest.mark.parametrize(
    ("character", "message"),
    [
        ("\x00", "NUL character"),
        (" ", "U+00A0"),
        ("　", "U+3000"),
        (" ", "U+2007"),
    ],
)
def test_nul_and_non_ascii_whitespace_outside_comments_fail_closed(character, message):
    in_row = _chain_example().replace("100.0        WtrDpth", f"100.0{character}WtrDpth", 1)
    with pytest.raises(DeckFormatError, match=rf":26: .*{re.escape(message)}"):
        DeckFile.from_text(in_row)
    before_header = _chain_example().replace(
        "--------------------- POINTS", f"{character}--------------------- POINTS", 1
    )
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(before_header)
    # Inside a comment the character is commentary.
    in_comment = _chain_example().replace(
        "100.0        WtrDpth", f"100.0        WtrDpth # note{character}", 1
    )
    DeckFile.from_text(in_comment)


def test_section_header_uses_the_whole_record():
    banner = "-" * 70 + " CableDyn Input File " + "-" * 10
    DeckFile.from_text(
        _chain_example().replace(
            "--------------------- CableDyn Input File ------------------------------------",
            banner,
            1,
        )
    )
    unknown = "-" * 20 + " " + "Z" * 80 + " ---"
    with pytest.raises(DeckFormatError, match="unknown deck section"):
        DeckFile.from_text(
            _chain_example().replace(
                "--------------------- CableDyn Input File ------------------------------------",
                unknown,
                1,
            )
        )
    # Section names match on ASCII letters only (no Unicode case mapping).
    dotless = "--- ınput file ---"
    with pytest.raises(DeckFormatError, match="unknown deck section"):
        DeckFile.from_text(
            _chain_example().replace(
                "--------------------- CableDyn Input File ------------------------------------",
                dotless,
                1,
            )
        )


def test_subnormal_dtm_is_rejected_before_the_step_count():
    text = _minimal_chain_source().replace(
        "100.0        WtrDpth", "100.0 WtrDpth\n5e-324 dtM\n30.0 TMax", 1
    )
    with pytest.raises(DeckFormatError, match="OPTION dtM value '5e-324' is subnormal"):
        DeckFile.from_text(text)


# (a dtM below 1e-100 s is refused before the step count: test_deck_native_parity)
@pytest.mark.parametrize("dtm", ["1e-90", "1e-12"])
def test_step_count_beyond_the_native_counter_is_a_format_error(dtm):
    text = _minimal_chain_source().replace(
        "100.0        WtrDpth", f"100.0 WtrDpth\n{dtm} dtM\n30.0 TMax", 1
    )
    with pytest.raises(DeckFormatError, match="needs more than 2147483646 time steps"):
        DeckFile.from_text(text)


def test_syrope_line_needs_the_dynamic_clock():
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    static = "\n".join(
        line for line in source.splitlines() if not re.match(r"\s*\S+\s+(dtM|TMax)\b", line)
    )
    with pytest.raises(DeckFormatError, match="Syrope line has no static output"):
        DeckFile.from_text(static)
    DeckFile.from_text(static, caller_driven=True)


def test_syrope_line_takes_viv_and_a_current():
    # a Syrope line takes the hydrodynamics of any EI = 0 line, VIV included (MoorDyn's)
    source = (ROOT / "examples/syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    row = '"SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"  5.0e10|1.0e5'
    row += "  0.0  1.0  0.0  1.0  0.0"
    assert source.count(row) == 1
    text = source.replace(row, row + "  0.8")
    DeckFile.from_text(re.sub(r"none(\s+)current", r"uniform 0 0.5 0\1current", text))


@pytest.mark.parametrize("column", [6, 7, 8, 9])
def test_negative_drag_or_added_mass_coefficient_is_rejected(column):
    row = "chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0"
    tokens = row.split()
    tokens[column] = "-0.5"
    with pytest.raises(DeckFormatError, match=r":9: LINE TYPES drag and added-mass"):
        DeckFile.from_text(_chain_example().replace(row, " ".join(tokens), 1))


def test_motion_file_is_rejected_on_the_connect_free_route():
    source = (ROOT / "examples/connect_weighted_point.dat").read_text(encoding="utf-8")
    with_motion = source.replace("2.0          TMax", "2.0          TMax\nmotion.txt motionFile", 1)
    with pytest.raises(DeckFormatError, match="Connect/Free dynamic-point deck"):
        DeckFile.from_text(with_motion)
    with pytest.raises(DeckFormatError, match="driven by the host, not a deck motionFile"):
        DeckFile.from_text(with_motion, caller_driven=True)
    failure = _with_section(
        _edit(_STATIC, ("50.0 WtrDpth\n", "50.0 WtrDpth\n0.1 dtM\n1.0 TMax\nm.txt motionFile\n")),
        "FAILURE",
        _FAILURE_HEADER,
        "1 1 1 10.0 0",
    )
    with pytest.raises(DeckFormatError, match="FAILURE deck does not support motionFile"):
        DeckFile.from_text(failure)


def test_every_shadowed_option_row_is_validated():
    # The native reader validates each row too, so a NaN hidden by a later row fails.
    text = _minimal_chain_source().replace("1025.0       rhoW", "NaN rhoW\n1025.0       rhoW", 1)
    with pytest.raises(DeckFormatError, match="rhoW must be finite"):
        DeckFile.from_text(text)


def test_reserved_windows_device_names_are_refused(monkeypatch, tmp_path):
    import functools

    from cabledyn import _paths, deck_file

    monkeypatch.setattr(
        deck_file,
        "windows_device_component",
        functools.partial(_paths.windows_device_component, windows=True),
    )
    with pytest.raises(DeckFormatError, match="reserved Windows device"):
        DeckFile.read("CON")
    with pytest.raises(DeckFormatError, match="reserved Windows device"):
        DeckFile.read(tmp_path / "aux.dat")
    deck = DeckFile.from_text(_chain_example())
    with pytest.raises(ValueError, match="reserved Windows device"):
        deck.write(tmp_path / "nul")


_TURBINE_DECK = (
    "title\n"
    "--------------------- LINE TYPES ---------------------------------------\n"
    "chain 0.1 20.0 1.0e9 -1.0 0.0 1.2 0.2 1.0 0.0\n"
    "--------------------- TURBINES ------------------------------------------\n"
    "J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw\n"
    "1 0 0 0 0 0 0 0 0 0\n"
    "2 600 0 0\n"
    "--------------------- POINTS -------------------------------------------\n"
    "1 Turbine1 0 0 -10 0 0 0 0\n"
    "2 Turbine2 0 0 -10 0 0 0 0\n"
    "3 Fixed 300 0 -100 0 0 0 0\n"
    "--------------------- LINES --------------------------------------------\n"
    "1 1 3 -\n2 2 3 -\n"
    "--------------------- SECTIONS -----------------------------------------\n"
    "1 chain 380 20\n2 chain 380 20\n"
    "--------------------- OPTIONS ------------------------------------------\n"
    "100 WtrDpth\n"
    "--------------------- OUTPUTS ------------------------------------------\n"
    '"Point3FH"\n'
    "--------------------- need this line -----------------------------------\n"
)


def test_section_curvature_channels_need_a_finite_ei_line():
    # CurvX/CurvY<L>N<J>: the curvature on the section axes of a finite-EI line; distinct from
    # Curv<L>N<J> and from each other
    with_channels = _edit(_DYNAMIC, ("\nFairTen1\n", "\nFairTen1\nCurvX1N2\nCurvY1N2\nCurv1N2\n"))
    deck = DeckFile.from_text(with_channels)
    assert {"CurvX1N2", "CurvY1N2", "Curv1N2"} <= set(deck.outputs)
    ei0 = _edit(_TIMED, ("\nFairTen1\n", "\nFairTen1\nCurvX1N2\n"))
    with pytest.raises(DeckFormatError, match="section curvature components need a finite-EI line"):
        DeckFile.from_text(ei0)
    # a farm-shared cable (two moving ends) runs on the cubic-Hermite route, which drives End B
    # as a second moving end and carries the section frame from End A
    shared = _edit(
        _TURBINE_DECK,
        ("chain 0.1 20.0 1.0e9 -1.0 0.0 1.2", "chain 0.1 20.0 1.0e9 -1.0 1.0e4 1.2"),
        ("1 1 3 -\n2 2 3 -\n", "1 1 2 -\n"),
        ("1 chain 380 20\n2 chain 380 20\n", "1 chain 620 30\n"),
        ("100 WtrDpth\n", "100 WtrDpth\n0.1 dtM\n10.0 TMax\n"),
        ('"Point3FH"', '"CurvY1N5"'),
    )
    assert "CurvY1N5" in DeckFile.from_text(shared).outputs


def test_viv_and_lift_flag_on_a_finite_ei_line_with_two_moving_ends():
    # native run_deck_driver: a farm-shared finite-EI line (Turbine1 to Turbine2) runs on the
    # cubic-Hermite march with both ends driven, which carries VIV: Cl > 0 and the lift file V
    # are accepted as on a line with a Fixed End B
    shared = _edit(
        _TURBINE_DECK,
        ("chain 0.1 20.0 1.0e9 -1.0 0.0 1.2", "chain 0.1 20.0 1.0e9 -1.0 1.0e4 1.2"),
        ("1 1 3 -\n2 2 3 -\n", "1 1 2 -\n"),
        ("1 chain 380 20\n2 chain 380 20\n", "1 chain 620 30\n"),
        ("100 WtrDpth\n", "100 WtrDpth\n0.1 dtM\n10.0 TMax\n"),
    )
    DeckFile.from_text(shared)
    viv = _edit(shared, ("1.2 0.2 1.0 0.0\n", "1.2 0.2 1.0 0.0 0.8\n"))
    DeckFile.from_text(viv)
    DeckFile.from_text(_edit(viv, ("1 1 2 -\n", "1 1 2 V\n")))
    # the same flag on a line with a Fixed End B is accepted
    DeckFile.from_text(_edit(_DYNAMIC, ("1 2 1 -\n", "1 2 1 V\n")))


def test_finite_ei_line_between_two_coupled_points():
    # native finalize_checks: a finite-EI line may join two Coupled/Vessel points (both ends
    # driven on the cubic-Hermite route); an EI = 0 line between them, or a finite-EI line to a
    # Connect point, stays refused
    deck = (
        "title\n"
        "--------------------- LINE TYPES ---------------------------------------\n"
        "chain 0.1 20.0 1.0e9 -1.0 1.0e4 1.2 0.2 1.0 0.0\n"
        "--------------------- POINTS -------------------------------------------\n"
        "1 Coupled 0 0 -10 0 0 0 0\n"
        "2 Vessel 300 0 -10 0 0 0 0\n"
        "--------------------- LINES --------------------------------------------\n"
        "1 1 2 -\n"
        "--------------------- SECTIONS -----------------------------------------\n"
        "1 chain 620 30\n"
        "--------------------- OPTIONS ------------------------------------------\n"
        "100 WtrDpth\n0.1 dtM\n10.0 TMax\n"
        "--------------------- OUTPUTS ------------------------------------------\n"
        "FairTen1\n"
        "--------------------- need this line -----------------------------------\n"
    )
    DeckFile.from_text(deck)
    ei0 = _edit(deck, ("chain 0.1 20.0 1.0e9 -1.0 1.0e4 1.2", "chain 0.1 20.0 1.0e9 -1.0 0.0 1.2"))
    with pytest.raises(DeckFormatError, match="End B must be Fixed"):
        DeckFile.from_text(ei0)


@pytest.mark.parametrize(
    ("edit", "message"),
    [
        (None, None),
        (("2 600 0 0\n", "2 600 0\n"), "TURBINES row needs 4 or 10 fields"),
        (("2 600 0 0\n", "1 600 0 0\n"), "TURBINES J must be unique"),
        (("2 Turbine2", "2 Turbine5"), "without a TURBINES row"),
    ],
)
def test_turbines_section(edit, message):
    text = _TURBINE_DECK if edit is None else _TURBINE_DECK.replace(*edit)
    if message is None:
        DeckFile.from_text(text)
    else:
        with pytest.raises(DeckFormatError, match=message):
            DeckFile.from_text(text)


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 Body1 G 0|0|-1e6 0 0", None),
        ("1 Body1 L 0 5|5|20 1", None),
        ("1 Body2 G 0 0 0", "must be a Rigid6 Body<N>"),
        ("1 Body1 X 0 0 0", "needs the CSys letter"),
        ("1 Body1 G 5 0 0", "Force is 0 or f1|f2|f3"),
        ("1 Body1 G 0 -1 0", "must be non-negative"),
        ("1 Body1 G 0 1|2 0", "needs one or three values"),
        ("1 Body1 G 0 0", "needs 6 fields"),
    ],
)
def test_external_loads(row, message):
    heading = "--------------------- OPTIONS ------------------------------------------\n"
    block = "--------------------- EXTERNAL LOADS ---------------------------------------\n"
    text = _example("rigid6_buoy.dat", (heading, block + row + "\n" + heading))
    if message is None:
        DeckFile.from_text(text)
    else:
        with pytest.raises(DeckFormatError, match=re.escape(message)):
            DeckFile.from_text(text)


def _wave_source(rows: str) -> str:
    source = _minimal_chain_source()
    return source.replace(
        "100.0        WtrDpth   - Water depth (m)",
        "100.0        WtrDpth   - Water depth (m)\n0.1 dtM\n1.0 TMax\n" + rows,
    )


@pytest.mark.parametrize(
    "rows",
    [
        "pm 3 9 0 waves",
        "ISSC 3 9 0 waves\n4 WaveSpreading\n5 WaveDirections",
        "bretschneider 3 9 0 waves",
        "torsethaugen 4 12 20 waves - two-peak sea",
        "ochihubble 2 14 3 2.5 7 1 0 waves",
        "jonswap 3 8 3.3 0 waves\n2 WaveSpreading\n100 WaveComponents",
        "jonswap 3 8 3.3 0 2 wavetrain\nissc 2 13 60 0 wavetrain\nairy 1 10 -30 wavetrain",
        "ochihubble 2 14 3 2.5 7 1 0 3 wave_train",
    ],
)
def test_spectral_waves_and_wave_trains_are_native_compatible(rows):
    deck = DeckFile.from_text(_wave_source(rows))
    keywords = [option.keyword.lower() for option in deck.options]
    assert "waves" in keywords or "wavetrain" in keywords or "wave_train" in keywords


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        ("pm 3 9 waves", "unknown OPTION keyword|malformed|positional"),
        ("pm -3 9 0 waves", "positive height/period"),
        ("pm 3 9 0 -1 wavetrain", "spreading exponent"),
        ("jonswap 3 9 0.5 0 2 wavetrain", "gamma must be in"),
        ("ochihubble 2 14 0 2.5 7 1 0 waves", "Ochi-Hubble"),
        ("jonswap 3 8 3.3 0 2 wavetrain\nairy 1 10 0 waves", "both wavetrain rows and a waves row"),
        ("airy 1 10 0 waves\n2 WaveSpreading", "needs a spectral waves row"),
        ("2 WaveSpreading", "needs a spectral waves row"),
        ("jonswap 3 8 3.3 0 2 wavetrain\n2 WaveSpreading", "carries its own spreading"),
        ("pm 3 9 0 waves\n1 WaveComponents", r"must be an integer in \[2, 100000\]"),
        ("pm 3 9 0 waves\n2.5 WaveDirections", r"must be an integer in \[1, 100000\]"),
        ("pm 3 9 0 waves\n2000 WaveSpreading", r"must be in \[0, 1000\]"),
    ],
)
def test_spectral_wave_rows_fail_closed_like_native(rows, message):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(_wave_source(rows))


def test_wave_train_row_is_editable():
    deck = DeckFile.from_text(_wave_source("jonswap 3 8 3.3 0 2 wavetrain"))
    deck.set_option("wavetrain", ("pm", 2.5, 10.0, 45.0, 4.0))
    assert deck.option("wavetrain").values == ("pm", "2.5", "10", "45", "4")
    with pytest.raises(ValueError):
        deck.set_option("wavetrain", ("pm", 2.5, 10.0, 45.0))


@pytest.mark.parametrize(
    "rows",
    [
        "0.5 frictionMu\n0.2 frictionMuAxial",
        "0.2 frictionMuAxial\n0.8 frictionMuLateral",
        "0.5 frictionMu\n0.5 frictionMuAxial\n0.5 frictionMuLateral",
        "0 frictionMuAxial\n0 frictionMuLateral",
    ],
)
def test_anisotropic_friction_rows_are_native_compatible(rows):
    deck = DeckFile.from_text(_wave_source(rows))
    assert deck.option("frictionMuAxial" if "Axial" in rows else "frictionMu") is not None


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        ("0.2 frictionMuAxial", "both the axial and the lateral coefficient positive"),
        (
            "0.5 frictionMu\n0 frictionMuLateral",
            "both the axial and the lateral coefficient positive",
        ),
        ("-0.2 frictionMuAxial\n0.5 frictionMu", "must be >= 0"),
    ],
)
def test_anisotropic_friction_rows_fail_closed_like_native(rows, message):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(_wave_source(rows))


@pytest.mark.parametrize(
    "rows",
    [
        "asLaid staticsFriction",
        "none staticsFriction",
        "ASLAID statics_friction",
        "As_Laid staticsSeabedFrictionPolicy",
        '"as-laid" seabedFrictionPolicy',
        "45.0 layAzimuth",
        "-30 lay_azimuth",
        "180 layAzimuth1",
        "2.0e5 asLaidTension",
        "0 as_laid_tension",
        "1e5 ASLAIDTENSION1",
        "10 layAzimuth01\n20 layAzimuth1\n0.5 frictionMu\nasLaid staticsFriction",
    ],
)
def test_static_friction_rows_are_native_compatible(rows):
    deck = DeckFile.from_text(_wave_source(rows))
    deck.validate()
    assert deck.options


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        ("restart staticsFriction", "OPTION staticsFriction must be asLaid or none"),
        ("1 seabedFrictionPolicy", "must be asLaid or none"),
        ("inf layAzimuth", "must be finite"),
        ("abc layAzimuth", "must be numeric"),
        ("nan layAzimuth1", "must be finite"),
        ("-1 asLaidTension", "must be >= 0"),
        ("-1 asLaidTension1", "must be >= 0"),
        ("inf as_laid_tension", "must be finite"),
        ("30 layAzimuth2", "layAzimuth2 names no LINE"),
        ("30 layAzimuth0", "layAzimuth0 names no LINE"),
        ("30 asLaidTension7", "asLaidTension7 names no LINE"),
        ("30 layAzimuth99999999999999999999", "names no LINE"),
        ("1 asLaidTension99999999999999999999", "names no LINE"),
        ("30 layAzimuth1x", "unknown OPTION keyword 'layAzimuth1x'"),
        ("30 layAzimuth_1", "unknown OPTION keyword"),
        ("30 layAzimuthx", "unknown OPTION keyword"),
        ("30 asLaidTension-1", "unknown OPTION keyword"),
    ],
)
def test_static_friction_rows_fail_closed_like_native(rows, message):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(_wave_source(rows)).validate()


def test_static_friction_option_identities_and_editing():
    deck = DeckFile.from_text(
        _wave_source(
            "90 layAzimuth\n45 LayAzimuth1\n30 layazimuth01\n0 asLaidTension\n"
            "5e4 asLaidTension1\nasLaid STATICSFRICTION"
        )
    )
    deck.validate()
    assert deck.option("layAzimuth").values == ("90",)
    assert deck.option("lay_azimuth").values == ("90",)
    # layAzimuth1, LayAzimuth1 and layazimuth01 name one line: the last row wins
    assert deck.option("layAzimuth1").values == ("30",)
    assert deck.option("LAYAZIMUTH001").values == ("30",)
    assert deck.option("asLaidTension1").values == ("5e4",)
    assert deck.option("as_laid_tension").values == ("0",)
    assert deck.option("staticsFriction").values == ("asLaid",)
    assert deck.option("seabedFrictionPolicy").values == ("asLaid",)
    with pytest.raises(KeyError):
        deck.option("layAzimuth2")
    deck.set_option("layAzimuth1", 120.0)
    deck.set_option("lay_azimuth", -15)
    deck.set_option("staticsFriction", "none")
    assert deck.option("layAzimuth01").values == ("120",)
    assert deck.option("layAzimuth").values == ("-15",)
    assert deck.option("staticsFriction").values == ("none",)
    with pytest.raises(DeckFormatError, match="asLaid or none"):
        deck.set_option("staticsFriction", "restart")
    with pytest.raises(DeckFormatError, match=">= 0"):
        deck.set_option("asLaidTension1", -2.0)
    with pytest.raises(DeckFormatError, match="must be finite"):
        deck.set_option("layAzimuth1", float("inf"))
    assert deck.option("staticsFriction").values == ("none",)
    assert deck.option("asLaidTension1").values == ("5e4",)
    assert DeckFile.from_text(deck.text()).option("layAzimuth1").values == ("120",)


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("10 nModes", None),
        ("0 modes", None),
        ("2.5 nModes", r"must be an integer in \[0, 1000\]"),
        ("2000 n_modes", r"must be an integer in \[0, 1000\]"),
    ],
)
def test_modal_option_matches_native(row, message):
    if message is None:
        DeckFile.from_text(_wave_source(row))
    else:
        with pytest.raises(DeckFormatError, match=message):
            DeckFile.from_text(_wave_source(row))


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        ("stream 6 9 0 waves", None),
        ("dean 6 9 0 waves\n30 StreamOrder", None),
        ("stream 6 9 0 waves\n0 stream_order", None),
        ("stream 0 9 0 waves", "positive height/period"),
        ("stream 6 9 0 waves\n1 StreamOrder", r"must be 0 \(default\) or an integer in \[2, 60\]"),
        ("stream 6 9 0 waves\n2 WaveSpreading", "needs a spectral waves row"),
    ],
)
def test_stream_wave_rows_match_native(rows, message):
    if message is None:
        DeckFile.from_text(_wave_source(rows))
    else:
        with pytest.raises(DeckFormatError, match=message):
            DeckFile.from_text(_wave_source(rows))


@pytest.mark.parametrize("mode", ["3", "7"])
def test_moordyn_c_wavekin_modes_are_accepted(tmp_path, mode):
    source = (ROOT / "examples/chain_catenary_r3_100m.dat").read_text(encoding="utf-8")
    source = source.replace("0         WaterKin", f"{mode}         WaterKin\n0.1 dtM\n1.0 TMax")
    path = tmp_path / "wavekin-mode.dat"
    path.write_text(source, encoding="utf-8")
    assert DeckFile.read(path).option("WaterKin").values == (mode,)


# ---------------------------------------------------------------------------
# Input admissibility: non-finite and subnormal numbers, strict attachments,
# admissible magnitudes (native list_safe_row / apply_option / finalize parity)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("row", ["NaN WaveKin", '"-Inf" WaterKin', "Infinity WaterKin"])
def test_nonfinite_waterkin_selector_is_not_a_file_name(row):
    with pytest.raises(DeckFormatError, match="is not a finite number"):
        DeckFile.from_text(_edit(_STATIC, ("50.0 WtrDpth\n", f"50.0 WtrDpth\n{row}\n")))


@pytest.mark.parametrize("row", ["NaN Currents", "-NaN recovery_max_substeps", "NaN mu"])
def test_nan_option_values_fail_closed(row):
    with pytest.raises(DeckFormatError):
        DeckFile.from_text(_edit(_STATIC, ("50.0 WtrDpth\n", f"50.0 WtrDpth\n{row}\n")))


@pytest.mark.parametrize(
    ("edit", "message"),
    [
        (("chain 0.252", "chain 5e-324"), "LINE TYPES column 2 value '5e-324' is subnormal"),
        (("400.0 0.0 -50.0", "1e309 0.0 -50.0"), "POINTS column 3 value '1e309' is not a finite"),
        (("410.0 41", "4.9e-324 41"), "SECTIONS column 3 value '4.9e-324' is subnormal"),
        (("50.0 WtrDpth\n", "50.0 WtrDpth\n4.9e-324 kBot\n"), "value '4.9e-324' is subnormal"),
        (("1.674e9 -1.0", "5e-324 -1.0"), "EA part 1 must be numeric"),
    ],
)
def test_subnormal_and_overflowing_numbers_fail_their_row(edit, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(_STATIC, edit))


def test_real_token_defect_ignores_names_and_separated_tokens():
    from cabledyn.deck_file import _real_token_defect

    assert _real_token_defect("chain") is None
    assert _real_token_defect("1/2") is None
    assert _real_token_defect("") is None
    assert _real_token_defect("1.0e5") is None
    assert "subnormal" in (_real_token_defect("-4.9e-324") or "")
    assert "not a finite" in (_real_token_defect("-inf") or "")


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ('1 "2 x" 1 -', "LINES column 2 must be an unquoted number"),
        ("1 2 '1' -", "LINES column 3 must be an unquoted number"),
        ('1 chain "2" 1 410.0 41 -', "LINES column 3 must be an unquoted number"),
        ('1 2 1 "-', "invalid quoting"),
        ("1 2x 1 -", "each line attachment must be a point id or a rod end"),
    ],
)
def test_line_attachments_are_unquoted_whole_ids(row, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(_STATIC, ("1 2 1 -\n", f"{row}\n")))


def test_line_free_object_deck_checks_line_type_rows_without_crashing():
    body_rows = (
        "ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca",
        "1 Rigid6 0 0 -20 0 0 0 1000 2 0 0 0 0 0",
    )
    no_lines = _edit(
        _STATIC,
        ("chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0\n", "chain 0.252\n"),
        ("1 2 1 -\n", ""),
        ("1 chain 410.0 41\n", ""),
    )
    with pytest.raises(DeckFormatError, match="LINE TYPES row needs 10, 11, 13, 14 fields"):
        DeckFile.from_text(_with_section(no_lines, "BODIES", *body_rows))
    # a header-only LINES section does not make the deck a line deck (the rule counts rows)
    with pytest.raises(DeckFormatError) as caught:
        DeckFile.from_text(
            _with_section(_edit(no_lines, ("chain 0.252\n", "")), "BODIES", *body_rows)
        )
    assert "missing" not in str(caught.value) and "has no data rows" not in str(caught.value)


def test_static_finite_ei_follows_the_native_mixed_route():
    mixed = _example(
        "iea15mw_umaine_mixed_cabledyn.dat",
        ("0.025    dtM", "-- dtM"),
        ("0.0      TMax", "-- TMax"),
        ("0.35     frictionMu", "-- frictionMu"),
    )
    DeckFile.from_text(mixed)
    pure = _edit(_DYNAMIC, ("0.1 dtM\n10.0 TMax\n", ""))
    with pytest.raises(DeckFormatError, match="finite-EI sections require dtM and TMax"):
        DeckFile.from_text(pure)


@pytest.mark.parametrize(
    ("base", "edit", "message"),
    [
        ("static", ("9.80665 g", "1e300 g"), "g must be at most 1e3"),
        ("static", ("1025.0 rhoW", "1e6 rhoW"), "rhoW at most 1e5"),
        ("static", ("50.0 WtrDpth", "1e7 WtrDpth"), "WtrDpth must be at most 1e6"),
        ("static", ("50.0 WtrDpth\n", "50.0 WtrDpth\n1e300 kBot\n"), "kBot and cBot"),
        ("static", ("1.674e9 -1.0", "1e-300 -1.0"), "EA >= 1e-3 N"),
        ("static", ("chain 0.252", "chain 1e-300"), "Diam >= 1e-6 m"),
        ("static", ("1.37 0.64", "1e100 0.64"), "Cd and Ca <= 1e3"),
        ("static", ("-1.0 0.0 1.37", "-1e300 0.0 1.37"), "|BA| <= 1e15"),
        ("dynamic", ("-1.0 1.0e4", "-1.0 1e300"), "EI and |BA| <= 1e15"),
        ("static", ("400.0 0.0 -50.0", "1e300 0.0 -50.0"), "POINTS row outside"),
        ("static", ("-50.0 0 0 0 0", "-50.0 0 0 0 1e100"), "POINTS row outside"),
        ("dynamic", ("10.0 TMax\n", "10.0 TMax\nairy 1e300 8 0 waves\n"), "height <= 1e3 m"),
        ("dynamic", ("10.0 TMax\n", "10.0 TMax\nairy 2 1e-300 0 waves\n"), "period in [0.1"),
        (
            "dynamic",
            ("10.0 TMax\n", "10.0 TMax\njonswap 2 8 1e10 0 waves\n"),
            "JONSWAP gamma must be in [1, 32.6)",
        ),
        ("dynamic", ("10.0 TMax\n", "10.0 TMax\npm 1e30 8 0 waves\n"), "a wave train needs"),
        ("dynamic", ("10.0 TMax\n", "10.0 TMax\nairy 2 8 1e7 wavetrain\n"), "a wave train needs"),
        (
            "dynamic",
            ("10.0 TMax\n", "10.0 TMax\nochihubble 2 8 1 1e30 8 1 0 waves\n"),
            "Hs2 <= 1e3 m",
        ),
        ("dynamic", ("10.0 TMax\n", "10.0 TMax\nuniform 1e100 0 0 current\n"), "at most 1e3 m/s"),
        (
            "dynamic",
            ("10.0 TMax\n", "10.0 TMax\nprofile -10 1e100 0 0 0 0 0 0 current\n"),
            "velocities at most 1e3 m/s",
        ),
        (
            "dynamic",
            ("10.0 TMax\n", "10.0 TMax\nprofile -1e7 0 0 0 0 0 0 0 current\n"),
            "depths must be at most 1e6 m",
        ),
    ],
)
def test_admissible_magnitudes_match_native(base, edit, message):
    text = _STATIC if base == "static" else _DYNAMIC
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(text, edit))


def test_turbine_positions_have_an_admissible_magnitude():
    with pytest.raises(DeckFormatError, match="TURBINES positions and angles"):
        DeckFile.from_text(_TURBINE_DECK.replace("2 600 0 0\n", "2 1e300 0 0\n"))


@pytest.mark.parametrize(
    ("name", "edit"),
    [
        ("rigid6_buoy.dat", ("1   Rigid6  0.0  0.0  -20.0", "1   Rigid6  1e7  0.0  -20.0")),
        ("rigid6_buoy.dat", ("0.0  0.0  8.0   0.5  3.5e4", "0.0  0.0  8.0   1e5  3.5e4")),
        ("mixed_body_rods_points.dat", ("1.5e5    0.0    2.0e6", "1.5e5    0.0    2.0e16")),
    ],
)
def test_body_magnitudes_match_native(name, edit):
    with pytest.raises(DeckFormatError, match="BODY data outside the admissible range"):
        DeckFile.from_text(_example(name, edit))


def test_host_body_magnitudes_match_native():
    text = _example(
        "rigid6_buoy.dat", ("1   Rigid6  0.0  0.0  -20.0", "1   Coupled  0.0  0.0  -2e6")
    )
    with pytest.raises(DeckFormatError, match="BODY data outside the admissible range"):
        DeckFile.from_text(text, caller_driven=True)


def _coupled_ambient_source(extra_option: str) -> str:
    return _minimal_chain_source().replace(
        "100.0        WtrDpth   - Water depth (m)",
        f"100.0        WtrDpth   - Water depth (m)\n0.05 dtM\n{extra_option}",
    )


@pytest.mark.parametrize(
    "row", ["airy 2.0 8.0 0.0 waves", "jonswap 2.0 8.0 3.3 0.0 waves", "airy 1.0 6.0 0.0 wavetrain"]
)
def test_coupled_route_rejects_deck_waves_by_name(tmp_path, row):
    path = tmp_path / "coupled-waves.dat"
    path.write_text(_coupled_ambient_source(row), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="deck waves are not evaluated on the coupled route"):
        DeckFile.read(path, caller_driven=True)


@pytest.mark.parametrize(
    ("old", "new"),
    [
        ("-1.0       0.0      1.37", "-1.0       2.0e4    1.37"),
        ("2     Coupled", "2     Turbine1"),
        (
            "--------------------- POINTS -------------------------------------------",
            "--------------------- BODIES -------------------------------------------\n"
            "1 Rigid6 0 0 0 0 0 0 1 1 0 0 0 1 1 2 3 4\n"
            "--------------------- POINTS -------------------------------------------",
        ),
    ],
    ids=["finite-ei", "farm", "rigid6"],
)
def test_coupled_route_keeps_deck_current_only_on_pure_ei0_decks(tmp_path, old, new):
    source = _coupled_ambient_source("uniform 0.5 0 0 current")
    assert old in source
    plain = tmp_path / "coupled-current.dat"
    plain.write_text(source, encoding="utf-8")
    assert DeckFile.read(plain, caller_driven=True).option("current").values[0] == "uniform"
    path = tmp_path / "coupled-current-rejected.dat"
    path.write_text(source.replace(old, new), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="deck current on the coupled route is kept only"):
        DeckFile.read(path, caller_driven=True)


# MoorDyn's optional cross-flow VIV columns: Cl, or Cl dF cF, after the ten standard ones.
_VIV_ROW = "chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0"


@pytest.mark.parametrize(
    "columns, expected",
    [
        (" 0.8", (0.8, None, None)),
        (" 0.8 0.05 0.2", (0.8, 0.05, 0.2)),
        (" 0.0 0.08 0.18", (0.0, 0.08, 0.18)),
    ],
)
def test_line_type_viv_columns_are_read_and_kept(tmp_path, columns, expected):
    from cabledyn import DeckModel

    text = _edit(_STATIC, (_VIV_ROW, _VIV_ROW + columns))
    DeckFile.from_text(text)
    path = tmp_path / "viv.dat"
    path.write_text(text, encoding="utf-8")
    line_type = DeckModel.load(path).line_types["chain"]
    assert (line_type.cl, line_type.df, line_type.cf) == expected
    saved = tmp_path / "saved.dat"
    DeckModel.load(path).save(saved)
    reread = DeckModel.load(saved).line_types["chain"]
    # a saved Cl row always writes the band; MoorDyn's defaults fill a Cl-only row
    assert (reread.cl, reread.df, reread.cf) == (
        expected[0],
        0.08 if expected[1] is None else expected[1],
        0.18 if expected[2] is None else expected[2],
    )


@pytest.mark.parametrize(
    "columns, message",
    [
        (" -0.1", "Cl must be non-negative"),
        (" 0.8 0.2 0.18", "needs cF > 0 and 0 <= dF < cF"),
        (" 0.8 0.05 0.0", "needs cF > 0 and 0 <= dF < cF"),
        (" 0.8 0.08", "LINE TYPES row needs 10, 11, 13, 14 fields"),
    ],
)
def test_line_type_viv_columns_follow_the_native_checks(columns, message):
    with pytest.raises(DeckFormatError, match=re.escape(message)):
        DeckFile.from_text(_edit(_STATIC, (_VIV_ROW, _VIV_ROW + columns)))


def test_line_type_viv_is_accepted_on_a_finite_ei_line_type(tmp_path):
    from cabledyn import DeckModel

    row = "chain 0.252 390.0 1.674e9 -1.0 1.0e4 1.37 0.64 1.0 0.0"
    text = _edit(_DYNAMIC, (row, row + " 0.8"))
    DeckFile.from_text(text)
    path = tmp_path / "viv_ei.dat"
    path.write_text(text, encoding="utf-8")
    line_type = DeckModel.load(path).line_types["chain"]
    assert (line_type.ei, line_type.cl) == (1.0e4, 0.8)


def test_viv_is_accepted_on_the_coupled_route():
    text = _edit(_STATIC, (_VIV_ROW, _VIV_ROW + " 0.8"))
    DeckFile.from_text(text)
    DeckFile.from_text(text, caller_driven=True)
    # the host supplies the water, so a deck without a depth is not refused there
    DeckFile.from_text(_edit(text, ("50.0 WtrDpth\n", "")), caller_driven=True)


def test_viv_on_an_ei0_line_needs_no_seabed(tmp_path):
    # native init_one_model builds every EI = 0 line with the still-water Morison drag (the
    # surface at z = 0), with or without a seabed, so its lift needs no WtrDpth either
    DeckFile.from_text(_edit(_STATIC, (_VIV_ROW, _VIV_ROW + " 0.8"), ("50.0 WtrDpth\n", "")))
    # a MoorDyn-C Currents 1 profile without a depth row
    source = ROOT / "tests" / "data" / "currents_mdc" / "c1"
    for name in ("currents.dat", "current_profile.txt", "points.txt"):
        shutil.copy(source / name, tmp_path / name)
    row = (
        "chain      0.1     50.0       1.0e7      0.0         0          1.2    1.0    0.2     0.0"
    )
    deck = tmp_path / "currents.dat"
    text = deck.read_text(encoding="utf-8")
    depth = "50            WtrDpth              water depth (m)\n"
    assert row in text and depth in text
    deck.write_text(text.replace(depth, "").replace(row, row + "    0.8"), encoding="utf-8")
    DeckFile.read(deck)


def test_finite_ei_viv_is_accepted_on_the_multibody_march():
    # the clamped cable of a moored Rigid6 buoy (native multibody march)
    row = "cable      0.20     60.0           5.0e8      -1.0       2.0e4    1.2   0.0   1.0   0.0"
    DeckFile.from_text(_example("buoy_clamped_cable.dat", (row, row + "   0.8")))


def test_viv_rms_window_option_is_non_negative():
    base = _edit(_STATIC, (_VIV_ROW, _VIV_ROW + " 0.8"))
    DeckFile.from_text(_edit(base, ("50.0 WtrDpth\n", "50.0 WtrDpth\n0.25 VIVrmsWindow\n")))
    with pytest.raises(DeckFormatError, match="VIVrmsWindow"):
        DeckFile.from_text(_edit(base, ("50.0 WtrDpth\n", "50.0 WtrDpth\n-1.0 VIVrmsWindow\n")))


def test_as_laid_statics_refused_on_a_finite_ei_line_between_two_moving_points():
    # native build_one_hermite_cable: no anchored end to lay the line from
    deck = (
        "title\n"
        "--------------------- LINE TYPES ---------------------------------------\n"
        "chain 0.1 20.0 1.0e9 -1.0 1.0e4 1.2 0.2 1.0 0.0\n"
        "--------------------- POINTS -------------------------------------------\n"
        "1 Coupled 0 0 -10 0 0 0 0\n"
        "2 Vessel 300 0 -10 0 0 0 0\n"
        "--------------------- LINES --------------------------------------------\n"
        "1 1 2 -\n"
        "--------------------- SECTIONS -----------------------------------------\n"
        "1 chain 620 30\n"
        "--------------------- OPTIONS ------------------------------------------\n"
        "100 WtrDpth\n0.1 dtM\n10.0 TMax\n0.5 frictionMu\nasLaid staticsFriction\n"
        "--------------------- OUTPUTS ------------------------------------------\n"
        "FairTen1\n"
        "--------------------- need this line -----------------------------------\n"
    )
    with pytest.raises(DeckFormatError, match="has a moving End B"):
        DeckFile.from_text(deck)
    DeckFile.from_text(deck.replace("asLaid staticsFriction", "none staticsFriction"))
