import argparse
import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from validation.bundles import pair
from validation.capture import (
    expected_tokens,
    metric_declarations,
    normalize_trace,
    run_sim,
    scheduler_paths,
)
from validation.validator import ContractError, compare


def state(running=0, waiting=0, tokens=0):
    return {
        "running_requests": running,
        "waiting_requests": waiting,
        "generation_tokens_total": tokens,
    }


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.trace = self.root / "trace.jsonl"
        self.output = self.root / "engine.csv"

    def write_trace(self, frames):
        self.trace.write_text(
            "".join(
                json.dumps({"time_s": time, "state": value}) + "\n"
                for time, value in frames
            )
        )

    def test_counts_remain_steps_and_idle_extension_preserves_per_scope_totals(self):
        self.write_trace(
            [
                (0, {"schedulers": [state(1), state(1)]}),
                (0.7, {"schedulers": [state(tokens=2), state(1, tokens=1)]}),
                (1.2, {"schedulers": [state(tokens=2), state(tokens=3)]}),
            ]
        )
        paths = ["/schedulers/0", "/schedulers/1"]
        result = normalize_trace(self.trace, self.output, paths, 2, 0.5)
        self.assertEqual(result["generation_tokens_by_path"], dict(zip(paths, [2, 3])))
        self.assertEqual(result["last_engine_event_s"], 1.2)
        with self.output.open() as stream:
            rows = list(csv.DictReader(stream))
        self.assertEqual(
            [int(row["/schedulers/0/generation_tokens_total"]) for row in rows],
            [0, 0, 2, 2, 2],
        )
        self.assertEqual(
            [int(row["/schedulers/1/generation_tokens_total"]) for row in rows],
            [0, 0, 1, 3, 3],
        )
        declarations = metric_declarations(paths)
        self.assertEqual(len(declarations), 6)
        self.assertEqual(
            declarations["/schedulers/1/generation_rate"]["dimensions"],
            {"path": "/schedulers/1"},
        )

    def test_nested_and_pd_scopes_follow_configuration_paths(self):
        single = {"scheduler": {"kind": "chunked_prefill"}}
        config = {
            "instances": [
                single,
                {"prefill_instances": [single], "decode_instances": [single]},
            ]
        }
        self.assertEqual(
            scheduler_paths(config),
            [
                "/instances/0/scheduler",
                "/instances/1/decode_instances/0/scheduler",
                "/instances/1/prefill_instances/0/scheduler",
            ],
        )
        with self.assertRaisesRegex(ContractError, "unsupported"):
            scheduler_paths({"scheduler": {"kind": "unknown"}})

    def test_incomplete_horizon_and_undrained_trace_are_rejected(self):
        self.write_trace(
            [(0, {"scheduler": state(1)}), (2, {"scheduler": state(tokens=1)})]
        )
        with self.assertRaisesRegex(ContractError, "horizon"):
            normalize_trace(self.trace, self.output, ["/scheduler"], 1, 0.5)
        self.write_trace([(0, {"scheduler": state(1)})])
        with self.assertRaisesRegex(ContractError, "drain"):
            normalize_trace(self.trace, self.output, ["/scheduler"], 1, 0.5)

    def test_missing_scope_reset_and_noninteger_metrics_are_rejected(self):
        bad = [
            None,
            {"other": state()},
            {"scheduler": None},
            {"scheduler": state(tokens=0.5)},
            {"scheduler": state(tokens=True)},
            {"scheduler": state(tokens=0)},
            {"scheduler": state(tokens=1), "instances": [{"scheduler": state()}]},
        ]
        for value in bad:
            with self.subTest(value=value):
                self.write_trace([(0, {"scheduler": state(tokens=1)}), (1, value)])
                with self.assertRaises(ContractError):
                    normalize_trace(self.trace, self.output, ["/scheduler"], 1, 0.5)

    def test_missing_origin_duplicate_times_and_bad_sampling_are_rejected(self):
        for times in ([1], [0, 0], [0, -1], [0, float("nan")]):
            self.write_trace([(time, {"scheduler": state()}) for time in times])
            with self.assertRaises(ContractError):
                normalize_trace(self.trace, self.output, ["/scheduler"], 1, 0.5)
        for duration, interval in [(0, 1), (1, 0), (float("inf"), 1), (1, 1e-12)]:
            with self.assertRaises(ContractError):
                normalize_trace(
                    self.trace, self.output, ["/scheduler"], duration, interval
                )

    def capture_args(self):
        workload = self.root / "workload.jsonl"
        workload.write_text(
            json.dumps(
                {
                    "request_id": 0,
                    "arrival_time": 0,
                    "initial": [0],
                    "sub_requests": [
                        {
                            "kind": "llm",
                            "input_tokens": 4,
                            "output_tokens": 1,
                            "next": [],
                        }
                    ],
                }
            )
            + "\n"
        )
        config = self.root / "config.toml"
        config.write_text('[system.scheduler]\nkind = "chunked_prefill"\n')
        environment = self.root / "environment.json"
        environment.write_text(
            json.dumps(
                {
                    "model": "synthetic",
                    "model_revision": "test",
                    "hardware": "none",
                    "deployment": {},
                    "serving_config": {},
                }
            )
        )
        return argparse.Namespace(
            workload=workload,
            config=config,
            environment=environment,
            binary=Path(sys.executable),
            out=self.root / "capture",
            duration=1.0,
            interval=0.5,
            revision="synthetic",
        )

    def test_failed_process_leaves_incomplete_receipt(self):
        args = self.capture_args()
        with patch("validation.capture.subprocess.run") as process:
            process.return_value.returncode = 1
            with self.assertRaisesRegex(ContractError, "simulator failed"):
                run_sim(args)
        receipt = json.loads((args.out / "bundle.json").read_text())
        self.assertEqual(receipt["status"], "INCOMPLETE")
        self.assertEqual(receipt["exit_code"], 1)
        self.assertTrue(receipt["error"])

    def test_capture_to_comparison_retains_identities_and_metric_semantics(self):
        args = self.capture_args()

        def execute(command, **_):
            trace = Path(command[command.index("--output-engine-trace") + 1])
            trace.write_text(
                json.dumps({"time_s": 0, "state": {"scheduler": state(1)}})
                + "\n"
                + json.dumps({"time_s": 0.7, "state": {"scheduler": state(tokens=1)}})
                + "\n"
            )
            Path(command[command.index("--output-jsonl") + 1]).write_text(
                "synthetic results\n"
            )
            return argparse.Namespace(returncode=0)

        with patch("validation.capture.subprocess.run", side_effect=execute):
            receipt = run_sim(args)
        self.assertEqual(receipt["status"], "COMPLETE")
        comparison = self.root / "comparison.json"
        comparison.write_text(
            json.dumps({"comparison_id": "synthetic", "bin_s": 0.5, "max_gap_s": 0.51})
        )
        out = self.root / "pair"
        pair(
            argparse.Namespace(
                reference=args.out,
                candidate=args.out,
                policy=comparison,
                case_id="self-check",
                data_kind="synthetic",
                allow_heldout=False,
                out=out,
            )
        )
        report = compare(out / "case.json")
        self.assertEqual(report["analysis_status"], "ANALYZED")
        self.assertEqual(report["metrics"]["/scheduler/generation_rate"]["mae"], 0)
        self.assertIsNone(report["accuracy_verdict"])

    def test_capture_refuses_dependency_driven_workloads(self):
        args = self.capture_args()
        row = json.loads(args.workload.read_text())
        row["sub_requests"][0]["interval"] = 1
        args.workload.write_text(json.dumps(row))
        with self.assertRaisesRegex(ContractError, "fixed-arrival"):
            expected_tokens(args.workload)


if __name__ == "__main__":
    unittest.main()
