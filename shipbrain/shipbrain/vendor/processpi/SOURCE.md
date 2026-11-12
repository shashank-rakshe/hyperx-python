# ProcessPi (copied unchanged)

From https://github.com/varma666/ProcessPi.git, commit c817afd2c661ae6d89e39e1401dc1a37a5fc8ece. Licence: MIT
(see repo/LICENSE), Copyright (c) 2025 Raviteja Varma Nadimpalli. Only the `processpi` package, its licence, README
and CHANGELOG are copied - the repository's committed virtual environment (.venv_broken, with .exe files), the app and
the docs are left out.

How ShipBrain uses it (shipbrain/pipeflow.py), and why:
- fluids are ShipBrain's own Component subclasses with fixed density and viscosity: the built-in Water class ignores a
  density override (an oil "overridden" this way is computed with water's density), and has no seawater or fuel oils;
- valves / bends are put in each pipe's `fittings` list: fittings added at a network node are skipped by design.
