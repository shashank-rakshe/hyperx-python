"""L2 — Semantic Grounding + Project Knowledge Graph.

L1 says "there is a symbol here, 93% confident." L2 makes it *mean* something:

* **Ontology mapping.** Assign each :class:`cir.Entity` its IFC class plus
  :class:`cir.OntologyCodes` — **MasterFormat** (North American spec/estimating),
  **UniFormat** (elemental/assembly takeoff), **OmniClass** (master taxonomy), and
  **Uniclass** (UK/EU expansion). A small classifier (literature reports ~0.99 F1 for
  IFC→Uniclass *when geometry is correct*) plus deterministic rules. Grounding is
  effectively solved if L1 is right — which is why we invest in L1.
* **Project knowledge graph.** A queryable graph (``networkx`` for v1; a graph DB
  later) linking drawings ↔ sheets ↔ entities ↔ specs ↔ schedules ↔ RFIs, including
  the cross-reference callout edges (:class:`cir.CrossReference`) and connectivity
  edges (:class:`cir.Connection`) recovered upstream.
* **Query API.** The clean interface the L4 agent calls — e.g. "all electrical
  panels and their circuits on E-201", "resolve callout 3/E-501".

The graph *is* the substrate L4 reasons over, and it is part of the moat (it is hard
to replicate and creates integration lock-in).

Status: **stub.** Implemented in Build Playbook step 3.1. Ships the ontology
reference tables and a ``networkx``-based graph.
"""

from __future__ import annotations
