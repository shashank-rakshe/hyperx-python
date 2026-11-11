# pyDEXPI Integration

This page documents how DEXPI Studio integrates with pyDEXPI today.

## Integration contract

DEXPI Studio is intentionally thin:

- pyDEXPI handles loading, parsing, rendering, and exports
- DEXPI Studio handles desktop UX, navigation, and orchestration

## pyDEXPI APIs used

### Loading

- `pydexpi.load_xml_file(path)`
- `pydexpi.load_json_file(path)`

### SVG and diagram generation

- `DrawDiagram(...).draw_svg(...)` via adapter utilities
- Adapter builds GUI-side render metadata from model/diagram context

### Introspection and property extraction

- `model_toolkit` helpers for model traversal
- attribute utility functions for composition/data/reference extraction

### Query and search

- `pydexpi.query.QueryEngine`
  - `find_by_tag(...)`
  - `find_all(type=...)`
  - `get_by_id(...)`

### Exports exposed in GUI

- GraphML
- Tables (Excel)
- Neo4j CSV
- LLM context

All export logic is delegated to pyDEXPI exporters.

## What DEXPI Studio does not duplicate

- No custom parser for DEXPI XML/JSON
- No custom replacement renderer
- No separate export engine
- No CLI replacement

## Current adapter responsibilities

`core/pydexpi_adapter.py` provides thin wrappers that:

- normalize load/render calls
- classify and index IDs
- build tree/search-supporting structures
- expose validation + export helpers to GUI

## Known boundaries

- Files are loaded with `load_xml_with_report` / `load_json_with_report`, which keep the
  loader's error registry; the plain loaders discard it, so a file read in part would look whole
- Validation runs `pydexpi.validation.validate`; `core/issues.py` puts its issues and the
  loader's entries into one list for the Issues panel
- pyDEXPI 2.1.0's SVG renderer raises on a `ShapeUsage` without a shape or a
  `RepresentationGroup` without the object it represents, which a strict load leaves when it
  refuses an object; `render_svg` draws a copy without them
- Rendering is still pyDEXPI-driven; GUI adds interaction overlays
- Some complex model semantics remain raw pyDEXPI object structures

## Direction

Short-term integration work continues to focus on:

- stronger object-to-graphics mapping
- improved query-assisted navigation
- keeping GUI logic thin and pyDEXPI-first
