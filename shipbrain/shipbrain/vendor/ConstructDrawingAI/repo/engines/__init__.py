"""L3 — Product Engines. **This is our IP.**

L3 turns grounded CIR data into the things customers pay for. Every engine consumes
the CIR (perception + grounding output) and produces a decision-support artifact —
never an oracle. The cross-cutting product rule, for liability: **every
customer-facing number carries a confidence score and a link back to its exact
source view** (cropped image + sheet + coordinates), and low-confidence items are
flagged for human review.

Planned engines, in roadmap order:

* ``takeoff_mep`` — **the wedge.** MEP/electrical takeoff + quantification: fixture
  and device counts by type, conduit/wire linear measurements, panel/circuit
  quantities, mapped to MasterFormat, with per-quantity confidence and evidence
  links. Uses **commercial-lane models only** for anything a customer touches.
* ``connectivity`` — electrical/P&ID graph extraction (home-run → panel,
  component → component), targeting the published node/edge AP SOTA.
* ``clash`` — upstream clash/constructability triage from 2D/mixed sets, and AI
  triage of false-positive clashes (Phase 4 — depends on solid L1 + L2).
* ``schedule_4d`` — element → activity/sequence linkage (Phase 4).
* ``drawing_to_bim`` — promote vectorization to watertight IFC/structure output.

Status: **stub.** The wedge engine (``takeoff_mep``) is built in Build Playbook
step 3.2; the rest follow in Phase 4.
"""

from __future__ import annotations
