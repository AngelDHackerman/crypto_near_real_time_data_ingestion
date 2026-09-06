"""
Verification of glue_jobs_silver_gold/gold/indicators.sql.  roadmap.md Phase 7.

Phase 7's DoD says the indicators are "unit-verified against a known reference
series" rather than eyeballed, and this is that check. It runs WITHOUT Spark,
without a JVM and without AWS, which is the whole reason the maths lives in a
SQL file: the text executed here is byte-for-byte the text the Glue job sends to
Spark, expanded by the same indicator_sql.build_sql.

THREE LAYERS, BECAUSE ANY ONE OF THEM ALONE IS WEAK

  1. HAND-COMPUTED LITERALS on a series small enough to check on paper. This is
     the layer that catches a definition both implementations misunderstand in
     the same way -- an independent implementation written by the same person on
     the same afternoon is not actually independent about the DEFINITION, only
     about the code.

  2. AN INDEPENDENT PYTHON IMPLEMENTATION of every window, written from the
     definitions rather than translated from the SQL, compared row by row. This
     is the layer that catches off-by-one frames, null handling and the gap
     semantics -- the things that are invisible on a three-row example.

  3. ADVERSARIAL SERIES: a gap, a flat stablecoin, and a single-bar symbol. Each
     targets a specific claim the SQL's comments make, so a claim that stops
     being true fails a test instead of ageing quietly into a lie.

Run: python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import math
import os
import sys
import unittest
from datetime import datetime, timedelta

import duckdb

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLD = os.path.join(REPO, "glue_jobs_silver_gold", "gold")
sys.path.insert(0, GOLD)

from indicator_sql import build_sql  # noqa: E402

with open(os.path.join(GOLD, "indicators.sql")) as fh:
    TEMPLATE = fh.read()

T0 = datetime(2024, 1, 1, 0, 0, 0)


def bar(symbol, minute, close, *, high=None, low=None, volume=100.0, taker=40.0, trades=10):
    """One row in the input shape indicators.sql expects.

    Defaults keep the OHLCV fields out of the way of whichever feature a test is
    actually about; a test that cares sets them explicitly.
    """
    return (
        symbol,
        T0 + timedelta(minutes=minute),
        "backfill",
        close,  # open
        high if high is not None else close,
        low if low is not None else close,
        close,
        volume,
        close * volume,
        taker,
        close * taker,
        trades,
    )


COLUMNS = (
    "symbol, event_time_utc, source, open, high, low, close, volume, "
    "quote_volume, taker_buy_base_volume, taker_buy_quote_volume, trade_count"
)


def run_sql(rows):
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE bars (
            symbol VARCHAR, event_time_utc TIMESTAMP, source VARCHAR,
            open DOUBLE, high DOUBLE, low DOUBLE, close DOUBLE,
            volume DOUBLE, quote_volume DOUBLE,
            taker_buy_base_volume DOUBLE, taker_buy_quote_volume DOUBLE,
            trade_count BIGINT
        )
        """
    )
    con.executemany(f"INSERT INTO bars ({COLUMNS}) VALUES ({','.join(['?'] * 12)})", rows)
    sql = build_sql(TEMPLATE, "bars", dialect="duckdb")
    cur = con.execute(sql + " ORDER BY symbol, event_time_utc")
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


# ---------------------------------------------------------------------------
# Layer 2: the independent implementation.
#
# Written from the definitions, not from the SQL. It deliberately uses a
# different strategy -- an explicit scan over the rows inside each time window
# -- so a mistake in the SQL's frame boundaries cannot be reproduced here by
# construction.
# ---------------------------------------------------------------------------
def window_rows(series, i, span_minutes):
    """Rows within `span_minutes` of row i, inclusive of i, per the RANGE frame.

    The frame is "INTERVAL span-1 MINUTES PRECEDING AND CURRENT ROW", so the
    oldest row that qualifies is exactly span-1 minutes before the current one.
    """
    now = series[i]["ts"]
    lower = now - timedelta(minutes=span_minutes - 1)
    return [r for r in series[: i + 1] if r["ts"] >= lower]


def mean(values):
    vals = [v for v in values if v is not None]
    return sum(vals) / len(vals) if vals else None


def stddev_samp(values):
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return None
    mu = sum(vals) / len(vals)
    return math.sqrt(sum((v - mu) ** 2 for v in vals) / (len(vals) - 1))


def reference(rows):
    """Compute the expected values for every input row, independently."""
    by_symbol = {}
    for r in rows:
        by_symbol.setdefault(r[0], []).append(
            {"ts": r[1], "close": r[6], "high": r[4], "low": r[5], "volume": r[7], "trades": r[11]}
        )

    out = {}
    for symbol, series in by_symbol.items():
        series.sort(key=lambda r: r["ts"])
        # An explicit index, because a flat series makes every row dict equal and
        # list.index() would then return the FIRST match for all of them -- a
        # reference implementation that is silently wrong on exactly the
        # adversarial case it exists to check.
        for pos, r in enumerate(series):
            r["i"] = pos
        for i, row in enumerate(series):
            prev = series[i - 1] if i else None
            gap = round((row["ts"] - prev["ts"]).total_seconds() / 60) if prev else None

            diff = row["close"] - prev["close"] if prev and gap == 1 else None
            ret_1m = math.log(row["close"] / prev["close"]) if prev and gap == 1 and prev["close"] > 0 else None

            def rets(span):
                return [
                    (math.log(w["close"] / series[w["i"] - 1]["close"])
                     if w["i"] > 0
                     and round((w["ts"] - series[w["i"] - 1]["ts"]).total_seconds() / 60) == 1
                     and series[w["i"] - 1]["close"] > 0
                     else None)
                    for w in window_rows(series, i, span)
                ]

            def gains_losses(span):
                g, ls = [], []
                for w in window_rows(series, i, span):
                    j = w["i"]
                    if j == 0 or round((w["ts"] - series[j - 1]["ts"]).total_seconds() / 60) != 1:
                        g.append(None)
                        ls.append(None)
                        continue
                    d = w["close"] - series[j - 1]["close"]
                    g.append(d if d > 0 else 0.0)
                    ls.append(-d if d < 0 else 0.0)
                return mean(g), mean(ls)

            avg_gain, avg_loss = gains_losses(14)
            if avg_gain is None or avg_loss is None or avg_gain + avg_loss == 0:
                rsi = None
            else:
                rsi = 100.0 * avg_gain / (avg_gain + avg_loss)

            w15 = window_rows(series, i, 15)
            w60 = window_rows(series, i, 60)
            sd60 = stddev_samp([w["close"] for w in w60])
            sma60 = mean([w["close"] for w in w60])

            out[(symbol, row["ts"])] = {
                "minutes_since_prev": gap,
                "ret_1m": ret_1m,
                "sma_15m": mean([w["close"] for w in w15]),
                "sma_60m": sma60,
                "vol_15m": stddev_samp(rets(15)),
                "vol_60m": stddev_samp(rets(60)),
                "rsi_14": rsi,
                "bb_z_60m": ((row["close"] - sma60) / sd60) if sd60 else None,
                "ret_60m": (math.log(row["close"] / w60[0]["close"]) if w60[0]["close"] > 0 else None),
                "bars_in_60m": len(w60),
                "diff_1m_unused": diff,
            }
    return out


def close_enough(a, b, tol=1e-9):
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


class TestHandComputed(unittest.TestCase):
    """Layer 1 -- values a reader can check without running anything."""

    def test_three_rising_bars(self):
        rows = [bar("A", 0, 10.0), bar("A", 1, 11.0), bar("A", 2, 12.0)]
        res = run_sql(rows)

        first, second, third = res
        # No previous bar exists, so every step-dependent value is undefined --
        # not zero. A zero return on the first bar of a series is the most
        # common silent bug in this kind of table.
        self.assertIsNone(first["minutes_since_prev"])
        self.assertIsNone(first["ret_1m"])
        self.assertIsNone(first["rsi_14"])

        self.assertEqual(second["minutes_since_prev"], 1)
        self.assertAlmostEqual(second["ret_1m"], math.log(11 / 10), places=12)

        # SMA over the 15-minute window, which at bar 3 holds all three bars.
        self.assertAlmostEqual(third["sma_15m"], (10 + 11 + 12) / 3, places=12)

        # Two one-minute changes, both +1, no losses at all: RSI is 100 by
        # definition, and this is the boundary the "+ 0 denominator" guard has
        # to get right.
        self.assertAlmostEqual(third["rsi_14"], 100.0, places=12)

        # Return over the 60-minute window = from the oldest bar in it.
        self.assertAlmostEqual(third["ret_60m"], math.log(12 / 10), places=12)
        self.assertEqual(third["bars_in_60m"], 3)

    def test_rsi_half_way(self):
        # +1, -1: mean gain 0.5, mean loss 0.5 over the two observed changes,
        # so RSI is exactly 50. Checked on paper because it is the one value a
        # sign error still produces by accident.
        rows = [bar("A", 0, 10.0), bar("A", 1, 11.0), bar("A", 2, 10.0)]
        res = run_sql(rows)
        self.assertAlmostEqual(res[-1]["rsi_14"], 50.0, places=12)

    def test_true_range_uses_previous_close(self):
        # Wilder's true range is max(h-l, |h-prev_close|, |l-prev_close|). Bar 2
        # has a narrow high-low but gaps away from bar 1's close, which is
        # exactly the case a naive high-low range gets wrong.
        rows = [bar("A", 0, 10.0, high=10.0, low=10.0), bar("A", 1, 20.0, high=20.5, low=19.5)]
        res = run_sql(rows)
        self.assertAlmostEqual(res[0]["true_range"], 0.0, places=12)
        self.assertAlmostEqual(res[1]["true_range"], 10.5, places=12)  # |20.5 - 10.0|


class TestAgainstReference(unittest.TestCase):
    """Layer 2 -- every row, every window, against the independent version."""

    def _compare(self, rows):
        expected = reference(rows)
        for row in run_sql(rows):
            key = (row["symbol"], row["event_time_utc"])
            exp = expected[key]
            for field in (
                "minutes_since_prev",
                "ret_1m",
                "sma_15m",
                "sma_60m",
                "vol_15m",
                "vol_60m",
                "rsi_14",
                "bb_z_60m",
                "ret_60m",
                "bars_in_60m",
            ):
                self.assertTrue(
                    close_enough(row[field], exp[field]),
                    f"{key} {field}: sql={row[field]!r} reference={exp[field]!r}",
                )

    def test_dense_series(self):
        # 90 minutes of a deterministic but non-monotonic walk, long enough that
        # the 60-minute windows are genuinely full and then genuinely rolling.
        closes = [100 + 10 * math.sin(i / 7) + (i % 5) for i in range(90)]
        self._compare([bar("A", i, c) for i, c in enumerate(closes)])

    def test_two_symbols_do_not_bleed(self):
        # Both series occupy the same minutes. If the PARTITION BY were ever
        # dropped, every window here would silently mix two assets and still
        # return numbers.
        rows = []
        for i in range(40):
            rows.append(bar("A", i, 100 + i))
            rows.append(bar("B", i, 5000 - 3 * i))
        self._compare(rows)


class TestAdversarialSeries(unittest.TestCase):
    """Layer 3 -- one test per claim the SQL's header makes."""

    def test_gap_is_recorded_and_not_filled(self):
        # 0,1,2 then a 30-minute halt, then 32,33. The DoD line is "missing
        # minutes treated as missing, never forward-filled".
        rows = [bar("A", m, 10.0 + m) for m in (0, 1, 2, 32, 33)]
        res = run_sql(rows)
        after_gap = res[3]

        self.assertEqual(after_gap["minutes_since_prev"], 30)
        # A one-minute return across a thirty-minute halt does not exist.
        self.assertIsNone(after_gap["ret_1m"])
        # The return that DOES exist is carried separately rather than dropped.
        self.assertIsNotNone(after_gap["ret_since_prev"])

        # The window is time-based, so it holds fewer bars rather than reaching
        # further back in wall-clock time. With ROWS framing this would be 15.
        self.assertEqual(after_gap["bars_in_60m"], 4)
        self.assertEqual(res[4]["bars_in_60m"], 5)

        # No row was invented to fill the halt.
        self.assertEqual(len(res), 5)

    def test_flat_stablecoin_yields_null_not_a_midpoint(self):
        # The tracked universe carries stablecoins as a negative control
        # (data_sources.md section 5): a model that emits signals on a series
        # pinned at 1.0000 is broken. A conventional RSI of 50 and a Bollinger
        # z of 0 are exactly the fabricated inputs that would let it.
        rows = [bar("USDCUSDT", m, 1.0) for m in range(20)]
        res = run_sql(rows)
        for row in res:
            self.assertIsNone(row["rsi_14"], "flat series must not report an RSI")
            self.assertIsNone(row["bb_z_60m"], "zero-width band has no position inside it")
        self.assertAlmostEqual(res[-1]["ret_1m"], 0.0, places=12)

    def test_single_bar_symbol(self):
        # The shortest possible history. Every windowed dispersion needs two
        # observations, so they are undefined, and nothing here may raise.
        res = run_sql([bar("NEWCOIN", 0, 3.5)])
        self.assertEqual(len(res), 1)
        row = res[0]
        self.assertIsNone(row["vol_60m"])
        self.assertIsNone(row["bb_z_60m"])
        self.assertAlmostEqual(row["sma_15m"], 3.5, places=12)
        self.assertEqual(row["bars_in_60m"], 1)

    def test_taker_ratio_is_a_share_not_a_volume(self):
        rows = [bar("A", 0, 10.0, volume=200.0, taker=50.0)]
        res = run_sql(rows)
        self.assertAlmostEqual(res[0]["taker_buy_ratio"], 0.25, places=12)

    def test_zero_volume_bar_does_not_divide_by_zero(self):
        rows = [bar("A", 0, 10.0, volume=0.0, taker=0.0, trades=0)]
        res = run_sql(rows)
        self.assertIsNone(res[0]["taker_buy_ratio"])
        self.assertIsNone(res[0]["quote_per_trade"])


class TestTemplateContract(unittest.TestCase):
    def test_every_placeholder_is_expanded(self):
        sql = build_sql(TEMPLATE, "bars", dialect="spark")
        body = "\n".join(line for line in sql.splitlines() if not line.strip().startswith("--"))
        self.assertNotIn("%", body)

    def test_dialects_differ_only_in_the_epoch_function(self):
        """The two engines must receive the same statement bar one function name.

        Comments are stripped first: the file's header explains the seam and so
        names BOTH functions in prose, which a naive whole-text substitution
        would rewrite. The claim being checked is about the SQL that executes.
        """

        def code(dialect):
            sql = build_sql(TEMPLATE, "bars", dialect=dialect)
            return "\n".join(line for line in sql.splitlines() if not line.strip().startswith("--"))

        spark, duck = code("spark"), code("duckdb")
        self.assertNotEqual(spark, duck)
        self.assertEqual(spark.replace("unix_timestamp", "epoch"), duck)
        # And the seam is exactly as small as it claims to be.
        self.assertEqual(spark.count("unix_timestamp"), 2)

    def test_unknown_dialect_is_rejected(self):
        with self.assertRaises(ValueError):
            build_sql(TEMPLATE, "bars", dialect="trino")


if __name__ == "__main__":
    unittest.main()
