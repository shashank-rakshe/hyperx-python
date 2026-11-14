#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Consistency checks for the committed physical and performance records."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import re
import statistics
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATION = ROOT / "validation"


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assert_close(test: unittest.TestCase, actual: float, expected: float) -> None:
    test.assertTrue(math.isclose(actual, expected, rel_tol=1.0e-11, abs_tol=1.0e-12))


class ValidationRecordTests(unittest.TestCase):
    def test_provenance_uses_the_release_version(self) -> None:
        cmake = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
        match = re.search(r"project\(CableDynCore VERSION (\d+\.\d+\.\d+)", cmake)
        self.assertIsNotNone(match)
        expected = f"v{match.group(1)}"
        # A record rerun on an unreleased development build after that release says so; the
        # version bump of the next release makes it fail here until the record is rerun.
        development = f"{expected}+dev (unreleased)"
        for relative in (
            "experiments/holcombe/provenance.json",
            "experiments/bergdahl/provenance.json",
        ):
            self.assertIn(load_json(VALIDATION / relative)["CableDyn_release"], (expected, development))

    def test_holcombe_marker_curvature_summary(self) -> None:
        directory = VALIDATION / "experiments" / "holcombe"
        rows = load_csv(directory / "marker_curvature_comparison.csv")
        markers = load_csv(directory / "experimental_markers.csv")
        summary = load_json(directory / "marker_curvature_summary.json")
        provenance = load_json(directory / "provenance.json")
        for filename, key in (
            ("experimental_markers.csv", "experimental_markers_sha256"),
            ("marker_curvature_comparison.csv", "marker_curvature_comparison_sha256"),
            ("marker_curvature_summary.json", "marker_curvature_summary_sha256"),
            ("mesh_refinement_summary.csv", "mesh_refinement_summary_sha256"),
        ):
            self.assertEqual(sha256(directory / filename), provenance[key])
        self.assertEqual(len(markers), 7)
        self.assertEqual([int(row["marker"]) for row in markers], list(range(1, 8)))
        self.assertEqual(len(rows), 5)

        for column, key in (("pinned", "free_rotation"), ("rigid", "vertical_clamp")):
            errors = [float(row[column]) - float(row["exp"]) for row in rows[:4]]
            reported = summary[key]
            self.assertEqual(reported["number_of_independent_curvature_stations"], 4)
            assert_close(self, statistics.fmean(errors), reported["bias_m_inv"])
            assert_close(self, statistics.fmean(abs(value) for value in errors), reported["mae_m_inv"])
            assert_close(
                self,
                math.sqrt(statistics.fmean(value * value for value in errors)),
                reported["rmse_m_inv"],
            )
            assert_close(self, max(abs(value) for value in errors), reported["maximum_absolute_error_m_inv"])

        measured_peak = max(rows, key=lambda row: float(row["exp"]))
        self.assertEqual(int(float(measured_peak["marker"])), 5)
        self.assertAlmostEqual(float(measured_peak["s"]), 2.73)

    def test_holcombe_mesh_refinement(self) -> None:
        rows = load_csv(
            VALIDATION / "experiments" / "holcombe" / "mesh_refinement_summary.csv"
        )
        self.assertEqual(len(rows), 12)
        # Free rotation converges to < 0.008 mm; the ideal clamp's marker 1, next to the clamped
        # end, moves 0.128 mm between 212 and 771 elements (0.011 mm at the 400-element primary).
        shifts: dict[str, float] = {}
        for row in rows:
            shift = float(row["maximum_marker_shift_from_h0p005_mm"])
            shifts[row["end_condition"]] = max(shifts.get(row["end_condition"], 0.0), shift)
        self.assertLess(shifts["pinned"], 0.008)
        self.assertLess(shifts["rigid"], 0.13)
        self.assertEqual({row["representation"] for row in rows}, {"discrete", "distributed"})
        self.assertEqual({row["end_condition"] for row in rows}, {"pinned", "rigid"})

    def test_bergdahl_aggregate_metrics(self) -> None:
        directory = VALIDATION / "experiments" / "bergdahl"
        rows = load_csv(directory / "comparison_summary.csv")
        reported = load_json(directory / "aggregate_metrics.json")
        provenance = load_json(directory / "provenance.json")
        for filename, key in (
            ("comparison_summary.csv", "force_maxima_sha256"),
            ("aggregate_metrics.json", "aggregate_metrics_sha256"),
            ("case_manifest.json", "case_manifest_sha256"),
            ("waveform_T1p25_R0p200.csv", "waveform_T1p25_sha256"),
            ("waveform_T3p50_R0p200.csv", "waveform_T3p50_sha256"),
            ("waveform_metrics.json", "waveform_metrics_sha256"),
            ("refinement_summary.csv", "refinement_summary_sha256"),
        ):
            self.assertEqual(sha256(directory / filename), provenance[key])
        self.assertEqual(len(rows), 30)
        self.assertEqual(len({row["case"] for row in rows}), 30)

        measured = [float(row["measured_maximum_N"]) for row in rows]
        predicted = [float(row["predicted_mean_cycle_maximum_N"]) for row in rows]
        errors = [calc - test for calc, test in zip(predicted, measured, strict=True)]
        percentages = [100.0 * error / test for error, test in zip(errors, measured, strict=True)]
        assert_close(self, statistics.fmean(errors), reported["mean_bias_N"])
        assert_close(self, statistics.fmean(percentages), reported["mean_bias_percent_of_measured"])
        assert_close(self, statistics.fmean(abs(value) for value in errors), reported["mae_N"])
        assert_close(self, statistics.fmean(abs(value) for value in percentages), reported["mape_percent"])
        assert_close(
            self,
            math.sqrt(statistics.fmean(value * value for value in errors)),
            reported["rmse_N"],
        )
        assert_close(self, max(abs(value) for value in percentages), reported["maximum_absolute_error_percent"])
        assert_close(self, statistics.correlation(measured, predicted), reported["pearson_correlation"])

        mean_measured = statistics.fmean(measured)
        mean_predicted = statistics.fmean(predicted)
        variance_measured = statistics.pvariance(measured)
        variance_predicted = statistics.pvariance(predicted)
        covariance = statistics.fmean(
            (test - mean_measured) * (calc - mean_predicted)
            for test, calc in zip(measured, predicted, strict=True)
        )
        concordance = 2.0 * covariance / (
            variance_measured + variance_predicted + (mean_measured - mean_predicted) ** 2
        )
        assert_close(self, concordance, reported["lin_concordance_correlation"])

    def test_bergdahl_refinement_and_waveforms(self) -> None:
        directory = VALIDATION / "experiments" / "bergdahl"
        refinement = load_json(directory / "refinement_summary.json")
        waveforms = load_json(directory / "waveform_metrics.json")
        provenance = load_json(directory / "provenance.json")
        self.assertEqual(refinement["conditions"], 2)
        assert_close(
            self,
            refinement["maximum_primary_spatial_difference_percent"],
            provenance["maximum_spatial_refinement_difference_percent"],
        )
        assert_close(
            self,
            refinement["maximum_primary_temporal_difference_percent"],
            provenance["maximum_temporal_refinement_difference_percent"],
        )
        # Regression pins just above the recorded release values (0.49% and 0.28%). The primary
        # 0.3125 ms step resolves the segment axial modes that the snap loads excite.
        self.assertLessEqual(refinement["maximum_primary_spatial_difference_percent"], 0.6)
        self.assertLessEqual(refinement["maximum_primary_temporal_difference_percent"], 0.4)
        self.assertEqual(len(waveforms), 2)
        self.assertLessEqual(max(item["rmse_percent_of_measured_range"] for item in waveforms), 6.5)
        self.assertGreaterEqual(min(item["correlation"] for item in waveforms), 0.98)
        self.assertEqual(provenance["completed_cases"], 30)
        self.assertEqual(provenance["nonlinear_misses"], 0)

    def test_performance_summary_matches_machine_readable_record(self) -> None:
        directory = VALIDATION / "performance"
        rows = load_csv(directory / "performance_summary.csv")
        others = load_csv(directory / "wallclock_summary.csv")
        record = load_json(directory / "performance_metrics.json")
        # L5-DPC: three spans, CableDyn with the GNU development build and the IFX release driver,
        # OrcaFlex and MoorDyn-F.
        cabledyn_builds = {row["build"] for row in rows if row["solver"] == "CableDyn"}
        self.assertEqual(len(cabledyn_builds), 2)
        expected = {(site, "CableDyn", build) for site in ("80m", "200m", "800m") for build in cabledyn_builds}
        expected |= {(site, solver, solver.lower()) for site in ("80m", "200m", "800m")
                     for solver in ("OrcaFlex", "MoorDyn-F")}
        lookup = {(row["site"], row["solver"], row["build"]): row for row in rows}
        self.assertEqual(len(lookup), len(rows))
        self.assertEqual(set(lookup), expected)
        self.assertEqual({row["case"] for row in rows}, {"L5-DPC"})
        # L5-V (CableDyn builds and OrcaFlex) and L5-wc (CableDyn builds and MoorDyn-C).
        other_lookup = {(row["case"], row["solver"], row["build"]): row for row in others}
        self.assertEqual(len(other_lookup), len(others))
        self.assertEqual(
            set(other_lookup),
            {(case, "CableDyn", build) for case in ("L5-V", "L5-wc") for build in cabledyn_builds}
            | {("L5-V", "OrcaFlex", "orcaflex"), ("L5-wc", "MoorDyn-C", "moordyn-c")},
        )

        for table, key_fields, json_rows in (
            (lookup, ("site", "solver", "build"), record["rows"]),
            (other_lookup, ("case", "solver", "build"), record["wallclock_rows"]),
        ):
            records = {tuple(row[field] for field in key_fields): row for row in json_rows}
            self.assertEqual(set(records), set(table))
            for key, row in table.items():
                median = float(row["total_wall_median_s"])
                self.assertLessEqual(float(row["total_wall_min_s"]), median)
                self.assertGreaterEqual(float(row["total_wall_max_s"]), median)
                assert_close(self, median, records[key]["total_wall_median_s"])
                self.assertIn(row["build"], record["codes"])
        for key, row in list(lookup.items()) + list(other_lookup.items()):
            if row["solver"] == "CableDyn" and row["subdivided_intervals"]:
                self.assertEqual(int(row["subdivided_intervals"]), 0, key)
        for site in ("80m", "200m", "800m"):
            for build in cabledyn_builds:
                self.assertEqual(int(lookup[(site, "CableDyn", build)]["subdivided_intervals"]), 0)
        # The refined MoorDyn-F step is the largest whose halving moves the scored responses < 0.01 %.
        checks = record["moordyn_f_step_checks"]
        self.assertEqual(len(checks), 3)
        for check in checks.values():
            self.assertLess(check["largest_relative_move"], 1.0e-4)


if __name__ == "__main__":
    unittest.main()
