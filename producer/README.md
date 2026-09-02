# Binance WebSocket producer

The streaming half of ingestion (roadmap.md, Phase 5). Holds one WebSocket to
Binance, batches events per symbol into ~5 KB records, and writes them to
Kinesis with the symbol as the partition key.

**It is not running.** The project is dormant and stays that way until the end
(see *Current state: DORMANT* in `roadmap.md`). The ECS service exists with
`desired_count = 0`, and the Kinesis stream it would write to does not exist at
all — a shard bills from creation, so dormancy here means absent, not idle.

## Verify it without AWS

The Binance WebSocket is public and needs no key, so the producer can be proved
end to end with no AWS resource in existence and nothing billed:

```bash
pip install -r producer/requirements.txt
DRY_RUN=1 LOG_LEVEL=INFO python producer/producer.py
```

It reads `config/tracked_assets.json` directly when `BINANCE_SYMBOLS` is unset,
subscribes to `@aggTrade` + `@kline_1m` on the 45 streamable symbols, and logs a
stats line every 60 s. `boto3` is never imported in this mode.

What to look for: `events/s` in the tens, `records/s` far lower than `events/s`
(batching is working), and `dropped=0`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `KINESIS_STREAM_NAME` | — | Target stream. Required unless `DRY_RUN` is set |
| `AWS_REGION` | `us-east-1` | |
| `BINANCE_SYMBOLS` | from `config/tracked_assets.json` | Comma-separated. Set by the ECS task definition, which reads the same file |
| `BINANCE_STREAMS` | `aggTrade,kline_1m` | Per-symbol stream suffixes |
| `BATCH_MAX_BYTES` | `5120` | Flush a symbol's buffer at this size |
| `BATCH_MAX_SECONDS` | `5` | Flush a partial buffer after this long, so quiet symbols are not held |
| `QUEUE_MAX_RECORDS` | `10000` | Backpressure bound. Overflow is dropped and counted, never buffered without limit |
| `DRY_RUN` | unset | Skip Kinesis entirely |
| `LOG_LEVEL` | `INFO` | |

## Design notes worth knowing before changing it

- **Batching is per symbol, not global.** The partition key is the symbol, so
  one asset's records stay ordered on one shard. Mixing symbols in a record
  makes that key arbitrary.
- **`put_records` partial failures are retried explicitly.** The call returns
  HTTP 200 with a `FailedRecordCount`; code that only catches exceptions loses
  those records silently, and silent loss in a market feed is indistinguishable
  from a quiet market.
- **Reconnects are routine.** Binance closes every connection at 24 h and sends
  `serverShutdown` before maintenance. Backoff is exponential with jitter.
- **`SIGTERM` drains the buffers.** That is how ECS stops a task; without it the
  last few seconds of every deploy are lost.
