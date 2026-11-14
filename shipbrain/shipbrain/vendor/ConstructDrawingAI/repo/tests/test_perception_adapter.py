"""The DetectorAdapter turns per-tile detections into a CIR DrawingSet via the contract.

Uses a fake detector (no torch/weights) so the test isolates the L0->L1 wiring: tiling,
composition through ``ingest.handoff.aggregate``, and CIR entity construction (label, IFC
class, confidence, pixel-exact source_bbox, provenance).
"""

from __future__ import annotations

from PIL import Image

from cir import (
    BBox,
    DataLane,
    DrawingSet,
    EntityType,
    LicenseProvenance,
)
from eval.tasks import CLEAN, RASTER, EvalSample, Slice
from ingest import tile_image
from perception.adapter import DetectorAdapter
from perception.detector import TileSymbol

_PROV = {"license_provenance": LicenseProvenance.SYNTHETIC_OWNED, "data_lane": DataLane.COMMERCIAL}


class _FakeDetector:
    """Returns a fixed set of tile-local detections for every tile (image-blind)."""

    def __init__(self, symbols: list[TileSymbol]) -> None:
        self._symbols = symbols

    def predict_tile(self, image: object) -> list[TileSymbol]:
        return [TileSymbol(s.label, s.bbox, s.score) for s in self._symbols]


def _sample(tmp_path, size=(500, 400)) -> EvalSample:
    path = tmp_path / "sheet.png"
    Image.new("RGB", size, "white").save(path)
    gt = DrawingSet(name="gt", **_PROV)  # unused by the adapter; predict ignores GT
    return EvalSample(
        id="s0", ground_truth=gt, slice=Slice("mep", RASTER, CLEAN, "t"), image_path=path
    )


def test_adapter_builds_cir_entities_with_evidence(tmp_path) -> None:
    fake = _FakeDetector(
        [
            TileSymbol(
                "Duplex Receptacle", BBox(x_min=0.40, y_min=0.40, x_max=0.50, y_max=0.50), 0.90
            ),
            TileSymbol("Panelboard", BBox(x_min=0.10, y_min=0.10, x_max=0.20, y_max=0.20), 0.80),
        ]
    )
    # One tile covering the whole sheet -> tile-local coords == sheet coords.
    adapter = DetectorAdapter(fake, tile_size=4096, overlap=0, name="cdai-detector-test")
    ds = adapter.predict(_sample(tmp_path))

    entities = list(ds.iter_entities())
    assert len(entities) == 2
    by_label = {e.label: e for e in entities}

    duplex = by_label["Duplex Receptacle"]
    assert duplex.entity_type is EntityType.SYMBOL
    assert duplex.ifc_class == "IfcOutlet"
    assert duplex.confidence == 0.90
    assert duplex.produced_by == "cdai-detector-test"
    box = duplex.geometry.bounds()
    assert abs(box.center.x - 0.45) < 1e-6 and abs(box.center.y - 0.45) < 1e-6
    # pixel-exact evidence link (ADR-0008): sheet-normalized * full size
    assert abs(duplex.source_bbox.x_min - 0.40 * 500) < 1e-3
    assert abs(duplex.source_bbox.y_max - 0.50 * 400) < 1e-3

    panel = by_label["Panelboard"]
    assert panel.entity_type is EntityType.EQUIPMENT
    assert panel.ifc_class == "IfcElectricDistributionBoard"

    # Predictions are research/unknown — a derived output has no source license.
    assert ds.data_lane is DataLane.RESEARCH
    assert ds.license_provenance is LicenseProvenance.UNKNOWN


def test_adapter_composes_every_tile_back_to_the_sheet(tmp_path) -> None:
    # A wide sheet that tiles into several columns; one detection per tile at its center.
    path = tmp_path / "wide.png"
    Image.new("RGB", (600, 200), "white").save(path)
    sample = EvalSample(
        id="wide",
        ground_truth=DrawingSet(name="gt", **_PROV),
        slice=Slice("mep", RASTER, CLEAN, "t"),
        image_path=path,
    )
    n_tiles = len(tile_image(path, tile_size=256, overlap=64).tiles)
    assert n_tiles > 1

    fake = _FakeDetector(
        [TileSymbol("Junction Box", BBox(x_min=0.45, y_min=0.45, x_max=0.55, y_max=0.55), 0.7)]
    )
    adapter = DetectorAdapter(fake, tile_size=256, overlap=64)
    ds = adapter.predict(sample)

    entities = list(ds.iter_entities())
    # Distinct tiles map their centers to distinct sheet points (no spurious dedup).
    assert len(entities) == n_tiles
    for e in entities:
        assert e.label == "Junction Box"
        b = e.geometry.bounds()
        assert 0.0 <= b.x_min <= 1.0 and 0.0 <= b.x_max <= 1.0
