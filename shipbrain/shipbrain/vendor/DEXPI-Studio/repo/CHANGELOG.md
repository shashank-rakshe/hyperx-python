# Changelog

## 0.1.1

### Validation and defective files

- An **Issues** panel replaces validation messages in the Logs panel. It lists what loading the
  file reported, then what validation found, with Mandatory (DEXPI requirements) and Recommended
  (pyDEXPI conventions) issues grouped by rule. Selecting an issue selects and highlights its
  objects; double-clicking zooms to them. The full text, the rule's description and its source
  are shown beside the list, and the issues can be exported as CSV.
- A file is validated as it opens, and the Issues panel opens when the loader left part of the
  file out or a mandatory rule is broken. Before, a file pyDEXPI read only in part opened as if
  it were whole: the loader's report was discarded.
- A file pyDEXPI refuses to load strictly can be opened leniently, from the error message or
  with **Reopen leniently** in the Issues panel; a lenient load lists everything it left out.
- A file that is not well-formed XML says so.
- The drawing of a file read in part renders without the objects that were not loaded, instead
  of not rendering at all.

## 0.1.0

First public release of DEXPI Studio, a desktop application for DEXPI P&IDs built on
[pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI) 2.1, free software under the
GNU Affero General Public License v3.

### Features

- Open DEXPI 2.0 and 2.0.1 XML and JSON files, and Proteus XML (DEXPI 1.3)
- Render the P&ID with pyDEXPI; navigate with a touchpad (pinch to zoom, two fingers to move,
  double tap to fit) or a mouse
- Collapsible, searchable model tree, a properties panel, and selection shared between tree and
  diagram
- Validate with pyDEXPI's rules
- Summary of equipment, piping and instruments with their tags
- Compare two models with pyDEXPI's diff
- Exports, with pyDEXPI's options:
  - GraphML, Neo4j CSV and LLM context at any graph level, including a process model's flow
  - Equipment, line, instrument, piping component and valve tables as Excel, CSV or JSON, in
    English, German, Dutch or Chinese
  - SVG, PNG and PDF images
  - DEXPI 2.0.1 XML and JSON
  - A stable text projection for reviewing model changes in Git
- Optional ChatP&ID assistant, which sends the context you select to the AI provider you
  configure
- Ready-to-run builds for Windows, macOS (Apple silicon) and Linux

### Architecture

- Clean core/GUI separation
- Core layer does not import PySide6
- All functionality delegated to pyDEXPI — no duplication
