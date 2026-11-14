# SPDX-License-Identifier: Apache-2.0
"""Unit gates for the standalone executable wrapper and table parser."""

from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    CableDynDriver,
    DriverExecutionError,
    DriverNotFoundError,
    LineNodeHistory,
    LineSegmentHistory,
    OutputFormatError,
    StaticProfile,
    TimeHistory,
    read_output,
)


def test_import_and_driver_discovery_do_not_require_shared_library(tmp_path, monkeypatch):
    monkeypatch.delenv("CABLEDYN_DRIVER", raising=False)
    with pytest.raises(DriverNotFoundError):
        CableDynDriver(tmp_path / "missing-driver")


def test_explicit_bare_executable_resolves_from_current_directory(tmp_path, monkeypatch):
    executable = tmp_path / "local-driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    monkeypatch.chdir(tmp_path)
    assert CableDynDriver("local-driver").executable == executable.resolve()


def test_read_main_output_without_units(tmp_path):
    path = tmp_path / "run.out"
    path.write_text(
        "# CableDyn driver output (static IC; converged=T)\n"
        "Time(s)\tFairTen1\n"
        "0.0 1.2D+06\n0.1 1.3E+06\n",
        encoding="ascii",
    )
    table = read_output(path)
    assert isinstance(table, TimeHistory)
    assert table.channels == ("Time(s)", "FairTen1")
    assert table.units is None
    assert np.allclose(table.column("FairTen1"), [1.2e6, 1.3e6])
    with pytest.raises(ValueError):
        table.values[0, 0] = 4.0


def test_read_static_output_with_units(tmp_path):
    path = tmp_path / "run.static.out"
    path.write_text(
        "CableDyn static profile\nLineID Node ArcLength\n(-) (-) (m)\n1 1 0.0\n1 2 2.5\n",
        encoding="ascii",
    )
    table = read_output(path)
    assert isinstance(table, StaticProfile)
    assert table.units == ("(-)", "(-)", "(m)")
    assert table.values.shape == (2, 3)


@pytest.mark.parametrize(
    ("header", "row", "channels"),
    [
        ("Node X(m) Y(m) Z(m)", "1 0.0 1.0 -2.0", ("Node", "X(m)", "Y(m)", "Z(m)")),
        ("Segment Tension(N)", "1 2.5E+05", ("Segment", "Tension(N)")),
    ],
)
def test_read_static_per_line_outputs(tmp_path, header, row, channels):
    path = tmp_path / "run.Line1.p.out"
    path.write_text(f"# static per-line output\n{header}\n{row}\n", encoding="ascii")
    table = read_output(path)
    assert table.channels == channels
    assert table.values.shape == (1, len(channels))


@pytest.mark.parametrize(
    "body",
    [
        "Title\nTime(s) A B\n0 1\n",
        "Title\nTime(s) A\n0 ********\n",
        "Title\nTime(s) A\n0 NaN\n",
        "Title only\n0 1\n",
    ],
)
def test_read_output_rejects_malformed_tables(tmp_path, body):
    path = tmp_path / "bad.out"
    path.write_text(body, encoding="ascii")
    with pytest.raises(OutputFormatError):
        read_output(path)


def test_run_uses_deck_directory_and_validates_output(tmp_path, monkeypatch):
    executable = tmp_path / "CableDyn_driver.exe"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck_dir = tmp_path / "case"
    deck_dir.mkdir()
    deck = deck_dir / "model.dat"
    deck.write_text("deck", encoding="ascii")
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"] = command
        seen["cwd"] = kwargs["cwd"]
        Path(f"{command[2]}.out").write_text(
            "CableDyn output\nTime(s) FairTen1\n0 100\n", encoding="ascii"
        )
        Path(f"{command[2]}.static.out").write_text(
            "Profile\nLineID Node ArcLength\n(-) (-) (m)\n1 1 0\n", encoding="ascii"
        )
        return subprocess.CompletedProcess(command, 0, "completed\n", "banner\n")

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = CableDynDriver(executable).run(deck, "results/run")
    assert seen["cwd"] == deck_dir
    assert seen["command"][0] == str(executable.resolve())
    assert result.read_main().column("FairTen1")[0] == 100
    assert result.read_static().channels == ("LineID", "Node", "ArcLength")


def test_driver_result_discovers_and_reads_typed_line_histories(tmp_path):
    root = tmp_path / "run"
    main = tmp_path / "run.out"
    main.write_text("Time(s) A\n0 1\n", encoding="ascii")
    positions = tmp_path / "run.Line4.p.out"
    positions.write_text("Time(s) Node1X(m) Node1Y(m) Node1Z(m)\n0 1 2 3\n", encoding="ascii")
    tensions = tmp_path / "run.Line4.t.out"
    tensions.write_text("Time(s) Segment1Tension(N)\n0 100\n", encoding="ascii")
    from cabledyn.driver import DriverResult

    result = DriverResult(
        executable=tmp_path / "driver",
        deck=tmp_path / "model.dat",
        output_root=root,
        main_output=main,
        static_output=None,
        elements_output=None,
        line_outputs=(positions, tensions),
        rod_outputs=(),
        stdout="",
        stderr="",
        returncode=0,
    )
    assert result.line_ids == (4,)
    assert isinstance(result.read_line_positions(4), LineNodeHistory)
    assert isinstance(result.read_line_tensions(4), LineSegmentHistory)
    with pytest.raises(FileNotFoundError, match="Line 5"):
        result.read_line_positions(5)


def test_relative_deck_resolves_against_explicit_working_directory(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    case_dir = tmp_path / "case"
    case_dir.mkdir()
    deck = case_dir / "model.dat"
    deck.write_text("deck", encoding="ascii")
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"] = command
        Path(f"{command[2]}.out").write_text("CableDyn output\nTime(s) A\n0 1\n", encoding="ascii")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = CableDynDriver(executable).run("model.dat", "run", cwd=case_dir)
    assert seen["command"][1] == str(deck.resolve())
    assert result.deck == deck.resolve()
    assert result.output_root == (case_dir / "run").resolve()


def test_run_refuses_existing_outputs_unless_overwrite(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")
    old = tmp_path / "run.out"
    old.write_text("old", encoding="ascii")
    old_rod = tmp_path / "run.Rod4.p.out"
    old_rod.write_text("old rod result", encoding="ascii")

    driver = CableDynDriver(executable)
    with pytest.raises(FileExistsError):
        driver.run(deck, "run")

    def fake_run(command, **kwargs):
        Path(f"{command[2]}.out").write_text("CableDyn output\nTime(s) A\n0 1\n", encoding="ascii")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    assert driver.run(deck, "run", overwrite=True).main_output.is_file()
    assert not old_rod.exists()


def test_auxiliary_protection_treats_output_stem_literally(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")
    old_line = tmp_path / "case[1].Line2.p.out"
    old_line.write_text("old line result", encoding="ascii")
    driver = CableDynDriver(executable)

    with pytest.raises(FileExistsError):
        driver.run(deck, "case[1]")

    def fake_run(command, **kwargs):
        Path(f"{command[2]}.out").write_text("CableDyn output\nTime(s) A\n0 1\n", encoding="ascii")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = driver.run(deck, "case[1]", overwrite=True)
    assert not old_line.exists()
    assert result.line_outputs == ()


def test_nonzero_exit_preserves_native_diagnostic(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 2, "", "Newton failed"),
    )
    with pytest.raises(DriverExecutionError) as caught:
        CableDynDriver(executable).run(deck, "run")
    assert caught.value.returncode == 2
    assert "Newton failed" in str(caught.value)


_CLOSING = "CableDyn_driver: ended with exit code 2\n"
# The start-up line of a driver that writes the closing line on every failure.
_CONTRACT = (
    "  Exit status: every non-zero exit the driver makes itself ends stderr with "
    '"CableDyn_driver: ended with exit code <n>".\n'
)
_PARTIAL_TABLE = "# CableDyn\nTime\tFairTen1\n0.0\t1.0\n7534.6\t2.0\n7534.65\t2."


@pytest.mark.parametrize(
    ("returncode", "stderr", "table", "expected"),
    [
        # An exit the driver chose: its closing line ends stderr.
        (
            2,
            "  init\nstep 12 did not converge\n" + _CLOSING,
            None,
            "failed with exit code 2: init\nstep 12 did not converge",
        ),
        # An interrupt or a fault the driver reported, with the time its output reached.
        (
            3221225725,
            "  init\n\nCableDyn_driver: fatal error: stack overflow (exception 0xC00000FD) after "
            "the step at simulated time t = 7534.600 s. The run did not finish; its output "
            "files end at the last step written.\n",
            _PARTIAL_TABLE,
            "ended abnormally (exit code 3221225725); its output ends at t = 7534.6 s: "
            "CableDyn_driver: fatal error: stack overflow",
        ),
        # The report followed by the runtime's own lines: the release executable's Ctrl+Break
        # (forrtl, exit 1) and a GNU access violation (the libgfortran backtrace).
        (
            1,
            _CONTRACT + "\nCableDyn_driver: stopped by Ctrl+Break after the step at simulated "
            "time t = 97.400 s. The run did not finish; its output files end at the last step "
            "written.\nforrtl: error (200): program aborting due to control-BREAK event\n"
            "Image              PC                Routine            Line        Source\n",
            _PARTIAL_TABLE,
            "ended abnormally (exit code 1); its output ends at t = 7534.6 s: "
            "CableDyn_driver: stopped by Ctrl+Break after the step at simulated time t = 97.400 s",
        ),
        # The same when the runtime's traceback meets output in progress (forrtl 152): the
        # driver's own report wins over the runtime's lines.
        (
            152,
            _CONTRACT + "\nCableDyn_driver: stopped by Ctrl+Break after the step at simulated "
            "time t = 2076.000 s. The run did not finish; its output files end at the last step "
            "written.\nforrtl: error (200): program aborting due to control-BREAK event\n"
            "forrtl: severe (152): unresolved contention for Intel Fortran RTL global resource\n",
            None,
            "ended abnormally (exit code 152): CableDyn_driver: stopped by Ctrl+Break",
        ),
        (
            3,
            _CONTRACT + "\nCableDyn_driver: fatal error: access violation (exception 0xC0000005) "
            "after the step at simulated time t = 12.000 s. The run did not finish; its output "
            "files end at the last step written.\n\nProgram received signal SIGSEGV: "
            "Segmentation fault - invalid memory reference.\n\nBacktrace for this error:\n",
            None,
            "ended abnormally (exit code 3): CableDyn_driver: fatal error: access violation",
        ),
        # Ended from outside (taskkill /F): the driver stated the exit contract, then wrote
        # no closing line and no report.
        (
            1,
            _CONTRACT + "  CableDyn initialization completed.\n",
            _PARTIAL_TABLE,
            "initialization completed.\nCableDyn driver ended with exit code 1 without "
            "reporting a result; its output ends at t = 7534.6 s: the process was ended from "
            "outside",
        ),
        # The same with no output table yet.
        (
            -9,
            _CONTRACT,
            None,
            "ended with exit code -9 without reporting a result: the process",
        ),
        # A driver older than the exit contract (0.1.0) writes no closing line on its own
        # refusals: they are reported with their own text, never as ended from outside.
        (
            1,
            "  CableDyn  v0.1.0\nCableDyn_DeckDriver: deck line 42: bad value\n",  # past-release
            _PARTIAL_TABLE,
            "failed with exit code 1; its output ends at t = 7534.6 s: "
            "CableDyn  v0.1.0\n"  # past-release
            "CableDyn_DeckDriver: deck line 42: bad value",
        ),
        (2, "", None, "failed with exit code 2: Progress:  65.0%"),
        # The Fortran runtime ended the run with its own error: never read as an outside end.
        (
            41,
            _CONTRACT + "forrtl: severe (41): insufficient virtual memory\n",
            _PARTIAL_TABLE,
            "ended with a Fortran runtime error (exit code 41); its output ends at t = 7534.6 s: "
            "forrtl: severe (41): insufficient virtual memory",
        ),
        (
            2,
            _CONTRACT + "Operating system error: Not enough space\nError allocating 8 bytes\n",
            None,
            "ended with a Fortran runtime error (exit code 2): Error allocating 8 bytes",
        ),
    ],
)
def test_nonzero_exit_tells_driver_failures_from_abnormal_ends(
    tmp_path, monkeypatch, returncode, stderr, table, expected
):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")

    def fake_run(*args, **kwargs):
        if table is not None:
            (tmp_path / "run.out").write_bytes(table.encode("ascii"))
        return subprocess.CompletedProcess(args[0], returncode, "  Progress:  65.0%\n", stderr)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(DriverExecutionError) as caught:
        CableDynDriver(executable).run(deck, "run")
    assert caught.value.returncode == returncode
    assert expected in str(caught.value)
    assert caught.value.stderr == stderr
    assert ("ended from outside" in str(caught.value)) == ("without reporting" in expected)


@pytest.mark.parametrize(
    ("content", "window", "expected"),
    [
        (b"Time\ta\n0.0\t1\n0.5\t2\n", 1 << 20, 0.5),
        (b"Time\ta\n0.0\t1\n0.5\t2\n1.0\t", 1 << 20, 0.5),  # last row cut short
        (b"Time\ta\n0.0\t1\nnan\t2\n", 1 << 20, None),
        (b"Time\ta\n0.0\t1\nq\t2\n", 1 << 20, None),
        (b"Time\ta\n\n", 1 << 20, None),
        # The window starts inside a row: that row is not trusted, the next whole one is.
        (b"Time\ta\n123456.0\t1\n2.0\t2\n", 10, 2.0),
        (b"Time\ta\n123456.0\t1\n", 10, None),
    ],
)
def test_last_output_time_reads_only_whole_rows(tmp_path, content, window, expected):
    from cabledyn.driver import _last_output_time

    path = tmp_path / "run.out"
    path.write_bytes(content)
    assert _last_output_time(path, window) == expected
    assert _last_output_time(tmp_path / "missing.out") is None


def test_element_table_is_protected_reported_and_replaced(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")
    stale = tmp_path / "run.elements.out"
    stale.write_text("precious user file", encoding="ascii")
    driver = CableDynDriver(executable)
    with pytest.raises(FileExistsError):
        driver.run(deck, "run")
    assert stale.read_text(encoding="ascii") == "precious user file"

    def fake_run(command, **kwargs):
        Path(f"{command[2]}.out").write_text("Time(s) A\n0 1\n", encoding="ascii")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = driver.run(deck, "run", overwrite=True)
    assert not stale.exists()
    assert result.elements_output is None


def test_environment_override_replaces_windows_names_case_insensitively(monkeypatch):
    from cabledyn import driver as driver_module

    monkeypatch.setattr(driver_module.os, "name", "nt")
    monkeypatch.setattr(driver_module.os, "environ", {"PATH": "inherited", "OTHER": "kept"})
    merged = driver_module._merged_environment({"Path": "override"})
    assert merged == {"Path": "override", "OTHER": "kept"}


def test_undecodable_native_output_is_replaced_not_fatal(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")
    seen = {}

    def fake_run(command, **kwargs):
        seen.update(kwargs)
        Path(f"{command[2]}.out").write_text("Time(s) A\n0 1\n", encoding="ascii")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    CableDynDriver(executable).run(deck, "run")
    assert seen["encoding"] == "utf-8"
    assert seen["errors"] == "replace"


def test_zero_exit_malformed_output_preserves_native_streams(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")

    def fake_run(command, **kwargs):
        Path(f"{command[2]}.out").write_text("Time(s) FairTen1\n0 overflow\n", encoding="ascii")
        return subprocess.CompletedProcess(
            command, 0, "native standard output\n", "native warning\n"
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(DriverExecutionError, match="invalid main output") as caught:
        CableDynDriver(executable).run(deck, "run")
    assert caught.value.returncode == 0
    assert caught.value.stdout == "native standard output\n"
    assert caught.value.stderr == "native warning\n"


def test_timeout_captures_are_always_text(tmp_path, monkeypatch):
    executable = tmp_path / "driver"
    executable.write_bytes(b"placeholder")
    executable.chmod(0o755)
    deck = tmp_path / "model.dat"
    deck.write_text("deck", encoding="ascii")

    def fake_timeout(command, **kwargs):
        raise subprocess.TimeoutExpired(
            command, 1.0, output=b"partial output\xff", stderr=b"native diagnostic"
        )

    monkeypatch.setattr(subprocess, "run", fake_timeout)
    with pytest.raises(DriverExecutionError) as caught:
        CableDynDriver(executable).run(deck, "run", timeout=1.0)
    assert isinstance(caught.value.stdout, str)
    assert isinstance(caught.value.stderr, str)
    assert caught.value.stdout == "partial output\ufffd"
    assert caught.value.stderr == "native diagnostic"
