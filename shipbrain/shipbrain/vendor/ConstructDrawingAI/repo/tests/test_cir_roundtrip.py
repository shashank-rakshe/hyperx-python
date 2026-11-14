"""Round-trip serialization tests for the CIR — the explicitly required tests.

A CIR document must survive a round trip through every codec byte-for-structure
identical: JSON, gzip-JSON, and the compact msgpack binary, plus the dict form.
These tests are the contract that lets every layer trust serialized CIR on disk and
over the wire.
"""

from __future__ import annotations

from pathlib import Path

import pytest

import cir
from cir import DataLane, DrawingSet, Entity, make_example_drawing_set

# (dumps, loads) codec pairs that operate on str/bytes payloads.
STRING_OR_BYTES_CODECS = [
    pytest.param(cir.to_json, cir.from_json, id="json"),
    pytest.param(cir.to_gzip_json, cir.from_gzip_json, id="gzip-json"),
    pytest.param(cir.to_msgpack, cir.from_msgpack, id="msgpack"),
]

LANES = [
    pytest.param(DataLane.RESEARCH, id="research"),
    pytest.param(DataLane.COMMERCIAL, id="commercial"),
]


@pytest.mark.parametrize("dumps,loads", STRING_OR_BYTES_CODECS)
@pytest.mark.parametrize("lane", LANES)
def test_roundtrip_equals_original(dumps, loads, lane) -> None:
    """dump → load reproduces an equal DrawingSet for every codec and lane."""
    original = make_example_drawing_set(data_lane=lane)
    restored = loads(DrawingSet, dumps(original))
    assert restored == original


@pytest.mark.parametrize("lane", LANES)
def test_dict_roundtrip(lane) -> None:
    """The dict form round-trips too."""
    original = make_example_drawing_set(data_lane=lane)
    restored = cir.from_dict(DrawingSet, cir.to_dict(original))
    assert restored == original


def test_roundtrip_is_idempotent(research_set: DrawingSet) -> None:
    """Serializing a restored document yields byte-identical JSON (stable output)."""
    once = cir.to_json(research_set)
    twice = cir.to_json(cir.from_json(DrawingSet, once))
    assert once == twice


def test_schema_version_is_stamped_and_preserved(research_set: DrawingSet) -> None:
    """Every DrawingSet carries the current schema version, and it survives a round trip."""
    assert research_set.schema_version == cir.SCHEMA_VERSION
    payload = cir.to_dict(research_set)
    assert payload["schema_version"] == cir.SCHEMA_VERSION
    assert cir.from_dict(DrawingSet, payload).schema_version == cir.SCHEMA_VERSION


def test_enums_and_nesting_survive_roundtrip(research_set: DrawingSet) -> None:
    """Enums come back as enum instances and the full hierarchy is preserved."""
    restored = cir.from_json(DrawingSet, cir.to_json(research_set))

    assert isinstance(restored.license_provenance, cir.LicenseProvenance)
    assert isinstance(restored.data_lane, cir.DataLane)

    sheet = restored.sheets[0]
    assert sheet.discipline is cir.Discipline.ELECTRICAL
    assert sheet.discipline.code == "E"

    plan = sheet.views[0]
    assert plan.view_type is cir.ViewType.PLAN
    # Connectivity edges survive and still reference real entity ids.
    entity_ids = {e.id for e in restored.iter_entities()}
    for conn in plan.connections:
        assert conn.source_id in entity_ids
        assert conn.target_id in entity_ids


def test_entity_counts_and_content_preserved(research_set: DrawingSet) -> None:
    """Counts and representative leaf values match after a binary round trip."""
    restored = cir.from_msgpack(DrawingSet, cir.to_msgpack(research_set))
    assert restored.entity_count() == research_set.entity_count()

    panels = [e for e in restored.iter_entities() if e.ifc_class == "IfcElectricDistributionBoard"]
    assert len(panels) == 1
    assert panels[0].ontology.masterformat == "26 24 16"

    dims = [d for e in restored.iter_entities() for d in e.dimensions]
    assert any(d.value_mm == 3810.0 for d in dims)


def test_submodel_roundtrip(research_set: DrawingSet) -> None:
    """An individual Entity (a sub-model) round-trips on its own."""
    entity = next(research_set.iter_entities())
    restored = cir.from_msgpack(Entity, cir.to_msgpack(entity))
    assert restored == entity


@pytest.mark.parametrize("lane", LANES)
def test_binary_forms_are_compact(lane) -> None:
    """The binary codecs are smaller than indented JSON (they are the storage form)."""
    ds = make_example_drawing_set(data_lane=lane)
    json_bytes = cir.to_json(ds, indent=2).encode("utf-8")
    assert len(cir.to_msgpack(ds)) < len(json_bytes)
    assert len(cir.to_gzip_json(ds)) < len(json_bytes)


@pytest.mark.parametrize("suffix", [".json", ".json.gz", ".cir", ".msgpack", ".mpk"])
def test_save_load_files(tmp_path: Path, research_set: DrawingSet, suffix: str) -> None:
    """save() / load() round-trip through every supported on-disk format."""
    path = tmp_path / f"drawing_set{suffix}"
    cir.save(research_set, path)
    assert path.exists()
    assert cir.load(DrawingSet, path) == research_set


def test_save_rejects_unknown_suffix(tmp_path: Path, research_set: DrawingSet) -> None:
    """An unknown file suffix is a clear error, not a silent mis-serialization."""
    with pytest.raises(cir.SerializationError):
        cir.save(research_set, tmp_path / "drawing_set.bin")


def test_load_rejects_incompatible_schema_version(research_set: DrawingSet) -> None:
    """A document from an incompatible MAJOR schema version is refused on load."""
    payload = cir.to_dict(research_set)
    payload["schema_version"] = "99.0.0"
    with pytest.raises(cir.SchemaVersionError):
        cir.from_dict(DrawingSet, payload)
