# Ship tools (2D drawing -> member model -> ship XML)

These modules are loaded by ShipBrain automatically as extra tools:

| Tool | What it does |
|---|---|
| `rules_search` | search the rule book (needs your own `ship_src/` rule files next to these modules; not in the repo) |
| `check_members` | rule checks on a member table (outline, members with section and end points) |
| `xml_from_members`, `xml_validate` | write and validate the moulded-line ship XML; the XML is always written by code, never by the model |
| `ocr_fix` | repair labels that OCR misread on scanned drawings |
| `classify_number` | class of a printed number (a weld size is never a plate thickness) |
| `alike_score`, `drawing_tile` | compare an XML deck with its drawing; cut a drawing tile (need your drawings in `ship_src/`) |

`ship_xml_kit.xml_to_members` is also used by ShipBrain's `compare_structures` and `structure_to_mesh` to read ship XML.

Other files: `ship_online.py` (the step-by-step reading method as training tasks and checks), `ship_pairs.py` (drawing tiles
paired with reference members), `ship_rag.py` (CPU runtime with rule search), `ship_eval.py` (scoring),
`cad_vlm_all_in_one.py` and `cad3d_basics.py` (vision-model training data: 2D drawings to 3D parts).

Drawings, XML models and rule-book texts are **not** in this repository. Put them in `shiptools/ship_src/` on your own PC;
that folder is ignored by git. Self-test: `python ship_online.py --selftest`.

## Ship drawing reader (`deckrules_tool/`)

Reads a 2D structural drawing (PDF deck plans, elevations, sections) and builds the moulded-line ship XML, with a review
and report: `python -m deckrules.build_ship DRAWING.pdf --settings project_settings.json --out out`. Rules: see its
`RULES` comments in the code. OCR for scans: PaddleOCR, RapidOCR or Tesseract (whichever is installed).
ShipBrain uses its OCR for scanned drawings in `drawing_check` and the comparison tools.

- Hull numbers are replaced by placeholders (1001-1009) in comments and docstrings; the company name, the internal
  tool name and project-specific settings, answers, sample outputs and benchmark scripts that need private drawings are
  left out. `yards/default_yard.json` holds the section aliases; put your own pipe table next to it.
- It still uses PyMuPDF (AGPL or paid licence) for reading PDFs. Fine for in-house use; replace it with
  pdfplumber / pypdfium2 before giving the tool to others (about 25 files).
- Status as delivered: works well on vector deck plans; the scanned-drawing path is experimental (see its tests: 66 pass).
- OCR of written arithmetic on scans is not reliable: the OCR engines often drop `=` and `@`. Use vector PDFs or DXF for
  `drawing_check`.
