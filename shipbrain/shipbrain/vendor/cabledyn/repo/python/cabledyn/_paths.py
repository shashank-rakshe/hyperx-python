# SPDX-License-Identifier: Apache-2.0
"""File-name checks shared by the Python readers.

Windows maps the reserved device names (``CON``, ``PRN``, ``AUX``, ``NUL``,
``COM1``-``COM9``, ``LPT1``-``LPT9``, ``CONIN$``, ``CONOUT$``) to devices in
every directory and with any extension, so opening ``data/con.txt`` reads the
console and blocks. The native driver rejects these names; the readers use the
same rule so a mistyped path fails with a clear message instead of hanging.
"""

from __future__ import annotations

import os
import re
from pathlib import PureWindowsPath

__all__ = ["windows_device_component"]

_RESERVED_DEVICE = re.compile(
    r"(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³]|conin\$|conout\$)",
    re.IGNORECASE,
)


def windows_device_component(
    path: str | os.PathLike[str], *, windows: bool | None = None
) -> str | None:
    """Return the first path component that names a reserved Windows device.

    Parameters
    ----------
    path : str | os.PathLike
        Path to check.
    windows : bool | None
        Apply the Windows rule; ``None`` applies it only when running on
        Windows (``os.name == "nt"``). Other systems treat these names as
        ordinary files.

    Returns
    -------
    str | None
        The offending component, or ``None`` when the path names no device.
    """
    if windows is None:
        windows = os.name == "nt"
    if not windows:
        return None
    text = os.fspath(path)
    if text.startswith(("\\\\.\\", "//./")):
        return text
    for component in PureWindowsPath(text).parts:
        # Windows ignores everything from the first dot or colon and trailing
        # spaces when it matches a device name ("con.txt", "nul .dat", "CON:").
        stem = re.split(r"[.:]", component, maxsplit=1)[0].rstrip(" ")
        if _RESERVED_DEVICE.fullmatch(stem) is not None:
            return component
    return None
