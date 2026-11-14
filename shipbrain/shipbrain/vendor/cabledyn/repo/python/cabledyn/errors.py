# SPDX-License-Identifier: Apache-2.0
"""Public exception hierarchy for CableDyn's Python interfaces.

Every class is importable without the native shared library, so callers can
catch in-process errors even in an installation that only uses the standalone
driver.
"""

from __future__ import annotations

__all__ = [
    "CableDynError",
    "ConvergenceError",
    "DeckFormatError",
    "DriverError",
    "DriverExecutionError",
    "DriverNotFoundError",
    "OutputFormatError",
    "StudyFormatError",
    "StudyOutputError",
]

#: Status codes returned by the CableDyn C ABI (``CD_C_*`` in ``CableDyn_CAPI.h``).
C_API_STATUS_NAMES = {
    0: "OK",
    1: "BAD_HANDLE",
    2: "ALLOC_FAIL",
    3: "BAD_INPUT",
    4: "SOLVE_FAIL",
    5: "NOT_INITIALIZED",
}


class DriverError(RuntimeError):
    """Base class for standalone-driver and result-file errors."""


class DriverNotFoundError(DriverError):
    """No usable CableDyn driver executable could be located."""


class DriverExecutionError(DriverError):
    """The native driver returned an error or did not produce its main output.

    Captured streams are retained for diagnosis.

    Parameters
    ----------
    message : str
        Error message.
    returncode : int | None
        Native exit code, or ``None``.
    stdout, stderr : str
        Captured output streams.

    Attributes
    ----------
    returncode : int | None
        Native exit code; ``None`` for failures that occur before process
        exit, such as a timeout. ``0`` means the run finished but its main
        output was missing or invalid.
    stdout : str
        Captured standard output, possibly partial.
    stderr : str
        Captured standard error, possibly partial.
    """

    def __init__(
        self, message: str, *, returncode: int | None = None, stdout: str = "", stderr: str = ""
    ) -> None:
        super().__init__(message)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class OutputFormatError(DriverError):
    """A CableDyn output table is missing, truncated, or malformed."""


class DeckFormatError(ValueError):
    """A CableDyn input deck is structurally malformed or inconsistent."""


class StudyFormatError(ValueError):
    """A generated-case or completed-study manifest is malformed or unauditable."""


class StudyOutputError(OSError):
    """A study ran its cases but could not write ``summary.csv`` or ``study.json``.

    The per-case native outputs and logs that were already written are kept.
    """


class CableDynError(RuntimeError):
    """A CableDyn C API call failed.

    Parameters
    ----------
    call : str
        Name of the C function that failed.
    status : int
        C ABI status code (see ``C_API_STATUS_NAMES``).
    detail : str
        The library's diagnostic for the handle, possibly empty.

    Attributes
    ----------
    call : str
        Name of the C function that failed, for example ``"CableDyn_Step"``.
    status : int
        C ABI status code: 1 ``BAD_HANDLE``, 2 ``ALLOC_FAIL``, 3 ``BAD_INPUT``,
        4 ``SOLVE_FAIL``, or 5 ``NOT_INITIALIZED``.
    detail : str
        The library's diagnostic message for the handle, possibly empty.
    """

    def __init__(self, call: str, status: int, detail: str) -> None:
        name = C_API_STATUS_NAMES.get(status, str(status))
        message = f"{call} failed with {name}"
        super().__init__(f"{message}: {detail}" if detail else message)
        self.call = call
        self.status = status
        self.detail = detail


class ConvergenceError(CableDynError):
    """An implicit step finished without meeting the Newton tolerance.

    The model has already advanced to ``t + dt`` and holds the best iterate
    found, so retrying the same step would advance time twice. The status is
    always 4 (``SOLVE_FAIL``).

    Parameters
    ----------
    call : str
        Name of the C function that failed.
    detail : str
        The library's diagnostic for the handle, possibly empty.
    n_iter : int
        Newton iterations performed.
    stalled : bool
        Whether the line search stalled.

    Attributes
    ----------
    n_iter : int
        Newton iterations performed in the step.
    stalled : bool
        Whether the line search stalled.
    """

    def __init__(self, call: str, detail: str, *, n_iter: int, stalled: bool) -> None:
        super().__init__(call, 4, detail)
        self.n_iter = n_iter
        self.stalled = stalled
