"""Tag normalization and ISA-5.1 instrument tag parsing."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from .ontology import ISA_FUNCTIONS, ISA_MEASURED, ISA_VARIABLE_MODIFIERS

_DASHES = dict.fromkeys(map(ord, "‐‑‒–—−"), "-")
_COMPACT = re.compile(r"^([A-Z]{1,6})(\d{1,6}[A-Z]{0,2})$")


def normalize_tag(raw: Optional[str]) -> Optional[str]:
    """Normalize a printed tag so the same item read twice compares equal.

    ``"fit 0502"``, ``"FIT-0502"``, ``"FIT_0502"`` and ``"FIT0502"`` all become
    ``"FIT-0502"``. Area prefixes and suffixes are preserved
    (``"660 TK 004"`` -> ``"660-TK-004"``).
    """
    if raw is None:
        return None
    s = str(raw).translate(_DASHES).strip().strip("\"'").upper()
    if not s:
        return None
    s = re.sub(r"[\s_/]*-[\s_/]*", "-", s)
    s = re.sub(r"[\s_]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    m = _COMPACT.match(s)
    if m:
        s = f"{m.group(1)}-{m.group(2)}"
    return s


def normalize_label(raw: Optional[str]) -> str:
    """Normalize free text (boundary names, off-page labels) for matching."""
    s = (raw or "").translate(_DASHES).upper()
    s = re.sub(r"[^A-Z0-9#\-\. ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


_ISA_TAG = re.compile(
    r"^(?:(?P<prefix>[0-9][0-9A-Z]*)-)?"
    r"(?P<letters>[A-Z]{1,6})-"
    r"(?P<number>[A-Z]?\d{1,5})(?P<suffix>[A-Z]{0,2})"
    r"(?:-(?P<ext>[A-Z0-9]{1,4}))?$"
)

_RELIEF = {"PSV", "PRV", "PSE", "TSV", "TSE", "VRV", "PVRV", "PVSV"}

ROLE_ORDER = (
    "relief_device",
    "hand_switch",
    "final_element",
    "relay",
    "controller",
    "transmitter",
    "switch",
    "element",
    "gauge",
    "indicator",
    "recorder",
    "totalizer",
    "alarm",
    "other",
)


@dataclass
class IsaTag:
    tag: str
    prefix: Optional[str]
    letters: str
    number: str
    suffix: str
    variable_code: str
    variable: str
    modifiers: list[str] = field(default_factory=list)
    functions: list[str] = field(default_factory=list)
    role: str = "other"

    @property
    def loop_key(self) -> str:
        base = f"{self.variable_code[0]}-{self.number}"
        return f"{self.prefix}-{base}" if self.prefix else base


def parse_isa_tag(tag: Optional[str]) -> Optional[IsaTag]:
    """Parse an ISA-5.1 style instrument tag. Returns None if it does not fit."""
    t = normalize_tag(tag)
    if not t:
        return None
    m = _ISA_TAG.match(t)
    if not m:
        return None
    letters = m.group("letters")
    first, rest = letters[0], letters[1:]
    if first not in ISA_MEASURED:
        return None

    variable_code = first
    modifiers: list[str] = []
    state = None
    # Open/closed state suffix on position and event tags: ZSO, ZSC, ZIO, ZIC, XSO, XSC.
    if first in "XYZ" and len(rest) >= 2 and rest[-1] in "OC" and rest[-2] in "IS":
        state = "open" if rest[-1] == "O" else "closed"
        rest = rest[:-1]
    if letters in _RELIEF:
        functions = ["safety", "valve"]
        role = "relief_device"
        variable_code = first
    else:
        if rest and rest[0] in ISA_VARIABLE_MODIFIERS and len(rest) > 1:
            variable_code = first + rest[0]
            modifiers.append(ISA_VARIABLE_MODIFIERS[rest[0]])
            rest = rest[1:]
        functions = [ISA_FUNCTIONS.get(ch, ch) for ch in rest]
        if state:
            functions.append(state)
        role = _role(rest)
        if first == "H" and role in ("switch", "controller", "indicator", "other"):
            role = "hand_switch"  # operator input (HS, HIC), not a process sensor

    variable = ISA_MEASURED[first]
    if modifiers:
        variable = f"{modifiers[0]} {variable}"
    return IsaTag(
        tag=t,
        prefix=m.group("prefix"),
        letters=letters,
        number=m.group("number"),
        suffix=m.group("suffix") or "",
        variable_code=variable_code,
        variable=variable,
        modifiers=modifiers,
        functions=functions,
        role=role,
    )


def _role(fn: str) -> str:
    if fn.endswith("V") or fn.endswith("Z"):
        return "final_element"
    if "Y" in fn:
        return "relay"
    if "C" in fn or fn.endswith("K"):
        return "controller"
    if "T" in fn:
        return "transmitter"
    if "S" in fn:
        return "switch"
    if "E" in fn:
        return "element"
    if "G" in fn:
        return "gauge"
    if "I" in fn:
        return "indicator"
    if "R" in fn:
        return "recorder"
    if "Q" in fn:
        return "totalizer"
    if "A" in fn:
        return "alarm"
    return "other"


# Roles that sense the process directly and therefore should have a MEASURES edge.
SENSING_ROLES = {"transmitter", "switch", "element", "gauge"}

# Candidate tags in free text (OCR or vector text). Deliberately loose; used only
# to suggest items the extraction may have missed.
TAG_CANDIDATE = re.compile(
    r"\b(?:\d{2,4}[- ]?)?[A-Z]{1,5}[- ]?\d{2,5}[A-Z]?\b"
)
