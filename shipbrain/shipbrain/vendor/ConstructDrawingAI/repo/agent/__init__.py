"""L4 — Agentic Workflow Layer.

L4 turns extracted facts into the workflows buyers already pay for. It is a
**frontier-model agent** (Claude / GPT / Gemini via a swappable adapter) that
orchestrates by calling **tools down into our own stack** — it never perceives raw
drawings itself for counting or measurement; it asks L1/L2 for that. Mirrors the
AEC-Bench tool pattern: page-render, ``pdftotext``, ``grep``, and structured
retrieval over the CIR / project graph.

Two flagship workflows:

* **RFI origination.** Detect inconsistencies ("panel schedule lists 14 circuits,
  plan shows 12 home-runs") from the CIR/graph, then auto-draft an RFI with the
  cropped drawing view, the conflicting evidence, and a cited spec clause. Routed to
  a human for one-click approve/transmit.
* **Spec/drawing-sync compliance.** Cross-reference drawings against spec sections;
  flag mismatches with exact citations.

Non-negotiables:

* **RAG, never fine-tune, on code/spec/contract text** — it changes and varies by
  jurisdiction; verbatim citation is mandatory.
* **Mandatory human-in-the-loop** on anything touching scope, cost, code, or
  life-safety. Every output is decision-support with confidence + citations.

Status: **stub.** Implemented in Build Playbook step 3.3. See the ``claude-api``
skill / Anthropic SDK for the agent + tool-use + prompt-caching implementation.
"""

from __future__ import annotations
