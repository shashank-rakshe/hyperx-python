"""Smoke tests for the FastAPI backend (skipped if FastAPI is not installed)."""

from __future__ import annotations

import pytest

pytest.importorskip("fastapi", reason="backend extra not installed")

from fastapi.testclient import TestClient

import cir
from backend.app import app

client = TestClient(app)


def test_healthz_reports_schema_version() -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["cir_schema_version"] == cir.SCHEMA_VERSION


def test_example_then_validate_roundtrips_over_http() -> None:
    example = client.get("/cir/example", params={"lane": "research"})
    assert example.status_code == 200

    summary = client.post("/cir/validate", json=example.json())
    assert summary.status_code == 200
    body = summary.json()
    assert body["valid"] is True
    assert body["entity_count"] >= 1
    assert body["is_commercial_safe"] is False  # the research example is CC-BY-NC


def test_validate_rejects_lane_violation() -> None:
    """Posting a commercial set built from non-commercial data is a 422."""
    doc = cir.to_dict(cir.make_example_drawing_set(data_lane=cir.DataLane.RESEARCH))
    doc["data_lane"] = "commercial"  # inconsistent: commercial set, CC-BY-NC provenance
    response = client.post("/cir/validate", json=doc)
    assert response.status_code == 422


def test_home_serves_demo_ui() -> None:
    r = client.get("/")
    assert r.status_code == 200 and "ConstructDrawing" in r.text


def test_takeoff_endpoint_returns_quantities() -> None:
    ex = client.get("/cir/example").json()
    r = client.post("/takeoff", json=ex)
    assert r.status_code == 200
    body = r.json()
    assert "total_count" in body and isinstance(body["lines"], list)
    assert "scale_known" in body


def test_ground_endpoint_reports_coverage() -> None:
    ex = client.get("/cir/example").json()
    body = client.post("/ground", json=ex).json()
    assert 0 <= body["grounded"] <= body["total"]


def test_qa_endpoint_answers_structure_question() -> None:
    ex = client.get("/cir/example").json()
    body = client.post("/qa", json={"drawing_set": ex, "question": "how many sheets"}).json()
    assert body["value"] == len(ex["sheets"])


def test_rfi_endpoint_returns_list() -> None:
    ex = client.get("/cir/example").json()
    r = client.post("/rfi", json=ex)
    assert r.status_code == 200 and isinstance(r.json(), list)


def test_api_key_required_when_configured(monkeypatch) -> None:
    monkeypatch.setenv("CDAI_API_KEY", "secret")
    ex = client.get("/cir/example").json()
    assert client.post("/takeoff", json=ex).status_code == 401
    assert client.post("/takeoff", json=ex, headers={"X-API-Key": "secret"}).status_code == 200


def test_detect_returns_503_without_configured_detector() -> None:
    r = client.post("/detect", files={"file": ("d.png", b"x", "image/png")})
    assert r.status_code == 503


def test_takeoff_from_image_with_stub_detector() -> None:
    from backend.app import app as _app
    from backend.detect import get_detector
    from cir import (
        DataLane,
        DrawingSet,
        Entity,
        EntityType,
        Geometry,
        LicenseProvenance,
        Sheet,
        View,
        ViewType,
    )

    class _Stub:
        def detect(self, image_bytes, discipline, *, conf=0.25):
            e = Entity(
                id="e0",
                entity_type=EntityType.SYMBOL,
                label="Duplex Receptacle",
                geometry=Geometry.box(0.1, 0.1, 0.2, 0.2),
                license_provenance=LicenseProvenance.UNKNOWN,
                data_lane=DataLane.RESEARCH,
                confidence=0.9,
            )
            return DrawingSet(
                name="up",
                sheets=[
                    Sheet(
                        sheet_number="S-1",
                        discipline="electrical",
                        views=[View(view_type=ViewType.PLAN, entities=[e])],
                    )
                ],
                license_provenance=LicenseProvenance.UNKNOWN,
                data_lane=DataLane.RESEARCH,
            )

    _app.dependency_overrides[get_detector] = lambda: _Stub()
    try:
        r = client.post(
            "/takeoff-from-image",
            params={"discipline": "electrical"},
            files={"file": ("d.png", b"x", "image/png")},
        )
        assert r.status_code == 200
        body = r.json()
        assert body["total_count"] == 1 and body["lines"][0]["item"] == "Duplex Receptacle"
    finally:
        _app.dependency_overrides.clear()
