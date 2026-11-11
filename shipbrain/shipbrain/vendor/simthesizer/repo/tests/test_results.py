import copy
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from compare import compare
from results import (
    Run,
    load_run,
    load_runs,
    match_runs,
    measurements,
    paired_errors,
    parse_request,
    relative_error,
    summarize,
    throughput,
    timeline,
)


def llm(latencies, **overrides):
    return {
        "kind": "llm",
        "input_tokens": 4,
        "output_tokens": len(latencies),
        "next": [],
        "token_latency": latencies,
        **overrides,
    }


def request(nodes=None, request_id=0, arrival=0, initial=None):
    return {
        "request_id": request_id,
        "arrival_time": arrival,
        "initial": [0] if initial is None else initial,
        "sub_requests": [llm([1, 2, 3])] if nodes is None else nodes,
    }


def run(*rows, label="test"):
    return Run(
        label,
        Path(f"{label}.jsonl"),
        {row["request_id"]: parse_request(copy.deepcopy(row)) for row in rows},
    )


class MetricsTests(unittest.TestCase):
    def test_call_and_token_weighting_and_single_token_response(self):
        result = measurements(
            run(
                request(),
                request([llm([4, 5])], request_id=1),
                request([llm([7])], request_id=2),
            )
        )
        self.assertEqual(list(result["ttft"].values()), [1, 4, 7])
        self.assertEqual(list(result["e2e"].values()), [6, 9, 7])
        self.assertEqual(list(result["normalized_e2e"].values()), [2, 4.5, 7])
        self.assertEqual(list(result["tpot"].values()), [2.5, 5])
        self.assertEqual(list(result["itl"].values()), [2, 3, 5])
        self.assertEqual(summarize(result["tpot"], [50])["mean"], 3.75)
        self.assertAlmostEqual(summarize(result["itl"], [50])["mean"], 10 / 3)
        self.assertEqual(result["makespan"], {(): 9})
        self.assertEqual(result["output_throughput"], {(): 6 / 9})
        self.assertEqual(result["request_throughput"], {(): 3 / 9})

    def test_dag_intervals_fork_join_and_tool_tail(self):
        tool = {
            "kind": "tool_call",
            "input_tokens": 0,
            "output_tokens": 0,
            "duration": 4,
            "interval": 1,
            "next": [3],
        }
        tail = {**tool, "duration": 2, "interval": 0, "next": []}
        row = request(
            [
                llm([1, 1], interval=2, next=[1, 2]),
                llm([2], interval=3, next=[3]),
                tool,
                llm([1, 2], interval=2, next=[4]),
                tail,
            ],
            arrival=10,
        )
        result = run(row)
        starts, ends = timeline(result.requests[0])
        self.assertEqual(starts, [12, 17, 15, 21, 24])
        self.assertEqual(ends, [14, 19, 19, 24, 26])
        self.assertEqual(list(result.token_times()), [13, 14, 19, 22, 24])
        measured = measurements(result)
        self.assertEqual(measured["request_e2e"], {(0,): 16})
        self.assertEqual(measured["ttft"], {(0, 0): 1, (0, 1): 2, (0, 3): 1})
        self.assertEqual(measured["makespan"], {(): 16})
        self.assertEqual(measured["output_throughput"], {(): 5 / 16})

    def test_multiple_roots_order_is_irrelevant(self):
        result = run(request([llm([1]), llm([2])], initial=[1, 0]))
        self.assertEqual(measurements(result)["request_e2e"], {(0,): 2})

    def test_identity_and_scaled_predictions(self):
        reference = run(request(), label="real")
        candidate = run(request([llm([2, 4, 6])]), label="sim")
        report = compare(
            [reference, candidate],
            ["ttft", "tpot", "e2e", "makespan", "output_throughput"],
            [50, 95],
        )
        for row in report["metrics"]:
            expected = -50 if row["metric"] == "output_throughput" else 100
            self.assertEqual(row["relative_error_pct"]["mean"], expected)
            if row["paired"] is not None:
                self.assertEqual(row["paired"]["mape_pct"], abs(expected))
        identity = compare([reference, reference], ["ttft", "tpot", "e2e"], [50, 95])
        for row in identity["metrics"]:
            self.assertEqual(row["paired"]["mae"], 0)
            self.assertEqual(row["paired"]["mape_pct"], 0)
            self.assertEqual(set(row["relative_error_pct"].values()), {0})

    def test_pairing_exposes_swapped_latencies_with_identical_distributions(self):
        reference = {(1,): 1, (2,): 3}
        candidate = {(2,): 1, (1,): 3}
        self.assertEqual(summarize(reference, [50, 95]), summarize(candidate, [50, 95]))
        errors = paired_errors(reference, candidate)
        self.assertEqual(errors["mae"], 2)
        self.assertEqual(errors["bias"], 0)
        self.assertEqual(errors["wape_pct"], 100)
        self.assertAlmostEqual(errors["mape_pct"], 400 / 3)

    def test_zero_denominators_are_explicit(self):
        errors = paired_errors({0: 0, 1: 2}, {0: 5, 1: 1})
        self.assertEqual(
            errors,
            {
                "count": 2,
                "mae": 3,
                "bias": 2,
                "mape_pct": 50,
                "mape_count": 1,
                "wape_pct": 300,
            },
        )
        self.assertIsNone(relative_error(0, 0))
        self.assertIsNone(relative_error(0, 3))
        self.assertIsNone(paired_errors({0: 0}, {0: 3})["wape_pct"])
        self.assertEqual(paired_errors({}, {})["count"], 0)
        self.assertEqual(summarize({}, [95]), {"mean": None, "p95": None})
        result = measurements(run(request([llm([0])], arrival=10)))
        self.assertEqual(result["tpot"], {})
        self.assertEqual(result["itl"], {})
        self.assertEqual(result["output_throughput"], {})
        report = compare(
            [
                run(request([llm([0])]), label="real"),
                run(request([llm([1])]), label="sim"),
            ],
            ["ttft", "output_throughput"],
            [50],
        )
        self.assertIsNone(report["metrics"][1]["relative_error_pct"]["mean"])
        self.assertEqual(report["metrics"][1]["prediction"]["mean"], 1)

    def test_percentile_uses_linear_interpolation(self):
        self.assertEqual(
            summarize({0: 1, 1: 3}, [0, 50, 95, 100]),
            {"mean": 2, "p0": 1, "p50": 2, "p95": 2.9, "p100": 3},
        )

    def test_throughput_preserves_tokens_boundaries_and_idle_time(self):
        result = run(
            request([llm([0, 0.5, 0.5])], arrival=10),
            request([llm([0.5])], request_id=1, arrival=12),
        )
        edges, rates = throughput(result, 1, 4)
        self.assertEqual(edges, [0, 1, 2, 3, 4, 5])
        self.assertEqual(rates, [2, 1, 1, 0, 0])
        self.assertEqual(sum(rates), 4)
        self.assertEqual(measurements(result)["makespan"], {(): 2.5})


class ValidationTests(unittest.TestCase):
    def test_rejects_incomplete_or_invalid_timings(self):
        for node in [
            llm([1], output_tokens=2),
            llm([1, 2], output_tokens=1),
            llm([math.nan]),
            llm([math.inf]),
            llm([-1]),
            llm([True]),
            llm([1], interval=-1),
        ]:
            with self.subTest(node=node), self.assertRaises(ValueError):
                run(request([node]))

    def test_rejects_invalid_dags(self):
        rows = [
            request([llm([1], next=[1])]),
            request([llm([1], next=[0])], initial=[]),
            request([llm([1]), llm([1], next=[1])]),
            request([llm([1]), llm([1])], initial=[0]),
            request([llm([1], next=[1, 1]), llm([1])]),
            request(initial=[0, 0]),
            request(nodes=[]),
        ]
        for row in rows:
            with self.subTest(row=row), self.assertRaises(ValueError):
                run(row)

    def test_matching_checks_workload_but_tolerates_absent_trace(self):
        reference = run(request([llm([1], input_token_ids=[1, 2, 3, 4])]))
        match_runs(reference, run(request([llm([2])]), label="candidate"))
        for row in [
            request([llm([2])], request_id=1),
            request([llm([2])], arrival=1),
            request([llm([2], interval=1)]),
            request([llm([2], input_tokens=5)]),
            request([llm([2], input_token_ids=[4, 3, 2, 1])]),
            request([llm([2, 2])]),
        ]:
            with self.subTest(row=row), self.assertRaises(ValueError):
                match_runs(reference, run(row, label="candidate"))

    def test_loader_reports_line_and_duplicate_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.jsonl"
            path.write_text(json.dumps(request()) + "\n" + json.dumps(request()))
            with self.assertRaisesRegex(ValueError, r":2: duplicate request_id"):
                load_run(str(path))
            path.write_text("{bad json}\n")
            with self.assertRaisesRegex(ValueError, r":1:"):
                load_run(str(path))
            path.write_text("\n")
            with self.assertRaisesRegex(ValueError, "empty result"):
                load_run(str(path))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.reference = self.root / "real.jsonl"
        self.candidate = self.root / "sim.jsonl"
        self.reference.write_text(json.dumps(request()) + "\n")
        self.candidate.write_text(json.dumps(request([llm([2, 4, 6])])) + "\n")

    def command(self, script, *arguments):
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / script),
                str(self.reference),
                str(self.candidate),
                *map(str, arguments),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_compare_report_and_multiple_candidates(self):
        output = self.root / "report.json"
        process = self.command(
            "compare.py",
            f"repeat={self.reference}",
            "--output",
            output,
            "--metrics",
            "ttft",
            "tpot",
            "--percentiles",
            "50",
            "99",
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        report = json.loads(output.read_text())
        self.assertEqual(len(report["metrics"]), 4)
        self.assertEqual(report["metrics"][0]["paired"]["mape_pct"], 100)
        self.assertIn("MAPE %", process.stdout)
        self.assertIn("p99", process.stdout)

    def test_compare_failure_does_not_create_report(self):
        output = self.root / "report.json"
        self.candidate.write_text(json.dumps(request([llm([1])])) + "\n")
        process = self.command("compare.py", "--output", output)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("output_tokens differs", process.stderr)
        self.assertFalse(output.exists())

    def test_output_cannot_replace_input(self):
        before = self.reference.read_bytes()
        for script in ("compare.py", "draw.py"):
            process = self.command(script, "--output", self.reference)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("overwrite", process.stderr)
            self.assertEqual(self.reference.read_bytes(), before)

    def test_rejects_duplicate_labels(self):
        with self.assertRaisesRegex(ValueError, "duplicate run labels"):
            load_runs([str(self.reference), str(self.reference)])

    def test_draw_cdf_scatter_and_time_series(self):
        try:
            import matplotlib  # noqa: F401
        except ImportError:
            self.skipTest("matplotlib is required for drawing")
        for view, suffix in (("cdf", "svg"), ("scatter", "png")):
            output = self.root / f"{view}.{suffix}"
            process = self.command(
                "draw.py",
                "--output",
                output,
                "--view",
                view,
                "--metrics",
                "ttft",
                "tpot",
                "throughput",
                "cumulative",
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertGreater(output.stat().st_size, 1000)
        svg = (self.root / "cdf.svg").read_text()
        self.assertIn("Time since first arrival", svg)
        self.assertIn("TTFT", svg)


if __name__ == "__main__":
    unittest.main()
