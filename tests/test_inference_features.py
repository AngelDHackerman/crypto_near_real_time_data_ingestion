"""
Verification of serving/inference/feature_request.py.  roadmap.md Phase 10.

The claim this file checks is the one Phase 7's daily-cadence argument rests on:
that inference recomputes features from the SAME SQL the batch pipeline uses, so
there is no training/serving skew to drift into.

It builds real Parquet with DuckDB rather than mocking the reader, because the
Parquet path is part of what is being tested -- the Lambda downloads objects and
points DuckDB at local files, and "it works on a DataFrame" would not have shown
that the `source` partition column is absent from the file itself.
"""

from __future__ import annotations

import math
import os
import sys
import tempfile
import unittest

import duckdb

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "serving", "inference"))

from feature_request import InsufficientHistory, latest_feature_row  # noqa: E402

with open(os.path.join(REPO, "glue_jobs_silver_gold", "gold", "indicators.sql")) as fh:
    TEMPLATE = fh.read()

# A realistic subset of what the training job would emit, in a deliberate
# non-alphabetical order -- the point of reading the list rather than
# reconstructing it is that the order is arbitrary and must be preserved.
FEATURES = ["rsi_14", "ret_60m", "vol_60m", "taker_buy_ratio", "bb_z_60m", "volume_z_1440m"]


def write_bars(path, symbol="BTCUSDT", minutes=1500, start_price=100.0):
    """Write a Parquet file shaped exactly like a Silver klines object.

    Note what is NOT written: `source`. It is a partition key in Silver, so it
    lives in the S3 path and never in the file -- which is precisely the detail
    a mocked reader would have hidden.
    """
    con = duckdb.connect()
    con.execute(
        f"""
        COPY (
            SELECT
                '{symbol}'                                        AS symbol,
                TIMESTAMP '2026-01-01 00:00:00' + INTERVAL (i) MINUTE AS event_time_utc,
                {start_price} + 10 * sin(i / 50.0) + (i % 7) * 0.1 AS open,
                {start_price} + 10 * sin(i / 50.0) + (i % 7) * 0.1 + 0.5 AS high,
                {start_price} + 10 * sin(i / 50.0) + (i % 7) * 0.1 - 0.5 AS low,
                {start_price} + 10 * sin(i / 50.0) + (i % 7) * 0.1 + 0.2 AS close,
                100.0 + (i % 13)                                  AS volume,
                (100.0 + (i % 13)) * {start_price}                AS quote_volume,
                40.0 + (i % 5)                                    AS taker_buy_base_volume,
                (40.0 + (i % 5)) * {start_price}                  AS taker_buy_quote_volume,
                CAST(10 + (i % 4) AS BIGINT)                      AS trade_count
            FROM range({minutes}) t(i)
        ) TO '{path}' (FORMAT PARQUET)
        """
    )
    con.close()


class TestLatestFeatureRow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "bars.parquet")
        self.con = duckdb.connect()

    def tearDown(self):
        self.con.close()
        self.tmp.cleanup()

    def test_returns_values_in_the_models_own_order(self):
        write_bars(self.path)
        values, record = latest_feature_row(self.con, [self.path], "BTCUSDT", TEMPLATE, FEATURES)

        self.assertEqual(len(values), len(FEATURES))
        for i, name in enumerate(FEATURES):
            self.assertAlmostEqual(values[i], float(record[name]), places=12,
                                   msg=f"{name} is not at position {i}")

    def test_it_scores_the_most_recent_bar(self):
        write_bars(self.path, minutes=1500)
        _, record = latest_feature_row(self.con, [self.path], "BTCUSDT", TEMPLATE, FEATURES)
        self.assertEqual(str(record["event_time_utc"]), "2026-01-02 00:59:00")

    def test_the_maths_is_the_same_maths(self):
        # Not a re-test of the indicators -- a check that the values coming out
        # of the SERVING path are in the ranges the definitions guarantee, i.e.
        # that this path really is running indicators.sql and not something
        # that merely returns numbers.
        write_bars(self.path)
        _, record = latest_feature_row(self.con, [self.path], "BTCUSDT", TEMPLATE, FEATURES)
        self.assertTrue(0.0 <= record["rsi_14"] <= 100.0)
        self.assertTrue(0.0 <= record["taker_buy_ratio"] <= 1.0)
        self.assertTrue(math.isfinite(record["ret_60m"]))

    def test_thin_history_raises_instead_of_scoring(self):
        # XGBoost would accept a row of NaNs and return a confident number, and
        # a prediction from a half-empty vector is indistinguishable from a real
        # one at the point where someone acts on it.
        write_bars(self.path, minutes=30)
        with self.assertRaises(InsufficientHistory):
            latest_feature_row(self.con, [self.path], "BTCUSDT", TEMPLATE, FEATURES)

    def test_a_flat_series_raises_rather_than_returning_a_null_feature(self):
        # A stablecoin. rsi_14 and bb_z_60m are null by design on a flat series
        # (feature_schema.md), which is correct for a table and unusable for a
        # scoring request -- so it has to be an error here.
        con = duckdb.connect()
        con.execute(
            f"""COPY (SELECT 'USDCUSDT' AS symbol,
                TIMESTAMP '2026-01-01 00:00:00' + INTERVAL (i) MINUTE AS event_time_utc,
                1.0 AS open, 1.0 AS high, 1.0 AS low, 1.0 AS close, 100.0 AS volume,
                100.0 AS quote_volume, 40.0 AS taker_buy_base_volume,
                40.0 AS taker_buy_quote_volume, CAST(5 AS BIGINT) AS trade_count
                FROM range(1500) t(i)) TO '{self.path}' (FORMAT PARQUET)"""
        )
        con.close()
        with self.assertRaises(InsufficientHistory):
            latest_feature_row(self.con, [self.path], "USDCUSDT", TEMPLATE, FEATURES)

    def test_unknown_symbol_raises(self):
        write_bars(self.path)
        with self.assertRaises(InsufficientHistory):
            latest_feature_row(self.con, [self.path], "DOGEUSDT", TEMPLATE, FEATURES)

    def test_a_feature_the_sql_does_not_produce_is_a_version_mismatch(self):
        # The model was trained against a different indicators.sql. This must be
        # a loud error, because it is exactly what feature_block_version exists
        # to catch and the alternative is scoring against a shifted vector.
        write_bars(self.path)
        with self.assertRaises(RuntimeError) as ctx:
            latest_feature_row(self.con, [self.path], "BTCUSDT", TEMPLATE, FEATURES + ["ema_200m"])
        self.assertIn("ema_200m", str(ctx.exception))

    def test_a_symbol_that_is_not_a_symbol_is_refused(self):
        # DuckDB cannot take a prepared parameter inside CREATE VIEW, so the
        # symbol is interpolated -- which makes this test the thing standing
        # between a request payload and the query. An allow-list, so the check
        # is "is this a Binance pair", not "does this look dangerous".
        write_bars(self.path)
        for hostile in ("BTC'; DROP VIEW bars; --", "btcusdt", "BTC USDT", "", "*"):
            with self.assertRaises(ValueError, msg=f"accepted {hostile!r}"):
                latest_feature_row(self.con, [self.path], hostile, TEMPLATE, FEATURES)

    def test_no_files_raises(self):
        with self.assertRaises(InsufficientHistory):
            latest_feature_row(self.con, [], "BTCUSDT", TEMPLATE, FEATURES)

    def test_multiple_objects_are_unioned(self):
        # Silver writes one object per (dt, hour); a 2-day window is ~48 of them.
        p1 = os.path.join(self.tmp.name, "a.parquet")
        p2 = os.path.join(self.tmp.name, "b.parquet")
        write_bars(p1, minutes=800)
        con = duckdb.connect()
        con.execute(
            f"""COPY (SELECT 'BTCUSDT' AS symbol,
                TIMESTAMP '2026-01-01 13:20:00' + INTERVAL (i) MINUTE AS event_time_utc,
                100.0 + (i%11) AS open, 101.0 + (i%11) AS high, 99.0 + (i%11) AS low,
                100.5 + (i%11) AS close, 100.0 AS volume, 10000.0 AS quote_volume,
                40.0 AS taker_buy_base_volume, 4000.0 AS taker_buy_quote_volume,
                CAST(10 AS BIGINT) AS trade_count
                FROM range(800) t(i)) TO '{p2}' (FORMAT PARQUET)"""
        )
        con.close()
        values, _ = latest_feature_row(self.con, [p1, p2], "BTCUSDT", TEMPLATE, FEATURES)
        self.assertEqual(len(values), len(FEATURES))


if __name__ == "__main__":
    unittest.main()
