# SPDX-License-Identifier: Apache-2.0
"""Lazy imports of optional plotting and table dependencies."""

from __future__ import annotations

from typing import Any


def pyplot() -> Any:
    """Return ``matplotlib.pyplot`` or explain how to install it."""
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:  # pragma: no cover - depends on the optional environment
        raise ImportError("matplotlib is required for plotting; install 'cabledyn[plot]'") from exc
    return plt
