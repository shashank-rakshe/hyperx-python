# The L0 → L1 tiling handoff contract

This is the seam where L1 perception results get stitched back onto the global sheet.
A symbol detected in a tile must land at the right place on the whole drawing — because
a **stitching error becomes a counting error**, and counting accuracy (MAPE) is a
headline metric for takeoff. So the handoff is an explicit, validated
schema ([`ingest/handoff.py`](../ingest/handoff.py)), not an ad-hoc dict, and it is
pinned by a model-free round-trip test ([`tests/test_ingest_handoff.py`](../tests/test_ingest_handoff.py)).

## Three coordinate systems

| System | Definition |
|---|---|
| **Full-raster pixels** | Integer pixels of the rasterized sheet, `full_width` × `full_height`. A tile is a **1:1 crop** — tile-local pixels map to sheet pixels by a pure offset; there is no per-tile resampling. |
| **Sheet-normalized [0,1]** | The CIR convention. `sheet_norm = pixel / full_size`, origin top-left, x→right, y→down. CIR `Entity` geometry lives here. |
| **Tile-local-normalized [0,1]** | Coordinates *within one tile* — **this is what L1 returns per tile**. |

**Composition (the one formula that matters):**

```
sheet_norm = region.min + tile_norm * region.size
tile_norm  = (sheet_norm - region.min) / region.size
```

where `region` is the tile's rectangle in sheet-normalized coordinates. These are
`TileRef.tile_box_to_sheet` / `TileRef.sheet_box_to_tile`, and the round-trip test
asserts they are exact inverses (including for a detection that straddles a tile seam).

## What L0 produces

`ingest.tiling.tile_image(image, *, sheet_id, tile_size=1536, overlap=192, dpi=None)`
returns a `TiledSheet`:

- `tiles: list[Tile]` — each `Tile` is the cropped image **plus** its `TileRef`.
- `global_view` — a downsampled whole-sheet image (global context).
- `refs` — `{tile_id: TileRef}`, for composing detections back.

### `TileRef` — the per-tile contract

| Field | Meaning |
|---|---|
| `tile_id` | Stable, deterministic id: `f"{sheet_id}:r{row}c{col}"`. |
| `sheet_id` | Back-reference to the CIR `Sheet` this tile belongs to. |
| `row`, `col` | Grid position. |
| `full_width`, `full_height` | Rasterized sheet size, pixels. |
| `pixel` | `PixelRegion(x, y, width, height)` — origin offset + size, **pixels**. |
| `region` | The tile rectangle in **sheet-normalized** `[0,1]` (`BBox`). |
| `scale_x`, `scale_y` | Tile-local-normalized → sheet-normalized scale = `region.width/height`. |
| `core`, `core_pixel` | The tile interior with overlap margins removed (normalized + pixels). |
| `overlap_px` | Configured overlap margin between neighbours. |
| `dpi` | Rasterization DPI (ties pixels to real-world units via the recovered sheet scale). |

Helper methods: `tile_norm_to_sheet` / `sheet_to_tile_norm`, `tile_box_to_sheet` /
`sheet_box_to_tile`, `tile_px_to_sheet_px`, `fully_contains(box)`, `owns(x, y)`.

## What L1 receives and must return

**Receives** (per tile): the tile image + its `TileRef`. (Plus the global-context view
for whole-sheet reasoning.)

**Must return**: `TileDetection` objects —

```python
TileDetection(tile_id=ref.tile_id, label="duplex_receptacle", bbox=<tile-local [0,1]>, score=0.93)
```

- `bbox` is in **tile-local-normalized** coordinates (the frame of the tile it was
  detected in).
- `tile_id` references the tile, so the aggregator knows which `TileRef` composes it.
- `label`/`score` are the class and confidence; richer class info (IFC class, ontology)
  is attached when these become CIR `Entity` objects.

L1 must **not** return sheet-global coordinates — composition is L0's job, via the
contract, so the mapping is computed in exactly one audited place.

## How results compose back

`ingest.handoff.aggregate(tile_detections, refs, iou_threshold=0.5)`:

1. **Compose**: each `TileDetection.bbox` → sheet-normalized via its `TileRef`
   (`compose_to_sheet`).
2. **Dedup across seams**: per label, detections overlapping above `iou_threshold` are
   merged (highest score wins; merged `source_tile_ids` are recorded). This is what
   turns a symbol seen in two overlapping tiles into **one** counted detection.

The result is `SheetDetection` objects in sheet-normalized coordinates, ready to become
CIR `Entity` objects on the `Sheet`.

### Why overlap + two dedup options

Tiles overlap by `overlap_px` so a symbol near a seam is **fully visible in at least one
tile** (and usually two). Two complementary dedup strategies:

- **NMS** (used by `aggregate`): merge overlapping same-label detections after
  composition. Robust to small localization differences between tiles.
- **Core ownership** (`TileRef.owns`): the tiles' `core` rectangles *partition* the
  sheet, so a detection whose center lands in a tile's core belongs to exactly that
  tile. Useful as a deterministic tie-breaker. The round-trip test checks the cores
  partition the sheet.

## Guarantees (asserted by the test suite)

- **Round-trip identity**: `tile_box_to_sheet(sheet_box_to_tile(b)) == b` for any box
  fully inside a tile (exact within 1e-9), including a seam-straddling detection.
- **No double counting**: a detection visible in two overlapping tiles aggregates to a
  single `SheetDetection` (recording both `source_tile_ids`).
- **Cores partition the sheet**: every sheet point is owned by exactly one tile.

When perception is built in Phase 2, L1 conforms to *this* contract — it is not
reverse-engineered from the stub.
