# DEXPI Studio

Desktop GUI for exploring DEXPI P&ID models with [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI) — local-first, open-source, and built for engineers.

<p align="center">
  <a href="https://github.com/process-intelligence-research/DEXPI-Studio/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" alt="License"></a>
  <img src="https://img.shields.io/badge/python-3.12%2B-blue.svg" alt="Python">
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey" alt="Platform">
  <img src="https://img.shields.io/badge/local--first-no%20telemetry-green" alt="Local first">
</p>

<p align="center">
  <img src="docs/images/main_window.png" alt="DEXPI Studio showing the DEXPI reference P&amp;ID, with heat exchanger H1007 selected and its properties listed" width="900">
</p>

## Why DEXPI Studio?

DEXPI models are machine-readable and rich, but many workflows still need code-first tooling.
DEXPI Studio gives you a modern desktop interface around pyDEXPI so you can inspect, validate,
search, and export models quickly without writing scripts.

## Download

Ready-to-run applications for Windows, macOS and Linux are on the
[DEXPI Studio page](https://www.pi-research.org/research/software/dexpi-studio/) and under
[Releases](https://github.com/process-intelligence-research/DEXPI-Studio/releases). No Python
installation is needed.

> [!IMPORTANT]
> **Two limits of the current builds:**
>
> - **macOS: Apple silicon only.** The Mac build runs on Macs with an M-series chip (M1 or
>   later), not on Intel Macs. On an Intel Mac, run DEXPI Studio from source (see
>   [Quick Start](#quick-start)).
> - **Not code-signed yet.** Windows and macOS warn on the first start. On Windows, choose
>   **More info → Run anyway**. On macOS, right-click the app and choose **Open**; if macOS
>   still refuses, open **System Settings → Privacy & Security** and choose **Open Anyway**.

## Features

- Open DEXPI 2.0 and 2.0.1 `.xml` and `.json` files, and Proteus XML (DEXPI 1.3)
- Render P&ID diagrams via pyDEXPI, with touchpad and mouse navigation
- Navigate model tree + inspect properties
- Always-visible in-app model search with compact result dropdown
- Select and highlight objects between tree and diagram
- Validate as you open a file: an Issues panel lists what the loader could not read and where
  the model breaks DEXPI's requirements or pyDEXPI's conventions, and selects the objects
  involved
- Summary of a model's equipment, piping and instruments, with their tags
- Compare two models (pyDEXPI's diff)
- Export through pyDEXPI, with its options: GraphML, Neo4j CSV and LLM context at any graph
  level; equipment, line, instrument, piping component and valve tables (Excel, CSV, JSON) in
  English, German, Dutch or Chinese; SVG, PNG and PDF images; DEXPI 2.0.1 XML and JSON; and a
  stable text projection for reviewing model changes in Git
- ChatP&ID assistant panel with local chat persistence and markdown export
- Detached raw SVG panel for visual comparison

## Quick Start

```bash
git clone https://github.com/process-intelligence-research/DEXPI-Studio.git
cd DEXPI-Studio
pip install -e ".[dev]"
python -m dexpi_studio.app
```

## Typical Workflow

1. **Open** a DEXPI file (`Ctrl+O`)
2. **Search** objects in the top search bar (`Ctrl+F`)
3. **Select** an item from tree, diagram, or search results
4. **Inspect** properties in the right panel
5. Review the **Issues** panel; **Validate** (`Ctrl+Shift+V`) checks the model again
6. **Export** (`Ctrl+E`) to your desired downstream format

## Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Open file | `Ctrl+O` |
| Export | `Ctrl+E` |
| Find | `Ctrl+F` |
| Next search result | `F3` |
| Fit to window | `Ctrl+0` |
| Reset zoom | `Ctrl+1` |
| Validate | `Ctrl+Shift+V` |
| Open ChatP&ID | `Ctrl+Shift+A` |

## Local-First & Privacy

- No telemetry
- Your DEXPI files are opened, rendered, validated and exported on your machine; the core
  application uploads nothing
- The optional ChatP&ID assistant is the exception: when you use it, it sends your question and
  the model context you select to the AI provider you configure, under that provider's terms
- Chats and settings are stored locally

## Relationship to pyDEXPI

DEXPI Studio is intentionally a **thin GUI wrapper** around pyDEXPI.

It does **not** replace or duplicate:

- pyDEXPI parsing/loading
- pyDEXPI rendering logic
- pyDEXPI CLI
- pyDEXPI export implementations

## Documentation

- [Home](docs/index.md)
- [Getting Started](docs/getting_started.md)
- [Architecture](docs/architecture.md)
- [pyDEXPI Integration](docs/pydexpi_integration.md)
- [Limitations](docs/limitations.md)
- [Roadmap](docs/roadmap.md)
- [**Releasing**](docs/releasing.md)

Build docs locally:

```bash
mkdocs serve
```

## Release & Distribution

Pre-built binaries are produced by [`scripts/release.py`](scripts/release.py) and the
[GitHub Actions release workflow](.github/workflows/release.yml).
See **[docs/releasing.md](docs/releasing.md)** for the full guide covering local builds,
CI triggering, and code-signing setup (Windows/macOS/Linux).

## Development

```bash
pytest -q
ruff check .
ruff format .
mkdocs build
```

## License

DEXPI Studio is released under the [GNU Affero General Public License v3](LICENSE). It also contains
third-party material, attributed in [`NOTICE`](NOTICE).

Copyright (C) 2025-2026 Process Intelligence Research, TU Delft.

For licensing inquiries, contact: [a.schweidtmann@tudelft.nl](mailto:a.schweidtmann@tudelft.nl)
