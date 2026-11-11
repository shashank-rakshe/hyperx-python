# Changelog

Package versions are pyDEXPI's own and are not DEXPI versions. `pydexpi.DEXPI_SPEC_VERSION` says
which DEXPI the classes implement. The publish workflow uses a version's section below as the notes
of its GitHub release.

## 2.1.0

The first public release since 1.2.0, and a breaking one. It moves the classes from DEXPI 1.3 to
DEXPI 2.0.1. Version 2.0.0 was never published. See the
[migration guide](https://www.pydexpi.org/migration/).

### Changed

- The classes implement DEXPI 2.0.1, in `pydexpi.pydexpi_classes`. `pydexpi.dexpi_classes` is gone.
- The root of a model is `EngineeringModel`, not `DexpiModel`.
- pyDEXPI reads DEXPI 2.0 documents by converting them to 2.0.1 as they load, and writes only 2.0.1.
- `pydexpi.loaders.svg_loader` moved to `pydexpi.exports.svg_export`.
- `ProteusSerializer` is imported from `pydexpi.loaders.proteus_serializer`.

### Added

- Native DEXPI XML and JSON loading and export, and a public loading API in `pydexpi`.
- DEXPI process models, with a process-flow graph level and process validation rules.
- Lenient loading (`strict=False`, `--lenient`), which reports what a file omits and keeps the rest.
- A command-line interface (extra `cli`) and an MCP server (extra `mcp`).
- Query and search, a validation engine with rules, a semantic diff, and a stable text projection
  for reviewing models in Git.
- Exports to Excel and CSV tables, GraphML, Neo4j, PDF and PNG.

### Removed

- The 23 sample patterns under `data/dexpi_sample_patterns/`. They held DEXPI 1.3 classes and could
  not be loaded. The synthetic P&ID generator stays and works with patterns you provide.

### Known limitations

- Objects without an id in the source file get a new id on every load, so two loads of one file
  export differently. This also affects pipes and node positions in Proteus imports.
- Direct conversion (`pydexpi convert --fast`) and validated conversion give different documents,
  and direct conversion writes a `DateTime` back to DEXPI XML as a `String`.

## 1.2.0 and earlier

See the [GitHub releases](https://github.com/process-intelligence-research/pyDEXPI/releases).
