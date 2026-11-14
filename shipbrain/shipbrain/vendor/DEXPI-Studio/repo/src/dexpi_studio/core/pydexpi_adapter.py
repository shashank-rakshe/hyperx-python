"""Thin wrappers around existing pyDEXPI APIs.

This module provides adapter functions that the GUI calls. Each function
delegates to pyDEXPI — no parsing, rendering, or export logic is reimplemented here.
"""

from __future__ import annotations

import importlib
import logging
import math
from copy import deepcopy
from pathlib import Path
from typing import TYPE_CHECKING, Any

from dexpi_studio.core.diagram_manifest import DiagramRenderManifest, DiagramTextLabel

if TYPE_CHECKING:
    from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel

_log = logging.getLogger(__name__)


def _identity_matrix() -> tuple[float, float, float, float, float, float]:
    return (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def _matrix_mul(
    a: tuple[float, float, float, float, float, float],
    b: tuple[float, float, float, float, float, float],
) -> tuple[float, float, float, float, float, float]:
    a11, a12, a21, a22, atx, aty = a
    b11, b12, b21, b22, btx, bty = b
    return (
        a11 * b11 + a21 * b12,
        a12 * b11 + a22 * b12,
        a11 * b21 + a21 * b22,
        a12 * b21 + a22 * b22,
        a11 * btx + a21 * bty + atx,
        a12 * btx + a22 * bty + aty,
    )


def _apply_matrix(
    m: tuple[float, float, float, float, float, float], x: float, y: float
) -> tuple[float, float]:
    a11, a12, a21, a22, tx, ty = m
    return (a11 * x + a21 * y + tx, a12 * x + a22 * y + ty)


def _shape_usage_matrix(shape_usage: object) -> tuple[float, float, float, float, float, float]:
    sx = float(getattr(shape_usage, "scaleX", 1.0) or 1.0)
    sy = float(getattr(shape_usage, "scaleY", 1.0) or 1.0)
    if bool(getattr(shape_usage, "isMirrored", False)):
        sx *= -1.0
    rot_deg = float(getattr(shape_usage, "rotation", 0.0) or 0.0)
    tx = float(getattr(getattr(shape_usage, "position", None), "x", 0.0) or 0.0)
    ty = float(getattr(getattr(shape_usage, "position", None), "y", 0.0) or 0.0)

    s = (sx, 0.0, 0.0, sy, 0.0, 0.0)
    rad = math.radians(rot_deg)
    c = math.cos(rad)
    si = math.sin(rad)
    r = (c, si, -si, c, 0.0, 0.0)
    t = (1.0, 0.0, 0.0, 1.0, tx, ty)
    return _matrix_mul(t, _matrix_mul(r, s))


def _stroke_color_tuple(stroke: object) -> tuple[int, int, int, int] | None:
    if stroke is None:
        return None
    color = getattr(stroke, "color", None)
    if color is None:
        return None
    r = int(getattr(color, "r", 0) or 0)
    g = int(getattr(color, "g", 0) or 0)
    b = int(getattr(color, "b", 0) or 0)
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)), 255)


def _stroke_width(stroke: object) -> float | None:
    if stroke is None:
        return None
    w = getattr(stroke, "width", None)
    if w is None:
        return None
    try:
        width = float(w)
    except (TypeError, ValueError):
        return None
    return width if width > 0 else None


def _stroke_dash_pattern(stroke: object) -> list[float] | None:
    if stroke is None:
        return None
    dash_style = getattr(stroke, "dashStyle", None)
    if dash_style is None:
        return None
    name = str(getattr(dash_style, "name", dash_style)).upper()
    w = _stroke_width(stroke) or 1.0
    mapping: dict[str, list[float]] = {
        "SOLID": [],
        "DOT": [w, 2 * w],
        "SHORTDASH": [5 * w, 2 * w],
        "DASH": [10 * w, 2 * w],
        "LONGDASH": [15 * w, 2 * w],
        "DASHSHORTDASH": [10 * w, 2 * w, 3 * w, 2 * w],
        "LONGDASHSHORTDASH": [15 * w, 2 * w, 3 * w, 2 * w],
        "LONGDASHSHORTDASHSHORTDASH": [15 * w, 2 * w, 3 * w, 2 * w, 3 * w, 2 * w],
    }
    value = mapping.get(name)
    if value is None or not value:
        return None
    return [float(v) for v in value]


def build_diagram_render_manifest(
    model: EngineeringModel,
    equipment_ids: set[str],
    piping_ids: set[str],
) -> DiagramRenderManifest:
    """Build a model-first render manifest from pyDEXPI diagram objects.

    This avoids re-parsing generated SVG and uses pyDEXPI model primitives
    directly for geometry, style, and labels.
    """
    from collections import Counter

    from pydexpi.pydexpi_classes.pydexpi_classes import (
        ConnectorLine,
        Ellipse,
        EllipseArc,
        GraphicalPrimitive,
        Polygon,
        PolyLine,
        RepresentationGroup,
        RepresentationTypeGroup,
        ShapeUsage,
        Text,
    )

    manifest = DiagramRenderManifest()
    if model.diagram is None:
        return manifest

    bounds_by_id: dict[str, tuple[float, float, float, float]] = {}
    geometry_by_id: dict[str, list[list[tuple[float, float]]]] = {}
    style_colors: dict[str, list[tuple[int, int, int, int]]] = {}
    style_dashes: dict[str, list[tuple[float, ...]]] = {}
    style_widths: dict[str, list[float]] = {}

    def _is_neutral_color(color: tuple[int, int, int, int]) -> bool:
        r, g, b, _a = color
        spread = max(r, g, b) - min(r, g, b)
        return spread <= 20

    def _preferred_equipment_color(
        values: list[tuple[int, int, int, int]],
    ) -> tuple[int, int, int, int]:
        from collections import Counter

        ranked = Counter(values).most_common()
        for color, _count in ranked:
            if not _is_neutral_color(color):
                return color
        return ranked[0][0]

    def _update_bounds(oid: str, points: list[tuple[float, float]]) -> None:
        if not points:
            return
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
        current = bounds_by_id.get(oid)
        if current is None:
            bounds_by_id[oid] = (x0, y0, x1, y1)
            return
        cx0, cy0, cx1, cy1 = current
        bounds_by_id[oid] = (min(cx0, x0), min(cy0, y0), max(cx1, x1), max(cy1, y1))

    def _collect_style(oid: str, primitive: object) -> None:
        stroke = getattr(primitive, "stroke", None)
        color = _stroke_color_tuple(stroke)
        if color is not None:
            style_colors.setdefault(oid, []).append(color)
        dash = _stroke_dash_pattern(stroke)
        if dash:
            style_dashes.setdefault(oid, []).append(tuple(float(v) for v in dash))
        width = _stroke_width(stroke)
        if width is not None:
            style_widths.setdefault(oid, []).append(float(width))

    def _register_geometry(oid: str, points: list[tuple[float, float]]) -> None:
        if len(points) < 2:
            return
        geometry_by_id.setdefault(oid, []).append(points)

    def _bounds_from_polylines(
        polylines: list[list[tuple[float, float]]],
    ) -> tuple[float, float, float, float] | None:
        xs: list[float] = []
        ys: list[float] = []
        for polyline in polylines:
            for x, y in polyline:
                xs.append(float(x))
                ys.append(float(y))
        if not xs or not ys:
            return None
        return (min(xs), min(ys), max(xs), max(ys))

    def _alignment_anchor(alignment: object | None) -> tuple[str, str]:
        if alignment is None:
            return ("start", "alphabetic")
        value = str(getattr(alignment, "value", alignment))
        if value.startswith("Left"):
            anchor = "start"
        elif value.startswith("Right"):
            anchor = "end"
        else:
            anchor = "middle"

        if value.endswith("Top"):
            baseline = "hanging"
        elif value.endswith("Bottom"):
            baseline = "text-after-edge"
        else:
            baseline = "middle"
        return (anchor, baseline)

    def _process_primitive(
        owner_id: str | None,
        primitive: object,
        matrix: tuple[float, float, float, float, float, float],
    ) -> None:
        if owner_id is None and not isinstance(primitive, Text):
            return

        if isinstance(primitive, PolyLine):
            points = [
                _apply_matrix(matrix, float(pt.x), float(pt.y))
                for pt in getattr(primitive, "points", [])
            ]
            _update_bounds(owner_id, points)
            _register_geometry(owner_id, points)
            if owner_id in piping_ids and len(points) >= 2:
                manifest.piping_paths.setdefault(owner_id, []).append(points)
            _collect_style(owner_id, primitive)
            return

        if isinstance(primitive, ConnectorLine):
            all_points: list[object] = []
            src = getattr(getattr(primitive, "source", None), "position", None)
            if src is not None:
                all_points.append(src)
            all_points.extend(getattr(primitive, "innerPoints", []) or [])
            tgt = getattr(getattr(primitive, "target", None), "position", None)
            if tgt is not None:
                all_points.append(tgt)
            points = [
                _apply_matrix(matrix, float(getattr(pt, "x", 0.0)), float(getattr(pt, "y", 0.0)))
                for pt in all_points
            ]
            _update_bounds(owner_id, points)
            _register_geometry(owner_id, points)
            if owner_id in piping_ids and len(points) >= 2:
                manifest.piping_paths.setdefault(owner_id, []).append(points)
            _collect_style(owner_id, primitive)
            return

        if isinstance(primitive, Polygon):
            points = [
                _apply_matrix(matrix, float(pt.x), float(pt.y))
                for pt in getattr(primitive, "points", [])
            ]
            _update_bounds(owner_id, points)
            _register_geometry(owner_id, points)
            if owner_id in piping_ids and len(points) >= 2:
                manifest.piping_paths.setdefault(owner_id, []).append(points)
            _collect_style(owner_id, primitive)
            return

        if isinstance(primitive, Ellipse):
            cx = float(getattr(getattr(primitive, "center", None), "x", 0.0) or 0.0)
            cy = float(getattr(getattr(primitive, "center", None), "y", 0.0) or 0.0)
            rx = float(getattr(primitive, "horizontalSemiAxis", 0.0) or 0.0)
            ry = float(getattr(primitive, "verticalSemiAxis", 0.0) or 0.0)
            sample: list[tuple[float, float]] = []
            for i in range(16):
                t = (2.0 * math.pi * i) / 16.0
                sample.append(_apply_matrix(matrix, cx + rx * math.cos(t), cy + ry * math.sin(t)))
            if sample:
                sample.append(sample[0])
            _update_bounds(owner_id, sample)
            _register_geometry(owner_id, sample)
            if owner_id in piping_ids and len(sample) >= 2:
                manifest.piping_paths.setdefault(owner_id, []).append(sample)
            _collect_style(owner_id, primitive)
            return

        if isinstance(primitive, EllipseArc):
            cx = float(getattr(getattr(primitive, "center", None), "x", 0.0) or 0.0)
            cy = float(getattr(getattr(primitive, "center", None), "y", 0.0) or 0.0)
            rx = float(getattr(primitive, "horizontalSemiAxis", 0.0) or 0.0)
            ry = float(getattr(primitive, "verticalSemiAxis", 0.0) or 0.0)
            start_deg = float(getattr(primitive, "startAngle", 0.0) or 0.0)
            end_deg = float(getattr(primitive, "endAngle", 0.0) or 0.0)

            sweep_deg = end_deg - start_deg
            if sweep_deg <= 0.0:
                sweep_deg += 360.0
            if sweep_deg >= 360.0 or math.isclose(sweep_deg, 0.0, abs_tol=1e-6):
                sweep_deg = 360.0

            segment_count = max(8, int(math.ceil((sweep_deg / 360.0) * 48.0)))
            sample: list[tuple[float, float]] = []
            for i in range(segment_count + 1):
                t_deg = start_deg + (sweep_deg * i / segment_count)
                t = math.radians(t_deg)
                sample.append(_apply_matrix(matrix, cx + rx * math.cos(t), cy + ry * math.sin(t)))

            if sweep_deg >= 360.0 and sample:
                sample.append(sample[0])

            _update_bounds(owner_id, sample)
            _register_geometry(owner_id, sample)
            if owner_id in piping_ids and len(sample) >= 2:
                manifest.piping_paths.setdefault(owner_id, []).append(sample)
            _collect_style(owner_id, primitive)
            return

        if isinstance(primitive, Text):
            px = float(getattr(getattr(primitive, "position", None), "x", 0.0) or 0.0)
            py = float(getattr(getattr(primitive, "position", None), "y", 0.0) or 0.0)
            tx, ty = _apply_matrix(matrix, px, py)
            anchor, baseline = _alignment_anchor(getattr(primitive, "alignment", None))
            color = getattr(primitive, "color", None)
            rgba = (
                int(getattr(color, "r", 20) or 20),
                int(getattr(color, "g", 20) or 20),
                int(getattr(color, "b", 20) or 20),
                220,
            )
            size = float(getattr(primitive, "size", 0.6) or 0.6)
            local_rot = float(getattr(primitive, "rotation", 0.0) or 0.0)
            matrix_rot = math.degrees(math.atan2(matrix[1], matrix[0]))
            manifest.text_labels.append(
                DiagramTextLabel(
                    text=str(getattr(primitive, "text", "") or ""),
                    x=tx,
                    y=ty,
                    color=rgba,
                    size=size,
                    anchor=anchor,
                    baseline=baseline,
                    rotation_deg=matrix_rot + local_rot,
                )
            )
            if owner_id is not None:
                _update_bounds(owner_id, [(tx, ty)])
            return

    def _walk_type_group(
        type_group: object,
        matrix: tuple[float, float, float, float, float, float],
        owner_id: str | None,
    ) -> None:
        for element in getattr(type_group, "elements", []) or []:
            if isinstance(element, ShapeUsage):
                shape = getattr(element, "shape", None)
                if shape is None:
                    continue
                composed = _matrix_mul(matrix, _shape_usage_matrix(element))
                for primitive in getattr(shape, "primitives", []) or []:
                    _process_primitive(owner_id, primitive, composed)
                continue
            if isinstance(element, GraphicalPrimitive):
                _process_primitive(owner_id, element, matrix)

    def _walk_group(
        group: object,
        matrix: tuple[float, float, float, float, float, float],
        inherited_owner_id: str | None,
    ) -> None:
        represents = getattr(group, "represents", None)
        owner_id = inherited_owner_id
        if represents is not None:
            rep_id = getattr(represents, "id", None)
            if rep_id:
                owner_id = str(rep_id)

        for nested in getattr(group, "groups", []) or []:
            if isinstance(nested, RepresentationGroup):
                _walk_group(nested, matrix, owner_id)
            elif isinstance(nested, RepresentationTypeGroup):
                _walk_type_group(nested, matrix, owner_id)

    for top_group in getattr(model.diagram, "groups", []) or []:
        if "RepresentationGroup" in type(top_group).__name__:
            _walk_group(top_group, _identity_matrix(), None)
        elif "RepresentationTypeGroup" in type(top_group).__name__:
            _walk_type_group(top_group, _identity_matrix(), None)
        elif type(top_group).__name__ == "Label":
            # Label group has no plant-object owner; process it so that its
            # Text primitives are added to manifest.text_labels for the crisp
            # text overlay layer (title block field values etc.).
            _walk_type_group(top_group, _identity_matrix(), None)

    try:
        from pydexpi.pydexpi_classes.pydexpi_classes import (
            ActuatingFunction,
            ActuatingSystem,
            TaggedPlantItem,
        )
        from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

        id_to_obj = {
            str(getattr(obj, "id")): obj
            for obj in get_all_instances_in_model(model)
            if getattr(obj, "id", None)
        }

        def _equipment_descendants_for_owner(owner_id: str, max_depth: int = 6) -> list[str]:
            owner_obj = id_to_obj.get(owner_id)
            if owner_obj is None:
                return [owner_id]

            resolved: list[str] = []
            seen_ids: set[str] = set()

            def _walk(node: object, depth: int) -> None:
                if node is None or depth < 0:
                    return
                node_id = getattr(node, "id", None)
                node_sid = str(node_id) if node_id is not None else None
                if node_sid is not None and node_sid in seen_ids:
                    return
                if node_sid is not None:
                    seen_ids.add(node_sid)
                    resolved.append(node_sid)

                for attr_name in ("chambers", "nozzles"):
                    for child in getattr(node, attr_name, []) or []:
                        _walk(child, depth - 1)

            _walk(owner_obj, max_depth)
            if not resolved:
                return [owner_id]
            return resolved

        def _aggregation_order(owner_id: str) -> tuple[int, str]:
            # An actuating function takes the geometry this loop aggregates for its
            # actuating system, so the systems come first. Iterating the set itself made
            # that depend on string hashing, which differs between runs.
            rank = 1 if isinstance(id_to_obj.get(owner_id), ActuatingFunction) else 0
            return rank, owner_id

        for owner_id in sorted(equipment_ids, key=_aggregation_order):
            owner_obj = id_to_obj.get(owner_id)
            if not isinstance(owner_obj, TaggedPlantItem | ActuatingSystem | ActuatingFunction):
                continue

            collected_polylines: list[list[tuple[float, float]]] = []
            collected_colors: list[tuple[int, int, int, int]] = []
            collected_dashes: list[tuple[float, ...]] = []
            collected_widths: list[float] = []
            if isinstance(owner_obj, TaggedPlantItem):
                related_ids = _equipment_descendants_for_owner(owner_id)
            elif isinstance(owner_obj, ActuatingSystem):
                related_ids = [owner_id]
                for attr_name in (
                    "controlledActuator",
                    "operatedValveReference",
                    "positioner",
                ):
                    value = getattr(owner_obj, attr_name, None)
                    if value is None:
                        continue
                    values = value if isinstance(value, list) else [value]
                    for child in values:
                        child_id = getattr(child, "id", None)
                        if child_id is not None:
                            related_ids.append(str(child_id))
            else:
                related_ids = [
                    sid
                    for sid in highlight_target_ids_for_actuating_function(owner_obj)
                    if sid != owner_id
                ]
                if not related_ids:
                    related_ids = [owner_id]

            for child_id in related_ids:
                collected_polylines.extend(geometry_by_id.get(child_id, []))
                collected_colors.extend(style_colors.get(child_id, []))
                collected_dashes.extend(style_dashes.get(child_id, []))
                collected_widths.extend(style_widths.get(child_id, []))

            if collected_polylines:
                geometry_by_id[owner_id] = collected_polylines
                aggregate = _bounds_from_polylines(collected_polylines)
                if aggregate is not None:
                    bounds_by_id[owner_id] = aggregate
            if collected_colors:
                style_colors[owner_id] = collected_colors
            if collected_dashes:
                style_dashes[owner_id] = collected_dashes
            if collected_widths:
                style_widths[owner_id] = collected_widths
    except Exception:
        # Keep manifest generation robust if pyDEXPI model internals evolve.
        pass

    for oid, (x0, y0, x1, y1) in bounds_by_id.items():
        if oid in equipment_ids:
            manifest.equipment_bounds[oid] = (
                x0,
                y0,
                max(0.1, x1 - x0),
                max(0.1, y1 - y0),
            )

    for oid, polylines in geometry_by_id.items():
        if oid in equipment_ids and polylines:
            manifest.equipment_paths[oid] = polylines

    for oid, values in style_colors.items():
        if oid in equipment_ids and values:
            manifest.equipment_colors[oid] = _preferred_equipment_color(values)
    for oid, values in style_dashes.items():
        if oid in equipment_ids and values:
            manifest.equipment_dash_patterns[oid] = [
                float(v) for v in Counter(values).most_common(1)[0][0]
            ]
    for oid, values in style_widths.items():
        if oid in equipment_ids and values:
            manifest.equipment_stroke_widths[oid] = float(Counter(values).most_common(1)[0][0])

    for oid, values in style_colors.items():
        if oid in piping_ids and values:
            manifest.pipe_colors[oid] = Counter(values).most_common(1)[0][0]
    for oid, values in style_dashes.items():
        if oid in piping_ids and values:
            manifest.pipe_dash_patterns[oid] = [
                float(v) for v in Counter(values).most_common(1)[0][0]
            ]
    for oid, values in style_widths.items():
        if oid in piping_ids and values:
            manifest.pipe_stroke_widths[oid] = float(Counter(values).most_common(1)[0][0])

    # Add title block (PlantMetaData) bounds derived from the Label group's PolyLine primitives.
    # This lets the canvas create a clickable hit-area over the title block even though the
    # Label group has no 'represents' link to a plant object.
    try:
        conceptual = getattr(model, "conceptualModel", None)
        meta = getattr(conceptual, "metaData", None)
        meta_id = getattr(meta, "id", None)
        if meta_id and model.diagram is not None:
            meta_id_str = str(meta_id)
            label_group = next(
                (
                    g
                    for g in getattr(model.diagram, "groups", []) or []
                    if type(g).__name__ == "Label"
                ),
                None,
            )
            if label_group is not None:
                all_pts: list[tuple[float, float]] = []
                for elem in getattr(label_group, "elements", []) or []:
                    if isinstance(elem, PolyLine):
                        for pt in getattr(elem, "points", []) or []:
                            all_pts.append((float(pt.x), float(pt.y)))
                if all_pts:
                    xs = [p[0] for p in all_pts]
                    ys = [p[1] for p in all_pts]
                    manifest.equipment_bounds[meta_id_str] = (
                        min(xs),
                        min(ys),
                        max(0.1, max(xs) - min(xs)),
                        max(0.1, max(ys) - min(ys)),
                    )
    except Exception:
        pass

    return manifest


def _import_draw_diagram() -> type:
    """Import ``DrawDiagram`` from pydexpi."""
    from pydexpi.exports.svg_export import DrawDiagram

    return DrawDiagram


def load_dexpi_file(path: str | Path) -> EngineeringModel:
    """Load a DEXPI file (XML or JSON) using pyDEXPI.

    Parameters
    ----------
    path : str or Path
        Path to the DEXPI file.

    Returns
    -------
    EngineeringModel
        The loaded model.

    Raises
    ------
    FileNotFoundError
        If the file does not exist.
    ValueError
        If the file format is not supported.
    Exception
        Any error from pyDEXPI during loading.
    """
    from pydexpi import load_json_file, load_xml_file

    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path}")

    suffix = path.suffix.lower()
    if suffix == ".xml":
        return load_xml_file(path)
    elif suffix == ".json":
        return load_json_file(path)
    else:
        raise ValueError(f"Unsupported file format: {suffix}. Expected .xml or .json")


def load_proteus_file(path: str | Path) -> EngineeringModel:
    """Load a ProteusXML (DEXPI 1.3) file and map it to the DEXPI 2.0 data model.

    Parameters
    ----------
    path : str or Path
        Path to the ProteusXML file.

    Returns
    -------
    EngineeringModel
        The loaded model mapped to DEXPI 2.0.1.

    Raises
    ------
    FileNotFoundError
        If the file does not exist.
    """
    from pydexpi.loaders.proteus_serializer import ProteusSerializer

    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path}")
    serializer = ProteusSerializer()
    return serializer.load_from_string(path.read_text(encoding="utf-8"))


def load_file_with_report(
    path: str | Path, *, strict: bool = True, proteus: bool = False
) -> tuple[EngineeringModel, list]:
    """Load a file and keep what the loader reported about it.

    :func:`load_dexpi_file` uses pyDEXPI's plain loaders, which discard their error registry:
    a file they read in part looks like a whole one. This keeps the registry, so the user can
    be told what was left out.

    Parameters
    ----------
    path : str or Path
        Path to the file.
    strict : bool, optional
        pyDEXPI's ``strict`` setting. ``False`` builds an object that lacks a mandatory
        attribute rather than leaving it out, and reports it. Proteus has no such setting.
    proteus : bool, optional
        Read the file as ProteusXML (DEXPI 1.3).

    Returns
    -------
    tuple of EngineeringModel and list of ErrorRegistryEntry
        The model, and every entry the loader recorded.

    Raises
    ------
    FileNotFoundError
        If the file does not exist.
    ValueError
        If the file format is not supported, or nothing could be loaded; a refused DEXPI 2.0
        conversion is a ``ConversionRefusedError``, which is a ``ValueError``.
    """
    from pydexpi.loaders.public import load_json_with_report, load_xml_with_report

    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path}")
    if proteus:
        from pydexpi.loaders.proteus_serializer import ProteusSerializer

        serializer = ProteusSerializer()
        model = serializer.load_from_string(path.read_text(encoding="utf-8"))
        registry = serializer.get_loading_errors()
        entries = registry.get_errors() if hasattr(registry, "get_errors") else list(registry)
        return model, list(entries)
    suffix = path.suffix.lower()
    if suffix == ".xml":
        report = load_xml_with_report(path.read_bytes(), strict=strict)
    elif suffix == ".json":
        report = load_json_with_report(path.read_bytes(), strict=strict)
    else:
        raise ValueError(f"Unsupported file format: {suffix}. Expected .xml or .json")
    return report.model, list(report.errors)


def render_svg(model: EngineeringModel) -> str | None:
    """Render the model's diagram as SVG using pyDEXPI.

    Parameters
    ----------
    model : EngineeringModel
        The loaded DEXPI model.

    Returns
    -------
    str or None
        SVG content as a string, or None if rendering is not possible
        (e.g., no diagram data in the model).
    """
    DrawDiagram = _import_draw_diagram()

    if model.diagram is None:
        return None

    diagram = _without_shapeless_usages(model.diagram)
    drawer = DrawDiagram(diagram, padding=5.0, pretty=True)
    svg_content = drawer.draw_svg(return_element=False, background=True)
    return svg_content


def _without_shapeless_usages(diagram: Any) -> Any:
    """Return the diagram, or a copy without what pyDEXPI 2.1.0's renderer cannot draw.

    A strict load that refuses an object leaves what pointed at it empty, and the renderer
    raises on the first such element, which costs the whole drawing:

    - a ``ShapeUsage`` whose ``Shape`` was refused has ``shape=None``;
    - a ``RepresentationGroup`` whose object was refused has ``represents=None``.

    There is nothing to draw for either, so the copy leaves them out and the rest of the
    drawing renders. The loaded model is not changed, and the Issues panel names what the
    loader refused. Remove this once pyDEXPI's renderer skips such elements itself.
    """
    from pydexpi.pydexpi_classes.pydexpi_classes import RepresentationGroup, ShapeUsage

    def undrawable(obj: Any) -> bool:
        if isinstance(obj, ShapeUsage):
            return obj.shape is None
        if isinstance(obj, RepresentationGroup):
            return obj.represents is None
        return False

    def holders(obj: Any, seen: set[int]):
        """Yield (object, list name) for every ``elements`` or ``groups`` list under *obj*."""
        if id(obj) in seen or not hasattr(type(obj), "model_fields"):
            return
        seen.add(id(obj))
        for name in ("elements", "groups"):
            if isinstance(getattr(obj, name, None), list):
                yield obj, name
        for name, field in type(obj).model_fields.items():
            extra = field.json_schema_extra
            if not isinstance(extra, dict) or extra.get("attribute_category") != "composition":
                continue
            value = getattr(obj, name, None)
            for child in value if isinstance(value, list) else [value]:
                yield from holders(child, seen)

    skipped = sum(
        undrawable(item)
        for holder, name in holders(diagram, set())
        for item in getattr(holder, name)
    )
    if not skipped:
        return diagram

    _log.warning("Not drawn: %d element(s) whose shape or object did not load", skipped)
    copy = deepcopy(diagram)
    for holder, name in list(holders(copy, set())):
        items = getattr(holder, name)
        if any(undrawable(item) for item in items):
            setattr(holder, name, [item for item in items if not undrawable(item)])
    return copy


#: The tables of ``export_tables``. Selecting all of them exports ``"all"``.
_ALL_TABLES = frozenset({"equipment", "line", "instrument", "piping component", "valve"})


def run_export(
    model: EngineeringModel,
    export_name: str,
    output_path: str | Path,
    options: dict[str, object] | None = None,
) -> str:
    """Run an export using existing pyDEXPI export functions.

    Parameters
    ----------
    model : EngineeringModel
        The loaded DEXPI model.
    export_name : str
        Name of the export (must match a known export capability).
    output_path : str or Path
        Where to write the export output. For tables, the extension is replaced by
        each chosen format's.
    options : dict, optional
        Keyword arguments of the pyDEXPI export function, as
        :func:`dexpi_studio.core.export_options.options_for` lists them. An option left
        out takes pyDEXPI's default.

    Returns
    -------
    str
        Success message.

    Raises
    ------
    ValueError
        If the export name is not recognized.
    """
    from pydexpi.exports import export_graphml, export_llm_context, export_neo4j_csv, export_tables

    output_path = Path(output_path)
    options = dict(options or {})

    if export_name == "GraphML":
        export_graphml(model, output_path, **options)
        return f"GraphML exported to {output_path}"
    elif export_name == "Tables":
        stem = output_path
        if stem.suffix.lower() in {".xlsx", ".csv", ".json"}:
            stem = stem.with_suffix("")
        if set(options.get("lists", ())) >= _ALL_TABLES:
            # One file holding every table, rather than a file per table.
            options["lists"] = ["all"]
        export_tables(model, str(stem), **options)
        return f"Tables exported to {stem.parent} as {stem.name}"
    elif export_name == "Neo4j CSV":
        output_path.mkdir(parents=True, exist_ok=True)
        export_neo4j_csv(model, output_path, **options)
        return f"Neo4j CSV exported to {output_path}"
    elif export_name == "LLM Context":
        export_llm_context(model, output_path, **options)
        return f"LLM context exported to {output_path}"
    elif export_name in {"Image PNG", "Image SVG", "Image PDF"}:
        if model.diagram is None:
            raise ValueError("Model has no diagram; image export is not available.")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        diagram_name = getattr(model.diagram, "name", "diagram") or "diagram"

        # Preferred path: DrawDiagram.save_svg/save_png/save_pdf
        DrawDiagram = _import_draw_diagram()
        drawer = DrawDiagram(diagram=model.diagram)
        method_name = {
            "Image PNG": "save_png",
            "Image SVG": "save_svg",
            "Image PDF": "save_pdf",
        }[export_name]
        method = getattr(drawer, method_name, None)
        if callable(method):
            method(diagram_name, str(output_path))
            return f"{export_name} exported to {output_path}"

        # Fallback path in some versions: pydexpi.exports.export_png/svg/pdf
        exports_mod = importlib.import_module("pydexpi.exports")
        fn_name = {
            "Image PNG": "export_png",
            "Image SVG": "export_svg",
            "Image PDF": "export_pdf",
        }[export_name]
        fn = getattr(exports_mod, fn_name, None)
        if callable(fn):
            fn(model, output_path)
        else:
            raise ValueError(f"{export_name} is not available in the installed pyDEXPI version.")
        return f"{export_name} exported to {output_path}"
    elif export_name == "DEXPI 2.0.1 XML":
        from pydexpi.loaders.xml_serializer import DexpiXmlSerializer

        output_path.parent.mkdir(parents=True, exist_ok=True)
        DexpiXmlSerializer().save(model, output_path.parent, output_path.stem)
        return f"DEXPI 2.0.1 XML exported to {output_path}"
    elif export_name == "DEXPI 2.0.1 JSON":
        from pydexpi.loaders.json_serializer import JsonSerializer

        output_path.parent.mkdir(parents=True, exist_ok=True)
        JsonSerializer().save(model, output_path.parent, output_path.stem)
        return f"DEXPI 2.0.1 JSON exported to {output_path}"
    elif export_name == "Git projection":
        from pydexpi.versioning import model_to_projection

        output_path.parent.mkdir(parents=True, exist_ok=True)
        # Bytes, as `pydexpi git-projection -o` writes them: the text is "\n"-separated
        # on every platform.
        output_path.write_bytes(model_to_projection(model, **options).encode("utf-8"))
        return f"Git projection exported to {output_path}"
    else:
        raise ValueError(f"Unknown export: {export_name}")


def model_summary(model: EngineeringModel):  # type: ignore[no-untyped-def]
    """Summarize the model with pyDEXPI, as ``pydexpi info`` does.

    Returns
    -------
    pydexpi.toolkits.model_summary.ModelSummary
        Counts cover the whole model, not only its top level.
    """
    from pydexpi.toolkits.model_summary import summarize_model

    return summarize_model(model)


def summary_counts(summary) -> list[tuple[str, str]]:  # type: ignore[no-untyped-def]
    """The counts ``pydexpi info`` prints, as (label, value) rows.

    The process rows appear only for a model that has process steps or connections.
    """
    rows = [
        ("Model type", summary.conceptual_model_type or "—"),
        ("Equipment", str(len(summary.equipment))),
        ("Piping network systems", str(summary.piping_system_count)),
        ("Piping segments", str(summary.piping_segment_count)),
        ("Piping components (incl. valves)", str(summary.piping_component_count)),
        ("Instruments", str(len(summary.instruments))),
    ]
    if summary.process_step_count or summary.process_connection_count:
        rows += [
            ("Process steps", str(summary.process_step_count)),
            ("Process connections", str(summary.process_connection_count)),
            ("Streams", str(summary.stream_count)),
            ("Energy flows", str(summary.energy_flow_count)),
            ("Information flows", str(summary.information_flow_count)),
        ]
    rows.append(("Objects", str(summary.total_objects)))
    return rows


def model_summary_text(summary) -> str:  # type: ignore[no-untyped-def]
    """The summary as plain text, for the clipboard: counts, then the tags, tab-separated."""
    from pydexpi.toolkits.display_name import humanize_class_name

    lines = [f"{label}\t{value}" for label, value in summary_counts(summary)]
    for title, entries in (("Equipment", summary.equipment), ("Instruments", summary.instruments)):
        if entries:
            lines += ["", f"{title}\tTag"]
            lines += [f"{humanize_class_name(entry.type)}\t{entry.tag or '—'}" for entry in entries]
    return "\n".join(lines) + "\n"


def run_diff(model_old: EngineeringModel, model_new: EngineeringModel):
    """Compare two DEXPI models with pyDEXPI's diff engine, matching objects by tag.

    Objects are matched by tag rather than by id because a DEXPI XML load mints a fresh
    id for every object the file does not identify, so two loads of one XML file would
    differ in every such object under ``pydexpi.diff.id_diff``. A changed tag is
    therefore reported as one object removed and one added.

    Parameters
    ----------
    model_old : EngineeringModel
        The baseline model.
    model_new : EngineeringModel
        The model to compare against the baseline.

    Returns
    -------
    pydexpi.diff.DiffResult
        Structured diff result with added, removed, modified, and moved objects.
    """
    from pydexpi.diff import PyDexpiDiffEngine, TagEquality

    return PyDexpiDiffEngine(TagEquality()).diff(model_old, model_new)


def build_id_index(model: EngineeringModel) -> dict[str, object]:
    """Build a flat ``{object_id: dexpi_object}`` index for the entire model.

    Used by the interactive canvas to resolve a clicked SVG element ID back to
    the corresponding pyDEXPI model object in O(1).

    Parameters
    ----------
    model : EngineeringModel
        The loaded DEXPI model.

    Returns
    -------
    dict[str, object]
        Mapping from DEXPI object ID strings (e.g. ``"id_3ccf7b0f…"``) to the
        corresponding ``PyDexpiBaseModel`` instances.  Only objects that have a
        non-empty ``.id`` attribute are included.
    """
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    index: dict[str, object] = {}
    for obj in get_all_instances_in_model(model):
        obj_id = getattr(obj, "id", None)
        if obj_id:
            key = str(obj_id)
            if key in index:
                _log.warning(
                    "Duplicate DEXPI object ID %r: existing=%r, incoming=%r — "
                    "keeping the first occurrence.",
                    key,
                    index[key],
                    obj,
                )
            else:
                index[key] = obj
    return index


def classify_ids(model: EngineeringModel) -> tuple[set[str], set[str]]:
    """Classify model object IDs into equipment and piping segment sets.

    Used by the SVG viewer to decide *how* to display hit areas and highlights:
    equipment items get a bounding-box rectangle; piping segments / connections
    get their actual polyline strokes highlighted.

    The two sets cover:

            * **equipment_ids** — ``TaggedPlantItem`` instances (vessels, pumps, …),
                ``ActuatingSystem`` and ``ActuatingFunction`` instances,
      ``Nozzle`` instances, *and* ``PipingNetworkSegmentItem`` instances
      (valves, fittings, off-page connectors, …) that live inside a piping
      segment.  All get a rectangular highlight overlay.

    * **piping_ids** — ``PipingNetworkSegment`` instances *and*
            ``PipingConnection`` instances (``Pipe``, ``DirectPipingConnection``, …),
                plus ``SignalConveyingFunction``,
                ``ProcessSignalGeneratingFunction``, and
                ``ProcessInstrumentationFunction`` instances used for signal paths.
                All get polyline-stroke highlights.

    Parameters
    ----------
    model : EngineeringModel
        The loaded DEXPI model.

    Returns
    -------
    tuple[set[str], set[str]]
        ``(equipment_ids, piping_ids)``
    """
    from pydexpi.pydexpi_classes.pydexpi_classes import (
        ActuatingFunction,
        ActuatingSystem,
        Nozzle,
        PipingConnection,
        PipingNetworkSegment,
        PipingNetworkSegmentItem,
        ProcessInstrumentationFunction,
        SignalConveyingFunction,
        TaggedPlantItem,
    )
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    all_objects = get_all_instances_in_model(model)

    equipment_ids: set[str] = {
        str(obj.id)
        for obj in all_objects
        if getattr(obj, "id", None)
        and isinstance(
            obj,
            TaggedPlantItem
            | PipingNetworkSegmentItem
            | ActuatingSystem
            | ActuatingFunction
            | Nozzle,
        )
    }
    piping_ids: set[str] = {
        str(obj.id)
        for obj in all_objects
        if getattr(obj, "id", None)
        and isinstance(
            obj,
            PipingNetworkSegment
            | PipingConnection
            | SignalConveyingFunction
            | ProcessInstrumentationFunction,
        )
        or (getattr(obj, "id", None) and type(obj).__name__ == "ProcessSignalGeneratingFunction")
    }
    return equipment_ids, piping_ids


def related_function_ids_for_process_instrumentation_function(obj: object) -> list[str]:
    """Return IDs of function objects composed within a ProcessInstrumentationFunction.

    Parameters
    ----------
    obj : object
        Any object. If it does not expose expected composition attributes,
        an empty list is returned.

    Returns
    -------
    list[str]
        Ordered unique IDs of included function objects from
        ``actuatingFunctions``, ``actuatingElectricalFunctions``, and
        ``signalConveyingFunctions``.
    """
    ids: list[str] = []
    seen: set[str] = set()

    for attr in ("actuatingFunctions", "actuatingElectricalFunctions", "signalConveyingFunctions"):
        values = getattr(obj, attr, None) or []
        for child in values:
            if attr in {"actuatingFunctions", "actuatingElectricalFunctions"}:
                child_ids = highlight_target_ids_for_actuating_function(child)
                for sid in child_ids:
                    if sid in seen:
                        continue
                    seen.add(sid)
                    ids.append(sid)
                continue

            oid = getattr(child, "id", None)
            if oid is not None:
                sid = str(oid)
                if sid not in seen:
                    seen.add(sid)
                    ids.append(sid)

    return ids


def highlight_target_ids_for_actuating_function(obj: object) -> list[str]:
    """Return drawable highlight IDs for an actuating function selection.

    Prefers the actuating function's own ID when present and also includes
    referenced ActuatingSystem IDs (``systems`` attribute), which are typically
    the drawable symbols in the SVG.
    """
    ids: list[str] = []
    seen: set[str] = set()

    own_id = getattr(obj, "id", None)
    if own_id is not None:
        sid = str(own_id)
        seen.add(sid)
        ids.append(sid)

    systems = getattr(obj, "systems", None)
    if systems is None:
        systems_list: list[object] = []
    elif isinstance(systems, list):
        systems_list = systems
    else:
        systems_list = [systems]

    for sys_obj in systems_list:
        sid_obj = getattr(sys_obj, "id", None)
        if sid_obj is None:
            continue
        sid = str(sid_obj)
        if sid in seen:
            continue
        seen.add(sid)
        ids.append(sid)

    return ids


def collect_highlight_ids(obj: object, max_depth: int = 4) -> list[str]:
    """Resolve any pyDEXPI object to the list of SVG element IDs to highlight.

    Leaf nodes return their own ID.  Container / parent nodes recursively
    aggregate their children's IDs so that selecting a high-level tree item
    (e.g. a ``PipingNetworkSystem``) highlights every drawable descendant.

    Parameters
    ----------
    obj : object
        Any pyDEXPI model object (typically a ``PyDexpiBaseModel``).
    max_depth : int
        Recursion guard to prevent infinite traversal on cyclic or very
        deep models.

    Returns
    -------
    list[str]
        Ordered-unique list of DEXPI object IDs suitable for
        ``DiagramView.highlight_ids``.
    """
    ids: list[str] = []
    seen: set[str] = set()
    _collect(obj, ids, seen, max_depth)
    return ids


def _collect(obj: object, ids: list[str], seen: set[str], depth: int) -> None:
    """Recursive workhorse for :func:`collect_highlight_ids`."""
    if obj is None or depth < 0:
        return

    from pydexpi.pydexpi_classes.pydexpi_classes import (
        ActuatingFunction,
        InstrumentationLoopFunction,
        PipingNetworkSegment,
        PipingNetworkSegmentItem,
        PipingNetworkSystem,
        ProcessInstrumentationFunction,
        PyDexpiBaseModel,
        TaggedPlantItem,
    )

    def _add(oid: object) -> None:
        if oid is not None:
            s = str(oid)
            if s not in seen:
                seen.add(s)
                ids.append(s)

    # --- leaf-like: own ID first ---
    own_id = getattr(obj, "id", None)
    if own_id is not None:
        _add(own_id)

    # --- PipingNetworkSystem: aggregate all segments ---
    if isinstance(obj, PipingNetworkSystem):
        for seg in getattr(obj, "segments", []):
            _collect(seg, ids, seen, depth - 1)
        return

    # --- PipingNetworkSegment: items + connections ---
    if isinstance(obj, PipingNetworkSegment):
        for item in getattr(obj, "items", []):
            _add(getattr(item, "id", None))
        for conn in getattr(obj, "connections", []):
            _add(getattr(conn, "id", None))
        return

    # --- PipingNetworkSegmentItem (valves/fittings): leaf-only ---
    if isinstance(obj, PipingNetworkSegmentItem):
        return

    # --- TaggedPlantItem (equipment): nozzles ---
    if isinstance(obj, TaggedPlantItem):
        for nozzle in getattr(obj, "nozzles", []):
            _add(getattr(nozzle, "id", None))
        return

    # --- ActuatingFunction: delegate to existing helper ---
    if isinstance(obj, ActuatingFunction):
        for sid in highlight_target_ids_for_actuating_function(obj):
            _add(sid)
        return

    # --- ProcessInstrumentationFunction: own + related functions ---
    if isinstance(obj, ProcessInstrumentationFunction):
        for sid in related_function_ids_for_process_instrumentation_function(obj):
            _add(sid)
        return

    # --- InstrumentationLoopFunction: aggregate referenced PIFs ---
    if isinstance(obj, InstrumentationLoopFunction):
        for pif in getattr(obj, "processInstrumentationFunctions", []):
            _collect(pif, ids, seen, depth - 1)
        return

    # --- Generic fallback: walk composition children ---
    if isinstance(obj, PyDexpiBaseModel) and depth > 0:
        try:
            from pydexpi.toolkits.base_model_utils import get_composition_attributes

            for _attr_name, attr_value in get_composition_attributes(obj).items():
                if attr_value is None:
                    continue
                if isinstance(attr_value, list):
                    for child in attr_value:
                        if isinstance(child, PyDexpiBaseModel):
                            _collect(child, ids, seen, depth - 1)
                elif isinstance(attr_value, PyDexpiBaseModel):
                    _collect(attr_value, ids, seen, depth - 1)
        except Exception:
            pass
