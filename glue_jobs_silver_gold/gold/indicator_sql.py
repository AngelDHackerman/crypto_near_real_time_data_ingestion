"""
Expansion of indicators.sql into an executable statement.  roadmap.md Phase 7.

The SQL next door is a template with a handful of placeholders. This module is
the only thing that fills them in, so the Glue job on Spark and the unit test on
DuckDB necessarily run the same text with the same window frames -- which is the
entire reason the maths was written as SQL rather than as DataFrame calls.

It is deliberately dependency-free (standard library only) so the test can
import it on a laptop with no Spark and no JVM, and Glue can ship it with a
plain `--extra-py-files`.
"""

from __future__ import annotations

# `INTERVAL <n> MINUTES` rather than the ANSI `INTERVAL '<n>' MINUTE`. Both are
# accepted by DuckDB (checked), and the multi-unit form is the one Spark's own
# documentation uses for time-based window frames -- so it is the spelling with
# the least chance of a surprise on the engine that cannot be tested here.
#
# Every span is "N minus one minute preceding, plus the current row", so a
# window named _60m spans sixty minutes INCLUDING the bar it is computed on. Off
# by one in either direction is the classic way an indicator silently disagrees
# with every reference implementation of itself.
_ORDER = "PARTITION BY symbol ORDER BY event_time_utc"


def _range(minutes: int) -> str:
    return f"({_ORDER} RANGE BETWEEN INTERVAL {minutes - 1} MINUTES PRECEDING AND CURRENT ROW)"


WINDOWS = {
    "%W_ROW%": f"({_ORDER})",
    # 14 one-minute changes, which is what RSI(14) is defined over: fourteen
    # bars, hence thirteen minutes of look-back plus the current row.
    "%W_RSI%": _range(14),
    "%W_15%": _range(15),
    "%W_60%": _range(60),
    "%W_240%": _range(240),
    "%W_1440%": _range(1440),
}

# Seconds since the epoch: the one function whose name differs between the two
# engines. Kept as a table rather than an if/else so adding a third engine is a
# line here and nothing anywhere else.
EPOCH_FN = {"spark": "unix_timestamp", "duckdb": "epoch"}


def build_sql(template: str, input_relation: str, dialect: str = "spark") -> str:
    """Fill in indicators.sql for one engine and one input relation.

    `input_relation` is substituted as-is, so it must be a table/view name the
    caller controls -- never a value that reached this process from data. Every
    caller in this repository passes a literal registered by itself.
    """
    if dialect not in EPOCH_FN:
        raise ValueError(f"unknown dialect {dialect!r}; expected one of {sorted(EPOCH_FN)}")

    sql = template
    for token, frame in WINDOWS.items():
        sql = sql.replace(token, frame)
    sql = sql.replace("%EPOCH%", EPOCH_FN[dialect])
    sql = sql.replace("%INPUT%", input_relation)

    # A placeholder that survives expansion is a typo that would otherwise
    # surface as a syntax error thirty minutes into a Glue run.
    leftover = [line for line in sql.splitlines() if "%" in line and "--" not in line.split("%")[0]]
    if leftover:
        raise ValueError(f"unexpanded placeholder in indicators.sql: {leftover[0].strip()}")
    return sql
