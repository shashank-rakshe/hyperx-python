"""Page classification and rendering on small synthetic PDFs."""

import pytest

from pidkg.pdf import probe_pdf, render_page, rotate_norm_bbox, text_runs, tile_grid


def _write_pdf(path, content: bytes, with_font: bool) -> None:
    """Write a minimal one-page PDF with the given content stream."""
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] /Contents 4 0 R"
        + (b" /Resources << /Font << /F1 5 0 R >> >>" if with_font else b"") + b" >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
    ]
    if with_font:
        objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    path.write_bytes(bytes(out))


def _lines(n: int) -> bytes:
    return b"\n".join(b"%d %d m %d %d l S" % (50 + i, 50, 50 + i, 500) for i in range(n))


@pytest.fixture
def vector_text_pdf(tmp_path):
    text = b"BT /F1 10 Tf 100 300 Td (FIT-0502 TK-100 P-101 LIC-200 FEED TANK TRANSFER PUMP) Tj ET\n"
    text += b"BT /F1 10 Tf 100 320 Td (6in-PW-001 MAKEUP WATER SUPPLY TO CLARIFIER) Tj ET\n"
    p = tmp_path / "vector_text.pdf"
    _write_pdf(p, _lines(250) + b"\n" + text, with_font=True)
    return p


@pytest.fixture
def vector_outlined_pdf(tmp_path):
    p = tmp_path / "outlined.pdf"
    _write_pdf(p, _lines(300), with_font=False)
    return p


@pytest.fixture
def raster_pdf(tmp_path):
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (1650, 1275), "white")
    d = ImageDraw.Draw(img)
    for x in range(100, 1500, 50):
        d.line([(x, 100), (x, 1100)], fill="black", width=3)
    p = tmp_path / "scan.pdf"
    img.save(p, resolution=150)
    return p


def test_classifies_vector_text(vector_text_pdf):
    (probe,) = probe_pdf(str(vector_text_pdf))
    assert probe.page_class == "vector_text"
    assert probe.text_chars >= 50


def test_classifies_vector_outlined(vector_outlined_pdf):
    (probe,) = probe_pdf(str(vector_outlined_pdf))
    assert probe.page_class == "vector_outlined"
    assert probe.text_chars == 0


def test_classifies_raster(raster_pdf):
    (probe,) = probe_pdf(str(raster_pdf))
    assert probe.page_class == "raster"
    assert probe.max_image_coverage > 0.9
    assert probe.effective_image_dpi == pytest.approx(150, rel=0.05)
    assert any("low scan resolution" in n for n in probe.notes)


def test_render_vector_and_raster(vector_outlined_pdf, raster_pdf):
    img = render_page(str(vector_outlined_pdf), 1, "vector_outlined", 0, vector_long_edge=2000)
    assert max(img.size) == 2000
    img = render_page(str(raster_pdf), 1, "raster", 0, raster_long_edge=3000)
    assert img.mode == "L"
    assert max(img.size) == pytest.approx(3000, abs=2)


def test_text_runs_have_positions(vector_text_pdf):
    runs = text_runs(str(vector_text_pdf), 1)
    joined = " ".join(r["text"] for r in runs)
    assert "FIT-0502" in joined
    for r in runs:
        x0, y0, x1, y1 = r["bbox"]
        assert 0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1


def test_tile_grid_covers_image_with_overlap():
    tiles = tile_grid(5000, 3864, tile=1400, overlap=200)
    assert tiles[0]["px"][:2] == [0, 0]
    assert max(t["px"][2] for t in tiles) == 5000
    assert max(t["px"][3] for t in tiles) == 3864
    row1 = [t for t in tiles if t["row"] == 1]
    for a, b in zip(row1, row1[1:]):
        assert a["px"][2] - b["px"][0] >= 200


@pytest.mark.parametrize("rot, expected", [
    (0, [0.1, 0.2, 0.3, 0.4]),
    (90, [0.6, 0.1, 0.8, 0.3]),
    (180, [0.7, 0.6, 0.9, 0.8]),
    (270, [0.2, 0.7, 0.4, 0.9]),
])
def test_rotate_norm_bbox(rot, expected):
    assert rotate_norm_bbox([0.1, 0.2, 0.3, 0.4], rot) == pytest.approx(expected)


def test_parse_pages_uses_probe_selection_by_default():
    from render_pages import parse_pages

    assert parse_pages(None, 5) == [1, 2, 3, 4, 5]
    assert parse_pages(None, 70, default=[47, 48, 60]) == [47, 48, 60]
    assert parse_pages("2-3,5", 5, default=[1]) == [2, 3, 5]
    assert parse_pages("4-9", 5) == [4, 5]


def test_probe_records_selected_pages(vector_outlined_pdf, tmp_path):
    import json
    import subprocess
    import sys
    from pathlib import Path

    script = Path(__file__).resolve().parents[1] / "skills" / "pid-to-kg" / "scripts" / "probe_pdf.py"
    work = tmp_path / "work"
    run = subprocess.run([sys.executable, str(script), str(vector_outlined_pdf), "--work", str(work),
                          "--pages", "1"], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    assert json.loads((work / "manifest.json").read_text(encoding="utf-8"))["selected_pages"] == [1]
    bad = subprocess.run([sys.executable, str(script), str(vector_outlined_pdf), "--work", str(work),
                          "--pages", "9"], capture_output=True, text=True)
    assert bad.returncode == 2
