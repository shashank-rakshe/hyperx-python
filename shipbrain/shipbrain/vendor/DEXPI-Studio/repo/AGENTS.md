# AGENTS.md — DEXPI Studio Development Guidelines

## Core Principles

- **DEXPI Studio must remain a GUI wrapper around pyDEXPI.** Do not duplicate pyDEXPI functionality.
- **Do not duplicate pyDEXPI CLI.** pyDEXPI has its own CLI; DEXPI Studio is GUI-only.
- **Do not duplicate pyDEXPI exporters.** Expose existing exports through the GUI.
- **Do not duplicate pyDEXPI parsers/renderers.** Use `load_xml_file`, `DrawDiagram`, etc. directly.
- **Keep core/GUI separation.** The `core/` package must not import PySide6.
- **No cloud. No telemetry.** Files stay on the user's machine.
- **Read-only.** DEXPI Studio views, validates and exports what pyDEXPI supports. It does not edit models.

## Before Adding Features

- Always inspect pyDEXPI APIs before assuming names or capabilities.
- Check if pyDEXPI already provides the functionality you need.
- Only implement the thinnest GUI-side adapter needed.
- Document any gaps in `docs/pydexpi_integration.md`.

## Testing

- Tests for `core/` must not require a display (no PySide6).
- Use the reference DEXPI file from pyDEXPI's `data/` directory for integration tests.
- Run `pytest` before committing.
- Run `ruff check .` and `ruff format --check .` before committing.

## Code Style

- Follow ruff configuration in `pyproject.toml`.
- Use type hints.
- Use numpy-style docstrings.
- Keep imports at the top of files.
- Prefer composition over inheritance in the GUI.

## Architecture

```
src/dexpi_studio/
├── app.py          # GUI entry point (python -m dexpi_studio.app)
├── core/           # No PySide6 imports allowed
│   ├── capabilities.py
│   ├── pydexpi_adapter.py
│   ├── model_tree.py
│   └── selection.py
└── gui/            # PySide6 widgets
    ├── main_window.py
    ├── actions.py
    └── widgets/
```
