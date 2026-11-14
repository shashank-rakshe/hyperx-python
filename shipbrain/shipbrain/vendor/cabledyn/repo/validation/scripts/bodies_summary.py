# File: validation/scripts/bodies_summary.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Summary statistics of a bodies-suite series, for references kept as summary values only.

Some references (the OrcaFlex twin of V-D1b) are licensed output and are committed as the
summary values the gates check rather than as full series. :func:`summarise` reduces a
series to those values, and ``bodies_score.py`` applies the same function to the CableDyn
series before comparing, so both sides are reduced identically:

* ``mean``, ``std``, ``max``, ``t_max``, ``min``, ``t_min`` over the scored window;
* ``excursion``: the largest excursion from the window's last sample (the ``e_rms`` scale);
* ``period``: the mean upward-crossing period about the late-time mean (``bodies_metrics``);
* ``harmonic``: amplitude and phase (degrees, ``a cos(2 pi f t + phase)``) at a given
  frequency, projected over the whole cycles in the window;
* ``snaps``: the maxima of a channel within given time spans (snap loads).

The generating OrcaFlex script (``orcaflex_vd1b_reference.py``) writes these values into the
reference's provenance JSON under ``summary`` (:func:`reference_summary`); ``bodies_score.py``
evaluates the ``e_stat``, ``e_harm``, ``e_snap`` and ``e_T`` metrics against them
(:func:`score`).
"""

from __future__ import annotations

import numpy as np

import bodies_metrics as bm


def window(t, y, win):
    t, y = np.asarray(t, float), np.asarray(y, float)
    m = (t >= win[0] - 1e-9) & (t <= win[1] + 1e-9)
    return t[m], y[m]


def harmonic(t, y, freq):
    """Amplitude and phase (deg) of ``a cos(2 pi f t + phase)`` over the whole cycles in t."""
    t, y = np.asarray(t, float), np.asarray(y, float)
    ncyc = int(np.floor((t[-1] - t[0]) * freq))
    if ncyc < 1:
        return float("nan"), float("nan")
    m = t <= t[0] + ncyc / freq + 1e-9
    tt, yy = t[m], y[m] - np.mean(y[m])
    w = np.exp(-2j * np.pi * freq * tt)
    z = 2.0 * np.trapezoid(yy * w, tt) / (tt[-1] - tt[0])
    return float(abs(z)), float(np.degrees(np.angle(z)))


def summarise(t, y, win, freq=None):
    """The scalar summary of one channel over ``win`` (see the module docstring)."""
    tw, yw = window(t, y, win)
    out = dict(
        mean=float(np.mean(yw)), std=float(np.std(yw)),
        max=float(np.max(yw)), t_max=float(tw[np.argmax(yw)]),
        min=float(np.min(yw)), t_min=float(tw[np.argmin(yw)]),
        excursion=float(np.max(np.abs(yw - yw[-1]))),
        period=bm.period(tw, yw),
    )
    if freq is not None:
        out["harmonic_amp"], out["harmonic_phase_deg"] = harmonic(tw, yw, freq)
    return out


def dominant_frequency(t, y):
    """Frequency of the largest non-zero FFT bin of y (uniform grid t)."""
    t, y = np.asarray(t, float), np.asarray(y, float)
    amp = np.abs(np.fft.rfft(y - np.mean(y)))
    f = np.fft.rfftfreq(len(y), t[1] - t[0])
    return float(f[1 + int(np.argmax(amp[1:]))])


def grid(win, dt):
    """The uniform reference grid ``win[0]:dt:win[1]`` of a summary."""
    n = int(round((win[1] - win[0]) / dt))
    return win[0] + dt * np.arange(n + 1)


def reference_summary(t, channels, win, dt, harmonic_channels=(), snap_spans=None):
    """Summary record of a reference: every channel's statistics over ``win`` on the ``dt`` grid,
    the dominant-frequency harmonic of ``harmonic_channels``, and the maxima of the given
    channels within each snap span (``{channel: [[t0, t1], ...]}``)."""
    tg = grid(win, dt)
    out = dict(window=list(win), grid_dt=dt, channels={}, snaps={})
    for name, y in channels.items():
        yg = np.interp(tg, t, y)
        freq = dominant_frequency(tg, yg) if name in harmonic_channels else None
        rec = summarise(tg, yg, win, freq)
        if freq is not None:
            rec["harmonic_freq"] = freq
        out["channels"][name] = rec
    for name, spans in (snap_spans or {}).items():
        yg = np.interp(tg, t, channels[name])
        out["snaps"][name] = []
        for span in spans:
            ts, ys = window(tg, yg, span)
            k = int(np.argmax(ys))
            if k in (0, len(ys) - 1):
                raise ValueError(f"{name}: the maximum in {span} sits on the span edge, not on a snap peak")
            out["snaps"][name].append(dict(span=list(span), t=float(ts[k]), max=float(ys[k])))
    return out


def score(kind, spec, summary, t, y):
    """Evaluate one summary metric of a CableDyn series (t, y) against a reference summary.

    The CableDyn series is sampled on the summary's grid first, so both sides are reduced
    from the same instants. ``spec`` is the cases.json metric (``ref``, ``stat``, ``scale``,
    ``snap``).
    """
    win = summary["window"]
    tg = grid(win, summary["grid_dt"])
    t, y = np.asarray(t, float), np.asarray(y, float)
    if t[0] > tg[0] + 1e-9 or t[-1] < tg[-1] - 1e-9:
        raise ValueError(f"series covers t = {t[0]:g}-{t[-1]:g} s, summary window is {win}")
    yg = np.interp(tg, t, y)
    ref = summary["channels"][spec["ref"]]
    if kind == "e_snap":
        snap = summary["snaps"][spec["ref"]][spec["snap"]]
        _, ys = window(tg, yg, snap["span"])
        return float(abs(np.max(ys) - snap["max"]) / abs(snap["max"]))
    cd = summarise(tg, yg, win, ref.get("harmonic_freq"))
    if kind == "e_stat":
        stat = spec["stat"]
        scale = ref["excursion"] if spec["scale"] == "excursion" else abs(ref[stat])
        return float(abs(cd[stat] - ref[stat]) / scale)
    if kind == "e_T":
        return float(abs(cd["period"] - ref["period"]) / ref["period"])
    if kind == "e_harm":
        z = cd["harmonic_amp"] * np.exp(1j * np.radians(cd["harmonic_phase_deg"]))
        zr = ref["harmonic_amp"] * np.exp(1j * np.radians(ref["harmonic_phase_deg"]))
        return float(abs(z - zr) / abs(zr))
    raise ValueError(f"metric {kind} is not a summary metric")
