# SPDX-License-Identifier: Apache-2.0
"""Build case specifications for parametric deck studies.

:func:`parameter_grid` turns selector value lists into the ``{case: {selector:
value}}`` mapping that :func:`cabledyn.generate_deck_cases` and
``cabledyn-deck generate`` consume::

    cases = parameter_grid({"option.dtM": [0.01, 0.02], "section.1.1.length": [540, 550]})
    generate_deck_cases("base.dat", "study", cases)
"""

from __future__ import annotations

import itertools
import re
from collections.abc import Mapping, Sequence

__all__ = ["parameter_grid"]

_CASE_PREFIX = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def parameter_grid(
    parameters: Mapping[str, Sequence[object]], *, mode: str = "product", prefix: str = "case"
) -> dict[str, dict[str, object]]:
    """Return case specifications for every combination (or pairing) of values.

    ``mode="product"`` takes the Cartesian product of the value lists in
    selector order (the last selector varies fastest); ``mode="zip"`` pairs
    the i-th values of equally long lists. Cases are named ``<prefix>000``,
    ``<prefix>001``, ... with enough digits for the case count (at least
    three).

    Parameters
    ----------
    parameters : collections.abc.Mapping[str, list | tuple]
        ``{selector: values}``, for example ``{"option.dtM": [0.01, 0.02]}``.
        Each value list is a non-empty sequence (not a string). Values are
        passed through unchanged, in the units the deck selector expects (SI
        for CableDyn decks), so any value the selector accepts can be used.
        Selector and value validity is checked later, when the decks are
        generated.
    mode : str
        ``"product"`` or ``"zip"``.
    prefix : str
        Case-name prefix matching ``[A-Za-z0-9][A-Za-z0-9_.-]*``.

    Returns
    -------
    dict[str, dict[str, object]]
        ``{case_name: {selector: value}}`` in case order, ready for
        :func:`cabledyn.generate_deck_cases`.

    Raises
    ------
    ValueError
        If ``prefix`` is invalid, ``parameters`` is empty, a selector is not a
        non-empty string, a value list is empty or a string, ``mode`` is
        unknown, or ``"zip"`` lists differ in length.
    """
    if not isinstance(prefix, str) or not _CASE_PREFIX.fullmatch(prefix):
        raise ValueError("prefix must match [A-Za-z0-9][A-Za-z0-9_.-]*")
    if not parameters:
        raise ValueError("parameters must name at least one selector")
    selectors = list(parameters)
    columns: list[list[object]] = []
    for selector in selectors:
        values = parameters[selector]
        if not isinstance(selector, str) or not selector:
            raise ValueError("selectors must be non-empty strings")
        if isinstance(values, (str, bytes)) or not isinstance(values, Sequence) or not values:
            raise ValueError(f"{selector}: values must be a non-empty sequence (not a string)")
        columns.append(list(values))
    if mode == "product":
        combinations = list(itertools.product(*columns))
    elif mode == "zip":
        if len({len(column) for column in columns}) != 1:
            raise ValueError("zip mode needs value lists of equal length")
        combinations = list(zip(*columns, strict=True))
    else:
        raise ValueError("mode must be 'product' or 'zip'")
    width = max(3, len(str(len(combinations) - 1)))
    return {
        f"{prefix}{index:0{width}d}": dict(zip(selectors, combination, strict=True))
        for index, combination in enumerate(combinations)
    }
