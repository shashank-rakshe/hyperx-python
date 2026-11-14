# SPDX-License-Identifier: Apache-2.0
"""S-N and T-N fatigue curves, including bilinear curves, with cited defaults.

A :class:`FatigueCurve` gives the number of cycles to failure of a constant
range ``S`` as ``N = a * S**(-m)``, or ``log10(N) = log10(a) - m log10(S)``.
A bilinear curve has a second segment ``(m2, log10(a2))`` that applies below
the range at which the two segments intersect.

* An **S-N** curve (``kind="S-N"``) takes a stress range in MPa.
* A **T-N** curve (``kind="T-N"``) takes a dimensionless tension range: the
  tension range divided by a reference breaking strength.

Built-in curves are provided only where the constants are published:

* :func:`dnv_rp_c203_curve` -- DNV-RP-C203 steel S-N curves in air, in
  seawater with cathodic protection, and under free corrosion;
* :func:`dnv_os_e301_curve` -- DNV-OS-E301 mooring-component curves for
  studlink and studless chain, stranded and spiral-strand wire rope, and
  polyester rope;
* :func:`api_rp_2sk_curve` -- API RP 2SK T-N curves for chain, connecting
  links, and wire rope.

Check the constants against the edition that your design basis names. Any
other curve can be built directly from its published constants with
:class:`FatigueCurve`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

import numpy as np
import numpy.typing as npt

__all__ = [
    "FatigueCurve",
    "api_rp_2sk_curve",
    "chain_nominal_area",
    "dnv_os_e301_curve",
    "dnv_rp_c203_curve",
]

_DNV_RP_C203 = (
    "DNV-RP-C203 Fatigue design of offshore steel structures (2016 edition, amended 2019)"
)
_DNVGL_OS_E301_2018 = "DNVGL-OS-E301 Position mooring (July 2018), Ch.2 Sec.2 fatigue limit state"
_API_RP_2SK = "API RP 2SK Design and Analysis of Stationkeeping Systems, 3rd edition (2005)"

# DNV-RP-C203 Table 2-1 (air): name -> (m1, log a1, log a2 with m2 = 5, k).
_C203_AIR: dict[str, tuple[float, float, float, float]] = {
    "B1": (4.0, 15.117, 17.146, 0.00),
    "B2": (4.0, 14.885, 16.856, 0.00),
    "C": (3.0, 12.592, 16.320, 0.05),
    "C1": (3.0, 12.449, 16.081, 0.10),
    "C2": (3.0, 12.301, 15.835, 0.15),
    "D": (3.0, 12.164, 15.606, 0.20),
    "E": (3.0, 12.010, 15.350, 0.20),
    "F": (3.0, 11.855, 15.091, 0.25),
    "F1": (3.0, 11.699, 14.832, 0.25),
    "F3": (3.0, 11.546, 14.576, 0.25),
    "G": (3.0, 11.398, 14.330, 0.25),
    "W1": (3.0, 11.261, 14.101, 0.25),
    "W2": (3.0, 11.107, 13.845, 0.25),
    "W3": (3.0, 10.970, 13.617, 0.25),
}
# DNV-RP-C203 Table 2-2 (seawater with cathodic protection): log a1; the
# second segment (m2 = 5, log a2) and k are those of Table 2-1.
_C203_SEAWATER_CP: dict[str, float] = {
    "B1": 14.917,
    "B2": 14.685,
    "C": 12.192,
    "C1": 12.049,
    "C2": 11.901,
    "D": 11.764,
    "E": 11.610,
    "F": 11.455,
    "F1": 11.299,
    "F3": 11.146,
    "G": 10.998,
    "W1": 10.861,
    "W2": 10.707,
    "W3": 10.570,
}
# DNV-RP-C203 Table 2-4 (free corrosion): single slope m = 3, log a.
_C203_FREE_CORROSION: dict[str, float] = {
    "B1": 12.436,
    "B2": 12.262,
    "C": 12.115,
    "C1": 11.972,
    "C2": 11.824,
    "D": 11.687,
    "E": 11.533,
    "F": 11.378,
    "F1": 11.222,
    "F3": 11.068,
    "G": 10.921,
    "W1": 10.784,
    "W2": 10.630,
    "W3": 10.493,
}
_C203_REFERENCE_THICKNESS_MM = 25.0

# DNVGL-OS-E301 (July 2018) Ch.2 Sec.2 fatigue curve parameters:
# component -> (a_D, m, kind, source).
_E301: dict[str, tuple[float, float, str, str]] = {
    "studlink_chain": (1.2e11, 3.0, "S-N", _DNVGL_OS_E301_2018),
    "studless_chain": (6.0e10, 3.0, "S-N", _DNVGL_OS_E301_2018),
    "stranded_rope": (3.4e14, 4.0, "S-N", _DNVGL_OS_E301_2018),
    "spiral_strand_rope": (1.7e17, 4.8, "S-N", _DNVGL_OS_E301_2018),
    "polyester_rope": (0.259, 13.46, "T-N", _DNVGL_OS_E301_2018),
}

# API RP 2SK T-N curves N R^M = K: component -> (M, log10 K at zero mean load,
# slope of log10 K against the mean-load ratio).
_API_2SK: dict[str, tuple[float, float, float]] = {
    "studlink_chain": (3.36, 3.0, 0.0),
    "studless_chain": (3.36, math.log10(316.0), 0.0),
    "connecting_link": (3.36, math.log10(178.0), 0.0),
    "stranded_rope": (4.09, 3.20, -2.79),
    "spiral_strand_rope": (5.05, 3.25, -3.43),
}


def _positive(value: float, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be finite and positive")
    number = float(value)
    if not math.isfinite(number) or number <= 0.0:
        raise ValueError(f"{name} must be finite and positive")
    return number


def _finite(value: float, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be finite")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"{name} must be finite")
    return number


@dataclass(frozen=True)
class FatigueCurve:
    """A single-slope or bilinear S-N or T-N curve, ``N = a S^-m``.

    Attributes
    ----------
    name : str
        Curve label, for example ``"DNV-RP-C203 D (seawater, CP)"``.
    kind : str
        ``"S-N"`` (ranges are stress ranges in MPa) or ``"T-N"`` (ranges are
        tension ranges divided by a reference breaking strength).
    m1 : float
        Inverse slope of the first (high-range, low-cycle) segment.
    log_a1 : float
        ``log10`` of the first segment's intercept ``a1``.
    m2 : float | None
        Inverse slope of the second (low-range) segment of a bilinear curve;
        larger than ``m1``. ``None`` for a single-slope curve.
    log_a2 : float | None
        ``log10`` of the second segment's intercept; given with ``m2``.
    source : str
        Publication the constants come from; empty for a user curve.
    thickness_exponent : float
        Thickness exponent ``k`` of a welded-steel curve; ``0`` when the
        curve has no thickness effect.
    reference_thickness : float | None
        Reference thickness, in millimetres, of the thickness correction;
        required when ``thickness_exponent`` is positive.
    endurance_limit : float | None
        Optional range, in the curve unit, at or below which a cycle does no
        damage. ``None`` (the default, and the published form of every
        built-in curve) keeps every cycle.

    Raises
    ------
    ValueError
        If a constant is not finite, a slope is not positive, only one of
        ``m2``/``log_a2`` is given, ``m2`` does not exceed ``m1``, or the
        thickness settings are inconsistent.
    """

    name: str
    kind: str
    m1: float
    log_a1: float
    m2: float | None = None
    log_a2: float | None = None
    source: str = ""
    thickness_exponent: float = 0.0
    reference_thickness: float | None = None
    endurance_limit: float | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name:
            raise ValueError("name must be a non-empty string")
        if self.kind not in {"S-N", "T-N"}:
            raise ValueError("kind must be 'S-N' or 'T-N'")
        object.__setattr__(self, "m1", _positive(self.m1, "m1"))
        object.__setattr__(self, "log_a1", _finite(self.log_a1, "log_a1"))
        if (self.m2 is None) != (self.log_a2 is None):
            raise ValueError("m2 and log_a2 must be given together")
        if self.m2 is not None and self.log_a2 is not None:
            m2 = _positive(self.m2, "m2")
            if m2 <= self.m1:
                raise ValueError("the second slope m2 must exceed m1")
            object.__setattr__(self, "m2", m2)
            object.__setattr__(self, "log_a2", _finite(self.log_a2, "log_a2"))
        exponent = _finite(self.thickness_exponent, "thickness_exponent")
        if exponent < 0.0:
            raise ValueError("thickness_exponent must be non-negative")
        object.__setattr__(self, "thickness_exponent", exponent)
        if self.reference_thickness is not None:
            object.__setattr__(
                self,
                "reference_thickness",
                _positive(self.reference_thickness, "reference_thickness"),
            )
        elif exponent > 0.0:
            raise ValueError("a positive thickness_exponent needs a reference_thickness")
        if self.endurance_limit is not None:
            object.__setattr__(
                self, "endurance_limit", _positive(self.endurance_limit, "endurance_limit")
            )

    @property
    def unit(self) -> str:
        """The unit of the ranges the curve takes, ``"MPa"`` or ``"-"``."""
        return "MPa" if self.kind == "S-N" else "-"

    @property
    def bilinear(self) -> bool:
        """Whether the curve has a second segment."""
        return self.m2 is not None

    @property
    def transition_range(self) -> float | None:
        """Range at which the two segments meet, in the curve unit; ``None`` if single-slope."""
        if self.m2 is None or self.log_a2 is None:
            return None
        return float(10.0 ** ((self.log_a2 - self.log_a1) / (self.m2 - self.m1)))

    @property
    def transition_cycles(self) -> float | None:
        """Cycles to failure at :attr:`transition_range`; ``None`` if single-slope."""
        knee = self.transition_range
        if knee is None:
            return None
        return float(10.0 ** (self.log_a1 - self.m1 * math.log10(knee)))

    def cycles_to_failure(self, ranges: npt.ArrayLike) -> npt.NDArray[Any]:
        """Return the constant-range endurance ``N`` for each range.

        Parameters
        ----------
        ranges : array_like
            Non-negative, finite ranges in the curve unit.

        Returns
        -------
        numpy.ndarray
            Read-only cycles to failure, of the shape of ``ranges``; ``inf``
            for a zero range or one at or below the endurance limit.

        Raises
        ------
        ValueError
            If a range is negative or not finite.
        """
        values = np.asarray(ranges, dtype=np.float64)
        if not np.all(np.isfinite(values)) or np.any(values < 0.0):
            raise ValueError("ranges must be finite and non-negative")
        result = np.full(values.shape, np.inf)
        active = values > 0.0
        if self.endurance_limit is not None:
            active &= values > self.endurance_limit
        logs = np.log10(values, where=active, out=np.zeros(values.shape))
        log_n = self.log_a1 - self.m1 * logs
        knee = self.transition_range
        if knee is not None and self.m2 is not None and self.log_a2 is not None:
            low = active & (values < knee)
            log_n = np.where(low, self.log_a2 - self.m2 * logs, log_n)
        result[active] = 10.0 ** log_n[active]
        result.setflags(write=False)
        return result

    def thickness_factor(self, thickness: float) -> float:
        """Return the stress-range factor ``(max(t, t_ref) / t_ref) ** k``.

        Multiply a nominal stress range by this factor to apply the
        thickness effect of a welded-steel curve.

        Parameters
        ----------
        thickness : float
            Positive plate or wall thickness, in millimetres.

        Returns
        -------
        float
            The factor; ``1.0`` for a curve without a thickness effect.

        Raises
        ------
        ValueError
            If ``thickness`` is not finite and positive.
        """
        value = _positive(thickness, "thickness")
        if self.thickness_exponent == 0.0 or self.reference_thickness is None:
            return 1.0
        return float(
            (max(value, self.reference_thickness) / self.reference_thickness)
            ** self.thickness_exponent
        )

    def tension_scale(
        self, *, area: float | None = None, breaking_strength: float | None = None
    ) -> float:
        """Return the factor that turns a tension range in newtons into a curve range.

        An S-N curve needs the nominal cross-section ``area`` in square metres
        (the factor is ``1 / (area * 1e6)``, giving MPa); a T-N curve needs the
        reference ``breaking_strength`` in newtons (the factor is
        ``1 / breaking_strength``).

        Parameters
        ----------
        area : float | None
            Nominal cross-section area, in m^2; S-N curves only.
        breaking_strength : float | None
            Reference breaking strength, in N; T-N curves only.

        Returns
        -------
        float
            The multiplier from newtons to the curve unit.

        Raises
        ------
        ValueError
            If the argument the curve kind needs is missing or not positive,
            or the other one is given.
        """
        if self.kind == "S-N":
            if area is None or breaking_strength is not None:
                raise ValueError("an S-N curve needs area (m^2) and no breaking_strength")
            return 1.0 / (_positive(area, "area") * 1.0e6)
        if breaking_strength is None or area is not None:
            raise ValueError("a T-N curve needs breaking_strength (N) and no area")
        return 1.0 / _positive(breaking_strength, "breaking_strength")


def dnv_rp_c203_curve(name: str, environment: str = "air") -> FatigueCurve:
    """Return a DNV-RP-C203 S-N curve for welded or plain steel.

    Source: DNV-RP-C203 *Fatigue design of offshore steel structures* (2016
    edition, amended 2019), Table 2-1 (in air: ``m1`` 3 or 4 up to 1e7
    cycles, ``m2 = 5`` beyond), Table 2-2 (seawater with cathodic
    protection: ``m1`` up to 1e6 cycles, ``m2 = 5`` beyond), and Table 2-4
    (free corrosion: single slope ``m = 3``). The thickness exponent ``k`` is
    taken from the same tables, with the reference thickness of 25 mm for
    welded connections other than tubular joints. Stress ranges are in MPa.

    Parameters
    ----------
    name : str
        Curve class: ``B1``, ``B2``, ``C``, ``C1``, ``C2``, ``D``, ``E``,
        ``F``, ``F1``, ``F3``, ``G``, ``W1``, ``W2``, or ``W3``
        (case-insensitive).
    environment : str
        ``"air"``, ``"seawater_cp"``, or ``"free_corrosion"``.

    Returns
    -------
    FatigueCurve
        The S-N curve.

    Raises
    ------
    ValueError
        If the curve class or the environment is not recognised.
    """
    key = str(name).upper()
    if key not in _C203_AIR:
        raise ValueError(f"unknown DNV-RP-C203 curve {name!r}; expected one of {tuple(_C203_AIR)}")
    m1, log_a1, log_a2, k = _C203_AIR[key]
    if environment == "air":
        return FatigueCurve(
            name=f"DNV-RP-C203 {key} (air)",
            m1=m1,
            log_a1=log_a1,
            m2=5.0,
            log_a2=log_a2,
            source=f"{_DNV_RP_C203}, Table 2-1",
            kind="S-N",
            thickness_exponent=k,
            reference_thickness=_C203_REFERENCE_THICKNESS_MM,
        )
    if environment == "seawater_cp":
        return FatigueCurve(
            name=f"DNV-RP-C203 {key} (seawater, CP)",
            m1=m1,
            log_a1=_C203_SEAWATER_CP[key],
            m2=5.0,
            log_a2=log_a2,
            source=f"{_DNV_RP_C203}, Table 2-2",
            kind="S-N",
            thickness_exponent=k,
            reference_thickness=_C203_REFERENCE_THICKNESS_MM,
        )
    if environment == "free_corrosion":
        return FatigueCurve(
            name=f"DNV-RP-C203 {key} (free corrosion)",
            m1=3.0,
            log_a1=_C203_FREE_CORROSION[key],
            source=f"{_DNV_RP_C203}, Table 2-4",
            kind="S-N",
            thickness_exponent=k,
            reference_thickness=_C203_REFERENCE_THICKNESS_MM,
        )
    raise ValueError("environment must be 'air', 'seawater_cp', or 'free_corrosion'")


def dnv_os_e301_curve(component: str) -> FatigueCurve:
    """Return a DNV-OS-E301 fatigue curve for a mooring-line component.

    Source: DNV-OS-E301 *Position mooring*, Ch.2 Sec.2, fatigue limit state,
    design curves ``n_c(s) = a_D s^-m``:

    ========================  ============  ======  =====
    Component                 ``a_D``       ``m``   Range
    ========================  ============  ======  =====
    ``studlink_chain``        1.2e11        3.0     MPa
    ``studless_chain``        6.0e10        3.0     MPa
    ``stranded_rope``         3.4e14        4.0     MPa
    ``spiral_strand_rope``    1.7e17        4.8     MPa
    ``polyester_rope``        0.259         13.46   T/MBS
    ========================  ============  ======  =====

    The chain and steel-rope ranges are nominal stress ranges in MPa (see
    :func:`chain_nominal_area` for chain). The polyester curve, from
    DNVGL-OS-E301 (July 2018), takes the tension range divided by the rope's
    minimum breaking strength, so it is returned as a T-N curve.

    Parameters
    ----------
    component : str
        One of the component names in the table.

    Returns
    -------
    FatigueCurve
        The single-slope curve.

    Raises
    ------
    ValueError
        If ``component`` is not recognised.
    """
    if component not in _E301:
        raise ValueError(
            f"unknown DNV-OS-E301 component {component!r}; expected one of {tuple(_E301)}"
        )
    a_d, m, kind, source = _E301[component]
    return FatigueCurve(
        name=f"DNV-OS-E301 {component.replace('_', ' ')}",
        kind=kind,
        m1=m,
        log_a1=math.log10(a_d),
        source=source,
    )


def api_rp_2sk_curve(component: str, *, mean_load_ratio: float | None = None) -> FatigueCurve:
    """Return an API RP 2SK T-N curve, ``N R^M = K``.

    Source: API RP 2SK *Design and Analysis of Stationkeeping Systems for
    Floating Structures*, 3rd edition (2005), fatigue analysis T-N curves.
    ``R`` is the tension range divided by the reference breaking strength:
    for chain and connecting links, that of ORQ chain of the same diameter;
    for wire rope, the rope's minimum breaking strength.

    ======================  ======  ================================
    Component               ``M``   ``K``
    ======================  ======  ================================
    ``studlink_chain``      3.36    1000
    ``studless_chain``      3.36    316
    ``connecting_link``     3.36    178 (Baldt and Kenter links)
    ``stranded_rope``       4.09    ``10**(3.20 - 2.79 Lm)``
    ``spiral_strand_rope``  5.05    ``10**(3.25 - 3.43 Lm)``
    ======================  ======  ================================

    ``Lm`` is the ratio of the mean tension to the reference breaking
    strength.

    Parameters
    ----------
    component : str
        One of the component names in the table.
    mean_load_ratio : float | None
        ``Lm`` in ``[0, 1)``; required for wire rope and rejected for chain
        and links.

    Returns
    -------
    FatigueCurve
        The single-slope T-N curve.

    Raises
    ------
    ValueError
        If ``component`` is not recognised, or ``mean_load_ratio`` is missing,
        out of range, or given for chain.
    """
    if component not in _API_2SK:
        raise ValueError(
            f"unknown API RP 2SK component {component!r}; expected one of {tuple(_API_2SK)}"
        )
    exponent, log_k, slope = _API_2SK[component]
    if slope == 0.0:
        if mean_load_ratio is not None:
            raise ValueError(f"{component} has no mean-load dependence; omit mean_load_ratio")
        name = f"API RP 2SK {component.replace('_', ' ')}"
    else:
        if mean_load_ratio is None:
            raise ValueError(f"{component} needs mean_load_ratio (mean tension / MBS)")
        ratio = _finite(mean_load_ratio, "mean_load_ratio")
        if not 0.0 <= ratio < 1.0:
            raise ValueError("mean_load_ratio must lie in [0, 1)")
        log_k += slope * ratio
        name = f"API RP 2SK {component.replace('_', ' ')} (Lm = {ratio:g})"
    return FatigueCurve(
        name=name,
        kind="T-N",
        m1=exponent,
        log_a1=log_k,
        source=f"{_API_RP_2SK}, T-N fatigue curves",
    )


def chain_nominal_area(diameter: float) -> float:
    """Return the nominal chain cross-section ``2 * pi * d**2 / 4`` in m^2.

    DNV-OS-E301 (Ch.2 Sec.2, fatigue limit state) refers the chain stress
    range to the area of the two legs of a link, from the nominal bar
    diameter.

    Parameters
    ----------
    diameter : float
        Nominal chain (bar) diameter, in metres.

    Returns
    -------
    float
        The nominal area, in m^2.

    Raises
    ------
    ValueError
        If ``diameter`` is not finite and positive.
    """
    value = _positive(diameter, "diameter")
    return 2.0 * math.pi * value * value / 4.0
