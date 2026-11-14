# The Canonical Intermediate Representation (CIR)

The CIR is the single schema every layer reads and writes. It is implemented in
[`../cir/`](../cir/) as a versioned **pydantic v2** model and is the most important
piece of the codebase after scope.

## Hierarchy

```
DrawingSet                      (cir.schema.DrawingSet)   ← root document / dataset record
  ├── schema_version, id, name, project_*, source, created_at, metadata
  ├── license_provenance, data_lane            ← MANDATORY (LicensedRecord)
  └── sheets: list[Sheet]
        ├── sheet_number, discipline, title, page_index, size, scale
        ├── title_block, cross_references[], legend[], revisions[]
        └── views: list[View]
              ├── name, view_type, region, scale
              ├── connections: list[Connection]     ← connectivity edges (MEP/P&ID)
              └── entities: list[Entity]            ← the atoms
                    ├── entity_type, label, geometry (normalized), ifc_class
                    ├── ontology (MasterFormat/UniFormat/OmniClass/Uniclass)
                    ├── text_spans[], dimensions[], source_bbox
                    ├── confidence                  ← REQUIRED
                    ├── produced_by, model_version  ← audit trail
                    └── license_provenance, data_lane  ← MANDATORY (LicensedRecord)
```

* **DrawingSet → Sheet → View → Entity** is the spine.
* **Connection** edges (within a View) carry connectivity graphs (e.g. home-run → panel
  in electrical). Nodes are Entities referenced by id.
* **CrossReference** edges (on a Sheet) carry the sheet-graph (callout → target).

## Coordinate systems

Two coexist on purpose (`cir/geometry.py`):

- **Normalized geometry** (`Geometry`, `Point`, `BBox`) — fractions of the *sheet*
  extent, origin top-left, x→right, y→down, nominally `[0,1]`. Resolution-independent
  so raster and vector detections compare directly.
- **Source coordinates** (`SourceBBox`) — the axis-aligned box in the *original* file
  system (PDF points / raster pixels on a page), so every entity traces back to
  pixel-exact evidence (the human-in-the-loop / liability story).

## The mandatory provenance contract

`LicensedRecord` (the base of `Entity`, `DrawingSet`, and `datasets.DatasetRecord`)
adds two mandatory fields and one invariant:

- `license_provenance: LicenseProvenance` — the source license.
- `data_lane: DataLane` — `research` or `commercial`.
- **Invariant:** a record may be in the `commercial` lane only if its license is
  *commercial-safe*. Enforced as a pydantic `ValidationError` at construction time.

A `DrawingSet` adds a stronger check: a commercial set may contain only
commercial-lane, commercial-safe entities. Helpers:

- `ds.is_commercial_safe` — property.
- `ds.assert_commercial_safe()` — raises `LicenseLaneError` (the typed guard for the
  audit command / CI).
- `ds.licenses_present()` — the set of licenses anywhere in the document.

The policy is defined in exactly one place: `cir.COMMERCIAL_SAFE_LICENSES` in
`cir/enums.py`. It is deliberately conservative — `CC-BY-NC` (and other `*-NC-*`),
`*-ND`, `CC-BY-SA`, `CC-BY` (pending legal sign-off), and `unknown`/unverified are
**research-only**; only `CC0`, `public-domain`, `permissive`, `synthetic-owned`,
`owned`, and `proprietary-licensed` are commercial-safe.

## Versioning

`cir.SCHEMA_VERSION` (semver) is stamped on every `DrawingSet`. Compatibility is by
**major** version; `cir.serialization` checks it on load and raises
`SchemaVersionError` for an incompatible document before validation.

## Serialization (`cir/serialization.py`)

Round-trip-stable across:

| Format | Functions | Use |
|---|---|---|
| dict | `to_dict` / `from_dict` | in-process, FastAPI bodies |
| JSON | `to_json` / `from_json` | human-readable interchange |
| gzip-JSON | `to_gzip_json` / `from_gzip_json` | dependency-free compact binary |
| **msgpack** | `to_msgpack` / `from_msgpack` | **default compact binary** (storage/transport) |

`save(obj, path)` / `load(cls, path)` dispatch on suffix (`.json`, `.json.gz`,
`.cir`/`.msgpack`/`.mpk`). The round-trip and invariant guarantees are pinned by
`tests/test_cir_roundtrip.py` and `tests/test_cir_invariants.py`.

## Usage

```python
import cir

ds = cir.make_example_drawing_set(data_lane=cir.DataLane.COMMERCIAL)

# round-trip
assert cir.from_msgpack(cir.DrawingSet, cir.to_msgpack(ds)) == ds
cir.save(ds, "out/drawing_set.cir")          # compact binary
again = cir.load(cir.DrawingSet, "out/drawing_set.cir")

# traverse + enforce
for entity in ds.iter_entities():
    print(entity.entity_type, entity.ifc_class, entity.confidence)
ds.assert_commercial_safe()                  # raises LicenseLaneError if it can't ship
```

## Design choices worth knowing

- **`extra="forbid"`** on every model — unknown fields are an error, catching typos
  and schema drift. Extensibility goes through explicit `attributes` / `metadata`
  / `raw_fields` dicts.
- **`validate_assignment=True`** — mutation re-runs validation, so flipping
  `data_lane` to commercial on NC data raises immediately.
- **`entity_type` vs `ifc_class`** — `entity_type` is the CIR's small, stable taxonomy
  of *primitive kinds*; `ifc_class` carries the *domain semantics*. Keep richness in
  `ifc_class` + ontology codes.
- **`confidence` is required on every `Entity`** — there is no unscored detection.
