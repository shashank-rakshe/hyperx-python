# SPDX-License-Identifier: Apache-2.0
"""Time-indexed geometry of a whole model, for animation and GUI playback.

:class:`Snapshots` holds the geometry of every line, point, body and rod at a
common set of sample times, together with the seabed and the water surface. It
is built either

* from an in-process run, with :class:`Recorder` (sample a
  :class:`~cabledyn.CableDyn` model every ``N`` steps) or the
  :func:`record` convenience loop, or
* from the standalone driver's files, with :meth:`Snapshots.from_files`
  (``.Line<L>.p.out``/``.t.out``, ``.Rod<N>.p.out``, the ``Point<P>p`` and
  ``Body<N>P/R`` channels of the main ``.out``) or :meth:`Snapshots.from_static`
  (the ``.static.out`` profile).

:meth:`Snapshots.save_npz` writes one compact ``.npz`` archive with one array
per object, which :meth:`Snapshots.load_npz` reads back; a viewer can load
only the arrays it draws. :func:`animate` plays the snapshots in a Matplotlib
3D axes.
"""

from __future__ import annotations

import math
import os
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np
import numpy.typing as npt

from cabledyn.clearance import Bathymetry, read_bathymetry
from cabledyn.errors import OutputFormatError
from cabledyn.results import LineNodeHistory, OutputTable, StaticProfile, read_output

if TYPE_CHECKING:
    from cabledyn.model import CableDyn

__all__ = [
    "FORMAT",
    "Recorder",
    "Seabed",
    "Snapshots",
    "WaterSurface",
    "animate",
    "record",
]

FloatArray = npt.NDArray[np.float64]

#: Format tag stored in every archive written by :meth:`Snapshots.save_npz`.
FORMAT = "cabledyn-snapshots-1"

_GRAVITY = 9.80665


def _readonly(values: npt.ArrayLike) -> FloatArray:
    arr = np.array(values, dtype=np.float64, copy=True)
    arr.setflags(write=False)
    return arr


@dataclass(frozen=True)
class Seabed:
    """The seabed: a flat plane at ``z = -depth`` or a bathymetry grid.

    Attributes
    ----------
    depth : float | None
        Flat water depth in metres (positive), or ``None`` with a grid.
    bathymetry : cabledyn.Bathymetry | None
        Structured seabed, which takes precedence over ``depth``.
    """

    depth: float | None = None
    bathymetry: Bathymetry | None = None

    def __post_init__(self) -> None:
        if self.bathymetry is None:
            if self.depth is None:
                raise ValueError("a seabed needs a depth or a bathymetry grid")
            if not math.isfinite(self.depth) or self.depth <= 0.0:
                raise ValueError("seabed depth must be finite and positive")

    def elevation(self, x: npt.ArrayLike, y: npt.ArrayLike) -> FloatArray:
        """Seabed elevation ``z_floor(x, y)`` [m] (negative below still water)."""
        if self.bathymetry is not None:
            return np.asarray(-self.bathymetry.depth_at(x, y), dtype=np.float64)
        shape = np.broadcast_shapes(np.shape(x), np.shape(y))
        assert self.depth is not None
        return np.full(shape, -self.depth)

    def grid(
        self, x_range: tuple[float, float], y_range: tuple[float, float], n: int = 25
    ) -> tuple[FloatArray, FloatArray, FloatArray]:
        """Surface mesh ``(X, Y, Z)`` of shape ``(n, n)`` over the given ranges."""
        gx, gy = np.meshgrid(np.linspace(*x_range, n), np.linspace(*y_range, n), indexing="ij")
        return gx, gy, self.elevation(gx, gy)


@dataclass(frozen=True)
class WaterSurface:
    """The free surface: still water, or a deck's regular Airy wave.

    Attributes
    ----------
    height, period : float
        Wave height [m] and period [s]; zero for still water.
    direction : float
        Propagation direction from +x toward +y [deg].
    depth : float | None
        Water depth for the dispersion relation [m]; ``None`` is deep water.
    gravity : float
        Gravitational acceleration [m/s^2].
    ramp_time : float
        Half-cosine start-up ramp of the amplitude [s] (the deck ``rampTime``).
    unmodelled : bool
        The deck has waves this surface does not reproduce (irregular seas and
        wave trains, whose random phases live in the solver, stream-function
        waves, or WaterKin kinematics, whose file may carry waves); the
        surface is then drawn as still water.

    The elevation is the solver's ``r(t) H/2 cos(k (x cos b + y sin b) - w t)``
    with ``w^2 = g k tanh(k h)`` and the ramp ``r(t) = (1 - cos(pi t / T))/2``
    for ``t < T``, else 1.
    """

    height: float = 0.0
    period: float = 0.0
    direction: float = 0.0
    depth: float | None = None
    gravity: float = _GRAVITY
    ramp_time: float = 0.0
    unmodelled: bool = False

    @property
    def still(self) -> bool:
        """Whether the surface is flat (no regular wave)."""
        return self.height <= 0.0 or self.period <= 0.0

    @property
    def wavenumber(self) -> float:
        """Wavenumber ``k`` [rad/m] from the linear dispersion relation (0 for still water)."""
        if self.still:
            return 0.0
        omega = 2.0 * math.pi / self.period
        k = omega * omega / self.gravity
        if self.depth is None:
            return k
        for _ in range(100):
            th = math.tanh(k * self.depth)
            f = self.gravity * k * th - omega * omega
            df = self.gravity * (th + k * self.depth * (1.0 - th * th))
            step = f / df
            k -= step
            if abs(step) < 1.0e-14 * k:
                break
        return k

    def elevation(self, time: float, x: npt.ArrayLike, y: npt.ArrayLike) -> FloatArray:
        """Surface elevation ``eta`` [m] at ``time`` and horizontal points ``(x, y)``."""
        gx = np.asarray(x, dtype=np.float64)
        gy = np.asarray(y, dtype=np.float64)
        if self.still:
            return np.zeros(np.broadcast_shapes(gx.shape, gy.shape))
        beta = math.radians(self.direction)
        omega = 2.0 * math.pi / self.period
        along = gx * math.cos(beta) + gy * math.sin(beta)
        ramp = 1.0
        if self.ramp_time > 0.0 and time < self.ramp_time:
            ramp = 0.0 if time <= 0.0 else 0.5 * (1.0 - math.cos(math.pi * time / self.ramp_time))
        amplitude = 0.5 * self.height * ramp
        return np.asarray(amplitude * np.cos(self.wavenumber * along - omega * time))

    @classmethod
    def from_deck(cls, deck: str | os.PathLike[str]) -> WaterSurface:
        """The surface a deck prescribes (its ``waves`` option; still water otherwise)."""
        from cabledyn.deck_file import DeckFile

        deck_file = DeckFile.read(deck)
        gravity = _option_float(deck_file, "g", _GRAVITY) or _GRAVITY
        depth = _option_float(deck_file, "WtrDpth", None)
        ramp = _option_float(deck_file, "rampTime", 0.0) or 0.0
        try:
            tokens = deck_file.option("waves").values
        except KeyError:
            # wave trains and WaterKin kinematics (a file, SEASTATE, or the
            # MoorDyn-C modes 3 and 7) are seas this surface does not draw
            try:
                deck_file.option("wavetrain")
            except KeyError:
                pass
            else:
                return cls(depth=depth, gravity=gravity, unmodelled=True)
            try:
                kinematics = deck_file.option("WaterKin").values[0].lower()
            except KeyError:
                kinematics = "none"
            return cls(
                depth=depth,
                gravity=gravity,
                unmodelled=kinematics not in {"none", "0"} and _nonzero(kinematics),
            )
        kind = tokens[0].lower() if tokens else "none"
        if kind == "airy" and len(tokens) >= 3:
            direction = float(tokens[3]) if len(tokens) > 3 else 0.0
            return cls(float(tokens[1]), float(tokens[2]), direction, depth, gravity, ramp)
        return cls(depth=depth, gravity=gravity, unmodelled=kind not in {"none", "0"})


def _nonzero(value: str) -> bool:
    """Whether a WaterKin value selects a kinematics source (anything but numeric 0)."""
    try:
        return float(value) != 0.0
    except ValueError:
        return True


def _option_float(deck_file: Any, keyword: str, default: float | None) -> float | None:
    try:
        return float(deck_file.option(keyword).values[0])
    except (KeyError, ValueError, IndexError):
        return default


def seabed_from_deck(deck: str | os.PathLike[str]) -> Seabed | None:
    """The seabed of a deck: its ``bathymetryFile`` grid, else its flat ``WtrDpth``."""
    from cabledyn.deck_file import DeckFile

    path = Path(deck).expanduser().resolve()
    deck_file = DeckFile.read(path)
    try:
        grid = deck_file.option("bathymetryFile").values[0]
    except KeyError:
        grid = ""
    if grid and grid.lower() not in {"none", "0"}:
        grid_path = Path(grid)
        if not grid_path.is_absolute():
            grid_path = path.parent / grid_path
        return Seabed(bathymetry=read_bathymetry(grid_path))
    depth = _option_float(deck_file, "WtrDpth", None)
    return Seabed(depth=depth) if depth is not None and depth > 0.0 else None


@dataclass(frozen=True)
class Snapshots:
    """Geometry of a model at a common set of sample times.

    Attributes
    ----------
    times : numpy.ndarray
        ``(n,)`` strictly increasing sample times [s].
    lines : Mapping[int, numpy.ndarray]
        Deck line id -> node positions ``(n, n_nodes, 3)`` [m], End A first.
    tensions : Mapping[int, numpy.ndarray]
        Deck line id -> segment tensions ``(n, n_segments)`` [N] (may be empty).
    points : Mapping[int, numpy.ndarray]
        Deck point id -> position ``(n, 3)`` [m].
    bodies : Mapping[int, numpy.ndarray]
        Deck body id -> pose ``(n, 6)``: reference point [m] and x-y'-z'' angles [deg].
    rods : Mapping[int, numpy.ndarray]
        Deck rod id -> node positions ``(n, n_nodes, 3)`` [m], End A first.
    seabed : Seabed | None
        The seabed, when known.
    water : WaterSurface | None
        The free surface, when known.
    """

    times: FloatArray
    lines: Mapping[int, FloatArray] = field(default_factory=dict)
    tensions: Mapping[int, FloatArray] = field(default_factory=dict)
    points: Mapping[int, FloatArray] = field(default_factory=dict)
    bodies: Mapping[int, FloatArray] = field(default_factory=dict)
    rods: Mapping[int, FloatArray] = field(default_factory=dict)
    seabed: Seabed | None = None
    water: WaterSurface | None = None

    def __post_init__(self) -> None:
        times = _readonly(self.times)
        if times.ndim != 1 or times.size == 0 or not np.all(np.isfinite(times)):
            raise ValueError("times must be a non-empty finite one-dimensional array")
        if times.size > 1 and np.any(np.diff(times) <= 0.0):
            raise ValueError("times must be strictly increasing")
        object.__setattr__(self, "times", times)
        n = times.size
        for name, ndim, tail in (
            ("lines", 3, 3),
            ("tensions", 2, None),
            ("points", 2, 3),
            ("bodies", 2, 6),
            ("rods", 3, 3),
        ):
            checked: dict[int, FloatArray] = {}
            for key, value in getattr(self, name).items():
                arr = _readonly(value)
                if arr.ndim != ndim or arr.shape[0] != n or (tail and arr.shape[-1] != tail):
                    raise ValueError(f"{name}[{key}] has shape {arr.shape}; expected {n} samples")
                checked[int(key)] = arr
            object.__setattr__(self, name, dict(sorted(checked.items())))

    @property
    def n_frames(self) -> int:
        """Number of sample times."""
        return int(self.times.size)

    def index_at(self, time: float) -> int:
        """Index of the sample nearest to ``time``."""
        return int(np.argmin(np.abs(self.times - float(time))))

    def frame(self, index: int) -> dict[str, dict[int, FloatArray]]:
        """All geometry of one sample: ``{"lines": {id: (n_nodes, 3)}, "points": ...}``."""
        return {
            "lines": {k: v[index] for k, v in self.lines.items()},
            "tensions": {k: v[index] for k, v in self.tensions.items()},
            "points": {k: v[index] for k, v in self.points.items()},
            "bodies": {k: v[index] for k, v in self.bodies.items()},
            "rods": {k: v[index] for k, v in self.rods.items()},
        }

    def bounds(self) -> tuple[FloatArray, FloatArray]:
        """Lower and upper corners ``(3,)`` of every recorded position [m]."""
        chunks: list[FloatArray] = [v.reshape(-1, 3) for v in self.lines.values()]
        chunks += [v.reshape(-1, 3) for v in self.rods.values()]
        chunks += [v.reshape(-1, 3) for v in self.points.values()]
        chunks += [v[:, :3] for v in self.bodies.values()]
        if not chunks:
            raise ValueError("the snapshots hold no geometry")
        allxyz = np.concatenate(chunks)
        return allxyz.min(axis=0), allxyz.max(axis=0)

    # -- archive ---------------------------------------------------------------

    def save_npz(self, path: str | os.PathLike[str], *, compress: bool = True) -> Path:
        """Write the snapshots to one ``.npz`` archive and return its path.

        Keys: ``format``, ``times``, ``line/<id>/xyz``, ``line/<id>/tension``,
        ``point/<id>/xyz``, ``body/<id>/pose``, ``rod/<id>/xyz``, and when known
        ``seabed/depth`` or ``seabed/x``, ``seabed/y``, ``seabed/depth_grid``,
        and ``water/airy`` = ``[height, period, direction, depth or nan, g,
        ramp_time, unmodelled]``. ``compress=False`` writes an uncompressed archive whose
        members can be read without inflating.
        """
        arrays: dict[str, Any] = {"format": np.array(FORMAT), "times": self.times}
        for key, value in self.lines.items():
            arrays[f"line/{key}/xyz"] = value
        for key, value in self.tensions.items():
            arrays[f"line/{key}/tension"] = value
        for key, value in self.points.items():
            arrays[f"point/{key}/xyz"] = value
        for key, value in self.bodies.items():
            arrays[f"body/{key}/pose"] = value
        for key, value in self.rods.items():
            arrays[f"rod/{key}/xyz"] = value
        if self.seabed is not None:
            if self.seabed.bathymetry is not None:
                arrays["seabed/x"] = self.seabed.bathymetry.x
                arrays["seabed/y"] = self.seabed.bathymetry.y
                arrays["seabed/depth_grid"] = self.seabed.bathymetry.depth
            else:
                arrays["seabed/depth"] = np.array(self.seabed.depth)
        if self.water is not None:
            w = self.water
            arrays["water/airy"] = np.array(
                [
                    w.height,
                    w.period,
                    w.direction,
                    np.nan if w.depth is None else w.depth,
                    w.gravity,
                    w.ramp_time,
                    float(w.unmodelled),
                ]
            )
        target = Path(path).expanduser()
        if target.suffix != ".npz":
            target = target.with_name(target.name + ".npz")
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as stream:
            (np.savez_compressed if compress else np.savez)(stream, **arrays)
        return target.resolve()

    @classmethod
    def load_npz(cls, path: str | os.PathLike[str]) -> Snapshots:
        """Read an archive written by :meth:`save_npz`."""
        with np.load(Path(path).expanduser(), allow_pickle=False) as data:
            if "format" not in data.files or str(data["format"]) != FORMAT:
                raise OutputFormatError(f"{path}: not a {FORMAT} archive")
            groups: dict[str, dict[int, FloatArray]] = {
                "lines": {},
                "tensions": {},
                "points": {},
                "bodies": {},
                "rods": {},
            }
            where = {
                ("line", "xyz"): "lines",
                ("line", "tension"): "tensions",
                ("point", "xyz"): "points",
                ("body", "pose"): "bodies",
                ("rod", "xyz"): "rods",
            }
            for key in data.files:
                parts = key.split("/")
                if len(parts) == 3 and (parts[0], parts[2]) in where:
                    groups[where[(parts[0], parts[2])]][int(parts[1])] = data[key]
            seabed = None
            if "seabed/depth_grid" in data.files:
                seabed = Seabed(
                    bathymetry=Bathymetry(
                        data["seabed/x"], data["seabed/y"], data["seabed/depth_grid"]
                    )
                )
            elif "seabed/depth" in data.files:
                seabed = Seabed(depth=float(data["seabed/depth"]))
            water = None
            if "water/airy" in data.files:
                h, t, d, depth, g, ramp, other = (float(v) for v in data["water/airy"])
                water = WaterSurface(
                    h, t, d, None if math.isnan(depth) else depth, g, ramp, bool(other)
                )
            return cls(times=data["times"], seabed=seabed, water=water, **groups)

    # -- output files ------------------------------------------------------------

    @classmethod
    def from_files(
        cls, root: str | os.PathLike[str], *, deck: str | os.PathLike[str] | None = None
    ) -> Snapshots:
        """Collect the geometry the standalone driver wrote for output root ``root``.

        Lines come from ``<root>.Line<L>.p.out`` (and tensions from
        ``.t.out``), rods from ``<root>.Rod<N>.p.out`` (End A and End B),
        points and bodies from the ``Point<P>p{x,y,z}`` and ``Body<N>P/R{x,y,z}``
        channels of ``<root>.out``. The sample times are those of the per-line
        files, else of the main output; other series are interpolated linearly
        onto them. ``deck`` adds its seabed and water surface.
        """
        base = Path(root).expanduser().resolve()
        main_path = base.with_name(base.name + ".out")
        main = read_output(main_path) if main_path.is_file() else None
        line_files = _numbered(base, "Line", "p")
        tension_files = _numbered(base, "Line", "t")
        rod_files = _numbered(base, "Rod", "p")
        lines: dict[int, tuple[FloatArray, FloatArray]] = {}
        for key, path in line_files.items():
            table = read_output(path)
            if isinstance(table, LineNodeHistory):
                lines[key] = (table.time, table.values[:, 1:].reshape(table.time.size, -1, 3))
            else:
                xyz = np.column_stack([table.column(c) for c in ("X(m)", "Y(m)", "Z(m)")])
                lines[key] = (np.zeros(1), xyz[np.newaxis])
        times: FloatArray | None = None
        if lines:
            times = next(iter(lines.values()))[0]
        elif main is not None:
            times = _time_column(main)
        if times is None:
            raise FileNotFoundError(f"no CableDyn output files found for root {base}")

        def on_times(t: FloatArray, values: FloatArray) -> FloatArray:
            if t.size == times.size and np.array_equal(t, times):
                return values
            flat = values.reshape(t.size, -1)
            out = np.column_stack([np.interp(times, t, flat[:, j]) for j in range(flat.shape[1])])
            return out.reshape((times.size, *values.shape[1:]))

        line_xyz = {k: on_times(t, v) for k, (t, v) in lines.items()}
        tensions: dict[int, FloatArray] = {}
        for key, path in tension_files.items():
            table = read_output(path)
            if "Time(s)" in table.channels:
                tensions[key] = on_times(_time_column(table), table.values[:, 1:])
        rods: dict[int, FloatArray] = {}
        for key, path in rod_files.items():
            table = read_output(path)
            cols = [f"End{e}{a}(m)" for e in "AB" for a in "XYZ"]
            data = np.column_stack([table.column(c) for c in cols]).reshape(-1, 2, 3)
            rods[key] = on_times(_time_column(table), data)
        points: dict[int, FloatArray] = {}
        bodies: dict[int, FloatArray] = {}
        if main is not None:
            mt = _time_column(main)
            for pid in _object_ids(main.channels, r"Point(\d+)p[xyz]"):
                pcols = [main.column(f"Point{pid}p{a}") for a in "xyz"]
                points[pid] = on_times(mt, np.column_stack(pcols))
            for bid in _object_ids(main.channels, r"Body(\d+)P[xyz]"):
                names = [f"Body{bid}P{a}" for a in "xyz"] + [f"Body{bid}R{a}" for a in "xyz"]
                bcols = [main.column(n) if n in main.channels else np.zeros(mt.size) for n in names]
                bodies[bid] = on_times(mt, np.column_stack(bcols))
        seabed = seabed_from_deck(deck) if deck is not None else None
        water = WaterSurface.from_deck(deck) if deck is not None else None
        return cls(
            times=times,
            lines=line_xyz,
            tensions=tensions,
            points=points,
            bodies=bodies,
            rods=rods,
            seabed=seabed,
            water=water,
        )

    @classmethod
    def from_static(
        cls, path: str | os.PathLike[str], *, deck: str | os.PathLike[str] | None = None
    ) -> Snapshots:
        """One frame (time 0) from a ``.static.out`` profile of every line."""
        table = read_output(path)
        if not isinstance(table, StaticProfile):
            raise OutputFormatError(f"{path}: not a static line profile")
        ids = table.column("LineID").astype(int)
        xyz = np.column_stack([table.column(c) for c in ("X", "Y", "Z")])
        lines = {int(k): xyz[ids == k][np.newaxis] for k in np.unique(ids)}
        seabed = seabed_from_deck(deck) if deck is not None else None
        water = WaterSurface.from_deck(deck) if deck is not None else None
        return cls(times=np.zeros(1), lines=lines, seabed=seabed, water=water)


def _time_column(table: OutputTable) -> FloatArray:
    for name in table.channels:
        if name.lower() in {"time", "time(s)"}:
            return np.asarray(table.column(name), dtype=np.float64)
    raise OutputFormatError(f"{table.path}: no time column")


def _numbered(base: Path, kind: str, flag: str) -> dict[int, Path]:
    pattern = re.compile(rf"^{re.escape(base.name)}\.{kind}([1-9][0-9]*)\.{flag}\.out$")
    found: dict[int, Path] = {}
    if base.parent.is_dir():
        for path in base.parent.iterdir():
            match = pattern.match(path.name)
            if match:
                found[int(match.group(1))] = path
    return dict(sorted(found.items()))


def _object_ids(channels: tuple[str, ...], pattern: str) -> list[int]:
    ids: set[int] = set()
    regex = re.compile(pattern, flags=re.IGNORECASE)
    for name in channels:
        match = regex.fullmatch(name)
        if match:
            ids.add(int(match.group(1)))
    return sorted(ids)


class Recorder:
    """Sample an in-process model into :class:`Snapshots`.

    Call :meth:`sample` whenever the model holds a state to keep (for example
    after every ``N``-th :meth:`~cabledyn.CableDyn.step`), then
    :meth:`snapshots`. Positions are copied into preallocated rows, so the
    per-sample cost is the object queries alone.

    Parameters
    ----------
    model : CableDyn
        An initialized model.
    tensions : bool
        Also record every line's segment tensions.
    """

    def __init__(self, model: CableDyn, *, tensions: bool = True) -> None:
        self._model = model
        self._tensions = tensions
        self._times: list[float] = []
        self._lines: dict[int, list[FloatArray]] = {line.id: [] for line in model.lines}
        self._ten: dict[int, list[FloatArray]] = (
            {line.id: [] for line in model.lines} if tensions else {}
        )
        self._points: dict[int, list[FloatArray]] = {p.id: [] for p in model.points}
        self._bodies: dict[int, list[FloatArray]] = {b.id: [] for b in model.bodies}
        self._rods: dict[int, list[FloatArray]] = {r.id: [] for r in model.rods}

    def __len__(self) -> int:
        return len(self._times)

    def sample(self) -> None:
        """Record the model's current state at its current time."""
        model = self._model
        time = model.time
        if self._times and time <= self._times[-1]:
            raise ValueError(f"sample time {time} does not advance past {self._times[-1]}")
        for line in model.lines:
            self._lines[line.id].append(line.node_positions())
            if self._tensions:
                self._ten[line.id].append(line.segment_tensions())
        for point in model.points:
            self._points[point.id].append(point.position())
        for body in model.bodies:
            self._bodies[body.id].append(body.pose())
        for rod in model.rods:
            self._rods[rod.id].append(rod.node_positions())
        self._times.append(time)

    def snapshots(self) -> Snapshots:
        """The recorded samples, with the deck's seabed and water surface."""
        if not self._times:
            raise ValueError("no samples recorded")
        deck = self._model.deck
        return Snapshots(
            times=np.array(self._times),
            lines={k: np.stack(v) for k, v in self._lines.items()},
            tensions={k: np.stack(v) for k, v in self._ten.items()},
            points={k: np.stack(v) for k, v in self._points.items()},
            bodies={k: np.stack(v) for k, v in self._bodies.items()},
            rods={k: np.stack(v) for k, v in self._rods.items()},
            seabed=seabed_from_deck(deck) if deck is not None else None,
            water=WaterSurface.from_deck(deck) if deck is not None else None,
        )


Motion = Callable[[float], tuple[npt.ArrayLike, npt.ArrayLike, npt.ArrayLike]]


def record(
    model: CableDyn,
    dt: float,
    n_steps: int,
    *,
    every: int = 1,
    motion: Motion | None = None,
    tensions: bool = True,
) -> Snapshots:
    """Step ``model`` ``n_steps`` times and record every ``every``-th state.

    The initial state is always recorded. ``motion(t)`` returns the coupled
    kinematics ``(q, v, a)`` at time ``t`` (see
    :meth:`~cabledyn.CableDyn.step`); without it the coupled points are
    held (:meth:`~cabledyn.CableDyn.step_held`).
    """
    if isinstance(every, bool) or not isinstance(every, int) or every < 1:
        raise ValueError("every must be a positive integer")
    if isinstance(n_steps, bool) or not isinstance(n_steps, int) or n_steps < 0:
        raise ValueError("n_steps must be a non-negative integer")
    recorder = Recorder(model, tensions=tensions)
    recorder.sample()
    for step in range(1, n_steps + 1):
        if motion is None:
            model.step_held(dt)
        else:
            q, v, a = motion(model.time + dt)
            model.step(dt, q, v, a)
        if step % every == 0:
            recorder.sample()
    return recorder.snapshots()


def animate(
    snapshots: Snapshots,
    *,
    ax: Any = None,
    interval: float = 50.0,
    stride: int = 1,
    seabed: bool = True,
    water: bool = True,
    grid: int = 20,
) -> Any:
    """Play the snapshots in a Matplotlib 3D axes; returns the ``FuncAnimation``.

    Lines and rods are drawn as polylines, points as dots and bodies as
    their reference points. The seabed and the water surface are drawn when
    known (the water surface moves with a regular Airy wave). Save the result
    with ``anim.save("run.gif")`` or show it with ``matplotlib.pyplot.show()``.

    Parameters
    ----------
    snapshots : Snapshots
        The geometry to play.
    ax : mpl_toolkits.mplot3d.Axes3D, optional
        Target axes; a new figure is created when omitted.
    interval : float
        Delay between frames [ms].
    stride : int
        Play every ``stride``-th sample.
    seabed, water : bool
        Draw the seabed and the water surface.
    grid : int
        Resolution of the seabed and water surface meshes.
    """
    from cabledyn._optional import pyplot

    plt = pyplot()
    from matplotlib.animation import FuncAnimation

    if isinstance(stride, bool) or not isinstance(stride, int) or stride < 1:
        raise ValueError("stride must be a positive integer")
    if ax is None:
        fig = plt.figure()
        ax = fig.add_subplot(projection="3d")
    fig = ax.figure
    lo, hi = snapshots.bounds()
    pad = 0.05 * float(np.max(hi - lo) or 1.0)
    xr = (float(lo[0] - pad), float(hi[0] + pad))
    yr = (float(lo[1] - pad), float(hi[1] + pad))
    zlo, zhi = float(lo[2] - pad), float(max(hi[2], 0.0) + pad)
    if seabed and snapshots.seabed is not None:
        gx, gy, gz = snapshots.seabed.grid(xr, yr, grid)
        ax.plot_surface(gx, gy, gz, color="tan", alpha=0.3, linewidth=0)
        zlo = min(zlo, float(gz.min()))
    water_art: list[Any] = []
    wx, wy = np.meshgrid(np.linspace(*xr, grid), np.linspace(*yr, grid), indexing="ij")
    draw_water = water and snapshots.water is not None

    def draw_surface(time: float) -> None:
        for art in water_art:
            art.remove()
        water_art.clear()
        assert snapshots.water is not None
        wz = snapshots.water.elevation(time, wx, wy)
        water_art.append(ax.plot_surface(wx, wy, wz, color="tab:blue", alpha=0.15, linewidth=0))

    if draw_water:
        draw_surface(float(snapshots.times[0]))
    ax.set_xlim(*xr)
    ax.set_ylim(*yr)
    ax.set_zlim(zlo, zhi)
    ax.set_xlabel("X (m)")
    ax.set_ylabel("Y (m)")
    ax.set_zlabel("Z (m)")
    line_art = {k: ax.plot(*v[0].T, lw=1.5)[0] for k, v in snapshots.lines.items()}
    rod_art = {k: ax.plot(*v[0].T, lw=4.0, color="dimgray")[0] for k, v in snapshots.rods.items()}
    pts = [snapshots.points[k] for k in snapshots.points] + [
        snapshots.bodies[k][:, :3] for k in snapshots.bodies
    ]
    point_art = ax.plot([], [], [], "o", ms=4, color="black")[0] if pts else None
    title = ax.set_title("")
    frames = list(range(0, snapshots.n_frames, stride))

    def update(index: int) -> list[Any]:
        for k, art in line_art.items():
            xyz = snapshots.lines[k][index]
            art.set_data_3d(xyz[:, 0], xyz[:, 1], xyz[:, 2])
        for k, art in rod_art.items():
            xyz = snapshots.rods[k][index]
            art.set_data_3d(xyz[:, 0], xyz[:, 1], xyz[:, 2])
        if point_art is not None:
            xyz = np.array([p[index] for p in pts])
            point_art.set_data_3d(xyz[:, 0], xyz[:, 1], xyz[:, 2])
        time = float(snapshots.times[index])
        if draw_water and snapshots.water is not None and not snapshots.water.still:
            draw_surface(time)
        title.set_text(f"t = {time:.2f} s")
        return [*line_art.values(), *rod_art.values(), title]

    update(0)
    return FuncAnimation(fig, update, frames=frames, interval=interval, blit=False)
