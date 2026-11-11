# SPDX-License-Identifier: Apache-2.0
"""Command-line inspection and export of CableDyn result files."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable
from dataclasses import asdict, replace
from pathlib import Path
from typing import Any

from cabledyn.compare import compare_histories
from cabledyn.errors import DriverError
from cabledyn.fatigue import cycle_histogram
from cabledyn.formats import read_table
from cabledyn.results import (
    LineNodeHistory,
    LineSegmentHistory,
    OutputTable,
    StaticProfile,
    TimeHistory,
)
from cabledyn.spectra import DEFAULT_POWER_FLOOR_RATIO


def _print_pairs(values: dict[str, object]) -> None:
    for key, value in values.items():
        print(f"{key}: {value}")


def _output_path(value: str | None, source: Path, *, overwrite: bool) -> Path | None:
    """Validate a requested output path before any work is done."""
    if value is None:
        return None
    output = Path(value).expanduser().resolve()
    if output == source:
        raise ValueError(f"output must not replace the source result file: {output}")
    if output.exists() and not overwrite:
        raise FileExistsError(f"output already exists: {output}; pass --overwrite to replace it")
    return output


def _save_figure(ax: Any, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    ax.figure.savefig(output, bbox_inches="tight")
    print(output)


def _period(args: argparse.Namespace, table: TimeHistory) -> TimeHistory:
    if args.start is None and args.stop is None:
        return table
    return table.period(args.start, args.stop)


def _add_spectral_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--segment-length",
        type=int,
        required=True,
        help="samples per Welch segment (explicit, no automatic shortening)",
    )
    parser.add_argument(
        "--overlap", type=float, default=0.5, help="overlap fraction in [0,1) (default: 0.5)"
    )
    parser.add_argument(
        "--fft-length", type=int, help="FFT length >= segment length (default: segment length)"
    )
    parser.add_argument("--window", choices=("hann", "boxcar"), default="hann")
    parser.add_argument("--detrend", choices=("constant", "none"), default="constant")
    parser.add_argument("--start", type=float)
    parser.add_argument("--stop", type=float)
    parser.add_argument("--output", help="write unit-aware CSV")
    parser.add_argument("--plot-output", help="write figure")
    parser.add_argument("--overwrite", action="store_true")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cabledyn-post",
        description="Summarize, plot, or export a CableDyn result table.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    summary = subparsers.add_parser("summary", help="print engineering result statistics")
    summary.add_argument("file")
    summary.add_argument("--line", type=int, help="static LineID (default: every line)")
    summary.add_argument("--start", type=float, help="time-history period start (s)")
    summary.add_argument("--stop", type=float, help="time-history period stop (s)")

    export = subparsers.add_parser("export", help="write a pyDatView-friendly table")
    export.add_argument("file")
    export.add_argument("output")
    export.add_argument("--line", type=int, help="export one static LineID")
    export.add_argument("--overwrite", action="store_true")

    plot = subparsers.add_parser("plot", help="plot a channel or static geometry")
    plot.add_argument("file")
    plot.add_argument("channel", help="channel name, or 'geometry' for a static profile")
    plot.add_argument("--line", type=int)
    plot.add_argument("--x", default="ArcLength", help="static x-axis channel")
    plot.add_argument("--plane", default="xz", choices=("xy", "xz", "yz", "3d"))
    plot.add_argument("--start", type=float)
    plot.add_argument("--stop", type=float)
    plot.add_argument("--time", type=float, help="dynamic range-graph snapshot time (s)")
    plot.add_argument("--output", help="save figure instead of showing it")
    plot.add_argument("--overwrite", action="store_true")

    fatigue = subparsers.add_parser(
        "fatigue",
        help="rainflow-count a channel and calculate an uncorrected DEL range",
    )
    fatigue.add_argument("file")
    fatigue.add_argument("channel")
    fatigue.add_argument(
        "--m", type=float, required=True, dest="wohler_exponent", help="Wohler/S-N exponent"
    )
    reference = fatigue.add_mutually_exclusive_group(required=True)
    reference.add_argument("--reference-cycles", type=float)
    reference.add_argument(
        "--reference-frequency", type=float, help="equivalent-cycle frequency (Hz)"
    )
    fatigue.add_argument("--start", type=float)
    fatigue.add_argument("--stop", type=float)
    fatigue.add_argument("--bins", type=int, help="number of cycle-range histogram bins")
    fatigue.add_argument("--cycles-output", help="write the exact rainflow cycle table CSV")
    fatigue.add_argument("--histogram-output", help="write histogram CSV")
    fatigue.add_argument("--plot-output", help="write histogram figure")
    fatigue.add_argument("--overwrite", action="store_true")

    spectrum = subparsers.add_parser(
        "spectrum",
        help="calculate a one-sided Welch power spectral density",
    )
    spectrum.add_argument("file")
    spectrum.add_argument("channel")
    _add_spectral_options(spectrum)
    spectrum.add_argument(
        "--moment",
        type=float,
        action="append",
        default=[],
        help="spectral-moment order to integrate (repeatable)",
    )
    spectrum.add_argument(
        "--min-frequency",
        type=float,
        help="lower band limit for moments and peaks (Hz; default: the first "
        "bin, or the first non-zero bin for a negative moment order)",
    )
    spectrum.add_argument(
        "--max-frequency",
        type=float,
        help="upper band limit for moments and peaks (Hz; default: last bin)",
    )
    spectrum.add_argument(
        "--peaks", type=int, default=1, help="number of strongest local-maximum bins to report"
    )
    spectrum.add_argument(
        "--logarithmic", action="store_true", help="use a logarithmic PSD ordinate"
    )

    coherence = subparsers.add_parser(
        "coherence",
        help="calculate magnitude-squared Welch coherence",
    )
    coherence.add_argument("file")
    coherence.add_argument("channel_x")
    coherence.add_argument("channel_y")
    _add_spectral_options(coherence)
    coherence.add_argument(
        "--power-floor-ratio",
        type=float,
        default=DEFAULT_POWER_FLOOR_RATIO,
        help="relative auto-spectrum floor below which bins are invalid",
    )

    compare = subparsers.add_parser(
        "compare",
        help="compare two time histories channel by channel",
    )
    compare.add_argument("reference", help="reference time history")
    compare.add_argument("candidate", help="time history compared against the reference")
    compare.add_argument(
        "--channel",
        action="append",
        dest="channels",
        help="channel NAME, or REFERENCE=CANDIDATE for differently named channels "
        "(repeatable; default: every shared channel)",
    )
    compare.add_argument("--start", type=float)
    compare.add_argument("--stop", type=float)
    compare.add_argument(
        "--grid",
        choices=("reference", "candidate"),
        default="reference",
        help="time grid the other record is interpolated onto",
    )
    compare.add_argument("--percentile", type=float, default=95.0)
    compare.add_argument(
        "--no-unit-check", action="store_true", help="compare channels whose recorded units differ"
    )
    compare.add_argument("--output", help="write one CSV row of metrics per channel")
    compare.add_argument("--overwrite", action="store_true")

    for command in (summary, export, plot, fatigue, spectrum, coherence, compare):
        command.add_argument(
            "--format",
            default="auto",
            choices=("auto", "cabledyn", "openfast", "moordyn", "moordyn-line"),
            help="input format (default: from the file name)",
        )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    handlers: dict[str, Callable[[argparse.Namespace, OutputTable], None]] = {
        "summary": _summary,
        "export": _export,
        "plot": _plot,
        "fatigue": _fatigue,
        "spectrum": _spectrum,
        "coherence": _coherence,
    }
    try:
        if args.command == "compare":
            _compare(args)
            return 0
        table = read_table(args.file, format=args.format)
        handlers[args.command](args, table)
    except KeyError as exc:
        parser.exit(1, f"cabledyn-post: {exc.args[0] if exc.args else exc}\n")
    except (DriverError, OSError, ValueError, ImportError) as exc:
        parser.exit(1, f"cabledyn-post: {exc}\n")
    return 0


def _summary(args: argparse.Namespace, table: OutputTable) -> None:
    if isinstance(table, StaticProfile):
        identifiers = (args.line,) if args.line is not None else table.line_ids
        for identifier in identifiers:
            _print_pairs(asdict(table.summary(identifier)))
            if identifier != identifiers[-1]:
                print()
    elif isinstance(table, TimeHistory):
        view = _period(args, table)
        print(f"samples: {view.values.shape[0]}")
        print(f"time_start: {view.time[0]}")
        print(f"time_stop: {view.time[-1]}")
        for statistics in view.statistics():
            print()
            _print_pairs(asdict(statistics))
    else:
        print(f"rows: {table.values.shape[0]}")
        print(f"channels: {', '.join(table.channels)}")


def _export(args: argparse.Namespace, table: OutputTable) -> None:
    if args.line is not None:
        if not isinstance(table, StaticProfile):
            raise ValueError("--line is valid only for a static profile")
        table = table.line(args.line)
    print(table.export_pydatview(args.output, overwrite=args.overwrite))


def _fatigue(args: argparse.Namespace, table: OutputTable) -> None:
    if not isinstance(table, TimeHistory):
        raise ValueError("fatigue analysis requires a time-history result")
    cycles_output = _output_path(args.cycles_output, table.path, overwrite=args.overwrite)
    histogram_output = _output_path(args.histogram_output, table.path, overwrite=args.overwrite)
    plot_output = _output_path(args.plot_output, table.path, overwrite=args.overwrite)
    bins = args.bins
    if bins is None and (histogram_output or plot_output):
        bins = 32
    result = table.fatigue(
        args.channel,
        wohler_exponent=args.wohler_exponent,
        reference_cycles=args.reference_cycles,
        reference_frequency=args.reference_frequency,
        start=args.start,
        stop=args.stop,
    )
    if bins is not None and result.cycles:
        result = replace(result, histogram=cycle_histogram(result.cycles, bins))
    for key in (
        "channel",
        "source",
        "unit",
        "sample_count",
        "start_time",
        "end_time",
        "duration",
        "wohler_exponent",
        "reference_cycles",
        "equivalent_frequency",
        "cycle_count",
        "damage_equivalent_range",
    ):
        print(f"{key}: {getattr(result, key)}")
    if cycles_output:
        print(result.export_cycles(cycles_output, overwrite=args.overwrite))
    if (histogram_output or plot_output) and result.histogram is None:
        # A constant record has no cycles, so there are no histogram limits to report.
        print("histogram: not written (the selected record contains no load cycles)")
        return
    if histogram_output:
        print(result.export_histogram(histogram_output, overwrite=args.overwrite))
    if plot_output:
        _save_figure(result.plot_histogram(), plot_output)


def _spectrum(args: argparse.Namespace, table: OutputTable) -> None:
    if not isinstance(table, TimeHistory):
        raise ValueError("spectral analysis requires a time-history result")
    output = _output_path(args.output, table.path, overwrite=args.overwrite)
    plot_output = _output_path(args.plot_output, table.path, overwrite=args.overwrite)
    result = table.spectrum(
        args.channel,
        segment_length=args.segment_length,
        overlap=args.overlap,
        fft_length=args.fft_length,
        window=args.window,
        detrend=args.detrend,
        start=args.start,
        stop=args.stop,
    )
    lower = args.min_frequency
    if lower is None and any(order < 0.0 for order in args.moment) and result.frequency.size > 1:
        # Negative-order moments are undefined at f = 0; start at the first non-zero bin.
        lower = float(result.frequency[1])
    # Evaluate every requested quantity before printing, so an invalid request
    # fails without partial output.
    moments = [
        (
            order,
            result.moment(order, minimum_frequency=lower, maximum_frequency=args.max_frequency),
            result.moment_unit(order),
        )
        for order in args.moment
    ]
    peaks = result.dominant_peaks(
        args.peaks,
        minimum_frequency=0.0 if lower is None else lower,
        maximum_frequency=args.max_frequency,
    )
    for key in (
        "channel",
        "source",
        "unit",
        "density_unit",
        "start_time",
        "end_time",
        "sample_interval",
        "sample_count",
        "segment_length",
        "overlap_samples",
        "fft_length",
        "segment_count",
        "window",
        "detrend",
        "uniform_rtol",
        "uniform_atol",
        "frequency_resolution",
    ):
        print(f"{key}: {getattr(result, key)}")
    for order, value, unit in moments:
        print(f"moment_{order:g}: {value}")
        print(f"moment_{order:g}_unit: {unit}")
    for rank, peak in enumerate(peaks, start=1):
        print(f"peak_{rank}_frequency: {peak.frequency}")
        print(f"peak_{rank}_density: {peak.density}")
    if output:
        print(result.export(output, overwrite=args.overwrite))
    if plot_output:
        _save_figure(result.plot(logarithmic=args.logarithmic), plot_output)


def _coherence(args: argparse.Namespace, table: OutputTable) -> None:
    if not isinstance(table, TimeHistory):
        raise ValueError("coherence requires a time-history result")
    output = _output_path(args.output, table.path, overwrite=args.overwrite)
    plot_output = _output_path(args.plot_output, table.path, overwrite=args.overwrite)
    result = table.coherence(
        args.channel_x,
        args.channel_y,
        segment_length=args.segment_length,
        overlap=args.overlap,
        fft_length=args.fft_length,
        window=args.window,
        detrend=args.detrend,
        start=args.start,
        stop=args.stop,
        power_floor_ratio=args.power_floor_ratio,
    )
    for key in (
        "channel_x",
        "channel_y",
        "source",
        "start_time",
        "end_time",
        "sample_interval",
        "sample_count",
        "segment_length",
        "overlap_samples",
        "fft_length",
        "segment_count",
        "window",
        "detrend",
        "uniform_rtol",
        "uniform_atol",
        "power_floor_ratio",
    ):
        print(f"{key}: {getattr(result, key)}")
    print(f"valid_bins: {int(result.valid.sum())}")
    print(f"invalid_bins: {int((~result.valid).sum())}")
    if output:
        print(result.export(output, overwrite=args.overwrite))
    if plot_output:
        _save_figure(result.plot(), plot_output)


def _compare(args: argparse.Namespace) -> None:
    reference = read_table(args.reference, format=args.format)
    candidate = read_table(args.candidate, format=args.format)
    if not isinstance(reference, TimeHistory) or not isinstance(candidate, TimeHistory):
        raise ValueError("comparison requires two time-history results")
    output = _output_path(args.output, reference.path, overwrite=args.overwrite)
    if output is not None and output == candidate.path:
        raise ValueError(f"output must not replace the source result file: {output}")
    channels: dict[str, str] | None = None
    if args.channels:
        channels = {}
        for item in args.channels:
            name, separator, other = item.partition("=")
            if not name or (separator and not other):
                raise ValueError(f"invalid --channel {item!r}; use NAME or REFERENCE=CANDIDATE")
            if name in channels:
                raise ValueError(f"--channel {name!r} is given more than once")
            channels[name] = other if separator else name
    result = compare_histories(
        reference,
        candidate,
        channels=channels,
        start=args.start,
        stop=args.stop,
        grid=args.grid,
        percentile=args.percentile,
        check_units=not args.no_unit_check,
    )
    print(f"reference: {result.reference}")
    print(f"candidate: {result.candidate}")
    print(f"time_start: {result.start_time}")
    print(f"time_stop: {result.end_time}")
    print(f"samples: {result.time.size}")
    print(f"percentile: {result.percentile:g}")
    for item in result.channels:
        print()
        _print_pairs(asdict(item))
    if output is not None:
        print(result.export(output, overwrite=args.overwrite))


def _plot(args: argparse.Namespace, table: OutputTable) -> None:
    output = _output_path(args.output, table.path, overwrite=args.overwrite)
    ax: Any
    if isinstance(table, StaticProfile):
        if args.time is not None:
            raise ValueError("--time is valid only for a dynamic per-line output")
        if args.channel.lower() == "geometry":
            ax = table.plot_geometry(plane=args.plane, line_id=args.line)
        else:
            ax = table.plot(args.channel, x=args.x, line_id=args.line)
    elif isinstance(table, LineNodeHistory):
        if args.channel.lower() != "geometry":
            raise ValueError("dynamic line-position output supports channel 'geometry'")
        if args.time is None:
            raise ValueError("dynamic line geometry requires --time")
        if args.start is not None or args.stop is not None or args.line is not None:
            raise ValueError("--start, --stop, and --line do not apply to line geometry")
        ax = table.plot_geometry(args.time, plane=args.plane)
    elif isinstance(table, LineSegmentHistory):
        if args.channel.lower() not in {"tension", "range"}:
            raise ValueError("dynamic line-tension output supports channel 'Tension'")
        if args.line is not None:
            raise ValueError("--line does not apply to an already selected per-line file")
        if args.time is not None:
            if args.start is not None or args.stop is not None:
                raise ValueError("--time cannot be combined with --start or --stop")
            ax = table.plot_range(args.time)
        else:
            ax = table.plot_envelope(args.start, args.stop)
    elif isinstance(table, TimeHistory):
        if args.time is not None:
            raise ValueError("--time is valid only for a dynamic per-line output")
        ax = table.plot(args.channel, start=args.start, stop=args.stop)
    else:
        raise ValueError("plotting requires a time history or static profile")
    if output is not None:
        _save_figure(ax, output)
    else:
        import matplotlib.pyplot as plt

        plt.show()


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
