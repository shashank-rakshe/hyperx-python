"""A9 annotation pipeline: CIR↔Label-Studio mapping, selection, and export ingest."""

from __future__ import annotations

import json

import cir
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
from perception.annotation import (
    cir_to_ls_results,
    ingest_label_studio_export,
    label_config,
    ls_results_to_entities,
    select_sheets,
)

_PROV = {"license_provenance": LicenseProvenance.UNKNOWN, "data_lane": DataLane.RESEARCH}


def test_cir_to_ls_percent_and_back() -> None:
    ent = Entity(
        entity_type=EntityType.SYMBOL,
        label="Duplex Receptacle",
        geometry=Geometry.box(0.10, 0.20, 0.30, 0.50),
        confidence=1.0,
        **_PROV,
    )
    ds = DrawingSet(
        sheets=[Sheet(sheet_number="E-101", views=[View(view_type=ViewType.PLAN, entities=[ent])])],
        **_PROV,
    )
    results = cir_to_ls_results(ds)
    assert len(results) == 1
    v = results[0]["value"]
    assert (v["x"], v["y"], v["width"], v["height"]) == (10.0, 20.0, 20.0, 30.0)
    assert v["rectanglelabels"] == ["Duplex Receptacle"]

    # round-trip back to CIR entities (percent -> normalized)
    back = ls_results_to_entities(results)
    assert len(back) == 1 and back[0].label == "Duplex Receptacle"
    box = back[0].geometry.bounds()
    assert abs(box.x_min - 0.10) < 1e-9 and abs(box.y_max - 0.50) < 1e-9


def test_label_config_lists_classes() -> None:
    cfg = label_config(["Duplex Receptacle", "Panelboard"])
    assert "RectangleLabels" in cfg
    assert 'value="Duplex Receptacle"' in cfg and 'value="Panelboard"' in cfg


def _index(n_projects: int) -> dict:
    return {
        "sets": [
            {
                "project": f"P{i}",
                "filename": f"P{i}.pdf",
                "pages": [
                    {"page": 0, "sheet_no": "E-101", "discipline_letter": "E"},
                    {"page": 1, "sheet_no": "E-102", "discipline_letter": "E"},
                    {"page": 2, "sheet_no": "A-101", "discipline_letter": "A"},
                ],
            }
            for i in range(n_projects)
        ]
    }


def test_select_sheets_spreads_across_projects() -> None:
    picked = select_sheets(_index(6), letter="E", count=6, min_projects=5)
    assert len(picked) == 6
    # round-robin: the first 6 picks are one E-sheet from each of 6 distinct projects
    assert len({p["project"] for p in picked}) == 6
    assert all(p["sheet_no"].startswith("E") for p in picked)


def test_select_sheets_requires_min_projects() -> None:
    import pytest

    with pytest.raises(ValueError, match="projects"):
        select_sheets(_index(3), letter="E", count=4, min_projects=5)


def test_ingest_export_writes_loadable_cir_pairs(tmp_path) -> None:
    from PIL import Image

    images = tmp_path / "images"
    images.mkdir()
    Image.new("RGB", (200, 100), "white").save(images / "P1_E-101_p0.png")
    export = [
        {
            "data": {"image": "images/P1_E-101_p0.png"},
            "annotations": [
                {
                    "result": [
                        {
                            "type": "rectanglelabels",
                            "value": {
                                "x": 10,
                                "y": 20,
                                "width": 20,
                                "height": 30,
                                "rectanglelabels": ["GFCI Receptacle"],
                            },
                        }
                    ]
                }
            ],
        }
    ]
    export_path = tmp_path / "export.json"
    export_path.write_text(json.dumps(export))
    out = tmp_path / "real"
    n = ingest_label_studio_export(export_path, out, images_dir=images)
    assert n == 1
    assert (out / "P1_E-101_p0.png").is_file()  # image copied for the scoreboard loader
    ds = cir.load(DrawingSet, str(out / "P1_E-101_p0.cir"))
    ents = list(ds.iter_entities())
    assert len(ents) == 1 and ents[0].label == "GFCI Receptacle"
    assert ds.metadata["annotated"] is True
