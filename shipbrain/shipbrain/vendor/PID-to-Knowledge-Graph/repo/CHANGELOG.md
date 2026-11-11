# Changelog

## 0.1.0 (unreleased)

First release.

- Page classification for vector (with or without a text layer), scanned and hybrid PDFs.
- `--pages` on the probe picks the P&ID pages out of a longer document, such as a permit application; later steps use only those pages.
- OCR is optional and installs only on Python 3.10–3.12, where its package is available; the skill runs without it on newer Python.
- Rendering adapts to the drawing:
  - orientation is detected automatically;
  - resolution is chosen from the measured text size;
  - pages are cut into overlapping tiles with blank-tile detection.
- Deterministic hints from the PDF text layer or OCR (RapidOCR), used to flag possible missed tags.
- Extraction schema and procedure for Claude's visual reading of each sheet.
- Graph builder:
  - merges items across sheets by tag;
  - expands pipe runs into segments, including tees and taps;
  - pairs off-page connectors;
  - locates instruments;
  - infers ISA-5.1 control loops, including relays, cascades, interlocks and VFD drives;
  - derives equipment-level flow.
- Outputs:
  - `graph.json`, the canonical graph;
  - `graph.duckdb`, with views and the `upstream`/`downstream` macros;
  - `summary.md`, for LLM context;
  - `qa_report.md`.
- `kg_query.py` CLI, GraphML and Neo4j export, and an `eval_kg.py` scorer.
- Handling for problems found on real drawings:
  - the same tag on two items (`duplicate_tag`);
  - tags reused across sheets (`tag_reused`);
  - off-page flags naming the wrong drawing (`off_page_reference_mismatch`);
  - revision suffixes on drawing numbers;
  - two revisions of one drawing in one PDF (`possible_duplicate_revision`);
  - mounted equipment (`part_of`);
  - area instruments (`area` boundaries);
  - untagged gauges (`function`);
  - valve-type codes kept out of loops;
  - P&ID detail preferred over PFD shortcuts.
- Tested on three real plants: two vector drawing sets with outlined text and one scanned set.
