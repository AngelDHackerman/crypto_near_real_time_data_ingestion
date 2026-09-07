"""
Verification of ml/training/splitting.py.  roadmap.md Phase 8.

The two things in a training pipeline that are wrong most often and visible
least often are the split and the metric. A leaking split reports a great
number; a metric chosen badly reports a great number for a model that always
says no. Both fail silently and both are checkable without a GPU, a container
or an AWS account -- so they are checked here, in under a second.

Run: python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ml", "training"))

from splitting import (  # noqa: E402
    average_precision,
    positive_rate_baseline,
    purged_time_split,
    scale_pos_weight,
)

MIN = 60
HOUR = 3600


class TestPurgedTimeSplit(unittest.TestCase):
    def test_splits_are_chronological_and_disjoint(self):
        times = [i * MIN for i in range(1000)]
        (a0, a1), (b0, b1), (c0, c1) = purged_time_split(times, embargo_seconds=HOUR)

        self.assertLess(a0, a1)
        self.assertLess(b0, b1)
        self.assertLess(c0, c1)
        # Ordered, and separated -- not merely non-overlapping.
        self.assertLess(a1, b0)
        self.assertLess(b1, c0)

    def test_embargo_is_at_least_the_label_horizon_wide(self):
        # The whole point: a row in training must not be labelled by an outcome
        # that lands in validation. With a 60-minute horizon, the gap between
        # the last training timestamp and the first validation timestamp has to
        # exceed 60 minutes.
        times = [i * MIN for i in range(1000)]
        (_, a1), (b0, _), _ = purged_time_split(times, embargo_seconds=HOUR)

        last_train = times[a1 - 1]
        first_valid = times[b0]
        self.assertGreater(first_valid - last_train, HOUR)

    def test_zero_embargo_leaks_and_the_test_proves_it(self):
        # The negative control. Without an embargo the boundary is touching,
        # which is exactly the leak the embargo exists to remove -- asserted so
        # that "the embargo does something" is demonstrated rather than assumed.
        times = [i * MIN for i in range(1000)]
        (_, a1), (b0, _), _ = purged_time_split(times, embargo_seconds=0)
        self.assertLessEqual(times[b0] - times[a1 - 1], MIN)

    def test_uneven_spacing_is_handled_in_time_not_rows(self):
        # A gappy series: dense for a while, then one bar an hour. A row-count
        # embargo would cover minutes here and hours there.
        times = [i * MIN for i in range(500)] + [500 * MIN + i * HOUR for i in range(500)]
        (_, a1), (b0, _), _ = purged_time_split(times, embargo_seconds=HOUR)
        self.assertGreater(times[b0] - times[a1 - 1], HOUR)

    def test_series_too_short_for_the_embargo_yields_empty_not_negative(self):
        times = [i * MIN for i in range(10)]
        _, (b0, b1), _ = purged_time_split(times, embargo_seconds=10 * HOUR)
        self.assertGreaterEqual(b1, b0)  # empty, never inverted

    def test_empty_input(self):
        self.assertEqual(purged_time_split([]), ((0, 0), (0, 0), (0, 0)))

    def test_rejects_fractions_that_leave_no_test_set(self):
        with self.assertRaises(ValueError):
            purged_time_split([1, 2, 3], train_frac=0.8, valid_frac=0.3)


class TestAveragePrecision(unittest.TestCase):
    def test_perfect_ranking(self):
        # Every positive scored above every negative: AP is 1 by definition.
        self.assertAlmostEqual(average_precision([1, 1, 0, 0], [0.9, 0.8, 0.2, 0.1]), 1.0, places=12)

    def test_worst_ranking(self):
        # Both positives last. Precision is 1/3 at the first positive and 2/4 at
        # the second, each contributing half the recall:
        #   0.5 * (1/3) + 0.5 * (2/4) = 1/6 + 1/4 = 5/12
        self.assertAlmostEqual(average_precision([0, 0, 1, 1], [0.9, 0.8, 0.2, 0.1]), 5 / 12, places=12)

    def test_hand_computed_middle_case(self):
        # Ranked: 1, 0, 1, 0.  Precision at the two positives is 1/1 and 2/3,
        # each adding 0.5 recall -> 0.5 * 1 + 0.5 * (2/3) = 5/6.
        self.assertAlmostEqual(average_precision([1, 0, 1, 0], [0.9, 0.8, 0.7, 0.6]), 5 / 6, places=12)

    def test_ties_do_not_depend_on_input_order(self):
        # All scores equal: the metric must not change when the rows are
        # permuted. Without tie handling this returns different values for the
        # two orderings, which makes a model's score depend on how its rows
        # happened to come off S3.
        a = average_precision([1, 0, 1, 0], [0.5] * 4)
        b = average_precision([0, 1, 0, 1], [0.5] * 4)
        self.assertAlmostEqual(a, b, places=12)
        self.assertAlmostEqual(a, 0.5, places=12)

    def test_no_positives_is_undefined_not_zero(self):
        # Zero would be a score, and a score invites comparison.
        self.assertIsNone(average_precision([0, 0, 0], [0.9, 0.5, 0.1]))

    def test_an_always_no_model_scores_the_positive_rate(self):
        # THE POINT OF CHOOSING THIS METRIC. A constant predictor -- the model
        # that would score ~93% accuracy on this data and be worthless -- gets
        # exactly the positive rate here, which is the floor every reported
        # PR-AUC must be quoted against.
        y = [1] * 7 + [0] * 93
        constant = [0.42] * 100
        self.assertAlmostEqual(average_precision(y, constant), 0.07, places=12)
        self.assertAlmostEqual(positive_rate_baseline(y), 0.07, places=12)

    def test_length_mismatch_is_rejected(self):
        with self.assertRaises(ValueError):
            average_precision([1, 0], [0.5])


class TestClassWeight(unittest.TestCase):
    def test_negatives_per_positive(self):
        self.assertAlmostEqual(scale_pos_weight([1] * 10 + [0] * 90), 9.0, places=12)

    def test_no_positives_falls_back_to_one(self):
        self.assertEqual(scale_pos_weight([0, 0, 0]), 1.0)


if __name__ == "__main__":
    unittest.main()
