"""Tests for the real plan-set acquirer/indexer (datasets.realsets).

Network is monkeypatched; PDFs are generated in-memory — fast and offline.
"""

from __future__ import annotations

import datasets.realsets as rs
from datasets.realsets import (
    MISSOURI,
    _is_drawing_set,
    _sanitize,
    index_pdf,
    rasterize_sheet,
    scrape,
)


def test_is_drawing_set_keeps_plans_rejects_specs_ifb_addenda() -> None:
    assert _is_drawing_set("_T2612-01 Final Bid Plans.pdf")
    assert _is_drawing_set("SGO BID SET - Drawings.pdf")
    assert not _is_drawing_set("T2523-01 Final specs.pdf")
    assert not _is_drawing_set("REBID T2421-01 - IFB.pdf")
    assert not _is_drawing_set("Addendum 1.pdf")
    assert not _is_drawing_set("Instructions to bidders.pdf")


def test_sanitize_makes_a_safe_name() -> None:
    assert _sanitize("_T2612-01 Final Bid Plans.pdf") == "T2612-01_Final_Bid_Plans.pdf"
    assert (
        _sanitize("REBID%20T2421-01%20-%20Final%20Plans.pdf") == "REBID_T2421-01_-_Final_Plans.pdf"
    )


def test_scrape_keeps_only_drawing_sets(monkeypatch) -> None:
    base = "https://oa.mo.gov/sites/default/files/bid-opportunities/"
    page = (
        f'<a href="{base}_T2612-01 Final Bid Plans.pdf">plans</a>'
        f'<a href="{base}T2523-01 Final specs.pdf">specs</a>'
        f'<a href="{base}REBID T2421-01 - IFB.pdf">ifb</a>'
    )
    monkeypatch.setattr(rs, "_fetch", lambda url, timeout=60: page.encode())
    refs = scrape(MISSOURI)
    assert len(refs) == 1
    assert refs[0].project == "T2612-01"
    assert refs[0].filename == "T2612-01_Final_Bid_Plans.pdf"
    assert refs[0].url.endswith(".pdf")


def _make_pdf(path, sheets: list[str]) -> None:
    import fitz

    doc = fitz.open()
    for label in sheets:
        page = doc.new_page()
        page.insert_text((72, 72), f"SHEET  {label}")
    doc.save(str(path))
    doc.close()


def test_index_pdf_recovers_sheet_numbers_and_disciplines(tmp_path) -> None:
    path = tmp_path / "T1234-01 Final Bid Plans.pdf"
    _make_pdf(path, ["E-101", "A-201", "S-100"])
    rec = index_pdf(path)
    assert rec.project == "T1234-01"
    assert rec.n_pages == 3
    assert rec.error is None
    letters = {p.discipline_letter for p in rec.pages if p.discipline_letter}
    assert {"E", "A", "S"} <= letters
    assert rec.by_discipline.get("E") == 1
    # discipline name is mapped from the letter (E -> electrical)
    e_page = next(p for p in rec.pages if p.discipline_letter == "E")
    assert e_page.discipline == "electrical"


def test_index_pdf_records_error_on_bad_file(tmp_path) -> None:
    bad = tmp_path / "T9999-99 Plans.pdf"
    bad.write_bytes(b"not a pdf")
    rec = index_pdf(bad)
    assert rec.error is not None  # recorded, not raised


def test_rasterize_sheet_writes_png(tmp_path) -> None:
    path = tmp_path / "x Plans.pdf"
    _make_pdf(path, ["E-101"])
    out = rasterize_sheet(path, 0, tmp_path / "out.png", dpi=150)
    assert out.exists() and out.stat().st_size > 0
