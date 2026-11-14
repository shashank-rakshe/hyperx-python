# SPDX-License-Identifier: Apache-2.0
"""Gates for the programmatic deck model (:mod:`cabledyn.builder`)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from cabledyn import DeckFile, DeckFormatError
from cabledyn.builder import (
    Body,
    DeckModel,
    DeckReferenceError,
    Line,
    MoorDynBody,
    Option,
    Point,
    RodEnd,
    SyropeEA,
)
from cabledyn.deck_file import (
    _end_connection_end,
    _native_float,
    _native_int,
    _option_key,
    _rod_end_token,
)

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = sorted(
    path
    for path in (ROOT / "examples").rglob("*.dat")
    if "data" not in path.relative_to(ROOT / "examples").parts
)


# ------------------------------------------------------------------ semantic normalizer


def _value(token: str) -> object:
    parts = re.split(r"[|:]", token)
    out: list[object] = []
    for part in parts:
        try:
            out.append(_native_float(part))
        except ValueError:
            out.append(part.lower())
    return out[0] if len(out) == 1 else tuple(out)


def _cells(tokens: tuple[str, ...]) -> tuple[object, ...]:
    return tuple(_value(token) for token in tokens)


def _end(token: str) -> object:
    canonical = _rod_end_token(token)
    return canonical if canonical is not None else _native_int(token)


def _semantic(deck: DeckFile) -> dict[str, object]:
    """Reduce a parsed deck to its meaning, independently of the builder."""
    line_types = []
    for row in deck.line_types:
        fields = dict(zip(deck._line_type_fields(row), row.tokens, strict=True))
        if "cd" in fields:
            fields.update(cdn=fields["cd"], can=fields["ca"], cdt=fields["cdax"])
            fields["cat"] = fields["caax"]
        names = ["name", "diam", "mass", "ea", "ba", "ei", "gas", "gj", "irt", "irn"]
        names += ["cdn", "cdt", "can", "cat"]
        line_types.append(tuple(_value(fields[n]) if n in fields else None for n in names))
    points = [_cells(row.tokens + ("0",) * (9 - len(row.tokens))) for row in deck.points]
    lines = {}
    for row in deck.lines:
        tokens = row.tokens
        line_id = _native_int(tokens[0])
        ends = tokens[2:4] if len(tokens) == 7 else tokens[1:3]
        outputs = tokens[6] if len(tokens) == 7 else (tokens[3] if len(tokens) == 4 else "-")
        sections = []
        for record, _, section in deck._line_section_records(line_id):
            t = record.tokens
            if section == "LINES":
                sections.append((t[1].lower(), _native_float(t[4]), _native_int(t[5])))
            else:
                sections.append((t[1].lower(), _native_float(t[2]), _native_int(t[3])))
        lines[line_id] = (_end(ends[0]), _end(ends[1]), outputs, sections)
    end_connections = [
        (_native_int(t[0]), _end_connection_end(t[1]), *_cells(t[2:]))
        for t in (row.tokens for row in deck.end_connections)
    ]
    rods = [_cells(row.tokens + ("-",) * (11 - len(row.tokens))) for row in deck._rows("RODS")]
    failures = []
    for row in deck._rows("FAILURE"):
        t = row.tokens
        point = t[1][1:] if t[1][:1].lower() == "p" else t[1]
        failures.append((_native_int(point), [int(v) for v in t[2].split(",")], *_cells(t[3:])))
    syrope = [
        ([int(v) for v in "".join(row.tokens[:-2]).split(",")], *_cells(row.tokens[-2:]))
        for row in deck._rows("SYROPE IC")
    ]
    generic = {
        section: [_cells(row.tokens) for row in deck._rows(section)]
        for section in (
            "BODIES",
            "ROD TYPES",
            "TURBINES",
            "EQUIVALENT BUOYANCY",
            "ATTACHMENTS",
            "STIFFENERS",
            "CONTROL",
            "EXTERNAL LOADS",
        )
    }
    options = [(_option_key(row.keyword), row.values) for row in deck.options]
    return {
        "line_types": line_types,
        "points": points,
        "lines": lines,
        "end_connections": end_connections,
        "rods": rods,
        "failures": failures,
        "syrope": syrope,
        **generic,
        "options": options,
        "outputs": [name.lower() for name in deck.outputs],
    }


def _caller_driven(path: Path) -> bool:
    return "openfast" in path.parts


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda path: path.name)
def test_every_example_round_trips(path: Path) -> None:
    caller_driven = _caller_driven(path)
    original = DeckFile.read(path, caller_driven=caller_driven)
    model = DeckModel.from_deck_file(original)
    text = model.to_text()
    reparsed = DeckFile.from_text(text, path=path, caller_driven=caller_driven)
    assert _semantic(reparsed) == _semantic(original)
    # model -> text -> model -> text is a fixed point
    assert DeckModel.from_text(text, path=path, caller_driven=caller_driven).to_text() == text


def test_examples_are_found() -> None:
    assert len(EXAMPLES) >= 50


# ------------------------------------------------------------------ building from scratch


def _chain_model(tmp_path: Path | None = None) -> DeckModel:
    model = DeckModel.new(
        title="single chain catenary", path=(tmp_path or Path.cwd()) / "chain.dat"
    )
    chain = model.add_line_type(
        "chain", diam=0.252, mass=390.0, ea=1.674e9, ba=-1.0, cdn=1.37, cdt=0.64, can=1.0
    )
    fairlead = model.add_point(1, "Coupled", 0.0, 0.0, 0.0)
    anchor = model.add_point(2, "Fixed", 400.0, 0.0, -50.0)
    model.add_line(1, fairlead, anchor, chain, length=410.0, num_segs=41)
    model.options.set("g", 9.80665, description="Gravitational acceleration (m/s^2)")
    model.options.set("WtrDpth", 50.0)
    model.outputs.add("FairTen1", "AnchTen1", "Point1pz")
    return model


def test_build_single_catenary_validates_and_saves(tmp_path: Path) -> None:
    model = _chain_model(tmp_path)
    model.validate()
    target = model.save(tmp_path / "out" / "chain.dat")
    deck = DeckFile.read(target)
    assert [row.tokens[0] for row in deck.points] == ["1", "2"]
    assert deck.option("WtrDpth").values == ("50.0",)
    assert deck.option("g").description == "Gravitational acceleration (m/s^2)"
    assert deck.outputs == ("FairTen1", "AnchTen1", "Point1pz")
    loaded = DeckModel.load(target)
    assert loaded.title == "single chain catenary"
    assert loaded.lines[1].sections[0].line_type is loaded.line_types["CHAIN"]
    assert loaded.lines[1].length == 410.0
    assert loaded.to_text() == model.to_text()
    with pytest.raises(FileExistsError):
        model.save(target)
    assert model.save(target, overwrite=True) == target


def test_viv_columns_do_not_combine_with_the_wide_finite_ei_row(tmp_path: Path) -> None:
    model = _chain_model(tmp_path)
    model.add_line_type(
        "cable",
        diam=0.2,
        mass=40.0,
        ea=5.0e8,
        ei=1.0e4,
        gas=1.0e8,
        gj=1.0e3,
        irt=0.1,
        irn=0.05,
        cl=0.0,
    )
    with pytest.raises(ValueError, match="do not combine with gas, gj, irt, irn"):
        model.to_text(validate=False)


def test_build_spread_mooring_with_multi_section_lines() -> None:
    import math

    model = DeckModel.new(title="three-leg spread")
    chain = model.add_line_type("chain", diam=0.252, mass=390.0, ea=1.674e9, ba=-1.0)
    wire = model.add_line_type("wire", diam=0.2, mass=90.0, ea=7.0e8, ba=-1.0)
    for leg in range(3):
        angle = math.radians(120.0 * leg)
        fairlead = model.add_point(
            model.points.next_id(), "Vessel", 40 * math.cos(angle), 40 * math.sin(angle), -14.0
        )
        anchor = model.add_point(
            model.points.next_id(), "Fixed", 800 * math.cos(angle), 800 * math.sin(angle), -200.0
        )
        line = model.add_line(model.lines.next_id(), fairlead, anchor, outputs="pt")
        model.add_section(line, "wire", 300.0, 30)
        model.add_section(line, chain, 550.0, 55)
        model.outputs.add(f"FairTen{line.id}")
    model.add_section(1, wire, 5.0, 1, index=0)
    model.options.set("WtrDpth", 200.0)
    deck = model.to_deck_file()
    assert [row.tokens for row in deck.sections][:3] == [
        ("1", "wire", "5.0", "1"),
        ("1", "wire", "300.0", "30"),
        ("1", "chain", "550.0", "55"),
    ]
    assert model.lines[1].num_segs == 86
    assert len(model.lines) == 3 and model.lines.keys() == [1, 2, 3]
    assert model.points.next_id() == 7


def test_stock_moordyn_rows_are_kept_and_expand_when_sectioned() -> None:
    model = _chain_model()
    line = model.lines[1]
    line.stock_row = True
    deck = model.to_deck_file()
    assert deck.lines[0].tokens == ("1", "chain", "1", "2", "410.0", "41", "-")
    assert deck.sections == ()
    model.add_section(line, "chain", 10.0, 1)
    deck = model.to_deck_file()
    assert deck.lines[0].tokens == ("1", "1", "2", "-")
    assert len(deck.sections) == 2


# ------------------------------------------------------------------ editing


def test_edit_fields_in_place_and_revalidate() -> None:
    model = DeckModel.load(ROOT / "examples/chain_catenary_r3_100m.dat")
    line = next(iter(model.lines))
    line.sections[0].length += 25.0
    model.points[line.end_b.id].z = -99.0  # type: ignore[union-attr]
    new = model.add_point(model.points.next_id(), "Fixed", 10.0, 0.0, -100.0)
    assert new in model.points and new.id in model.points
    deck = model.to_deck_file()
    assert _native_float(deck.sections[0].tokens[2]) == line.sections[0].length
    with pytest.raises(DeckFormatError, match="below the seabed"):
        new.z = -500.0
        model.validate()


def test_rename_propagates_to_rows_and_output_channels() -> None:
    model = _chain_model()
    model.outputs.add(
        "Ten1N3", "L1N2px", "TDP1s", "TDP1Grd", "AnchFz1", "AnchFH1", "Point2FH", "Con1py"
    )
    model.rename(model.lines[1], 7)
    model.rename(model.points[1], 11)
    model.rename(model.line_types["chain"], "R3chain")
    assert list(model.outputs) == [
        "FairTen7",
        "AnchTen7",
        "Point11pz",
        "Ten7N3",
        "L7N2px",
        "TDP7s",
        "TDP7Grd",
        "AnchFz7",
        "AnchFH7",
        "Point2FH",
        "Con11py",
    ]
    deck = model.to_deck_file()
    assert deck.lines[0].tokens == ("7", "11", "2", "-")
    assert deck.sections[0].tokens[:2] == ("7", "R3chain")
    with pytest.raises(ValueError, match="already"):
        model.rename(model.points[11], 2)
    with pytest.raises(ValueError, match="already exists"):
        model.add_line_type("r3CHAIN", diam=1.0, mass=1.0, ea=1.0)
    with pytest.raises(ValueError, match="already exists"):
        model.rename(model.add_line_type("spare", diam=1.0, mass=1.0, ea=1.0), "R3CHAIN")
    with pytest.raises(TypeError):
        model.rename(model.points[11], "11")
    with pytest.raises(TypeError):
        model.rename(model.line_types["spare"], 3)
    with pytest.raises(DeckReferenceError):
        model.rename(Point(1, "Fixed", 0.0, 0.0, 0.0), 3)


def test_per_line_options_follow_rename_and_removal() -> None:
    model = _chain_model()
    model.options.set("layAzimuth1", 30)
    model.options.set("asLaidTension01", 5.0e3)
    model.options.set("layAzimuth", 10)

    def friction_keywords() -> list[str]:
        return [
            row.keyword
            for row in model.options
            if row.keyword.lower().startswith(("layazimuth", "aslaidtension"))
        ]

    model.rename(model.lines[1], 2)
    assert friction_keywords() == ["layAzimuth2", "asLaidTension2", "layAzimuth"]
    text = model.to_text()
    assert "layAzimuth2" in text and "asLaidTension2" in text
    line = model.lines[2]
    assert [ref.keyword for ref in model.references(line) if isinstance(ref, Option)] == [
        "layAzimuth2",
        "asLaidTension2",
    ]
    with pytest.raises(DeckReferenceError) as caught:
        model.remove(line)
    assert "OPTION layAzimuth2" in str(caught.value)
    model.remove(line, cascade=True)
    assert friction_keywords() == ["layAzimuth"]


def test_remove_reports_referential_integrity_and_cascades() -> None:
    model = _chain_model()
    model.add_line_type("finite", diam=0.2, mass=100.0, ea=1.0e9, ei=1.0e4)
    line = model.lines[1]
    failure = model.add_failure(1, line, fail_time=10.0)
    with pytest.raises(DeckReferenceError) as caught:
        model.remove(line)
    assert failure in caught.value.referrers
    assert "FairTen1" in caught.value.referrers
    assert "is still used by" in str(caught.value)
    model.remove(line, cascade=True)
    assert len(model.lines) == 0
    assert model.failures == ()
    assert list(model.outputs) == ["Point1pz"]
    # the deck is now incomplete, which native validation reports
    with pytest.raises(DeckFormatError):
        model.validate()
    assert "LINES" not in model.to_text(validate=False)


def test_remove_point_cascades_through_lines() -> None:
    model = _chain_model()
    with pytest.raises(DeckReferenceError, match="Line 1"):
        model.remove(model.points[2])
    model.remove(model.points[2], cascade=True)
    assert model.points.keys() == [1]
    assert len(model.lines) == 0
    assert "FairTen1" not in model.outputs and "point1pz" in model.outputs


def test_remove_line_type_drops_sections_and_emptied_lines() -> None:
    model = _chain_model()
    wire = model.add_line_type("wire", diam=0.2, mass=90.0, ea=7.0e8)
    model.add_section(1, wire, 50.0, 5)
    model.add_equivalent_buoyancy(wire, 0.3, 100.0)
    refs = model.references(wire)
    assert len(refs) == 2
    model.remove(wire, cascade=True)
    assert len(model.lines[1].sections) == 1 and model.equivalent_buoyancy == ()
    model.remove(model.line_types["chain"], cascade=True)
    assert len(model.lines) == 0


def test_remove_multi_line_rows_keep_their_other_lines() -> None:
    model = _chain_model()
    model.add_point(3, "Fixed", -400.0, 0.0, -50.0)
    model.add_line(2, 1, 3, "chain", length=410.0, num_segs=41)
    model.options.set("dtM", 0.01)
    model.options.set("TMax", 1.0)
    failure = model.add_failure(model.points[1], [1, 2], fail_tension=1.0e6)
    model.validate()
    model.remove(model.lines[1], cascade=True)
    assert failure.lines == [model.lines[2]]
    assert model.to_deck_file()._rows("FAILURE")[0].tokens == ("1", "P1", "2", "0.0", "1000000.0")
    model.remove(failure)
    assert model.failures == ()


def test_remove_rows_sections_channels_and_errors() -> None:
    model = _chain_model()
    section = model.lines[1].sections[0]
    model.remove(section)
    assert model.lines[1].sections == []
    model.remove("fairten1")
    assert "FairTen1" not in model.outputs
    with pytest.raises(DeckReferenceError, match="not part of this model"):
        model.remove(section)
    with pytest.raises(DeckReferenceError):
        model.references(object())
    with pytest.raises(KeyError):
        model.outputs.remove("nope")


# ------------------------------------------------------------------ finite-EI rows


def _finite_ei_model() -> DeckModel:
    model = DeckModel.new(title="finite-EI cable")
    cable = model.add_line_type(
        "cable", diam=0.2, mass=100.0, ea=7.0e8, ba=-1.0, ei=1.0e4, cdn=1.2, cdt=0.01, can=1.0
    )
    model.add_point(1, "Coupled", 0.0, 0.0, -10.0)
    model.add_point(2, "Fixed", 150.0, 0.0, -100.0)
    model.add_line(1, 1, 2, cable, length=200.0, num_segs=40)
    model.options.set("WtrDpth", 100.0)
    model.options.set("dtM", 0.01)
    model.options.set("TMax", 1.0)
    return model


def test_section_curvature_channels_follow_rename_and_removal() -> None:
    model = _finite_ei_model()
    model.outputs.add("CurvX1N2", "curvy1n2", "Curv1N2", "BendMom1N2")
    model.rename(model.lines[1], 3)
    assert list(model.outputs)[-4:] == ["CurvX3N2", "curvy3n2", "Curv3N2", "BendMom3N2"]
    model.validate()
    model.remove(model.lines[3], cascade=True)
    assert not any(name.lower().startswith(("curv", "bendmom")) for name in model.outputs)


def test_end_connections_attachments_and_equivalent_buoyancy() -> None:
    model = _finite_ei_model()
    model.add_end_connection(1, "EndA", 2.0e4, (-0.25, 0.0, -0.97))
    model.add_end_connection(model.lines[1], "b", "Rigid", [1.0, 0.0, 0.0])
    with pytest.raises(ValueError, match="already has an end connection"):
        model.add_end_connection(1, "A", "Pinned", (0.0, 0.0, 1.0))
    with pytest.raises(ValueError, match="end must be A or B"):
        model.add_end_connection(1, "C", 0.0, (0.0, 0.0, 1.0))
    with pytest.raises(TypeError):
        model.add_end_connection(1, 1, 0.0, (0.0, 0.0, 1.0))  # type: ignore[arg-type]
    model.add_attachment(1, (42.5, 5.0, 87.5), mass=114.15, volume=0.2297, cda=0.78, ca=1.0)
    model.add_attachment(1, 120.0, mass=800.0, cda=0.3, cdax=0.1)
    model.add_equivalent_buoyancy("cable", 0.3, 500.0)
    deck = model.to_deck_file()
    assert [row.tokens for row in deck.end_connections] == [
        ("1", "A", "20000.0", "-0.25", "0.0", "-0.97"),
        ("1", "B", "Rigid", "1.0", "0.0", "0.0"),
    ]
    assert deck._rows("ATTACHMENTS")[0].tokens[1] == "42.5:5.0:87.5"
    assert len(deck._rows("ATTACHMENTS")[1].tokens) == 7
    round_trip = DeckModel.from_deck_file(deck)
    assert round_trip.attachments[0].arc_length == (42.5, 5.0, 87.5)
    assert round_trip.end_connections[1].stiffness == "Rigid"
    # a bend stiffener: a cylindrical root and a cone at End A
    model.add_stiffener(1, "a", 0.4, 0.45, 0.45, 0.17, 5.0e7, 1150.0)
    model.add_stiffener(model.lines[1], "EndA", 3.6, 0.45, 0.18, 0.17, 5.0e7, 1150.0)
    deck = model.to_deck_file()
    assert [row.tokens[:3] for row in deck._rows("STIFFENERS")] == [
        ("1", "A", "0.4"),
        ("1", "A", "3.6"),
    ]
    round_trip = DeckModel.from_deck_file(deck)
    assert [(row.end, row.length, row.tip_od) for row in round_trip.stiffeners] == [
        ("A", 0.4, 0.45),
        ("A", 3.6, 0.18),
    ]
    refs = round_trip.references(round_trip.lines[1])
    assert all(any(ref is row for ref in refs) for row in round_trip.stiffeners)
    with pytest.raises(ValueError, match="end must be A or B"):
        model.add_stiffener(1, "C", 1.0, 0.4, 0.4, 0.2, 5.0e7, 1150.0)
        model.to_text(validate=False)
    model.remove(model.stiffeners[-1])
    assert len(model.stiffeners) == 2
    # an end connection on an EI = 0 line is a native error
    model.line_types["cable"].ei = 0.0
    with pytest.raises(DeckFormatError):
        model.validate()


def test_wide_line_types_and_viscoelastic_forms() -> None:
    model = _finite_ei_model()
    cable = model.line_types["cable"]
    cable.gas, cable.gj, cable.irt, cable.irn = 1.0e8, 1.0e4, 0.1, 0.2
    model.add_line_type("ve", diam=0.2, mass=40.0, ea=(1.0e8, 3.0e8), ba=(-0.8, 1.0e5))
    model.add_line_type(
        "rope", diam=0.2, mass=40.0, ea=SyropeEA("syrope/settings.dat", 1.0e8, 20.0), ba=(1e7, 1e8)
    )
    deck = model.to_deck_file()
    assert len(deck.line_types[0].tokens) == 14
    assert deck.line_types[1].tokens[3:5] == ("100000000.0|300000000.0", "-0.8|100000.0")
    assert deck.line_types[2].tokens[3] == "SYROPE:syrope/settings.dat|100000000.0|20.0"
    loaded = DeckModel.from_deck_file(deck)
    assert loaded.line_types["rope"].ea == SyropeEA("syrope/settings.dat", 1.0e8, 20.0)
    assert loaded.line_types["cable"].irn == 0.2
    cable.irn = None
    with pytest.raises(ValueError, match="gas, gj, irt, irn"):
        model.to_text()


# ------------------------------------------------------------------ FAILURE, CONTROL, motion


def test_failure_rows_are_numbered_in_order() -> None:
    model = _chain_model()
    model.options.set("dtM", 0.01)
    model.options.set("TMax", 1.0)
    model.add_failure(1, 1, fail_time=5.0)
    model.add_failure(model.points[1], [model.lines[1]], fail_tension=2.5e6)
    rows = model.to_deck_file()._rows("FAILURE")
    assert [row.tokens[:3] for row in rows] == [("1", "P1", "1"), ("2", "P1", "1")]
    model.add_failure(2, 1)
    with pytest.raises(DeckFormatError, match="FailTime > 0 or FailTen > 0"):
        model.validate()
    with pytest.raises(ValueError, match="at least one line"):
        model.add_failure(1, [])


def test_control_rows_on_the_caller_driven_route() -> None:
    model = _chain_model()
    model.caller_driven = True
    model.add_point(3, "Fixed", -400.0, 0.0, -50.0)
    model.add_line(2, 1, 3, "chain", length=410.0, num_segs=41)
    model.add_control(1, [1, 2])
    deck = model.to_deck_file()
    assert deck._rows("CONTROL")[0].tokens == ("1", "1,2")
    assert DeckModel.from_deck_file(deck).controls[0].lines[1].id == 2


def test_prescribed_motion_sources_are_alternatives() -> None:
    model = _chain_model()
    model.options.set("dtM", 0.1)
    model.options.set("TMax", 10.0)
    model.set_vessel_motion("data/vessel/motion.txt", reference=(0.0, 0.0, -5.0))
    assert model.options.value("vesselMotion") == "data/vessel/motion.txt"
    assert model.options.value("vesselRef") == "0.0|0.0|-5.0"
    model.validate()
    model.set_motion_file(Path("motion.dat"))
    assert "vesselMotion" not in model.options
    assert model.options.value("motionfile") == "motion.dat"
    model.set_vessel_rao("rao.txt")
    assert "motionFile" not in model.options and "vesselRef" in model.options
    with pytest.raises(DeckFormatError, match="needs deck waves"):
        model.validate()
    model.options.set("waves", "airy", 2.0, 8.0, 0.0)
    model.validate()
    assert model.to_text().count("airy 2.0 8.0 0.0 waves") == 1
    model.clear_motion()
    assert not any(k in model.options for k in ("vesselRAO", "vesselRef", "motionFile"))


def test_save_rebases_relative_ancillary_paths(tmp_path: Path) -> None:
    source = ROOT / "examples/lazy_wave_vessel_motion.dat"
    model = DeckModel.load(source)
    keyword = next(row for row in model.options if row.keyword.lower() == "vesselmotion")
    target = model.save(tmp_path / "nested" / "copy.dat")
    written = DeckFile.read(target).option("vesselMotion").values[0]
    assert (target.parent / written).resolve() == (source.parent / keyword.value).resolve()
    assert model.options.value("vesselMotion") == keyword.value
    unrebased = model.save(tmp_path / "plain.dat", rebase=False)
    assert DeckFile.read(unrebased).option("vesselMotion").values[0] == keyword.value


# ------------------------------------------------------------------ bodies, rods, turbines


def test_bodies_rods_and_rod_ends() -> None:
    model = DeckModel.new(title="spar")
    model.add_line_type("chain", diam=0.1, mass=20.0, ea=5.0e8, ba=-0.8, cdn=1.2, cdt=0.4)
    model.add_rod_type("can", diam=2.0, mass=1500.0, cd=0.8, ca=1.0)
    model.add_rod_type("arm", diam=0.5, mass=600.0, cd=1.0, ca=1.0, cd_ax=0.1, ca_ax=0.2)
    body = model.add_moordyn_body(
        1, "Free", 3.0, 0.0, -15.0, mass=1.5e5, inertia=2.0e6, volume=160.0, cda=(20.0, 0.0), ca=0.5
    )
    model.add_rod(1, "can", "Body1", (0.0, 0.0, 2.0), (0.0, 0.0, 8.0), 4)
    arm = model.add_rod(2, "arm", "BodyPinned", (0, 0, -2.0), (0, 0, -12.0), 5, body=body)
    assert arm.type_token == "Body1Pinned"
    model.add_point(1, "Body1", 3.0, 0.0, 0.0)
    model.add_point(2, "Fixed", 150.0, 0.0, -70.0)
    model.add_point(3, "Fixed", 3.0, 0.0, -70.0)
    model.add_point(4, "Rod", 0.0, 0.0, 0.0, rod_end=model.rod_end(1, "b"))
    model.add_line(1, 1, 2, "chain", length=150.0, num_segs=20)
    rod_line = model.add_line(2, "R2B", 3, "chain", length=60.0, num_segs=12)
    assert isinstance(rod_line.end_a, RodEnd) and rod_line.end_a.token == "R2B"
    model.options.set("dtM", 0.005)
    model.options.set("TMax", 1.0)
    model.options.set("WtrDpth", 70.0)
    model.outputs.add("Body1Px", "Rod2Ry", "Rod2N5Px")
    deck = model.to_deck_file()
    assert deck._rows("RODS")[1].tokens[2] == "Body1Pinned"
    assert deck.points[3].tokens[1] == "Rod1B"
    assert model.points[4].type_token == "Rod1B"
    assert deck._rows("BODIES")[0].tokens[12] == "20.0|0.0"
    assert len(deck._rows("ROD TYPES")[1].tokens) == 9
    # renumbering the body and rods follows every reference
    model.rename(body, 5)
    model.rename(arm, 9)
    text = model.to_text()
    assert "Body5Pinned" in text and "R9B" in text and '"Rod9Ry"' in text
    assert '"Body5Px"' in text
    with pytest.raises(DeckReferenceError):
        model.remove(model.rods[9])
    model.remove(model.rods[9], cascade=True)
    assert 2 not in model.lines and "Rod9Ry" not in model.outputs
    model.remove(model.rod_types["can"], cascade=True)
    assert 4 not in model.points and len(model.rods) == 0
    model.remove(body, cascade=True)
    assert model.points.keys() == [2, 3] and len(model.lines) == 0


def test_rigid6_body_external_loads() -> None:
    model = DeckModel.load(ROOT / "examples/als_volturnus_line_break_tension.dat")
    body = next(iter(model.bodies))
    assert isinstance(body, Body) and body.inertia is not None
    load = model.external_loads[0]
    assert load.body is body and isinstance(load.force, tuple)
    body.inertia = None
    with pytest.raises(DeckFormatError, match="Ixx, Iyy, and Izz"):
        model.validate()
    body.inertia = (1.0, 2.0, 3.0)
    extra = model.add_external_load(2, body.id, csys="L", force=0.0, blin=(1.0, 2.0, 3.0))
    deck = model.to_deck_file()
    expected = ("2", f"Body{body.id}", "L", "0.0", "1.0|2.0|3.0", "0.0")
    assert deck._rows("EXTERNAL LOADS")[1].tokens == expected
    with pytest.raises(DeckReferenceError):
        model.remove(body)
    model.remove(extra)
    assert len(model.external_loads) == 1


def test_turbines_on_a_farm_deck() -> None:
    model = DeckModel.new(title="farm")
    model.add_line_type("chain", diam=0.1, mass=20.0, ea=1.0e9, ba=-1.0, cdn=1.2, cdt=0.2, can=1.0)
    model.add_turbine(1, 0.0, 0.0, 0.0, ptfm=(0, 0, 0, 0, 0, 0))
    turbine = model.add_turbine(2, 600.0, 0.0, 0.0)
    model.add_point(1, "Turbine1", 0.0, 0.0, -10.0)
    model.add_point(2, "T", 0.0, 0.0, -10.0, turbine=2)
    model.add_point(3, "Fixed", 300.0, 0.0, -100.0)
    model.add_line(1, 1, 3, "chain", length=380.0, num_segs=20)
    model.add_line(2, 2, 3, "chain", length=380.0, num_segs=20)
    model.options.set("WtrDpth", 100.0)
    deck = model.to_deck_file()
    assert [row.tokens[1] for row in deck.points] == ["Turbine1", "T2", "Fixed"]
    assert len(deck._rows("TURBINES")[0].tokens) == 10
    model.rename(turbine, 5)
    assert model.points[2].type_token == "T5"
    with pytest.raises(DeckReferenceError):
        model.remove(turbine)
    model.remove(turbine, cascade=True)
    assert 2 not in model.points and 2 not in model.lines


def test_syrope_initial_condition_rows() -> None:
    model = DeckModel.load(ROOT / "examples/syrope_polyester_mooring.dat")
    ic = model.syrope_ic[0]
    assert all(isinstance(line, Line) for line in ic.lines)
    ic.tmax0 = ic.tmean0 / 2.0
    with pytest.raises(DeckFormatError, match="Tmax0 >= Tmean0"):
        model.validate()
    model.remove(ic)
    model.add_syrope_ic([line.id for line in model.lines], 4.0e6, 1.0e6)
    model.validate()


# ------------------------------------------------------------------ collections and options


def test_collections_are_live_lookups() -> None:
    model = _chain_model()
    points = model.points
    assert len(points) == 2 and [p.id for p in points] == [1, 2]
    assert points.get(9) is None and 1 in points and "x" not in points
    assert "chain" in model.line_types and "CHAIN" in model.line_types
    assert "Point" in repr(points) or "point" in repr(points)
    with pytest.raises(KeyError, match="point 9 does not exist"):
        points[9]
    with pytest.raises(TypeError):
        points.get(True)
    model.points[1].id = 5
    assert points.keys() == [5, 2]
    assert "DeckModel" in repr(model)


def test_option_set_static_friction_rows() -> None:
    model = _chain_model()
    options = model.options
    options.set("staticsFriction", "asLaid")
    options.set("layAzimuth", 45.0)
    options.set("layAzimuth1", 180.0)
    options.set("LAYAZIMUTH01", 90.0)  # the same line as layAzimuth1: replaces it
    options.set("asLaidTension1", 1.0e5)
    assert [row.keyword for row in options if row.keyword.lower().startswith("layazimuth")] == [
        "layAzimuth",
        "LAYAZIMUTH01",
    ]
    assert options.value("layAzimuth1") == "90.0" and options.value("asLaidTension1") == "100000.0"
    assert options.value("layAzimuth2") is None
    model.validate()
    text = model.to_text()
    assert "asLaid staticsFriction" in text and "90.0 LAYAZIMUTH01" in text
    assert options.remove("layAzimuth1") == 1 and "layAzimuth" in options
    with pytest.raises(ValueError, match="unknown option keyword"):
        options.set("layAzimuth1x", 1.0)
    options.set("layAzimuth3", 10.0)
    with pytest.raises(Exception, match="names no LINE"):
        model.validate()


def test_option_set_semantics() -> None:
    model = _chain_model()
    options = model.options
    options.set("dt", 0.05, description="Time step (s)")
    options.set("TMax", 10)
    options.set("modified_newton", True)
    assert options.value("dtM") == "0.05" and options.get("dtm") is not None
    assert options.value("modified_newton") == "True"
    assert options.value("nothing", "fallback") == "fallback"
    options.add("dtM", 0.1)
    assert [row.value for row in options if row.keyword.lower() in {"dt", "dtm"}] == ["0.05", "0.1"]
    options.set("dtM", 0.02)
    assert [row.keyword for row in options].count("dtM") == 1 and "dt" not in {
        row.keyword for row in options
    }
    options.set("dynamic_solver", 1e-8, 1e-14, 30, 12)
    options.set("current", "uniform", 0.5, 0.0, 0.0)
    text = model.to_text()
    assert "dynamic_solver 1e-08 1e-14 30 12" in text
    assert "uniform 0.5 0.0 0.0 current" in text
    assert "0.02 dtM - Time step (s)" not in text and "0.02 dtM" in text
    assert options.remove("current") == 1 and "current" not in options and 3 not in options
    with pytest.raises(ValueError, match="unknown option keyword"):
        options.set("staticRelTol", 1.0)
    with pytest.raises(ValueError, match="takes one value"):
        options.set("dtM", 0.1, 0.2)
    with pytest.raises(ValueError, match="needs a value"):
        options.set("dtM")
    with pytest.raises(TypeError):
        options.set("dtM", None)
    with pytest.raises(TypeError):
        options.set(3, 1.0)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="cannot contain whitespace"):
        options.set("motionFile", "a b.txt")
    with pytest.raises(ValueError, match="must not contain"):
        options.set("dtM", 0.1, description="bad # comment")
    assert "OPTIONS" in repr(options) and len(options) > 0
    options.clear()
    assert len(options) == 0 and "OPTIONS" not in model.to_text(validate=False)


def test_wavetrain_rows_add_up() -> None:
    model = _chain_model()
    model.options.set("dtM", 0.1)
    model.options.set("TMax", 10.0)
    model.options.add("wavetrain", "jonswap", 4.0, 10.0, 3.3, 0.0, 0.0)
    model.options.add("wavetrain", "airy", 1.0, 20.0, 90.0)
    deck = model.to_deck_file()
    assert [row.keyword for row in deck.options].count("wavetrain") == 2


def test_output_list() -> None:
    model = _chain_model()
    outputs = model.outputs
    assert outputs[0] == "FairTen1" and len(outputs) == 3 and "fairten1" in outputs
    with pytest.raises(ValueError, match="already listed"):
        outputs.add("FAIRTEN1")
    with pytest.raises(ValueError, match="must not contain ','"):
        outputs.add("FairTen1,AnchTen1")
    with pytest.raises(TypeError):
        outputs.add(1)  # type: ignore[arg-type]
    outputs.add("NoSuchChannel9")
    assert model.references(model.lines[1]) == ("FairTen1", "AnchTen1")
    with pytest.raises(DeckFormatError, match="unsupported OUTPUT channel"):
        model.validate()
    outputs.clear()
    assert "OUTPUTS" not in model.to_text() and "OUTPUTS" in repr(outputs)


def test_copy_is_independent() -> None:
    model = _chain_model()
    twin = model.copy()
    twin.points[2].z = -40.0
    twin.lines[1].sections[0].line_type.mass = 1.0
    assert model.points[2].z == -50.0 and model.line_types["chain"].mass == 390.0
    assert twin.lines[1].end_a is twin.points[1]


# ------------------------------------------------------------------ error paths


def test_argument_and_reference_errors() -> None:
    model = _chain_model()
    other = _chain_model()
    with pytest.raises(ValueError, match="already exists"):
        model.add_point(1, "Fixed", 0.0, 0.0, 0.0)
    with pytest.raises(TypeError):
        model.add_point("1", "Fixed", 0.0, 0.0, 0.0)  # type: ignore[arg-type]
    with pytest.raises(KeyError, match="line type 'nope'"):
        model.add_line(5, 1, 2, "nope", length=1.0, num_segs=1)
    with pytest.raises(ValueError, match="together"):
        model.add_line(5, 1, 2, "chain", length=1.0)
    with pytest.raises(ValueError, match="rod end"):
        model.add_line(5, 1, "X9", "chain", length=1.0, num_segs=1)
    with pytest.raises(DeckReferenceError, match="not part of this model"):
        model.add_line(5, other.points[1], 2)
    with pytest.raises(DeckReferenceError):
        model.add_section(other.lines[1], "chain", 1.0, 1)
    with pytest.raises(DeckReferenceError):
        model.add_equivalent_buoyancy(other.line_types["chain"], 0.3, 1.0)
    with pytest.raises(DeckReferenceError):
        model.add_external_load(1, MoorDynBody(1, "Free", 0.0, 0.0, 0.0))
    with pytest.raises(DeckReferenceError):
        foreign = other.add_rod_type("x", diam=1.0, mass=1.0)
        model.add_rod(1, foreign, "Free", (0, 0, 0), (0, 0, 1), 1)
    with pytest.raises(KeyError):
        model.rod_end(3, "A")
    with pytest.raises(KeyError):
        model.add_point(3, "Body7", 0.0, 0.0, 0.0)
    with pytest.raises(ValueError, match="line-type name"):
        model.add_line_type("two	words", diam=1.0, mass=1.0, ea=1.0)
    with pytest.raises(ValueError, match="line-type name"):
        model.add_line_type(" leading", diam=1.0, mass=1.0, ea=1.0)
    # a row pointing outside the model is caught before rendering
    model.lines[1].end_b = other.points[2]
    with pytest.raises(DeckReferenceError):
        model.to_text()
    model.lines[1].end_b = "2"  # type: ignore[assignment]
    with pytest.raises(TypeError, match="Point or RodEnd"):
        model.to_text()


def test_render_errors_name_the_field() -> None:
    model = _chain_model()
    model.points[2].z = "deep"  # type: ignore[assignment]
    with pytest.raises(TypeError, match="point 2 must be a number"):
        model.to_text()
    point = model.points[2]
    point.z = -50.0
    point.id = 2.5  # type: ignore[assignment]
    with pytest.raises(TypeError, match="must be an integer"):
        model.to_text()
    with pytest.raises(TypeError):
        model.points[2.5]  # type: ignore[index]
    point.id = True
    assert model.points.get(1) is not None and model.points.get(2) is None
    with pytest.raises(TypeError, match="must be an integer"):
        model.to_text()


def test_render_errors_for_linked_types() -> None:
    model = _chain_model()
    model.points[2].type = "Body"
    with pytest.raises(ValueError, match="does not match"):
        model.to_text()
    model.points[2].type = "Fixed"
    model.add_rod_type("can", diam=1.0, mass=10.0)
    rod = model.add_rod(1, "can", "Free", (0.0, 0.0, -1.0), (0.0, 0.0, -2.0), 1)
    rod.type = "Body"
    with pytest.raises(ValueError, match="needs its body"):
        model.to_text()
    rod.type = "Free"
    rod.body = Body(1, "Rigid6", 0.0, 0.0, 0.0)
    with pytest.raises(DeckReferenceError):
        model.to_text()
    rod.body = model.add_body(1, "Point3", 0.0, 0.0, -5.0, mass=1.0)
    with pytest.raises(ValueError, match="only a Body/BodyPinned rod"):
        model.to_text()
    rod.body = None
    rod.end_a = (0.0, 0.0)  # type: ignore[assignment]
    with pytest.raises(ValueError, match="sequence of 3 numbers"):
        model.to_text()
    rod.end_a = (0.0, 0.0, -1.0)
    model.rod_types["can"].cd_ax = 0.1
    with pytest.raises(ValueError, match="cd_ax and ca_ax"):
        model.to_text()
    model.rod_types["can"].cd_ax = None
    model.line_types["chain"].ba = ()
    with pytest.raises(ValueError, match="must not be empty"):
        model.to_text()
    model.line_types["chain"].ba = 0.0
    model.title = "bad --- title"
    with pytest.raises(ValueError, match="---"):
        model.to_text()


def test_constructor_and_title_fallbacks() -> None:
    with pytest.raises(TypeError, match="caller_driven"):
        DeckModel(caller_driven=1)  # type: ignore[arg-type]
    text = _chain_model().to_text().split("\n", 2)[2]
    assert DeckModel.from_text(text).title == "CableDyn deck"
    model = _chain_model()
    model.title = ""
    assert model.to_text().splitlines()[1] == "CableDyn deck"
    gravity = model.options.get("g")
    assert gravity is not None and gravity.value == "9.80665"


def test_objects_given_by_reference_and_farm_round_trip() -> None:
    model = DeckModel.new(title="farm", caller_driven=True)
    model.add_line_type("chain", diam=0.1, mass=20.0, ea=1.0e9, ba=-1.0, cdn=1.2, cdt=0.2, can=1.0)
    model.add_turbine(1, 0.0, 0.0, 0.0, ptfm=(1.0, 0, 0, 0, 0, 5.0))
    model.add_point(1, "Turbine1", 0.0, 0.0, -10.0)
    model.add_point(2, "Fixed", 300.0, 0.0, -100.0)
    model.add_line(1, 1, 2, "chain", length=380.0, num_segs=20)
    loaded = DeckModel.from_text(model.to_text(), caller_driven=True)
    assert loaded.turbines[1].ptfm == (1.0, 0.0, 0.0, 0.0, 0.0, 5.0)
    assert loaded.points[1].turbine == 1 and loaded.points[1].type == "Turbine"
    # objects of the same model are accepted wherever an id or name is
    can = model.add_rod_type("can", diam=1.0, mass=10.0)
    rod = model.add_rod(1, can, "Free", (0.0, 0.0, -1.0), (0.0, 0.0, -2.0), 1)
    end = model.rod_end(rod, "A")
    line = model.add_line(2, end, 2)
    assert line.end_a is end
    model.add_section(line, model.line_types["chain"], 50.0, 5)


def test_cascade_skips_referrers_already_removed() -> None:
    model = _chain_model()
    model.options.set("dtM", 0.01)
    model.options.set("TMax", 1.0)
    # the failure row refers to point 1 and to the line on point 1: removing the
    # line first (through the point cascade) must not trip the second visit
    model.add_failure(1, 1, fail_time=1.0)
    model.remove(model.points[1], cascade=True)
    assert model.failures == () and len(model.lines) == 0
    line = model.add_line(3, model.add_point(9, "Coupled", 0.0, 0.0, 0.0), 2)
    assert model.references(line) == ()


def test_rows_render_errors_for_empty_line_lists() -> None:
    model = _chain_model()
    control = model.add_control(1, 1)
    control.lines.clear()
    with pytest.raises(ValueError, match="at least one line"):
        model.to_text()
    model.remove(control)
    section = model.lines[1].sections[0]
    with pytest.raises(DeckReferenceError, match="Section"):
        model.remove(model.line_types["chain"])
    assert section in model.references(model.line_types["chain"])


def test_title_is_read_only_after_the_banner() -> None:
    text = _chain_model().to_text()
    body = text.split("\n", 2)[2]
    banner_only = text.split("\n", 1)[0] + "\n" + body
    assert DeckModel.from_text(banner_only).title == "CableDyn deck"
    preamble = "preamble" + chr(10) + text
    assert DeckModel.from_text(preamble).title == "single chain catenary"


def test_torque_tension_coupling_round_trips_in_the_gj_column(tmp_path: Path) -> None:
    model = _chain_model(tmp_path)
    cable = model.add_line_type(
        "cable",
        diam=0.2,
        mass=40.0,
        ea=5.0e8,
        ei=1.0e4,
        gas=1.0e8,
        gj=(1.0e4, 2.0e5),
        irt=0.1,
        irn=0.05,
    )
    assert cable.gj == (1.0e4, 2.0e5)
    target = model.save(tmp_path / "coupled.dat")
    deck = DeckFile.read(target)
    row = next(r for r in deck.line_types if r.tokens[0] == "cable")
    assert [float(v) for v in row.tokens[7].split("|")] == [1.0e4, 2.0e5]
    loaded = DeckModel.load(target)
    assert next(t for t in loaded.line_types if t.name == "cable").gj == (1.0e4, 2.0e5)


def test_torsional_damping_round_trips_in_the_gj_column(tmp_path: Path) -> None:
    model = _chain_model(tmp_path)
    cable = model.add_line_type(
        "cable",
        diam=0.2,
        mass=40.0,
        ea=5.0e8,
        ei=1.0e4,
        gas=1.0e8,
        gj=(1.0e4, 0.0, -0.02),
        irt=0.1,
        irn=0.05,
    )
    assert cable.gj == (1.0e4, 0.0, -0.02)
    target = model.save(tmp_path / "damped.dat")
    deck = DeckFile.read(target)
    row = next(r for r in deck.line_types if r.tokens[0] == "cable")
    assert [float(v) for v in row.tokens[7].split("|")] == [1.0e4, 0.0, -0.02]
    loaded = DeckModel.load(target)
    assert next(t for t in loaded.line_types if t.name == "cable").gj == (1.0e4, 0.0, -0.02)


@pytest.mark.parametrize(
    ("gj", "ei", "message"),
    [
        ("1.0e4|1.0e7", "1.0e4", r"K\^2 < EA GJ"),
        ("1.0e4|1.0e3", "0.0", "needs a finite-EI cable"),
        ("1.0e4|1.0e3|5.0|1.0", "1.0e4", r"takes GJ, GJ\|K or GJ\|K\|Bt"),
        ("1.0e4|0|5.0", "0.0", "torsional damping"),
    ],
)
def test_torque_tension_coupling_refusals(tmp_path: Path, gj: str, ei: str, message: str) -> None:
    model = _chain_model(tmp_path)
    model.add_line_type(
        "cable", diam=0.2, mass=40.0, ea=5.0e8, ei=1.0e4, gas=1.0e8, gj=1.0e4, irt=0.1, irn=0.05
    )
    text = model.to_text(validate=False)
    bad = re.sub(
        r"^cable\s.*$",
        f"cable 0.2 40.0 5.0e8 0.0 {ei} 1.0e8 {gj} 0.1 0.05 0.0 0.0 0.0 0.0",
        text,
        flags=re.M,
    )
    path = tmp_path / "bad.dat"
    path.write_text(bad, encoding="utf-8")
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(path)
