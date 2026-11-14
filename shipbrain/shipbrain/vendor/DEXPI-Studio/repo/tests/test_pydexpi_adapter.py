"""Tests for the pyDEXPI adapter layer."""

import importlib
from pathlib import Path

import pydexpi.exports as exports_mod
import pytest

from dexpi_studio.core.pydexpi_adapter import (
    build_diagram_render_manifest,
    classify_ids,
    collect_highlight_ids,
    highlight_target_ids_for_actuating_function,
    load_dexpi_file,
    related_function_ids_for_process_instrumentation_function,
    render_svg,
    run_export,
)


def _import_draw_diagram():  # type: ignore[no-untyped-def]
    for module_name in ("pydexpi.exports.svg_export", "pydexpi.loaders.svg_loader"):
        try:
            module = importlib.import_module(module_name)
        except ImportError:
            continue
        draw_diagram = getattr(module, "DrawDiagram", None)
        if draw_diagram is not None:
            return draw_diagram
    raise RuntimeError("DrawDiagram not available in installed pyDEXPI")


DrawDiagram = _import_draw_diagram()

_REFERENCE_PID: Path = Path(__file__).parent.parent / "data" / "reference_pid.xml"


@pytest.fixture
def sample_model():
    """Load the reference DEXPI model for testing."""
    from pydexpi import load_xml_file

    return load_xml_file(_REFERENCE_PID)


def test_load_dexpi_file_xml():
    """Loading a valid XML file should return an EngineeringModel."""
    from pydexpi.pydexpi_classes import EngineeringModel

    model = load_dexpi_file(_REFERENCE_PID)
    assert isinstance(model, EngineeringModel)


def test_load_dexpi_file_not_found():
    """Loading a nonexistent file should raise FileNotFoundError."""
    with pytest.raises(FileNotFoundError):
        load_dexpi_file("/nonexistent/path/file.xml")


def test_load_dexpi_file_unsupported_format(tmp_path):
    """Loading an unsupported format should raise ValueError."""
    bad_file = tmp_path / "test.txt"
    bad_file.write_text("not dexpi")
    with pytest.raises(ValueError, match="Unsupported file format"):
        load_dexpi_file(bad_file)


def test_render_svg_returns_string(sample_model):
    """render_svg should return an SVG string if diagram exists."""
    result = render_svg(sample_model)
    if sample_model.diagram is not None:
        assert isinstance(result, str)
        assert "<svg" in result
    else:
        assert result is None


def test_render_svg_no_diagram():
    """render_svg returns None for a model without a diagram."""
    from pydexpi.pydexpi_classes import EngineeringModel, PlantModel

    model = EngineeringModel(conceptualModel=PlantModel())
    result = render_svg(model)
    assert result is None


def test_render_svg_draws_the_rest_when_a_shape_did_not_load():
    """A shape the load refused leaves its usages without one; the rest is still drawn."""
    import re

    from pydexpi.loaders.public import load_xml_bytes
    from pydexpi.pydexpi_classes.pydexpi_classes import ShapeUsage
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    document, removed = re.subn(
        rb'<Data property="SymbolRegistrationNumber">\s*<String>[^<]*</String>\s*</Data>',
        b"",
        _REFERENCE_PID.read_bytes(),
        count=1,
    )
    assert removed == 1
    model = load_xml_bytes(document)
    shapeless = [
        obj
        for obj in get_all_instances_in_model(model)
        if isinstance(obj, ShapeUsage) and obj.shape is None
    ]
    assert shapeless

    result = render_svg(model)

    assert result is not None and "<svg" in result
    assert all(usage.shape is None for usage in shapeless)  # the model is not changed


def test_run_export_optional_image_png(monkeypatch, sample_model, tmp_path):
    """run_export should prefer DrawDiagram.save_png when available."""
    calls: list[tuple[str, Path]] = []

    def _save_png(self, diagram_name: str, filepath: str) -> None:  # type: ignore[no-untyped-def]
        calls.append((diagram_name, Path(filepath)))

    monkeypatch.setattr(DrawDiagram, "save_png", _save_png, raising=False)
    # Ensure fallback path is not taken
    monkeypatch.delattr(exports_mod, "export_png", raising=False)

    out = tmp_path / "diagram.png"
    msg = run_export(sample_model, "Image PNG", out)

    assert calls and calls[0][1] == out
    assert "Image PNG exported to" in msg


def test_run_export_optional_image_pdf(monkeypatch, sample_model, tmp_path):
    """run_export should prefer DrawDiagram.save_pdf when available."""
    calls: list[tuple[str, Path]] = []

    def _save_pdf(self, diagram_name: str, filepath: str) -> None:  # type: ignore[no-untyped-def]
        calls.append((diagram_name, Path(filepath)))

    monkeypatch.setattr(DrawDiagram, "save_pdf", _save_pdf, raising=False)
    # Ensure fallback path is not taken
    monkeypatch.delattr(exports_mod, "export_pdf", raising=False)

    out = tmp_path / "diagram.pdf"
    msg = run_export(sample_model, "Image PDF", out)

    assert calls and calls[0][1] == out
    assert "Image PDF exported to" in msg


def test_classify_ids_actuating_vs_signal_functions(sample_model):
    """Actuating functions are equipment-like; signal/PIF/PSGF functions are line-like."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    equipment_ids, piping_ids = classify_ids(sample_model)

    actuating_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ActuatingFunction"
    ]
    signal_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and type(obj).__name__ == "SignalConveyingFunction"
    ]
    pif_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ProcessInstrumentationFunction"
    ]
    psgf_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ProcessSignalGeneratingFunction"
    ]

    if not actuating_ids and not signal_ids and not pif_ids and not psgf_ids:
        pytest.skip("No relevant function objects present in sample model")

    for oid in actuating_ids:
        assert oid in equipment_ids

    for oid in signal_ids + pif_ids + psgf_ids:
        assert oid in piping_ids


def test_related_function_ids_for_process_instrumentation_function(sample_model):
    """Collect included actuating and signal-conveying function IDs from a PIF."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    pif = next(
        (
            obj
            for obj in get_all_instances_in_model(sample_model)
            if type(obj).__name__ == "ProcessInstrumentationFunction" and getattr(obj, "id", None)
        ),
        None,
    )
    if pif is None:
        pytest.skip("No ProcessInstrumentationFunction in sample model")

    related_ids = related_function_ids_for_process_instrumentation_function(pif)

    expected_ids: list[str] = []
    for attr in ("actuatingFunctions", "actuatingElectricalFunctions", "signalConveyingFunctions"):
        for child in getattr(pif, attr, None) or []:
            if attr in {"actuatingFunctions", "actuatingElectricalFunctions"}:
                expected_ids.extend(highlight_target_ids_for_actuating_function(child))
                continue
            oid = getattr(child, "id", None)
            if oid:
                expected_ids.append(str(oid))

    assert related_ids == list(dict.fromkeys(expected_ids))


def test_highlight_target_ids_for_actuating_function_includes_referenced_system(sample_model):
    """Actuating-function highlight targets include linked actuating-system IDs."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    actuating = next(
        (
            obj
            for obj in get_all_instances_in_model(sample_model)
            if type(obj).__name__ == "ActuatingFunction" and getattr(obj, "id", None)
        ),
        None,
    )
    if actuating is None:
        pytest.skip("No ActuatingFunction in sample model")

    ids = highlight_target_ids_for_actuating_function(actuating)
    assert str(actuating.id) in ids

    systems = getattr(actuating, "systems", None)
    if systems is None:
        system_ids: list[str] = []
    elif isinstance(systems, list):
        system_ids = [str(s.id) for s in systems if getattr(s, "id", None)]
    else:
        system_ids = [str(systems.id)] if getattr(systems, "id", None) else []

    for sid in system_ids:
        assert sid in ids


# ---------------------------------------------------------------------------
# collect_highlight_ids tests
# ---------------------------------------------------------------------------


def test_collect_highlight_ids_leaf_equipment(sample_model):
    """A TaggedPlantItem leaf should return its own ID plus nozzle IDs."""
    pm = sample_model.conceptualModel
    tpi = pm.taggedPlantItems[0] if pm.taggedPlantItems else None
    if tpi is None:
        pytest.skip("No TaggedPlantItem in sample model")

    ids = collect_highlight_ids(tpi)
    assert str(tpi.id) == ids[0]
    nozzle_ids = [str(n.id) for n in getattr(tpi, "nozzles", []) if getattr(n, "id", None)]
    for nid in nozzle_ids:
        assert nid in ids


def test_collect_highlight_ids_piping_network_system(sample_model):
    """A PipingNetworkSystem should aggregate all segment, item, and connection IDs."""
    pm = sample_model.conceptualModel
    pns = next((p for p in pm.pipingNetworkSystems if p.segments), None)
    if pns is None:
        pytest.skip("No PipingNetworkSystem with segments in sample model")

    ids = collect_highlight_ids(pns)
    assert str(pns.id) in ids
    for seg in pns.segments:
        if getattr(seg, "id", None):
            assert str(seg.id) in ids
        for item in getattr(seg, "items", []):
            if getattr(item, "id", None):
                assert str(item.id) in ids
        for conn in getattr(seg, "connections", []):
            if getattr(conn, "id", None):
                assert str(conn.id) in ids


def test_collect_highlight_ids_piping_network_segment(sample_model):
    """A PipingNetworkSegment should include its own ID plus items and connections."""
    pm = sample_model.conceptualModel
    seg = None
    for pns in pm.pipingNetworkSystems:
        for s in pns.segments:
            if getattr(s, "items", []) or getattr(s, "connections", []):
                seg = s
                break
        if seg:
            break
    if seg is None:
        pytest.skip("No PipingNetworkSegment with children in sample model")

    ids = collect_highlight_ids(seg)
    assert str(seg.id) == ids[0]
    assert len(ids) > 1


def test_collect_highlight_ids_piping_network_segment_item_is_leaf(sample_model):
    """A segment item (e.g., valve) should highlight only its own ID."""
    pm = sample_model.conceptualModel
    seg_item = None
    for pns in pm.pipingNetworkSystems:
        for seg in pns.segments:
            items = getattr(seg, "items", [])
            if items:
                seg_item = items[0]
                break
        if seg_item is not None:
            break

    if seg_item is None or not getattr(seg_item, "id", None):
        pytest.skip("No PipingNetworkSegmentItem with ID in sample model")

    ids = collect_highlight_ids(seg_item)
    assert ids == [str(seg_item.id)]


def test_collect_highlight_ids_process_instrumentation_function(sample_model):
    """A ProcessInstrumentationFunction should include its own ID plus related function IDs."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    pif = next(
        (
            obj
            for obj in get_all_instances_in_model(sample_model)
            if type(obj).__name__ == "ProcessInstrumentationFunction" and getattr(obj, "id", None)
        ),
        None,
    )
    if pif is None:
        pytest.skip("No ProcessInstrumentationFunction in sample model")

    ids = collect_highlight_ids(pif)
    assert str(pif.id) in ids
    related = related_function_ids_for_process_instrumentation_function(pif)
    for rid in related:
        assert rid in ids


def test_collect_highlight_ids_instrumentation_loop_function(sample_model):
    """An InstrumentationLoopFunction should aggregate its referenced PIFs."""
    pm = sample_model.conceptualModel
    ilf = next(
        (f for f in pm.instrumentationLoopFunctions if getattr(f, "id", None)),
        None,
    )
    if ilf is None:
        pytest.skip("No InstrumentationLoopFunction in sample model")

    ids = collect_highlight_ids(ilf)
    assert str(ilf.id) in ids
    for pif in getattr(ilf, "processInstrumentationFunctions", []):
        if getattr(pif, "id", None):
            assert str(pif.id) in ids


def test_collect_highlight_ids_no_duplicates(sample_model):
    """collect_highlight_ids should never return duplicate IDs."""
    pm = sample_model.conceptualModel
    pns = next((p for p in pm.pipingNetworkSystems if p.segments), None)
    if pns is None:
        pytest.skip("No PipingNetworkSystem with segments")

    ids = collect_highlight_ids(pns)
    assert len(ids) == len(set(ids))


def test_classify_ids_includes_nozzles(sample_model):
    """Nozzle IDs should be classified as equipment."""
    equipment_ids, _piping_ids = classify_ids(sample_model)
    pm = sample_model.conceptualModel
    nozzle_ids = [
        str(n.id)
        for tpi in pm.taggedPlantItems
        for n in getattr(tpi, "nozzles", [])
        if getattr(n, "id", None)
    ]
    if not nozzle_ids:
        pytest.skip("No nozzles in sample model")
    for nid in nozzle_ids:
        assert nid in equipment_ids


def test_build_manifest_tagged_plant_item_aggregates_nozzle_chamber_geometry(sample_model):
    """TaggedPlantItem geometry should include drawable nozzle/chamber descendant primitives."""
    equipment_ids, piping_ids = classify_ids(sample_model)
    manifest = build_diagram_render_manifest(sample_model, equipment_ids, piping_ids)

    pm = sample_model.conceptualModel
    candidates = [
        tpi
        for tpi in getattr(pm, "taggedPlantItems", [])
        if getattr(tpi, "id", None)
        and (getattr(tpi, "nozzles", None) or getattr(tpi, "chambers", None))
    ]
    if not candidates:
        pytest.skip("No TaggedPlantItem with nozzle/chamber descendants")

    found_aggregated = False
    for tpi in candidates:
        tagged_id = str(tpi.id)
        descendant_ids = [
            str(obj.id)
            for attr_name in ("chambers", "nozzles")
            for obj in (getattr(tpi, attr_name, None) or [])
            if getattr(obj, "id", None)
        ]
        if not descendant_ids:
            continue

        if not any(manifest.equipment_paths.get(desc_id) for desc_id in descendant_ids):
            continue

        assert manifest.equipment_paths.get(tagged_id), (
            f"Expected tagged plant item {tagged_id} to aggregate descendant geometry "
            f"from {descendant_ids}"
        )
        found_aggregated = True
        break

    assert found_aggregated, "Expected at least one tagged plant item with aggregated geometry"


def test_build_manifest_process_instrumentation_function_contains_bubble_geometry(sample_model):
    """Known ProcessInstrumentationFunction should include circle/bubble polyline paths."""
    target_id = "id_0521c8d59ef9471a8da1709d6c8539f2"
    equipment_ids, piping_ids = classify_ids(sample_model)

    manifest = build_diagram_render_manifest(sample_model, equipment_ids, piping_ids)
    if target_id not in piping_ids:
        pytest.skip(f"{target_id} not present in reference fixture")

    paths = manifest.piping_paths.get(target_id, [])
    assert paths, f"Expected piping paths for ProcessInstrumentationFunction {target_id}"

    # Bubble geometry should be sampled with multiple points; pure connector lines
    # typically have only a few points.
    assert any(len(polyline) >= 8 for polyline in paths), (
        f"Expected sampled bubble/circle geometry for {target_id}"
    )


def test_build_manifest_actuating_system_contains_drawable_geometry(sample_model):
    """ActuatingSystem should aggregate drawable geometry from composed actuator objects."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    equipment_ids, piping_ids = classify_ids(sample_model)
    manifest = build_diagram_render_manifest(sample_model, equipment_ids, piping_ids)

    system_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ActuatingSystem"
    ]
    if not system_ids:
        pytest.skip("No ActuatingSystem instances in sample model")

    assert any(manifest.equipment_paths.get(sid) for sid in system_ids), (
        "Expected at least one ActuatingSystem to expose aggregated equipment path geometry"
    )


def test_build_manifest_actuating_function_has_drawable_geometry(sample_model):
    """ActuatingFunction IDs should resolve to concrete geometry (not renderer fallback)."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    equipment_ids, piping_ids = classify_ids(sample_model)
    manifest = build_diagram_render_manifest(sample_model, equipment_ids, piping_ids)

    function_objects = [
        obj
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ActuatingFunction"
    ]
    if not function_objects:
        pytest.skip("No ActuatingFunction instances in sample model")

    covered = set(manifest.equipment_bounds) | set(manifest.equipment_paths)
    expected_covered = []
    for obj in function_objects:
        own_id = str(obj.id)
        target_ids = [
            sid for sid in highlight_target_ids_for_actuating_function(obj) if sid != own_id
        ]
        if target_ids:
            expected_covered.append(own_id)

    if not expected_covered:
        pytest.skip("No ActuatingFunction instances with drawable target systems")

    # All of them, in every run: whether one was covered once depended on string hashing.
    assert all(fid in covered for fid in expected_covered), (
        "Expected every ActuatingFunction with related target systems to be "
        "covered in manifest geometry"
    )


def test_build_manifest_includes_title_block_bounds(sample_model):
    """PlantMetaData (title block) bounds should be present in manifest.equipment_bounds."""
    equipment_ids, piping_ids = classify_ids(sample_model)
    meta = getattr(getattr(sample_model, "conceptualModel", None), "metaData", None)
    if meta is None:
        pytest.skip("No PlantMetaData in sample model")
    meta_id = str(meta.id)
    equipment_ids.add(meta_id)
    manifest = build_diagram_render_manifest(sample_model, equipment_ids, piping_ids)
    assert meta_id in manifest.equipment_bounds, (
        "Expected PlantMetaData id to have bounds in manifest.equipment_bounds"
    )
    x, y, w, h = manifest.equipment_bounds[meta_id]
    assert w > 0 and h > 0, "Title block bounds should have positive width and height"


def test_build_manifest_pump_prefers_non_neutral_equipment_color(sample_model):
    """Pump symbols should prefer process color (e.g. red) over neutral black details."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    equipment_ids, piping_ids = classify_ids(sample_model)
    manifest = build_diagram_render_manifest(sample_model, equipment_ids, piping_ids)

    pump_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(sample_model)
        if getattr(obj, "id", None) and "Pump" in type(obj).__name__
    ]
    if not pump_ids:
        pytest.skip("No pump objects in sample model")

    colored_pumps = [pid for pid in pump_ids if pid in manifest.equipment_colors]
    if not colored_pumps:
        pytest.skip("No pump equipment colors generated in manifest")

    # In the reference model pumps contain both black details and red process strokes;
    # manifest selection should preserve the non-neutral process color.
    assert any(
        (manifest.equipment_colors[pid][0] > manifest.equipment_colors[pid][1])
        and (manifest.equipment_colors[pid][0] > manifest.equipment_colors[pid][2])
        for pid in colored_pumps
    ), "Expected at least one pump to prefer a red-dominant equipment color"
