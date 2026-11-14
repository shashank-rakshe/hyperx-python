import csv
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from validation.validator import (
    ContractError,
    compare,
    digest,
    load_source,
    rebin,
    source_segments,
    write_report,
)


def fixture(root, reference=(10, 10, 10, 10), candidate=(10, 20, 20, 10)):
    workload = root / "workload.jsonl"
    workload.write_text(
        '{"request_id":0,"arrival_time":0,"initial":[0],"sub_requests":[{"kind":"llm","input_tokens":32,"output_tokens":40,"next":[]}]}\n'
    )
    env = {
        "model": "synthetic",
        "model_revision": "fixture-v1",
        "hardware": "none",
        "deployment": {"tp": 1},
        "serving_config": {},
        "target_vllm_version": "synthetic",
    }
    eh = hashlib.sha256(
        json.dumps(env, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    metric = {
        "name": "generation_rate",
        "unit": "tokens/s",
        "meaning": "engine.generated_tokens.rate",
        "acceptance": {
            "absolute_tolerance": 1,
            "relative_tolerance": 0.1,
            "max_bad_duration_fraction": 0.0,
        },
        "components_to_inspect": ["compute", "scheduler"],
    }
    case = {
        "schema_version": 1,
        "case_id": "synthetic-divergence",
        "data_kind": "synthetic test fixture; not GPU evidence",
        "workload": {"path": "workload.jsonl", "replay_mode": "fixed_arrivals"},
        "environment": env,
        "comparison": {
            "start_s": 0,
            "end_s": 4,
            "bin_s": 1,
            "reconstruction": "piecewise_constant",
            "window_evidence": "complete synthetic run",
        },
        "metrics": [metric],
    }
    for role, values in [("reference", reference), ("candidate", candidate)]:
        with (root / (role + ".csv")).open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["timestamp", "generation_rate"])
            w.writerows(enumerate(values, 1))
        case[role] = {
            "path": role + ".csv",
            "workload_sha256": digest(workload),
            "environment_sha256": eh,
            "run_id": role,
            "producer_revision": "fixture-v1",
            "clock": {
                "column": "timestamp",
                "unit": "s",
                "origin": 0,
                "basis": "workload_start",
                "evidence": "synthetic clock",
            },
            "metrics": {
                "generation_rate": {
                    "column": "generation_rate",
                    "observation": "interval_mean",
                    "interval_seconds": 1,
                    "max_gap_s": 1.1,
                    "meaning": metric["meaning"],
                    "unit": metric["unit"],
                    "verified": True,
                    "evidence": "exact fixture construction",
                }
            },
        }
    path = root / "case.json"
    path.write_text(json.dumps(case, indent=2) + "\n")
    return path, case


class ValidatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.path, self.case = fixture(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def run_case(self):
        self.path.write_text(json.dumps(self.case))
        return compare(self.path, check_acceptance=True)

    def test_known_divergence_and_evidence(self):
        r = self.run_case()
        self.assertEqual(r["status"], "FAIL")
        self.assertAlmostEqual(r["metrics"]["generation_rate"]["mae"], 5)
        self.assertAlmostEqual(r["metrics"]["generation_rate"]["wape"], 0.5)
        self.assertEqual(
            (r["findings"][0]["start_s"], r["findings"][0]["end_s"]), (1, 3)
        )
        self.assertEqual(r["findings"][0]["evidence"]["reference_rows"], [3, 4])

    def test_identical_data_passes(self):
        (self.root / "candidate.csv").write_bytes(
            (self.root / "reference.csv").read_bytes()
        )
        self.assertEqual(self.run_case()["status"], "PASS")

    def test_zero_reference_does_not_hide_error(self):
        self.path, self.case = fixture(self.root, (0, 0, 0, 0), (10, 0, 0, 0))
        r = self.run_case()
        self.assertEqual(r["status"], "FAIL")
        self.assertIsNone(r["metrics"]["generation_rate"]["wape"])
        self.assertIsNone(r["windows"][0]["relative_error"])
        self.assertEqual(r["windows"][0]["absolute_error"], 10)

    def test_missing_tail_not_truncated(self):
        (self.root / "candidate.csv").write_text(
            "timestamp,generation_rate\n1,10\n2,10\n"
        )
        r = self.run_case()
        self.assertEqual(r["status"], "INCOMPLETE")
        self.assertEqual(r["metrics"]["generation_rate"]["coverage_fraction"], 0.5)
        self.assertEqual(len(r["windows"]), 4)

    def test_wrong_workload_cannot_pass(self):
        self.case["candidate"]["workload_sha256"] = "incorrect"
        r = self.run_case()
        self.assertEqual(r["status"], "INCOMPLETE")
        self.assertTrue(any("digest" in i for i in r["contract_issues"]))

    def test_unverified_semantics_not_compared(self):
        self.case["reference"]["metrics"]["generation_rate"]["verified"] = False
        r = self.run_case()
        self.assertEqual(r["metrics"]["generation_rate"]["status"], "INCOMPARABLE")
        self.assertEqual(r["windows"], [])

    def test_different_meaning_not_compared(self):
        self.case["candidate"]["metrics"]["generation_rate"]["meaning"] = (
            "client.stream_chunks.rate"
        )
        self.assertEqual(
            self.run_case()["metrics"]["generation_rate"]["status"], "INCOMPARABLE"
        )

    def test_unknown_origin_not_fitted(self):
        self.case["reference"]["clock"]["origin"] = None
        self.assertEqual(
            self.run_case()["metrics"]["generation_rate"]["status"], "INCOMPARABLE"
        )

    def test_counter_reset_is_missing_coverage(self):
        (self.root / "reference.csv").write_text(
            "timestamp,generation_rate\n0,0\n1,10\n2,5\n3,15\n4,25\n"
        )
        self.case["reference"]["metrics"]["generation_rate"]["observation"] = "counter"
        r = self.run_case()
        self.assertEqual(r["status"], "INCOMPLETE")
        self.assertTrue(
            any(
                x["kind"] == "counter_reset"
                for x in r["metrics"]["generation_rate"]["reference_data_issues"]
            )
        )

    def test_counts_rebin_with_conservation(self):
        s = [(0, 0.5, 20, [2]), (0.5, 2, 10, [3])]
        b = rebin(s, [0, 1, 2])
        self.assertEqual([v["value"] for v in b], [15, 10])
        self.assertEqual(sum(v["value"] for v in b), 25)

    def test_time_weighted_gauge_not_iteration_average(self):
        (self.root / "reference.csv").write_text(
            "timestamp,generation_rate\n0,10\n0.1,20\n1,30\n"
        )
        self.case["reference"]["metrics"]["generation_rate"]["observation"] = (
            "gauge_hold"
        )
        source = load_source(self.root, self.case["reference"])
        segments, _ = source_segments(
            source, self.case["reference"]["metrics"]["generation_rate"]
        )
        self.assertAlmostEqual(rebin(segments, [0, 1])[0]["value"], 19)

    def test_gap_not_carried_forward(self):
        (self.root / "reference.csv").write_text(
            "timestamp,generation_rate\n0,10\n4,10\n"
        )
        self.case["reference"]["metrics"]["generation_rate"]["observation"] = (
            "gauge_hold"
        )
        self.assertEqual(
            self.run_case()["metrics"]["generation_rate"]["comparable_bins"], 0
        )

    def test_duplicate_timestamps_rejected(self):
        (self.root / "reference.csv").write_text(
            "timestamp,generation_rate\n1,10\n1,20\n"
        )
        with self.assertRaises(ContractError):
            self.run_case()

    def test_no_policy_is_unscored(self):
        del self.case["metrics"][0]["acceptance"]
        self.assertEqual(
            self.run_case()["metrics"]["generation_rate"]["status"], "UNSCORED"
        )

    def test_millisecond_clock_alignment(self):
        (self.root / "reference.csv").write_text(
            "timestamp,generation_rate\n11000,10\n12000,10\n13000,10\n14000,10\n"
        )
        self.case["reference"]["clock"].update(unit="ms", origin=10000)
        self.assertEqual(self.run_case()["metrics"]["generation_rate"]["mae"], 5)

    def test_reports_valid_json_and_refuse_overwrite(self):
        out = self.root / "report"
        write_report(self.run_case(), out)
        json.loads((out / "summary.json").read_text())
        with self.assertRaises(ContractError):
            write_report(self.run_case(), out)


if __name__ == "__main__":
    unittest.main()
