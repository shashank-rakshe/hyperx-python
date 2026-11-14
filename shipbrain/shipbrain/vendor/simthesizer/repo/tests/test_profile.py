import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "profile_script", ROOT / "scripts/profile.py"
)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ReceiptTests(unittest.TestCase):
    def test_mixed_batches_preserve_order_and_expand_routing(self):
        cases = profile.expand_batches(
            [
                {
                    "requests": [
                        {"query": [8, 16]},
                        {"count": 2, "query": 1, "context": [128, 512]},
                    ],
                    "routing": {"model.moe": [4, 8]},
                }
            ]
        )
        self.assertEqual(len(cases), 8)
        self.assertEqual(
            cases[0],
            {
                "requests": [
                    {"query": 8, "context": 0, "phase": "prefill"},
                    {"query": 1, "context": 128, "phase": "decode"},
                    {"query": 1, "context": 128, "phase": "decode"},
                ],
                "routing": {"model.moe": 4},
            },
        )
        self.assertEqual(cases[-1]["requests"][0]["query"], 16)
        self.assertEqual(cases[-1]["routing"], {"model.moe": 8})

    def test_short_prefill_is_distinct_from_decode(self):
        cases = profile.expand_batches(
            [
                {"requests": [{"query": 1, "context": 8}]},
                {"requests": [{"query": 1, "context": 8, "phase": "prefill"}]},
                {"requests": [{"query": 1, "context": 8}]},
            ]
        )
        self.assertEqual(len(cases), 2)
        self.assertEqual(
            [case["requests"][0]["phase"] for case in cases], ["decode", "prefill"]
        )

    def test_invalid_batches_fail_before_loading_vllm(self):
        for group in (
            {"query": 0},
            {"query": True},
            {"query": 1, "count": []},
            {"query": 8, "phase": "decode", "context": 32},
            {"query": 1, "phase": "decode", "context": 0},
            {"query": 1, "context": -1},
            {"query": 1, "context_length": 512},
        ):
            with self.subTest(group=group), self.assertRaises(ValueError):
                profile.expand_batches([{"requests": [group]}])

    def test_variant_overrides_merge_without_mutating_base(self):
        base = {
            "model": "llama",
            "hf_overrides": {"num_hidden_layers": 1, "head_dim": 128},
        }
        actual = profile.merge(base, {"hf_overrides": {"num_attention_heads": 16}})
        self.assertEqual(
            actual["hf_overrides"],
            {"num_hidden_layers": 1, "head_dim": 128, "num_attention_heads": 16},
        )
        self.assertNotIn("num_attention_heads", base["hf_overrides"])

    def test_example_stays_within_engine_limits(self):
        receipt, cases = profile.load_receipt(
            ROOT / "examples/profiles/llama3_1_8b.toml"
        )
        self.assertEqual(len(cases), 29)
        for case in cases:
            requests = case["requests"]
            self.assertLessEqual(len(requests), receipt["engine"]["max_num_seqs"])
            self.assertLessEqual(
                sum(r["query"] for r in requests),
                receipt["engine"]["max_num_batched_tokens"],
            )
            self.assertTrue(
                all(
                    r["query"] + r["context"] <= receipt["engine"]["max_model_len"]
                    for r in requests
                )
            )


class MeasurementTests(unittest.TestCase):
    def test_inclusive_gpu_time_and_invocation_counts(self):
        def node(name, metrics, children=()):
            return {"frame": {"name": name}, "metrics": metrics, "children": children}

        tree = node(
            "ROOT",
            {},
            [
                node("setup_kernel", {"time (ns)": 2000, "count": 1}),
                node(
                    "component:decoder",
                    {"calls": 1},
                    [
                        node(
                            "component:norm",
                            {"calls": 2},
                            [
                                node("rms_norm", {"time (ns)": 6000, "count": 2}),
                            ],
                        ),
                        node("gemm", {"time (ns)": 10000, "count": 1}),
                    ],
                ),
                node(
                    "component:norm",
                    {"calls": 1},
                    [
                        node("rms_norm", {"time (ns)": 3000, "count": 1}),
                    ],
                ),
            ],
        )
        rows, total_us = profile.read_proton([tree, {"CUDA": {}}])
        self.assertEqual(total_us, 21)
        self.assertEqual(rows["decoder"], {"total_us": 16, "calls": 1, "kernels": 3})
        self.assertEqual(rows["norm"], {"total_us": 9, "calls": 3, "kernels": 3})

    def test_repeat_carries_hidden_and_residual_state(self):
        calls = []

        def block(positions, hidden_states, residual=None):
            calls.append((positions, hidden_states, residual))
            return hidden_states + 1, (residual or 0) + hidden_states

        repeated = profile.repeat_forward(block, 3)
        self.assertEqual(repeated(7, hidden_states=2), (5, 9))
        self.assertEqual(calls, [(7, 2, None), (7, 3, 2), (7, 4, 5)])

    def test_filename_does_not_break_cprofile_in_child_processes(self):
        subprocess.run(
            [
                sys.executable,
                "-c",
                "import cProfile, profile; assert cProfile.Profile; assert profile.Profile",
            ],
            cwd=ROOT / "scripts",
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
