import argparse
import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from test_trace_validation import fixture
from validate import main
from validation.bundles import object_hash, pair
from validation.validator import compare, digest, write_report


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.path, self.case = fixture(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def run_case(self):
        self.path.write_text(json.dumps(self.case))
        return compare(self.path)

    def test_default_reports_differences_without_acceptance_or_verdict(self):
        del self.case["metrics"][0]["acceptance"]
        r = self.run_case()
        m = r["metrics"]["generation_rate"]
        self.assertEqual(r["status"], "ANALYZED")
        self.assertIsNone(r["accuracy_verdict"])
        self.assertEqual(m["status"], "COMPARED")
        self.assertNotIn("acceptance_check", m)
        self.assertAlmostEqual(m["mae"], 5)
        self.assertAlmostEqual(m["signed_bias"], 5)
        self.assertAlmostEqual(m["rmse"], (50) ** 0.5)
        self.assertEqual(m["absolute_error_p95"], 10)
        self.assertEqual(m["reference_statistics"]["time_weighted_mean"], 10)
        self.assertEqual(m["candidate_statistics"]["time_weighted_mean"], 15)
        self.assertEqual(
            (r["findings"][0]["start_s"], r["findings"][0]["end_s"]), (1, 3)
        )
        self.assertEqual(r["windows"][-1]["signed_error_area_over_observed_bins"], 20)

    def test_configured_acceptance_is_ignored_by_default_and_findings_do_not_depend_on_it(
        self,
    ):
        self.case["metrics"][0]["acceptance"]["absolute_tolerance"] = 10000
        r = self.run_case()
        self.assertTrue(r["findings"])
        self.assertTrue(all(w["exceeds_tolerance"] is None for w in r["windows"]))
        self.assertEqual(r["acceptance_check"], {"requested": False, "status": None})

    def test_sign_reversals_are_not_hidden_by_cancellation(self):
        self.path, self.case = fixture(self.root, (10, 10, 10, 10), (10, 20, 0, 10))
        r = self.run_case()
        self.assertEqual(r["metrics"]["generation_rate"]["signed_bias"], 0)
        self.assertEqual(
            [f["direction"] for f in r["findings"]],
            ["overprediction", "underprediction"],
        )
        self.assertEqual(
            [(f["start_s"], f["end_s"]) for f in r["findings"]], [(1, 2), (2, 3)]
        )

    def test_partial_coverage_retains_evidence_without_filling_tail(self):
        (self.root / "candidate.csv").write_text(
            "timestamp,generation_rate\n1,10\n2,20\n"
        )
        r = self.run_case()
        self.assertEqual(r["analysis_status"], "PARTIAL")
        self.assertEqual(r["metrics"]["generation_rate"]["coverage_fraction"], 0.5)
        self.assertIsNone(r["windows"][-1]["signed_error"])
        self.assertEqual(r["windows"][-1]["cumulative_observed_duration_s"], 2)
        self.assertEqual(r["windows"][-1]["signed_error_area_over_observed_bins"], 10)

    def test_identity_mismatch_withholds_paired_claims_but_keeps_source_inventory(self):
        self.case["candidate"]["workload_sha256"] = "different"
        r = self.run_case()
        self.assertEqual(r["analysis_status"], "UNAVAILABLE")
        self.assertEqual(r["windows"], [])
        self.assertEqual(r["findings"], [])
        self.assertEqual(r["source_inventory"]["candidate"]["rows"], 4)
        self.assertTrue(r["metrics"]["generation_rate"]["reference_statistics"])
        self.assertEqual(r["input_comparability"], "NOT_ESTABLISHED")

    def test_cross_signal_context_includes_matching_as_well_as_differing_signals(self):
        spec = copy.deepcopy(self.case["metrics"][0])
        spec.update(
            name="waiting_requests", meaning="engine.waiting_requests", unit="requests"
        )
        self.case["metrics"].append(spec)
        for role, vals in [("reference", [1, 2, 3, 4]), ("candidate", [1, 2, 3, 4])]:
            (self.root / (role + ".csv")).write_text(
                "timestamp,generation_rate,waiting\n"
                + "".join(
                    f"{i + 1},{[10, 10, 10, 10][i] if role == 'reference' else [10, 20, 20, 10][i]},{v}\n"
                    for i, v in enumerate(vals)
                )
            )
            self.case[role]["metrics"]["waiting_requests"] = {
                **self.case[role]["metrics"]["generation_rate"],
                "column": "waiting",
                "meaning": "engine.waiting_requests",
                "unit": "requests",
            }
        r = self.run_case()
        context = r["findings"][0]["concurrent_signals"]["waiting_requests"]
        self.assertEqual(context["reference_mean"], 2.5)
        self.assertEqual(context["candidate_mean"], 2.5)
        self.assertEqual(r["findings"][0]["cooccurring_metrics"], [])

    def test_zero_reference_keeps_absolute_evidence(self):
        self.path, self.case = fixture(self.root, (0, 0, 0, 0), (10, 0, 0, 0))
        r = self.run_case()
        m = r["metrics"]["generation_rate"]
        self.assertEqual(m["relative_error_undefined_bins"], 4)
        self.assertIsNone(m["wape"])
        self.assertEqual(m["peak_absolute_error"]["absolute_error"], 10)

    def test_identical_data_is_analyzed_not_accepted(self):
        (self.root / "candidate.csv").write_bytes(
            (self.root / "reference.csv").read_bytes()
        )
        r = self.run_case()
        self.assertEqual(r["status"], "ANALYZED")
        self.assertEqual(r["findings"], [])

    def test_cli_exit_reports_execution_not_accuracy_unless_explicitly_requested(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(
                main(["compare", str(self.path), "--out", str(self.root / "evidence")]),
                0,
            )
            self.assertEqual(
                main(
                    [
                        "compare",
                        str(self.path),
                        "--out",
                        str(self.root / "gate"),
                        "--check-acceptance",
                    ]
                ),
                2,
            )
        report = json.loads((self.root / "evidence/summary.json").read_text())
        self.assertIsNone(report["accuracy_verdict"])
        self.assertEqual(report["mode"], "evidence")

    def test_html_is_self_contained_escapes_data_and_shows_both_traces(self):
        self.case["case_id"] = "<script>alert(1)</script>"
        r = self.run_case()
        out = self.root / "html"
        write_report(r, out)
        page = (out / "report.html").read_text()
        self.assertIn("<svg", page)
        self.assertIn("Reference (solid) and candidate (dashed)", page)
        self.assertNotIn("<script>", page)
        self.assertIn("&lt;script&gt;", page)
        self.assertIn("Concurrent signal", page)
        self.assertNotIn(b"\r\n", (out / "window_errors.csv").read_bytes())

    def test_pair_includes_all_declared_signals_and_explains_unavailable_ones(self):
        self.case["metrics"][0].pop("acceptance")
        for role in ("reference", "candidate"):
            root = self.root / role
            root.mkdir()
            (root / "workload.jsonl").write_bytes(
                (self.root / "workload.jsonl").read_bytes()
            )
            (root / "environment.json").write_text(json.dumps(self.case["environment"]))
            (root / "engine.csv").write_bytes(
                (self.root / (role + ".csv")).read_bytes()
            )
            receipt = {
                "schema_version": 1,
                "status": "COMPLETE",
                "run_id": role,
                "producer_revision": "fixture",
                "workload_sha256": digest(root / "workload.jsonl"),
                "environment_sha256": object_hash(self.case["environment"]),
                "capture_duration_s": 4,
                "clock": self.case[role]["clock"],
                "metrics": copy.deepcopy(self.case[role]["metrics"]),
                "artifacts": {
                    name: digest(root / name)
                    for name in ["engine.csv", "workload.jsonl", "environment.json"]
                },
            }
            if role == "reference":
                receipt["metrics"]["kv_usage"] = {
                    "meaning": "engine.kv",
                    "unit": "fraction",
                    "column": "kv",
                    "observation": "gauge_hold",
                    "verified": True,
                    "evidence": "fixture",
                }
            (root / "bundle.json").write_text(json.dumps(receipt))
        config = self.root / "comparison.json"
        config.write_text(
            json.dumps({"comparison_id": "evidence", "bin_s": 1, "max_gap_s": 1.1})
        )
        args = argparse.Namespace(
            reference=self.root / "reference",
            candidate=self.root / "candidate",
            policy=config,
            case_id="all",
            data_kind="synthetic",
            out=self.root / "pair",
            allow_heldout=False,
        )
        case = pair(args)
        self.assertEqual(
            {m["name"] for m in case["metrics"]}, {"generation_rate", "kv_usage"}
        )
        r = compare(args.out / "case.json")
        self.assertEqual(r["analysis_status"], "PARTIAL")
        self.assertEqual(r["metrics"]["kv_usage"]["analysis_status"], "UNAVAILABLE")
        self.assertTrue(r["findings"])
        self.assertEqual(
            r["findings"][0]["concurrent_signals"]["kv_usage"][
                "paired_coverage_fraction"
            ],
            0,
        )


if __name__ == "__main__":
    unittest.main()
