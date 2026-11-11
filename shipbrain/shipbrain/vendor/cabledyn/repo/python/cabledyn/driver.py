# SPDX-License-Identifier: Apache-2.0
"""Safe subprocess interface to the production CableDyn standalone driver."""

from __future__ import annotations

import contextlib
import math
import operator
import os
import re
import shutil
import subprocess
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from cabledyn.errors import (
    DriverError,
    DriverExecutionError,
    DriverNotFoundError,
    OutputFormatError,
)
from cabledyn.results import (
    LineNodeHistory,
    LineSegmentHistory,
    NaturalModes,
    OutputTable,
    StaticProfile,
    TimeHistory,
    read_output,
)

__all__ = [
    "CableDynDriver",
    "DriverError",
    "DriverExecutionError",
    "DriverNotFoundError",
    "DriverResult",
    "read_output",
]


def _checked_timeout(timeout: float | None) -> float | None:
    """Return a finite positive timeout in seconds, ``None`` for no limit."""
    if timeout is None:
        return None
    if isinstance(timeout, bool):
        raise ValueError("timeout must be finite and positive")
    try:
        value = float(timeout)
    except (TypeError, ValueError) as exc:
        raise ValueError("timeout must be finite and positive") from exc
    if not math.isfinite(value) or value <= 0.0:
        raise ValueError("timeout must be finite and positive")
    return value


def _timeout_stream(value: str | bytes | None) -> str:
    """Normalize TimeoutExpired captures to the public text-stream contract."""
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


# The last stderr line of every non-zero exit the driver makes itself.
_CLOSING_LINE = re.compile(r"CableDyn_driver: ended with exit code -?\d+\s*\Z")
# The start-up line of a driver that writes the closing line on every failure (app/cabledyn.f90).
_EXIT_CONTRACT = re.compile(
    r"^\s*Exit status: .*ends stderr with "
    r"\"CableDyn_driver: ended with exit code <n>\"",
    re.MULTILINE,
)
# The driver's report of an interrupt or a fatal fault (src/cabledyn_fatal.c).
_ABNORMAL_REPORT = re.compile(r"^CableDyn_driver: (?:fatal error:|stopped by) .*$", re.MULTILINE)
# The Fortran runtime's own report of an error it ends the process on (for example memory
# exhaustion), which leaves no closing line.
_RUNTIME_REPORT = re.compile(
    r"^(?:forrtl: |Fortran runtime error|Error allocating|Operating system error|"
    r"Program received signal).*$",
    re.MULTILINE,
)


def _last_output_time(main: Path, window: int = 1 << 20) -> float | None:
    """Time of the last complete row of a main output table, or ``None``."""
    try:
        with main.open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            start = max(0, size - window)
            handle.seek(start)
            tail = handle.read()
    except OSError:
        return None
    lines = tail.splitlines(keepends=True)
    # A row is trusted only whole: ended by a line end, and begun inside the window.
    first_whole = 0 if start == 0 else 1
    for line in reversed(lines[first_whole:]):
        fields = line.split()
        if not line.endswith(b"\n") or not fields:
            continue
        try:
            value = float(fields[0])
        except ValueError:
            return None
        return value if math.isfinite(value) else None
    return None


def _failure_message(returncode: int, stdout: str, stderr: str, main: Path) -> str:
    """Describe a non-zero exit, telling the driver's own failures from an abnormal end."""
    closing = _CLOSING_LINE.search(stderr)
    if closing:
        # The closing line repeats the exit code; the diagnostic is what precedes it.
        diagnostic = stderr[: closing.start()].strip() or stdout.strip() or "no diagnostic"
        return f"CableDyn driver failed with exit code {returncode}: {diagnostic}"
    last = _last_output_time(main)
    reached = "" if last is None else f"; its output ends at t = {last:g} s"
    report = _ABNORMAL_REPORT.findall(stderr)
    if report:
        return f"CableDyn driver ended abnormally (exit code {returncode}){reached}: {report[-1]}"
    runtime = _RUNTIME_REPORT.findall(stderr)
    if runtime:
        return (
            f"CableDyn driver ended with a Fortran runtime error (exit code {returncode})"
            f"{reached}: {runtime[-1].strip()}"
        )
    if not _EXIT_CONTRACT.search(stderr):
        # A driver that does not state the exit contract (0.1.0 and older) writes no closing
        # line on any failure, so its own refusals look just like this: report them as such.
        diagnostic = stderr.strip() or stdout.strip() or "no diagnostic"
        return f"CableDyn driver failed with exit code {returncode}{reached}: {diagnostic}"
    # The conclusion goes last: summaries show the last line of a message.
    diagnostic = stderr.strip() or stdout.strip()
    tail = "".join(f"{line}\n" for line in diagnostic.splitlines()[-20:])
    return (
        f"{tail}CableDyn driver ended with exit code {returncode} without reporting a "
        f"result{reached}: the process was ended from outside (for example by Task Manager, "
        "taskkill /F or kill -9) or by a fault it could not report."
    )


@dataclass(frozen=True)
class DriverResult:
    """Files and captured streams from one completed driver run.

    A result exists only after a zero native exit, which the driver reserves for
    a fully converged analysis, and validation of the main table.

    Attributes
    ----------
    executable : pathlib.Path
        Absolute path of the native driver that ran.
    deck : pathlib.Path
        Absolute path of the input deck.
    output_root : pathlib.Path
        Absolute output stem, without ``.out``.
    main_output : pathlib.Path
        Main channel history ``<root>.out``.
    static_output : pathlib.Path | None
        Static line profile ``<root>.static.out``, or ``None`` if not written.
    elements_output : pathlib.Path | None
        Per-element static table ``<root>.elements.out`` written for finite-EI
        lines, or ``None`` if not written.
    line_outputs : tuple[pathlib.Path, ...]
        Per-line node-position (``.p.out``) and segment-tension (``.t.out``)
        files, sorted by name.
    rod_outputs : tuple[pathlib.Path, ...]
        Per-rod node-position files, sorted by name.
    stdout : str
        Captured standard output of the driver.
    stderr : str
        Captured standard error of the driver.
    returncode : int
        Native exit code; always ``0`` for a result.
    modes_output : pathlib.Path | None
        Natural frequencies and mode shapes ``<root>.modes.out``, or ``None``
        if not written.
    """

    executable: Path
    deck: Path
    output_root: Path
    main_output: Path
    static_output: Path | None
    elements_output: Path | None
    line_outputs: tuple[Path, ...]
    rod_outputs: tuple[Path, ...]
    stdout: str
    stderr: str
    returncode: int
    modes_output: Path | None = None

    def read_main(self) -> TimeHistory:
        """Read the primary channel history again from disk.

        Returns
        -------
        TimeHistory
            The main output table: time in seconds followed by the requested
            channels (tensions in N, positions in m, angles in deg).

        Raises
        ------
        OutputFormatError
            If the file is missing, malformed, or not a time history.
        """
        table = read_output(self.main_output)
        if not isinstance(table, TimeHistory):
            raise OutputFormatError(f"{self.main_output}: main output is not a time history")
        return table

    def read_static(self) -> StaticProfile:
        """Read the static profile, raising if this run did not create one.

        Returns
        -------
        StaticProfile
            The static line profile, with lengths in metres and tensions in
            newtons.

        Raises
        ------
        FileNotFoundError
            If the run did not write a static profile.
        OutputFormatError
            If the file is malformed or not a line profile.
        """
        if self.static_output is None:
            raise FileNotFoundError("the run did not produce a .static.out profile")
        table = read_output(self.static_output)
        if not isinstance(table, StaticProfile):
            raise OutputFormatError(f"{self.static_output}: static output is not a line profile")
        return table

    def read_modes(self) -> NaturalModes:
        """Read the natural modes, raising if this run did not write them.

        Returns
        -------
        NaturalModes
            The frequency table of each line, with the mode shapes in its
            ``shapes`` attribute.

        Raises
        ------
        FileNotFoundError
            If the run did not write a modal output (the deck sets no ``nModes``).
        OutputFormatError
            If the file is malformed or not a modal output.
        """
        if self.modes_output is None:
            raise FileNotFoundError("the run did not produce a .modes.out file")
        table = read_output(self.modes_output)
        if not isinstance(table, NaturalModes):
            raise OutputFormatError(f"{self.modes_output}: modal output has no modal tables")
        return table

    @property
    def line_ids(self) -> tuple[int, ...]:
        """Line identifiers for which a per-line output file was produced."""
        identifiers: set[int] = set()
        pattern = re.compile(r"\.Line([1-9][0-9]*)\.[pt]\.out$")
        for path in self.line_outputs:
            match = pattern.search(path.name)
            if match:
                identifiers.add(int(match.group(1)))
        return tuple(sorted(identifiers))

    def _line_output(self, line_id: int, flag: str) -> Path:
        try:
            identifier = operator.index(line_id)
        except TypeError as exc:
            raise ValueError("line_id must be a positive integer") from exc
        if isinstance(line_id, bool) or identifier <= 0:
            raise ValueError("line_id must be a positive integer")
        suffix = f".Line{identifier}.{flag}.out"
        matches = tuple(path for path in self.line_outputs if path.name.endswith(suffix))
        if not matches:
            raise FileNotFoundError(
                f"the run did not produce the requested Line {identifier} {flag!r} output"
            )
        if len(matches) != 1:
            raise OutputFormatError(f"multiple outputs match {suffix}")
        return matches[0]

    def read_line_positions(self, line_id: int) -> OutputTable:
        """Read one line's static node table or dynamic node-position history.

        Parameters
        ----------
        line_id : int
            Positive, one-based line identifier.

        Returns
        -------
        OutputTable
            A :class:`LineNodeHistory` for a dynamic run, or a static table
            with ``Node``, ``X(m)``, ``Y(m)``, and ``Z(m)`` columns; positions
            in metres.

        Raises
        ------
        ValueError
            If ``line_id`` is not a positive integer.
        FileNotFoundError
            If the run did not write that line's position output.
        OutputFormatError
            If the file is malformed, ambiguous, or not a line-position table.
        """
        table = read_output(self._line_output(line_id, "p"))
        if isinstance(table, LineSegmentHistory) or not (
            isinstance(table, LineNodeHistory)
            or {"Node", "X(m)", "Y(m)", "Z(m)"}.issubset(table.channels)
        ):
            raise OutputFormatError(f"{table.path}: expected a line-position output")
        return table

    def read_line_tensions(self, line_id: int) -> OutputTable:
        """Read one line's static segment table or dynamic segment-tension history.

        Parameters
        ----------
        line_id : int
            Positive, one-based line identifier.

        Returns
        -------
        OutputTable
            A :class:`LineSegmentHistory` for a dynamic run, or a static table
            with ``Segment`` and ``Tension(N)`` columns; tensions in newtons.

        Raises
        ------
        ValueError
            If ``line_id`` is not a positive integer.
        FileNotFoundError
            If the run did not write that line's tension output.
        OutputFormatError
            If the file is malformed, ambiguous, or not a line-tension table.
        """
        table = read_output(self._line_output(line_id, "t"))
        if isinstance(table, LineNodeHistory) or not (
            isinstance(table, LineSegmentHistory)
            or {"Segment", "Tension(N)"}.issubset(table.channels)
        ):
            raise OutputFormatError(f"{table.path}: expected a line-tension output")
        return table


def bundled_driver(package_directory: Path | None = None) -> Path:
    """The driver a wheel carries in the package's ``bin`` folder: ``CableDyn_driver`` (the name
    the MSVC-style toolchains give it) or ``cabledyn`` (GNU), each with ``.exe`` on Windows. Returns
    the first that exists, else the ``CableDyn_driver`` path (to report)."""
    package = Path(__file__).resolve().parent if package_directory is None else package_directory
    suffix = ".exe" if os.name == "nt" else ""
    candidates = [package / "bin" / f"{stem}{suffix}" for stem in ("CableDyn_driver", "cabledyn")]
    return next((c for c in candidates if c.is_file()), candidates[0])


def _resolve_executable(executable: str | os.PathLike[str] | None) -> Path:
    direct_candidates: list[str | os.PathLike[str]] = []
    if executable is not None:
        direct_candidates.append(executable)
    else:
        env = os.environ.get("CABLEDYN_DRIVER")
        if env:
            direct_candidates.append(env)

    tried: list[str] = []
    for candidate in direct_candidates:
        resolved = Path(candidate).expanduser().resolve()
        tried.append(str(resolved))
        if resolved.is_file() and (os.name == "nt" or os.access(resolved, os.X_OK)):
            return resolved
    if executable is None:
        # the driver a wheel carries in the package (matching its bundled library) before PATH
        bundled = bundled_driver()
        tried.append(str(bundled))
        if bundled.is_file() and (os.name == "nt" or os.access(bundled, os.X_OK)):
            return bundled
        for name in ("CableDyn_driver.exe", "CableDyn_driver", "cabledyn"):
            found = shutil.which(name)
            tried.append(name)
            if found:
                return Path(found).resolve()
    source = (
        "the explicit path"
        if executable is not None
        else "CABLEDYN_DRIVER, the bundled driver or PATH"
    )
    raise DriverNotFoundError(
        f"could not locate CableDyn_driver using {source}. Tried: {', '.join(tried)}"
    )


def _merged_environment(overrides: Mapping[str, str]) -> dict[str, str]:
    """Merge ``overrides`` over the process environment.

    Windows environment names are case-insensitive, so an override such as
    ``Path`` replaces the inherited ``PATH`` instead of duplicating it.
    """
    merged = dict(os.environ)
    for key, value in overrides.items():
        if os.name == "nt":
            for existing in [name for name in merged if name.upper() == key.upper()]:
                del merged[existing]
        merged[key] = value
    return merged


def _result_files(root: Path) -> list[Path]:
    """Return every existing native result file of ``root``.

    These are the files a run with ``overwrite`` moves aside and restores: every name the
    driver writes under the root, the VIV lift (``.Line<L>.V.out``), range
    (``.Line<L>.range.out``) and modal (``.modes.out``) outputs included.
    """
    fixed = ("out", "static.out", "elements.out", "modes.out")
    candidates = [Path(f"{root}.{suffix}") for suffix in fixed]
    candidates.extend(_auxiliary_outputs(root, "Line", r"(?:[pt]|V|range)"))
    candidates.extend(_auxiliary_outputs(root, "Rod"))
    return [path for path in candidates if path.is_file()]


def _auxiliary_outputs(root: Path, object_name: str, flag: str | None = None) -> tuple[Path, ...]:
    """Find literal ``<root>.<object_name>*.out`` files without glob expansion.

    ``flag`` is the regular expression of the part before ``.out``; by default the
    node-position and tension files (``p``/``t`` for lines, ``p`` for rods).
    """
    if flag is None:
        flag = {"Line": "[pt]", "Rod": "p"}[object_name]
    pattern = re.compile(rf"{re.escape(root.name)}\.{object_name}-?\d+\.{flag}\.out")
    return tuple(
        sorted(
            path
            for path in root.parent.iterdir()
            if path.is_file() and pattern.fullmatch(path.name)
        )
    )


class CableDynDriver:
    """Run complete standalone decks through ``CableDyn_driver.exe``.

    Parameters
    ----------
    executable : str | os.PathLike | None
        Explicit native executable. When omitted, ``CABLEDYN_DRIVER`` is
        checked before release/development names on ``PATH``.

    Attributes
    ----------
    executable : pathlib.Path
        Absolute path of the resolved native driver.

    Raises
    ------
    DriverNotFoundError
        If no executable driver can be located.
    """

    def __init__(self, executable: str | os.PathLike[str] | None = None) -> None:
        self.executable = _resolve_executable(executable)

    def version(self, *, timeout: float = 10.0) -> str:
        """Query and return the complete native version banner.

        Parameters
        ----------
        timeout : float
            Finite, positive time limit, in seconds.

        Returns
        -------
        str
            The version banner the driver prints for ``--version``.

        Raises
        ------
        ValueError
            If ``timeout`` is not finite and positive.
        DriverExecutionError
            If the query times out or exits with a non-zero code.
        """
        if _checked_timeout(timeout) is None:
            raise ValueError("timeout must be finite and positive")
        try:
            completed = subprocess.run(
                [str(self.executable), "--version"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise DriverExecutionError(
                f"CableDyn driver version query exceeded the {timeout:g} s timeout",
                stdout=_timeout_stream(exc.stdout),
                stderr=_timeout_stream(exc.stderr),
            ) from exc
        if completed.returncode != 0:
            raise DriverExecutionError(
                f"CableDyn driver version query failed with exit code {completed.returncode}",
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            )
        return "\n".join(
            part.strip() for part in (completed.stderr, completed.stdout) if part.strip()
        )

    def run(
        self,
        deck: str | os.PathLike[str],
        output_root: str | os.PathLike[str],
        *,
        timeout: float | None = None,
        cwd: str | os.PathLike[str] | None = None,
        env: Mapping[str, str] | None = None,
        overwrite: bool = False,
    ) -> DriverResult:
        """Run one complete deck and validate its primary output.

        Existing results are protected unless ``overwrite`` is true. With
        ``overwrite``, the previous result files of this root are moved into a
        temporary directory beside them while the solver runs. They are
        deleted only after the new run succeeds; on any failure the partial new
        files are removed and the previous results are restored.

        Parameters
        ----------
        deck : str | os.PathLike
            Input deck. A relative path is resolved against ``cwd`` when given.
        output_root : str | os.PathLike
            Output stem without ``.out``; a relative stem is resolved against
            the working directory. Missing parent directories are created.
        timeout : float | None
            ``None`` (no limit) or a finite, positive limit in seconds.
        cwd : str | os.PathLike | None
            Working directory of the run; defaults to the deck directory,
            preserving relative ancillary-file references.
        env : collections.abc.Mapping[str, str] | None
            Entries merged over the process environment.
        overwrite : bool
            Replace existing result files of this root.

        Returns
        -------
        DriverResult
            The written files and captured streams of the converged run.

        Raises
        ------
        ValueError
            If ``timeout`` is invalid, or ``output_root`` has no stem or ends
            in ``.out``.
        NotADirectoryError
            If ``cwd`` does not exist.
        FileNotFoundError
            If the deck does not exist.
        FileExistsError
            If result files exist for the root and ``overwrite`` is false.
        DriverExecutionError
            If the driver times out, exits with a non-zero code (for example
            on non-convergence), or does not write a valid main output.
        """
        timeout = _checked_timeout(timeout)
        if cwd is not None:
            workdir = Path(cwd).expanduser().resolve()
            if not workdir.is_dir():
                raise NotADirectoryError(f"working directory does not exist: {workdir}")
            deck_arg = Path(deck).expanduser()
            deck_path = (deck_arg if deck_arg.is_absolute() else workdir / deck_arg).resolve()
        else:
            deck_path = Path(deck).expanduser().resolve()
            workdir = deck_path.parent
        if not deck_path.is_file():
            raise FileNotFoundError(f"CableDyn deck does not exist: {deck_path}")
        root_arg = Path(output_root).expanduser()
        if root_arg.name in {"", ".", ".."}:
            raise ValueError("output_root must include a file stem")
        root = root_arg.resolve() if root_arg.is_absolute() else (workdir / root_arg).resolve()
        if root.suffix.lower() == ".out":
            raise ValueError("output_root is a stem; omit the .out suffix")
        root.parent.mkdir(parents=True, exist_ok=True)

        existing = _result_files(root)
        if existing and not overwrite:
            raise FileExistsError(
                f"output files already exist for {root}; pass overwrite=True to replace them"
            )
        if not existing:
            return self._execute(deck_path, root, workdir, timeout, env)
        backup = Path(tempfile.mkdtemp(prefix=f".{root.name}.previous-", dir=root.parent))
        moved: list[Path] = []
        try:
            for path in existing:
                os.replace(path, backup / path.name)
                moved.append(path)
            result = self._execute(deck_path, root, workdir, timeout, env)
        except BaseException:
            for path in _result_files(root):
                with contextlib.suppress(OSError):
                    path.unlink()
            for path in moved:
                os.replace(backup / path.name, path)
            shutil.rmtree(backup, ignore_errors=True)
            raise
        shutil.rmtree(backup, ignore_errors=True)
        return result

    def _execute(
        self,
        deck_path: Path,
        root: Path,
        workdir: Path,
        timeout: float | None,
        env: Mapping[str, str] | None,
    ) -> DriverResult:
        """Launch the native driver and validate what it wrote for ``root``."""
        command = [str(self.executable), str(deck_path), str(root)]
        process_env = None if env is None else _merged_environment(env)
        try:
            completed = subprocess.run(
                command,
                cwd=workdir,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
                env=process_env,
            )
        except subprocess.TimeoutExpired as exc:
            timeout_text = "configured" if timeout is None else f"{timeout:g} s"
            raise DriverExecutionError(
                f"CableDyn driver exceeded the {timeout_text} timeout",
                stdout=_timeout_stream(exc.stdout),
                stderr=_timeout_stream(exc.stderr),
            ) from exc
        if completed.returncode != 0:
            raise DriverExecutionError(
                _failure_message(
                    completed.returncode, completed.stdout, completed.stderr, Path(f"{root}.out")
                ),
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            )

        main = Path(f"{root}.out")
        if not main.is_file():
            raise DriverExecutionError(
                f"CableDyn driver exited successfully but did not create {main}",
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            )
        try:
            read_output(main)
        except (DriverError, OSError, ValueError) as exc:
            raise DriverExecutionError(
                f"CableDyn driver exited successfully but produced an invalid main output: {exc}",
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            ) from exc
        static_candidate = Path(f"{root}.static.out")
        elements_candidate = Path(f"{root}.elements.out")
        modes_candidate = Path(f"{root}.modes.out")
        line_outputs = _auxiliary_outputs(root, "Line")
        rod_outputs = _auxiliary_outputs(root, "Rod")
        return DriverResult(
            executable=self.executable,
            deck=deck_path,
            output_root=root,
            main_output=main,
            static_output=static_candidate if static_candidate.is_file() else None,
            elements_output=elements_candidate if elements_candidate.is_file() else None,
            line_outputs=line_outputs,
            rod_outputs=rod_outputs,
            stdout=completed.stdout,
            stderr=completed.stderr,
            returncode=completed.returncode,
            modes_output=modes_candidate if modes_candidate.is_file() else None,
        )
