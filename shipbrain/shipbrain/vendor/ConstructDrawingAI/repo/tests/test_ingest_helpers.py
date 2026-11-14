"""Tests for the deterministic L0 helpers (scale, sheets, normalize, tiling)."""

from __future__ import annotations

from pathlib import Path

import pytest

from cir import Discipline
from ingest.normalize import Bounds, Normalizer
from ingest.scale import parse_scale, resolve_px
from ingest.sheets import (
    discipline_for_letter,
    find_cross_references,
    parse_sheet_number,
    parse_title_block,
)
from ingest.tiling import tile_image


def test_parse_scale_imperial() -> None:
    scale = parse_scale('1/4" = 1\'-0"')
    assert scale is not None
    assert scale.ratio == pytest.approx(0.25 / 12)
    assert scale.real_world_unit == "ft"


def test_parse_scale_engineering() -> None:
    scale = parse_scale("1\" = 20'")
    assert scale is not None and scale.ratio == pytest.approx(1 / 240)


def test_parse_scale_metric() -> None:
    scale = parse_scale("1:50")
    assert scale is not None and scale.ratio == pytest.approx(0.02)
    assert scale.real_world_unit == "m"


def test_parse_scale_not_to_scale_and_garbage() -> None:
    assert parse_scale("NTS") is None
    assert parse_scale("NOT TO SCALE") is None
    assert parse_scale("just some words") is None


def test_resolve_px_imperial() -> None:
    scale = resolve_px(parse_scale('1/4" = 1\'-0"'), dpi=300)  # type: ignore[arg-type]
    # 1 ft real -> 0.25 in on paper -> 75 px at 300 DPI
    assert scale.px_per_real_unit == pytest.approx(75.0)


def test_sheet_number_and_discipline() -> None:
    assert parse_sheet_number("SHEET A-101") == "A-101"
    assert parse_sheet_number("E201 POWER PLAN") == "E-201"
    assert discipline_for_letter("E") is Discipline.ELECTRICAL
    assert discipline_for_letter("S") is Discipline.STRUCTURAL


def test_find_cross_references() -> None:
    refs = find_cross_references("see detail 3/A-501 and section A/S-101")
    pairs = {(r.target_detail, r.target_sheet) for r in refs}
    assert ("3", "A-501") in pairs
    assert ("A", "S-101") in pairs


def test_parse_title_block() -> None:
    block, scale = parse_title_block('PROJECT X\nSHEET E-201\nSCALE: 1/4" = 1\'-0"')
    assert block.sheet_number == "E-201"
    assert block.discipline is Discipline.ELECTRICAL
    assert scale is not None and scale.ratio == pytest.approx(0.25 / 12)


def test_normalizer_flips_y() -> None:
    norm = Normalizer(Bounds(0.0, 0.0, 10.0, 20.0), flip_y=True)
    top = norm.point(0.0, 20.0)  # y_max -> top of sheet
    assert top.x == pytest.approx(0.0) and top.y == pytest.approx(0.0)
    bottom = norm.point(0.0, 0.0)  # y_min -> bottom
    assert bottom.y == pytest.approx(1.0)


def test_tiling_produces_overlapping_tiles_and_global_view(tmp_path: Path) -> None:
    from PIL import Image

    big = tmp_path / "big.png"
    Image.new("RGB", (4000, 3000)).save(big)
    tiled = tile_image(big, sheet_id="big", tile_size=1536, overlap=192)
    assert len(tiled.tiles) > 1
    assert max(tiled.global_view.size) <= 1024
    assert tiled.full_width == 4000 and tiled.full_height == 3000
    # every tile carries a TileRef with a stable id and sheet back-reference
    assert all(t.ref.tile_id.startswith("big:") for t in tiled.tiles)
    assert tiled.refs[tiled.tiles[0].ref.tile_id] is tiled.tiles[0].ref
