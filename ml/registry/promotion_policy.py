"""
The promotion decision, as a pure function.  roadmap.md Phase 9.

Phase 9's DoD says promotion is "scripted, not clicked". A script that calls
UpdateModelPackage is not what that means -- clicking Approve in a console and
running a script that approves unconditionally are the same decision made by the
same person, one of them just faster. What makes it scripted is that the
CRITERIA are code: written down, reviewable in a diff, and testable.

So the rule lives here, with no boto3 and no AWS, and tests/test_promotion.py
checks it in milliseconds. `promote_model.py` does the talking to SageMaker and
contains no judgement at all.

Phase 13 extends this with the latency gate once Phase 10 measures one. The
shape is already here: add a check, add a reason string, add a test.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Candidate:
    """What a model has to declare about itself to be considered."""

    version: str
    pr_auc: float | None
    positive_rate: float | None
    lift: float | None
    feature_block_version: str
    label_version: str
    rows_validation: int = 0
    latency_p95_ms: float | None = None


@dataclass
class Decision:
    promote: bool
    reasons: list[str] = field(default_factory=list)


# A challenger has to be better by a margin, not merely different. Two models
# trained on overlapping windows differ by noise in the third decimal, and a
# rule that promotes on any improvement promotes noise -- which then becomes the
# champion the NEXT candidate has to beat, so the registry drifts on a random
# walk while every individual step looked like progress.
MIN_LIFT_IMPROVEMENT = 0.05  # 5% relative

# Below this, the model is not beating "flag everything" by enough to be worth
# deploying, whatever it beats the incumbent by.
MIN_ABSOLUTE_LIFT = 1.10

# A validation set this small cannot distinguish a good model from a lucky one.
MIN_VALIDATION_ROWS = 5000

# Phase 10 fills this in; until then latency is simply not asserted rather than
# assumed to pass. See `require_latency` below.
MAX_LATENCY_P95_MS = 500.0


def decide(candidate: Candidate, champion: Candidate | None, *, require_latency: bool = False) -> Decision:
    """Should `candidate` replace `champion` in production?

    Returns every reason, not the first failure. A candidate rejected for three
    reasons and a candidate rejected for one are different situations, and the
    person reading the log is trying to decide what to change.
    """
    reasons: list[str] = []

    if candidate.lift is None or candidate.pr_auc is None:
        return Decision(False, ["candidate has no metrics; a model that cannot report is not a model that can ship"])

    if candidate.rows_validation < MIN_VALIDATION_ROWS:
        reasons.append(
            f"validation set too small: {candidate.rows_validation} < {MIN_VALIDATION_ROWS}"
        )

    if candidate.lift < MIN_ABSOLUTE_LIFT:
        reasons.append(
            f"lift {candidate.lift:.3f} is below the absolute floor {MIN_ABSOLUTE_LIFT}: "
            "it barely beats flagging every row"
        )

    if require_latency:
        if candidate.latency_p95_ms is None:
            reasons.append("latency was required but not measured")
        elif candidate.latency_p95_ms > MAX_LATENCY_P95_MS:
            reasons.append(f"p95 latency {candidate.latency_p95_ms:.0f}ms exceeds {MAX_LATENCY_P95_MS:.0f}ms")

    if champion is None:
        # Nothing in production. The floors above are the only bar, which is
        # correct: the first model cannot be asked to beat a predecessor.
        return Decision(not reasons, reasons or ["first model: no champion to beat"])

    # THE COMPARISON IS ONLY MEANINGFUL WITHIN ONE TARGET AND ONE FEATURE SET.
    # Comparing a model trained on h60m_t20bps against one trained on
    # h240m_t50bps is comparing answers to two different questions, and the
    # bigger number wins for reasons that have nothing to do with the model.
    # This is why both versions travel on every row and into the registry.
    if candidate.label_version != champion.label_version:
        reasons.append(
            f"label definition changed ({champion.label_version} -> {candidate.label_version}); "
            "these numbers are not comparable"
        )
    if candidate.feature_block_version != champion.feature_block_version:
        reasons.append(
            f"feature definition changed ({champion.feature_block_version} -> "
            f"{candidate.feature_block_version}); these numbers are not comparable"
        )

    if champion.lift is not None:
        required = champion.lift * (1 + MIN_LIFT_IMPROVEMENT)
        if candidate.lift < required:
            reasons.append(
                f"lift {candidate.lift:.3f} does not clear the champion's "
                f"{champion.lift:.3f} by {MIN_LIFT_IMPROVEMENT:.0%} (needs {required:.3f})"
            )

    return Decision(not reasons, reasons or [f"lift {candidate.lift:.3f} beats champion {champion.lift:.3f}"])
