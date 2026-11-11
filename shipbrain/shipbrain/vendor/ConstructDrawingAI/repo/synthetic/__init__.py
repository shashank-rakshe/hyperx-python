"""The synthetic-data engine — **our core competitive moat.**

.. warning::

   **PROPRIETARY. Do not open-source.** Per Decision 4 (publish results / withhold
   methods), the *existence* and *results* of this engine may be published, but its
   internals — the generation pipeline, the degradation models, the style/­distribution
   controls, and the curated mixes — stay private. This is what keeps the moat after we
   publish.

Because we bootstrap on public + synthetic data only (Decision 1), synthetic generation
is the load-bearing pillar, not a nice-to-have. The engine renders realistic 2D
construction drawings **from a canonical model with pixel-perfect ground truth**, and the
governing invariant is that the ground truth is *exactly* what was drawn — guaranteed by
deriving both the pixels and the CIR from one source model in one place
(:mod:`synthetic.render`), then proving it with the eval harness's ground-truth validator.

v0 scope: **electrical only** — power/lighting plans, panel schedules, and
single-line/connectivity diagrams. Breadth (mechanical, plumbing, …) is a later step.

Module map:

* :mod:`synthetic.model` — the canonical :class:`~synthetic.model.ElectricalModel` (truth).
* :mod:`synthetic.scene` — parametric scene generation (the v0 source).
* :mod:`synthetic.ifc_source` — IFC → model via IfcOpenShell (source-limited; see docs).
* :mod:`synthetic.render` — model → images + CIR, the one auditable mapping.
* :mod:`synthetic.style` / :mod:`synthetic.symbols` / :mod:`synthetic.canvas` — drafting style.
* :mod:`synthetic.degrade` — parameterized, image-only legacy-scan degradation.
* :mod:`synthetic.qa` — optional, local-model-only grounded QA pairs (default off).
* :mod:`synthetic.expect` + :mod:`eval.validate` — the ground-truth self-validation.
* :mod:`synthetic.generate` — the ``python -m synthetic.generate`` CLI and pipeline.

CLI: ``python -m synthetic.generate --type electrical --n 1000 --degradation-range 0..3
--out <dvc_path>`` (``--style-seed``, ``--qa-pairs``). Re-validate a run with
``python -m synthetic.validate <out_dir>``.

This top-level import is deliberately light (provenance only); pull in submodules for
rendering so ``import synthetic`` does not require Pillow/NumPy.
"""

from __future__ import annotations

from .provenance import (
    ENGINE_VERSION,
    SYNTHETIC_LANE,
    SYNTHETIC_LICENSE,
    SyntheticProvenanceError,
    assert_synthetic_owned,
    stamp,
)

__all__ = [
    "SYNTHETIC_LICENSE",
    "SYNTHETIC_LANE",
    "ENGINE_VERSION",
    "SyntheticProvenanceError",
    "assert_synthetic_owned",
    "stamp",
]
