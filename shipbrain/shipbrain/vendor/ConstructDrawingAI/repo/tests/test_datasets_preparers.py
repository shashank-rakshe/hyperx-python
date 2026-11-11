"""Offline tests for the dataset preparers (converters + audit).

These seed tiny synthetic raw inputs into a tmp ``data_root`` so they never touch the
network: ``download()`` is a no-op because the raw dir is already populated. They pin
the native-annotation → CIR conversion for PIDQA (CSV QA) and DELP (Pascal-VOC ground
truth only), and the prepared-data license audit.
"""

from __future__ import annotations

from pathlib import Path

from cir import DataLane, DrawingSet, LicenseProvenance, load
from datasets import DatasetRegistry
from datasets.audit import audit_prepared
from datasets.preparers import available_preparers, get_preparer_class, has_preparer
from datasets.preparers.delp import DELPPreparer
from datasets.preparers.pidqa import PIDQAPreparer


def _record(name: str):
    return DatasetRegistry.load().get(name)


def test_preparer_registry() -> None:
    assert set(available_preparers()) == {"PIDQA", "DELP-SkeySpot"}
    assert has_preparer("pidqa")  # case-insensitive
    assert get_preparer_class("DELP-SkeySpot") is DELPPreparer


def test_pidqa_converts_csv_to_one_drawing_set_per_sheet(tmp_path: Path) -> None:
    preparer = PIDQAPreparer(_record("PIDQA"), data_root=tmp_path)
    csv_dir = preparer.raw_dir / "Simple Counting"
    csv_dir.mkdir(parents=True)
    (csv_dir / "simple_counting.csv").write_text(
        "P&ID_number,Type,Symbol_Class,Q_id,Question,GT,Cypher\n"
        "0,Count,1,10,How many class 1?,2,MATCH (s) RETURN count(s)\n"
        "1,Count,2,11,How many class 2?,3,MATCH (s) RETURN count(s)\n",
        encoding="utf-8",
    )

    docs = list(preparer.convert())
    assert [d.id for d in docs] == ["pidqa-0", "pidqa-1"]

    first = docs[0]
    assert first.license_provenance is LicenseProvenance.CC0
    assert first.data_lane is DataLane.RESEARCH
    assert first.sheets[0].discipline.value == "process"
    assert first.entity_count() == 0  # PIDQA carries QA, not symbol geometry
    qa = first.metadata["qa_pairs"]
    assert len(qa) == 1
    assert qa[0]["question"].startswith("How many")
    assert qa[0]["answer"] == "2"
    assert qa[0]["category"] == "simple_counting"


def test_delp_does_not_materialize_inference_summaries(tmp_path: Path) -> None:
    """Model-inference detection summaries must NOT enter the CIR/dataset layer."""
    preparer = DELPPreparer(_record("DELP-SkeySpot"), data_root=tmp_path)
    preparer.raw_dir.mkdir(parents=True)
    (preparer.raw_dir / "Plot99_detection_summary.csv").write_text(
        "Class Label,Class Number,Quantity\nDouble Socket,6,4\nLight Switch,15,2\nTotal,,6\n",
        encoding="utf-8",
    )
    # Only Pascal-VOC ground truth is converted; summaries are ignored entirely.
    assert list(preparer.convert()) == []
    result = preparer.prepare(fmt="json")
    assert result.n_drawing_sets == 0
    assert list(preparer.cir_dir.glob("*")) == []  # nothing materialized in the CIR layer


def test_delp_converts_voc_to_bbox_entities(tmp_path: Path) -> None:
    preparer = DELPPreparer(_record("DELP-SkeySpot"), data_root=tmp_path)
    preparer.raw_dir.mkdir(parents=True)
    (preparer.raw_dir / "plotA.xml").write_text(
        "<annotation><size><width>100</width><height>200</height></size>"
        "<object><name>Double Socket</name>"
        "<bndbox><xmin>10</xmin><ymin>20</ymin><xmax>30</xmax><ymax>60</ymax></bndbox>"
        "</object></annotation>",
        encoding="utf-8",
    )

    docs = list(preparer.convert())  # VOC present -> uses ground-truth boxes
    assert len(docs) == 1
    entity = next(docs[0].iter_entities())
    assert entity.label == "Double Socket"
    assert entity.source_bbox is not None and entity.source_bbox.x_min == 10
    bounds = entity.geometry.bounds() if entity.geometry else None
    assert bounds is not None
    assert abs(bounds.x_min - 0.1) < 1e-9  # 10 / 100
    assert abs(bounds.y_max - 0.3) < 1e-9  # 60 / 200


def test_prepare_writes_cir_and_manifest_and_roundtrips(tmp_path: Path) -> None:
    preparer = DELPPreparer(_record("DELP-SkeySpot"), data_root=tmp_path)
    preparer.raw_dir.mkdir(parents=True)
    (preparer.raw_dir / "PlotZ.xml").write_text(
        "<annotation><size><width>100</width><height>100</height></size>"
        "<object><name>Radiator</name>"
        "<bndbox><xmin>10</xmin><ymin>10</ymin><xmax>30</xmax><ymax>30</ymax></bndbox>"
        "</object></annotation>",
        encoding="utf-8",
    )

    result = preparer.prepare(fmt="json")  # download() is a no-op (raw already present)
    assert result.n_drawing_sets == 1
    assert (preparer.processed_dir / "manifest.json").exists()

    written = list(preparer.cir_dir.glob("*.json"))
    assert len(written) == 1
    restored = load(DrawingSet, written[0])
    assert restored.entity_count() == 1
    assert restored.data_lane is DataLane.RESEARCH


def test_audit_prepared_clean_when_only_research(tmp_path: Path) -> None:
    preparer = DELPPreparer(_record("DELP-SkeySpot"), data_root=tmp_path)
    preparer.raw_dir.mkdir(parents=True)
    (preparer.raw_dir / "PlotR.xml").write_text(
        "<annotation><size><width>100</width><height>100</height></size>"
        "<object><name>Radiator</name>"
        "<bndbox><xmin>10</xmin><ymin>10</ymin><xmax>30</xmax><ymax>30</ymax></bndbox>"
        "</object></annotation>",
        encoding="utf-8",
    )
    preparer.prepare(fmt="json")

    violations, n_scanned, n_commercial = audit_prepared(tmp_path)
    assert violations == []
    assert n_scanned == 1
    assert n_commercial == 0


def test_audit_prepared_flags_invalid_commercial_doc(tmp_path: Path) -> None:
    """A hand-written commercial-lane doc built from non-commercial data is caught."""
    cir_dir = tmp_path / "processed" / "bad" / "cir"
    cir_dir.mkdir(parents=True)
    (cir_dir / "bad.json").write_text(
        '{"schema_version":"0.1.0","id":"bad","license_provenance":"CC-BY-NC",'
        '"data_lane":"commercial","sheets":[]}',
        encoding="utf-8",
    )
    violations, _, _ = audit_prepared(tmp_path)
    assert violations  # rejected: commercial lane + non-commercial license is invalid CIR
