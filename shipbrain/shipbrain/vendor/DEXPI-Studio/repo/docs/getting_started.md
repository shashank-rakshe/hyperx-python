# Getting Started

## Requirements

- Python 3.12+
- Desktop environment with display support

## Install (development setup)

```bash
git clone https://github.com/process-intelligence-research/DEXPI-Studio.git
cd DEXPI-Studio
pip install -e ".[dev]"
```

Optional quality hooks:

```bash
pre-commit install
```

## Run the app

```bash
python -m dexpi_studio.app
```

## First workflow

1. Open a model with **File → Open DEXPI File** (`Ctrl+O`)
2. Use the top search bar (`Ctrl+F`) to find objects quickly
3. Select a result, tree node, or diagram object
4. Inspect attributes in the **Properties** panel
5. Review the **Issues** panel: the file is validated as it opens, and **Validate / Check**
   (`Ctrl+Shift+V`) checks it again. Select an issue to select its objects.
6. Export with **File → Export** (`Ctrl+E`)

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Open file | `Ctrl+O` |
| Export | `Ctrl+E` |
| Find | `Ctrl+F` |
| Next search result | `F3` |
| Fit to window | `Ctrl+0` |
| Zoom in | `Ctrl++` |
| Zoom out | `Ctrl+-` |
| Reset zoom | `Ctrl+1` |
| Validate | `Ctrl+Shift+V` |
| Open ChatP&ID | `Ctrl+Shift+A` |

## Docs and development commands

```bash
pytest -q
ruff check .
ruff format .
mkdocs serve
```
