# SPDX-License-Identifier: Apache-2.0
"""Palmgren-Miner fatigue damage, cable stress recovery, and lifetime weighting.

* :func:`miner_damage` sums ``n_i / N(S_i)`` over rainflow cycles for a
  :class:`~cabledyn.FatigueCurve`, with an optional Goodman mean-stress
  correction (off by default).
* :func:`channel_damage` does the same for one channel of a time history.
* :func:`cable_stress` recovers the axial stress at the two extreme fibres of
  a cable, ``sigma = T/A +/- E kappa r``.
* :func:`damage_along_arc` evaluates the damage at every output node of a
  line, from tension or from recovered stress.
* :func:`study_sea_state_damage` and :func:`lifetime_fatigue` weight the
  short-term damage of each sea state of a :func:`cabledyn.run_study` batch
  by its probability of occurrence to give the annual damage, the damage
  over the design life, and the fatigue life.

The damage calculations are deterministic post-processing of the recorded
histories: they take the counted cycles as given and apply no design fatigue
factor unless one is passed.
"""

from __future__ import annotations

import math
import os
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn._optional import pyplot
from cabledyn.curves import FatigueCurve
from cabledyn.errors import StudyOutputError
from cabledyn.fatigue import RainflowCycle, rainflow_cycles
from cabledyn.ranges import ArcSource, node_channels, node_locations, node_matrix
from cabledyn.results import TimeHistory, read_output
from cabledyn.study import StudyResult

__all__ = [
    "ChannelDamage",
    "DamageProfile",
    "LifetimeFatigue",
    "SeaStateDamage",
    "cable_stress",
    "channel_damage",
    "damage_along_arc",
    "lifetime_fatigue",
    "miner_damage",
    "study_sea_state_damage",
]

SECONDS_PER_YEAR = 365.25 * 24.0 * 3600.0


def _positive(value: float, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be finite and positive")
    number = float(value)
    if not math.isfinite(number) or number <= 0.0:
        raise ValueError(f"{name} must be finite and positive")
    return number


def _readonly(values: npt.ArrayLike) -> npt.NDArray[Any]:
    result = np.array(values, dtype=np.float64, copy=True)
    result.setflags(write=False)
    return result


def miner_damage(
    cycles: Iterable[RainflowCycle],
    curve: FatigueCurve,
    *,
    scale: float = 1.0,
    ultimate_strength: float | None = None,
) -> float:
    """Return the Palmgren-Miner damage ``sum(n_i / N(S_i))`` of rainflow cycles.

    Each cycle range and mean is multiplied by ``scale`` to express it in the
    curve unit. With ``ultimate_strength`` (in the curve unit) the Goodman
    correction ``S_eq = S / (1 - S_mean / S_u)`` is applied to every cycle
    with a tensile mean; compressive means are left uncorrected.

    Parameters
    ----------
    cycles : collections.abc.Iterable[RainflowCycle]
        Counted cycles, typically from :func:`cabledyn.rainflow_cycles`.
    curve : FatigueCurve
        S-N or T-N curve.
    scale : float
        Positive factor from the history unit to the curve unit, for example
        :meth:`FatigueCurve.tension_scale`.
    ultimate_strength : float | None
        Ultimate strength for the Goodman correction, in the curve unit;
        ``None`` (the default) applies no correction.

    Returns
    -------
    float
        The damage; ``0.0`` for no cycles.

    Raises
    ------
    ValueError
        If ``scale`` or ``ultimate_strength`` is not finite and positive, the
        cycles are not :class:`~cabledyn.RainflowCycle` values, or a cycle
        mean reaches the ultimate strength.
    """
    factor = _positive(scale, "scale")
    selected = tuple(cycles)
    if not all(isinstance(cycle, RainflowCycle) for cycle in selected):
        raise ValueError("cycles must contain RainflowCycle values")
    if not selected:
        return 0.0
    ranges = np.asarray([cycle.range for cycle in selected]) * factor
    counts = np.asarray([cycle.count for cycle in selected])
    if ultimate_strength is not None:
        limit = _positive(ultimate_strength, "ultimate_strength")
        means = np.maximum(np.asarray([cycle.mean for cycle in selected]) * factor, 0.0)
        if np.any(means >= limit):
            raise ValueError("a cycle mean reaches the ultimate strength; Goodman is undefined")
        ranges = ranges / (1.0 - means / limit)
    return float(math.fsum(counts / curve.cycles_to_failure(ranges)))


@dataclass(frozen=True)
class ChannelDamage:
    """Palmgren-Miner damage of one channel over one record.

    Attributes
    ----------
    channel : str
        Analysed channel.
    source : pathlib.Path
        Result file of the channel.
    curve : FatigueCurve
        Curve used.
    scale : float
        Factor applied to the channel to express it in the curve unit.
    goodman : bool
        Whether the Goodman correction was applied.
    duration : float
        Length of the analysed record, in seconds.
    cycle_count : float
        Sum of the rainflow cycle weights.
    damage : float
        Miner damage accumulated over ``duration``.
    """

    channel: str
    source: Path
    curve: FatigueCurve
    scale: float
    goodman: bool
    duration: float
    cycle_count: float
    damage: float

    @property
    def damage_rate(self) -> float:
        """Damage per year of exposure to this record, ``damage * year / duration``."""
        return self.damage * SECONDS_PER_YEAR / self.duration

    @property
    def fatigue_life(self) -> float:
        """Years to a damage of one at :attr:`damage_rate`; ``inf`` for no damage."""
        rate = self.damage_rate
        return 1.0 / rate if rate > 0.0 else math.inf


def _window(history: TimeHistory, start: float | None, stop: float | None) -> TimeHistory:
    view = history.period(start, stop) if start is not None or stop is not None else history
    if view.time.size < 2:
        raise ValueError("damage analysis needs at least two time samples")
    return view


def channel_damage(
    history: TimeHistory,
    channel: str,
    curve: FatigueCurve,
    *,
    scale: float = 1.0,
    ultimate_strength: float | None = None,
    start: float | None = None,
    stop: float | None = None,
) -> ChannelDamage:
    """Return the rainflow Palmgren-Miner damage of one channel.

    Parameters
    ----------
    history : TimeHistory
        Record to analyse.
    channel : str
        Non-time channel, for example ``"FairTen1"``.
    curve : FatigueCurve
        S-N or T-N curve.
    scale : float
        Factor from the channel unit to the curve unit; for a tension channel
        use :meth:`FatigueCurve.tension_scale`.
    ultimate_strength : float | None
        Enables the Goodman correction (see :func:`miner_damage`).
    start, stop : float | None
        Optional analysis window, in seconds.

    Returns
    -------
    ChannelDamage
        The damage and the settings that produced it.

    Raises
    ------
    KeyError
        If the table has no channel of that name.
    ValueError
        If ``channel`` is the time channel, fewer than two samples are
        selected, or a setting is invalid.
    """
    if channel == history.time_channel:
        raise ValueError("damage analysis needs a non-time channel")
    view = _window(history, start, stop)
    cycles = rainflow_cycles(view.column(channel))
    factor = _positive(scale, "scale")
    damage = miner_damage(cycles, curve, scale=factor, ultimate_strength=ultimate_strength)
    return ChannelDamage(
        channel=channel,
        source=view.path,
        curve=curve,
        scale=factor,
        goodman=ultimate_strength is not None,
        duration=float(view.time[-1] - view.time[0]),
        cycle_count=float(math.fsum(cycle.count for cycle in cycles)),
        damage=damage,
    )


def cable_stress(
    tension: npt.ArrayLike,
    curvature: npt.ArrayLike,
    *,
    area: float,
    modulus: float,
    radius: float,
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Return the axial stress at the outer and inner fibre, ``T/A +/- E kappa r``.

    This is the usual two-fibre recovery for a cable component (an armour
    wire or a conductor) at distance ``radius`` from the neutral axis. The
    solver's curvature is a magnitude, so the bending stress is applied at the
    fibre on the outside (``+``) and the inside (``-``) of the bend; the
    rotation of the bending plane is not tracked.

    Parameters
    ----------
    tension : array_like
        Effective tension, in newtons.
    curvature : array_like
        Curvature magnitude, in 1/m, broadcastable against ``tension``.
    area : float
        Positive area that carries the tension, in m^2.
    modulus : float
        Positive Young's modulus of the component, in Pa.
    radius : float
        Non-negative distance of the fibre from the neutral axis, in metres.

    Returns
    -------
    tuple[numpy.ndarray, numpy.ndarray]
        Read-only outer-fibre and inner-fibre stress, in Pa.

    Raises
    ------
    ValueError
        If a section property is invalid or a value is not finite.
    """
    section = _positive(area, "area")
    elastic = _positive(modulus, "modulus")
    if isinstance(radius, bool) or not math.isfinite(float(radius)) or float(radius) < 0.0:
        raise ValueError("radius must be finite and non-negative")
    axial = np.asarray(tension, dtype=np.float64) / section
    bending = elastic * np.asarray(curvature, dtype=np.float64) * float(radius)
    if not np.all(np.isfinite(axial)) or not np.all(np.isfinite(bending)):
        raise ValueError("tension and curvature must be finite")
    return _readonly(axial + bending), _readonly(axial - bending)


@dataclass(frozen=True)
class DamageProfile:
    """Palmgren-Miner damage at every output node of one line.

    Attributes
    ----------
    line_id : int
        Deck line identifier.
    quantity : str
        ``"tension"`` or ``"stress"``.
    curve : FatigueCurve
        Curve used.
    node_ids : tuple[int, ...]
        Output nodes, in End-A-to-End-B order.
    location_kind : str
        ``"ArcLength"`` or ``"Node"``.
    location : numpy.ndarray
        ``(n,)`` arc length in metres, or node number.
    damage : numpy.ndarray
        ``(n,)`` damage over the record; for ``"stress"`` the larger of the
        two fibres.
    duration : float
        Length of the analysed record, in seconds.
    source : pathlib.Path
        Result file.
    """

    line_id: int
    quantity: str
    curve: FatigueCurve
    node_ids: tuple[int, ...]
    location_kind: str
    location: npt.NDArray[Any]
    damage: npt.NDArray[Any]
    duration: float
    source: Path

    def __post_init__(self) -> None:
        object.__setattr__(self, "location", _readonly(self.location))
        object.__setattr__(self, "damage", _readonly(self.damage))

    @property
    def critical_node(self) -> int:
        """Node with the largest damage."""
        return self.node_ids[int(np.argmax(self.damage))]

    @property
    def maximum_damage(self) -> float:
        """Largest damage on the line."""
        return float(np.max(self.damage))

    def plot(self, *, ax: Any = None) -> Any:
        """Plot damage against location on a logarithmic axis.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        ax.semilogy(self.location, self.damage, marker="o")
        ax.set_xlabel("Arc length [m]" if self.location_kind == "ArcLength" else "Node [-]")
        ax.set_ylabel("Damage [-]")
        ax.grid(True, which="both")
        return ax


def damage_along_arc(
    history: TimeHistory,
    line_id: int,
    curve: FatigueCurve,
    *,
    quantity: str = "tension",
    area: float | None = None,
    breaking_strength: float | None = None,
    modulus: float | None = None,
    radius: float | None = None,
    ultimate_strength: float | None = None,
    arc_length: ArcSource = None,
    start: float | None = None,
    stop: float | None = None,
) -> DamageProfile:
    """Return the Miner damage at every output node of a line.

    With ``quantity="tension"`` the ``Ten<L>N<J>`` channels are counted:
    an S-N curve needs the nominal ``area`` and a T-N curve the reference
    ``breaking_strength`` (see :meth:`FatigueCurve.tension_scale`).

    With ``quantity="stress"`` the stress at the two extreme fibres is
    recovered from ``Ten<L>N<J>`` and ``Curv<L>N<J>`` by :func:`cable_stress`
    (``area``, ``modulus``, and ``radius`` are required, and the curve must be
    S-N); each fibre is counted separately and the larger damage is kept.
    Both channels must be written for the same nodes.

    Parameters
    ----------
    history : TimeHistory
        Main output with the node channels.
    line_id : int
        Deck line identifier.
    curve : FatigueCurve
        S-N or T-N curve.
    quantity : str
        ``"tension"`` or ``"stress"``.
    area, breaking_strength, modulus, radius : float | None
        Section properties, in SI units, as described above.
    ultimate_strength : float | None
        Enables the Goodman correction, in the curve unit.
    arc_length : StaticProfile | collections.abc.Mapping[int, float] | None
        Node positions along the line (see :func:`cabledyn.node_range_graph`).
    start, stop : float | None
        Optional analysis window, in seconds.

    Returns
    -------
    DamageProfile
        Damage at each output node.

    Raises
    ------
    KeyError
        If the needed node channels are missing.
    ValueError
        If ``quantity`` is unknown, a section property is missing or invalid,
        or the tension and curvature channels cover different nodes.
    """
    view = _window(history, start, stop)
    tensions = node_channels(view, line_id, "Ten")
    data = node_matrix(view, tensions)
    if quantity == "tension":
        scale = curve.tension_scale(area=area, breaking_strength=breaking_strength)
        histories = [data]
    elif quantity == "stress":
        if curve.kind != "S-N":
            raise ValueError("stress-based damage needs an S-N curve")
        if area is None or modulus is None or radius is None or breaking_strength is not None:
            raise ValueError("stress-based damage needs area, modulus, and radius only")
        curvatures = node_channels(view, line_id, "Curv")
        if tuple(curvatures) != tuple(tensions):
            raise ValueError("Ten and Curv channels must be written for the same nodes")
        outer, inner = cable_stress(
            data, node_matrix(view, curvatures), area=area, modulus=modulus, radius=radius
        )
        scale = 1.0e-6
        histories = [outer, inner]
    else:
        raise ValueError("quantity must be 'tension' or 'stress'")
    damage = np.zeros(data.shape[1])
    for series in histories:
        for index in range(data.shape[1]):
            value = miner_damage(
                rainflow_cycles(series[:, index]),
                curve,
                scale=scale,
                ultimate_strength=ultimate_strength,
            )
            damage[index] = max(damage[index], value)
    node_ids = tuple(tensions)
    kind, location = node_locations(int(line_id), node_ids, arc_length)
    return DamageProfile(
        line_id=int(line_id),
        quantity=quantity,
        curve=curve,
        node_ids=node_ids,
        location_kind=kind,
        location=location,
        damage=damage,
        duration=float(view.time[-1] - view.time[0]),
        source=view.path,
    )


@dataclass(frozen=True)
class SeaStateDamage:
    """Short-term damage of one sea state and its probability of occurrence.

    Attributes
    ----------
    name : str
        Sea-state (case) name.
    probability : float
        Fraction of the design life spent in this sea state, in ``(0, 1]``.
    duration : float
        Length of the simulated record that produced ``damage``, in seconds.
    damage : numpy.ndarray
        Read-only ``(n,)`` damage over ``duration``: one value for a single
        channel, or one per location for a :class:`DamageProfile`.

    Raises
    ------
    ValueError
        If the name is empty, a value is out of range or not finite, or the
        damage is not a non-empty one-dimensional non-negative array.
    """

    name: str
    probability: float
    duration: float
    damage: npt.NDArray[Any]

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name:
            raise ValueError("name must be a non-empty string")
        probability = _positive(self.probability, "probability")
        if probability > 1.0:
            raise ValueError("probability must lie in (0, 1]")
        object.__setattr__(self, "probability", probability)
        object.__setattr__(self, "duration", _positive(self.duration, "duration"))
        damage = _readonly(np.atleast_1d(np.asarray(self.damage, dtype=np.float64)))
        if damage.ndim != 1 or damage.size == 0 or not np.all(np.isfinite(damage)):
            raise ValueError("damage must be a non-empty finite one-dimensional array")
        if np.any(damage < 0.0):
            raise ValueError("damage must be non-negative")
        object.__setattr__(self, "damage", damage)

    @property
    def annual_damage(self) -> npt.NDArray[Any]:
        """The read-only damage contribution per year, ``p * damage * year / duration``."""
        return _readonly(self.probability * self.damage * SECONDS_PER_YEAR / self.duration)


@dataclass(frozen=True)
class LifetimeFatigue:
    """Probability-weighted fatigue over a design life.

    Arrays are read-only with one value per location (one for a single
    channel).

    Attributes
    ----------
    states : tuple[SeaStateDamage, ...]
        The weighted sea states.
    design_life : float
        Design life, in years.
    design_factor : float
        Design fatigue factor applied to the damage.
    annual_damage : numpy.ndarray
        Factored damage per year, summed over the sea states.
    lifetime_damage : numpy.ndarray
        ``annual_damage * design_life``; fatigue fails where it exceeds one.
    fatigue_life : numpy.ndarray
        ``1 / annual_damage``, in years (``inf`` where there is no damage).
    """

    states: tuple[SeaStateDamage, ...]
    design_life: float
    design_factor: float
    annual_damage: npt.NDArray[Any]
    lifetime_damage: npt.NDArray[Any]
    fatigue_life: npt.NDArray[Any]

    @property
    def total_probability(self) -> float:
        """Sum of the sea-state probabilities."""
        return float(math.fsum(state.probability for state in self.states))

    @property
    def critical_index(self) -> int:
        """Location index with the largest lifetime damage."""
        return int(np.argmax(self.lifetime_damage))

    @property
    def maximum_lifetime_damage(self) -> float:
        """Largest lifetime damage."""
        return float(np.max(self.lifetime_damage))

    @property
    def minimum_fatigue_life(self) -> float:
        """Shortest fatigue life, in years."""
        return float(np.min(self.fatigue_life))

    @property
    def passed(self) -> bool:
        """Whether the lifetime damage is at most one everywhere."""
        return self.maximum_lifetime_damage <= 1.0

    def contributions(self) -> dict[str, npt.NDArray[Any]]:
        """Return each sea state's share of the factored annual damage.

        Returns
        -------
        dict[str, numpy.ndarray]
            Read-only factored annual damage per sea state, by name.
        """
        return {
            state.name: _readonly(state.annual_damage * self.design_factor) for state in self.states
        }

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the per-sea-state contributions as CSV.

        One row per sea state and location index, with its probability,
        record duration, short-term damage, and factored annual damage.

        Parameters
        ----------
        path : str | os.PathLike
            Target CSV file; missing parent directories are created.
        overwrite : bool
            Replace an existing file instead of raising :class:`FileExistsError`.

        Returns
        -------
        pathlib.Path
            Absolute path of the written file.

        Raises
        ------
        FileExistsError
            If ``path`` exists and ``overwrite`` is false.
        """
        rows = (
            (
                state.name,
                index,
                number(state.probability),
                number(state.duration),
                number(state.damage[index]),
                number(state.annual_damage[index] * self.design_factor),
            )
            for state in self.states
            for index in range(state.damage.size)
        )
        return write_csv(
            path,
            (
                "SeaState",
                "Location_[-]",
                "Probability_[-]",
                "Duration_[s]",
                "Damage_[-]",
                "AnnualDamage_[1/yr]",
            ),
            rows,
            overwrite=overwrite,
        )


def lifetime_fatigue(
    states: Iterable[SeaStateDamage],
    *,
    design_life: float,
    design_factor: float = 1.0,
) -> LifetimeFatigue:
    """Combine sea-state damage into annual and lifetime damage.

    ``annual = DFF * sum(p_i * D_i * year / T_i)`` over sea states with
    probability ``p_i``, short-term damage ``D_i`` over a record of ``T_i``
    seconds, and design fatigue factor ``DFF``; the lifetime damage is
    ``annual * design_life`` and the fatigue life ``1 / annual`` years. A year
    is 365.25 days. The probabilities may sum to less than one (sea states that
    do no damage may be left out) but not to more.

    Parameters
    ----------
    states : collections.abc.Iterable[SeaStateDamage]
        Sea states with unique names and damage arrays of one shape.
    design_life : float
        Positive design life, in years.
    design_factor : float
        Positive design fatigue factor that multiplies the damage; ``1.0``
        by default. Take its value from the governing standard.

    Returns
    -------
    LifetimeFatigue
        Annual damage, lifetime damage, and fatigue life per location.

    Raises
    ------
    ValueError
        If there are no states, a name repeats, the damage shapes differ, the
        probabilities sum to more than one, or a setting is invalid.
    """
    selected = tuple(states)
    if not selected or not all(isinstance(state, SeaStateDamage) for state in selected):
        raise ValueError("states must be a non-empty sequence of SeaStateDamage values")
    names = [state.name for state in selected]
    if len(set(names)) != len(names):
        raise ValueError("sea-state names must be unique")
    if len({state.damage.shape for state in selected}) != 1:
        raise ValueError("every sea state must have damage of the same shape")
    if math.fsum(state.probability for state in selected) > 1.0 + 1.0e-9:
        raise ValueError("sea-state probabilities must not sum to more than one")
    life = _positive(design_life, "design_life")
    factor = _positive(design_factor, "design_factor")
    annual = factor * np.sum([state.annual_damage for state in selected], axis=0)
    with np.errstate(divide="ignore"):
        fatigue_life = np.where(annual > 0.0, 1.0 / annual, np.inf)
    return LifetimeFatigue(
        states=selected,
        design_life=life,
        design_factor=factor,
        annual_damage=_readonly(annual),
        lifetime_damage=_readonly(annual * life),
        fatigue_life=_readonly(fatigue_life),
    )


def study_sea_state_damage(
    study: StudyResult,
    probabilities: Mapping[str, float],
    evaluate: Callable[[TimeHistory], float | ChannelDamage | DamageProfile | npt.ArrayLike],
    *,
    start: float | None = None,
    stop: float | None = None,
) -> tuple[SeaStateDamage, ...]:
    """Evaluate the short-term damage of each sea state of a batch study.

    Each case named in ``probabilities`` must have completed. Its main output
    is read, trimmed to ``[start, stop]`` (for example to drop the start-up
    transient), and passed to ``evaluate``, which returns the damage over that
    record: a number, an array, a :class:`ChannelDamage`, or a
    :class:`DamageProfile`. The duration is that of the returned result, or
    the trimmed record length for a plain number or array.

    Parameters
    ----------
    study : StudyResult
        Result of :func:`cabledyn.run_study`.
    probabilities : collections.abc.Mapping[str, float]
        Probability of occurrence of each case, by case name.
    evaluate : collections.abc.Callable
        Damage of one trimmed record, for example
        ``lambda h: channel_damage(h, "FairTen1", curve, scale=s)``.
    start, stop : float | None
        Optional analysis window applied to every case, in seconds.

    Returns
    -------
    tuple[SeaStateDamage, ...]
        One entry per named case, in study order; pass them to
        :func:`lifetime_fatigue`.

    Raises
    ------
    KeyError
        If a named case is not in the study.
    StudyOutputError
        If a named case did not complete or has no main output.
    ValueError
        If ``probabilities`` is empty or a probability is invalid.
    """
    if not probabilities:
        raise ValueError("probabilities must name at least one case")
    cases = {case.name: case for case in study.cases}
    unknown = sorted(set(probabilities) - set(cases))
    if unknown:
        raise KeyError(f"cases not in the study: {unknown}")
    result: list[SeaStateDamage] = []
    for case in study.cases:
        if case.name not in probabilities:
            continue
        if case.status != "completed" or case.main_output is None:
            raise StudyOutputError(f"case {case.name!r} did not complete; it has no damage")
        table = read_output(case.main_output)
        if not isinstance(table, TimeHistory):
            raise StudyOutputError(f"{case.main_output} is not a time history")
        view = _window(table, start, stop)
        value = evaluate(view)
        duration = float(view.time[-1] - view.time[0])
        if isinstance(value, (ChannelDamage, DamageProfile)):
            damage: npt.ArrayLike = value.damage
            duration = value.duration
        else:
            damage = value
        result.append(
            SeaStateDamage(
                name=case.name,
                probability=probabilities[case.name],
                duration=duration,
                damage=np.asarray(damage, dtype=np.float64),
            )
        )
    return tuple(result)
