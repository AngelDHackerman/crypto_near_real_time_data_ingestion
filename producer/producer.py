"""
Binance WebSocket -> Kinesis producer.

roadmap.md Phase 5. The first process in this project that stays alive: a
WebSocket needs a persistent connection, which is why this runs on Fargate and
not on Lambda, whose 15-minute ceiling rules it out.

WHAT IT SUBSCRIBES TO, AND WHY THAT EXACT SET
    @aggTrade + @kline_1m on the 45 symbols with has_stream: true. Phase 4
    measured these on the wire rather than estimating them (data_sources.md
    section 9):

      - @aggTrade over @trade: 3.86x fewer frames live, and at a one-minute
        modelling grain nothing is lost -- aggTrade collapses the fills of one
        taker order at one price into a single event.
      - @kline_1m: 0.5 msg/s per symbol, and it is what makes the free 2017
        backfill and the live stream THE SAME TABLE, field for field.
      - NO @bookTicker. It was recommended before it was measured; measuring
        reversed it. 123.5 msg/s on BTCUSDT alone, 7.7x that symbol's aggTrade
        rate.

WHY IT BATCHES
    Kinesis rounds every record up to 1 KB for billing, and Binance frames are
    146-360 bytes. One record per event therefore bills roughly 4x the bytes
    actually sent -- $47.78/month against $36.38 for identical data. Events are
    accumulated PER SYMBOL into ~5 KB newline-delimited-JSON records.

    Per symbol, not globally, and that is deliberate: the Kinesis partition key
    is the symbol, so all of one asset's records land on one shard in order.
    Packing several symbols into one record would make the partition key
    arbitrary and throw that ordering away the first time the stream is
    resharded.

RUNNING IT LOCALLY
    The Binance WebSocket is public and free, so the whole producer can be
    proved -- connect, parse, batch, reconnect -- without a single AWS resource
    existing. That is exactly how Phase 5 verifies it while the project stays
    dormant:

        DRY_RUN=1 python producer/producer.py

    With DRY_RUN set, nothing is sent to Kinesis and boto3 is never even
    imported; the batches are counted and logged instead.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import signal
import sys
import time
from pathlib import Path

import websockets

LOG = logging.getLogger("producer")

# Binance's combined-stream endpoint. Payloads arrive wrapped as
# {"stream": "<name>", "data": {...}}, which is what lets one connection carry
# all 90 streams -- the per-connection limit is 1,024.
BINANCE_WS_BASE = "wss://stream.binance.com:9443/stream?streams="

# PutRecords hard limits. 500 records and 5 MiB per call; the byte budget is
# kept under the limit so a call is never rejected wholesale for being 1 KB over.
KINESIS_MAX_RECORDS_PER_CALL = 500
KINESIS_MAX_BYTES_PER_CALL = 4_500_000

# A single Kinesis record may not exceed 1 MiB. Nothing here comes close --
# batches flush at ~5 KB -- but the guard means a Binance change cannot turn a
# surprise into a rejected batch.
KINESIS_MAX_RECORD_BYTES = 1_000_000


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def load_symbols() -> list[str]:
    """The subscription list, from Terraform if present, from the file if not.

    BINANCE_SYMBOLS is set by the ECS task definition, which reads
    config/tracked_assets.json itself. The file fallback exists so a local run
    needs no environment at all -- and both paths lead to the same file, so the
    producer cannot end up tracking a different universe from the Lambda.
    """
    env = os.environ.get("BINANCE_SYMBOLS", "").strip()
    if env:
        return [s.strip().upper() for s in env.split(",") if s.strip()]

    config = Path(__file__).resolve().parent.parent / "config" / "tracked_assets.json"
    LOG.info("BINANCE_SYMBOLS unset, falling back to %s", config)
    assets = json.loads(config.read_text())["assets"]

    # has_stream is READ, never assumed. Five of the fifty have no Binance pair:
    # USDT cannot have a USDT pair at all, XMR and DAI are delisted tombstones
    # whose symbols still appear in exchangeInfo as BREAK -- they accept a
    # subscription and then deliver nothing, forever -- and HYPE and KAS were
    # never listed. See data_sources.md section 6.
    return [a["binance_symbol"] for a in assets if a["has_stream"]]


class Config:
    def __init__(self) -> None:
        self.symbols = load_symbols()
        self.stream_types = [
            s.strip()
            for s in os.environ.get("BINANCE_STREAMS", "aggTrade,kline_1m").split(",")
            if s.strip()
        ]
        self.stream_name = os.environ.get("KINESIS_STREAM_NAME", "")
        self.region = os.environ.get("AWS_REGION", "us-east-1")
        self.batch_max_bytes = _env_int("BATCH_MAX_BYTES", 5120)
        self.batch_max_seconds = float(_env_int("BATCH_MAX_SECONDS", 5))

        # No stream name means no Kinesis: local verification, not a silent
        # misconfiguration in production. Made explicit so the two cannot be
        # confused in the logs.
        self.dry_run = os.environ.get("DRY_RUN", "").strip() not in ("", "0", "false")
        if not self.stream_name and not self.dry_run:
            raise SystemExit(
                "KINESIS_STREAM_NAME is unset and DRY_RUN is not set. Refusing to "
                "start: this would look like a working producer that writes nowhere."
            )

        # Bounded, and the bound matters. If Kinesis throttles or the network
        # drops, an unbounded queue turns backpressure into an OOM kill several
        # minutes later, which reads as a crash rather than as the throughput
        # problem it is. Overflow is dropped and COUNTED instead -- a visible
        # number in the logs beats an invisible one in the heap.
        self.queue_max = _env_int("QUEUE_MAX_RECORDS", 10_000)

    def stream_url(self) -> str:
        streams = [
            f"{symbol.lower()}@{stream}"
            for symbol in self.symbols
            for stream in self.stream_types
        ]
        return BINANCE_WS_BASE + "/".join(streams)


# ---------------------------------------------------------------------------
# Counters -- one place, logged on a heartbeat
# ---------------------------------------------------------------------------
class Stats:
    def __init__(self) -> None:
        self.events = 0
        self.records = 0
        self.bytes_out = 0
        self.put_calls = 0
        self.retried_records = 0
        self.dropped_records = 0
        self.reconnects = 0
        self.started = time.monotonic()

    def snapshot(self) -> str:
        elapsed = max(time.monotonic() - self.started, 1e-9)
        return (
            f"events={self.events} ({self.events / elapsed:.1f}/s) "
            f"records={self.records} ({self.records / elapsed:.1f}/s) "
            f"bytes={self.bytes_out} ({self.bytes_out / elapsed / 1024:.1f} KB/s) "
            f"put_calls={self.put_calls} retried={self.retried_records} "
            f"dropped={self.dropped_records} reconnects={self.reconnects}"
        )


# ---------------------------------------------------------------------------
# Per-symbol batching
# ---------------------------------------------------------------------------
class SymbolBatcher:
    """Accumulates one symbol's events into ~5 KB newline-delimited records."""

    def __init__(self, cfg: Config, queue: asyncio.Queue, stats: Stats) -> None:
        self.cfg = cfg
        self.queue = queue
        self.stats = stats
        self._lines: dict[str, list[bytes]] = {}
        self._size: dict[str, int] = {}
        self._opened: dict[str, float] = {}

    def add(self, symbol: str, payload: bytes) -> None:
        lines = self._lines.setdefault(symbol, [])
        if not lines:
            self._opened[symbol] = time.monotonic()
        lines.append(payload)
        self._size[symbol] = self._size.get(symbol, 0) + len(payload) + 1

        if self._size[symbol] >= self.cfg.batch_max_bytes:
            self.flush(symbol)

    def flush(self, symbol: str) -> None:
        lines = self._lines.get(symbol)
        if not lines:
            return

        # Newline-delimited JSON, with a trailing newline. Firehose concatenates
        # records as it writes them into an S3 object, so without the terminator
        # the last event of one record and the first of the next would be glued
        # into a line that parses as neither.
        blob = b"\n".join(lines) + b"\n"
        self._lines[symbol] = []
        self._size[symbol] = 0
        self._opened.pop(symbol, None)

        if len(blob) > KINESIS_MAX_RECORD_BYTES:
            LOG.error("dropping oversized record for %s (%d bytes)", symbol, len(blob))
            self.stats.dropped_records += 1
            return

        try:
            self.queue.put_nowait({"Data": blob, "PartitionKey": symbol})
        except asyncio.QueueFull:
            self.stats.dropped_records += 1
            if self.stats.dropped_records % 100 == 1:
                LOG.error(
                    "queue full (%d records): dropping. Kinesis is not keeping up "
                    "or is unreachable. dropped=%d",
                    self.cfg.queue_max,
                    self.stats.dropped_records,
                )

    def flush_stale(self) -> None:
        """Age out partial batches.

        Without this, a quiet symbol -- XAUt trades a few times a minute -- would
        sit in a half-full buffer until it happened to fill, which at its rate
        could be hours. The tail of the asset list would arrive in Bronze
        arbitrarily late while BTC looked fine.
        """
        now = time.monotonic()
        for symbol, opened in list(self._opened.items()):
            if now - opened >= self.cfg.batch_max_seconds:
                self.flush(symbol)

    def flush_all(self) -> None:
        for symbol in list(self._lines):
            self.flush(symbol)


# ---------------------------------------------------------------------------
# Kinesis writer
# ---------------------------------------------------------------------------
class KinesisWriter:
    def __init__(self, cfg: Config, queue: asyncio.Queue, stats: Stats) -> None:
        self.cfg = cfg
        self.queue = queue
        self.stats = stats
        self.client = None
        if not cfg.dry_run:
            import boto3  # imported here so a dry run needs no AWS SDK at all
            from botocore.config import Config as BotoConfig

            self.client = boto3.client(
                "kinesis",
                region_name=cfg.region,
                # boto3 retries throttled records itself, but only for the CALL.
                # PARTIAL failures inside a successful call are ours to handle --
                # see _put below, which is the bug this whole class exists to
                # avoid.
                config=BotoConfig(retries={"max_attempts": 5, "mode": "adaptive"}),
            )

    async def run(self, stop: asyncio.Event) -> None:
        while not (stop.is_set() and self.queue.empty()):
            batch = await self._collect(stop)
            if batch:
                await self._put(batch)

    async def _collect(self, stop: asyncio.Event) -> list[dict]:
        """Fill one PutRecords call, or return what is there when the queue dries up."""
        batch: list[dict] = []
        total = 0
        try:
            first = await asyncio.wait_for(self.queue.get(), timeout=1.0)
        except asyncio.TimeoutError:
            return []
        batch.append(first)
        total += len(first["Data"])

        while len(batch) < KINESIS_MAX_RECORDS_PER_CALL and total < KINESIS_MAX_BYTES_PER_CALL:
            try:
                item = self.queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            batch.append(item)
            total += len(item["Data"])
        return batch

    async def _put(self, batch: list[dict]) -> None:
        self.stats.records += len(batch)
        self.stats.bytes_out += sum(len(r["Data"]) for r in batch)
        self.stats.put_calls += 1

        if self.cfg.dry_run:
            return

        loop = asyncio.get_running_loop()
        pending = batch
        attempt = 0

        # PARTIAL FAILURE IS THE POINT OF THIS LOOP. PutRecords returns HTTP 200
        # with a FailedRecordCount: individual records can be throttled while the
        # call as a whole "succeeds". Code that checks only for an exception
        # loses those records silently, and silent loss in a market feed looks
        # exactly like a quiet market.
        while pending and attempt < 5:
            resp = await loop.run_in_executor(
                None,
                lambda p=pending: self.client.put_records(
                    StreamName=self.cfg.stream_name, Records=p
                ),
            )
            failed = resp.get("FailedRecordCount", 0)
            if not failed:
                return

            retry = [
                rec
                for rec, out in zip(pending, resp["Records"])
                if out.get("ErrorCode")
            ]
            self.stats.retried_records += len(retry)
            codes = {out.get("ErrorCode") for out in resp["Records"] if out.get("ErrorCode")}
            LOG.warning("put_records: %d/%d failed %s, retrying", failed, len(pending), codes)

            attempt += 1
            await asyncio.sleep(min(2**attempt * 0.1, 2.0) + random.uniform(0, 0.1))
            pending = retry

        if pending:
            self.stats.dropped_records += len(pending)
            LOG.error("giving up on %d records after %d attempts", len(pending), attempt)


# ---------------------------------------------------------------------------
# WebSocket loop
# ---------------------------------------------------------------------------
async def consume(cfg: Config, batcher: SymbolBatcher, stats: Stats, stop: asyncio.Event) -> None:
    url = cfg.stream_url()
    LOG.info(
        "subscribing to %d streams (%d symbols x %d types)",
        len(cfg.symbols) * len(cfg.stream_types),
        len(cfg.symbols),
        len(cfg.stream_types),
    )

    backoff = 1.0
    while not stop.is_set():
        try:
            # RECONNECTION IS A ROUTINE PATH, NOT AN ERROR PATH. Binance forcibly
            # closes every connection at 24 hours, and sends a serverShutdown
            # notice before a maintenance restart. Both are expected several
            # times a week; treating them as failures produces an alert storm
            # that trains everyone to ignore the alerts.
            #
            # ping_interval/ping_timeout implement the documented contract: the
            # server pings every 20 s and expects a pong within 60 s. The library
            # answers server pings automatically; these settings make US probe a
            # silently dead connection rather than sitting on a socket that will
            # never deliver another frame.
            async with websockets.connect(
                url, ping_interval=20, ping_timeout=60, max_queue=4096, close_timeout=5
            ) as ws:
                LOG.info("connected")
                backoff = 1.0
                async for raw in ws:
                    if stop.is_set():
                        break
                    _handle(raw, batcher, stats)

        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 -- reconnect on anything
            if stop.is_set():
                break
            stats.reconnects += 1
            # Jittered exponential backoff. Without the jitter every reconnect
            # after a Binance-side restart would land on the same second.
            delay = min(backoff, 60.0) * (1 + random.uniform(0, 0.3))
            LOG.warning("disconnected (%s: %s), reconnecting in %.1fs", type(exc).__name__, exc, delay)
            await asyncio.sleep(delay)
            backoff = min(backoff * 2, 60.0)


def _handle(raw: str | bytes, batcher: SymbolBatcher, stats: Stats) -> None:
    try:
        msg = json.loads(raw)
    except (ValueError, TypeError):
        LOG.warning("unparseable frame, skipping")
        return

    data = msg.get("data")
    if data is None:
        # Control frames: subscription acks, and the serverShutdown notice.
        # Neither is market data, and neither is an error.
        LOG.info("control frame: %s", str(msg)[:200])
        return

    symbol = data.get("s") or msg.get("stream", "").split("@")[0].upper()
    if not symbol:
        return

    # Ingestion timestamp added at the edge. Bronze is raw, so nothing else is
    # touched -- but the gap between Binance's event time and ours is the only
    # measure of producer lag that survives into the lake, and it cannot be
    # reconstructed later.
    data["_ingested_at"] = int(time.time() * 1000)
    data["_stream"] = msg.get("stream")

    stats.events += 1
    batcher.add(symbol, json.dumps(data, separators=(",", ":")).encode("utf-8"))


async def flusher(batcher: SymbolBatcher, stop: asyncio.Event) -> None:
    while not stop.is_set():
        await asyncio.sleep(0.5)
        batcher.flush_stale()


async def heartbeat(stats: Stats, stop: asyncio.Event) -> None:
    while not stop.is_set():
        await asyncio.sleep(60)
        LOG.info("stats: %s", stats.snapshot())


# ---------------------------------------------------------------------------
async def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )

    cfg = Config()
    LOG.info(
        "starting: %d symbols, streams=%s, target=%s",
        len(cfg.symbols),
        cfg.stream_types,
        "DRY RUN (nothing is sent)" if cfg.dry_run else cfg.stream_name,
    )

    stats = Stats()
    queue: asyncio.Queue = asyncio.Queue(maxsize=cfg.queue_max)
    batcher = SymbolBatcher(cfg, queue, stats)
    writer = KinesisWriter(cfg, queue, stats)
    stop = asyncio.Event()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        # SIGTERM is how ECS stops a task. Catching it lets the buffers drain
        # into Kinesis instead of being lost in the container's last 30 seconds.
        loop.add_signal_handler(sig, stop.set)

    consumer = asyncio.create_task(consume(cfg, batcher, stats, stop))
    tasks = [
        consumer,
        asyncio.create_task(flusher(batcher, stop)),
        asyncio.create_task(heartbeat(stats, stop)),
        asyncio.create_task(writer.run(stop)),
    ]

    # Wait on the stop signal OR the consumer dying, not on the signal alone.
    # consume() reconnects from any exception, so it should only finish when
    # asked to -- but "should only" is how a 24/7 process ends up sitting there
    # holding a healthy ECS task that produces nothing, which is worse than
    # crashing because nothing alerts on it. If it exits, so do we, and ECS
    # restarts the task.
    stopper = asyncio.create_task(stop.wait())
    done, _ = await asyncio.wait({stopper, consumer}, return_when=asyncio.FIRST_COMPLETED)
    stopper.cancel()

    if consumer in done and not stop.is_set():
        stop.set()
        exc = consumer.exception()
        LOG.error("consumer exited unexpectedly (%s), shutting down", exc)

    LOG.info("shutting down, draining buffers")
    batcher.flush_all()

    for task in tasks[:-1]:
        task.cancel()
    await asyncio.gather(*tasks[:-1], return_exceptions=True)
    await asyncio.wait_for(tasks[-1], timeout=30)

    LOG.info("final stats: %s", stats.snapshot())

    # Non-zero so ECS records a failed task rather than a clean stop. A clean
    # exit code on an unexpected death is how a crash-loop hides.
    return 0 if consumer.cancelled() or consumer.exception() is None else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
