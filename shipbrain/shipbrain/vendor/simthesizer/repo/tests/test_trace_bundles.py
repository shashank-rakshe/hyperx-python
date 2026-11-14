import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from validation.bundles import ContractError, object_hash, pair
from validation.validator import digest


class BundleTests(unittest.TestCase):
    def test_pair_enforces_hashes_and_heldout_boundary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {
                "model": "mock",
                "model_revision": "fixture",
                "hardware": "none",
                "deployment": {"tp": 1},
                "serving_config": {},
            }
            for role in ["ref", "sim"]:
                p = root / role
                p.mkdir()
                (p / "workload.jsonl").write_text("fixture")
                (p / "environment.json").write_text(json.dumps(env))
                (p / "engine.csv").write_text(
                    "time_s,running_requests,waiting_requests,generation_tokens_total\n0,0,0,0\n1,0,0,0\n"
                )
                r = {
                    "metrics": {},
                    "status": "COMPLETE",
                    "run_id": role,
                    "workload_sha256": digest(p / "workload.jsonl"),
                    "environment_sha256": object_hash(env),
                    "clock": {
                        "column": "time_s",
                        "origin": 0,
                        "unit": "s",
                        "basis": "workload_start",
                        "evidence": "fixture",
                    },
                    "capture_duration_s": 1,
                    "producer_revision": "fixture",
                    "sample_interval_s": 0.1,
                    "split": "heldout",
                    "split_group": "h",
                    "artifacts": {
                        n: digest(p / n)
                        for n in ["workload.jsonl", "environment.json", "engine.csv"]
                    },
                }
                (p / "bundle.json").write_text(json.dumps(r))
            policy = root / "policy.json"
            policy.write_text(
                json.dumps(
                    {
                        "policy_id": "test",
                        "bin_s": 1,
                        "max_gap_s": 1.1,
                        "metrics": [{"name": "generation_rate"}],
                    }
                )
            )
            args = argparse.Namespace(
                reference=root / "ref",
                candidate=root / "sim",
                policy=policy,
                out=root / "pair",
                allow_heldout=False,
                case_id="test",
                data_kind="synthetic",
            )
            with self.assertRaises(ContractError):
                pair(args)
            args.allow_heldout = True
            case = pair(args)
            self.assertEqual(case["split"], "heldout")
            file_args = argparse.Namespace(**vars(args))
            file_args.reference = args.reference / "bundle.json"
            file_args.candidate = args.candidate / "bundle.json"
            file_args.out = root / "receipt-pair"
            self.assertEqual(
                pair(file_args)["reference"]["path"], case["reference"]["path"]
            )
            file_args.candidate = args.candidate / "engine.csv"
            with self.assertRaisesRegex(
                ContractError, "bundle directory or its bundle.json"
            ):
                pair(file_args)
            # Pairing preserves adapter clocks instead of manufacturing origin zero.
            receipt_path = args.candidate / "bundle.json"
            receipt = json.loads(receipt_path.read_text())
            receipt["clock"]["origin"] = 4
            receipt_path.write_text(json.dumps(receipt))
            args.out = root / "clock-pair"
            self.assertEqual(pair(args)["candidate"]["clock"]["origin"], 4)
            del receipt["clock"]["evidence"]
            receipt_path.write_text(json.dumps(receipt))
            args.out = root / "missing-clock"
            with self.assertRaises(ContractError):
                pair(args)
            receipt["clock"]["evidence"] = "fixture"
            receipt_path.write_text(json.dumps(receipt))
            (args.candidate / "engine.csv").write_text("changed")
            with self.assertRaises(ContractError):
                pair(args)


if __name__ == "__main__":
    unittest.main()
