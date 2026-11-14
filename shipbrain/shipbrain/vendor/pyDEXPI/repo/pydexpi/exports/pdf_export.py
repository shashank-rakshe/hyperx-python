"""SVG-to-PDF conversion utility.

Converts SVG strings produced by the pyDEXPI SVG exporter into PDF format
using ``svglib`` + ``reportlab`` (pure-Python).

Install the optional extra to enable PDF conversion::

    pip install pydexpi[pdf]
"""

from __future__ import annotations

import tempfile
from pathlib import Path

from pydexpi.attribution import generator_string


def _check_pdf_deps() -> None:
    """Raise ImportError with install instructions if svglib/reportlab are missing."""
    missing: list[str] = []
    try:
        import svglib  # noqa: F401
    except ImportError:
        missing.append("svglib")
    try:
        import reportlab  # noqa: F401
    except ImportError:
        missing.append("reportlab")
    if missing:
        raise ImportError(
            f"PDF export requires the {', '.join(repr(m) for m in missing)} "
            f"package{'s' if len(missing) > 1 else ''}. "
            "Install with:  pip install pydexpi[pdf]"
        ) from None


def svg_to_pdf(svg_string: str, output_path: str | Path) -> None:
    """Convert an SVG string to a PDF file using svglib + reportlab.

    Parameters
    ----------
    svg_string : str
        The SVG content as a string.
    output_path : str | Path
        Destination file path for the PDF.

    Raises
    ------
    ImportError
        If ``svglib`` or ``reportlab`` is not installed.
    """
    _check_pdf_deps()

    from reportlab.graphics import renderPDF
    from reportlab.pdfgen.canvas import Canvas
    from svglib.svglib import svg2rlg

    generator = generator_string()

    # svglib requires a file path, so write to a temporary file.
    # Use try/finally from the start so the temp file is always cleaned up,
    # even if tmp.write() raises (e.g. encoding error or disk full).
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".svg", encoding="utf-8", delete=False
    ) as tmp:
        tmp_path = tmp.name

    try:
        Path(tmp_path).write_text(svg_string, encoding="utf-8")
        drawing = svg2rlg(tmp_path)
        if drawing is None:
            raise ValueError(
                "svglib could not parse the SVG content. The SVG may contain unsupported features."
            )
        try:
            # Drive the canvas directly instead of calling `renderPDF.drawToFile`.
            # `drawToFile` exposes no document-info arguments, and its `canvasMaker`
            # seam -- the only way in to set Producer/Creator before save -- was
            # removed in reportlab 5.0, where it builds its own `Canvas` and silently
            # swallows the argument. This is `drawToFile`'s own autoSize=1 path,
            # minus the title, and works on both 4.x and 5.x.
            scaled = renderPDF.renderScaledDrawing(drawing)
            canvas = Canvas(str(output_path), pagesize=(scaled.width, scaled.height))
            canvas.setCreator(generator)
            canvas.setProducer(generator)
            renderPDF.draw(scaled, canvas, 0, 0)
            canvas.showPage()
            canvas.save()
        except ZeroDivisionError:
            raise ValueError(
                "PDF rendering failed due to a non-invertible transform in the SVG "
                "(e.g. scale(0)). This typically means the SVG contains degenerate "
                "elements with zero-size scale factors. Regenerate the SVG with "
                "the latest pyDEXPI version, which skips such elements, or use "
                "save_png() which handles these transforms correctly."
            ) from None
    finally:
        Path(tmp_path).unlink(missing_ok=True)
