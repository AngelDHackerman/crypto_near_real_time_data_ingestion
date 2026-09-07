"""
SageMaker training entry point.  roadmap.md Phase 8.

Runs inside AWS's managed XGBoost container in script mode. What it produces is
a model artifact, a feature manifest and a metrics file -- and the metrics file
is the one Phase 13 measures degradation against, so its contents are part of
this job's contract rather than a log line.

WHY THE MANAGED CONTAINER AND NOT AN IMAGE OF OUR OWN
    Phase 5 built an ECR repository and a task definition that pulls `:latest`
    from it, and never built the image. That is still the one thing standing
    between the wake-up flags and a working wake-up. Repeating the shape of that
    mistake here -- a training job that cannot run until a phase four ahead of
    it builds an image -- would be a worse error than the first one, because
    this time the lesson was already written down.

    So Phase 8 trains on `683313688378.dkr.ecr.us-east-1.amazonaws.com/
    sagemaker-xgboost:1.7-1`, pinned exactly like every provider version in this
    project. Phase 12 owns containerisation and will move this to an image it
    builds in the same pipeline that pushes it, which is the only arrangement
    where an image and the thing that needs it cannot drift apart.

THE FEATURE LIST IS EXPLICIT, AND RAW PRICE LEVELS ARE NOT IN IT
    Not "every column except the label". Two categories are excluded and the
    second is the interesting one:

      leakage    -- y_fwd_ret, label_span_minutes and the label metadata. These
                    describe the outcome. Obvious, and still worth naming,
                    because a `df.drop(columns=['y_up'])` would keep every one
                    of them.

      non-stationary levels -- open/high/low/close, volume, quote_volume,
                    market_cap, price_cmc. BTCUSDT trades near $2,000 in 2017
                    and near $100,000 in 2025, so a raw price is a nearly
                    perfect proxy for the DATE. A tree model will happily split
                    on it and learn "2021 was a good year", which validates well
                    on any split that shares a regime and predicts nothing.
                    Ratios, returns and z-scores carry the same information
                    without the clock, and that is what the feature table was
                    built to provide.

    The list is written to the model directory alongside the model. Feature
    ORDER is part of an XGBoost model's interface, and Phase 10 has to
    reconstruct it exactly -- a serving path that guesses the order produces
    confident nonsense rather than an error.
"""

from __future__ import annotations

import argparse
import glob
import json
import os

import pandas as pd
import xgboost as xgb

from splitting import average_precision, positive_rate_baseline, purged_time_split, scale_pos_weight

# Columns that describe the outcome, or that encode the calendar. See the header.
LEAKAGE_COLUMNS = {"y_up", "y_fwd_ret", "label_span_minutes", "label_horizon_min",
                   "label_threshold_bps", "sample_stride_min", "label_version"}
LEVEL_COLUMNS = {"open", "high", "low", "close", "volume", "quote_volume",
                 "taker_buy_base_volume", "taker_buy_quote_volume", "trade_count",
                 "market_cap", "price_cmc", "circulating_supply", "sma_15m", "sma_60m",
                 "sma_240m", "true_range", "atr_15m", "quote_per_trade"}
IDENTITY_COLUMNS = {"event_time_utc", "symbol", "dt", "source", "asset_symbol", "cmc_id",
                    "feature_block_version", "has_context_features", "has_tick_features"}


def parse_args():
    p = argparse.ArgumentParser()
    # SageMaker passes hyperparameters as --key value and mounts channels at
    # these environment variables. Reading them from the environment rather than
    # hardcoding /opt/ml/... is what lets this script run unchanged locally.
    p.add_argument("--train", default=os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train"))
    p.add_argument("--model-dir", default=os.environ.get("SM_MODEL_DIR", "/opt/ml/model"))
    p.add_argument("--output-dir", default=os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output/data"))
    p.add_argument("--max-depth", type=int, default=6)
    p.add_argument("--eta", type=float, default=0.05)
    p.add_argument("--subsample", type=float, default=0.8)
    p.add_argument("--colsample-bytree", type=float, default=0.8)
    p.add_argument("--min-child-weight", type=float, default=20.0)
    p.add_argument("--num-round", type=int, default=400)
    p.add_argument("--early-stopping-rounds", type=int, default=30)
    # Must be at least the label horizon. It is a parameter and not a constant
    # so that a change to LABEL_HORIZON_MIN cannot leave a stale value here.
    p.add_argument("--embargo-seconds", type=int, default=3600)
    p.add_argument("--train-frac", type=float, default=0.7)
    p.add_argument("--valid-frac", type=float, default=0.15)
    p.add_argument("--feature-block-version", default="unknown")
    return p.parse_known_args()[0]


def load(channel_dir):
    files = sorted(glob.glob(os.path.join(channel_dir, "**", "*.parquet"), recursive=True))
    if not files:
        raise SystemExit(f"no parquet files under {channel_dir}")
    df = pd.concat((pd.read_parquet(f) for f in files), ignore_index=True)
    # Chronological order is a precondition of the split, not a nicety: the
    # split indexes a sorted list, and S3 hands the files back in whatever order
    # the listing produced.
    return df.sort_values("event_time_utc", kind="mergesort").reset_index(drop=True)


def main():
    args = parse_args()
    df = load(args.train)

    excluded = LEAKAGE_COLUMNS | LEVEL_COLUMNS | IDENTITY_COLUMNS
    features = [c for c in df.columns if c not in excluded and pd.api.types.is_numeric_dtype(df[c])]
    if not features:
        raise SystemExit("no usable feature columns survived the exclusion lists")

    df = df[df["y_up"].notna()]
    times = (df["event_time_utc"].astype("int64") // 10**9).tolist()
    (a0, a1), (b0, b1), (c0, c1) = purged_time_split(
        times, train_frac=args.train_frac, valid_frac=args.valid_frac, embargo_seconds=args.embargo_seconds
    )
    if a1 - a0 == 0 or b1 - b0 == 0:
        raise SystemExit("the purged split left an empty train or validation set; the input span is too short")

    X, y = df[features], df["y_up"].astype(int)
    d_train = xgb.DMatrix(X.iloc[a0:a1], label=y.iloc[a0:a1], feature_names=features)
    d_valid = xgb.DMatrix(X.iloc[b0:b1], label=y.iloc[b0:b1], feature_names=features)
    d_test = xgb.DMatrix(X.iloc[c0:c1], label=y.iloc[c0:c1], feature_names=features)

    params = {
        "objective": "binary:logistic",
        # aucpr, not auc and not error. The reasoning is in splitting.py: on a
        # minority class, the metric that early stopping watches decides what
        # the model becomes, and watching accuracy would stop it at "never
        # signal".
        "eval_metric": "aucpr",
        "max_depth": args.max_depth,
        "eta": args.eta,
        "subsample": args.subsample,
        "colsample_bytree": args.colsample_bytree,
        "min_child_weight": args.min_child_weight,
        # Reweights the gradient rather than resampling the rows, so the
        # validation set keeps its real class balance and the reported number
        # stays comparable to live conditions.
        "scale_pos_weight": scale_pos_weight(y.iloc[a0:a1].tolist()),
        "tree_method": "hist",
        "seed": 20260906,
    }

    booster = xgb.train(
        params,
        d_train,
        num_boost_round=args.num_round,
        evals=[(d_train, "train"), (d_valid, "validation")],
        early_stopping_rounds=args.early_stopping_rounds,
        verbose_eval=25,
    )

    def evaluate(dmatrix, y_true):
        # Scored with OUR average_precision, not XGBoost's. The two agree, and
        # the point is that the number Phase 13 compares against comes from an
        # implementation with unit tests rather than from whichever definition
        # of AP the training library shipped that release.
        scores = booster.predict(dmatrix, iteration_range=(0, booster.best_iteration + 1)).tolist()
        labels = y_true.tolist()
        ap = average_precision(labels, scores)
        base = positive_rate_baseline(labels)
        return {
            "rows": len(labels),
            "positive_rate": base,
            "pr_auc": ap,
            # The number that actually says whether the model learned anything.
            # An absolute PR-AUC is uninterpretable without the floor beside it,
            # and the floor drifts with volatility -- so Phase 13's threshold is
            # on this ratio, not on pr_auc.
            "lift_over_baseline": (ap / base) if (ap is not None and base) else None,
        }

    metrics = {
        "feature_block_version": args.feature_block_version,
        "features": features,
        "n_features": len(features),
        "best_iteration": booster.best_iteration,
        "train": evaluate(d_train, y.iloc[a0:a1]),
        "validation": evaluate(d_valid, y.iloc[b0:b1]),
        # Scored once, at the end, and never used for a decision. A test set
        # consulted during tuning stops being a test set.
        "test": evaluate(d_test, y.iloc[c0:c1]),
        "split": {
            "train_rows": a1 - a0,
            "validation_rows": b1 - b0,
            "test_rows": c1 - c0,
            "embargo_seconds": args.embargo_seconds,
        },
    }

    os.makedirs(args.model_dir, exist_ok=True)
    booster.save_model(os.path.join(args.model_dir, "model.json"))
    # Beside the model, not only in the metrics: Phase 10 needs the exact
    # ordered feature list to build an inference row, and it should not have to
    # parse a metrics report to get it.
    with open(os.path.join(args.model_dir, "feature_columns.json"), "w") as fh:
        json.dump({"features": features, "feature_block_version": args.feature_block_version}, fh, indent=2)
    with open(os.path.join(args.model_dir, "metrics.json"), "w") as fh:
        json.dump(metrics, fh, indent=2)

    os.makedirs(args.output_dir, exist_ok=True)
    with open(os.path.join(args.output_dir, "metrics.json"), "w") as fh:
        json.dump(metrics, fh, indent=2)

    # Emitted in the shape the training job's metric_definitions regex reads, so
    # these land as CloudWatch metrics rather than only in the log stream. That
    # is what lets Phase 11 alarm on them.
    v = metrics["validation"]
    print(f"validation_pr_auc={v['pr_auc']:.6f};")
    print(f"validation_positive_rate={v['positive_rate']:.6f};")
    print(f"validation_lift={v['lift_over_baseline']:.6f};")
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
