# SPDX-License-Identifier: Apache-2.0
"""Extreme-value statistics for time-history channels.

Sampling of extremes:

* :func:`block_maxima` returns the maximum (or minimum) of each complete,
  non-overlapping block of a given duration, the usual input to a Gumbel fit
  of, for example, 1-hour or 3-hour maxima.
* :func:`upcrossing_maxima` returns the largest value between successive
  up-crossings of a level (the mean by default), one peak per complete cycle,
  the usual input to a Weibull fit of individual peaks.

Distribution fits (NumPy only):

* :func:`fit_gumbel` fits a Gumbel (type I largest extreme value)
  distribution by maximum likelihood or by the method of moments.
* :func:`fit_weibull` fits a two-parameter Weibull distribution by maximum
  likelihood.

The fits describe the sample they are given. They do not check independence
or stationarity, do not extrapolate a block length, and give no confidence
interval; those remain engineering decisions.
"""

from __future__ import annotations

import itertools
import math
from dataclasses import dataclass
from typing import Any, Literal

import numpy as np
import numpy.typing as npt

from cabledyn.results import TimeHistory

__all__ = [
    "GumbelFit",
    "WeibullFit",
    "block_maxima",
    "fit_gumbel",
    "fit_weibull",
    "upcrossing_maxima",
]

_EULER_GAMMA = 0.5772156649015329
_BISECTION_STEPS = 200


def _readonly(values: npt.ArrayLike) -> npt.NDArray[Any]:
    result = np.array(values, dtype=np.float64, copy=True)
    result.setflags(write=False)
    return result


def _sample(values: npt.ArrayLike, what: str) -> npt.NDArray[Any]:
    data = np.asarray(values, dtype=np.float64).ravel()
    if data.size < 2 or not np.all(np.isfinite(data)):
        raise ValueError(f"{what} needs at least two finite values")
    if np.all(data == data[0]):
        raise ValueError(f"{what} needs values that are not all equal")
    return data


def _probability(value: float) -> float:
    if isinstance(value, bool) or not 0.0 < float(value) < 1.0:
        raise ValueError("probability must lie strictly between 0 and 1")
    return float(value)


def block_maxima(
    history: TimeHistory,
    channel: str,
    *,
    block_duration: float,
    start: float | None = None,
    stop: float | None = None,
    minima: bool = False,
) -> npt.NDArray[Any]:
    """Return the extreme of each complete block of ``block_duration`` seconds.

    Blocks start at the first selected sample and are half-open,
    ``[t0 + k T, t0 + (k + 1) T)``; the final block also includes a sample
    exactly at its end. A trailing incomplete block is discarded.

    Parameters
    ----------
    history : TimeHistory
        Record to sample.
    channel : str
        Non-time channel whose extremes are taken.
    block_duration : float
        Positive block length ``T``, in seconds.
    start, stop : float | None
        Optional analysis window, in seconds.
    minima : bool
        Return block minima instead of maxima.

    Returns
    -------
    numpy.ndarray
        Read-only ``(n_blocks,)`` block extremes, in the channel unit, in time
        order.

    Raises
    ------
    KeyError
        If the table has no channel of that name.
    ValueError
        If ``channel`` is the time channel, ``block_duration`` is not finite
        and positive, the window is invalid, the record is shorter than one
        block, or a block holds no sample.
    """
    if channel == history.time_channel:
        raise ValueError("block extremes need a non-time channel")
    duration = float(block_duration)
    if isinstance(block_duration, bool) or not math.isfinite(duration) or duration <= 0.0:
        raise ValueError("block_duration must be finite and positive")
    view = history.period(start, stop) if start is not None or stop is not None else history
    time, data = view.time, view.column(channel)
    span = float(time[-1] - time[0])
    count = math.floor(span / duration * (1.0 + 1.0e-12))
    if count < 1:
        raise ValueError("the record is shorter than one block")
    result: list[float] = []
    for block in range(count):
        lower = time[0] + block * duration
        upper = time[0] + (block + 1) * duration
        inside = (time >= lower) & ((time < upper) | (block == count - 1) & (time <= upper))
        if not np.any(inside):
            raise ValueError("a block contains no samples; use a longer block_duration")
        chunk = data[inside]
        result.append(float(np.min(chunk) if minima else np.max(chunk)))
    return _readonly(result)


def upcrossing_maxima(values: npt.ArrayLike, *, level: float | None = None) -> npt.NDArray[Any]:
    """Return the maximum between each pair of successive up-crossings of ``level``.

    ``level`` defaults to the sample mean. An up-crossing occurs between
    samples ``i`` and ``i + 1`` when ``x[i] < level <= x[i + 1]``. Samples
    before the first and after the last up-crossing are ignored, so only
    complete cycles contribute.

    Parameters
    ----------
    values : array_like
        At least three finite samples, in time order; flattened to 1-D.
    level : float | None
        Finite crossing level, in the unit of ``values``; ``None`` uses the
        sample mean.

    Returns
    -------
    numpy.ndarray
        Read-only ``(n_crossings - 1,)`` cycle maxima, in the unit of
        ``values``, in time order.

    Raises
    ------
    ValueError
        If there are fewer than three finite values, ``level`` is not finite,
        or fewer than two up-crossings occur.
    """
    data = np.asarray(values, dtype=np.float64).ravel()
    if data.size < 3 or not np.all(np.isfinite(data)):
        raise ValueError("up-crossing analysis needs at least three finite values")
    threshold = float(np.mean(data)) if level is None else float(level)
    if not math.isfinite(threshold):
        raise ValueError("level must be finite")
    crossings = np.flatnonzero((data[:-1] < threshold) & (data[1:] >= threshold)) + 1
    if crossings.size < 2:
        raise ValueError("fewer than two up-crossings: no complete cycle in the record")
    return _readonly(
        [float(np.max(data[first:second])) for first, second in itertools.pairwise(crossings)]
    )


@dataclass(frozen=True)
class GumbelFit:
    """Gumbel largest-extreme distribution ``F(x) = exp(-exp(-(x - location) / scale))``.

    Attributes
    ----------
    location : float
        Finite location (mode) parameter, in the unit of the fitted sample.
    scale : float
        Finite, positive scale parameter, in the unit of the fitted sample.
    sample_count : int
        Number of maxima fitted.
    method : str
        Estimator used: ``"mle"`` or ``"moments"``.

    Raises
    ------
    ValueError
        If ``location`` is not finite or ``scale`` is not finite and positive.
    """

    location: float
    scale: float
    sample_count: int
    method: str

    def __post_init__(self) -> None:
        if not math.isfinite(self.location) or not math.isfinite(self.scale) or self.scale <= 0:
            raise ValueError("Gumbel location must be finite and scale finite and positive")

    def cdf(self, value: npt.ArrayLike) -> npt.NDArray[Any]:
        """Non-exceedance probability of ``value``.

        Parameters
        ----------
        value : array_like
            Values, in the unit of the fitted sample; any shape.

        Returns
        -------
        numpy.ndarray
            Read-only probabilities ``F(value)`` in ``[0, 1]``, with the shape
            of ``value``.
        """
        reduced = (np.asarray(value, dtype=np.float64) - self.location) / self.scale
        return _readonly(np.exp(-np.exp(-reduced)))

    def quantile(self, probability: float) -> float:
        """Value with non-exceedance ``probability`` (strictly between 0 and 1).

        Parameters
        ----------
        probability : float
            Non-exceedance probability, strictly between 0 and 1.

        Returns
        -------
        float
            ``location - scale * ln(-ln(probability))``, in the unit of the
            fitted sample.

        Raises
        ------
        ValueError
            If ``probability`` is not strictly between 0 and 1.
        """
        p = _probability(probability)
        return self.location - self.scale * math.log(-math.log(p))

    def most_probable_maximum(self, blocks: float = 1.0) -> float:
        """Mode of the maximum over ``blocks`` fitted blocks, ``location + scale ln(blocks)``.

        ``blocks = 1`` gives the mode of the fitted block maximum itself. A
        larger count assumes independent, identically distributed blocks.

        Parameters
        ----------
        blocks : float
            Finite number of blocks, at least 1.

        Returns
        -------
        float
            Most probable maximum, in the unit of the fitted sample.

        Raises
        ------
        ValueError
            If ``blocks`` is not finite or is below 1.
        """
        count = float(blocks)
        if isinstance(blocks, bool) or not math.isfinite(count) or count < 1.0:
            raise ValueError("blocks must be finite and at least 1")
        return self.location + self.scale * math.log(count)

    def return_level(self, blocks: float) -> float:
        """Value exceeded on average once in ``blocks`` blocks (``blocks > 1``).

        Parameters
        ----------
        blocks : float
            Finite return period, in blocks, greater than 1.

        Returns
        -------
        float
            ``quantile(1 - 1 / blocks)``, in the unit of the fitted sample.

        Raises
        ------
        ValueError
            If ``blocks`` is not finite or is not greater than 1.
        """
        count = float(blocks)
        if isinstance(blocks, bool) or not math.isfinite(count) or count <= 1.0:
            raise ValueError("blocks must be finite and greater than 1")
        return self.quantile(1.0 - 1.0 / count)


def _gumbel_likelihood_scale(data: npt.NDArray[Any]) -> float:
    """Root of the Gumbel maximum-likelihood equation for the scale parameter."""
    mean, minimum = float(np.mean(data)), float(np.min(data))
    shifted = data - minimum

    def equation(scale: float) -> float:
        weights = np.exp(-shifted / scale)
        return scale - mean + float(np.sum(data * weights) / np.sum(weights))

    # With d = x - min >= 0, the weighted mean exceeds min by at most n * scale / e,
    # so equation(scale) <= scale * (1 + n / e) - (mean - min) and
    # equation(scale) >= scale - (mean - min). Both bounds below therefore
    # bracket the root.
    spread = mean - minimum
    lower = spread / (2.0 * (1.0 + data.size / math.e))
    upper = 2.0 * spread
    for _ in range(_BISECTION_STEPS):
        middle = 0.5 * (lower + upper)
        if equation(middle) < 0.0:
            lower = middle
        else:
            upper = middle
    return 0.5 * (lower + upper)


def fit_gumbel(maxima: npt.ArrayLike, *, method: Literal["mle", "moments"] = "mle") -> GumbelFit:
    """Fit a Gumbel distribution to a sample of maxima.

    ``"mle"`` solves the maximum-likelihood equations exactly (the scale by
    bisection, then the location in closed form); ``"moments"`` uses
    ``scale = s sqrt(6) / pi`` with the unbiased sample standard deviation
    ``s`` and ``location = mean - 0.5772 scale``.

    Parameters
    ----------
    maxima : array_like
        At least two finite, not all equal, sample maxima (for example from
        :func:`block_maxima`); flattened to 1-D.
    method : str
        ``"mle"`` (default) or ``"moments"``.

    Returns
    -------
    GumbelFit
        Fitted location and scale, in the unit of ``maxima``.

    Raises
    ------
    ValueError
        If the sample is too small, not finite, or constant, or ``method`` is
        unknown.
    """
    data = _sample(maxima, "a Gumbel fit")
    if method == "moments":
        scale = float(np.std(data, ddof=1)) * math.sqrt(6.0) / math.pi
        location = float(np.mean(data)) - _EULER_GAMMA * scale
    elif method == "mle":
        scale = _gumbel_likelihood_scale(data)
        minimum = float(np.min(data))
        location = minimum - scale * math.log(float(np.mean(np.exp(-(data - minimum) / scale))))
    else:
        raise ValueError("method must be 'mle' or 'moments'")
    return GumbelFit(location, scale, int(data.size), method)


@dataclass(frozen=True)
class WeibullFit:
    """Two-parameter Weibull distribution ``F(x) = 1 - exp(-(x / scale) ** shape)``, x >= 0.

    Attributes
    ----------
    shape : float
        Finite, positive, dimensionless shape parameter ``k``.
    scale : float
        Finite, positive scale parameter, in the unit of the fitted sample.
    sample_count : int
        Number of values fitted.

    Raises
    ------
    ValueError
        If ``shape`` or ``scale`` is not finite and positive.
    """

    shape: float
    scale: float
    sample_count: int

    def __post_init__(self) -> None:
        if not (
            math.isfinite(self.shape)
            and math.isfinite(self.scale)
            and self.shape > 0
            and self.scale > 0
        ):
            raise ValueError("Weibull shape and scale must be finite and positive")

    def cdf(self, value: npt.ArrayLike) -> npt.NDArray[Any]:
        """Non-exceedance probability of ``value`` (zero for negative values).

        Parameters
        ----------
        value : array_like
            Values, in the unit of the fitted sample; any shape.

        Returns
        -------
        numpy.ndarray
            Read-only probabilities ``F(value)`` in ``[0, 1]``, with the shape
            of ``value``.
        """
        x = np.clip(np.asarray(value, dtype=np.float64), 0.0, None)
        return _readonly(1.0 - np.exp(-((x / self.scale) ** self.shape)))

    def quantile(self, probability: float) -> float:
        """Value with non-exceedance ``probability`` (strictly between 0 and 1).

        Parameters
        ----------
        probability : float
            Non-exceedance probability, strictly between 0 and 1.

        Returns
        -------
        float
            ``scale * (-ln(1 - probability)) ** (1 / shape)``, in the unit of
            the fitted sample.

        Raises
        ------
        ValueError
            If ``probability`` is not strictly between 0 and 1.
        """
        p = _probability(probability)
        return float(self.scale * (-math.log1p(-p)) ** (1.0 / self.shape))


def fit_weibull(values: npt.ArrayLike) -> WeibullFit:
    """Fit a two-parameter Weibull distribution by maximum likelihood.

    Every value must be strictly positive. The shape solves
    ``sum(x^k ln x) / sum(x^k) - 1/k - mean(ln x) = 0``, which is monotone in
    ``k``, by bisection; the scale follows as ``mean(x^k) ** (1/k)``.

    Parameters
    ----------
    values : array_like
        At least two finite, strictly positive, not all equal values (for
        example from :func:`upcrossing_maxima`); flattened to 1-D.

    Returns
    -------
    WeibullFit
        Fitted dimensionless shape and scale in the unit of ``values``.

    Raises
    ------
    ValueError
        If the sample is too small, not finite, constant, or not strictly
        positive.
    """
    data = _sample(values, "a Weibull fit")
    if np.any(data <= 0.0):
        raise ValueError("a Weibull fit needs strictly positive values")
    logs = np.log(data)
    mean_log, top = float(np.mean(logs)), float(np.max(logs))

    def equation(shape: float) -> float:
        weights = np.exp(shape * (logs - top))
        return float(np.sum(weights * logs) / np.sum(weights)) - 1.0 / shape - mean_log

    # The weighted mean of ln x never exceeds max(ln x), so the equation is
    # negative at 0.5 / (max ln x - mean ln x); it tends to a positive limit as
    # the shape grows, so doubling finds the upper end of the bracket.
    lower = 0.5 / (top - mean_log)
    upper = 2.0 * lower
    while equation(upper) < 0.0:
        upper *= 2.0
    for _ in range(_BISECTION_STEPS):
        middle = 0.5 * (lower + upper)
        if equation(middle) < 0.0:
            lower = middle
        else:
            upper = middle
    shape = 0.5 * (lower + upper)
    scale = math.exp(top + math.log(float(np.mean(np.exp(shape * (logs - top))))) / shape)
    return WeibullFit(shape, scale, int(data.size))
