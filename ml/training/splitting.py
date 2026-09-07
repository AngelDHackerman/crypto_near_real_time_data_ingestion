"""
Time-series splitting and evaluation, with no ML dependencies.  roadmap.md Phase 8.

Separated from train.py on purpose. Everything in this file is the part of
training that can be WRONG IN A WAY THAT LOOKS RIGHT -- a split that leaks, a
metric that flatters an imbalanced class -- and none of it needs xgboost,
numpy, SageMaker or AWS to run. So it is imported by the training script and by
tests/test_splitting.py, and the tests run on any laptop in under a second.

That split of responsibilities is the same one Phase 7 made when it moved the
indicator maths into a SQL file: the code that is easy to get subtly wrong
should be the code that is cheapest to verify.
"""

from __future__ import annotations

from bisect import bisect_left


def purged_time_split(sorted_times, train_frac=0.7, valid_frac=0.15, embargo_seconds=3600):
    """Split a chronologically sorted list of timestamps into train/valid/test.

    Returns three (start, end) index pairs as half-open ranges.

    WHY NOT A RANDOM SPLIT. A random split of a price series puts minute t+1 in
    training and minute t in validation. The model then "predicts" a value it
    has effectively already seen, validation scores beautifully, and live
    performance does not resemble it at all. The split has to be by TIME.

    WHY AN EMBARGO, WHICH A PLAIN TIME SPLIT STILL NEEDS. The label looks
    FORWARD. A row at the last minute of the training set is labelled by what
    happened over the following hour -- which is the first hour of validation.
    So a clean chronological cut still leaks the beginning of the validation
    period into training, through the labels rather than through the features.

    The fix is to DELETE a band of rows either side of each boundary, at least
    as wide as the label horizon. Those rows are not moved to the other side;
    they are dropped, because they are the only rows whose outcome spans the
    cut. This is the "purging and embargo" idea from Lopez de Prado's Advances
    in Financial Machine Learning, and it is the difference between a backtest
    that means something and one that does not.

    The cost is real and small: at a 60-minute horizon and a 60-minute sampling
    stride, an embargo of one hour discards roughly one row per asset per
    boundary. Two boundaries, 45 assets, ninety rows. That is what correctness
    costs here.
    """
    if not sorted_times:
        return (0, 0), (0, 0), (0, 0)
    if not 0 < train_frac < 1 or not 0 < valid_frac < 1 or train_frac + valid_frac >= 1:
        raise ValueError("train_frac and valid_frac must be positive and leave room for a test set")

    n = len(sorted_times)
    train_cut = sorted_times[int(n * train_frac)]
    valid_cut = sorted_times[int(n * (train_frac + valid_frac))]

    # bisect_left on the cut gives the first index at or after it; the embargo
    # then walks the boundary outward on both sides. Working in TIME rather than
    # in row counts matters because the rows are not evenly spaced -- a halt, or
    # an asset with less history, would make a fixed row count cover a different
    # span for every boundary.
    # bisect_LEFT on both sides, not left-then-right. With bisect_right on the
    # upper side an embargo of zero would still discard the row sitting exactly
    # on the cut -- excluded from training for being at the boundary and from
    # validation for having been passed. One vanished row is harmless; a split
    # function whose zero setting is not actually a no-op is not, because it
    # means the embargo's effect can never be isolated from the split's.
    train_end = bisect_left(sorted_times, train_cut - embargo_seconds)
    valid_start = bisect_left(sorted_times, train_cut + embargo_seconds)
    valid_end = bisect_left(sorted_times, valid_cut - embargo_seconds)
    test_start = bisect_left(sorted_times, valid_cut + embargo_seconds)

    # A too-wide embargo against a too-short series can invert a range. Clamping
    # to empty is right; a negative-width slice would silently become a Python
    # slice that returns nothing anyway, which is the same outcome arrived at
    # without anyone noticing.
    valid_end = max(valid_end, valid_start)
    return (0, train_end), (valid_start, valid_end), (test_start, n)


def average_precision(y_true, y_score):
    """Area under the precision-recall curve, by the step-wise (AP) definition.

    WHY THIS AND NOT ACCURACY, AND NOT ROC-AUC.

    The label is "the forward return covered a round-trip taker fee", which is
    a minority class. Accuracy is then actively misleading: a model that always
    predicts "no signal" scores whatever the negative rate is -- 90-something
    percent -- while being worth nothing at all. It is the single easiest way to
    report a good number for a useless model.

    ROC-AUC is better but still flatters an imbalanced problem, because the
    false-positive rate has a huge denominator: a model can rack up a great many
    false positives and barely move it. Precision-recall uses the quantity that
    actually matters here -- of the rows we flagged, how many were right -- so
    its denominator is the model's own output.

    Implemented from the definition rather than pulled from sklearn so it can be
    checked by hand in the tests. It is the sum of precision at each threshold
    weighted by the increase in recall, which is the definition scikit-learn
    calls average_precision_score -- deliberately NOT the trapezoidal
    interpolation some libraries use, which is optimistically biased on sparse
    positives.
    """
    if len(y_true) != len(y_score):
        raise ValueError("y_true and y_score must be the same length")
    positives = sum(1 for y in y_true if y == 1)
    if positives == 0:
        # No positive class means average precision is undefined, not zero. Zero
        # would be a score, and a score invites comparison against another one.
        return None

    order = sorted(range(len(y_true)), key=lambda i: y_score[i], reverse=True)
    tp = 0
    ap = 0.0
    prev_recall = 0.0
    i = 0
    while i < len(order):
        # Ties share a threshold and therefore share a point on the curve.
        # Treating them as separate steps would let the order in which equal
        # scores happen to be sorted change the metric.
        j = i
        while j < len(order) and y_score[order[j]] == y_score[order[i]]:
            if y_true[order[j]] == 1:
                tp += 1
            j += 1
        precision = tp / j
        recall = tp / positives
        ap += precision * (recall - prev_recall)
        prev_recall = recall
        i = j
    return ap


def positive_rate_baseline(y_true):
    """The score a coin-flip-proportional model gets, i.e. the floor.

    An average precision of 0.08 sounds terrible until you know the positive
    rate is 0.07. This is the number every reported PR-AUC has to be quoted
    against, and Phase 13 measures degradation as a ratio to it rather than in
    absolute points -- because the positive rate itself drifts with volatility.
    """
    return (sum(1 for y in y_true if y == 1) / len(y_true)) if y_true else None


def scale_pos_weight(y_true):
    """XGBoost's handling of imbalance: negatives per positive.

    Preferred over resampling because it changes the gradient rather than the
    data -- so the validation set keeps its real class balance, and the reported
    PR-AUC stays comparable to the deployed model's operating conditions.
    Resampling the training set and then evaluating on a resampled validation
    set is a very common way to report a number that cannot be reproduced live.
    """
    pos = sum(1 for y in y_true if y == 1)
    neg = len(y_true) - pos
    if pos == 0:
        return 1.0
    return neg / pos
