# SPDX-License-Identifier: Apache-2.0
"""Manifest, argument, log-writing, and interruption gates for run_study."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from cabledyn import StudyCaseResult, StudyFormatError, run_study
from cabledyn import study as study_module


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _manifest(tmp_path: Path, mutate=None, names=("case_a",)) -> Path:
    source = tmp_path / "source.dat"
    source.write_text("source\n", encoding="ascii")
    rows = []
    for name in names:
        deck = tmp_path / f"{name}.dat"
        deck.write_text(f"deck {name}\n", encoding="ascii")
        rows.append({"name": name, "deck": str(deck), "sha256": _digest(deck)})
    data = {
        "schema": "cabledyn-deck-cases-v1",
        "source": str(source),
        "source_sha256": _digest(source),
        "cases": rows,
    }
    if mutate is not None:
        mutate(data, tmp_path)
    path = tmp_path / "cases.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def _set(key, value):
    def mutate(data, tmp_path):
        data[key] = value

    return mutate


def _row(key, value):
    def mutate(data, tmp_path):
        data["cases"][0][key] = value

    return mutate


def _missing_source(data, tmp_path):
    data["source"] = str(tmp_path / "gone.dat")


def _duplicate_deck(data, tmp_path):
    data["cases"].append(dict(data["cases"][0], name="other"))


def _missing_deck(data, tmp_path):
    data["cases"][0]["deck"] = str(tmp_path / "gone.dat")


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (_set("schema", "other"), "expected schema"),
        (_set("source", 5), "source must be a string"),
        (_set("source_sha256", "abc"), "64-digit SHA-256"),
        (_set("source_sha256", "0" * 64), "source deck SHA-256 does not match"),
        (_missing_source, "source deck does not exist"),
        (_set("cases", []), "non-empty array"),
        (_set("cases", ["not an object"]), "must be an object"),
        (_row("name", 3), "name/deck must be strings"),
        (_row("name", "../escape"), "safe and unique"),
        (_duplicate_deck, "deck paths must be unique"),
        (_missing_deck, "generated deck does not exist"),
    ],
)
def test_manifest_errors_fail_before_any_solver(tmp_path, mutate, message):
    manifest = _manifest(tmp_path, mutate)
    with pytest.raises(StudyFormatError, match=message):
        run_study(manifest, executable=tmp_path / "never-used.exe")


def test_unreadable_manifest_is_a_format_error(tmp_path):
    path = tmp_path / "cases.json"
    path.write_bytes(b"\xff\xfe not json")
    with pytest.raises(StudyFormatError, match="cannot read case manifest"):
        run_study(path)
    with pytest.raises(StudyFormatError, match="cannot read case manifest"):
        run_study(tmp_path / "absent.json")


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"jobs": "2"}, "jobs must be a positive integer"),
        ({"jobs": True}, "jobs must be a positive integer"),
        ({"jobs": 0}, "jobs must be a positive integer"),
        ({"timeout": True}, "timeout must be finite and positive"),
        ({"timeout": float("inf")}, "timeout must be finite and positive"),
        ({"start": True}, "start must be finite"),
        ({"stop": float("nan")}, "stop must be finite"),
        ({"start": 2.0, "stop": 1.0}, "must not exceed"),
        ({"channels": []}, "non-empty and unique"),
        ({"channels": ["A", "A"]}, "non-empty and unique"),
        ({"channels": [""]}, "non-empty and unique"),
    ],
)
def test_argument_errors_fail_before_any_solver(tmp_path, kwargs, message):
    manifest = _manifest(tmp_path)
    with pytest.raises(ValueError, match=message):
        run_study(manifest, executable=tmp_path / "never-used.exe", **kwargs)


def test_driver_and_executable_are_mutually_exclusive(tmp_path, fake_driver):
    from cabledyn import CableDynDriver

    with pytest.raises(ValueError, match="either driver or executable"):
        run_study(_manifest(tmp_path), driver=CableDynDriver(fake_driver), executable=fake_driver)


def test_driver_whose_executable_vanished_is_rejected(tmp_path, fake_driver):
    from cabledyn import CableDynDriver

    driver = CableDynDriver(fake_driver)
    driver.executable = tmp_path / "deleted.exe"
    with pytest.raises(FileNotFoundError, match="does not exist"):
        run_study(_manifest(tmp_path), driver=driver)


def test_single_channel_string_and_log_write_failures_are_recorded(
    tmp_path, fake_driver, monkeypatch
):
    manifest = _manifest(tmp_path)
    original = study_module._atomic_text

    def failing_logs(path, text):
        if path.name.endswith(".stderr.log"):
            raise PermissionError(13, "log locked")
        original(path, text)

    monkeypatch.setattr(study_module, "_atomic_text", failing_logs)
    result = run_study(manifest, executable=fake_driver, channels="FairTen1")
    (case,) = result.cases
    assert case.status == "postprocess_failed"
    assert case.error is not None and "could not write case_a.stderr.log" in case.error
    assert not result.passed and result.failed_cases == (case,)


def test_atomic_text_removes_its_temporary_file_on_failure(tmp_path, monkeypatch):
    def broken(*args, **kwargs):
        raise OSError("replace failed")

    monkeypatch.setattr(study_module.os, "replace", broken)
    with pytest.raises(OSError, match="replace failed"):
        study_module._atomic_text(tmp_path / "study.json", "{}")
    assert list(tmp_path.iterdir()) == []


def test_interrupted_study_cancels_and_propagates(tmp_path, fake_driver, monkeypatch):
    manifest = _manifest(tmp_path, names=("case_a", "case_b"))

    def interrupted(self, *args, **kwargs):
        raise KeyboardInterrupt

    monkeypatch.setattr(study_module.CableDynDriver, "run", interrupted)
    with pytest.raises(KeyboardInterrupt):
        run_study(manifest, executable=fake_driver)
    assert not (tmp_path / "study-results" / "study.json").exists()


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"status": "done"}, "unsupported study case status"),
        ({"elapsed_seconds": -1.0}, "finite and non-negative"),
        ({"elapsed_seconds": float("nan")}, "finite and non-negative"),
    ],
)
def test_case_result_validates_its_fields(tmp_path, kwargs, message):
    fields = {
        "name": "a",
        "status": "completed",
        "deck": tmp_path / "a.dat",
        "deck_sha256": "0" * 64,
        "output_root": tmp_path / "a",
        "elapsed_seconds": 1.0,
        "returncode": 0,
        "main_output": None,
        "static_output": None,
        "stdout_log": tmp_path / "a.stdout.log",
        "stderr_log": tmp_path / "a.stderr.log",
        "error": None,
    }
    fields.update(kwargs)
    with pytest.raises(ValueError, match=message):
        StudyCaseResult(**fields)
