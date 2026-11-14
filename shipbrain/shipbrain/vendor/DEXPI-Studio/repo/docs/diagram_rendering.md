# Diagram Rendering

This page explains how DEXPI Studio renders and interacts with diagrams.

## Rendering model

DEXPI Studio uses a layered approach in `DiagramScene` / `DiagramView`:

- **Base diagram layer**: SVG rendered from pyDEXPI
- **Interactive object layer**: model-backed items and selectable regions
- **Highlight layer**: active selection and focus visuals

The goal is to preserve pyDEXPI fidelity while enabling GUI interaction.

## Coordinate strategy

All interactive items are aligned to SVG document/viewBox coordinates.

- Avoids offset drift between diagram and overlays
- Keeps zoom/fit/selection behavior consistent

## Selection and highlighting

Selection can originate from tree, search results, or diagram interactions.

When selection changes, the view updates:

- active object highlight
- zoom/focus behavior
- synchronized tree/properties context

## Fallback behavior

Some objects may not produce ideal geometry from every source model.

Current behavior favors resilience:

- keep object selectable/highlightable where possible
- fall back to safe overlay handling when exact symbol extraction is not available
- emit diagram/log diagnostics when fallback paths are used

This keeps diagrams usable across varied upstream files while rendering coverage improves.

## Current focus areas

- stronger object-to-graphics mapping for edge cases
- smoother behavior on large models
- continued pyDEXPI-first rendering alignment
