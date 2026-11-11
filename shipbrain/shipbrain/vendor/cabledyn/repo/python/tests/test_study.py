# SPDX-License-Identifier: Apache-2.0
"""Batch-study provenance, continuation, and summary gates."""

from __future__ import annotations

import csv
import hashlib
import json
import threading
from pathlib import Path

import pytest

from cabledyn import DriverExecutionError, StudyFormatError, run_study
from cabledyn.driver import DriverResult


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _case_manifest(tmp_path: Path, names=("case_a", "case_b")) -> Path:
    source = tmp_path / "source.dat"
    source.write_text("source deck\n", encoding="ascii")
    rows = []
    for name in names:
        deck = tmp_path / f"{name}.dat"
        deck.write_text(f"generated {name}\n", encoding="ascii")
        rows.append({"name": name, "deck": str(deck), "sha256": _digest(deck), "changes": {}})
    manifest = tmp_path / "cases.json"
    manifest.write_text(
        json.dumps(
            {
                "schema": "cabledyn-deck-cases-v1",
                "source": str(source),
                "source_sha256": _digest(source),
                "cases": rows,
            }
        ),
        encoding="utf-8",
    )
    return manifest


class _Driver:
    def __init__(self, executable: Path, *, failing=(), output_failing=(), crashing=()) -> None:
        self.executable = executable
        self.failing = set(failing)
        self.output_failing = set(output_failing)
        self.crashing = set(crashing)
        self.calls: list[str] = []
        self._lock = threading.Lock()

    def version(self) -> str:
        return "CableDyn test driver 1.2.3"

    def run(self, deck, output_root, **kwargs) -> DriverResult:
        name = Path(deck).stem
        with self._lock:
            self.calls.append(name)
        if name in self.crashing:
            raise RuntimeError(f"unexpected wrapper fault in {name}")
        if name in self.failing:
            raise DriverExecutionError(
                f"{name} did not converge",
                returncode=2,
                stdout=f"stdout {name}\n",
                stderr=f"stderr {name}\n",
            )
        root = Path(output_root)
        main = Path(f"{root}.out")
        if name in self.output_failing:
            main.write_text("Time(s) FairTen1\n0 overflow\n", encoding="ascii")
            static = Path(f"{root}.static.out")
            static.write_text("incomplete static output\n", encoding="ascii")
            raise DriverExecutionError(
                f"{name} produced invalid output",
                returncode=0,
                stdout=f"stdout {name}\n",
                stderr=f"stderr {name}\n",
            )
        main.write_text(
            "Time(s) FairTen1 Other\n(s) (N) (-)\n0 100 1\n1 300 2\n2 500 3\n",
            encoding="ascii",
        )
        static = Path(f"{root}.static.out")
        static.write_text("LineID Node ArcLength\n(-) (-) (m)\n1 1 0\n", encoding="ascii")
        return DriverResult(
            executable=self.executable,
            deck=Path(deck),
            output_root=root,
            main_output=main,
            static_output=static,
            elements_output=None,
            line_outputs=(),
            rod_outputs=(),
            stdout=f"completed {name}\n",
            stderr="",
            returncode=0,
        )


def _driver(tmp_path: Path, **kwargs) -> _Driver:
    executable = tmp_path / "CableDyn_driver.exe"
    executable.write_bytes(b"test executable")
    return _Driver(executable, **kwargs)


def test_study_runs_in_manifest_order_and_writes_auditable_statistics(tmp_path):
    manifest = _case_manifest(tmp_path)
    driver = _driver(tmp_path)
    result = run_study(
        manifest,
        driver=driver,
        output_directory=tmp_path / "results",
        channels="FairTen1",
        start=1.0,
        stop=2.0,
        jobs=2,
    )
    assert result.passed
    assert [case.name for case in result.cases] == ["case_a", "case_b"]
    assert set(driver.calls) == {"case_a", "case_b"}
    assert len(result.executable_sha256) == 64
    assert all(
        case.stdout_log.read_text(encoding="utf-8").startswith("completed") for case in result.cases
    )
    with result.summary_csv.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    assert [row["case"] for row in rows] == ["case_a", "case_b"]
    assert all(row["channel"] == "FairTen1" for row in rows)
    assert all(row["unit"] == "N" for row in rows)
    assert all(row["count"] == "2" for row in rows)
    assert all(float(row["minimum"]) == 300.0 for row in rows)
    assert all(float(row["maximum"]) == 500.0 for row in rows)
    payload = json.loads(result.study_manifest.read_text(encoding="utf-8"))
    assert payload["schema"] == "cabledyn-study-results-v1"
    assert payload["jobs"] == 2
    assert payload["channels"] == ["FairTen1"]
    assert payload["cases"][0]["deck_sha256"] == _digest(tmp_path / "case_a.dat")


def test_study_records_the_preflight_manifest_snapshot(tmp_path):
    manifest = _case_manifest(tmp_path, ("case_a",))
    preflight_digest = _digest(manifest)
    driver = _driver(tmp_path)
    original_run = driver.run

    def mutate_manifest_after_preflight(*args, **kwargs):
        manifest.write_text('{"changed": true}\n', encoding="utf-8")
        return original_run(*args, **kwargs)

    driver.run = mutate_manifest_after_preflight  # type: ignore[method-assign]
    result = run_study(manifest, driver=driver, output_directory=tmp_path / "results")
    payload = json.loads(result.study_manifest.read_text(encoding="utf-8"))
    assert payload["case_manifest_sha256"] == preflight_digest
    assert payload["case_manifest_sha256"] != _digest(manifest)


def test_study_records_failures_but_runs_remaining_cases(tmp_path):
    manifest = _case_manifest(tmp_path, ("bad", "crash", "good"))
    driver = _driver(tmp_path, failing={"bad"}, crashing={"crash"})
    result = run_study(
        manifest,
        driver=driver,
        output_directory=tmp_path / "results",
        jobs=3,
    )
    assert not result.passed
    assert [case.status for case in result.cases] == ["failed", "failed", "completed"]
    assert len(result.failed_cases) == 2
    assert set(driver.calls) == {"bad", "crash", "good"}
    assert "unexpected wrapper fault" in (result.cases[1].error or "")
    assert result.study_manifest.is_file() and result.summary_csv.is_file()
    failed = result.cases[0]
    assert failed.returncode == 2
    assert failed.main_output is None
    assert failed.stderr_log.read_text(encoding="utf-8") == "stderr bad\n"
    assert "\n" not in (failed.error or "")
    with result.summary_csv.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    bad = next(row for row in rows if row["case"] == "bad")
    assert bad["status"] == "failed"
    assert bad["channel"] == ""
    assert "did not converge" in bad["error"]


def test_study_records_bad_channel_as_postprocess_failure_and_continues(tmp_path):
    manifest = _case_manifest(tmp_path)
    driver = _driver(tmp_path)
    result = run_study(
        manifest,
        driver=driver,
        output_directory=tmp_path / "results",
        channels="Missing",
        jobs=2,
    )
    assert [case.status for case in result.cases] == [
        "postprocess_failed",
        "postprocess_failed",
    ]
    assert set(driver.calls) == {"case_a", "case_b"}
    assert all(case.returncode == 0 and case.main_output is not None for case in result.cases)
    assert all("available:" in (case.error or "") for case in result.cases)
    with result.summary_csv.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    assert all(row["status"] == "postprocess_failed" for row in rows)
    assert all(row["channel"] == "" for row in rows)


def test_study_preserves_zero_exit_invalid_output_as_postprocess_failure(tmp_path):
    manifest = _case_manifest(tmp_path, ("malformed", "good"))
    driver = _driver(tmp_path, output_failing={"malformed"})
    result = run_study(
        manifest,
        driver=driver,
        output_directory=tmp_path / "results",
        jobs=2,
    )
    malformed, good = result.cases
    assert malformed.status == "postprocess_failed"
    assert malformed.returncode == 0
    assert malformed.main_output == tmp_path / "results" / "malformed.out"
    assert malformed.static_output == tmp_path / "results" / "malformed.static.out"
    assert malformed.stdout_log.read_text(encoding="utf-8") == "stdout malformed\n"
    assert malformed.stderr_log.read_text(encoding="utf-8") == "stderr malformed\n"
    assert good.status == "completed"


@pytest.mark.parametrize(
    "derived",
    [
        "base.static",
        "BASE.elements",
        "base.modes",
        "base.Line2.t",
        "base.Line1.V",
        "base.Line3.range",
        "base.Rod1.p",
    ],
)
def test_study_rejects_case_names_that_alias_another_cases_outputs(tmp_path, derived):
    manifest = _case_manifest(tmp_path, ("base", derived))
    driver = _driver(tmp_path)
    with pytest.raises(StudyFormatError, match="collides with the output files"):
        run_study(manifest, driver=driver, output_directory=tmp_path / "results")
    assert driver.calls == []


def test_study_hash_and_schema_errors_fail_before_solver_execution(tmp_path):
    manifest = _case_manifest(tmp_path)
    driver = _driver(tmp_path)
    (tmp_path / "case_b.dat").write_text("tampered\n", encoding="ascii")
    with pytest.raises(StudyFormatError, match="SHA-256"):
        run_study(manifest, driver=driver, output_directory=tmp_path / "results")
    assert driver.calls == []

    data = json.loads(manifest.read_text(encoding="utf-8"))
    data["schema"] = "unknown"
    manifest.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(StudyFormatError, match="schema"):
        run_study(manifest, driver=driver, output_directory=tmp_path / "results")
    assert driver.calls == []


def test_study_rejects_malformed_digest_before_solver_execution(tmp_path):
    manifest = _case_manifest(tmp_path)
    driver = _driver(tmp_path)
    data = json.loads(manifest.read_text(encoding="utf-8"))
    data["cases"][0]["sha256"] = "not-a-digest"
    manifest.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(StudyFormatError, match="64-digit SHA-256"):
        run_study(manifest, driver=driver, output_directory=tmp_path / "results")
    assert driver.calls == []


def test_study_rejects_unsafe_names_and_protects_existing_results(tmp_path):
    manifest = _case_manifest(tmp_path, ("safe",))
    data = json.loads(manifest.read_text(encoding="utf-8"))
    data["cases"][0]["name"] = "../escape"
    manifest.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(StudyFormatError, match="safe and unique"):
        run_study(manifest, driver=_driver(tmp_path), output_directory=tmp_path / "results")

    manifest = _case_manifest(tmp_path, ("safe",))
    output = tmp_path / "results"
    output.mkdir()
    sentinel = output / "keep.txt"
    sentinel.write_text("owned by user\n", encoding="ascii")
    with pytest.raises(FileExistsError, match="not empty"):
        run_study(manifest, driver=_driver(tmp_path), output_directory=output)
    assert sentinel.read_text(encoding="ascii") == "owned by user\n"


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"jobs": 0}, "jobs"),
        ({"jobs": True}, "jobs"),
        ({"timeout": float("nan")}, "timeout"),
        ({"timeout": True}, "timeout"),
        ({"start": 2.0, "stop": 1.0}, "start"),
        ({"start": True}, "start"),
        ({"channels": []}, "channels"),
        ({"channels": ["A", "A"]}, "channels"),
        ({"channels": [1]}, "channels"),
    ],
)
def test_study_argument_validation(tmp_path, kwargs, message):
    manifest = _case_manifest(tmp_path)
    with pytest.raises(ValueError, match=message):
        run_study(
            manifest,
            driver=_driver(tmp_path),
            output_directory=tmp_path / "results",
            **kwargs,
        )
