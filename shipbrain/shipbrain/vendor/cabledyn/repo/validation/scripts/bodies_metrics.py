# File: validation/scripts/bodies_metrics.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Metric library of the bodies validation suite (definitions in validation/bodies/README.md).

All comparisons interpolate the reference onto the CableDyn times inside the scored window.
Positions are measured from the late-time mean ``y_end`` (mean of the last 10 % of the window),
so peaks and periods are independent of the coordinate origin.
"""

from __future__ import annotations

import numpy as np


def _window(t, y, window):
    if window is None:
        return t, y
    m = (t >= window[0] - 1e-9) & (t <= window[1] + 1e-9)
    return t[m], y[m]


def y_end(y):
    n = max(1, len(y) // 10)
    return float(np.mean(y[-n:]))


def e_rms(t, y, tr, yr, window=None):
    """sqrt(mean (y - y_r)^2) / max |y_r - y_r(end)|  (decays)."""
    t, y = _window(np.asarray(t), np.asarray(y), window)
    trw, yrw = _window(np.asarray(tr), np.asarray(yr), window)
    t_hi = min(t[-1], trw[-1])
    m = t <= t_hi + 1e-9
    yi = np.interp(t[m], trw, yrw)
    amp = np.max(np.abs(yrw - yrw[-1]))
    if not amp > 1e-9 * max(1.0, float(np.max(np.abs(yrw)))):
        return float("nan")  # no excursion (e.g. a pinned end): the metric is undefined
    return float(np.sqrt(np.mean((y[m] - yi) ** 2)) / amp)


def e_rms_star(t, y, tr, yr, window=None):
    """sqrt(mean (y - y_r)^2) / std(y_r)  (forced, statistics windows)."""
    t, y = _window(np.asarray(t), np.asarray(y), window)
    trw, yrw = _window(np.asarray(tr), np.asarray(yr), window)
    yi = np.interp(t, trw, yrw)
    s = np.std(yi)
    return float(np.sqrt(np.mean((y - yi) ** 2)) / s) if s > 0 else float("nan")


def crossings(t, y):
    """Upward zero crossings of y - y_end (linear interpolation)."""
    z = np.asarray(y) - y_end(y)
    i = np.where((z[:-1] < 0) & (z[1:] >= 0))[0]
    return t[i] - z[i] * (t[i + 1] - t[i]) / (z[i + 1] - z[i])


def period(t, y, window=None, max_cycles=None):
    t, y = _window(np.asarray(t), np.asarray(y), window)
    tc = crossings(t, y)
    if max_cycles:
        tc = tc[: max_cycles + 1]
    return float(np.mean(np.diff(tc))) if len(tc) >= 3 else float("nan")


def first_extreme(t, y):
    z = np.asarray(y) - y_end(y)
    amp = np.max(np.abs(z))
    for k in range(1, len(z) - 1):
        if (z[k] - z[k - 1]) * (z[k + 1] - z[k]) <= 0 and abs(z[k]) > 0.02 * amp and k > 1:
            # skip the release point itself (the initial offset)
            if abs(t[k] - t[0]) > 1e-9:
                return float(t[k]), float(z[k])
    return float("nan"), float("nan")


def e_pk(t, y, tr, yr, window=None):
    """|dy_pk - dy_pk,r| / |dy_pk,r| for the first extreme after release (from y_end)."""
    t, y = _window(np.asarray(t), np.asarray(y), window)
    tr, yr = _window(np.asarray(tr), np.asarray(yr), window)
    _, p = first_extreme(t, y)
    _, pr = first_extreme(tr, yr)
    return float(abs(p - pr) / abs(pr))


def log_decrement_zeta(t, y, n=5):
    z = np.asarray(y) - y_end(y)
    k = [i for i in range(1, len(z) - 1) if z[i] > z[i - 1] and z[i] >= z[i + 1] and z[i] > 0]
    a = z[k][: n + 1]
    if len(a) < 2:
        return float("nan")
    return float(np.mean(np.log(a[:-1] / a[1:])) / (2 * np.pi))


def e_T(t, y, t_or_value, yr=None, window=None):
    """|T - T_r| / T_r; the reference is a series (tr, yr) or a scalar period."""
    T = period(t, y, window)
    Tr = float(t_or_value) if yr is None else period(np.asarray(t_or_value), np.asarray(yr), window)
    return float(abs(T - Tr) / Tr)


def decay_ratio(t, y, window=None):
    """Energy-decay sanity: the largest excursion from y_end in the last fifth of the window over
    the largest one in the first fifth (below 1 for a decaying release)."""
    t, y = _window(np.asarray(t), np.asarray(y), window)
    z = np.abs(y - y_end(y))
    n = max(1, len(z) // 5)
    early = float(np.max(z[:n]))
    return float(np.max(z[-n:]) / early) if early > 0 else float("nan")


def e_drift(e):
    e = np.asarray(e)
    return float(np.max(np.abs(e - e[0])) / abs(e[0]))


def cycle_mean(t, y, window=None):
    """Mean over the whole cycles between the first and last upward crossings in the window."""
    t, y = _window(np.asarray(t), np.asarray(y), window)
    tc = crossings(t, y)
    if len(tc) < 2:
        return float(np.mean(y))
    m = (t >= tc[0]) & (t <= tc[-1])
    return float(np.trapezoid(y[m], t[m]) / (t[m][-1] - t[m][0]))
