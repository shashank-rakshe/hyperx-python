# SPDX-License-Identifier: Apache-2.0
"""Design checks: cable bend radius and line tension against breaking strength.

* :func:`bend_check` compares curvature with a cable's minimum bend radius
  (MBR), in the style of the DNV-ST-0359 bend-radius requirement for subsea
  power cables: ``utilisation = kappa * MBR``, which must not exceed one. The
  cable has separate MBRs for storage (no tension) and for dynamic service,
  held by :class:`BendLimits`; both come from the cable manufacturer.
* :func:`tension_check` compares the line tension with the minimum breaking
  load (MBL): with the API RP 2SK factors of safety for intact, damaged, and
  transient conditions, with the DNV-OS-E301 partial safety factors for the
  ULS (intact) and ALS (damaged) limit states, or with a user factor.

The checks use the recorded extremes of the analysed window. A design check
on the most probable maximum of a longer exposure needs that extreme first,
for example from :func:`cabledyn.fit_gumbel`.
"""

from __future__ import annotations

import math
import os
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn._optional import pyplot
from cabledyn.ranges import (
    ArcSource,
    element_range_graph,
    node_channels,
    node_locations,
    node_matrix,
    static_range_graph,
)
from cabledyn.results import OutputTable, StaticProfile, TimeHistory

__all__ = [
    "API_RP_2SK_SAFETY_FACTORS",
    "DNV_OS_E301_PARTIAL_FACTORS",
    "DNV_OS_E301_STRENGTH_FACTOR",
    "BendCheck",
    "BendLimits",
    "TensionCheck",
    "bend_check",
    "mbr_utilisation",
    "tension_check",
]

#: API RP 2SK, 3rd edition (2005), tension limits and factors of safety for
#: mooring lines: ``(condition, analysis) -> factor``. ``"damaged"`` is the
#: one-line-broken condition; ``"transient"`` the motion that follows a break.
API_RP_2SK_SAFETY_FACTORS: dict[tuple[str, str], float] = {
    ("intact", "quasi-static"): 2.00,
    ("intact", "dynamic"): 1.67,
    ("damaged", "quasi-static"): 1.43,
    ("damaged", "dynamic"): 1.25,
    ("transient", "quasi-static"): 1.18,
    ("transient", "dynamic"): 1.05,
}

#: DNV-OS-E301 *Position mooring*, Ch.2 Sec.2, partial safety factors on the
#: mean and dynamic tension, ``(limit state, consequence class) ->
#: (gamma_mean, gamma_dyn)``: ULS for the intact system, ALS for one failed
#: line.
DNV_OS_E301_PARTIAL_FACTORS: dict[tuple[str, int], tuple[float, float]] = {
    ("ULS", 1): (1.10, 1.50),
    ("ULS", 2): (1.40, 2.10),
    ("ALS", 1): (1.00, 1.10),
    ("ALS", 2): (1.00, 1.25),
}

#: DNV-OS-E301 characteristic strength of a new chain or steel-wire-rope line
#: body, ``S_C = 0.95 S_mbs`` (the default ``strength_factor`` of
#: :func:`tension_check`; other line bodies take the factor of their design basis).
DNV_OS_E301_STRENGTH_FACTOR = 0.95


def _positive(value: float, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be finite and positive")
    number_ = float(value)
    if not math.isfinite(number_) or number_ <= 0.0:
        raise ValueError(f"{name} must be finite and positive")
    return number_


def _readonly(values: npt.ArrayLike) -> npt.NDArray[Any]:
    result = np.array(values, dtype=np.float64, copy=True)
    result.setflags(write=False)
    return result


@dataclass(frozen=True)
class BendLimits:
    """Minimum bend radii of a cable, from its manufacturer.

    Attributes
    ----------
    storage_mbr : float
        MBR without tension (storage, handling, static lay), in metres.
    dynamic_mbr : float
        MBR in dynamic service, in metres; normally larger than the storage
        MBR.

    Raises
    ------
    ValueError
        If a radius is not finite and positive.
    """

    storage_mbr: float
    dynamic_mbr: float

    def __post_init__(self) -> None:
        object.__setattr__(self, "storage_mbr", _positive(self.storage_mbr, "storage_mbr"))
        object.__setattr__(self, "dynamic_mbr", _positive(self.dynamic_mbr, "dynamic_mbr"))

    def mbr(self, condition: str) -> float:
        """Return the MBR of ``"storage"`` or ``"dynamic"``.

        Raises
        ------
        ValueError
            If ``condition`` is neither.
        """
        if condition == "storage":
            return self.storage_mbr
        if condition == "dynamic":
            return self.dynamic_mbr
        raise ValueError("condition must be 'storage' or 'dynamic'")


def mbr_utilisation(curvature: npt.ArrayLike, mbr: float) -> npt.NDArray[Any]:
    """Return the bend utilisation ``|kappa| * MBR`` (at most one to pass).

    Parameters
    ----------
    curvature : array_like
        Curvature, in 1/m.
    mbr : float
        Positive minimum bend radius, in metres.

    Returns
    -------
    numpy.ndarray
        Read-only utilisation, of the shape of ``curvature``.

    Raises
    ------
    ValueError
        If ``mbr`` is invalid or a curvature is not finite.
    """
    radius = _positive(mbr, "mbr")
    values = np.asarray(curvature, dtype=np.float64)
    if not np.all(np.isfinite(values)):
        raise ValueError("curvature must be finite")
    return _readonly(np.abs(values) * radius)


@dataclass(frozen=True)
class BendCheck:
    """Bend-radius check of one line against one MBR.

    Attributes
    ----------
    line_id : int
        Deck line identifier.
    condition : str
        ``"storage"`` or ``"dynamic"``.
    mbr : float
        Minimum bend radius checked against, in metres.
    location_kind : str
        ``"ArcLength"`` (metres from End A) or ``"Node"``.
    location : numpy.ndarray
        ``(n,)`` checked locations.
    curvature : numpy.ndarray
        ``(n,)`` largest curvature magnitude at each location, in 1/m.
    utilisation : numpy.ndarray
        ``(n,)`` ``curvature * mbr``.
    critical_time : float | None
        Time of the governing curvature, in seconds; ``None`` for a static
        source.
    source : pathlib.Path
        Result file checked.
    """

    line_id: int
    condition: str
    mbr: float
    location_kind: str
    location: npt.NDArray[Any]
    curvature: npt.NDArray[Any]
    utilisation: npt.NDArray[Any]
    critical_time: float | None
    source: Path

    def __post_init__(self) -> None:
        for name in ("location", "curvature", "utilisation"):
            object.__setattr__(self, name, _readonly(getattr(self, name)))

    @property
    def maximum_utilisation(self) -> float:
        """Largest utilisation on the line."""
        return float(np.max(self.utilisation))

    @property
    def passed(self) -> bool:
        """Whether the utilisation is at most one everywhere."""
        return self.maximum_utilisation <= 1.0

    @property
    def critical_location(self) -> float:
        """Location of the largest utilisation."""
        return float(self.location[int(np.argmax(self.utilisation))])

    @property
    def minimum_radius(self) -> float:
        """Smallest bend radius, in metres (``inf`` for a straight line)."""
        largest = float(np.max(self.curvature))
        return 1.0 / largest if largest > 0.0 else math.inf

    def report(self) -> str:
        """Return a one-line pass/fail summary with the governing location and time."""
        where = (
            f"arc {self.critical_location:.3f} m"
            if self.location_kind == "ArcLength"
            else f"node {int(self.critical_location)}"
        )
        when = "" if self.critical_time is None else f" at t = {self.critical_time:g} s"
        verdict = "PASS" if self.passed else "FAIL"
        return (
            f"{verdict}: line {self.line_id} {self.condition} bend check, minimum radius "
            f"{self.minimum_radius:.4g} m vs MBR {self.mbr:.4g} m "
            f"(utilisation {self.maximum_utilisation:.3f}) at {where}{when}"
        )

    def plot(self, *, ax: Any = None) -> Any:
        """Plot utilisation along the line with the limit of one.

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
        ax.plot(self.location, self.utilisation, label=f"{self.condition} MBR {self.mbr:g} m")
        ax.axhline(1.0, color="k", linestyle="--", linewidth=1.0)
        ax.set_xlabel("Arc length [m]" if self.location_kind == "ArcLength" else "Node [-]")
        ax.set_ylabel("MBR utilisation [-]")
        ax.grid(True)
        ax.legend()
        return ax

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write location, curvature, radius, and utilisation as CSV.

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
        first = "ArcLength_[m]" if self.location_kind == "ArcLength" else "Node_[-]"
        rows = (
            (
                number(location),
                number(curvature),
                number(1.0 / curvature) if curvature > 0.0 else "inf",
                number(utilisation),
            )
            for location, curvature, utilisation in zip(
                self.location, self.curvature, self.utilisation, strict=True
            )
        )
        return write_csv(
            path,
            (first, "Curvature_[1/m]", "Radius_[m]", "Utilisation_[-]"),
            rows,
            overwrite=overwrite,
        )


def bend_check(
    source: TimeHistory | StaticProfile | OutputTable,
    limits: BendLimits | float,
    *,
    condition: str,
    line_id: int,
    arc_length: ArcSource = None,
    start: float | None = None,
    stop: float | None = None,
) -> BendCheck:
    """Check the curvature of one line against the storage or dynamic MBR.

    Sources:

    * a main output :class:`~cabledyn.TimeHistory` -- the ``Curv<L>N<J>``
      node channels, with the time of the governing curvature;
    * a :class:`~cabledyn.StaticProfile` -- its ``Curvature`` column;
    * a cubic-Hermite element table (``.elements.out``) -- the peak
      curvature of each element, found between the nodes.

    Parameters
    ----------
    source : TimeHistory | StaticProfile | OutputTable
        Result holding the curvature.
    limits : BendLimits | float
        The cable's MBRs, or one MBR in metres.
    condition : str
        ``"storage"`` or ``"dynamic"``: which MBR of ``limits`` applies, and
        the label of the report.
    line_id : int
        Deck line identifier.
    arc_length : StaticProfile | collections.abc.Mapping[int, float] | None
        Node positions for a time-history source (see
        :func:`cabledyn.node_range_graph`).
    start, stop : float | None
        Optional time window for a time-history source, in seconds.

    Returns
    -------
    BendCheck
        Utilisation along the line with the governing location and time.

    Raises
    ------
    KeyError
        If the line or its curvature is missing from ``source``.
    ValueError
        If ``condition`` or ``limits`` is invalid, or the window or time
        arguments do not apply to the source.
    """
    if condition not in {"storage", "dynamic"}:
        raise ValueError("condition must be 'storage' or 'dynamic'")
    mbr = limits.mbr(condition) if isinstance(limits, BendLimits) else _positive(limits, "mbr")
    identifier = int(line_id)
    critical_time: float | None = None
    if isinstance(source, TimeHistory):
        view = source.period(start, stop) if start is not None or stop is not None else source
        channels = node_channels(view, identifier, "Curv")
        data = np.abs(node_matrix(view, channels))
        kind, location = node_locations(identifier, tuple(channels), arc_length)
        curvature = np.max(data, axis=0)
        row = int(np.argmax(data[:, int(np.argmax(curvature))]))
        critical_time = float(view.time[row])
        path = view.path
    else:
        if start is not None or stop is not None or arc_length is not None:
            raise ValueError("start, stop, and arc_length apply only to a time history")
        graph = (
            static_range_graph(source, identifier, "curvature")
            if isinstance(source, StaticProfile)
            else element_range_graph(source, identifier, "curvature")
        )
        kind, location, curvature, path = (
            graph.location_kind,
            graph.location,
            np.abs(graph.maximum),
            graph.source,
        )
    return BendCheck(
        line_id=identifier,
        condition=condition,
        mbr=mbr,
        location_kind=kind,
        location=location,
        curvature=curvature,
        utilisation=mbr_utilisation(curvature, mbr),
        critical_time=critical_time,
        source=path,
    )


@dataclass(frozen=True)
class TensionCheck:
    """Tension check of the governing channel against the breaking strength.

    ``utilisation = design_tension / capacity``, which must not exceed one.

    Attributes
    ----------
    standard : str
        ``"API RP 2SK"``, ``"DNV-OS-E301"``, or ``"custom"``.
    condition : str
        ``"intact"``, ``"damaged"``, or ``"transient"``.
    channel : str
        Governing channel.
    time : float
        Time of its maximum tension, in seconds.
    maximum_tension : float
        Largest tension of the governing channel, in newtons.
    mean_tension : float
        Its mean tension over the window, in newtons.
    design_tension : float
        Factored demand, in newtons: the maximum tension for the
        factor-of-safety format, ``gamma_mean T_mean + gamma_dyn T_dyn`` for
        DNV-OS-E301.
    capacity : float
        Resistance, in newtons: ``MBL / factor of safety``, or
        ``0.95 MBS`` for DNV-OS-E301.
    utilisation : float
        ``design_tension / capacity``.
    factors : tuple[float, ...]
        The factor of safety, or ``(gamma_mean, gamma_dyn)``.
    """

    standard: str
    condition: str
    channel: str
    time: float
    maximum_tension: float
    mean_tension: float
    design_tension: float
    capacity: float
    utilisation: float
    factors: tuple[float, ...]

    @property
    def passed(self) -> bool:
        """Whether the utilisation is at most one."""
        return self.utilisation <= 1.0

    def report(self) -> str:
        """Return a one-line pass/fail summary."""
        verdict = "PASS" if self.passed else "FAIL"
        return (
            f"{verdict}: {self.standard} {self.condition} tension check, {self.channel} "
            f"max {self.maximum_tension:.6g} N at t = {self.time:g} s, design "
            f"{self.design_tension:.6g} N vs capacity {self.capacity:.6g} N "
            f"(utilisation {self.utilisation:.3f})"
        )


def tension_check(
    history: TimeHistory,
    channels: str | Sequence[str],
    *,
    breaking_strength: float,
    condition: str = "intact",
    standard: str = "API RP 2SK",
    analysis: str | None = None,
    consequence_class: int | None = None,
    safety_factor: float | None = None,
    strength_factor: float | None = None,
    start: float | None = None,
    stop: float | None = None,
) -> TensionCheck:
    """Check line tension against the minimum breaking load.

    ``standard`` selects the format:

    * ``"API RP 2SK"`` -- ``T_max <= MBL / SF`` with the factor of safety of
      :data:`API_RP_2SK_SAFETY_FACTORS` for ``condition`` (``"intact"``,
      ``"damaged"``, or ``"transient"``) and ``analysis`` (``"dynamic"`` or
      ``"quasi-static"``);
    * ``"DNV-OS-E301"`` -- ``gamma_mean T_mean + gamma_dyn T_dyn <= S_C`` with
      the partial factors of :data:`DNV_OS_E301_PARTIAL_FACTORS`: ULS for
      ``"intact"``, ALS for ``"damaged"``, in ``consequence_class`` 1 or 2.
      ``T_mean`` is the window mean and ``T_dyn = T_max - T_mean``. The
      characteristic strength is ``S_C = strength_factor MBS``; the default
      :data:`~cabledyn.DNV_OS_E301_STRENGTH_FACTOR` (0.95) is the standard's value for a
      new chain or steel-wire-rope line body, so give the factor of the design
      basis for other line bodies (fibre rope, cable);
    * ``"custom"`` -- ``T_max <= MBL / safety_factor``.

    The governing channel is the one with the largest utilisation. Run the
    check once on the intact and once on the damaged (one line removed)
    simulation.

    Parameters
    ----------
    history : TimeHistory
        Record holding the tension channels, in newtons.
    channels : str | collections.abc.Sequence[str]
        Tension channel(s) to check, for example ``"FairTen1"``.
    breaking_strength : float
        Minimum breaking load (MBL/MBS) of the line, in newtons.
    condition : str
        ``"intact"``, ``"damaged"``, or (API RP 2SK and custom only)
        ``"transient"``.
    standard : str
        ``"API RP 2SK"``, ``"DNV-OS-E301"``, or ``"custom"``.
    analysis : str | None
        API RP 2SK analysis method: ``"dynamic"`` (default) or
        ``"quasi-static"``; rejected for the other standards.
    consequence_class : int | None
        DNV-OS-E301 consequence class, 1 (default) or 2; rejected for the
        other standards.
    safety_factor : float | None
        Factor of safety; required for ``"custom"`` and rejected otherwise.
    strength_factor : float | None
        DNV-OS-E301 characteristic-strength factor ``S_C / MBS``, in
        ``(0, 1]``; default :data:`~cabledyn.DNV_OS_E301_STRENGTH_FACTOR`. Rejected for
        the other standards.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    TensionCheck
        The governing channel's check.

    Raises
    ------
    KeyError
        If a channel is missing.
    ValueError
        If a setting is invalid for the chosen standard, or no channel is
        given.
    """
    names = (channels,) if isinstance(channels, str) else tuple(channels)
    if not names:
        raise ValueError("give at least one tension channel")
    if history.time_channel in names:
        raise ValueError("the time channel is not a tension channel")
    strength = _positive(breaking_strength, "breaking_strength")
    if condition not in {"intact", "damaged", "transient"}:
        raise ValueError("condition must be 'intact', 'damaged', or 'transient'")
    if standard != "custom" and safety_factor is not None:
        raise ValueError("safety_factor applies only to standard='custom'")
    if standard != "API RP 2SK" and analysis is not None:
        raise ValueError("analysis applies only to standard='API RP 2SK'")
    if standard != "DNV-OS-E301" and consequence_class is not None:
        raise ValueError("consequence_class applies only to standard='DNV-OS-E301'")
    if standard != "DNV-OS-E301" and strength_factor is not None:
        raise ValueError("strength_factor applies only to standard='DNV-OS-E301'")
    factors: tuple[float, ...]
    reduction = DNV_OS_E301_STRENGTH_FACTOR
    if standard == "API RP 2SK":
        key = (condition, "dynamic" if analysis is None else analysis)
        if key not in API_RP_2SK_SAFETY_FACTORS:
            raise ValueError("analysis must be 'dynamic' or 'quasi-static'")
        factors = (API_RP_2SK_SAFETY_FACTORS[key],)
    elif standard == "DNV-OS-E301":
        if condition == "transient":
            raise ValueError("DNV-OS-E301 checks 'intact' (ULS) or 'damaged' (ALS)")
        limit_state = "ULS" if condition == "intact" else "ALS"
        cclass = 1 if consequence_class is None else consequence_class
        if (limit_state, cclass) not in DNV_OS_E301_PARTIAL_FACTORS:
            raise ValueError("consequence_class must be 1 or 2")
        factors = DNV_OS_E301_PARTIAL_FACTORS[(limit_state, cclass)]
        if strength_factor is not None:
            reduction = _positive(strength_factor, "strength_factor")
            if reduction > 1.0:
                raise ValueError("strength_factor must be in (0, 1]")
    elif standard == "custom":
        if safety_factor is None:
            raise ValueError("standard='custom' needs safety_factor")
        factors = (_positive(safety_factor, "safety_factor"),)
    else:
        raise ValueError("standard must be 'API RP 2SK', 'DNV-OS-E301', or 'custom'")
    view = history.period(start, stop) if start is not None or stop is not None else history
    best: TensionCheck | None = None
    for name in names:
        values = view.column(name)
        row = int(np.argmax(values))
        maximum, mean = float(values[row]), float(np.mean(values))
        if standard == "DNV-OS-E301":
            design = factors[0] * mean + factors[-1] * (maximum - mean)
            capacity = reduction * strength
        else:
            design, capacity = maximum, strength / factors[0]
        check = TensionCheck(
            standard=standard,
            condition=condition,
            channel=name,
            time=float(view.time[row]),
            maximum_tension=maximum,
            mean_tension=mean,
            design_tension=design,
            capacity=capacity,
            utilisation=design / capacity,
            factors=factors,
        )
        if best is None or check.utilisation > best.utilisation:
            best = check
    assert best is not None
    return best
