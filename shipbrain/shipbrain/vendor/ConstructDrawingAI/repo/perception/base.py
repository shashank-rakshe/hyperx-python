"""Interface for L1 perception primitives.

A perception module consumes a (partial) CIR :class:`~cir.DrawingSet` — typically
produced by L0 ingestion — and returns an enriched one: more entities, vectorized
geometry, OCR text, parsed dimensions, recovered scale, or sheet-graph edges. Every
module writes its outputs into the CIR with per-entity confidence and an audit trail
(``produced_by`` / ``model_version``), so downstream layers and the eval harness can
score and trust them.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

from cir import DrawingSet


class PerceptionModule(ABC):
    """A single L1 primitive (detector, vectorizer, OCR, scale, graph extractor)."""

    #: Human-readable identifier, recorded into ``Entity.produced_by``.
    name: str = "perception-module"
    #: Version string, recorded into ``Entity.model_version`` (audit trail).
    version: str = "0.0.0"

    @abstractmethod
    def run(self, drawing_set: DrawingSet) -> DrawingSet:
        """Enrich ``drawing_set`` and return it (or a new CIR document)."""
        raise NotImplementedError
