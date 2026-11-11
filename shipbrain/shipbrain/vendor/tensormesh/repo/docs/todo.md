# Documentation TODO

A running log of documentation decisions worth revisiting in future
versions. Append-only — keep entries short and dated so older
decisions can be re-evaluated against newer thinking.

## Open questions / decisions to revisit

### 2026-05-03 — Public-API tier policy for low-level math objects

When auditing the API reference, we settled on a three-tier model:

| Tier | What it means | Where it lives |
|---|---|---|
| **Public** | Stable; signature changes are breaking | In subpackage `__init__.py`, full docs |
| **Advanced / Unstable** | Public but signature may evolve | In `__init__.py`, docs include a `.. note::` warning |
| **Internal** | Implementation detail; supported extension path is subclassing | Not in `__init__.py`, not autodoc'd |

Decisions made today:

- **`J2Plasticity`** → Public. Added to `tensormesh/assemble/__init__.py`.
- **`Polynomial` / `Polynomials`** → Advanced. Added to
  `tensormesh/element/__init__.py`; `api/element.rst` carries an
  unstable-API note.
- **`tensormesh.element.basis` / `quadrature` / `normal`** → Internal.
  Removed `automodule::` directives from `api/element.rst`. The
  user-facing extension path is subclassing
  :class:`~tensormesh.Element` and overriding its hooks. A short
  prose pointer to the source is left for the rare advanced reader.

**Why this might need to change:** if real users start filing issues
asking how to call these internal modules directly, that's a signal
they should be promoted to "Advanced" and given a stable interface.
The current bet is that almost no one will need them — revisit once
we have a few external users who have built custom element types.

### Other notes

- *(add new entries above this line, with `### YYYY-MM-DD — short title`)*
