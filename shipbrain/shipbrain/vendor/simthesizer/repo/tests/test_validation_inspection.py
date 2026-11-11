import argparse
import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from validation.inspection import inspect_report


class TemporalInspectionTests(unittest.TestCase):
    def test_direction_changes_concurrent_signals_missing_bins_and_pagination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "summary.json").write_text(
                json.dumps(
                    {
                        "case_id": "case",
                        "analysis_status": "PARTIAL",
                        "contract_issues": [],
                        "metrics": {
                            "rate": {"unit": "tokens/s", "mae": 5, "signed_bias": 0}
                        },
                    }
                )
            )
            findings = [
                {
                    "id": str(i),
                    "metric": "rate",
                    "start_s": i,
                    "end_s": i + 1,
                    "direction": "overprediction" if i == 0 else "underprediction",
                    "mean_signed_error": 5 if i == 0 else -5,
                    "absolute_error_area": 5,
                    "peak_absolute_error": {},
                    "evidence": {"reference_rows": [2 + i], "candidate_rows": [2 + i]},
                    "concurrent_signals": {
                        "running": {
                            "reference_mean": 2,
                            "candidate_mean": 3,
                            "source_rows": {"reference": [2]},
                        }
                    },
                }
                for i in range(2)
            ]
            (root / "findings.json").write_text(json.dumps(findings))
            with (root / "window_errors.csv").open("w") as stream:
                writer = csv.DictWriter(
                    stream,
                    fieldnames=["metric", "start_s", "end_s", "reference", "candidate"],
                )
                writer.writeheader()
                for i in range(3):
                    writer.writerow(
                        {
                            "metric": "rate",
                            "start_s": i,
                            "end_s": i + 1,
                            "reference": "" if i == 2 else 10,
                            "candidate": 15 if i == 0 else 5,
                        }
                    )
            args = argparse.Namespace(
                report=root, metric="rate", limit=1, offset=0, start=0.0, end=3.0
            )
            first = inspect_report(args)
            self.assertEqual(
                first["metrics"]["rate"]["findings"][0]["direction"], "overprediction"
            )
            self.assertTrue(first["more_bins"])
            self.assertEqual(
                first["metrics"]["rate"]["findings"][0]["concurrent_signals"][
                    "running"
                ]["reference_mean"],
                2,
            )
            args.offset = 1
            second = inspect_report(args)
            self.assertEqual(
                second["metrics"]["rate"]["findings"][0]["direction"], "underprediction"
            )
            args.offset = 2
            last = inspect_report(args)
            self.assertEqual(last["bins"][0]["reference"], "")
            self.assertFalse(last["more_bins"])
            args.end = args.start
            with self.assertRaises(ValueError):
                inspect_report(args)


if __name__ == "__main__":
    unittest.main()
