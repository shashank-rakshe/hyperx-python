# SPDX-License-Identifier: Apache-2.0
"""Subcommands, outputs, and argument rejections of the ``cabledyn-post`` command line."""

from __future__ import annotations

import csv
import math
from pathlib import Path

import pytest

from cabledyn.post_cli import main as post_main


def _write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="ascii")
    return path


def _history(tmp_path: Path, name: str = "case.out", *, scale: float = 1.0) -> Path:
    rows = []
    for step in range(64):
        t = 0.1 * step
        a = scale * math.sin(2.0 * math.pi * 0.625 * t)
        b = 0.5 * math.sin(2.0 * math.pi * 0.625 * t + 0.3) + 0.1 * math.cos(2.0 * math.pi * t)
        rows.append(f"{t:.6f} {1000.0 + 100.0 * a:.10f} {b:.10f}\n")
    return _write(tmp_path / name, "CableDyn history\nTime(s) FairTen1 AnchTen1\n" + "".join(rows))


def _profile(tmp_path: Path) -> Path:
    return _write(
        tmp_path / "case.static.out",
        "Static\nLineID Node ArcLength X Y Z Tension\n(-) (-) (m) (m) (m) (m) (N)\n"
        "1 1 0 0 0 -5 100\n1 2 2 2 0 -6 120\n2 1 0 0 1 -5 200\n2 2 3 3 1 -7 240\n",
    )


def _plain(tmp_path: Path) -> Path:
    return _write(tmp_path / "plain.out", "Node X Y\n1 2 3\n2 4 5\n")


def _positions(tmp_path: Path) -> Path:
    return _write(
        tmp_path / "case.Line1.p.out",
        "Time(s) Node1X(m) Node1Y(m) Node1Z(m) Node2X(m) Node2Y(m) Node2Z(m)\n"
        "0.0 0 0 -1 3 0 -5\n1.0 2 0 -1 8 0 -9\n",
    )


def _tensions(tmp_path: Path) -> Path:
    return _write(
        tmp_path / "case.Line1.t.out",
        "Time(s) Segment1Tension(N) Segment2Tension(N)\n0 100 200\n1 300 600\n2 500 400\n",
    )


def _fails(argv: list[str], capsys) -> str:
    with pytest.raises(SystemExit) as caught:
        post_main(argv)
    assert caught.value.code == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    return captured.err


def _plot_fails(argv: list[str], capsys) -> str:
    err = _fails(["plot", *argv], capsys)
    assert err.startswith("cabledyn-post: ")
    return err[len("cabledyn-post: ") :].rstrip("\n")


# ------------------------------------------------------------------------------- summary and export


def test_summary_of_a_time_history_period(tmp_path, capsys):
    source = _history(tmp_path)
    assert (
        post_main(
            ["summary", str(source), "--start", "1.0", "--stop", "1.5", "--format", "cabledyn"]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert lines[:3] == ["samples: 6", "time_start: 1.0", "time_stop: 1.5"]
    assert "channel: FairTen1" in lines
    assert "unit: N" in lines


def test_summary_of_every_static_line_is_blank_line_separated(tmp_path, capsys):
    assert post_main(["summary", str(_profile(tmp_path))]) == 0
    blocks = capsys.readouterr().out.strip().split("\n\n")
    assert len(blocks) == 2
    assert blocks[0].startswith("line_id: 1\nnode_count: 2\ndeformed_length: 2.0")
    assert "maximum_tension: 240.0" in blocks[1]
    assert "maximum_curvature: None" in blocks[1]


def test_summary_of_one_static_line(tmp_path, capsys):
    assert post_main(["summary", str(_profile(tmp_path)), "--line", "2"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[:3] == ["line_id: 2", "node_count: 2", "deformed_length: 3.0"]
    assert "maximum_tension: 240.0" in lines
    assert "" not in lines


def test_summary_of_a_plain_table(tmp_path, capsys):
    assert post_main(["summary", str(_plain(tmp_path))]) == 0
    assert capsys.readouterr().out == "rows: 2\nchannels: Node, X, Y\n"


def test_summary_of_a_missing_static_line_fails(tmp_path, capsys):
    err = _fails(["summary", str(_profile(tmp_path)), "--line", "9"], capsys)
    assert err.startswith("cabledyn-post: LineID 9 is not in case.static.out")


def test_export_one_static_line(tmp_path, capsys):
    target = tmp_path / "line2.csv"
    assert post_main(["export", str(_profile(tmp_path)), str(target), "--line", "2"]) == 0
    assert capsys.readouterr().out.strip() == str(target.resolve())
    with target.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream))
    assert rows[0] == [
        "LineID_[-]",
        "Node_[-]",
        "ArcLength_[m]",
        "X_[m]",
        "Y_[m]",
        "Z_[m]",
        "Tension_[N]",
    ]
    assert [row[0] for row in rows[1:]] == ["2", "2"]
    assert rows[2][-1] == "240"


def test_export_a_whole_time_history_as_tab_separated_text(tmp_path, capsys):
    target = tmp_path / "nested" / "case.txt"
    assert post_main(["export", str(_history(tmp_path)), str(target)]) == 0
    assert capsys.readouterr().out.strip() == str(target.resolve())
    lines = target.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "Time_[s]\tFairTen1_[N]\tAnchTen1_[N]"
    assert len(lines) == 65
    assert lines[1].split("\t")[:2] == ["0", "1000"]


def test_export_line_requires_a_static_profile(tmp_path, capsys):
    target = tmp_path / "x.csv"
    err = _fails(["export", str(_history(tmp_path)), str(target), "--line", "1"], capsys)
    assert err == "cabledyn-post: --line is valid only for a static profile\n"
    assert not target.exists()


def test_unknown_format_is_a_usage_error(tmp_path, capsys):
    with pytest.raises(SystemExit) as caught:
        post_main(["summary", str(_history(tmp_path)), "--format", "csv"])
    assert caught.value.code == 2
    assert "invalid choice: 'csv'" in capsys.readouterr().err


def test_missing_channels_are_reported_without_repr_quotes(tmp_path, capsys):
    err = _fails(
        ["fatigue", str(_history(tmp_path)), "Nope", "--m", "3", "--reference-cycles", "1e6"],
        capsys,
    )
    assert err.startswith("cabledyn-post: ")
    assert "Nope" in err
    assert not err.split(": ", 1)[1].startswith('"')


# ----------------------------------------------------------------- fatigue, spectrum, and coherence


@pytest.mark.parametrize(
    ("argv", "message"),
    [
        (
            ["fatigue", "{src}", "Tension", "--m", "3", "--reference-cycles", "1e6"],
            "fatigue analysis requires a time-history result",
        ),
        (
            ["spectrum", "{src}", "Tension", "--segment-length", "4"],
            "spectral analysis requires a time-history result",
        ),
        (
            ["coherence", "{src}", "Tension", "X", "--segment-length", "4"],
            "coherence requires a time-history result",
        ),
    ],
)
def test_analyses_reject_a_static_profile(tmp_path, capsys, argv, message):
    source = str(_profile(tmp_path))
    err = _fails([source if item == "{src}" else item for item in argv], capsys)
    assert err == f"cabledyn-post: {message}\n"


def test_fatigue_writes_summary_cycles_histogram_and_plot(tmp_path, capsys, plt):
    reversals = [-2, 1, -3, 5, -1, 3, -4, 4, -3, 1, -2, 3, 2, 6]  # ASTM E1049 example
    rows = "".join(f"{index} {value}\n" for index, value in enumerate(reversals))
    source = _write(tmp_path / "astm.out", f"Time(s) FairTen1\n(s) (N)\n{rows}")
    cycles = tmp_path / "cycles.csv"
    histogram = tmp_path / "histogram.csv"
    figure = tmp_path / "histogram.png"
    assert (
        post_main(
            [
                "fatigue",
                str(source),
                "FairTen1",
                "--m",
                "4",
                "--reference-frequency",
                "1",
                "--bins",
                "5",
                "--cycles-output",
                str(cycles),
                "--histogram-output",
                str(histogram),
                "--plot-output",
                str(figure),
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert "cycle_count: 6.5" in lines
    assert any(line.startswith("damage_equivalent_range: ") for line in lines)
    assert lines[-3:] == [str(path.resolve()) for path in (cycles, histogram, figure)]
    with cycles.open(encoding="utf-8", newline="") as stream:
        assert len(list(csv.reader(stream))) == 1 + 9  # the ASTM example has nine cycles
    with histogram.open(encoding="utf-8", newline="") as stream:
        assert len(list(csv.reader(stream))) == 1 + 5
    assert figure.stat().st_size > 0


def test_fatigue_histogram_without_plot(tmp_path, capsys):
    histogram = tmp_path / "hist.csv"
    assert (
        post_main(
            [
                "fatigue",
                str(_history(tmp_path)),
                "FairTen1",
                "--m",
                "3",
                "--reference-frequency",
                "1",
                "--histogram-output",
                str(histogram),
                "--bins",
                "4",
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert "channel: FairTen1" in lines
    assert "unit: N" in lines
    assert lines[-1] == str(histogram.resolve())
    with histogram.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream))
    assert len(rows) == 5


def test_fatigue_plot_without_histogram_uses_default_bins(tmp_path, capsys, plt):
    figure = tmp_path / "figs" / "hist.png"
    assert (
        post_main(
            [
                "fatigue",
                str(_history(tmp_path)),
                "FairTen1",
                "--m",
                "3",
                "--reference-cycles",
                "1e6",
                "--plot-output",
                str(figure),
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert lines[-1] == str(figure.resolve())
    assert "reference_cycles: 1000000.0" in lines
    assert figure.stat().st_size > 0


def test_fatigue_of_a_constant_channel_skips_the_histogram(tmp_path, capsys):
    source = _write(tmp_path / "flat.out", "Time(s) FairTen1\n(s) (N)\n0 5\n1 5\n2 5\n")
    histogram = tmp_path / "histogram.csv"
    assert (
        post_main(
            [
                "fatigue",
                str(source),
                "FairTen1",
                "--m",
                "3",
                "--reference-cycles",
                "1e6",
                "--histogram-output",
                str(histogram),
            ]
        )
        == 0
    )
    output = capsys.readouterr().out
    assert "damage_equivalent_range: 0.0" in output
    assert "histogram: not written" in output
    assert not histogram.exists()


def test_fatigue_output_over_the_source_is_rejected(tmp_path, capsys):
    source = _history(tmp_path)
    err = _fails(
        [
            "fatigue",
            str(source),
            "FairTen1",
            "--m",
            "3",
            "--reference-cycles",
            "1",
            "--cycles-output",
            str(source),
        ],
        capsys,
    )
    assert "output must not replace the source result file" in err


def test_spectrum_reports_peaks_without_outputs(tmp_path, capsys):
    assert (
        post_main(
            [
                "spectrum",
                str(_history(tmp_path)),
                "FairTen1",
                "--segment-length",
                "16",
                "--moment",
                "0",
                "--peaks",
                "1",
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert "fft_length: 16" in lines
    assert "moment_0_unit: N^2" in lines
    peak = float(next(line for line in lines if line.startswith("peak_1_frequency:")).split()[1])
    assert peak == pytest.approx(0.625)


def test_spectrum_writes_csv_and_plot(tmp_path, capsys, plt):
    table = tmp_path / "spectrum.csv"
    figure = tmp_path / "spectrum.png"
    assert (
        post_main(
            [
                "spectrum",
                str(_history(tmp_path)),
                "FairTen1",
                "--segment-length",
                "16",
                "--output",
                str(table),
                "--plot-output",
                str(figure),
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert "density_unit: N^2/Hz" in lines
    assert lines[-2:] == [str(table.resolve()), str(figure.resolve())]
    with table.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream))
    assert rows[0] == ["frequency_[Hz]", "PSD_[N^2/Hz]"]
    assert len(rows) == 1 + 9
    assert figure.stat().st_size > 0


def test_spectrum_negative_moment_starts_above_dc(tmp_path, capsys):
    assert (
        post_main(
            [
                "spectrum",
                str(_history(tmp_path)),
                "FairTen1",
                "--segment-length",
                "16",
                "--moment",
                "-1",
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert "moment_-1_unit: N^2*Hz^-1" in lines
    moment = float(next(line for line in lines if line.startswith("moment_-1:")).split()[1])
    assert math.isfinite(moment) and moment > 0.0


def test_spectrum_plot_over_the_source_is_rejected_before_any_output(tmp_path, capsys):
    source = _history(tmp_path)
    original = source.read_bytes()
    err = _fails(
        [
            "spectrum",
            str(source),
            "FairTen1",
            "--segment-length",
            "16",
            "--plot-output",
            str(source),
            "--overwrite",
        ],
        capsys,
    )
    assert "must not replace the source" in err
    assert source.read_bytes() == original


def test_coherence_csv_without_plot(tmp_path, capsys):
    output = tmp_path / "coh.csv"
    assert (
        post_main(
            [
                "coherence",
                str(_history(tmp_path)),
                "FairTen1",
                "AnchTen1",
                "--segment-length",
                "16",
                "--output",
                str(output),
            ]
        )
        == 0
    )
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == "channel_x: FairTen1"
    assert lines[1] == "channel_y: AnchTen1"
    assert "segment_length: 16" in lines
    valid = int(next(line for line in lines if line.startswith("valid_bins:")).split()[1])
    invalid = int(next(line for line in lines if line.startswith("invalid_bins:")).split()[1])
    assert valid + invalid == 9
    assert lines[-1] == str(output.resolve())
    assert output.read_text(encoding="utf-8").count("\n") >= 10


def test_coherence_plot_without_csv(tmp_path, capsys, plt):
    figure = tmp_path / "coh.png"
    assert (
        post_main(
            [
                "coherence",
                str(_history(tmp_path)),
                "FairTen1",
                "AnchTen1",
                "--segment-length",
                "16",
                "--plot-output",
                str(figure),
            ]
        )
        == 0
    )
    assert capsys.readouterr().out.splitlines()[-1] == str(figure.resolve())
    assert figure.stat().st_size > 0


# ------------------------------------------------------------------------------------------ compare


def test_compare_every_shared_channel_without_output(tmp_path, capsys):
    reference = _history(tmp_path, "ref.out")
    candidate = _history(tmp_path, "cand.out", scale=1.1)
    assert post_main(["compare", str(reference), str(candidate)]) == 0
    out = capsys.readouterr().out
    assert out.startswith(f"reference: {reference.resolve()}\ncandidate: {candidate.resolve()}\n")
    assert "samples: 64\npercentile: 95\n" in out
    blocks = {
        block.splitlines()[0]: dict(line.split(": ", 1) for line in block.splitlines())
        for block in out.strip().split("\n\n")[1:]
    }
    assert set(blocks) == {"channel: FairTen1", "channel: AnchTen1"}
    # AnchTen1 is identical in both records; FairTen1 differs by 10 % of a 100 N amplitude.
    assert float(blocks["channel: AnchTen1"]["max_abs_difference"]) == 0.0
    assert float(blocks["channel: FairTen1"]["max_abs_difference"]) == pytest.approx(10.0)
    assert blocks["channel: FairTen1"]["unit"] == "N"


@pytest.mark.parametrize(
    ("extra", "message"),
    [
        (["--channel", "=FairTen1"], "invalid --channel"),
        (["--channel", "FairTen1="], "invalid --channel"),
        (["--channel", "FairTen1", "--channel", "FairTen1=AnchTen1"], "more than once"),
        (["--channel", "Missing"], "Missing"),
    ],
)
def test_compare_rejects_malformed_channel_selections(tmp_path, capsys, extra, message):
    source = str(_history(tmp_path))
    assert message in _fails(["compare", source, source, *extra], capsys)


def test_compare_requires_two_time_histories(tmp_path, capsys):
    err = _fails(["compare", str(_history(tmp_path)), str(_profile(tmp_path))], capsys)
    assert err == "cabledyn-post: comparison requires two time-history results\n"


def test_compare_output_must_not_replace_the_candidate(tmp_path, capsys):
    reference = _history(tmp_path, "ref.out")
    candidate = _history(tmp_path, "cand.out")
    err = _fails(
        ["compare", str(reference), str(candidate), "--output", str(candidate), "--overwrite"],
        capsys,
    )
    assert "output must not replace the source result file" in err


# --------------------------------------------------------------------------------------------- plot


def test_plot_static_rejections(tmp_path, capsys, plt):
    source = str(_profile(tmp_path))
    assert _plot_fails([source, "geometry", "--time", "1"], capsys) == (
        "--time is valid only for a dynamic per-line output"
    )


def test_plot_static_geometry_and_channel(tmp_path, capsys, plt):
    source = str(_profile(tmp_path))
    figure = tmp_path / "geometry.png"
    assert (
        post_main(
            ["plot", source, "Geometry", "--plane", "xy", "--line", "1", "--output", str(figure)]
        )
        == 0
    )
    assert capsys.readouterr().out.strip() == str(figure.resolve())
    assert figure.stat().st_size > 0
    channel = tmp_path / "tension.png"
    assert post_main(["plot", source, "Tension", "--x", "X", "--output", str(channel)]) == 0
    assert channel.exists()


@pytest.mark.parametrize(
    ("extra", "message"),
    [
        (["Tension", "--time", "0.5"], "dynamic line-position output supports channel 'geometry'"),
        (["geometry"], "dynamic line geometry requires --time"),
        (
            ["geometry", "--time", "0.5", "--start", "0"],
            "--start, --stop, and --line do not apply to line geometry",
        ),
        (
            ["geometry", "--time", "0.5", "--stop", "1"],
            "--start, --stop, and --line do not apply to line geometry",
        ),
        (
            ["geometry", "--time", "0.5", "--line", "1"],
            "--start, --stop, and --line do not apply to line geometry",
        ),
        (["geometry", "--time", "5"], "sample time 5 is outside [0, 1]"),
    ],
)
def test_plot_line_position_rejections(tmp_path, capsys, plt, extra, message):
    assert _plot_fails([str(_positions(tmp_path)), *extra], capsys) == message


def test_plot_line_position_geometry(tmp_path, capsys, plt):
    figure = tmp_path / "p.png"
    assert (
        post_main(
            [
                "plot",
                str(_positions(tmp_path)),
                "geometry",
                "--time",
                "0.5",
                "--plane",
                "3d",
                "--output",
                str(figure),
            ]
        )
        == 0
    )
    assert capsys.readouterr().out.strip() == str(figure.resolve())
    assert figure.stat().st_size > 0


@pytest.mark.parametrize(
    ("extra", "message"),
    [
        (["Curvature"], "dynamic line-tension output supports channel 'Tension'"),
        (["Tension", "--line", "1"], "--line does not apply to an already selected per-line file"),
        (
            ["range", "--time", "1", "--start", "0"],
            "--time cannot be combined with --start or --stop",
        ),
        (
            ["range", "--time", "1", "--stop", "2"],
            "--time cannot be combined with --start or --stop",
        ),
    ],
)
def test_plot_line_tension_rejections(tmp_path, capsys, plt, extra, message):
    assert _plot_fails([str(_tensions(tmp_path)), *extra], capsys) == message


@pytest.mark.parametrize("extra", [["Range", "--time", "0.5"], ["TENSION", "--start", "1"]])
def test_plot_line_tension_range_and_envelope(tmp_path, capsys, plt, extra):
    figure = tmp_path / "t.png"
    assert post_main(["plot", str(_tensions(tmp_path)), *extra, "--output", str(figure)]) == 0
    assert capsys.readouterr().out.strip() == str(figure.resolve())
    assert figure.stat().st_size > 0


def test_plot_time_history_rejects_time_and_plain_tables(tmp_path, capsys, plt):
    assert _plot_fails([str(_history(tmp_path)), "FairTen1", "--time", "1"], capsys) == (
        "--time is valid only for a dynamic per-line output"
    )
    assert _plot_fails([str(_plain(tmp_path)), "X"], capsys) == (
        "plotting requires a time history or static profile"
    )


def test_plot_refuses_to_overwrite_without_the_flag(tmp_path, capsys, plt):
    source = str(_history(tmp_path))
    figure = tmp_path / "figure.png"
    figure.write_bytes(b"existing figure")
    assert "already exists" in _fails(["plot", source, "FairTen1", "--output", str(figure)], capsys)
    assert figure.read_bytes() == b"existing figure"
    assert post_main(["plot", source, "FairTen1", "--output", str(figure), "--overwrite"]) == 0
    assert figure.read_bytes() != b"existing figure"


def test_plot_without_output_shows_the_figure(tmp_path, capsys, plt, monkeypatch):
    shown: list[tuple[str, str]] = []

    def show() -> None:
        ax = plt.gca()
        shown.append((ax.get_xlabel(), ax.get_ylabel()))

    monkeypatch.setattr(plt, "show", show)
    assert (
        post_main(["plot", str(_history(tmp_path)), "FairTen1", "--start", "1", "--stop", "2"]) == 0
    )
    assert shown == [("Time [s]", "FairTen1 [N]")]
    assert capsys.readouterr().out == ""
