# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Regression tests for the solver-neutral FEM observable comparator."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "validation" / "scripts"))

from fem_observable_compare import ComparisonError, compare_manifest, read_output, read_table  # noqa: E402


def write_output(
    path: Path,
    channel: str,
    rows: list[tuple[float, float]],
    wrapped: bool = False,
    time_header: str = "Time",
    units_row: bool = True,
    exponent: str = "E",
) -> None:
    header = f"{time_header} {channel}\n"
    if wrapped:
        header = time_header + "\n" + channel + "\n"
    units = "(s) (N)\n" if units_row else ""
    rows_text = "\n".join(
        f"{time:.6f} {value:.12E}".replace("E", exponent) for time, value in rows
    )
    path.write_text(
        "generated regression fixture\n" + header + units + rows_text + "\n",
        encoding="utf-8",
    )


class FemObservableCompareTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        write_output(self.root / "reference.out", "FAIRTEN1", [(0.0, 10.0), (1.0, 12.0), (2.0, 10.0)], True)
        write_output(
            self.root / "candidate.out",
            "FairTen1",
            [(0.0, 10.0), (0.5, 11.0), (1.0, 12.0), (1.5, 11.0), (2.0, 10.0)],
        )
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "cases": [
                        {
                            "name": "line_case",
                            "reference": "reference.out",
                            "candidate": "candidate.out",
                            "observables": [
                                {
                                    "name": "line.1.fairlead_tension",
                                    "reference_channel": "FAIRTEN1",
                                    "candidate_channel": "FairTen1",
                                    "normalization": "range",
                                    "limits": {"nrmse": 1.0e-12, "peak_relative": 1.0e-12},
                                }
                            ],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_wrapped_header_and_time_interpolation_pass(self) -> None:
        table = read_output(self.root / "reference.out")
        self.assertEqual(table.names, ("Time", "FAIRTEN1"))
        results, passed = compare_manifest(self.manifest, self.root, self.root)
        self.assertTrue(passed)
        self.assertEqual(results[0]["observable"], "line.1.fairlead_tension")

    def test_cabledyn_time_with_units_and_no_units_row_passes(self) -> None:
        write_output(
            self.root / "candidate.out",
            "FairTen1",
            [(0.0, 10.0), (1.0, 12.0), (2.0, 10.0)],
            time_header="Time(s)",
            units_row=False,
            exponent="D",
        )
        table = read_output(self.root / "candidate.out")
        self.assertEqual(table.names, ("Time", "FairTen1"))
        results, passed = compare_manifest(self.manifest, self.root, self.root)
        self.assertTrue(passed)
        self.assertTrue(results[0]["passed"])

    def test_time_unit_spellings_are_case_insensitive(self) -> None:
        for spelling in ("TIME(S)", "time[s]", "Time(sec)"):
            write_output(
                self.root / "candidate.out",
                "FairTen1",
                [(0.0, 10.0), (1.0, 12.0), (2.0, 10.0)],
                time_header=spelling,
                units_row=False,
            )
            self.assertEqual(read_output(self.root / "candidate.out").names[0], "Time")

    def test_duplicate_logical_time_column_is_rejected(self) -> None:
        (self.root / "candidate.out").write_text(
            "Time(s) Time\n0.0 0.0\n1.0 1.0\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ComparisonError, "duplicate channel header"):
            read_output(self.root / "candidate.out")

    def test_truncated_numeric_row_is_rejected(self) -> None:
        (self.root / "candidate.out").write_text(
            "Time(s) FairTen1\n0.0 10.0\n1.0\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ComparisonError, "numeric row has 1 values; expected 2"):
            read_output(self.root / "candidate.out")

    def test_short_and_compensating_long_rows_are_rejected(self) -> None:
        (self.root / "candidate.out").write_text(
            "Time(s) FairTen1 AnchTen1\n"
            "0.0 10.0\n"
            "1.0 11.0 9.0 999.0\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ComparisonError, "numeric row has 2 values; expected 3"):
            read_output(self.root / "candidate.out")

    def test_numeric_row_with_overflow_marker_is_rejected(self) -> None:
        (self.root / "candidate.out").write_text(
            "Time(s) FairTen1\n0.0 10.0\n1.0 ********\n2.0 12.0\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ComparisonError, "numeric row contains a nonnumeric value"):
            read_output(self.root / "candidate.out")

    def test_corrupt_coordinate_after_numeric_data_is_rejected(self) -> None:
        (self.root / "candidate.out").write_text(
            "Time(s) FairTen1\n0.0 10.0\n******** 11.0\n2.0 12.0\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ComparisonError, "nonnumeric row encountered"):
            read_output(self.root / "candidate.out")

    def test_corrupt_coordinate_in_first_data_row_is_rejected(self) -> None:
        (self.root / "candidate.out").write_text(
            "Time(s) FairTen1\n******** 11.0\n2.0 12.0\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ComparisonError, "malformed row before numeric data"):
            read_output(self.root / "candidate.out")

    def test_static_profiles_compare_on_normalized_arc_length(self) -> None:
        reference = self.root / "reference.static.out"
        candidate = self.root / "candidate.static.out"
        reference.write_text(
            "profile\nLineID Node ArcLength Tension\n(-) (-) (m) (N)\n"
            "1 1 0.0 10.0\n1 2 5.0 20.0\n1 3 10.0 30.0\n"
            "2 1 0.0 99.0\n2 2 2.0 99.0\n",
            encoding="utf-8",
        )
        candidate.write_text(
            "profile\nLineID Node ArcLength Tension\n(-) (-) (m) (N)\n"
            "1 1 0.0 10.0\n1 2 4.0 19.0\n1 3 8.0 30.0\n",
            encoding="utf-8",
        )
        table = read_table(reference, "ArcLength")
        self.assertEqual(table.names, ("LineID", "Node", "ArcLength", "Tension"))
        data = {
            "schema": 1,
            "cases": [
                {
                    "name": "profile",
                    "reference": reference.name,
                    "candidate": candidate.name,
                    "reference_axis": "ArcLength",
                    "candidate_axis": "ArcLength",
                    "reference_filter": {"LineID": 1},
                    "candidate_filter": {"LineID": 1},
                    "normalize_axis": True,
                    "observables": [
                        {
                            "name": "line.1.tension_profile",
                            "reference_channel": "Tension",
                            "candidate_channel": "Tension",
                            "normalization": "magnitude",
                            "limits": {"nrmse": 0.04},
                        }
                    ],
                }
            ],
        }
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        results, passed = compare_manifest(self.manifest, self.root, self.root)
        self.assertTrue(passed)
        self.assertLess(results[0]["metrics"]["nrmse"], 0.04)

    def test_normalized_axis_with_window_is_rejected(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["cases"][0]["normalize_axis"] = True
        data["cases"][0]["axis_start"] = 0.5
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ComparisonError, "cannot also select an axis window"):
            compare_manifest(self.manifest, self.root, self.root)

    def test_unknown_metric_limit_is_rejected(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["cases"][0]["observables"][0]["limits"] = {"mystery": 0.1}
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ComparisonError, "unknown metric"):
            compare_manifest(self.manifest, self.root, self.root)

    def test_missing_or_empty_limits_are_rejected(self) -> None:
        for limits in (None, {}):
            data = json.loads(self.manifest.read_text(encoding="utf-8"))
            observable = data["cases"][0]["observables"][0]
            if limits is None:
                del observable["limits"]
            else:
                observable["limits"] = limits
            self.manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(ComparisonError, "limits must be a non-empty object"):
                compare_manifest(self.manifest, self.root, self.root)
            observable["limits"] = {"nrmse": 1.0e-12}
            self.manifest.write_text(json.dumps(data), encoding="utf-8")

    def test_duplicate_observable_names_are_rejected(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        duplicate = dict(data["cases"][0]["observables"][0])
        data["cases"][0]["observables"].append(duplicate)
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ComparisonError, "duplicate observable name"):
            compare_manifest(self.manifest, self.root, self.root)

    def test_explicit_reference_scale_converts_kn_to_n(self) -> None:
        write_output(
            self.root / "reference.out",
            "FAIRTEN1",
            [(0.0, 0.010), (1.0, 0.012), (2.0, 0.010)],
        )
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["cases"][0]["observables"][0]["reference_scale"] = 1000.0
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        results, passed = compare_manifest(self.manifest, self.root, self.root)
        self.assertTrue(passed)
        self.assertLess(results[0]["metrics"]["nrmse"], 1.0e-12)

    def test_nonfinite_or_zero_scale_is_rejected(self) -> None:
        for invalid in (0.0, "nan", "not-a-number"):
            data = json.loads(self.manifest.read_text(encoding="utf-8"))
            data["cases"][0]["observables"][0]["candidate_scale"] = invalid
            self.manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(ComparisonError, "candidate_scale must be"):
                compare_manifest(self.manifest, self.root, self.root)
            del data["cases"][0]["observables"][0]["candidate_scale"]
            self.manifest.write_text(json.dumps(data), encoding="utf-8")

    def test_regression_beyond_limit_fails(self) -> None:
        write_output(self.root / "candidate.out", "FairTen1", [(0.0, 10.0), (1.0, 14.0), (2.0, 10.0)])
        results, passed = compare_manifest(self.manifest, self.root, self.root)
        self.assertFalse(passed)
        self.assertFalse(results[0]["passed"])

    def test_moordyn_internal_object_is_rejected(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["cases"][0]["observables"][0]["name"] = "rod.1.node.2.position_z"
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ComparisonError, "not an FEM-level object"):
            compare_manifest(self.manifest, self.root, self.root)


if __name__ == "__main__":
    unittest.main()
