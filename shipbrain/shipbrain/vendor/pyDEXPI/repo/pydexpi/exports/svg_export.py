"""Drawing toolkit for DEXPI diagrams and shapes.

This module provides functionality to convert DEXPI diagrams and shapes to SVG format.
It consolidates drawing-related functionality into a single, cohesive toolkit.

PNG and PDF export are delegated to the dedicated modules in this package::

    pydexpi.exports.png_export   -- SVG → PNG via resvg
    pydexpi.exports.pdf_export   -- SVG → PDF via svglib + reportlab
"""

import math
import os
from abc import ABC, abstractmethod
from pathlib import Path

from lxml import etree

from pydexpi.attribution import generator_comment
from pydexpi.pydexpi_classes import (
    Color,
    ConnectorLine,
    DashStyle,
    Diagram,
    Ellipse,
    EllipseArc,
    FillStyle,
    GraphicalPrimitive,
    NodePosition,
    Point,
    Polygon,
    PolyLine,
    RepresentationGroup,
    RepresentationTypeGroup,
    Shape,
    ShapeCatalogue,
    ShapeUsage,
    Stroke,
    Text,
)


def _rotated_half_extent(ellipse) -> tuple[float, float]:
    """Half the width and height of the box enclosing an ellipse turned by its `rotation`.

    The unrotated semi-axes understate a turned ellipse's extent, and a viewBox built from them
    crops it.
    """
    a, b = ellipse.horizontalSemiAxis, ellipse.verticalSemiAxis
    r = math.radians(ellipse.rotation or 0.0)
    return math.hypot(a * math.cos(r), b * math.sin(r)), math.hypot(
        a * math.sin(r), b * math.cos(r)
    )


class SvgRenderer:
    """Core SVG rendering functionality without abstract methods.

    This class contains all the concrete implementation for converting DEXPI
    elements to SVG format. It handles coordinate conversion, primitive conversion,
    bounds management, and SVG generation. Use this class via composition in
    classes that need SVG rendering capabilities.
    """

    # Constants for default styles and A3 dimensions (in mm)
    A3_WIDTH = 420.0  # mm
    A3_HEIGHT = 297.0  # mm

    def __init__(self, padding: float = 0.0, pretty: bool = False):
        """Initialize the renderer with optional padding and pretty mode.

        Args:
            padding: Extra space around the drawing in SVG units
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        self.padding = padding
        self.pretty = pretty
        self.line_width_multiplier = 0.3 if pretty else 1.0
        self.zoom = 1.0  # Will be calculated later if pretty is True
        self.initial_bounds: tuple[float, float, float, float] | None = None
        self.min_x = float("inf")
        self.min_y = float("inf")
        self.max_x = float("-inf")
        self.max_y = float("-inf")

    def to_svg_y(self, y: float) -> float:
        """Convert DEXPI Y coordinate to SVG Y coordinate.

        pyDEXPI's canonical diagram coordinate space is Y-down, same as SVG, so no
        conversion is needed here. Loaders are responsible for normalizing into this
        space: Proteus files carry Y-up drawing coordinates, which the Proteus parser
        flips at load time (see ``proteus_serializer``); DEXPI-native XML/JSON already
        stores Y-down coordinates.

        Args:
            y: Y coordinate in the canonical (Y-down) DEXPI coordinate system

        Returns:
            float: Y coordinate in SVG coordinate system (unchanged)
        """
        return y

    def calculate_zoom_for_a3(self) -> float:
        """Calculate the zoom factor to fit content within A3 dimensions.

        Returns:
            float: Zoom factor to scale the content to fit A3 (420mm x 297mm)
        """
        # Calculate content dimensions
        content_width = self.max_x - self.min_x + 2 * self.padding
        content_height = self.max_y - self.min_y + 2 * self.padding

        # Calculate zoom factors for both dimensions
        zoom_x = self.A3_WIDTH / content_width if content_width > 0 else 1.0
        zoom_y = self.A3_HEIGHT / content_height if content_height > 0 else 1.0

        # Return the smaller zoom to ensure content fits within A3
        return min(zoom_x, zoom_y)

    def consolidate_bounds(self, other: "SvgRenderer") -> None:
        """Consolidate bounding box with another renderer's bounds.

        Use this method when incorporating elements from another renderer
        to ensure the bounding box encompasses all elements.

        Args:
            other: Another SvgRenderer instance whose bounds should be included
        """
        self.min_x = min(self.min_x, other.min_x)
        self.min_y = min(self.min_y, other.min_y)
        self.max_x = max(self.max_x, other.max_x)
        self.max_y = max(self.max_y, other.max_y)

    def set_initial_bounds(self, min_x: float, min_y: float, max_x: float, max_y: float) -> None:
        """Set bounds that every reset restores, in DEXPI model coordinates.

        Use this for a drawing's declared extents (e.g. the sheet size), so the rendered
        viewBox covers at least this area even when few primitives are drawn. The Y values
        are mapped through `to_svg_y` so the stored bounds live in SVG coordinate space.

        Args:
            min_x: Minimum X of the extent in model coordinates
            min_y: Minimum Y of the extent in model coordinates
            max_x: Maximum X of the extent in model coordinates
            max_y: Maximum Y of the extent in model coordinates
        """
        y_0, y_1 = self.to_svg_y(min_y), self.to_svg_y(max_y)
        self.initial_bounds = (min_x, min(y_0, y_1), max_x, max(y_0, y_1))
        self.reset_bounds()

    def reset_bounds(self) -> None:
        """Reset the bounding box coordinates to the initial bounds, if set."""
        if self.initial_bounds is not None:
            self.min_x, self.min_y, self.max_x, self.max_y = self.initial_bounds
        else:
            self.min_x = float("inf")
            self.min_y = float("inf")
            self.max_x = float("-inf")
            self.max_y = float("-inf")

    def update_bounds(self, x: float, y: float) -> None:
        """Update the bounding box."""
        self.min_x = min(self.min_x, x)
        self.min_y = min(self.min_y, y)
        self.max_x = max(self.max_x, x)
        self.max_y = max(self.max_y, y)

    def get_bounds(self) -> tuple[tuple[float, float], tuple[float, float]]:
        """Get the bounding box coordinates.

        Returns:
            A tuple of (top_left, bottom_right) points where:
            - top_left: Upper-left corner (min_x, min_y)
            - bottom_right: Lower-right corner (max_x, max_y)
        """
        if (
            self.min_x == float("inf")
            or self.min_y == float("inf")
            or self.max_x == float("-inf")
            or self.max_y == float("-inf")
        ):
            return ((0.0, 0.0), (0.0, 0.0))

        # Y-down: min_y is top-left, max_y is bottom-right
        return ((self.min_x, self.min_y), (self.max_x, self.max_y))

    def update_svg_dimensions(self, svg: etree._Element) -> tuple[float, float]:
        """Update SVG element dimensions based on current bounds.

        Returns:
            tuple[float, float]: The content (viewBox) width and height, unaffected by zoom.
                Use these for elements positioned in viewBox coordinate space (e.g. background rect).
        """
        width = self.max_x - self.min_x + 2 * self.padding
        height = self.max_y - self.min_y + 2 * self.padding

        # Apply zoom to the displayed size
        display_width = width * self.zoom
        display_height = height * self.zoom

        # With Y-down, min_y is the top of the viewport
        viewbox_y = self.min_y - self.padding

        # Set display dimensions (zoomed) but keep viewBox at original size
        # This makes the content appear larger without changing coordinates
        svg.set("width", str(display_width))
        svg.set("height", str(display_height))
        svg.set(
            "viewBox",
            f"{self.min_x - self.padding} {viewbox_y} {width} {height}",
        )

        # Return content dimensions (not display dimensions) so callers that place
        # elements in viewBox space (e.g. background rect) use the correct size.
        return width, height

    def create_svg_root(self) -> etree._Element:
        """Create the SVG root element with proper dimensions."""
        # Use default bounds if none were set
        if (
            self.min_x == float("inf")
            or self.min_y == float("inf")
            or self.max_x == float("-inf")
            or self.max_y == float("-inf")
        ):
            self.min_x = self.min_y = 0
            self.max_x = self.max_y = 0

        svg = etree.Element("svg")
        svg.set("xmlns", "http://www.w3.org/2000/svg")

        # Set initial dimensions
        self.update_svg_dimensions(svg)

        return svg

    def convert_color(self, color: Color) -> str:
        """Convert DEXPI color to SVG color string."""
        if hasattr(color, "r") and hasattr(color, "g") and hasattr(color, "b"):
            return f"rgb({color.r},{color.g},{color.b})"
        return "rgb(0,0,0)"  # default black

    def convert_stroke(self, stroke: Stroke) -> dict:
        """Convert DEXPI stroke to SVG stroke attributes."""
        attrs = {}
        if stroke:
            attrs["stroke"] = self.convert_color(stroke.color)
            # Apply line width multiplier to make lines thinner while maintaining proportions
            stroke_width = (
                stroke.width if stroke.width is not None else 1.0
            ) * self.line_width_multiplier
            attrs["stroke-width"] = str(stroke_width)

            # Use vector-effect to prevent stroke from scaling with viewBox
            attrs["vector-effect"] = "non-scaling-stroke"

            if stroke.dashStyle and stroke.dashStyle != DashStyle.SOLID:
                w = stroke_width
                if stroke.dashStyle == DashStyle.DOT:
                    attrs["stroke-dasharray"] = f"{w},{2 * w}"
                elif stroke.dashStyle == DashStyle.SHORTDASH:
                    attrs["stroke-dasharray"] = f"{5 * w},{2 * w}"
                elif stroke.dashStyle == DashStyle.DASH:
                    attrs["stroke-dasharray"] = f"{10 * w},{2 * w}"
                elif stroke.dashStyle == DashStyle.LONGDASH:
                    attrs["stroke-dasharray"] = f"{15 * w},{2 * w}"
                elif stroke.dashStyle == DashStyle.DASHSHORTDASH:
                    attrs["stroke-dasharray"] = f"{10 * w},{2 * w},{3 * w},{2 * w}"
                elif stroke.dashStyle == DashStyle.LONGDASHSHORTDASH:
                    attrs["stroke-dasharray"] = f"{15 * w},{2 * w},{3 * w},{2 * w}"
                elif stroke.dashStyle == DashStyle.LONGDASHSHORTDASHSHORTDASH:
                    attrs["stroke-dasharray"] = f"{15 * w},{2 * w},{3 * w},{2 * w},{3 * w},{2 * w}"
        return attrs

    def convert_primitive(self, primitive) -> etree._Element | None:
        """Convert a DEXPI primitive to SVG element."""
        if isinstance(primitive, PolyLine):
            return self.convert_polyline(primitive)
        elif isinstance(primitive, Polygon):
            return self.convert_polygon(primitive)
        elif isinstance(primitive, Ellipse):
            return self.convert_ellipse(primitive)
        elif isinstance(primitive, EllipseArc):
            return self.convert_ellipse_arc(primitive)
        elif isinstance(primitive, Text):
            return self.convert_text(primitive)
        elif isinstance(primitive, ConnectorLine):
            return self.convert_connector_line(primitive)
        return None

    def convert_polyline(self, polyline: PolyLine) -> etree._Element:
        """Convert DEXPI polyline to SVG polyline element."""
        points = []
        for point in polyline.points:
            svg_y = self.to_svg_y(point.y)
            self.update_bounds(point.x, svg_y)
            points.append(f"{point.x},{svg_y}")

        element = etree.Element("polyline")
        element.set("points", " ".join(points))
        element.set("fill", "none")

        stroke_attrs = self.convert_stroke(polyline.stroke)
        for key, value in stroke_attrs.items():
            element.set(key, value)

        return element

    def convert_polygon(self, polygon: Polygon) -> etree._Element:
        """Convert DEXPI polygon to SVG polygon element."""
        points = []
        for point in polygon.points:
            svg_y = self.to_svg_y(point.y)
            self.update_bounds(point.x, svg_y)
            points.append(f"{point.x},{svg_y}")

        element = etree.Element("polygon")
        element.set("points", " ".join(points))

        if polygon.fillStyle == FillStyle.SOLID and polygon.stroke and polygon.stroke.color:
            fill = self.convert_color(polygon.stroke.color)
        else:
            fill = "none"
        element.set("fill", fill)

        stroke_attrs = self.convert_stroke(polygon.stroke)
        for key, value in stroke_attrs.items():
            element.set(key, value)

        return element

    def convert_ellipse(self, ellipse: Ellipse) -> etree._Element:
        """Convert DEXPI ellipse to SVG ellipse element."""
        svg_cy = self.to_svg_y(ellipse.center.y)
        half_width, half_height = _rotated_half_extent(ellipse)
        self.update_bounds(ellipse.center.x - half_width, svg_cy - half_height)
        self.update_bounds(ellipse.center.x + half_width, svg_cy + half_height)

        element = etree.Element("ellipse")
        element.set("cx", str(ellipse.center.x))
        element.set("cy", str(svg_cy))
        element.set("rx", str(ellipse.horizontalSemiAxis))
        element.set("ry", str(ellipse.verticalSemiAxis))

        if ellipse.rotation:
            element.set(
                "transform",
                f"rotate({ellipse.rotation} {ellipse.center.x} {svg_cy})",
            )

        if ellipse.fillStyle == FillStyle.SOLID and ellipse.stroke and ellipse.stroke.color:
            fill = self.convert_color(ellipse.stroke.color)
        else:
            fill = "none"
        element.set("fill", fill)

        stroke_attrs = self.convert_stroke(ellipse.stroke)
        for key, value in stroke_attrs.items():
            element.set(key, value)

        return element

    def convert_ellipse_arc(self, arc: EllipseArc) -> etree._Element:
        """Convert DEXPI ellipse arc to SVG path element."""
        svg_cy = self.to_svg_y(arc.center.y)
        half_width, half_height = _rotated_half_extent(arc)
        self.update_bounds(arc.center.x - half_width, svg_cy - half_height)
        self.update_bounds(arc.center.x + half_width, svg_cy + half_height)

        # DEXPI angles are in degrees; convert to radians for math functions
        start_angle_rad = math.radians(arc.startAngle)
        end_angle_rad = math.radians(arc.endAngle)

        # Arc angles are in the canonical Y-down space, running from startAngle to
        # endAngle in the positive-angle direction, which in Y-down is clockwise on
        # screen: sweep = 1.
        angle_diff = (end_angle_rad - start_angle_rad) % (2 * math.pi)
        large_arc = 1 if angle_diff > math.pi else 0
        sweep = 1

        # Rotation is already in degrees
        rotation_deg = arc.rotation if arc.rotation is not None else 0.0

        # The endpoints in model space: the angles are measured in the ellipse's own
        # frame, which `rotation` turns clockwise (Y-down) about the centre -- the
        # same frame every renderer draws in. Leaving the rotation out put the ends
        # of every rotated arc on the unrotated ellipse.
        cos_r, sin_r = math.cos(math.radians(rotation_deg)), math.sin(math.radians(rotation_deg))

        def on_ellipse(angle_rad: float) -> tuple[float, float]:
            local_x = arc.horizontalSemiAxis * math.cos(angle_rad)
            local_y = arc.verticalSemiAxis * math.sin(angle_rad)
            return (
                arc.center.x + local_x * cos_r - local_y * sin_r,
                arc.center.y + local_x * sin_r + local_y * cos_r,
            )

        start_x, start_y = on_ellipse(start_angle_rad)
        end_x, end_y = on_ellipse(end_angle_rad)

        svg_start_y = self.to_svg_y(start_y)
        svg_end_y = self.to_svg_y(end_y)

        # Create SVG path
        element = etree.Element("path")
        d = f"M {start_x:.2f},{svg_start_y:.2f} "  # Start point
        d += f"A {arc.horizontalSemiAxis:.2f},{arc.verticalSemiAxis:.2f} "  # Radii
        d += f"{rotation_deg:.2f} {large_arc},{sweep} "  # Arc parameters
        d += f"{end_x:.2f},{svg_end_y:.2f}"  # End point
        element.set("d", d)
        element.set("fill", "none")

        stroke_attrs = self.convert_stroke(arc.stroke)
        for key, value in stroke_attrs.items():
            element.set(key, value)

        return element

    def convert_text(self, text: Text) -> etree._Element:
        """Convert DEXPI text to SVG text element."""
        svg_y = self.to_svg_y(text.position.y)
        self.update_bounds(text.position.x, svg_y)
        element = etree.Element("text")
        element.set("x", str(text.position.x))
        element.set("y", str(svg_y))
        element.text = text.text

        # Handle text alignment — Y-down: position is the anchor point
        if text.alignment:
            if text.alignment.value.startswith("Left"):
                element.set("text-anchor", "start")
            elif text.alignment.value.startswith("Right"):
                element.set("text-anchor", "end")
            else:  # Center alignment
                element.set("text-anchor", "middle")

            # Vertical alignment for Y-down coordinate system
            if text.alignment.value.endswith("Top"):
                element.set("dominant-baseline", "hanging")
            elif text.alignment.value.endswith("Bottom"):
                element.set("dominant-baseline", "text-bottom")
            else:  # Center vertical
                element.set("dominant-baseline", "middle")

        # Font properties
        if text.font:
            # Use Arial as fallback font
            font_family = f"'{text.font}', Arial"
            element.set("font-family", font_family)
        if text.size:
            element.set("font-size", str(text.size))

        # Rotation
        if text.rotation != 0:
            element.set(
                "transform",
                f"rotate({text.rotation} {text.position.x} {svg_y})",
            )

        # Text color
        element.set("fill", self.convert_color(text.color) if text.color else "black")

        return element

    def convert_connector_line(self, line: ConnectorLine) -> etree._Element:
        """Convert DEXPI connector line to SVG polyline element.

        Builds the full point list from source NodePosition + innerPoints + target NodePosition.
        """
        # Resolve start and end points from source/target NodePositions
        all_points: list[Point] = []
        if line.source and line.source.position:
            all_points.append(line.source.position)
        all_points.extend(line.innerPoints)
        if line.target and line.target.position:
            all_points.append(line.target.position)

        for point in all_points:
            self.update_bounds(point.x, self.to_svg_y(point.y))

        element = etree.Element("polyline")
        points = [f"{p.x},{self.to_svg_y(p.y)}" for p in all_points]
        element.set("points", " ".join(points))
        element.set("fill", "none")

        stroke_attrs = self.convert_stroke(line.stroke)
        for key, value in stroke_attrs.items():
            element.set(key, value)

        return element

    def add_background_rect(self, svg: etree._Element, width: float, height: float) -> None:
        """Add a background rectangle to the SVG element.

        The colour is a fixed neutral grey, and deliberately *not* `Diagram.backgroundColor`.
        The backdrop is viewer scaffolding rather than part of the drawing: DEXPI drawings
        contain white-filled shapes, which vanish against a white backdrop. The reference P&ID
        is the case in point -- it declares `BackgroundColor` white and renders five shapes
        filled `rgb(255,255,255)`, so honouring the attribute would make exactly those five
        invisible. A grey keeps both white and black content legible.

        `Diagram.backgroundColor` is therefore unused by this exporter. If sheet-accurate
        rendering is ever wanted it should arrive as an explicit argument the caller sets, not by
        silently adopting the model value here.

        Args:
            svg: The SVG element to add the background to
            width: The width of the background rectangle
            height: The height of the background rectangle
        """
        # With Y-down, min_y is the top of the viewport
        bg_y = self.min_y - self.padding

        bg = etree.Element("rect")
        bg.set("x", str(self.min_x - self.padding))
        bg.set("y", str(bg_y))
        bg.set("width", str(width))
        bg.set("height", str(height))
        bg.set("fill", "#f0f0f0")
        svg.insert(0, bg)

    def create_svg_content(
        self, svg: etree._Element, background: bool = True
    ) -> tuple[float, float]:
        """Create the SVG content with common elements and processing.

        Args:
            svg: The SVG root element to add content to
            background: If True, add a background rectangle

        Returns:
            tuple[float, float]: The width and height of the SVG
        """
        width, height = self.update_svg_dimensions(svg)

        if background:
            self.add_background_rect(svg, width, height)

        return width, height

    @abstractmethod
    def _add_metadata(self, svg: etree._Element) -> None:
        """Add metadata to the SVG element.

        Args:
            svg: The SVG element to add metadata to
        """

    @abstractmethod
    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create and return a group element for the main content.

        Args:
            svg: The parent SVG element

        Returns:
            etree._Element: The created group element
        """

    @abstractmethod
    def _get_primitives(self) -> list:
        """Get the list of primitives to convert.

        Returns:
            list: List of primitive elements to convert
        """

    def transform_content_group(
        self,
        translate: tuple[float, float],
        rotate: float,
        scale: tuple[float, float],
        is_mirrored: bool,
        svg: etree._Element,
    ) -> str:
        """Create an SVG transform attribute string and update viewBox based on transformations.

        Args:
            translate: A tuple (tx, ty) specifying translation in x and y directions
            rotate: Rotation angle in degrees
            scale: A tuple (sx, sy) specifying scale factors in x and y directions            svg: The SVG element whose viewBox needs to be updated

        Returns:
            str: SVG transform attribute string combining translate, rotate, and scale
        """
        transforms = []
        corners = [
            (self.min_x, self.min_y),
            (self.min_x, self.max_y),
            (self.max_x, self.min_y),
            (self.max_x, self.max_y),
        ]
        transformed_corners = []

        # First apply scale and mirroring if needed
        effective_scale = list(scale)
        if is_mirrored:
            effective_scale[0] *= -1  # Mirror along Y-axis by negating X scale

        # Apply scale transform if scale is not identity or if mirrored.
        # Skip if both scale factors are near-zero — the element is degenerate
        # and emitting scale(0.00,0.00) would produce a non-invertible
        # transform (values < 0.005 round to 0.00 with %.2f formatting).
        _ZERO_SCALE_THRESHOLD = 0.005
        if (
            abs(effective_scale[0]) < _ZERO_SCALE_THRESHOLD
            and abs(effective_scale[1]) < _ZERO_SCALE_THRESHOLD
        ):
            transformed_corners = corners.copy()
        elif effective_scale != [1.0, 1.0] or is_mirrored:
            transforms.append(f"scale({effective_scale[0]:.2f},{effective_scale[1]:.2f})")
            for x, y in corners:
                transformed_corners.append((x * effective_scale[0], y * effective_scale[1]))
        else:
            transformed_corners = corners.copy()

        # Then apply rotation
        if rotate != 0.0:
            angle_deg = rotate
            transforms.append(f"rotate({angle_deg:.2f})")
            rotated_corners = []
            for x, y in transformed_corners:
                rx = x * math.cos(math.radians(rotate)) - y * math.sin(math.radians(rotate))
                ry = x * math.sin(math.radians(rotate)) + y * math.cos(math.radians(rotate))
                rotated_corners.append((rx, ry))
            transformed_corners = rotated_corners

        # Finally apply translation
        if translate != (0.0, 0.0):
            transforms.append(f"translate({translate[0]:.2f},{translate[1]:.2f})")
            translated_corners = []
            for x, y in transformed_corners:
                translated_corners.append((x + translate[0], y + translate[1]))
            transformed_corners = translated_corners

        # Reset bounds and update with transformed corners
        self.min_x = float("inf")
        self.min_y = float("inf")
        self.max_x = float("-inf")
        self.max_y = float("-inf")

        for x, y in transformed_corners:
            self.update_bounds(x, y)

        # Add padding to bounds
        width = self.max_x - self.min_x + 2 * self.padding
        height = self.max_y - self.min_y + 2 * self.padding

        # With Y-down, min_y is the top of the viewport
        viewbox_y = self.min_y - self.padding

        # Update SVG viewBox
        svg.set("viewBox", f"{self.min_x - self.padding} {viewbox_y} {width} {height}")
        svg.set("width", str(width))
        svg.set("height", str(height))

        # Return transforms in reverse order for proper SVG transformation
        return " ".join(reversed(transforms))


class DrawSVG(ABC):
    """Minimal interface for DEXPI-to-SVG conversion using composition.

    This ABC defines the interface that concrete classes must implement,
    while delegating all rendering operations to a composed SvgRenderer instance.
    """

    def __init__(self, padding: float = 0.0, pretty: bool = False):
        """Initialize with a renderer for composition.

        Args:
            padding: Extra space around the drawing in SVG units
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        self.renderer = SvgRenderer(padding, pretty)

    # Convenience delegation methods for common rendering operations
    def to_svg_y(self, y: float) -> float:
        """Delegate to renderer's to_svg_y method."""
        return self.renderer.to_svg_y(y)

    def convert_color(self, color: Color) -> str:
        """Delegate to renderer's convert_color method."""
        return self.renderer.convert_color(color)

    def consolidate_bounds(self, other: "DrawSVG") -> None:
        """Consolidate bounds with another DrawSVG instance's renderer."""
        self.renderer.consolidate_bounds(other.renderer)

    def transform_content_group(
        self,
        translate: tuple[float, float],
        rotate: float,
        scale: tuple[float, float],
        is_mirrored: bool,
        svg: etree._Element,
    ) -> str:
        """Delegate to renderer's transform_content_group method."""
        return self.renderer.transform_content_group(translate, rotate, scale, is_mirrored, svg)

    @abstractmethod
    def _add_metadata(self, svg: etree._Element) -> None:
        """Add metadata to the SVG element.

        Args:
            svg: The SVG element to add metadata to
        """

    @abstractmethod
    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create and return a group element for the main content.

        Args:
            svg: The parent SVG element

        Returns:
            etree._Element: The created group element
        """

    @abstractmethod
    def _get_primitives(self) -> list:
        """Get the list of primitives to convert.

        Returns:
            list: List of primitive elements to convert
        """

    def draw_svg(
        self, return_element: bool = False, background: bool = True
    ) -> str | etree._Element:
        """Convert the DEXPI object to SVG.

        Args:
            return_element: If True, returns the SVG Element instead of string
            background: If True, add a background rectangle

        Returns:
            str | etree._Element: The SVG representation as a string or Element
        """
        self.renderer.reset_bounds()
        svg = self.renderer.create_svg_root()

        # Add metadata (implementation-specific)
        self._add_metadata(svg)

        # Create content group (implementation-specific)
        group = self._create_content_group(svg)

        # Convert each primitive
        for primitive in self._get_primitives():
            element = self.renderer.convert_primitive(primitive)
            if element is not None:
                group.append(element)

        # Calculate zoom for A3 if pretty mode is enabled
        if self.renderer.pretty:
            self.renderer.zoom = self.renderer.calculate_zoom_for_a3()

        # Update dimensions and add background
        width, height = self.renderer.update_svg_dimensions(svg)

        if background:
            self.renderer.add_background_rect(svg, width, height)

        etree.indent(svg, space="  ")

        if return_element:
            return svg

        # lxml refuses to emit a declaration alongside encoding="unicode", so it is prepended here.
        return '<?xml version="1.0" encoding="UTF-8"?>' + etree.tostring(svg, encoding="unicode")

    def save_svg(self, object_name: str, filepath: str, background: bool = True) -> str:
        """Save SVG content to a file.

        Args:
            object_name: Name of the object being saved (used for auto-generating filename)
            filepath: Path to save the SVG file. If directory, a filename will be generated
            background: If True, add a background rectangle

        Returns:
            str: The absolute path to the saved file
        """
        filepath: Path = Path(filepath)
        if filepath.is_dir() or not filepath.suffix:
            safe_name: str = "_".join(object_name.split())
            filepath = filepath / f"{safe_name}.svg"

        filepath.parent.mkdir(parents=True, exist_ok=True)

        svg_content = self.draw_svg(return_element=False, background=background)
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(svg_content)

        return str(filepath)

    def save_png(
        self, object_name: str, filepath: str, background: bool = True, scale: float = 4.0
    ) -> str:
        """Save drawing as a PNG file by converting the generated SVG.

        Requires the ``resvg`` package. Install with: ``pip install pydexpi[png]``

        Args:
            object_name: Name of the object being saved (used for auto-generating filename)
            filepath: Path to save the PNG file. If directory, a filename will be generated
            background: If True, add a background rectangle
            scale: Uniform scale factor for the output resolution. Default is ``4.0``,
                which yields approximately 300 DPI for an A3-sized diagram.

        Returns:
            str: The absolute path to the saved file

        Raises:
            ImportError: If ``resvg`` is not installed
        """
        from pydexpi.exports.png_export import svg_to_png

        filepath: Path = Path(filepath)
        if filepath.is_dir() or not filepath.suffix:
            safe_name: str = "_".join(object_name.split())
            filepath = filepath / f"{safe_name}.png"

        filepath.parent.mkdir(parents=True, exist_ok=True)

        svg_content = self.draw_svg(return_element=False, background=background)
        svg_to_png(svg_content, filepath, scale=scale)

        return str(filepath)

    def save_pdf(self, object_name: str, filepath: str, background: bool = True) -> str:
        """Save drawing as a PDF file by converting the generated SVG.

        Requires ``svglib`` and ``reportlab``. Install with: ``pip install pydexpi[pdf]``

        Args:
            object_name: Name of the object being saved (used for auto-generating filename)
            filepath: Path to save the PDF file. If directory, a filename will be generated
            background: If True, add a background rectangle

        Returns:
            str: The absolute path to the saved file

        Raises:
            ImportError: If ``svglib`` or ``reportlab`` is not installed
        """
        from pydexpi.exports.pdf_export import svg_to_pdf

        filepath: Path = Path(filepath)
        if filepath.is_dir() or not filepath.suffix:
            safe_name: str = "_".join(object_name.split())
            filepath = filepath / f"{safe_name}.pdf"

        filepath.parent.mkdir(parents=True, exist_ok=True)

        svg_content = self.draw_svg(return_element=False, background=background)
        svg_to_pdf(svg_content, filepath)

        return str(filepath)


class DrawShape(DrawSVG):
    """Converter for DEXPI shapes to SVG format."""

    def __init__(self, shape: Shape, padding: float = 0.0, pretty: bool = False):
        """Initialize with a shape to convert.

        Args:
            shape: The shape to convert
            padding: Extra space around the drawing
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        super().__init__(padding, pretty)
        self.shape = shape

    def _add_metadata(self, svg: etree._Element) -> None:
        """Add shape-specific metadata."""
        metadata = etree.SubElement(svg, "metadata")
        metadata.text = f"DEXPI Shape: {self.shape.name}"
        if hasattr(self.shape, "symbolRegistrationNumber") and self.shape.symbolRegistrationNumber:
            metadata.text += f" (Registration: {self.shape.symbolRegistrationNumber})"

    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create group for shape primitives."""
        group = etree.SubElement(svg, "g")
        if self.shape.name:
            group.set("id", self.shape.name)
        return group

    def _get_primitives(self) -> list:
        """Get shape primitives."""
        return self.shape.primitives


# Convenient functions for common operations
def process_shape_catalogue(catalogue: ShapeCatalogue, output_dir: str) -> dict[str, str]:
    """Process all shapes in a shape catalogue and save them as SVG files."""
    os.makedirs(output_dir, exist_ok=True)
    result = {}

    for shape in catalogue.shapes:
        safe_name = "_".join(shape.name.split())
        filename = f"{safe_name}.svg"
        filepath = os.path.join(output_dir, filename)

        drawer = DrawShape(shape)
        drawer.save_svg(shape.name, filepath)
        result[shape.name] = filepath

    return result


class DrawShapeUsage(DrawSVG):
    """Converter for DEXPI shape usage to SVG format."""

    def __init__(self, shape_usage: ShapeUsage, padding: float = 0.0, pretty: bool = False):
        """Initialize with a shape usage to convert.

        Args:
            shape_usage: The shape usage to convert
            padding: Extra space around the drawing
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        super().__init__(padding, pretty)
        self.shape_usage = shape_usage
        # Create a DrawShape instance for the referenced shape
        self.shape_drawer = DrawShape(self.shape_usage.shape, padding, pretty)

    def _add_metadata(self, svg: etree._Element) -> None:
        """Add shape usage-specific metadata."""
        # Get metadata from shape drawer first
        shape_svg = self.shape_drawer.draw_svg(return_element=True)
        shape_metadata = shape_svg.find("metadata")
        if shape_metadata is not None:
            metadata = etree.SubElement(svg, "metadata")
            # Add shape usage info to the shape metadata
            metadata.text = f"ShapeUsage of {shape_metadata.text}"

    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create group for shape usage content.

        This creates a group and applies the necessary transformations based on
        position, rotation, scale and mirror settings.

        Shape usages with zero scale factors (both scaleX and scaleY equal to
        zero) are treated as degenerate/hidden elements and are skipped rather
        than emitting a non-invertible ``scale(0,0)`` transform that would
        break downstream consumers such as reportlab's PDF renderer.
        """
        # Create a group for this shape usage
        group = etree.SubElement(svg, "g")

        # Skip degenerate shape usages whose scale is effectively zero.
        # Values like 0.0001 round to 0.00 in the SVG transform attribute
        # (which uses %.2f formatting), producing a non-invertible
        # scale(0.00,0.00) that crashes renderers like reportlab.
        _ZERO_SCALE_THRESHOLD = 0.005  # anything that rounds to 0.00
        if (
            abs(self.shape_usage.scaleX) < _ZERO_SCALE_THRESHOLD
            and abs(self.shape_usage.scaleY) < _ZERO_SCALE_THRESHOLD
        ):
            return group

        # First draw the shape using shape_drawer
        shape_element = self.shape_drawer.draw_svg(return_element=True, background=False)

        # Extract shape's content group and copy its bounds
        shape_content = shape_element.find("g")
        if shape_content is not None:
            # Copy the shape's bounds for proper transformation
            self.renderer.min_x = self.shape_drawer.renderer.min_x
            self.renderer.min_y = self.shape_drawer.renderer.min_y
            self.renderer.max_x = self.shape_drawer.renderer.max_x
            self.renderer.max_y = self.shape_drawer.renderer.max_y

            # Calculate transformations based on shape usage properties
            translate = (self.shape_usage.position.x, self.to_svg_y(self.shape_usage.position.y))
            rotate = self.shape_usage.rotation
            scale = (
                self.shape_usage.scaleX,
                self.shape_usage.scaleY,
            )
            is_mirrored = self.shape_usage.isMirrored

            # Apply transformations
            transform = self.transform_content_group(translate, rotate, scale, is_mirrored, svg)
            if transform:
                shape_content.set("transform", transform)

            # Add the transformed shape content to our group
            group.append(shape_content)

        return group

    def _get_primitives(self) -> list:
        """Get shape primitives from the referenced shape."""
        # We don't use this since we're using shape_drawer to draw primitives
        return []


class DrawRepresentationTypeGroup(DrawSVG):
    """Converter for DEXPI diagrams to SVG format."""

    def __init__(self, group: RepresentationTypeGroup, padding: float = 0.0, pretty: bool = False):
        """Initialize with a representation group to convert.

        Args:
            group: The representation group to convert
            padding: Extra space around the drawing
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        super().__init__(padding, pretty)
        self.group = group

    def _add_metadata(self, svg: etree._Element) -> None:
        """Add group-specific metadata."""
        metadata = etree.SubElement(svg, "metadata")
        metadata.text = f"DEXPI RepresentationTypeGroup: {self.group.__class__.__name__}"

    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create group for representation type elements.

        This handles both GraphicalPrimitive elements and ShapeUsage elements:
        - ShapeUsage elements are rendered directly using DrawShapeUsage (with transformations)
        - GraphicalPrimitive elements (PolyLine, Polygon, Ellipse, EllipseArc,
          ConnectorLine, Text) are returned by _get_primitives() for standard processing
        """
        group = etree.SubElement(svg, "g")
        group.set("class", self.group.__class__.__name__.lower())

        # Handle ShapeUsage elements directly (they require transformation handling)
        for element in self.group.elements:
            if isinstance(element, ShapeUsage):
                # Create DrawShapeUsage to handle transformations
                shape_drawer = DrawShapeUsage(element, self.renderer.padding, self.renderer.pretty)
                # Draw the shape and add it to our group
                shape_element = shape_drawer.draw_svg(return_element=True, background=False)
                if shape_element is not None:
                    # Extract the content group from the shape
                    shape_content = shape_element.find("g")
                    if shape_content is not None:
                        group.append(shape_content)
                        self.consolidate_bounds(shape_drawer)
            # GraphicalPrimitive elements are handled by _get_primitives() below

        return group

    def _get_primitives(self) -> list:
        """Get graphical primitive elements for rendering.

        Returns only GraphicalPrimitive elements (PolyLine, Polygon, Ellipse,
        EllipseArc, ConnectorLine, Text) since ShapeUsage elements are
        handled directly in _create_content_group.
        """
        return [
            element for element in self.group.elements if isinstance(element, GraphicalPrimitive)
        ]


class DrawNodePosition(DrawSVG):
    """Converter for DEXPI node positions to SVG format.

    Draws a crosshair marker at the node position to visually indicate connection points.
    """

    def __init__(
        self,
        node_position: NodePosition,
        padding: float = 0.0,
        marker_size: float = 10.0,
        pretty: bool = False,
    ):
        """Initialize with a node position to convert.

        Args:
            node_position: The node position to convert
            padding: Extra space around the drawing
            marker_size: Size of the crosshair marker in drawing units
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        super().__init__(padding, pretty)
        self.node_position = node_position
        self.marker_size = marker_size

    def _add_metadata(self, svg: etree._Element) -> None:
        """Add node position-specific metadata."""

    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create group for node position marker."""
        group = etree.SubElement(svg, "g")
        group.set("class", "node-position")
        return group

    def _get_primitives(self) -> list:
        """Create primitives to represent the node position.

        Returns a list containing two PolyLine objects forming a crosshair.
        """
        x = self.node_position.position.x
        y = self.node_position.position.y
        half_size = self.marker_size / 2

        # Create default stroke style for the marker
        stroke = Stroke(
            color=Color(r=0, g=0, b=0),  # Black color
            dashStyle=DashStyle.SOLID,
            width=1.0,
        )

        # Create horizontal line
        horizontal = PolyLine(
            points=[Point(x=x - half_size, y=y), Point(x=x + half_size, y=y)], stroke=stroke
        )

        # Create vertical line
        vertical = PolyLine(
            points=[Point(x=x, y=y - half_size), Point(x=x, y=y + half_size)], stroke=stroke
        )

        return [horizontal, vertical]


class DrawRepresentationGroup(DrawSVG):
    """Converter for DEXPI representation groups to SVG format.

    A representation group can contain:
    - Other representation groups
    - Representation type groups (which contain graphical elements)
    - Node positions
    """

    def __init__(
        self,
        group: RepresentationGroup,
        padding: float = 0.0,
        show_node_position: bool = False,
        pretty: bool = False,
    ):
        """Initialize with a representation group to convert.

        Args:
            group: The representation group to convert
            padding: Extra space around the drawing
            show_node_position: If True, displays node position markers (default: False)
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        super().__init__(padding, pretty)
        self.group = group
        self.show_node_position = show_node_position

    def _add_metadata(self, svg: etree._Element) -> None:
        """Add group-specific metadata with representation ID."""
        metadata = etree.SubElement(svg, "metadata")
        metadata.text = f"DEXPI RepresentationGroup representing: {self.group.represents.id}"

    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create group for representation content, handling nested groups and node positions."""
        # Create main group
        group = etree.SubElement(svg, "g")
        group.set("id", self.group.represents.id)
        group.set("class", "representation-group")

        # Process nested groups
        for nested_group in self.group.groups:
            if isinstance(nested_group, RepresentationGroup):
                # Recursively handle nested representation groups
                drawer = DrawRepresentationGroup(
                    nested_group,
                    self.renderer.padding,
                    show_node_position=self.show_node_position,
                    pretty=self.renderer.pretty,
                )
                nested_svg = drawer.draw_svg(return_element=True, background=False)
                content = nested_svg.find("g")
                if content is not None:
                    group.append(content)
                    # Consolidate bounds with nested group
                    self.consolidate_bounds(drawer)
            elif isinstance(nested_group, RepresentationTypeGroup):
                # Handle representation type groups using DrawRepresentationTypeGroup
                drawer = DrawRepresentationTypeGroup(
                    nested_group, self.renderer.padding, self.renderer.pretty
                )
                nested_svg = drawer.draw_svg(return_element=True, background=False)
                content = nested_svg.find("g")
                if content is not None:
                    group.append(content)
                    # Consolidate bounds with type group
                    self.consolidate_bounds(drawer)

        # Process node positions
        if self.show_node_position:
            for node_position in self.group.nodePositions:
                drawer = DrawNodePosition(
                    node_position,
                    self.renderer.padding,
                    marker_size=2.0,
                    pretty=self.renderer.pretty,
                )
                node_svg = drawer.draw_svg(return_element=True, background=False)
                content = node_svg.find("g")
                if content is not None:
                    group.append(content)
                    # Consolidate bounds with node position
                    self.consolidate_bounds(drawer)

        return group

    def _get_primitives(self) -> list:
        """Primitives will be handled by the nested groups' _create_content_group methods."""
        return []


class DrawDiagram(DrawSVG):
    """Converter for DEXPI diagrams to SVG format."""

    def __init__(
        self,
        diagram: Diagram,
        padding: float = 0.0,
        show_node_position: bool = False,
        pretty: bool = False,
    ):
        """Initialize with a DEXPI diagram to convert.

        Args:
            diagram: The DEXPI diagram to convert
            padding: Extra space around the drawing
            show_node_position: If True, displays node position markers (default: False)
            pretty: If True, applies thinner line widths (0.3x) and scales to fit A3 size
        """
        super().__init__(padding, pretty)
        self.diagram = diagram
        self.show_node_position = show_node_position

        # Seed the renderer with the diagram's declared extents (the sheet size) so the
        # rendered viewBox covers at least the sheet, surviving the bounds reset in draw_svg.
        extents = (diagram.minX, diagram.minY, diagram.maxX, diagram.maxY)
        if all(value is not None for value in extents):
            self.renderer.set_initial_bounds(*extents)

    def _add_metadata(self, svg: etree._Element) -> None:
        """Add diagram-specific metadata."""
        metadata = etree.SubElement(svg, "metadata")
        # Only the whole-drawing root is stamped with the generator; the per-shape
        # _add_metadata overrides are left alone so it is not repeated per symbol.
        metadata.text = f"DEXPI Diagram: {self.diagram.name} - {generator_comment()}"

    def _create_content_group(self, svg: etree._Element) -> etree._Element:
        """Create group for diagram elements.

        Since Diagram is a RepresentationGroup, we use DrawRepresentationGroup
        to handle all nested groups and elements.
        """
        # Create main group for the diagram
        group = etree.SubElement(svg, "g")
        group.set("id", f"diagram-{self.diagram.name}")
        group.set("class", "diagram")

        # `diagram.backgroundColor` is deliberately not applied here. `fill` on a <g> is the
        # inherited paint for the shapes inside it, not a backdrop, so setting it to the
        # background colour paints every primitive that does not override `fill` in the colour of
        # the paper it sits on - invisible. It happens to be harmless today only because every
        # convert_* method sets `fill` explicitly. The backdrop is a <rect>, and it does not use
        # `backgroundColor` either; `SvgRenderer.add_background_rect` explains why.

        # Process nested groups using DrawRepresentationGroup logic
        for nested_group in self.diagram.groups:
            if isinstance(nested_group, RepresentationGroup):
                # Recursively handle nested representation groups
                drawer = DrawRepresentationGroup(
                    nested_group,
                    self.renderer.padding,
                    show_node_position=self.show_node_position,
                    pretty=self.renderer.pretty,
                )
                nested_svg = drawer.draw_svg(return_element=True, background=False)
                content = nested_svg.find("g")
                if content is not None:
                    group.append(content)
                    # Consolidate bounds with nested group
                    self.consolidate_bounds(drawer)
            elif isinstance(nested_group, RepresentationTypeGroup):
                # Handle representation type groups using DrawRepresentationTypeGroup
                drawer = DrawRepresentationTypeGroup(
                    nested_group, self.renderer.padding, self.renderer.pretty
                )
                nested_svg = drawer.draw_svg(return_element=True, background=False)
                content = nested_svg.find("g")
                if content is not None:
                    group.append(content)
                    # Consolidate bounds with type group
                    self.consolidate_bounds(drawer)

        # Process node positions if requested
        if self.show_node_position:
            for node_position in self.diagram.nodePositions:
                drawer = DrawNodePosition(
                    node_position,
                    self.renderer.padding,
                    marker_size=2.0,
                    pretty=self.renderer.pretty,
                )
                node_svg = drawer.draw_svg(return_element=True, background=False)
                content = node_svg.find("g")
                if content is not None:
                    group.append(content)
                    # Consolidate bounds with node position
                    self.consolidate_bounds(drawer)

        return group

    def _get_primitives(self) -> list:
        """Get diagram elements.

        Primitives are handled by nested groups' _create_content_group methods,
        so we return an empty list here.
        """
        return []
