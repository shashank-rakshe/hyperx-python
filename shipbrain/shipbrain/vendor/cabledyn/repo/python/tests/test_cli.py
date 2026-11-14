# SPDX-License-Identifier: Apache-2.0
"""Command-line and child-process gates for cabledyn-run, cabledyn-study, and cabledyn-deck."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from cabledyn import (
    CableDynDriver,
    DeckFile,
    DriverExecutionError,
    StudyOutputError,
    deck_cli,
    generate_deck_cases,
    run_study,
    study_cli,
)
from cabledyn import cli as run_cli
from cabledyn import study as study_module

ROOT = Path(__file__).resolve().parents[2]
CHAIN = ROOT / "examples" / "chain_catenary_r3_100m.dat"


# ---------------------------------------------------------------------------
# CableDynDriver against a real child process
# ---------------------------------------------------------------------------


def test_driver_runs_a_real_child_process_in_the_deck_directory(fake_driver, deck):
    result = CableDynDriver(fake_driver).run(deck, "results/base", timeout=60)
    assert result.returncode == 0
    assert result.main_output == deck.parent / "results" / "base.out"
    assert result.static_output == deck.parent / "results" / "base.static.out"
    assert "fake run complete" in result.stdout
    history = result.read_main()
    assert history.channels == ("Time(s)", "FairTen1", "AnchTen1")
    assert history.values.shape == (201, 3)
    assert result.read_static().line_ids == (1,)
    log = (deck.parent / "results" / "argv.log").read_text(encoding="utf-8")
    working_directory, deck_argument, _ = log.strip().split("|")
    assert Path(working_directory) == deck.parent
    assert Path(deck_argument) == deck


def test_driver_version_reads_the_banner_and_reports_failures(fake_driver, monkeypatch):
    driver = CableDynDriver(fake_driver)
    assert driver.version() == "CableDyn_driver fake 0.0.0"
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", "bad-version")
    with pytest.raises(DriverExecutionError, match="exit code 4") as caught:
        driver.version()
    assert caught.value.returncode == 4
    assert "broken" in caught.value.stderr


@pytest.mark.parametrize("timeout", [0.0, -1.0, float("inf"), float("nan"), True, "soon"])
def test_driver_rejects_invalid_timeouts_before_starting(fake_driver, deck, timeout):
    driver = CableDynDriver(fake_driver)
    with pytest.raises(ValueError, match="timeout must be finite and positive"):
        driver.run(deck, "base", timeout=timeout)
    with pytest.raises(ValueError, match="timeout must be finite and positive"):
        driver.version(timeout=timeout)
    assert not (deck.parent / "argv.log").exists()


def test_driver_version_requires_a_timeout(fake_driver):
    with pytest.raises(ValueError, match="timeout"):
        CableDynDriver(fake_driver).version(timeout=None)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("mode", "message"),
    [
        ("fail", "exit code 3: CableDyn_driver: deck line 3: synthetic failure"),
        ("partial-fail", "exit code 3"),
        ("no-output", "did not create"),
        ("bad-output", "invalid main output"),
    ],
)
def test_failed_overwrite_restores_the_previous_results(
    fake_driver, deck, monkeypatch, mode, message
):
    driver = CableDynDriver(fake_driver)
    first = driver.run(deck, "base")
    previous = {path.name: path.read_bytes() for path in deck.parent.glob("base*.out")}
    assert set(previous) == {"base.out", "base.static.out"}
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", mode)
    with pytest.raises(DriverExecutionError, match=message):
        driver.run(deck, "base", overwrite=True)
    restored = {path.name: path.read_bytes() for path in deck.parent.glob("base*.out")}
    assert restored == previous
    assert first.read_main().values.shape == (201, 3)
    assert not list(deck.parent.glob(".base.previous-*"))


def test_successful_overwrite_replaces_and_removes_stale_auxiliary_files(
    fake_driver, deck, monkeypatch
):
    driver = CableDynDriver(fake_driver)
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", "lines")
    lines = driver.run(deck, "base")
    assert lines.line_ids == (1,)
    assert lines.read_line_positions(1).values.shape == (2, 7)
    assert lines.read_line_tensions(1).values.shape == (2, 2)
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", "ok")
    rerun = driver.run(deck, "base", overwrite=True)
    assert rerun.line_outputs == ()
    assert not (deck.parent / "base.Line1.p.out").exists()
    assert not list(deck.parent.glob(".base.previous-*"))


_LIFT_RANGE_MODES = ("base.Line1.V.out", "base.Line2.range.out", "base.modes.out")


def test_failed_overwrite_restores_lift_range_and_modal_outputs(fake_driver, deck, monkeypatch):
    driver = CableDynDriver(fake_driver)
    driver.run(deck, "base")
    previous = {}
    for name in _LIFT_RANGE_MODES:
        (deck.parent / name).write_text(f"previous {name}\n", encoding="ascii")
        previous[name] = (deck.parent / name).read_bytes()

    def fails_after_writing(*args, **kwargs):
        # the run writes partial lift, range and modal files over the previous ones, then fails
        for name in _LIFT_RANGE_MODES:
            (deck.parent / name).write_text("partial", encoding="ascii")
        return subprocess.CompletedProcess(args[0], 3, "", "CableDyn_driver: synthetic failure")

    monkeypatch.setattr(subprocess, "run", fails_after_writing)
    with pytest.raises(DriverExecutionError):
        driver.run(deck, "base", overwrite=True)
    assert {name: (deck.parent / name).read_bytes() for name in _LIFT_RANGE_MODES} == previous
    assert not list(deck.parent.glob(".base.previous-*"))


def test_successful_overwrite_removes_stale_lift_range_and_modal_outputs(
    fake_driver, deck, monkeypatch
):
    driver = CableDynDriver(fake_driver)
    driver.run(deck, "base")
    for name in _LIFT_RANGE_MODES:
        (deck.parent / name).write_text(f"previous {name}\n", encoding="ascii")
    driver.run(deck, "base", overwrite=True)
    assert not [name for name in _LIFT_RANGE_MODES if (deck.parent / name).exists()]
    assert not list(deck.parent.glob(".base.previous-*"))


def test_interrupted_overwrite_restores_previous_results(fake_driver, deck, monkeypatch):
    driver = CableDynDriver(fake_driver)
    driver.run(deck, "base")
    before = (deck.parent / "base.out").read_bytes()

    def interrupted(*args, **kwargs):
        Path(f"{deck.parent / 'base'}.out").write_text("partial", encoding="ascii")
        raise KeyboardInterrupt

    monkeypatch.setattr(subprocess, "run", interrupted)
    with pytest.raises(KeyboardInterrupt):
        driver.run(deck, "base", overwrite=True)
    assert (deck.parent / "base.out").read_bytes() == before


def test_run_timeout_is_forwarded_as_a_float(tmp_path, deck, monkeypatch, fake_driver):
    seen = {}

    def fake_run(command, **kwargs):
        seen.update(kwargs)
        raise subprocess.TimeoutExpired(command, kwargs["timeout"], output=None, stderr=b"late")

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(DriverExecutionError, match=r"2.5 s timeout") as caught:
        CableDynDriver(fake_driver).run(deck, "base", timeout=2.5)
    assert seen["timeout"] == 2.5
    assert caught.value.stderr == "late"
    assert caught.value.stdout == ""


def test_run_validates_paths(fake_driver, deck, tmp_path):
    driver = CableDynDriver(fake_driver)
    with pytest.raises(NotADirectoryError):
        driver.run(deck, "base", cwd=tmp_path / "missing")
    with pytest.raises(FileNotFoundError):
        driver.run(tmp_path / "missing.dat", "base")
    with pytest.raises(ValueError, match="file stem"):
        driver.run(deck, ".")
    with pytest.raises(ValueError, match=r"omit the .out"):
        driver.run(deck, "base.out")


def test_driver_discovery_uses_environment_then_path(fake_driver, monkeypatch, tmp_path):
    monkeypatch.setenv("CABLEDYN_DRIVER", str(fake_driver))
    assert CableDynDriver().executable == fake_driver.resolve()
    monkeypatch.delenv("CABLEDYN_DRIVER")
    monkeypatch.setattr(
        "shutil.which", lambda name: str(fake_driver) if name == "cabledyn" else None
    )
    assert CableDynDriver().executable == fake_driver.resolve()


def test_driver_result_line_helpers_validate_requests(fake_driver, deck, monkeypatch):
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", "lines")
    result = CableDynDriver(fake_driver).run(deck, "base")
    for bad in (0, -1, True, 1.5):
        with pytest.raises(ValueError, match="positive integer"):
            result.read_line_positions(bad)  # type: ignore[arg-type]
    with pytest.raises(FileNotFoundError, match="Line 2"):
        result.read_line_tensions(2)
    no_static = type(result)(**{**result.__dict__, "static_output": None})
    with pytest.raises(FileNotFoundError, match="static"):
        no_static.read_static()


# ---------------------------------------------------------------------------
# cabledyn-run
# ---------------------------------------------------------------------------


def test_cabledyn_run_prints_the_main_output(fake_driver, deck, capsys):
    assert (
        run_cli.main([str(deck), "run1", "--executable", str(fake_driver), "--timeout", "60"]) == 0
    )
    assert capsys.readouterr().out.strip() == str(deck.parent / "run1.out")


@pytest.mark.parametrize(
    "arguments",
    [
        ["--timeout", "0"],
        ["--timeout", "nan"],
        ["--timeout", "-5"],
    ],
)
def test_cabledyn_run_rejects_bad_timeouts(fake_driver, deck, capsys, arguments):
    with pytest.raises(SystemExit) as caught:
        run_cli.main([str(deck), "run1", "--executable", str(fake_driver), *arguments])
    assert caught.value.code == 1
    assert "timeout must be finite and positive" in capsys.readouterr().err


def test_cabledyn_run_reports_native_failures_and_existing_outputs(
    fake_driver, deck, capsys, monkeypatch
):
    assert run_cli.main([str(deck), "run1", "--executable", str(fake_driver)]) == 0
    with pytest.raises(SystemExit) as caught:
        run_cli.main([str(deck), "run1", "--executable", str(fake_driver)])
    assert caught.value.code == 1
    assert "already exist" in capsys.readouterr().err
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", "fail")
    with pytest.raises(SystemExit) as caught:
        run_cli.main([str(deck), "run1", "--executable", str(fake_driver), "--overwrite"])
    assert caught.value.code == 1
    assert "synthetic failure" in capsys.readouterr().err
    assert (deck.parent / "run1.out").is_file()


def test_cabledyn_run_reports_a_missing_executable(deck, tmp_path, capsys):
    with pytest.raises(SystemExit) as caught:
        run_cli.main([str(deck), "run1", "--executable", str(tmp_path / "missing.exe")])
    assert caught.value.code == 1
    assert "could not locate CableDyn_driver" in capsys.readouterr().err


def test_console_scripts_run_as_modules(fake_driver, deck):
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "cabledyn.cli",
            str(deck),
            "module_run",
            "--executable",
            str(fake_driver),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip().endswith("module_run.out")


# ---------------------------------------------------------------------------
# cabledyn-study
# ---------------------------------------------------------------------------


def _manifest(tmp_path: Path, names=("case_a", "case_b")) -> Path:
    source = tmp_path / "source.dat"
    source.write_text("source deck\n", encoding="ascii")
    rows = []
    for name in names:
        deck = tmp_path / f"{name}.dat"
        deck.write_text(f"generated {name}\n", encoding="ascii")
        rows.append(
            {
                "name": name,
                "deck": str(deck),
                "sha256": hashlib.sha256(deck.read_bytes()).hexdigest(),
            }
        )
    manifest = tmp_path / "cases.json"
    manifest.write_text(
        json.dumps(
            {
                "schema": "cabledyn-deck-cases-v1",
                "source": str(source),
                "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "cases": rows,
            }
        ),
        encoding="utf-8",
    )
    return manifest


def test_cabledyn_study_success_with_a_real_child_process(fake_driver, tmp_path, capsys):
    manifest = _manifest(tmp_path)
    code = study_cli.main(
        [
            str(manifest),
            "--executable",
            str(fake_driver),
            "--jobs",
            "2",
            "--channel",
            "FairTen1",
            "--start",
            "1",
            "--stop",
            "9",
            "--timeout",
            "120",
        ]
    )
    assert code == 0
    out = capsys.readouterr().out
    assert "case_a: completed" in out and "case_b: completed" in out
    record = json.loads((tmp_path / "study-results" / "study.json").read_text(encoding="utf-8"))
    assert record["solver_version"] == "CableDyn_driver fake 0.0.0"
    assert record["period"] == {"start": 1.0, "stop": 9.0}
    assert [case["status"] for case in record["cases"]] == ["completed", "completed"]


def test_cabledyn_study_failed_case_exits_one(fake_driver, tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("FAKE_CABLEDYN_MODE", "fail")
    manifest = _manifest(tmp_path, names=("only",))
    assert study_cli.main([str(manifest), "--executable", str(fake_driver)]) == 1
    out = capsys.readouterr().out
    assert "only: failed: CableDyn driver failed with exit code 3" in out
    assert (tmp_path / "study-results" / "only.stderr.log").read_text(
        encoding="utf-8"
    ).strip().splitlines() == [
        "CableDyn_driver: deck line 3: synthetic failure",
        "CableDyn_driver: ended with exit code 3",
    ]


def test_cabledyn_study_preflight_errors_exit_two(fake_driver, tmp_path, capsys):
    manifest = _manifest(tmp_path)
    Path(tmp_path / "case_a.dat").write_text("tampered\n", encoding="ascii")
    with pytest.raises(SystemExit) as caught:
        study_cli.main([str(manifest), "--executable", str(fake_driver)])
    assert caught.value.code == 2
    assert "SHA-256" in capsys.readouterr().err
    assert not (tmp_path / "study-results").exists()


def test_cabledyn_study_artifact_write_failure_exits_three(
    fake_driver, tmp_path, capsys, monkeypatch
):
    manifest = _manifest(tmp_path, names=("only",))

    def full_disk(*args, **kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(study_module, "_write_summary", full_disk)
    with pytest.raises(SystemExit) as caught:
        study_cli.main([str(manifest), "--executable", str(fake_driver)])
    assert caught.value.code == 3
    err = capsys.readouterr().err
    assert "cases ran but" in err and "summary.csv" in err
    assert (tmp_path / "study-results" / "only.out").is_file()


def test_study_manifest_write_failure_raises_study_output_error(fake_driver, tmp_path, monkeypatch):
    manifest = _manifest(tmp_path, names=("only",))
    original = study_module._atomic_text

    def failing(path, text):
        if path.name == "study.json":
            raise PermissionError(13, "locked")
        original(path, text)

    monkeypatch.setattr(study_module, "_atomic_text", failing)
    with pytest.raises(StudyOutputError, match=r"study.json") as caught:
        run_study(manifest, executable=fake_driver)
    assert isinstance(caught.value, OSError)
    assert (tmp_path / "study-results" / "summary.csv").is_file()


def test_summary_writer_cleans_up_its_temporary_file(tmp_path, monkeypatch):
    target = tmp_path / "summary.csv"

    def broken(*args, **kwargs):
        raise OSError("replace failed")

    monkeypatch.setattr(study_module.os, "replace", broken)
    with pytest.raises(OSError, match="replace failed"):
        study_module._write_summary(target, ("a",), [{"a": 1}])
    assert list(tmp_path.iterdir()) == []


# ---------------------------------------------------------------------------
# cabledyn-deck
# ---------------------------------------------------------------------------


def test_cabledyn_deck_validate_show_set_and_generate(tmp_path, capsys):
    assert deck_cli.main(["validate", str(CHAIN)]) == 0
    assert "valid:" in capsys.readouterr().out
    assert deck_cli.main(["show", str(CHAIN)]) == 0
    shown = capsys.readouterr().out
    assert "line_types: 1" in shown and "outputs:" in shown
    edited = tmp_path / "edited.dat"
    assert deck_cli.main(["set", str(CHAIN), str(edited), "point.2.z", "-1e-3"]) == 0
    assert DeckFile.read(edited).points[1].tokens[4] == "-0.001"
    spec = tmp_path / "spec.json"
    spec.write_text(json.dumps({"soft": {"option.kBot": 1.0e5}}), encoding="utf-8")
    assert deck_cli.main(["generate", str(CHAIN), str(spec), str(tmp_path / "cases")]) == 0
    assert capsys.readouterr().out.strip().endswith("soft.dat")


def test_cabledyn_deck_set_refuses_to_replace_its_source(tmp_path, capsys):
    source = tmp_path / "base.dat"
    source.write_bytes(CHAIN.read_bytes())
    before = source.read_bytes()
    with pytest.raises(SystemExit) as caught:
        deck_cli.main(["set", str(source), str(source), "option.kBot", "2e5", "--overwrite"])
    assert caught.value.code == 1
    assert "must not replace the source deck" in capsys.readouterr().err
    link = tmp_path / "alias.dat"
    try:
        os.link(source, link)
    except OSError:
        pytest.skip("hard links are not supported here")
    with pytest.raises(SystemExit):
        deck_cli.main(["set", str(source), str(link), "option.kBot", "2e5", "--overwrite"])
    assert source.read_bytes() == before


def test_generate_refuses_a_hard_link_alias_of_the_source(tmp_path):
    output = tmp_path / "cases"
    output.mkdir()
    source = output / "base.dat"
    source.write_bytes(CHAIN.read_bytes())
    try:
        os.link(source, output / "alias.dat")
    except OSError:
        pytest.skip("hard links are not supported here")
    with pytest.raises(ValueError, match="must not replace the source deck"):
        generate_deck_cases(source, output, {"alias": {"option.kBot": 2.0e5}}, overwrite=True)


@pytest.mark.parametrize(
    ("arguments", "message"),
    [
        (["set", "{deck}", "{out}", "point.2.z", "null"], "not null or an object"),
        (["set", "{deck}", "{out}", "nonsense", "1"], "unsupported deck selector"),
        (["generate", "{deck}", "{spec}", "{out}"], "duplicate key"),
        (["generate", "{deck}", "{list_spec}", "{out}"], "case spec must map"),
    ],
)
def test_cabledyn_deck_reports_errors(tmp_path, capsys, arguments, message):
    spec = tmp_path / "spec.json"
    spec.write_text('{"a": {"option.kBot": 1}, "a": {"option.kBot": 2}}', encoding="utf-8")
    list_spec = tmp_path / "list.json"
    list_spec.write_text('{"a": [1]}', encoding="utf-8")
    values = {
        "deck": str(CHAIN),
        "out": str(tmp_path / "out.dat"),
        "spec": str(spec),
        "list_spec": str(list_spec),
    }
    with pytest.raises(SystemExit) as caught:
        deck_cli.main([item.format(**values) for item in arguments])
    assert caught.value.code == 1
    assert message in capsys.readouterr().err


# ---------------------------------------------------------------------------
# DriverResult readers and discovery edge cases
# ---------------------------------------------------------------------------


def _result(tmp_path: Path, **overrides):
    from cabledyn import DriverResult

    fields = {
        "executable": tmp_path / "driver",
        "deck": tmp_path / "deck.dat",
        "output_root": tmp_path / "run",
        "main_output": tmp_path / "run.out",
        "static_output": None,
        "elements_output": None,
        "line_outputs": (),
        "rod_outputs": (),
        "stdout": "",
        "stderr": "",
        "returncode": 0,
    }
    fields.update(overrides)
    return DriverResult(**fields)


def test_driver_result_rejects_tables_of_the_wrong_kind(tmp_path):
    from cabledyn import OutputFormatError

    static = tmp_path / "run.static.out"
    static.write_text("LineID Node ArcLength\n1 1 0\n", encoding="ascii")
    history = tmp_path / "run.out"
    history.write_text("Time(s) FairTen1\n0 1\n", encoding="ascii")
    with pytest.raises(OutputFormatError, match="not a time history"):
        _result(tmp_path, main_output=static).read_main()
    with pytest.raises(OutputFormatError, match="not a line profile"):
        _result(tmp_path, static_output=history).read_static()
    positions = tmp_path / "run.Line1.p.out"
    positions.write_text("Node X(m) Y(m)\n1 0 0\n", encoding="ascii")  # no Z(m)
    tensions = tmp_path / "run.Line1.t.out"
    tensions.write_text("Segment Force(N)\n1 5\n", encoding="ascii")  # no Tension(N)
    result = _result(tmp_path, line_outputs=(positions, tensions, tmp_path / "run.Rod1.p.out"))
    assert result.line_ids == (1,)
    with pytest.raises(OutputFormatError, match="expected a line-position output"):
        result.read_line_positions(1)
    with pytest.raises(OutputFormatError, match="expected a line-tension output"):
        result.read_line_tensions(1)
    duplicate = _result(tmp_path, line_outputs=(positions, tmp_path / "xrun.Line1.p.out"))
    with pytest.raises(OutputFormatError, match="multiple outputs"):
        duplicate.read_line_positions(1)


def test_driver_discovery_reports_every_candidate(monkeypatch):
    from cabledyn import DriverNotFoundError

    monkeypatch.delenv("CABLEDYN_DRIVER", raising=False)
    monkeypatch.setattr("shutil.which", lambda name: None)
    with pytest.raises(
        DriverNotFoundError, match="CABLEDYN_DRIVER, the bundled driver or PATH"
    ) as caught:
        CableDynDriver()
    assert "CableDyn_driver.exe" in str(caught.value) and "cabledyn" in str(caught.value)
    assert str(Path("bin") / "CableDyn_driver") in str(caught.value)


def _fake_driver(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("")
    path.chmod(0o755)
    return path


def test_bundled_driver_comes_before_path(monkeypatch, tmp_path):
    # a wheel's own driver (matching its bundled library) wins over one on PATH
    from cabledyn import driver as driver_module

    bundled = _fake_driver(tmp_path / "pkg" / "bin" / "CableDyn_driver.exe")
    on_path = _fake_driver(tmp_path / "path" / "CableDyn_driver.exe")
    monkeypatch.delenv("CABLEDYN_DRIVER", raising=False)
    monkeypatch.setattr(driver_module, "bundled_driver", lambda: bundled)
    monkeypatch.setattr("shutil.which", lambda name: str(on_path))
    assert driver_module._resolve_executable(None) == bundled
    # without a bundled driver, PATH is searched as before
    monkeypatch.setattr(
        driver_module, "bundled_driver", lambda: tmp_path / "missing" / "CableDyn_driver.exe"
    )
    assert driver_module._resolve_executable(None) == on_path.resolve()


def test_cabledyn_driver_variable_comes_before_the_bundled_driver(monkeypatch, tmp_path):
    from cabledyn import driver as driver_module

    bundled = _fake_driver(tmp_path / "pkg" / "bin" / "CableDyn_driver.exe")
    chosen = _fake_driver(tmp_path / "chosen" / "CableDyn_driver.exe")
    monkeypatch.setenv("CABLEDYN_DRIVER", str(chosen))
    monkeypatch.setattr(driver_module, "bundled_driver", lambda: bundled)
    assert driver_module._resolve_executable(None) == chosen.resolve()


def test_posix_environment_merge_keeps_case_distinct_names(monkeypatch):
    from cabledyn import driver as driver_module

    monkeypatch.setattr(driver_module.os, "name", "posix")
    monkeypatch.setattr(driver_module.os, "environ", {"PATH": "inherited"})
    assert driver_module._merged_environment({"Path": "override"}) == {
        "PATH": "inherited",
        "Path": "override",
    }


def test_environment_overrides_reach_the_child_process(fake_driver, deck):
    with pytest.raises(DriverExecutionError, match="synthetic failure"):
        CableDynDriver(fake_driver).run(deck, "envrun", env={"FAKE_CABLEDYN_MODE": "fail"})


def test_version_timeout_decodes_byte_captures(fake_driver, monkeypatch):
    def slow(command, **kwargs):
        raise subprocess.TimeoutExpired(
            command, kwargs["timeout"], output=b"partial \xff", stderr=None
        )

    monkeypatch.setattr(subprocess, "run", slow)
    with pytest.raises(DriverExecutionError, match="version query exceeded the 1 s") as caught:
        CableDynDriver(fake_driver).version(timeout=1.0)
    assert caught.value.stdout == "partial �"
    assert caught.value.stderr == ""


def test_bundled_driver_accepts_both_toolchain_names(tmp_path):
    from cabledyn import driver as driver_module

    suffix = ".exe" if os.name == "nt" else ""
    package = tmp_path / "cabledyn"
    assert driver_module.bundled_driver(package) == package / "bin" / f"CableDyn_driver{suffix}"
    gnu = _fake_driver(package / "bin" / f"cabledyn{suffix}")
    assert driver_module.bundled_driver(package) == gnu
    msvc = _fake_driver(package / "bin" / f"CableDyn_driver{suffix}")
    assert driver_module.bundled_driver(package) == msvc
