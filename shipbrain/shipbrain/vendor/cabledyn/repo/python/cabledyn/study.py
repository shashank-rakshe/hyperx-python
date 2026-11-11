# SPDX-License-Identifier: Apache-2.0
"""Provenance-checked batch execution of generated CableDyn deck studies."""

from __future__ import annotations

import contextlib
import csv
import hashlib
import json
import math
import operator
import os
import re
import tempfile
import threading
import time
from collections.abc import Iterable
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from cabledyn.driver import CableDynDriver, DriverResult
from cabledyn.errors import DriverExecutionError, StudyFormatError, StudyOutputError

__all__ = ["StudyCaseResult", "StudyResult", "run_study"]

_CASE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
# Suffixes the native driver appends to an output root (``<root>.<suffix>.out``).
# Fixed-name MoorDyn-C kinematics files that generate_deck_cases copies next to the cases.
_COMPANION_FILES = frozenset(
    {
        "wave_elevation.txt",
        "wave_frequencies.txt",
        "current_profile.txt",
        "current_profile_dynamic.txt",
        "current_profile_4d.txt",
    }
)
_OUTPUT_SUFFIX = re.compile(
    r"\.(?:static|elements|modes|Line-?\d+\.(?:[pt]|V|range)|Rod-?\d+\.p)$", re.IGNORECASE
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent, text=True
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


def _write_summary(path: Path, fields: tuple[str, ...], rows: list[dict[str, object]]) -> None:
    """Atomically write the per-case statistics table."""
    fd, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent, text=True
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


def _write_log(path: Path, text: str) -> str | None:
    """Write one captured stream; return a diagnostic instead of raising."""
    try:
        _atomic_text(path, text)
    except OSError as exc:
        return f"could not write {path.name}: {exc}"
    return None


def _diagnostic_tail(error: BaseException) -> str:
    """Return a compact diagnostic; complete native streams live in log files."""
    lines = [line.strip() for line in str(error).splitlines() if line.strip()]
    return lines[-1] if lines else type(error).__name__


def _manifest_digest(value: object, *, field: str, path: Path) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9A-Fa-f]{64}", value) is None:
        raise StudyFormatError(f"{path}: {field} must be a 64-digit SHA-256 value")
    return value.lower()


@dataclass(frozen=True)
class StudyCaseResult:
    """Disposition and artifacts for one attempted generated case.

    Attributes
    ----------
    name : str
        Case name from the manifest.
    status : str
        ``"completed"``, ``"failed"`` (the native run failed), or
        ``"postprocess_failed"`` (the run finished but its outputs or logs
        could not be processed).
    deck : pathlib.Path
        Absolute path of the generated deck.
    deck_sha256 : str
        SHA-256 digest of the deck, verified against the manifest.
    output_root : pathlib.Path
        Absolute output stem of the case, without ``.out``.
    elapsed_seconds : float
        Wall-clock time spent on the case, in seconds.
    returncode : int | None
        Native exit code, or ``None`` if the process did not report one.
    main_output : pathlib.Path | None
        Main channel history, or ``None`` if not written.
    static_output : pathlib.Path | None
        Static line profile, or ``None`` if not written.
    stdout_log : pathlib.Path
        File holding the captured standard output.
    stderr_log : pathlib.Path
        File holding the captured standard error.
    error : str | None
        Short diagnostic for a failed case, otherwise ``None``.

    Raises
    ------
    ValueError
        If ``status`` is unknown or ``elapsed_seconds`` is negative or not
        finite.
    """

    name: str
    status: str
    deck: Path
    deck_sha256: str
    output_root: Path
    elapsed_seconds: float
    returncode: int | None
    main_output: Path | None
    static_output: Path | None
    stdout_log: Path
    stderr_log: Path
    error: str | None

    def __post_init__(self) -> None:
        if self.status not in {"completed", "failed", "postprocess_failed"}:
            raise ValueError(f"unsupported study case status {self.status!r}")
        if not math.isfinite(self.elapsed_seconds) or self.elapsed_seconds < 0.0:
            raise ValueError("elapsed_seconds must be finite and non-negative")
        for name in ("deck", "output_root", "stdout_log", "stderr_log"):
            object.__setattr__(self, name, Path(getattr(self, name)).expanduser().resolve())
        for name in ("main_output", "static_output"):
            value = getattr(self, name)
            if value is not None:
                object.__setattr__(self, name, Path(value).expanduser().resolve())


@dataclass(frozen=True)
class StudyResult:
    """Completed batch record and its deterministic summary artifacts.

    Attributes
    ----------
    case_manifest : pathlib.Path
        The ``cases.json`` manifest that was run.
    study_manifest : pathlib.Path
        The ``study.json`` record written for the batch.
    summary_csv : pathlib.Path
        The ``summary.csv`` table of per-case channel statistics, in each
        channel's unit.
    executable : pathlib.Path
        Absolute path of the native driver used.
    executable_sha256 : str
        SHA-256 digest of the driver executable.
    solver_version : str
        Native version banner of the driver.
    started_at : str
        UTC start time, ISO 8601.
    finished_at : str
        UTC finish time, ISO 8601.
    cases : tuple[StudyCaseResult, ...]
        One result per case, in manifest order.
    """

    case_manifest: Path
    study_manifest: Path
    summary_csv: Path
    executable: Path
    executable_sha256: str
    solver_version: str
    started_at: str
    finished_at: str
    cases: tuple[StudyCaseResult, ...]

    @property
    def passed(self) -> bool:
        """Whether every case completed with a converged native analysis."""
        return bool(self.cases) and all(case.status == "completed" for case in self.cases)

    @property
    def failed_cases(self) -> tuple[StudyCaseResult, ...]:
        """Cases whose native run or post-processing failed."""
        return tuple(case for case in self.cases if case.status != "completed")


@dataclass(frozen=True)
class _Case:
    name: str
    deck: Path
    sha256: str


def _load_cases(path: Path) -> tuple[tuple[_Case, ...], str]:
    try:
        manifest_bytes = path.read_bytes()
        data = json.loads(manifest_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StudyFormatError(f"cannot read case manifest {path}: {exc}") from exc
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    if not isinstance(data, dict) or data.get("schema") != "cabledyn-deck-cases-v1":
        raise StudyFormatError(f"{path}: expected schema 'cabledyn-deck-cases-v1'")
    source_text = data.get("source")
    if not isinstance(source_text, str):
        raise StudyFormatError(f"{path}: source must be a string")
    source_digest = _manifest_digest(
        data.get("source_sha256"),
        field="source_sha256",
        path=path,
    )
    source = Path(source_text).expanduser().resolve()
    if not source.is_file():
        raise StudyFormatError(f"{path}: source deck does not exist: {source}")
    if _sha256(source) != source_digest.lower():
        raise StudyFormatError(f"{path}: source deck SHA-256 does not match the manifest")
    rows = data.get("cases")
    if not isinstance(rows, list) or not rows:
        raise StudyFormatError(f"{path}: cases must be a non-empty array")
    cases: list[_Case] = []
    names: set[str] = set()
    decks: set[Path] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise StudyFormatError(f"{path}: case {index + 1} must be an object")
        name, deck_text = row.get("name"), row.get("deck")
        if not isinstance(name, str) or not isinstance(deck_text, str):
            raise StudyFormatError(f"{path}: case {index + 1} name/deck must be strings")
        digest = _manifest_digest(
            row.get("sha256"),
            field=f"case {index + 1} sha256",
            path=path,
        )
        folded = name.casefold()
        if not _CASE_NAME.fullmatch(name) or folded in names:
            raise StudyFormatError(f"{path}: case names must be safe and unique")
        names.add(folded)
        deck = Path(deck_text).expanduser().resolve()
        if deck in decks:
            raise StudyFormatError(f"{path}: generated deck paths must be unique")
        decks.add(deck)
        if not deck.is_file():
            raise StudyFormatError(f"{path}: generated deck does not exist: {deck}")
        if _sha256(deck) != digest:
            raise StudyFormatError(f"{path}: case {name!r} deck SHA-256 does not match")
        # MoorDyn-C kinematics files the case reads by fixed name from its folder
        companions = row.get("companion_files", {})
        if not isinstance(companions, dict):
            raise StudyFormatError(f"{path}: case {name!r} companion_files must be an object")
        for companion, companion_digest in companions.items():
            if companion not in _COMPANION_FILES:
                raise StudyFormatError(
                    f"{path}: case {name!r} names an unknown companion file {companion!r}"
                )
            expected = _manifest_digest(
                companion_digest, field=f"case {index + 1} {companion} sha256", path=path
            )
            companion_path = deck.parent / companion
            if not companion_path.is_file() or _sha256(companion_path) != expected:
                raise StudyFormatError(
                    f"{path}: case {name!r} companion file {companion_path} is missing or its "
                    "SHA-256 does not match"
                )
        cases.append(_Case(name, deck, digest))
    # Every case writes <name>.out, <name>.static.out, ... into one directory, so
    # a name such as "base.static" would overwrite files of case "base".
    for case in cases:
        match = _OUTPUT_SUFFIX.search(case.name)
        if match and case.name[: match.start()].casefold() in names:
            raise StudyFormatError(
                f"{path}: case name {case.name!r} collides with the output files of case "
                f"{case.name[: match.start()]!r}"
            )
    return tuple(cases), manifest_digest


def _case_dict(case: StudyCaseResult) -> dict[str, object]:
    result = asdict(case)
    for key, value in tuple(result.items()):
        if isinstance(value, Path):
            result[key] = str(value)
    return result


def run_study(
    case_manifest: str | os.PathLike[str],
    *,
    executable: str | os.PathLike[str] | None = None,
    driver: CableDynDriver | None = None,
    output_directory: str | os.PathLike[str] | None = None,
    channels: str | Iterable[str] | None = None,
    start: float | None = None,
    stop: float | None = None,
    timeout: float | None = None,
    jobs: int = 1,
    overwrite: bool = False,
) -> StudyResult:
    """Run every case in a ``generate_deck_cases`` manifest.

    Individual native failures are recorded and do not prevent remaining jobs
    from running. Manifest/hash/preflight errors fail before the first solver
    process starts.

    Parameters
    ----------
    case_manifest : str | os.PathLike
        ``cases.json`` written by :func:`cabledyn.generate_deck_cases`.
    executable : str | os.PathLike | None
        Native driver to use; located as by :class:`CableDynDriver` when
        omitted. Not allowed together with ``driver``.
    driver : CableDynDriver | None
        Pre-configured driver to use instead of ``executable``.
    output_directory : str | os.PathLike | None
        Directory for results, logs, ``summary.csv``, and ``study.json``;
        defaults to ``study-results`` beside the manifest.
    channels : str | collections.abc.Iterable[str] | None
        Main-output channels summarized in ``summary.csv``; every non-time
        channel when ``None``.
    start, stop : float | None
        Optional statistics window, in seconds.
    timeout : float | None
        Per-case time limit, in seconds; ``None`` for no limit.
    jobs : int
        Number of independent native processes run at once (not solver
        threads within a process).
    overwrite : bool
        Allow a non-empty output directory and replace existing case outputs.

    Returns
    -------
    StudyResult
        The batch record, including failed cases.

    Raises
    ------
    ValueError
        If both ``driver`` and ``executable`` are given, or ``jobs``,
        ``timeout``, ``start``, ``stop``, or ``channels`` is invalid.
    StudyFormatError
        If the manifest is malformed or a deck digest does not match it.
    FileExistsError
        If the output directory is not empty and ``overwrite`` is false.
    FileNotFoundError
        If the driver executable does not exist.
    DriverNotFoundError
        If no driver can be located.
    DriverExecutionError
        If the driver version query fails.
    StudyOutputError
        If the cases ran but ``summary.csv`` or ``study.json`` could not be
        written.
    """
    if driver is not None and executable is not None:
        raise ValueError("pass either driver or executable, not both")
    manifest_path = Path(case_manifest).expanduser().resolve()
    cases, manifest_digest = _load_cases(manifest_path)
    try:
        job_count = operator.index(jobs)
    except TypeError as exc:
        raise ValueError("jobs must be a positive integer") from exc
    if isinstance(jobs, bool) or job_count <= 0:
        raise ValueError("jobs must be a positive integer")
    if timeout is None:
        timeout_value = None
    else:
        if isinstance(timeout, bool):
            raise ValueError("timeout must be finite and positive")
        timeout_value = float(timeout)
        if not math.isfinite(timeout_value) or timeout_value <= 0.0:
            raise ValueError("timeout must be finite and positive")
    normalized_period: list[float | None] = []
    for value, label in ((start, "start"), (stop, "stop")):
        if value is None:
            normalized_period.append(None)
            continue
        if isinstance(value, bool):
            raise ValueError(f"{label} must be finite")
        numeric = float(value)
        if not math.isfinite(numeric):
            raise ValueError(f"{label} must be finite")
        normalized_period.append(numeric)
    start_value, stop_value = normalized_period
    if start_value is not None and stop_value is not None and start_value > stop_value:
        raise ValueError("start must not exceed stop")
    if channels is None:
        selected: tuple[str, ...] | None = None
    elif isinstance(channels, str):
        selected = (channels,)
    else:
        selected = tuple(channels)
    if selected is not None and (
        not selected
        or any(not isinstance(item, str) or not item for item in selected)
        or len(set(selected)) != len(selected)
    ):
        raise ValueError("channels must be non-empty and unique")

    destination = (
        Path(output_directory).expanduser().resolve()
        if output_directory is not None
        else manifest_path.parent / "study-results"
    )
    study_manifest = destination / "study.json"
    summary_csv = destination / "summary.csv"
    if destination.exists() and any(destination.iterdir()) and not overwrite:
        raise FileExistsError(
            f"study output directory is not empty: {destination}; pass overwrite=True"
        )
    native = driver if driver is not None else CableDynDriver(executable)
    executable_path = Path(native.executable).expanduser().resolve()
    if not executable_path.is_file():
        raise FileNotFoundError(f"CableDyn driver does not exist: {executable_path}")
    solver_digest = _sha256(executable_path)
    solver_version = native.version()
    destination.mkdir(parents=True, exist_ok=True)

    started = datetime.now(timezone.utc).isoformat()
    summaries: dict[str, list[dict[str, object]]] = {}
    summaries_lock = threading.Lock()

    def execute(case: _Case) -> StudyCaseResult:
        output_root = destination / case.name
        stdout_log = destination / f"{case.name}.stdout.log"
        stderr_log = destination / f"{case.name}.stderr.log"
        begin = time.perf_counter()
        stdout = ""
        stderr = ""
        native_result: DriverResult | None = None
        status = "completed"
        error: str | None = None
        returncode: int | None = None
        main_output: Path | None = None
        static_output: Path | None = None
        try:
            native_result = native.run(
                case.deck, output_root, timeout=timeout_value, overwrite=overwrite
            )
            stdout, stderr = native_result.stdout, native_result.stderr
            returncode = native_result.returncode
            main_output = native_result.main_output
            static_output = native_result.static_output
            history = native_result.read_main()
            view = (
                history.period(start_value, stop_value)
                if (start_value is not None or stop_value is not None)
                else history
            )
            stats = view.statistics(selected)
            with summaries_lock:
                summaries[case.name] = [asdict(item) for item in stats]
        except DriverExecutionError as exc:
            # A zero exit means the solver finished but its output was rejected.
            stdout, stderr, returncode = exc.stdout, exc.stderr, exc.returncode
            ran = exc.returncode == 0
            status = "postprocess_failed" if ran else "failed"
            error = _diagnostic_tail(exc)
            if ran:
                main_candidate = Path(f"{output_root}.out")
                static_candidate = Path(f"{output_root}.static.out")
                main_output = main_candidate if main_candidate.is_file() else None
                static_output = static_candidate if static_candidate.is_file() else None
        except Exception as exc:  # one case must never erase the record of the others
            status = "postprocess_failed" if native_result is not None else "failed"
            error = _diagnostic_tail(exc)
        log_errors = [
            problem
            for problem in (_write_log(stdout_log, stdout), _write_log(stderr_log, stderr))
            if problem is not None
        ]
        if log_errors:
            status = "postprocess_failed" if status == "completed" else status
            error = "; ".join(([error] if error else []) + log_errors)
        return StudyCaseResult(
            case.name,
            status,
            case.deck,
            case.sha256,
            output_root,
            time.perf_counter() - begin,
            returncode,
            main_output,
            static_output,
            stdout_log,
            stderr_log,
            error,
        )

    ordered: list[StudyCaseResult | None] = [None] * len(cases)
    executor = ThreadPoolExecutor(max_workers=min(job_count, len(cases)))
    try:
        future_indices: dict[Future[StudyCaseResult], int] = {
            executor.submit(execute, case): index for index, case in enumerate(cases)
        }
        for future in as_completed(future_indices):
            ordered[future_indices[future]] = future.result()
    except BaseException:
        # Interrupted (for example by Ctrl+C): do not start queued cases.
        executor.shutdown(wait=True, cancel_futures=True)
        raise
    executor.shutdown(wait=True)
    if any(case is None for case in ordered):  # pragma: no cover - executor invariant
        raise RuntimeError("internal error: a study case produced no result")
    results = tuple(case for case in ordered if case is not None)
    finished = datetime.now(timezone.utc).isoformat()

    rows: list[dict[str, object]] = []
    for case in results:
        case_stats = summaries.get(case.name, [])
        if not case_stats:
            rows.append(
                {
                    "case": case.name,
                    "status": case.status,
                    "elapsed_seconds": case.elapsed_seconds,
                    "channel": "",
                    "unit": "",
                    "count": "",
                    "minimum": "",
                    "maximum": "",
                    "mean": "",
                    "standard_deviation": "",
                    "rms": "",
                    "error": case.error or "",
                }
            )
        for stats in case_stats:
            rows.append(
                {
                    "case": case.name,
                    "status": case.status,
                    "elapsed_seconds": case.elapsed_seconds,
                    "channel": stats["channel"],
                    "unit": stats["unit"] or "",
                    "count": stats["count"],
                    "minimum": stats["minimum"],
                    "maximum": stats["maximum"],
                    "mean": stats["mean"],
                    "standard_deviation": stats["standard_deviation"],
                    "rms": stats["rms"],
                    "error": case.error or "",
                }
            )
    fields = (
        "case",
        "status",
        "elapsed_seconds",
        "channel",
        "unit",
        "count",
        "minimum",
        "maximum",
        "mean",
        "standard_deviation",
        "rms",
        "error",
    )
    try:
        _write_summary(summary_csv, fields, rows)
    except OSError as exc:
        raise StudyOutputError(f"cases ran but {summary_csv} could not be written: {exc}") from exc
    payload = {
        "schema": "cabledyn-study-results-v1",
        "case_manifest": str(manifest_path),
        "case_manifest_sha256": manifest_digest,
        "executable": str(executable_path),
        "executable_sha256": solver_digest,
        "solver_version": solver_version,
        "started_at": started,
        "finished_at": finished,
        "jobs": job_count,
        "timeout": timeout_value,
        "period": {"start": start_value, "stop": stop_value},
        "channels": list(selected) if selected is not None else None,
        "summary_csv": str(summary_csv),
        "cases": [_case_dict(case) for case in results],
    }
    try:
        _atomic_text(study_manifest, json.dumps(payload, indent=2, sort_keys=True) + "\n")
    except OSError as exc:
        raise StudyOutputError(
            f"cases ran but {study_manifest} could not be written: {exc}"
        ) from exc
    return StudyResult(
        manifest_path,
        study_manifest,
        summary_csv,
        executable_path,
        solver_digest,
        solver_version,
        started,
        finished,
        results,
    )
