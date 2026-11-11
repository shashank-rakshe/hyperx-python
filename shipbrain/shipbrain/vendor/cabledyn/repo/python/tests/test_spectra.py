# SPDX-License-Identifier: Apache-2.0
"""Welch power spectra, magnitude-squared coherence, and the spectral result objects."""

from __future__ import annotations

import csv
import math
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    CoherenceResult,
    PowerSpectrum,
    SpectralPeak,
    TimeHistory,
    magnitude_squared_coherence,
    power_spectrum,
    read_output,
)
from cabledyn import spectra as spectra_module

FS = 32.0
SAMPLES = 256


def _time(samples: int = SAMPLES) -> np.ndarray:
    return np.arange(samples, dtype=np.float64) / FS


def _sine(samples: int = SAMPLES, *, amplitude: float = 3.0, phase: float = 0.0) -> np.ndarray:
    return amplitude * np.sin(2.0 * np.pi * 4.0 * _time(samples) + phase)


def _history(tmp_path, *, samples: int = 1024, fs: float = 64.0) -> TimeHistory:
    time = np.arange(samples, dtype=np.float64) / fs
    force = 3.0 * np.sin(2.0 * np.pi * 4.0 * time)
    shifted = 2.0 * np.sin(2.0 * np.pi * 4.0 * time + 0.4)
    path = tmp_path / "spectral.out"
    with path.open("w", encoding="ascii", newline="\n") as stream:
        stream.write("Time(s) FairTen1 FairTen2\n(s) (N) (N)\n")
        for values in zip(time, force, shifted, strict=True):
            stream.write(" ".join(f"{value:.17g}" for value in values) + "\n")
    result = read_output(path)
    assert isinstance(result, TimeHistory)
    return result


def _spectrum(tmp_path: Path, **kwargs) -> PowerSpectrum:
    options = {
        "channel": "FairTen1",
        "source": tmp_path / "source.out",
        "unit": "N",
        "segment_length": 64,
    }
    options.update(kwargs)
    return power_spectrum(_time(), _sine(), **options)


def _coherence(tmp_path: Path, **kwargs) -> CoherenceResult:
    options = {
        "channel_x": "FairTen1",
        "channel_y": "FairTen2",
        "source": tmp_path / "source.out",
        "segment_length": 64,
    }
    options.update(kwargs)
    return magnitude_squared_coherence(
        _time(),
        _sine(),
        _sine(amplitude=2.0, phase=0.4),
        **options,
    )


def _read_rows(path: Path) -> list[list[str]]:
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.reader(stream))


# ----------------------------------------------------------------------------- Welch power spectrum


def test_welch_sine_peak_parseval_units_and_metadata(tmp_path) -> None:
    history = _history(tmp_path)
    result = history.spectrum("FairTen1", segment_length=256)
    peak = result.dominant_peaks()[0]
    assert peak.frequency == 4.0
    assert peak.period == 0.25
    assert peak.density == pytest.approx(12.0)
    assert result.moment(0) == pytest.approx(4.5)
    assert result.moment_unit(0) == "N^2"
    assert result.moment_unit(2) == "N^2*Hz^2"
    assert result.moment(0) == pytest.approx(np.var(history.column("FairTen1")))
    assert result.density_unit == "N^2/Hz"
    assert result.frequency_resolution == 0.25
    assert result.sample_interval == pytest.approx(1.0 / 64.0)
    assert result.segment_count == 7
    assert result.overlap_samples == 128
    assert not result.frequency.flags.writeable
    assert not result.density.flags.writeable


def test_boxcar_single_segment_has_exact_bin_power_and_scaling(tmp_path) -> None:
    history = _history(tmp_path, samples=256)
    result = history.spectrum(
        "FairTen1",
        segment_length=256,
        overlap=0.0,
        window="boxcar",
    )
    index = int(np.where(result.frequency == 4.0)[0][0])
    assert result.density[index] * result.frequency_resolution == pytest.approx(4.5)
    scaled = power_spectrum(
        history.time,
        2.0 * history.column("FairTen1"),
        channel="scaled",
        source=history.path,
        unit="N",
        segment_length=256,
        overlap=0.0,
        window="boxcar",
    )
    assert scaled.density[index] == pytest.approx(4.0 * result.density[index])


@pytest.mark.parametrize("samples", [9, 10])
def test_single_boxcar_segment_satisfies_parseval_for_odd_and_even_fft(
    tmp_path,
    samples,
) -> None:
    values = np.random.default_rng(1234).normal(1.5, 2.0, samples)
    result = power_spectrum(
        _time(samples),
        values,
        channel="x",
        source=tmp_path / "s.out",
        unit="N",
        segment_length=samples,
        overlap=0.0,
        window="Rectangular",
        detrend="NONE",
    )
    assert result.fft_length == samples
    assert result.frequency.size == samples // 2 + 1
    assert result.segment_count == 1
    assert result.window == "boxcar"  # the canonical name of the alias
    assert result.detrend == "none"
    # With no detrending the zeroth moment is the discrete mean square.
    assert result.moment(0) == pytest.approx(np.mean(values**2), rel=1.0e-12)


def test_zero_padding_changes_bins_not_integrated_sine_power(tmp_path) -> None:
    history = _history(tmp_path)
    base = history.spectrum("FairTen1", segment_length=256)
    padded = history.spectrum("FairTen1", segment_length=256, fft_length=1024)
    assert padded.frequency_resolution == pytest.approx(base.frequency_resolution / 4.0)
    assert padded.dominant_peaks()[0].frequency == 4.0
    assert padded.moment(0) == pytest.approx(base.moment(0), rel=1.0e-12)


def test_spectral_moments_use_requested_bin_band_and_guard_dc(tmp_path) -> None:
    result = _history(tmp_path).spectrum("FairTen1", segment_length=256)
    # A periodic Hann spreads an exact-bin sinusoid over the centre and two
    # adjacent bins; integrate those known bin-centred contributions exactly.
    expected_m2 = 3.0 * 4.0**2 + 0.75 * (3.75**2 + 4.25**2)
    assert result.moment(2) == pytest.approx(expected_m2, rel=1.0e-12)
    assert result.moment(0, minimum_frequency=3.0, maximum_frequency=5.0) == pytest.approx(4.5)
    with pytest.raises(ValueError, match="zero-frequency"):
        result.moment(-1)
    with pytest.raises(ValueError, match="at least two"):
        result.moment(0, minimum_frequency=4.0, maximum_frequency=4.0)


def test_moment_gives_dc_and_nyquist_bins_full_power(tmp_path) -> None:
    samples, fs = 256, 64.0
    time = np.arange(samples) / fs
    constant = power_spectrum(
        time,
        np.full(samples, 3.0),
        channel="constant",
        source=tmp_path / "source.out",
        unit="N",
        segment_length=samples,
        overlap=0.0,
        window="boxcar",
        detrend="none",
    )
    assert constant.moment(0) == pytest.approx(9.0)
    assert constant.dominant_peaks() == ()
    assert constant.dominant_peaks(include_dc=True)[0].frequency == 0.0
    nyquist = power_spectrum(
        time,
        2.0 * (-1.0) ** np.arange(samples),
        channel="nyquist",
        source=tmp_path / "source.out",
        unit="N",
        segment_length=samples,
        overlap=0.0,
        window="boxcar",
        detrend="none",
    )
    assert nyquist.moment(0) == pytest.approx(4.0)
    assert nyquist.dominant_peaks()[0].frequency == fs / 2.0


def test_negative_order_moment_above_dc_matches_bin_sum(tmp_path) -> None:
    result = _spectrum(tmp_path)
    mask = result.frequency >= 1.0
    expected = (
        float(np.sum(result.frequency[mask] ** -1.0 * result.density[mask]))
        * result.frequency_resolution
    )
    assert result.moment(-1, minimum_frequency=1.0) == pytest.approx(expected, rel=1.0e-15)


def test_flat_or_zero_spectrum_has_no_false_endpoint_peak(tmp_path) -> None:
    history = _history(tmp_path)
    zero = TimeHistory(
        history.path,
        history.title,
        history.channels,
        history.units,
        np.column_stack((history.time, np.ones(history.time.size), np.ones(history.time.size))),
    ).spectrum("FairTen1", segment_length=256)
    assert np.all(zero.density == 0.0)
    assert zero.dominant_peaks(5) == ()

    flat = replace(zero, density=np.ones_like(zero.density))
    assert flat.dominant_peaks(5) == ()


def test_flat_topped_peak_is_reported_once(tmp_path):
    spectrum = _history(tmp_path).spectrum("FairTen1", segment_length=256)
    density = np.zeros_like(spectrum.density)
    density[5:8] = [1.0, 3.0, 3.0]
    density[8] = 1.0
    density[20] = 2.0
    flat = replace(spectrum, density=density)
    peaks = flat.dominant_peaks(3)
    assert [peak.index for peak in peaks] == [6, 20]


def test_dominant_peaks_orders_by_density_then_frequency_within_band(tmp_path) -> None:
    base = _spectrum(tmp_path)
    density = np.zeros_like(base.density)
    density[3] = 2.0
    density[6] = 5.0
    density[9] = 5.0
    density[-1] = 1.0  # rising Nyquist endpoint is a valid peak
    shaped = replace(base, density=density)
    peaks = shaped.dominant_peaks(10)
    assert [peak.index for peak in peaks] == [6, 9, 3, density.size - 1]
    assert [peak.index for peak in shaped.dominant_peaks(2)] == [6, 9]
    df = base.frequency_resolution
    banded = shaped.dominant_peaks(5, minimum_frequency=4 * df, maximum_frequency=8 * df)
    assert banded == (SpectralPeak(6, 6 * df, 5.0),)
    with pytest.raises(ValueError, match="count must be an integer of at least 1"):
        shaped.dominant_peaks(0)


def test_accepted_sampling_jitter_uses_the_same_duration_tolerances(tmp_path) -> None:
    intervals = np.concatenate((np.ones(51), np.full(48, 1.009)))
    time = np.concatenate(([0.0], np.cumsum(intervals)))
    values = np.column_stack((time, np.sin(2.0 * np.pi * 0.1 * time)))
    history = TimeHistory(
        tmp_path / "jitter.out",
        "",
        ("Time(s)", "FairTen1"),
        ("s", "N"),
        values,
    )
    with pytest.raises(ValueError, match="uniform sampling"):
        history.spectrum("FairTen1", segment_length=32)
    result = history.spectrum("FairTen1", segment_length=32, uniform_rtol=0.01)
    assert result.uniform_rtol == 0.01
    assert result.sample_interval == 1.0
    assert result.end_time == pytest.approx(time[-1])


def test_compound_units_are_parenthesized_before_squaring(tmp_path) -> None:
    time = np.arange(256) / 32.0
    values = np.column_stack((time, np.sin(2.0 * np.pi * 2.0 * time)))
    history = TimeHistory(
        tmp_path / "velocity.out",
        "",
        ("Time(s)", "L1N1vx"),
        ("s", "m/s"),
        values,
    )
    result = history.spectrum("L1N1vx", segment_length=128)
    assert result.density_unit == "(m/s)^2/Hz"
    assert result.moment_unit(0) == "(m/s)^2"
    assert result.moment_unit(2) == "(m/s)^2*Hz^2"
    target = result.export(tmp_path / "velocity_psd.csv")
    with target.open(newline="", encoding="utf-8") as stream:
        assert tuple(next(csv.reader(stream))) == (
            "frequency_[Hz]",
            "PSD_[(m/s)^2/Hz]",
        )


@pytest.mark.parametrize(
    ("unit", "density_unit", "moment_0", "moment_2"),
    [
        (None, None, None, None),
        ("-", "1/Hz", "1", "Hz^2"),
        ("", "1/Hz", "1", "Hz^2"),
        ("1", "1/Hz", "1", "Hz^2"),
        ("kN", "kN^2/Hz", "kN^2", "kN^2*Hz^2"),
        ("N*m", "(N*m)^2/Hz", "(N*m)^2", "(N*m)^2*Hz^2"),
    ],
)
def test_unit_bookkeeping(tmp_path, unit, density_unit, moment_0, moment_2) -> None:
    result = _spectrum(tmp_path, unit=unit)
    assert result.density_unit == density_unit
    assert result.moment_unit(0) == moment_0
    assert result.moment_unit(2) == moment_2
    assert result.moment_unit(-0.5) == (
        None if unit is None else ("Hz^-0.5" if moment_0 == "1" else f"{moment_0}*Hz^-0.5")
    )


# ---------------------------------------------------------------------------- Welch argument checks


def test_spectrum_rejects_nonuniform_or_malformed_configuration(tmp_path) -> None:
    history = _history(tmp_path)
    altered = history.values.copy()
    altered[10, history.channels.index(history.time_channel)] += 1.0e-3
    nonuniform = TimeHistory(
        history.path,
        history.title,
        history.channels,
        history.units,
        altered,
    )
    with pytest.raises(ValueError, match="uniform sampling"):
        nonuniform.spectrum("FairTen1", segment_length=256)
    with pytest.raises(ValueError, match="non-time"):
        history.spectrum("Time(s)", segment_length=256)
    with pytest.raises(ValueError, match="must not exceed"):
        history.spectrum("FairTen1", segment_length=2048)
    with pytest.raises(ValueError, match="overlap"):
        history.spectrum("FairTen1", segment_length=256, overlap=1.0)
    with pytest.raises(ValueError, match="fft_length"):
        history.spectrum("FairTen1", segment_length=256, fft_length=128)
    with pytest.raises(ValueError, match="window"):
        history.spectrum("FairTen1", segment_length=256, window="blackman")


@pytest.mark.parametrize(
    ("time", "message"),
    [
        ([0.0], "at least two finite time samples"),
        ([0.0, math.nan, 2.0], "at least two finite time samples"),
        ([[0.0, 1.0], [2.0, 3.0]], "at least two finite time samples"),
        ([0.0, 2.0, 1.0], "strictly increasing time"),
        ([0.0, 1.0, 1.0], "strictly increasing time"),
    ],
)
def test_power_spectrum_rejects_malformed_time(tmp_path, time, message) -> None:
    values = np.zeros(np.asarray(time).shape)
    with pytest.raises(ValueError, match=message):
        power_spectrum(
            time, values, channel="x", source=tmp_path / "s.out", unit=None, segment_length=2
        )


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"values": _sine()[:-1]}, "channel samples must be finite and match time"),
        (
            {"values": np.where(np.arange(SAMPLES) == 7, np.nan, _sine())},
            "channel samples must be finite and match time",
        ),
        ({"uniform_rtol": -1.0e-6}, "uniform_rtol must be finite and non-negative"),
        ({"uniform_rtol": math.nan}, "uniform_rtol must be finite and non-negative"),
        ({"uniform_rtol": True}, "uniform_rtol must be finite and non-negative"),
        ({"uniform_atol": math.inf}, "uniform_atol must be finite and non-negative"),
        ({"segment_length": 64.0}, "segment_length must be an integer of at least 2"),
        ({"segment_length": True}, "segment_length must be an integer of at least 2"),
        ({"segment_length": 1}, "segment_length must be an integer of at least 2"),
        ({"overlap": True}, r"overlap must be a finite fraction in \[0, 1\)"),
        ({"overlap": math.nan}, r"overlap must be a finite fraction in \[0, 1\)"),
        ({"overlap": -0.1}, r"overlap must be a finite fraction in \[0, 1\)"),
        ({"fft_length": 63}, "fft_length must be an integer of at least 64"),
        ({"fft_length": "128"}, "fft_length must be an integer of at least 64"),
        ({"detrend": None}, "detrend must be 'constant' or 'none'"),
        ({"detrend": "linear"}, "detrend must be 'constant' or 'none'"),
        ({"window": None}, "window must be 'hann' or 'boxcar'"),
        ({"window": "blackman"}, "window must be 'hann' or 'boxcar'"),
    ],
)
def test_power_spectrum_rejects_invalid_configuration(tmp_path, changes, message) -> None:
    changes = dict(changes)
    options = {"channel": "x", "source": tmp_path / "s.out", "unit": "N", "segment_length": 64}
    values = changes.pop("values", _sine())
    options.update(changes)
    with pytest.raises(ValueError, match=message):
        power_spectrum(_time(), values, **options)


def test_welch_reports_overflow_instead_of_infinite_density(tmp_path) -> None:
    with np.errstate(over="ignore"), pytest.raises(ValueError, match="overflowed"):
        power_spectrum(
            _time(),
            _sine(amplitude=1.0e200),
            channel="x",
            source=tmp_path / "s.out",
            unit="N",
            segment_length=64,
        )
    with np.errstate(over="ignore"), pytest.raises(ValueError, match="overflowed"):
        magnitude_squared_coherence(
            _time(),
            _sine(),
            _sine(amplitude=1.0e200),
            channel_x="x",
            channel_y="y",
            source=tmp_path / "s.out",
            segment_length=64,
        )


@pytest.mark.parametrize("order", [True, math.nan, math.inf])
def test_moment_and_moment_unit_reject_nonfinite_orders(tmp_path, order) -> None:
    result = _spectrum(tmp_path)
    with pytest.raises(ValueError, match="order must be finite"):
        result.moment_unit(order)
    with pytest.raises(ValueError, match="order must be finite"):
        result.moment(order)


@pytest.mark.parametrize(
    ("lower", "upper"),
    [
        (math.nan, None),
        (None, math.inf),
        (-1.0, None),
        (5.0, 3.0),
    ],
)
def test_moment_and_peaks_reject_invalid_bands(tmp_path, lower, upper) -> None:
    result = _spectrum(tmp_path)
    with pytest.raises(ValueError, match="finite, non-negative, and ordered"):
        result.moment(0, minimum_frequency=lower, maximum_frequency=upper)
    with pytest.raises(ValueError, match="finite, non-negative, and ordered"):
        result.dominant_peaks(
            minimum_frequency=0.0 if lower is None else lower, maximum_frequency=upper
        )


# ---------------------------------------------------------------------------------------- coherence


def test_coherence_identifies_shared_frequency_and_masks_zero_power(tmp_path) -> None:
    history = _history(tmp_path)
    result = history.coherence("FairTen1", "FairTen2", segment_length=256)
    index = int(np.where(result.frequency == 4.0)[0][0])
    assert result.valid[index]
    assert result.coherence[index] == pytest.approx(1.0)
    assert result.segment_count == 7
    assert np.all(np.isnan(result.coherence[~result.valid]))
    assert not result.valid.flags.writeable

    values = history.values.copy()
    values[:, 1:] = 1.0
    constant = TimeHistory(
        history.path,
        history.title,
        history.channels,
        history.units,
        values,
    )
    masked = constant.coherence("FairTen1", "FairTen2", segment_length=256)
    assert not np.any(masked.valid)
    assert np.all(np.isnan(masked.coherence))


def test_undetrended_coherence_of_scaled_copy_is_unity_in_every_valid_bin(tmp_path) -> None:
    x = np.random.default_rng(99).normal(5.0, 1.0, SAMPLES)
    result = magnitude_squared_coherence(
        _time(),
        x,
        -3.0 * x,
        channel_x="x",
        channel_y="y",
        source=tmp_path / "s.out",
        segment_length=64,
        detrend="none",
        window="boxcar",
        overlap=0.0,
    )
    assert result.segment_count == 4
    assert result.detrend == "none"
    assert np.all(result.valid)
    assert np.allclose(result.coherence, 1.0, rtol=0.0, atol=1.0e-12)


def test_lower_power_floor_only_widens_the_valid_mask(tmp_path) -> None:
    default = _coherence(tmp_path)
    permissive = _coherence(tmp_path, power_floor_ratio=0.0)
    assert permissive.power_floor_ratio == 0.0
    assert np.all(permissive.valid[default.valid])
    index = int(np.where(default.frequency == 4.0)[0][0])
    assert default.valid[index]
    assert permissive.coherence[index] == pytest.approx(default.coherence[index])
    assert default.coherence[index] == pytest.approx(1.0)


def test_coherence_requires_distinct_channels_and_multiple_segments(tmp_path) -> None:
    history = _history(tmp_path, samples=256)
    with pytest.raises(ValueError, match="distinct"):
        history.coherence("FairTen1", "FairTen1", segment_length=128)
    with pytest.raises(ValueError, match="at least two complete"):
        history.coherence("FairTen1", "FairTen2", segment_length=256)
    with pytest.raises(ValueError, match="power_floor_ratio"):
        history.coherence(
            "FairTen1",
            "FairTen2",
            segment_length=128,
            power_floor_ratio=1.0,
        )


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"y": _sine()[:-2]}, "second-channel samples must be finite and match time"),
        ({"y": np.full(SAMPLES, np.inf)}, "second-channel samples must be finite and match time"),
        ({"power_floor_ratio": True}, r"power_floor_ratio must be finite and in \[0, 1\)"),
        ({"power_floor_ratio": -0.1}, r"power_floor_ratio must be finite and in \[0, 1\)"),
        ({"power_floor_ratio": math.nan}, r"power_floor_ratio must be finite and in \[0, 1\)"),
    ],
)
def test_coherence_rejects_invalid_second_channel_or_floor(tmp_path, changes, message) -> None:
    changes = dict(changes)
    y = changes.pop("y", _sine(phase=0.3))
    with pytest.raises(ValueError, match=message):
        magnitude_squared_coherence(
            _time(),
            _sine(),
            y,
            channel_x="x",
            channel_y="y",
            source=tmp_path / "s.out",
            segment_length=64,
            **changes,
        )


# ------------------------------------------------------------------------------------- SpectralPeak


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"index": 1.5}, "index must be a non-negative integer"),
        ({"index": True}, "index must be a non-negative integer"),
        ({"index": -1}, "index must be a non-negative integer"),
        ({"frequency": -1.0}, "finite and non-negative"),
        ({"frequency": math.inf}, "finite and non-negative"),
        ({"density": math.nan}, "finite and non-negative"),
        ({"density": -1.0e-9}, "finite and non-negative"),
    ],
)
def test_spectral_peak_rejects_invalid_fields(kwargs, message) -> None:
    fields = {"index": 1, "frequency": 2.0, "density": 3.0}
    fields.update(kwargs)
    with pytest.raises(ValueError, match=message):
        SpectralPeak(**fields)


def test_spectral_peak_period_and_normalization() -> None:
    peak = SpectralPeak(np.int64(4), np.float32(2.0), 3)
    assert (peak.index, peak.frequency, peak.density) == (4, 2.0, 3.0)
    assert type(peak.index) is int and type(peak.density) is float
    assert peak.period == 0.5
    assert SpectralPeak(0, 0.0, 1.0).period == math.inf


# ---------------------------------------------------------------- PowerSpectrum and CoherenceResult


def test_public_result_objects_reject_inconsistent_metadata(tmp_path) -> None:
    history = _history(tmp_path)
    spectrum = history.spectrum("FairTen1", segment_length=256)
    with pytest.raises(ValueError, match="segment_count"):
        replace(spectrum, segment_count=spectrum.segment_count + 1)
    with pytest.raises(ValueError, match="frequency bins"):
        replace(spectrum, frequency=spectrum.frequency + 0.01)
    with pytest.raises(ValueError, match="sampling metadata"):
        replace(spectrum, end_time=spectrum.end_time + 0.1)

    coherence = history.coherence("FairTen1", "FairTen2", segment_length=256)
    with pytest.raises(ValueError, match="boolean"):
        replace(coherence, valid=coherence.valid.astype(np.int64))
    for sentinel in (0.0, np.inf, -np.inf):
        malformed = coherence.coherence.copy()
        malformed[~coherence.valid] = sentinel
        with pytest.raises(ValueError, match="must be NaN"):
            replace(coherence, coherence=malformed)


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"channel": ""}, "channel must be a non-empty string"),
        ({"channel": None}, "channel must be a non-empty string"),
        ({"unit": 1}, "unit must be a string or None"),
        ({"start_time": math.nan}, "start_time must be finite"),
        ({"sample_interval": True}, "sample_interval must be finite"),
        ({"end_time": math.inf}, "end_time must be finite"),
        ({"sample_interval": -1.0 / FS}, "sample_interval must be positive"),
        ({"end_time": 0.0}, "end_time must follow start_time"),
        ({"sample_count": 1}, "sample_count must be an integer of at least 2"),
        ({"overlap_samples": 1.5}, "overlap_samples must be a non-negative integer"),
        ({"overlap_samples": True}, "overlap_samples must be a non-negative integer"),
        ({"overlap_samples": -1}, "overlap_samples must be a non-negative integer"),
        ({"overlap_samples": 64}, "segment/overlap metadata is inconsistent"),
        ({"segment_length": 512, "fft_length": 512}, "segment/overlap metadata is inconsistent"),
        ({"fft_length": 32}, "fft_length must be an integer of at least 64"),
        ({"segment_count": 0}, "segment_count must be an integer of at least 1"),
        ({"uniform_rtol": -1.0}, "uniform_rtol must be finite and non-negative"),
        ({"uniform_atol": True}, "uniform_atol must be finite and non-negative"),
        ({"window": 5}, "window must be 'hann' or 'boxcar'"),
        ({"window": "flattop"}, "window must be 'hann' or 'boxcar'"),
        ({"detrend": 5}, "detrend must be 'constant' or 'none'"),
        ({"detrend": "linear"}, "detrend must be 'constant' or 'none'"),
    ],
)
def test_power_spectrum_rejects_inconsistent_metadata(tmp_path, changes, message) -> None:
    base = _spectrum(tmp_path)
    with pytest.raises(ValueError, match=message):
        replace(base, **changes)


def test_power_spectrum_rejects_inconsistent_arrays(tmp_path) -> None:
    base = _spectrum(tmp_path)
    with pytest.raises(ValueError, match="matching one-dimensional arrays"):
        replace(base, density=base.density[:-1])
    with pytest.raises(ValueError, match="matching one-dimensional arrays"):
        replace(base, frequency=base.frequency[:1], density=base.density[:1])
    negative = base.density.copy()
    negative[3] = -1.0
    with pytest.raises(ValueError, match="finite and non-negative"):
        replace(base, density=negative)
    nonfinite = base.density.copy()
    nonfinite[3] = np.inf
    with pytest.raises(ValueError, match="finite and non-negative"):
        replace(base, density=nonfinite)
    with pytest.raises(ValueError, match="finite and non-negative"):
        replace(base, frequency=base.frequency[::-1].copy())
    with pytest.raises(ValueError, match="frequency bins are inconsistent"):
        replace(base, frequency=base.frequency * 2.0)


def test_power_spectrum_normalizes_metadata_and_copies_arrays(tmp_path) -> None:
    base = _spectrum(tmp_path)
    frequency = base.frequency.copy()
    density = base.density.copy()
    normalized = replace(
        base,
        source=str(tmp_path / "a" / ".." / "source.out"),
        window="HANN",
        detrend="Constant",
        sample_count=np.int64(SAMPLES),
        frequency=frequency,
        density=density,
    )
    density[:] = 0.0
    assert normalized.source == (tmp_path / "source.out").resolve()
    assert (normalized.window, normalized.detrend) == ("hann", "constant")
    assert type(normalized.sample_count) is int
    assert np.array_equal(normalized.density, base.density)
    assert not normalized.density.flags.writeable


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"channel_x": ""}, "non-empty and distinct"),
        ({"channel_y": 7}, "non-empty and distinct"),
        ({"channel_y": "FairTen1"}, "non-empty and distinct"),
        ({"power_floor_ratio": True}, r"power_floor_ratio must be finite and in \[0, 1\)"),
        ({"power_floor_ratio": 1.0}, r"power_floor_ratio must be finite and in \[0, 1\)"),
        ({"power_floor_ratio": math.nan}, r"power_floor_ratio must be finite and in \[0, 1\)"),
        ({"segment_count": 3}, "segment_count is inconsistent"),
    ],
)
def test_coherence_result_rejects_invalid_scalars(tmp_path, changes, message) -> None:
    base = _coherence(tmp_path)
    with pytest.raises(ValueError, match=message):
        replace(base, **changes)


def test_coherence_result_requires_two_segments_even_when_metadata_is_consistent(
    tmp_path,
) -> None:
    base = _coherence(tmp_path)
    with pytest.raises(ValueError, match="at least two complete Welch segments"):
        replace(
            base,
            sample_count=64,
            segment_count=1,
            end_time=base.start_time + 63 * base.sample_interval,
        )


def test_coherence_result_rejects_inconsistent_arrays(tmp_path) -> None:
    base = _coherence(tmp_path)
    with pytest.raises(ValueError, match="arrays must match"):
        replace(base, valid=base.valid[:-1])
    with pytest.raises(ValueError, match="arrays must match"):
        replace(base, coherence=base.coherence[:-1])
    with pytest.raises(ValueError, match="finite and increasing"):
        replace(base, frequency=base.frequency[::-1].copy())
    with pytest.raises(ValueError, match="frequency bins are inconsistent"):
        replace(base, frequency=base.frequency + 0.01)
    index = int(np.flatnonzero(base.valid)[0])
    for bad in (1.5, -0.1, np.nan):
        coherence = base.coherence.copy()
        coherence[index] = bad
        with pytest.raises(ValueError, match=r"valid coherence values must lie in \[0, 1\]"):
            replace(base, coherence=coherence)


# -------------------------------------------------------------------------------- exports and plots


def test_spectral_exports_are_atomic_unit_aware_and_source_safe(tmp_path) -> None:
    history = _history(tmp_path)
    spectrum = history.spectrum("FairTen1", segment_length=256)
    target = spectrum.export(tmp_path / "spectrum.csv")
    with target.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    assert tuple(rows[0]) == ("frequency_[Hz]", "PSD_[N^2/Hz]")
    assert len(rows) == spectrum.frequency.size
    with pytest.raises(FileExistsError):
        spectrum.export(target)
    original = history.path.read_bytes()
    with pytest.raises(ValueError, match="source result"):
        spectrum.export(history.path, overwrite=True)
    coherence = history.coherence("FairTen1", "FairTen2", segment_length=256)
    coherence_target = coherence.export(tmp_path / "coherence.csv")
    with coherence_target.open(newline="", encoding="utf-8") as stream:
        coherence_rows = list(csv.DictReader(stream))
    assert tuple(coherence_rows[0]) == (
        "frequency_[Hz]",
        "coherence_[-]",
        "valid_[-]",
    )
    assert history.path.read_bytes() == original


def test_power_spectrum_export_without_unit_and_atomic_overwrite(tmp_path) -> None:
    result = _spectrum(tmp_path, unit=None)
    target = tmp_path / "deep" / "psd.csv"
    assert result.export(target) == target.resolve()
    rows = _read_rows(target)
    assert rows[0] == ["frequency_[Hz]", "PSD"]
    assert len(rows) == 1 + result.frequency.size
    assert [float(value) for value in rows[5]] == [result.frequency[4], result.density[4]]
    target.write_text("stale\n", encoding="utf-8")
    result.export(target, overwrite=True)
    assert _read_rows(target) == rows


def test_coherence_export_writes_blank_values_for_invalid_bins(tmp_path) -> None:
    base = _coherence(tmp_path)
    assert base.valid.any() and not base.valid.all()
    target = base.export(tmp_path / "coh" / "coherence.csv")
    rows = _read_rows(target)
    assert rows[0] == ["frequency_[Hz]", "coherence_[-]", "valid_[-]"]
    body = rows[1:]
    assert len(body) == base.frequency.size
    for row, frequency, value, ok in zip(
        body, base.frequency, base.coherence, base.valid, strict=True
    ):
        assert float(row[0]) == frequency
        assert row[2] == ("1" if ok else "0")
        assert row[1] == (f"{value:.17g}" if ok else "")
    with pytest.raises(FileExistsError, match="already exists"):
        base.export(target)
    with pytest.raises(ValueError, match="source result"):
        base.export(base.source, overwrite=True)


def test_failed_spectral_export_removes_temporary_and_keeps_target(
    tmp_path,
    monkeypatch,
) -> None:
    result = _spectrum(tmp_path)
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    target = out_dir / "psd.csv"
    target.write_text("original\n", encoding="utf-8")

    def refuse(*_args, **_kwargs):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(spectra_module.os, "replace", refuse)
    with pytest.raises(OSError, match="simulated replace failure"):
        result.export(target, overwrite=True)
    monkeypatch.undo()
    assert target.read_text(encoding="utf-8") == "original\n"
    assert sorted(path.name for path in out_dir.iterdir()) == ["psd.csv"]


def test_spectrum_and_coherence_plots_use_supplied_axes_and_labels(tmp_path, plt) -> None:
    unitless = _spectrum(tmp_path, unit=None)
    coherence = _coherence(tmp_path)
    figure, (left, right) = plt.subplots(1, 2)
    try:
        assert unitless.plot(ax=left, logarithmic=True) is left
        assert left.get_yscale() == "log"
        assert left.get_ylabel() == "Power spectral density"
        assert left.get_xlabel() == "Frequency [Hz]"
        line = left.get_lines()[0]
        assert np.array_equal(line.get_xdata(), unitless.frequency)
        assert np.array_equal(line.get_ydata(), unitless.density)

        assert coherence.plot(ax=right) is right
        assert right.get_ylabel() == "Magnitude-squared coherence [-]"
        assert right.get_ylim() == (0.0, 1.0)
        assert np.array_equal(right.get_lines()[0].get_ydata(), coherence.coherence, equal_nan=True)
    finally:
        plt.close(figure)

    ax = _spectrum(tmp_path).plot()
    try:
        assert ax.get_yscale() == "linear"
        assert ax.get_ylabel() == "Power spectral density [N^2/Hz]"
    finally:
        plt.close(ax.figure)
