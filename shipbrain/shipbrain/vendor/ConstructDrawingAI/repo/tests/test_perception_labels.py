"""The detector class set is derived from the synthetic engine, and L1 calls no APIs."""

from __future__ import annotations

import subprocess
import sys

from perception.labels import (
    CLASS_NAMES,
    INDEX_TO_CLASS,
    LABEL_TO_INDEX,
    NUM_CLASSES,
    is_detectable,
)
from synthetic.model import DEVICE_CATALOG, PANEL_CLASS


def test_class_set_is_the_synthetic_vocabulary_plus_panel() -> None:
    # Exactly every renderable device kind + the panelboard.
    assert len(DEVICE_CATALOG) + 1 == NUM_CLASSES
    for device_class in DEVICE_CATALOG.values():
        assert device_class.label in LABEL_TO_INDEX
    assert PANEL_CLASS.label in LABEL_TO_INDEX
    assert CLASS_NAMES[-1] == PANEL_CLASS.label  # panel appended last (stable order)


def test_indices_are_contiguous_and_round_trip() -> None:
    assert sorted(LABEL_TO_INDEX.values()) == list(range(NUM_CLASSES))
    for index, dc in INDEX_TO_CLASS.items():
        assert LABEL_TO_INDEX[dc.label] == index
        assert CLASS_NAMES[index] == dc.label


def test_is_detectable_distinguishes_symbols_from_structure() -> None:
    assert is_detectable("Duplex Receptacle")
    assert is_detectable("Panelboard")
    assert not is_detectable("Wall")  # structure, not a detection target
    assert not is_detectable("Dimension")


def test_importing_perception_calls_no_external_api_sdks() -> None:
    """`import perception` must not pull a frontier SDK — these are our own models.

    Encodes the Build Playbook 2.1 rule: no external APIs anywhere in L1. The optional
    frontier vision adapters live in eval.frontier and must never be on a perception path.
    """
    # Check in a clean subprocess: the pytest process is shared, so a sibling test that
    # imports eval.frontier would otherwise pollute sys.modules and make this flaky.
    code = (
        "import perception, sys; "
        "bad = {'anthropic', 'openai', 'google.genai', 'google.generativeai', 'eval.frontier'}"
        " & set(sys.modules); "
        "assert not bad, sorted(bad)"
    )
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert (
        result.returncode == 0
    ), f"importing perception pulled an external-API SDK:\n{result.stderr}"
