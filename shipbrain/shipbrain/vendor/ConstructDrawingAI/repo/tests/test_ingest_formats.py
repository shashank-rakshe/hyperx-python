"""End-to-end L0 ingestion tests on programmatically generated fixtures.

Each format is exercised by generating a tiny file, ingesting it into the CIR, and
checking the structure + synthetic-owned/commercial stamping. The relevant parser
library is skipped-if-missing so the suite degrades gracefully.
"""

from __future__ import annotations

from pathlib import Path

import pytest

import cir
import ingest
from cir import DataLane, DrawingSet, LicenseProvenance

PROV = {
    "license_provenance": LicenseProvenance.SYNTHETIC_OWNED,
    "data_lane": DataLane.COMMERCIAL,
}


def _assert_commercial_stamped(ds: DrawingSet) -> None:
    assert ds.license_provenance is LicenseProvenance.SYNTHETIC_OWNED
    assert ds.data_lane is DataLane.COMMERCIAL
    for entity in ds.iter_entities():
        assert entity.license_provenance is LicenseProvenance.SYNTHETIC_OWNED
        assert entity.data_lane is DataLane.COMMERCIAL
    ds.assert_commercial_safe()  # synthetic-owned is commercial-safe


def test_dxf_ingest_roundtrips(tmp_path: Path) -> None:
    ezdxf = pytest.importorskip("ezdxf")
    path = tmp_path / "plan.dxf"
    doc = ezdxf.new()
    msp = doc.modelspace()
    msp.add_line((0, 0), (100, 0), dxfattribs={"layer": "WALLS"})
    msp.add_line((100, 0), (100, 50), dxfattribs={"layer": "WALLS"})
    msp.add_circle((50, 25), radius=10, dxfattribs={"layer": "SYMBOLS"})
    msp.add_text("E-201", dxfattribs={"insert": (10, 40)})
    block = doc.blocks.new(name="RECEPT")
    block.add_circle((0, 0), radius=1)
    msp.add_blockref("RECEPT", (20, 20))
    doc.saveas(path)

    ds = ingest.ingest(path, **PROV)
    assert ds.source is not None and ds.source.file_type == "dxf" and ds.source.is_vector
    _assert_commercial_stamped(ds)
    assert ds.entity_count() >= 4

    labels = {e.label for e in ds.iter_entities()}
    assert "RECEPT" in labels  # the block insert became a labeled symbol
    texts = {span.text for e in ds.iter_entities() for span in e.text_spans}
    assert "E-201" in texts

    # normalized geometry stays within the unit sheet frame
    for entity in ds.iter_entities():
        if entity.geometry:
            for p in entity.geometry.points:
                assert -0.001 <= p.x <= 1.001 and -0.001 <= p.y <= 1.001

    # exact CIR round trip
    assert cir.from_json(DrawingSet, cir.to_json(ds)) == ds


def test_pdf_vector_ingest(tmp_path: Path) -> None:
    fitz = pytest.importorskip("fitz")
    path = tmp_path / "sheet.pdf"
    doc = fitz.open()
    page = doc.new_page(width=612, height=792)
    page.insert_text((72, 72), "PROJECT EXAMPLE", fontsize=12)
    page.insert_text((72, 720), 'SHEET E-201   SCALE: 1/4" = 1\'-0"   SEE 3/A-501', fontsize=10)
    page.draw_line((100, 100), (300, 100))
    page.draw_rect(fitz.Rect(100, 200, 300, 400))
    page2 = doc.new_page(width=612, height=792)
    page2.insert_text((72, 72), "SHEET S-100 GENERAL NOTES", fontsize=12)
    doc.save(str(path))
    doc.close()

    ds = ingest.ingest(path, **PROV)
    assert ds.source is not None and ds.source.file_type == "pdf" and ds.source.page_count == 2
    _assert_commercial_stamped(ds)

    sheet = ds.sheets[0]
    assert sheet.sheet_number == "E-201"
    assert sheet.discipline is cir.Discipline.ELECTRICAL
    assert sheet.scale is not None and sheet.scale.ratio == pytest.approx(0.25 / 12)
    assert any(ref.target_sheet == "A-501" for ref in sheet.cross_references)
    assert sheet.attributes["origin"] == "vector"
    assert sheet.views[0].entities  # text + vector primitives extracted
    assert ds.sheets[1].sheet_number == "S-100"


def test_pdf_raster_fallback(tmp_path: Path) -> None:
    fitz = pytest.importorskip("fitz")
    pytest.importorskip("PIL")
    from PIL import Image

    scan = tmp_path / "scan.png"
    Image.new("RGB", (800, 1000), (255, 255, 255)).save(scan)
    path = tmp_path / "scan.pdf"
    doc = fitz.open()
    page = doc.new_page(width=612, height=792)
    page.insert_image(page.rect, filename=str(scan))  # full-page image, no text/vectors
    doc.save(str(path))
    doc.close()

    ds = ingest.ingest(path, **PROV)
    sheet = ds.sheets[0]
    assert sheet.attributes["origin"] == "raster"
    assert sheet.attributes["needs_perception"] is True
    assert sheet.attributes["dpi"] == 300
    assert sheet.views[0].entities == []  # no fabricated entities for a scanned page
    _assert_commercial_stamped(ds)


def test_ifc_ingest(tmp_path: Path) -> None:
    ifcopenshell = pytest.importorskip("ifcopenshell")
    path = tmp_path / "model.ifc"
    model = ifcopenshell.file(schema="IFC4")
    model.create_entity("IfcWall", GlobalId=ifcopenshell.guid.new(), Name="Wall-1")
    model.create_entity("IfcWall", GlobalId=ifcopenshell.guid.new(), Name="Wall-2")
    model.create_entity("IfcDoor", GlobalId=ifcopenshell.guid.new(), Name="Door-1")
    model.write(str(path))

    ds = ingest.ingest(path, **PROV)
    assert ds.source is not None and ds.source.file_type == "ifc"
    _assert_commercial_stamped(ds)
    classes = sorted(e.ifc_class for e in ds.iter_entities() if e.ifc_class)
    assert classes == ["IfcDoor", "IfcWall", "IfcWall"]


def test_image_ingest(tmp_path: Path) -> None:
    pytest.importorskip("PIL")
    from PIL import Image

    path = tmp_path / "scan.png"
    Image.new("RGB", (2000, 1500), (255, 255, 255)).save(path)

    ds = ingest.ingest(path, **PROV)
    assert ds.source is not None and ds.source.file_type == "image"
    sheet = ds.sheets[0]
    assert sheet.attributes["origin"] == "raster"
    assert sheet.attributes["needs_perception"] is True
    _assert_commercial_stamped(ds)


def test_unknown_extension_is_rejected(tmp_path: Path) -> None:
    bad = tmp_path / "notes.txt"
    bad.write_text("hello", encoding="utf-8")
    with pytest.raises(NotImplementedError):
        ingest.ingest(bad, **PROV)
