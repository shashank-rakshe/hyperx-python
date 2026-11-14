# SPDX-License-Identifier: Apache-2.0
"""The rainflow count and damage-equivalent load of validation/scripts/openfast_supercycle_ab.py."""

from __future__ import annotations

import importlib.util
import math
import unittest
from collections import Counter
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[1] / "validation" / "scripts" / "openfast_supercycle_ab.py"
_SPEC = importlib.util.spec_from_file_location("openfast_supercycle_ab", _SCRIPT)
ab = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(ab)

# ASTM E1049-85 (2017), Fig. 6: the rainflow counts of this history
_ASTM_HISTORY = [-2.0, 1.0, -3.0, 5.0, -1.0, 3.0, -4.0, 4.0, -2.0]
_ASTM_COUNTS = {3.0: 0.5, 4.0: 1.5, 6.0: 0.5, 8.0: 1.0, 9.0: 0.5}


def _counts(history):
    c = Counter()
    for r, n in ab.rainflow(history):
        c[r] += n
    return dict(c)


class RainflowTest(unittest.TestCase):
    def test_astm_example(self):
        self.assertEqual(_counts(_ASTM_HISTORY), _ASTM_COUNTS)

    def test_plateaus_count_once(self):
        # equal neighbours (a tension written to seven digits) neither add nor drop a turning point
        plateaued = [-2.0, 1.0, 1.0, -3.0, -3.0, 5.0, 5.0, 5.0, -1.0, 3.0, -4.0, 4.0, -2.0]
        self.assertEqual(_counts(plateaued), _ASTM_COUNTS)
        self.assertEqual(ab.turning_points([1.0, 2.0, 2.0, 1.0]), [1.0, 2.0, 1.0])

    def test_damage_equivalent_load(self):
        # a sine of amplitude A over N whole periods in T seconds: N full cycles of range 2A
        a, n, t = 3.0, 40, 200.0
        history = [a * ((-1.0) ** k) for k in range(2 * n + 1)]
        expected = (n * (2.0 * a) ** 3 / t) ** (1.0 / 3.0)
        self.assertAlmostEqual(ab.damage_equivalent_load(history, t, 3.0), expected, places=12)


class CompareChannelTest(unittest.TestCase):
    @staticmethod
    def _grid(values):
        return {k: [0.1 * k, v] for k, v in enumerate(values)}

    def test_truncated_twin_is_compared_over_its_overlap(self):
        # a run identical to the reference but ending at a tenth of it: no difference at all,
        # and the partial coverage is reported (the DEL is not set against the whole reference)
        ref = [3.0 * ((-1.0) ** k) * (1.0 + 0.01 * k) for k in range(1000)]
        c = ab.compare_channel(self._grid(ref[:100]), 1, self._grid(ref), 1, 0.1, 3.0)
        self.assertEqual(c["rel"], 0.0)
        self.assertEqual(c["ddel"], 0.0)
        self.assertAlmostEqual(c["covered"], 0.1)

    def test_a_scaled_run_changes_its_del_by_the_scale(self):
        ref = [3.0 * ((-1.0) ** k) for k in range(400)]
        c = ab.compare_channel(self._grid([1.02 * v for v in ref]), 1, self._grid(ref), 1, 0.1, 3.0)
        self.assertAlmostEqual(c["ddel"], 2.0, places=9)
        self.assertEqual(c["covered"], 1.0)

    def test_zero_damage_reference(self):
        # a constant tension has no cycles: identical constant histories change by 0 %, and a run
        # with cycles against a constant reference has an undefined change (not a crash)
        flat = [1000.0] * 200
        same = ab.compare_channel(self._grid(flat), 1, self._grid(flat), 1, 0.1, 3.0)
        self.assertEqual(same["del"], 0.0)
        self.assertEqual(same["ddel"], 0.0)
        wavy = ab.compare_channel(self._grid([1000.0 + (-1.0) ** k for k in range(200)]), 1,
                                  self._grid(flat), 1, 0.1, 3.0)
        self.assertGreater(wavy["del"], 0.0)
        self.assertTrue(math.isnan(wavy["ddel"]))

    def test_no_common_samples(self):
        self.assertIsNone(ab.compare_channel({0: [0.0, 1.0]}, 1, self._grid([1.0, 2.0, 3.0]), 1, 0.1, 3.0))
        self.assertEqual(ab.damage_equivalent_load([1.0, 2.0], 0.0, 3.0), 0.0)


if __name__ == "__main__":
    unittest.main()
