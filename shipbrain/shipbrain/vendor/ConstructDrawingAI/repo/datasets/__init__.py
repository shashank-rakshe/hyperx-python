"""Dataset registry + license-aware prep/audit — **the data contract, not the data.**

This package holds a single source-of-truth registry of every public dataset we
plan to use, each annotated with its license provenance and data lane, plus the
scripts to download/prepare them into the CIR and to **audit** that no commercial-
lane record ever traces to a non-permissive source. The data itself is never
committed here — it is versioned with DVC (see ``.dvc/config``).

* :mod:`datasets.registry` — the :class:`DatasetRecord` model (which reuses
  :class:`cir.LicensedRecord`, so every dataset record carries the mandatory
  ``license_provenance`` + ``data_lane`` and obeys the lane invariant) and the
  YAML-backed :class:`DatasetRegistry`.
* :mod:`datasets.prepare` — ``python -m datasets.prepare <name>`` / ``--all``:
  idempotent download + convert-to-CIR (stubbed; built in Build Playbook step 0.2).
* :mod:`datasets.audit` — ``python -m datasets.audit``: fails loudly if any
  commercial-lane record is not commercial-safe.

.. note::

   This package is named ``datasets``, which shadows the HuggingFace ``datasets``
   library. They are not needed in the same interpreter yet (HF ``datasets`` enters
   in the Phase-2 training deps). When it does, import it explicitly to disambiguate;
   if a hard clash appears, this package can be renamed (e.g. ``dataset_registry``)
   without touching the CIR.
"""

from __future__ import annotations

from .registry import DatasetRecord, DatasetRegistry, Modality

__all__ = ["DatasetRecord", "DatasetRegistry", "Modality"]
