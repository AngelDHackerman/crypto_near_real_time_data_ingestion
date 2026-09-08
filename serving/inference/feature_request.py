"""
Features at request time, from the same SQL the batch pipeline uses.
roadmap.md Phase 10.

WHY INFERENCE DOES NOT READ THE GOLD FEATURE TABLE
    Phase 7 settled that the batch pipeline stays daily, and the argument for
    that rested on a claim this file has to make true: the serving path does not
    read those tables at all. If it did, a prediction would be up to 24 hours
    stale and the daily cadence really would be the wrong grain.

    Instead, inference recomputes the same features over the last ~2 days of
    1-minute bars, at request time, from Silver. Freshness is then bounded by
    Firehose's five-minute buffer rather than by a schedule.

    Two days because the longest window in indicators.sql spans 1440 minutes,
    and asking for exactly 1440 would leave the oldest window one bar short.

THE TRAINING/SERVING SKEW PROBLEM, AND WHY THERE ISN'T ONE
    The classic way a model degrades in production without anyone noticing is
    that the features it is served differ subtly from the ones it was trained
    on -- a different rolling window convention, a different null policy, a
    different order of operations. It is subtle by definition: if it were
    obvious the model would fail loudly instead of quietly getting worse.

    Here there is one file, `glue_jobs_silver_gold/gold/indicators.sql`, expanded
    by one module, and the only difference between the two executions is which
    engine runs it -- Spark in Glue, DuckDB here. That is not "we were careful
    to keep them in sync"; it is the same text. Phase 7 wrote the maths as SQL
    for the testing argument, and this is the second thing that buys.

    The residual risk is engine semantics rather than definition drift, and it
    is bounded: tests/test_indicators.py runs the DuckDB side against an
    independent implementation, and the DuckDB version is pinned to the one in
    the Lambda layer.

A MISSING FEATURE IS AN ERROR, NEVER A ZERO
    XGBoost accepts a row with NaNs and returns a confident number. So a symbol
    whose recent history is too thin to fill the windows must raise, not score:
    a prediction built from a half-empty feature vector is indistinguishable
    from a real one at the point where it is acted on.
"""

from __future__ import annotations

import os
import re
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                 "glue_jobs_silver_gold", "gold"),
)

from indicator_sql import build_sql  # noqa: E402

BAR_COLUMNS = (
    "symbol", "event_time_utc", "open", "high", "low", "close", "volume",
    "quote_volume", "taker_buy_base_volume", "taker_buy_quote_volume", "trade_count",
)


# Binance spot pairs are upper-case alphanumerics. Deliberately strict: the
# tracked universe is 45 fixed symbols, so anything outside this shape is not a
# symbol this service would serve even if it were harmless.
SYMBOL_RE = re.compile(r"[A-Z0-9]{2,20}")


class InsufficientHistory(RuntimeError):
    """Not enough recent bars to fill the model's windows."""


def latest_feature_row(con, parquet_paths, symbol, indicators_template, feature_columns, min_bars=240):
    """Return (ordered_values, row_dict) for the most recent bar of `symbol`.

    `feature_columns` is the ordered list written beside the model artifact by
    the training job. Order is part of an XGBoost model's interface -- a serving
    path that guesses it produces confident nonsense rather than an error -- so
    it is READ, never reconstructed here.
    """
    if not parquet_paths:
        raise InsufficientHistory(f"no parquet files supplied for {symbol}")

    # DuckDB does not accept prepared parameters inside CREATE VIEW, so these
    # values are interpolated -- which makes validating them mandatory rather
    # than fastidious. `symbol` reaches this function from a request payload.
    #
    # An allow-list, not an escape: the tracked universe is 45 fixed Binance
    # pairs and every one of them matches this. Anything that does not is not a
    # symbol we would serve even if it were harmless.
    if not SYMBOL_RE.fullmatch(symbol):
        raise ValueError(f"refusing to build a query for symbol {symbol!r}")
    bad_paths = [p for p in parquet_paths if "'" in p or "\\" in p]
    if bad_paths:
        raise ValueError(f"refusing to build a query for path {bad_paths[0]!r}")

    path_list = ", ".join(f"'{p}'" for p in parquet_paths)
    con.execute("DROP VIEW IF EXISTS bars")
    con.execute(
        f"""
        CREATE VIEW bars AS
        SELECT {', '.join(BAR_COLUMNS)}, 'stream' AS source
        FROM read_parquet([{path_list}], union_by_name := true)
        WHERE symbol = '{symbol}'
        """  # noqa: S608 -- both interpolations are validated immediately above
    )

    # `source` is a PARTITION key in Silver, so it lives in the S3 path and not
    # in the file. It is re-added as a literal above because indicators.sql
    # carries it through -- it is not a feature, and nothing downstream reads it.

    (bar_count,) = con.execute("SELECT count(*) FROM bars").fetchone()
    if bar_count < min_bars:
        raise InsufficientHistory(
            f"{symbol} has {bar_count} bars in the window, need at least {min_bars}"
        )

    sql = build_sql(indicators_template, "bars", dialect="duckdb")
    cur = con.execute(
        f"SELECT * FROM ({sql}) ORDER BY event_time_utc DESC LIMIT 1"  # noqa: S608 -- see build_sql's docstring
    )
    row = cur.fetchone()
    if row is None:
        raise InsufficientHistory(f"{symbol} produced no feature row")
    record = dict(zip([d[0] for d in cur.description], row))

    missing = [c for c in feature_columns if c not in record]
    if missing:
        # The model was trained on columns this pipeline does not produce. That
        # is a version mismatch between the model and indicators.sql, and it is
        # exactly what feature_block_version exists to make visible.
        raise RuntimeError(f"model expects features absent from the feature SQL: {missing}")

    null_features = [c for c in feature_columns if record[c] is None]
    if null_features:
        raise InsufficientHistory(
            f"{symbol}: {len(null_features)} feature(s) could not be computed from the available "
            f"history ({', '.join(null_features[:5])}...)"
        )

    return [float(record[c]) for c in feature_columns], record
