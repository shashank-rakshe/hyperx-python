# webapp — production frontend (placeholder)

The production web application is built later (Build Playbook step 4.2), from a
prototype concepted in **Claude Design** and handed off to Claude Code.

Planned shape:

- **Stack:** React (the design system's components), bundled for the browser.
- **Core flow:** an estimator uploads a drawing set → watches the AI extract
  quantities → reviews/corrects them with full **confidence + evidence** visibility →
  originates RFIs from detected inconsistencies.
- **Key surfaces:**
  1. a drawing viewer (pan/zoom, multi-sheet, gigapixel tiling/lazy-loading, detected
     symbols highlighted),
  2. a takeoff panel (quantities by MasterFormat code, per-item confidence badges,
     "show evidence" → crop to the source on the drawing),
  3. a review queue of low-confidence items flagged for human correction,
  4. an RFI panel where detected inconsistencies become one-click draftable RFIs with
     cropped evidence and cited spec clauses.
- **Trust is the product:** confidence scores and evidence-linking are first-class,
  and the UI never touches research-lane weights or NC-licensed data.

It talks to the FastAPI backend in [`../backend`](../backend), which calls the
commercial-lane model servers.

This directory is intentionally a non-Python placeholder; it is not part of the
Python package build.
