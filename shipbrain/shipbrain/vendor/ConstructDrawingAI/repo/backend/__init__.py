"""The backend API service (FastAPI).

Today it exposes health, version, and CIR validation/example endpoints — enough to
prove the service runs and that the CIR is the wire format. The full product pipeline
(upload → L0 ingest → L1 perception → L2 grounding → L3 takeoff → L4 agent/RFI), with
progress streaming and an audit trail, is built in Build Playbook step 4.2.

Hard product rule (liability): the user path calls **commercial-lane models only** and
never touches research-lane weights or NC-licensed data.

Run it::

    uv run uvicorn backend.app:app --reload   # http://127.0.0.1:8000/docs

Requires the ``backend`` optional-dependency group (``uv sync --extra backend``).
"""

from __future__ import annotations
