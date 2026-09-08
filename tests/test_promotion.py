"""
Verification of ml/registry/promotion_policy.py.  roadmap.md Phase 9.

"Promotion is scripted, not clicked" is only true if the criteria are testable.
These are the cases that decide whether a registry accumulates progress or
drifts on a random walk while every step looks like an improvement.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ml", "registry"))

from promotion_policy import Candidate, decide  # noqa: E402


def model(version="2", lift=1.5, pr_auc=0.12, rows=50_000, feat="v1", label="h60m_t20bps", latency=None):
    return Candidate(
        version=version,
        pr_auc=pr_auc,
        positive_rate=0.08,
        lift=lift,
        feature_block_version=feat,
        label_version=label,
        rows_validation=rows,
        latency_p95_ms=latency,
    )


class TestPromotion(unittest.TestCase):
    def test_first_model_only_has_to_clear_the_floors(self):
        d = decide(model(lift=1.4), champion=None)
        self.assertTrue(d.promote)

    def test_first_model_below_the_absolute_floor_is_rejected(self):
        # 1.02 lift means the model barely beats flagging every row. There is no
        # champion to lose to, and it still should not ship.
        d = decide(model(lift=1.02), champion=None)
        self.assertFalse(d.promote)
        self.assertIn("absolute floor", " ".join(d.reasons))

    def test_a_clear_improvement_is_promoted(self):
        self.assertTrue(decide(model(lift=1.60), champion=model(version="1", lift=1.40)).promote)

    def test_a_worse_model_is_rejected(self):
        # The DoD line: "a worse model is rejected".
        d = decide(model(lift=1.20), champion=model(version="1", lift=1.40))
        self.assertFalse(d.promote)

    def test_a_marginal_improvement_is_rejected_as_noise(self):
        # 1.41 vs 1.40 is a third-decimal difference between two models trained
        # on overlapping windows. Promoting it makes noise the champion the next
        # candidate has to beat, and the registry random-walks upward while every
        # individual step looked like progress.
        d = decide(model(lift=1.41), champion=model(version="1", lift=1.40))
        self.assertFalse(d.promote)
        self.assertIn("does not clear", " ".join(d.reasons))

    def test_the_margin_boundary_is_where_it_says_it_is(self):
        champion = model(version="1", lift=1.40)
        self.assertFalse(decide(model(lift=1.40 * 1.05 - 1e-9), champion).promote)
        self.assertTrue(decide(model(lift=1.40 * 1.05 + 1e-9), champion).promote)

    def test_a_changed_label_makes_the_comparison_meaningless(self):
        # A model trained on a 240-minute horizon will show a bigger lift than
        # one trained on 60 minutes for reasons that have nothing to do with the
        # model. Blocked even though the number is higher.
        d = decide(model(lift=3.0, label="h240m_t50bps"), champion=model(version="1", lift=1.40))
        self.assertFalse(d.promote)
        self.assertIn("not comparable", " ".join(d.reasons))

    def test_a_changed_feature_version_is_blocked_the_same_way(self):
        d = decide(model(lift=3.0, feat="v2"), champion=model(version="1", lift=1.40))
        self.assertFalse(d.promote)

    def test_a_tiny_validation_set_is_rejected_however_good_it_looks(self):
        d = decide(model(lift=5.0, rows=100), champion=None)
        self.assertFalse(d.promote)
        self.assertIn("too small", " ".join(d.reasons))

    def test_missing_metrics_are_not_treated_as_zero(self):
        d = decide(Candidate("2", None, None, None, "v1", "h60m_t20bps", 50_000), champion=None)
        self.assertFalse(d.promote)

    def test_latency_gate_is_inert_until_required(self):
        # Phase 10 has not measured a latency yet. Not asserting it is right;
        # assuming it passes would be a gate that silently never fires.
        self.assertTrue(decide(model(latency=None), champion=None, require_latency=False).promote)
        self.assertFalse(decide(model(latency=None), champion=None, require_latency=True).promote)

    def test_latency_gate_rejects_a_slow_model(self):
        d = decide(model(latency=900.0), champion=None, require_latency=True)
        self.assertFalse(d.promote)
        self.assertIn("latency", " ".join(d.reasons))

    def test_every_failing_reason_is_reported_not_just_the_first(self):
        d = decide(model(lift=0.5, rows=10, label="other"), champion=model(version="1", lift=1.4))
        self.assertFalse(d.promote)
        self.assertGreaterEqual(len(d.reasons), 3)


if __name__ == "__main__":
    unittest.main()
