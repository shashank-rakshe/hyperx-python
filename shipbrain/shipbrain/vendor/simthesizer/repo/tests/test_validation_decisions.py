import argparse
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from validate import main
from validation.decisions import check_decision, write_decision


class DecisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "assessment.md").write_text("R1: observed expected completion.")
        self.args = argparse.Namespace(
            task_root=self.root,
            state=Path("validation-state.json"),
            action="complete",
            reason="R1 is supported under the tested conditions.",
            evidence=[Path("assessment.md")],
            pending_check=[],
            next_step=None,
            blocker=None,
        )

    def test_terminal_actions_require_finished_local_checks(self):
        for action, expected in [("complete", "COMPLETE"), ("blocked", "BLOCKED")]:
            with self.subTest(action=action):
                self.args.action = action
                self.args.blocker = "A matching target trace is unavailable."
                self.args.pending_check = ["Check allocation release."]
                self.assertEqual(write_decision(self.args)["status"], "CONTINUE")
                self.args.pending_check = []
                self.assertEqual(write_decision(self.args)["status"], expected)

    def test_missing_changed_and_deleted_evidence_prevent_completion(self):
        self.assertEqual(
            check_decision(self.root, self.args.state)["status"], "CONTINUE"
        )
        self.assertEqual(write_decision(self.args)["status"], "COMPLETE")
        (self.root / "assessment.md").write_text("R1 is now contradicted.")
        self.assertEqual(
            check_decision(self.root, self.args.state)["status"], "CONTINUE"
        )
        (self.root / "assessment.md").unlink()
        self.assertEqual(
            check_decision(self.root, self.args.state)["status"], "CONTINUE"
        )

    def test_each_round_requires_a_fresh_decision(self):
        first = write_decision(self.args)
        self.assertEqual(
            check_decision(self.root, self.args.state, first["state_sha256"])["status"],
            "CONTINUE",
        )
        write_decision(self.args)
        self.assertEqual(
            check_decision(self.root, self.args.state, first["state_sha256"])["status"],
            "COMPLETE",
        )

    def test_open_actions_need_next_step_and_blocked_needs_reason(self):
        for action in ("investigate", "revise"):
            self.args.action = action
            self.args.next_step = None
            self.assertTrue(write_decision(self.args)["issues"])
            self.args.next_step = "Run the pressure workload."
            result = write_decision(self.args)
            self.assertEqual(result["issues"], [])
            self.assertEqual(result["status"], "CONTINUE")
        self.args.action = "blocked"
        self.assertEqual(write_decision(self.args)["status"], "CONTINUE")

    def test_invalid_state_cannot_complete(self):
        for value in ([], {"schema_version": 1}, {"schema_version": 2}):
            (self.root / self.args.state).write_text(json.dumps(value))
            result = check_decision(self.root, self.args.state)
            self.assertEqual(result["status"], "CONTINUE")
            self.assertTrue(result["issues"])

    def test_paths_cannot_escape_task_root(self):
        with tempfile.TemporaryDirectory() as outside:
            (self.root / "escape").symlink_to(outside, target_is_directory=True)
            for name in (
                "../assessment.md",
                str(self.root / "assessment.md"),
                "escape/file",
            ):
                with self.subTest(name=name):
                    self.args.evidence = [Path(name)]
                    with self.assertRaises(ValueError):
                        write_decision(self.args)

    def test_cli_exit_codes_distinguish_recording_from_closure(self):
        common = ["--task-root", str(self.root)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(["check", *common]), 3)
            self.assertEqual(
                main(
                    [
                        "decide",
                        *common,
                        "--action",
                        "complete",
                        "--reason",
                        "R1 passed.",
                        "--evidence",
                        "assessment.md",
                        "--pending-check",
                        "Check R2.",
                    ]
                ),
                0,
            )
            self.assertEqual(main(["check", *common]), 3)
            write_decision(self.args)
            self.assertEqual(main(["check", *common]), 0)
            self.args.action = "blocked"
            self.args.blocker = "Need target measurements."
            write_decision(self.args)
            self.assertEqual(main(["check", *common]), 2)
            self.assertEqual(
                main(
                    [
                        "compare",
                        str(self.root / "missing.json"),
                        "--out",
                        str(self.root / "report"),
                    ]
                ),
                4,
            )


if __name__ == "__main__":
    unittest.main()
