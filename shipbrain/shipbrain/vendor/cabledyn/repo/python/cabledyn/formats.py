# SPDX-License-Identifier: Apache-2.0
"""Readers for OpenFAST, MoorDyn, and OpenFAST-coupled CableDyn output files.

Every reader returns the same typed tables as :func:`cabledyn.read_output`, so
statistics, fatigue, spectra, plots, comparisons, and exports work unchanged on
results from other tools:

* :func:`read_openfast_output` reads an OpenFAST time-series file, either the
  tab-separated text ``.out`` (title lines, a channel row, and a units row) or
  the binary ``.outb`` written by ``OutFileFmt = 2``/``3`` (all four binary
  format identifiers).
* :func:`read_moordyn_output` reads a MoorDyn main ``<root>.MD.out`` file, and
  :func:`read_moordyn_line` a per-line ``<root>.MD.Line<N>.out`` file, as
  written by MoorDyn-F in OpenFAST.
* :func:`read_coupled_run` gathers the files of one OpenFAST run that uses
  CableDyn as its mooring module (``CompMooring = 5``): ``<root>.CD.out``,
  ``<root>.CD.static.out``, and the OpenFAST ``<root>.out``/``<root>.outb``.
* :func:`read_table` dispatches on the file name.

Parsing is strict: a missing header, a units row whose width differs from the
channel row, a short data row, a non-numeric or non-finite value, a truncated
binary record, or non-increasing time raises :class:`OutputFormatError`. A channel
name that an OpenFAST file repeats keeps its column under a ``<name>_<k>`` alias.
"""

from __future__ import annotations

import os
import re
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn.errors import OutputFormatError
from cabledyn.results import (
    OutputTable,
    StaticProfile,
    TimeHistory,
    _check_not_device,
    _find_header,
    _parse_float,
    _read_lines,
    _unique_channels,
    read_output,
)

__all__ = [
    "CoupledRun",
    "MoorDynLineHistory",
    "read_coupled_run",
    "read_moordyn_line",
    "read_moordyn_output",
    "read_openfast_output",
    "read_table",
]

# OpenFAST binary output format identifiers (NWTC_IO FileFmtID_*).
_OUTB_WITH_TIME = 1
_OUTB_WITHOUT_TIME = 2
_OUTB_NO_COMPRESS_WITHOUT_TIME = 3
_OUTB_CHANNEL_LENGTH_IN = 4
_OUTB_DEFAULT_NAME_LENGTH = 10

# Indices are capped at nine digits so int() never meets an unbounded string.
_MOORDYN_NODE = re.compile(
    r"Node(0|[1-9][0-9]{0,8})"
    r"(px|py|pz|vx|vy|vz|ax|ay|az|Ux|Uy|Uz|Dx|Dy|Dz|bx|by|bz|Vx|Vy|Vz|Wz|Kurv)"
)
_MOORDYN_SEGMENT = re.compile(r"Seg([1-9][0-9]{0,8})(Ten|Dmp|Str|SRt|Lst)")
_MOORDYN_VECTORS = {
    "p": ("px", "py", "pz"),
    "v": ("vx", "vy", "vz"),
    "a": ("ax", "ay", "az"),
    "U": ("Ux", "Uy", "Uz"),
    "D": ("Dx", "Dy", "Dz"),
    "b": ("bx", "by", "bz"),
    "V": ("Vx", "Vy", "Vz"),
}
_MOORDYN_NODE_SCALARS = ("Wz", "Kurv")
_MOORDYN_SEGMENT_SCALARS = ("Ten", "Dmp", "Str", "SRt", "Lst")


def _read_text_table(
    path: str | os.PathLike[str],
    *,
    repeated_channels: bool = False,
) -> tuple[Path, str, tuple[str, ...], tuple[str, ...] | None, npt.NDArray[Any]]:
    """Parse a whitespace-separated ``Time`` table: title, channels, optional units, rows.

    With ``repeated_channels`` a repeated channel name (legitimate in an OpenFAST
    OutList) keeps its column under a ``<name>_<k>`` alias; otherwise it is an error.
    """
    table_path = Path(path).expanduser().resolve()
    lines = _read_lines(table_path)
    header_index = _find_header(lines) if lines else None
    if header_index is None or lines[header_index].split()[0].lower() not in {"time", "time(s)"}:
        raise OutputFormatError(f"{table_path}: no Time channel header row")
    channels = tuple(lines[header_index].split())
    if repeated_channels:
        channels = _unique_channels(channels, f"{table_path}:{header_index + 1}")
    elif len(channels) != len(set(channels)):
        raise OutputFormatError(f"{table_path}:{header_index + 1}: duplicate channel name")
    title = "\n".join(line.strip() for line in lines[:header_index] if line.strip())
    cursor = header_index + 1
    units: tuple[str, ...] | None = None
    if cursor < len(lines):
        tokens = tuple(lines[cursor].split())
        if tokens and all(token.startswith("(") and token.endswith(")") for token in tokens):
            if len(tokens) != len(channels):
                raise OutputFormatError(
                    f"{table_path}:{cursor + 1}: expected {len(channels)} units, got {len(tokens)}"
                )
            units = tokens
            cursor += 1
    rows: list[list[float]] = []
    for index in range(cursor, len(lines)):
        fields = lines[index].split()
        if not fields:
            continue
        if len(fields) != len(channels):
            raise OutputFormatError(
                f"{table_path}:{index + 1}: expected {len(channels)} fields, got {len(fields)}"
            )
        rows.append([_parse_float(field, table_path, index + 1) for field in fields])
    if not rows:
        raise OutputFormatError(f"{table_path}: table has no data rows")
    return table_path, title, channels, units, np.asarray(rows, dtype=np.float64)


def _history(
    path: Path,
    title: str,
    channels: tuple[str, ...],
    units: tuple[str, ...] | None,
    values: npt.NDArray[Any],
) -> TimeHistory:
    try:
        return TimeHistory(path, title, channels, units, values)
    except ValueError as exc:  # table checks other than the time order raise ValueError
        raise OutputFormatError(f"{path}: {exc}") from exc


class _BinaryCursor:
    """Sequential little-endian reader that fails closed on truncation."""

    def __init__(self, path: Path, data: bytes) -> None:
        self.path = path
        self.data = data
        self.offset = 0

    def take(self, count: int, dtype: str) -> npt.NDArray[Any]:
        size = np.dtype(dtype).itemsize * count
        if count < 0 or self.offset + size > len(self.data):
            raise OutputFormatError(
                f"{self.path}: binary output is truncated at byte {self.offset}"
            )
        values = np.frombuffer(self.data, dtype=dtype, count=count, offset=self.offset)
        self.offset += size
        return values

    def scalar(self, fmt: str) -> int | float:
        size = struct.calcsize(fmt)
        if self.offset + size > len(self.data):
            raise OutputFormatError(
                f"{self.path}: binary output is truncated at byte {self.offset}"
            )
        (value,) = struct.unpack_from(fmt, self.data, self.offset)
        self.offset += size
        return value  # type: ignore[no-any-return]

    def text(self, length: int) -> str:
        raw = self.take(length, "u1").tobytes()
        return raw.decode("latin-1").strip()


def _read_openfast_binary(path: Path) -> TimeHistory:
    """Decode an OpenFAST ``.outb`` file (NWTC_IO ``WrBinFAST`` layout)."""
    _check_not_device(path)
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise OutputFormatError(f"cannot read {path}: {exc}") from exc
    cursor = _BinaryCursor(path, data)
    file_id = int(cursor.scalar("<h"))
    if file_id not in {
        _OUTB_WITH_TIME,
        _OUTB_WITHOUT_TIME,
        _OUTB_NO_COMPRESS_WITHOUT_TIME,
        _OUTB_CHANNEL_LENGTH_IN,
    }:
        raise OutputFormatError(f"{path}: unknown OpenFAST binary format identifier {file_id}")
    name_length = (
        int(cursor.scalar("<h"))
        if file_id == _OUTB_CHANNEL_LENGTH_IN
        else _OUTB_DEFAULT_NAME_LENGTH
    )
    channel_count = int(cursor.scalar("<i"))
    sample_count = int(cursor.scalar("<i"))
    if name_length <= 0 or channel_count <= 0 or sample_count <= 0:
        raise OutputFormatError(
            f"{path}: binary header declares {channel_count} channels, {sample_count} samples, "
            f"and {name_length}-character names"
        )
    # Every count below sizes an allocation, so check the declared layout
    # against the bytes actually present before allocating anything. The
    # description adds at least its 4-byte length field.
    sample_bytes = 8 if file_id == _OUTB_NO_COMPRESS_WITHOUT_TIME else 2
    required = (
        16
        + 4
        + 2 * (channel_count + 1) * name_length
        + sample_count * channel_count * sample_bytes
        + (0 if file_id == _OUTB_NO_COMPRESS_WITHOUT_TIME else 8 * channel_count)
        + (4 * sample_count if file_id == _OUTB_WITH_TIME else 0)
    )
    available = len(data) - cursor.offset
    if required > available:
        raise OutputFormatError(
            f"{path}: binary output is truncated: the header declares {channel_count} channels, "
            f"{sample_count} samples, and {name_length}-character names, which need at least "
            f"{required} bytes after byte {cursor.offset}, but only {available} remain"
        )
    first, second = float(cursor.scalar("<d")), float(cursor.scalar("<d"))
    if not (np.isfinite(first) and np.isfinite(second)):
        raise OutputFormatError(f"{path}: binary time scale and offset must be finite")
    scale: npt.NDArray[np.float64]
    offset: npt.NDArray[np.float64]
    if file_id == _OUTB_NO_COMPRESS_WITHOUT_TIME:
        scale = np.ones(channel_count)
        offset = np.zeros(channel_count)
    else:
        scale = cursor.take(channel_count, "<f4").astype(np.float64)
        offset = cursor.take(channel_count, "<f4").astype(np.float64)
        if not np.all(np.isfinite(scale)) or np.any(scale == 0.0):
            raise OutputFormatError(f"{path}: binary channel scale factors must be non-zero")
    description_length = int(cursor.scalar("<i"))
    description = cursor.text(description_length)
    names = tuple(cursor.text(name_length) for _ in range(channel_count + 1))
    units = tuple(cursor.text(name_length) for _ in range(channel_count + 1))
    if file_id == _OUTB_WITH_TIME:
        if first == 0.0:
            raise OutputFormatError(f"{path}: binary time scale must be non-zero")
        packed_time = cursor.take(sample_count, "<i4").astype(np.float64)
    if file_id == _OUTB_NO_COMPRESS_WITHOUT_TIME:
        packed = cursor.take(sample_count * channel_count, "<f8")
    else:
        packed = cursor.take(sample_count * channel_count, "<i2")
    if cursor.offset != len(data):
        raise OutputFormatError(
            f"{path}: {len(data) - cursor.offset} unexpected trailing bytes after the data"
        )
    # Extreme header factors can overflow; the finiteness check of the table
    # reports that as a format error, so the floating-point warnings are muted.
    with np.errstate(over="ignore", invalid="ignore", divide="ignore"):
        if file_id == _OUTB_WITH_TIME:
            time = (packed_time - second) / first
        else:
            time = first + second * np.arange(sample_count, dtype=np.float64)
        values = (packed.reshape(sample_count, channel_count).astype(np.float64) - offset) / scale
    table = np.column_stack((time, values))
    unit_row = tuple(unit if unit.startswith("(") else f"({unit})" for unit in units)
    if not all(names):
        raise OutputFormatError(f"{path}: binary channel names must be non-empty")
    names = _unique_channels(names, str(path))
    return _history(path, description, names, unit_row, table)


def read_openfast_output(path: str | os.PathLike[str]) -> TimeHistory:
    """Read an OpenFAST text ``.out`` or binary ``.outb`` time-series file.

    The binary format is recognized by the ``.outb`` suffix. Compressed binary
    files store each channel as 16-bit integers with a per-channel scale and
    offset, so values carry that quantization; time is reconstructed exactly
    as OpenFAST encodes it. The file description becomes the table title.

    An OpenFAST OutList may request a channel twice (the r-test ElastoDyn file
    lists ``TwrBsFzt`` twice). Every column is kept: the first occurrence keeps
    its name, so ``column(name)`` returns it, and the k-th becomes
    ``<name>_k``, with a :class:`UserWarning`.

    Parameters
    ----------
    path : str | os.PathLike
        OpenFAST output file; a ``.outb`` suffix selects the binary reader.

    Returns
    -------
    TimeHistory
        Time, in seconds, followed by the OpenFAST channels in their recorded
        units; ``values`` has shape ``(n_samples, n_channels)``.

    Raises
    ------
    OutputFormatError
        If the file cannot be read, is truncated or malformed, has an empty
        channel name, holds a non-finite value, or its time does not
        strictly increase.
    """
    table_path = Path(path).expanduser().resolve()
    if table_path.suffix.lower() == ".outb":
        return _read_openfast_binary(table_path)
    return _history(*_read_text_table(table_path, repeated_channels=True))


def read_moordyn_output(path: str | os.PathLike[str]) -> TimeHistory:
    """Read a MoorDyn main output file such as ``<root>.MD.out``.

    Channel names keep MoorDyn's spelling (for example ``FAIRTEN1``); pass a
    channel mapping to :func:`cabledyn.compare_histories` to line them up with
    CableDyn names such as ``FairTen1``.

    Parameters
    ----------
    path : str | os.PathLike
        MoorDyn main output file.

    Returns
    -------
    TimeHistory
        Time, in seconds, followed by the MoorDyn channels in their recorded
        units (tensions in N, positions in m); ``values`` has shape
        ``(n_samples, n_channels)``.

    Raises
    ------
    OutputFormatError
        If the file cannot be read, has no ``Time`` header row, a units row or
        data row of the wrong width, a non-numeric or non-finite value, or
        non-increasing time.
    """
    return _history(*_read_text_table(path))


@dataclass(frozen=True)
class MoorDynLineHistory(TimeHistory):
    """A MoorDyn-F per-line output ``<root>.MD.Line<N>.out``.

    MoorDyn numbers nodes from ``0`` (End A) to ``N`` (End B) and segments from
    ``1`` to ``N``. Every channel must be one of the MoorDyn-F line quantities
    (node vectors ``p v a U D b V`` with ``x/y/z`` components, node scalars
    ``Wz`` and ``Kurv``, and segment scalars ``Ten Dmp Str SRt Lst``), and each
    quantity present must cover every node or segment of the line.

    A subclass of :class:`cabledyn.TimeHistory` with the same attributes;
    ``values`` has shape ``(n_samples, n_channels)``. Positions are in metres,
    velocities in m/s, forces and tensions in newtons, and times in seconds.

    Raises
    ------
    OutputFormatError
        If a channel is not a MoorDyn line channel, or the quantities present
        do not cover a consistent, contiguous set of nodes and segments.
    """

    def __post_init__(self) -> None:
        super().__post_init__()
        nodes: dict[str, list[int]] = {}
        segments: dict[str, list[int]] = {}
        for channel in self.channels[1:]:
            node = _MOORDYN_NODE.fullmatch(channel)
            segment = _MOORDYN_SEGMENT.fullmatch(channel)
            if node is not None:
                nodes.setdefault(node.group(2), []).append(int(node.group(1)))
            elif segment is not None:
                segments.setdefault(segment.group(2), []).append(int(segment.group(1)))
            else:
                raise OutputFormatError(f"{self.path}: {channel!r} is not a MoorDyn line channel")
        node_counts = {len(ids) for ids in nodes.values()}
        segment_counts = {len(ids) for ids in segments.values()}
        if len(node_counts) > 1 or len(segment_counts) > 1:
            raise OutputFormatError(f"{self.path}: line quantities cover different node counts")
        for kind, ids in nodes.items():
            if sorted(ids) != list(range(len(ids))) or len(set(ids)) != len(ids):
                raise OutputFormatError(f"{self.path}: Node*{kind} channels must be Node0..NodeN")
        for kind, ids in segments.items():
            if sorted(ids) != list(range(1, len(ids) + 1)) or len(set(ids)) != len(ids):
                raise OutputFormatError(f"{self.path}: Seg*{kind} channels must be Seg1..SegN")
        if (
            node_counts
            and segment_counts
            and next(iter(node_counts)) != next(iter(segment_counts)) + 1
        ):
            raise OutputFormatError(f"{self.path}: node and segment counts are inconsistent")
        for vector, components in _MOORDYN_VECTORS.items():
            present = [component in nodes for component in components]
            if any(present) and not all(present):
                raise OutputFormatError(
                    f"{self.path}: node quantity {vector!r} needs all three components"
                )
        if not nodes and not segments:
            raise OutputFormatError(f"{self.path}: MoorDyn line file has no line channels")
        segment_total = (
            next(iter(segment_counts)) if segment_counts else next(iter(node_counts)) - 1
        )
        object.__setattr__(self, "_segment_total", segment_total)

    @property
    def quantities(self) -> tuple[str, ...]:
        """MoorDyn quantity codes present, e.g. ``("p", "Ten")``, in file order."""
        found: list[str] = []
        for channel in self.channels[1:]:
            node = _MOORDYN_NODE.fullmatch(channel)
            if node is not None:
                code = node.group(2)
                kind = code if code in _MOORDYN_NODE_SCALARS else code[0]
            else:
                segment = _MOORDYN_SEGMENT.fullmatch(channel)
                assert segment is not None  # guaranteed by __post_init__
                kind = segment.group(2)
            if kind not in found:
                found.append(kind)
        return tuple(found)

    @property
    def segment_count(self) -> int:
        """Number of segments ``N`` of the line."""
        return int(getattr(self, "_segment_total"))  # noqa: B009 - set in __post_init__

    @property
    def node_count(self) -> int:
        """Number of nodes ``N + 1`` of the line."""
        return self.segment_count + 1

    def node_vectors(self, quantity: str, time: float) -> npt.NDArray[Any]:
        """Return an interpolated, read-only ``(N + 1, 3)`` node vector snapshot.

        Parameters
        ----------
        quantity : str
            ``"p"`` (position, m), ``"v"`` (velocity, m/s), ``"a"``
            (acceleration, m/s^2), ``"U"`` (fluid velocity, m/s), ``"D"``
            (drag, N), ``"b"`` (seabed force, N), or ``"V"`` (other force, N).
        time : float
            Physical time, in seconds, within the recorded interval.

        Returns
        -------
        numpy.ndarray
            Read-only ``(N + 1, 3)`` array of x, y, z components, one row per
            node from ``Node0`` (End A), linearly interpolated in time.

        Raises
        ------
        ValueError
            If ``quantity`` is unknown, or ``time`` is not finite or lies
            outside the recorded interval.
        KeyError
            If the file does not record that quantity.
        """
        try:
            components = _MOORDYN_VECTORS[quantity]
        except KeyError as exc:
            raise ValueError(f"unknown MoorDyn node vector {quantity!r}") from exc
        count = self.node_count
        names = tuple(f"Node{node}{component}" for node in range(count) for component in components)
        if any(name not in self.channels for name in names):
            raise KeyError(f"{self.path.name} has no {quantity!r} node channels")
        values = self._interpolate(names, time).reshape((count, 3))
        values.setflags(write=False)
        return values

    def positions(self, time: float) -> npt.NDArray[Any]:
        """Return interpolated ``(N + 1, 3)`` node positions in metres at ``time``.

        Parameters
        ----------
        time : float
            Physical time, in seconds, within the recorded interval.

        Returns
        -------
        numpy.ndarray
            Read-only ``(N + 1, 3)`` node positions, in metres, from End A.

        Raises
        ------
        ValueError
            If ``time`` is not finite or lies outside the recorded interval.
        KeyError
            If the file does not record node positions.
        """
        return self.node_vectors("p", time)

    def segment_values(self, quantity: str, time: float) -> npt.NDArray[Any]:
        """Return one interpolated segment scalar (``Ten``, ``Dmp``, ``Str``, ``SRt``, ``Lst``).

        Parameters
        ----------
        quantity : str
            ``"Ten"`` (tension, N), ``"Dmp"`` (internal damping force, N),
            ``"Str"`` (strain, dimensionless), ``"SRt"`` (strain rate, 1/s), or
            ``"Lst"`` (stretched length, m).
        time : float
            Physical time, in seconds, within the recorded interval.

        Returns
        -------
        numpy.ndarray
            Read-only ``(N,)`` values, one per segment from ``Seg1`` (End A),
            linearly interpolated in time.

        Raises
        ------
        ValueError
            If ``quantity`` is unknown, or ``time`` is not finite or lies
            outside the recorded interval.
        KeyError
            If the file does not record that quantity.
        """
        if quantity not in _MOORDYN_SEGMENT_SCALARS:
            raise ValueError(f"unknown MoorDyn segment quantity {quantity!r}")
        names = tuple(f"Seg{segment}{quantity}" for segment in range(1, self.segment_count + 1))
        if any(name not in self.channels for name in names):
            raise KeyError(f"{self.path.name} has no {quantity!r} segment channels")
        return self._interpolate(names, time)

    def segment_tensions(self, time: float) -> npt.NDArray[Any]:
        """Return interpolated segment tensions (``Seg<i>Ten``) at ``time``.

        Parameters
        ----------
        time : float
            Physical time, in seconds, within the recorded interval.

        Returns
        -------
        numpy.ndarray
            Read-only ``(N,)`` segment tensions, in newtons, from End A.

        Raises
        ------
        ValueError
            If ``time`` is not finite or lies outside the recorded interval.
        KeyError
            If the file does not record segment tensions.
        """
        return self.segment_values("Ten", time)


def read_moordyn_line(path: str | os.PathLike[str]) -> MoorDynLineHistory:
    """Read a MoorDyn-F per-line output file ``<root>.MD.Line<N>.out``.

    Parameters
    ----------
    path : str | os.PathLike
        MoorDyn-F per-line output file.

    Returns
    -------
    MoorDynLineHistory
        The validated line history, with node and segment accessors.

    Raises
    ------
    OutputFormatError
        If the file cannot be read, is not a rectangular table of finite
        numbers with increasing time, or holds channels that are not a
        consistent set of MoorDyn line quantities.
    """
    # The text parser admits only finite numbers in a rectangular table, so the
    # table checks that can fail here all raise OutputFormatError.
    return MoorDynLineHistory(*_read_text_table(path))


@dataclass(frozen=True)
class CoupledRun:
    """The result files of one OpenFAST run that uses CableDyn (``CompMooring = 5``).

    A member is ``None`` when the run did not write that file.

    Attributes
    ----------
    root : pathlib.Path
        Absolute OpenFAST output root, without a suffix.
    cabledyn : TimeHistory | None
        CableDyn channel history ``<root>.CD.out``; time in seconds.
    static : StaticProfile | None
        Coupled static line profile ``<root>.CD.static.out``; lengths in
        metres and tensions in newtons.
    openfast : TimeHistory | None
        OpenFAST glue-code output ``<root>.out`` or ``<root>.outb``.
    """

    root: Path
    cabledyn: TimeHistory | None
    static: StaticProfile | None
    openfast: TimeHistory | None


def read_coupled_run(root: str | os.PathLike[str]) -> CoupledRun:
    """Read the files of a coupled OpenFAST + CableDyn run from its output root.

    When both ``<root>.out`` and ``<root>.outb`` exist the call fails, because
    either could be stale. At least one file must exist.

    Parameters
    ----------
    root : str | os.PathLike
        OpenFAST output root: the ``.fst`` path without its suffix. A
        ``.fst``, ``.out``, or ``.outb`` suffix is removed.

    Returns
    -------
    CoupledRun
        The files found; members for missing files are ``None``.

    Raises
    ------
    FileNotFoundError
        If none of the files exists.
    OutputFormatError
        If both ``<root>.out`` and ``<root>.outb`` exist, a file is malformed,
        or ``<root>.CD.static.out`` is not a line profile.
    """
    stem = Path(root).expanduser().resolve()
    if stem.suffix.lower() in {".out", ".outb", ".fst"}:
        stem = stem.with_suffix("")
    history_path = Path(f"{stem}.CD.out")
    static_path = Path(f"{stem}.CD.static.out")
    text_path, binary_path = Path(f"{stem}.out"), Path(f"{stem}.outb")
    if text_path.is_file() and binary_path.is_file():
        raise OutputFormatError(
            f"both {text_path.name} and {binary_path.name} exist; read the intended one with "
            "read_openfast_output"
        )
    cabledyn = _history(*_read_text_table(history_path)) if history_path.is_file() else None
    static: StaticProfile | None = None
    if static_path.is_file():
        table = read_output(static_path)
        if not isinstance(table, StaticProfile):
            raise OutputFormatError(f"{static_path}: coupled static output is not a line profile")
        static = table
    openfast_path = text_path if text_path.is_file() else binary_path
    openfast = read_openfast_output(openfast_path) if openfast_path.is_file() else None
    if cabledyn is None and static is None and openfast is None:
        raise FileNotFoundError(f"no OpenFAST or CableDyn outputs exist for root {stem}")
    return CoupledRun(stem, cabledyn, static, openfast)


def read_table(path: str | os.PathLike[str], *, format: str = "auto") -> OutputTable:
    """Read any supported output table.

    Automatic selection uses the file name: ``.outb`` is OpenFAST binary,
    ``*.MD.Line<N>.out`` a MoorDyn line file, ``*.MD.out`` a MoorDyn main
    file, and anything else the CableDyn reader (which also reads OpenFAST
    text output and ``*.CD.out`` files).

    Parameters
    ----------
    path : str | os.PathLike
        Output file to read.
    format : str
        ``"cabledyn"`` (:func:`cabledyn.read_output`), ``"openfast"``
        (:func:`read_openfast_output`), ``"moordyn"``
        (:func:`read_moordyn_output`), ``"moordyn-line"``
        (:func:`read_moordyn_line`), or ``"auto"``.

    Returns
    -------
    OutputTable
        The table returned by the selected reader, usually a
        :class:`~cabledyn.TimeHistory` or one of its subclasses.

    Raises
    ------
    ValueError
        If ``format`` is unknown.
    OutputFormatError
        If the file cannot be read or is malformed.
    """
    table_path = Path(path).expanduser().resolve()
    name = table_path.name
    if format == "auto":
        if table_path.suffix.lower() == ".outb":
            format = "openfast"
        elif re.search(r"\.MD\.Line[1-9][0-9]*\.out$", name, flags=re.IGNORECASE):
            format = "moordyn-line"
        elif re.search(r"\.MD\.out$", name, flags=re.IGNORECASE):
            format = "moordyn"
        else:
            format = "cabledyn"
    readers = {
        "cabledyn": read_output,
        "openfast": read_openfast_output,
        "moordyn": read_moordyn_output,
        "moordyn-line": read_moordyn_line,
    }
    try:
        reader = readers[format]
    except KeyError as exc:
        raise ValueError(
            f"format must be one of auto, {', '.join(readers)}; got {format!r}"
        ) from exc
    return reader(table_path)
