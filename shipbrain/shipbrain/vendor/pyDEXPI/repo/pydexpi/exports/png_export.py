"""SVG-to-PNG conversion utility.

Converts SVG strings produced by the pyDEXPI SVG exporter into PNG format
using ``resvg`` (pure-Rust, no system C dependencies).

Install the optional extra to enable PNG conversion::

    pip install pydexpi[png]
"""

from __future__ import annotations

from pathlib import Path


def _check_png_deps() -> None:
    """Raise ImportError with install instructions if resvg is missing."""
    try:
        import resvg  # noqa: F401
    except ImportError:
        raise ImportError(
            "PNG export requires the 'resvg' package. Install it with:  pip install pydexpi[png]"
        ) from None


def svg_to_png(svg_string: str, output_path: str | Path, scale: float = 1.0) -> None:
    """Convert an SVG string to a PNG file using resvg.

    Parameters
    ----------
    svg_string : str
        The SVG content as a string.
    output_path : str | Path
        Destination file path for the PNG.
    scale : float, optional
        Uniform scale factor applied to the output dimensions.
        ``1.0`` preserves the SVG's native pixel size; ``4.0`` gives
        approximately 300 DPI for an A3-sized diagram (default ``1.0``).

    Raises
    ------
    ImportError
        If ``resvg`` is not installed.
    """
    _check_png_deps()

    import resvg
    from resvg import usvg

    opts = usvg.Options.default()
    opts.load_system_fonts()
    tree = usvg.Tree.from_str(svg_string, opts)

    w, h = tree.int_size()
    out_w, out_h = int(w * scale), int(h * scale)
    # Row-major affine scale transform: (a, b, c, d, e, f) == (sx, kx, tx, ky, sy, ty)
    transform = (float(scale), 0.0, 0.0, 0.0, float(scale), 0.0)
    png_data: bytes = resvg.render(tree, transform, bg_size=(out_w, out_h))

    Path(output_path).write_bytes(png_data)
