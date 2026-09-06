"""
The free Binance kline archive -> Bronze.  roadmap.md Phase 7.

WHAT THIS CLOSES
    A pipeline switched on in Phase 5 produces WEEKS of data. Phases 8 and 13
    need years: a model trained on three weeks of one market regime has learned
    that regime, and a degradation threshold needs a history to be a threshold
    against. data_sources.md section 11 established that Binance publishes its
    entire 1-minute history for free at data.binance.vision -- ~133 million
    candles over the 45 streamed pairs, ~4.4 GB, no API key and no quota.

    This job downloads that archive. It never touches Kinesis or Firehose, so
    none of the section 9 cost analysis applies to it: the only money it spends
    is S3 storage on what it writes.

WHY A PYTHON SHELL JOB AND NOT SPARK
    This is 3,135 HTTP downloads and 3,135 S3 puts. There is no join, no shuffle
    and no aggregation anywhere in it -- it is an IO-bound copy, and a Spark
    cluster would spend its life waiting on sockets while billing for executors
    that compute nothing. A Python shell job at 1 DPU with a thread pool is the
    right shape, and it is the cheapest Glue there is.

    The script deliberately imports nothing outside boto3 and the standard
    library, which has a second consequence worth having: it runs unchanged
    outside Glue (`python3 backfill_binance_klines.py --BRONZE_BUCKET ...`).
    That matters because this job is a ONE-TIME load, and a one-time load that
    can only run inside a managed service is one that cannot be rehearsed.

WHAT LANDS, AND WHY NOT UNDER binance/
    Bronze already has a `binance/` prefix and it belongs to Firehose. The
    streaming Silver job reads that prefix RECURSIVELY as newline-delimited
    JSON; a CSV placed anywhere underneath it would be handed to a JSON parser,
    which does not fail loudly so much as it produces a column of nulls. So the
    archive gets its own top-level prefix:

        bronze/binance_archive/symbol=<CANONICAL>/month=YYYY-MM/<TICKER>-1m-YYYY-MM.csv.gz

    The partition carries the CANONICAL symbol and the file name carries the
    ticker actually downloaded, so `symbol=RENDERUSDT/month=2022-05/RNDRUSDT-1m-2022-05.csv.gz`
    states on its face that this month came from the pre-rename alias. Provenance
    that lives in the path cannot be separated from the data it describes.

THREE TRAPS IN THE ARCHIVE, ALL VERIFIED AGAINST THE LIVE FILES ON 2026-09-06

  1. THE TIMESTAMP UNIT CHANGES MID-ARCHIVE. Files up to and including 2024-12
     carry MILLISECONDS; from 2025-01 onward they carry MICROSECONDS. Verified
     by fetching BTCUSDT-1m for four months either side of the boundary:

         2024-11  1730419200000     (13 digits, ms)
         2024-12  1733011200000     (13 digits, ms)
         2025-01  1735689600000000  (16 digits, us)
         2025-02  1738368000000000  (16 digits, us)

     data_sources.md section 11 says the archive and the live @kline_1m event
     are "the same twelve fields", and that is true of the fields. It is not
     true of their units, and nothing in this repository said so until now.
     Reading a microsecond value as milliseconds does not error -- it silently
     places January 2025 in the year 56,000, which a partition filter then hides
     rather than reports. This job does NOT normalise it (Bronze is raw), but it
     records the detected unit per file in the run manifest, and the Silver job
     detects it per row.

  2. THE CHECKSUM COVERS THE ZIP, NOT THE CSV. Each object has a sibling
     `.CHECKSUM` holding "<sha256>  <filename>" for the ZIP as published.
     Verified against BTCUSDT-1m-2018-01.zip: the published digest and the
     locally computed one match. So the digest is checked BEFORE extraction and
     the extracted CSV is what gets written -- Spark cannot read a member of a
     ZIP, and a Bronze object no reader can open is an archive, not raw data.

  3. history_months IN THE CONFIG IS A MEASUREMENT, NOT A BOUNDARY. It was
     counted on 2026-08-27 and the archive grows every month, so this job walks
     from `binance_history_from` to the current month and treats a 404 as
     "that month does not exist" rather than as an error. That is also how a
     delisting looks from here: XMRUSDT simply stops in 2024-02, and the walk
     records the gap instead of failing on it.

IDEMPOTENCE
    A run skips any month already present in Bronze unless FORCE=true. This job
    downloads gigabytes over the public internet and will be interrupted; the
    correct response to an interruption is to run it again, not to work out what
    it got through. FORCE exists for the one case where re-downloading is the
    point -- re-fetching months the stream also covers, so Phase 7's overlap
    validation has both halves to compare.
"""

# Glue's Python shell runtime is Python 3.9, where `bytes | None` in an
# annotation is evaluated at def time and raises TypeError. This makes every
# annotation lazy, which is the one-line fix and costs nothing locally.
from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import sys
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, timezone, datetime
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

import boto3

BASE_URL = "https://data.binance.vision/data/spot/monthly/klines"

# Binance's own floor. Nothing exists before this, for any pair, so a walk that
# starts earlier only buys 404s. See data_sources.md section 11.
ARCHIVE_FLOOR = "2017-07"

# The boundary from trap 1. Files strictly BEFORE this month are milliseconds;
# this month and after are microseconds. Recorded as a constant rather than a
# magic date so the one place that knows it is greppable.
MICROSECOND_ERA_FROM = "2025-01"

ARG_KEYS = [
    "BRONZE_BUCKET",
    "BRONZE_BACKFILL_PREFIX",
    "TRACKED_ASSETS_URI",
    "MANIFEST_BUCKET",
    "MANIFEST_PREFIX",
]
OPTIONAL_ARGS = {
    "FORCE": "false",
    "MAX_WORKERS": "8",
    # Both inclusive, YYYY-MM. Empty means "the whole archive". They exist so a
    # rehearsal can fetch one month of one asset before committing to 4.4 GB.
    "MONTH_FROM": "",
    "MONTH_TO": "",
    "ONLY_SYMBOLS": "",
}


def resolve_args() -> dict:
    """Read arguments from Glue if we are inside it, from argv if we are not.

    getResolvedOptions is the Glue way and it is not importable outside Glue, so
    the fallback is what makes the local rehearsal described in the header
    possible. Both paths accept the same `--KEY value` spelling, which is
    already how Glue passes them.
    """
    try:
        from awsglue.utils import getResolvedOptions  # noqa: PLC0415

        supplied = {a.lstrip("-").split("=")[0] for a in sys.argv}
        optional = [k for k in OPTIONAL_ARGS if k in supplied]
        args = getResolvedOptions(sys.argv, ARG_KEYS + optional)
    except ImportError:
        args = {}
        argv = sys.argv[1:]
        for i in range(0, len(argv) - 1, 2):
            args[argv[i].lstrip("-")] = argv[i + 1]
        missing = [k for k in ARG_KEYS if k not in args]
        if missing:
            raise SystemExit(f"missing required arguments: {', '.join(missing)}")

    for key, default in OPTIONAL_ARGS.items():
        args.setdefault(key, default)
    return args


def month_range(start: str, end: str):
    """Inclusive walk over YYYY-MM strings. Ordinary date arithmetic, spelled
    out because `dateutil` is not in the Glue Python shell environment."""
    y, m = (int(p) for p in start.split("-"))
    ey, em = (int(p) for p in end.split("-"))
    while (y, m) <= (ey, em):
        yield f"{y:04d}-{m:02d}"
        m += 1
        if m == 13:
            y, m = y + 1, 1


def http_get(url: str, retries: int = 4) -> bytes | None:
    """Fetch a URL, returning None for a 404 and raising for anything else.

    The 404/error distinction is the whole point. A missing month is DATA -- it
    is what a delisting or a not-yet-listed pair looks like from here -- while a
    503 is a transient failure that must be retried and then, if it persists,
    must stop the run rather than be recorded as an absent month. Collapsing the
    two would let a bad afternoon at the CDN masquerade as a gap in Binance's
    history, and nothing downstream could tell the difference afterwards.
    """
    for attempt in range(retries):
        try:
            with urlopen(url, timeout=120) as resp:
                return resp.read()
        except HTTPError as exc:
            if exc.code == 404:
                return None
            if attempt == retries - 1:
                raise
        except (URLError, TimeoutError):
            if attempt == retries - 1:
                raise
        time.sleep(2**attempt)
    return None


def detect_time_unit(first_line: str) -> str:
    """Milliseconds or microseconds, read from the value rather than the date.

    Deriving this from the month would work today and would be a latent bug:
    it would encode Binance's 2025-01 change as an assumption about every file,
    including ones re-published later. The magnitude is the fact -- a 1-minute
    open time in ms has 13 digits until the year 2286 -- so it is what gets
    checked, and MICROSECOND_ERA_FROM is used only to cross-check and warn.
    """
    open_time = first_line.split(",", 1)[0].strip()
    return "us" if len(open_time) >= 16 else "ms"


def fetch_one(symbol: str, ticker: str, month: str, cfg: dict) -> dict:
    """Download, verify, extract and upload one asset-month. Returns a manifest row."""
    s3 = cfg["s3"]
    name = f"{ticker}-1m-{month}"
    key = f"{cfg['prefix']}/symbol={symbol}/month={month}/{name}.csv.gz"

    if not cfg["force"]:
        try:
            s3.head_object(Bucket=cfg["bucket"], Key=key)
            return {"symbol": symbol, "ticker": ticker, "month": month, "status": "skipped"}
        except s3.exceptions.ClientError:
            pass

    url = f"{BASE_URL}/{ticker}/1m/{name}.zip"
    payload = http_get(url)
    if payload is None:
        return {"symbol": symbol, "ticker": ticker, "month": month, "status": "absent"}

    # Verify BEFORE extracting. A corrupt ZIP that still unzips is the case this
    # guards against, and it is not hypothetical over 3,135 downloads.
    published = http_get(f"{url}.CHECKSUM")
    if published is None:
        raise RuntimeError(f"{name}.zip exists but its .CHECKSUM does not; refusing to trust it")
    expected = published.decode().split()[0]
    actual = hashlib.sha256(payload).hexdigest()
    if actual != expected:
        raise RuntimeError(f"checksum mismatch for {name}.zip: published {expected}, got {actual}")

    with zipfile.ZipFile(io.BytesIO(payload)) as zf:
        member = zf.namelist()[0]
        csv_bytes = zf.read(member)

    text = csv_bytes.decode("utf-8", errors="strict")
    lines = text.splitlines()
    # Binance began shipping a header row on some datasets. Detect it by trying
    # the first field as an integer rather than by matching a literal, because
    # the header's exact wording is not a contract.
    if lines and not lines[0].split(",", 1)[0].strip().isdigit():
        lines = lines[1:]
        text = "\n".join(lines) + "\n"
        csv_bytes = text.encode("utf-8")
    if not lines:
        return {"symbol": symbol, "ticker": ticker, "month": month, "status": "empty"}

    unit = detect_time_unit(lines[0])
    expected_unit = "us" if month >= MICROSECOND_ERA_FROM else "ms"
    unit_surprise = unit != expected_unit

    body = gzip.compress(csv_bytes, compresslevel=6)
    s3.put_object(
        Bucket=cfg["bucket"],
        Key=key,
        Body=body,
        ContentType="text/csv",
        ContentEncoding="gzip",
        ServerSideEncryption="AES256",
        Metadata={
            # Carried on the object as well as in the manifest: a manifest can be
            # lost, and then the unit is unrecoverable from the bytes alone for
            # any month whose data happens to be sparse.
            "binance-ticker": ticker,
            "time-unit": unit,
            "sha256-zip": actual,
            "row-count": str(len(lines)),
        },
    )
    return {
        "symbol": symbol,
        "ticker": ticker,
        "month": month,
        "status": "written",
        "key": key,
        "rows": len(lines),
        "sha256_zip": actual,
        "time_unit": unit,
        "time_unit_surprise": unit_surprise,
        "bytes_gz": len(body),
    }


def main() -> None:
    args = resolve_args()
    s3 = boto3.client("s3")

    # An s3:// URI in Glue, a plain path in a local rehearsal. The second form
    # is not a convenience: the header promises this script runs outside Glue,
    # and requiring the config to already be in S3 would mean the rehearsal
    # could only happen after the deploy it is meant to de-risk.
    uri = args["TRACKED_ASSETS_URI"]
    if uri.startswith("s3://"):
        cfg_bucket, cfg_key = uri[5:].split("/", 1)
        tracked = json.loads(s3.get_object(Bucket=cfg_bucket, Key=cfg_key)["Body"].read())
    else:
        with open(uri) as fh:
            tracked = json.load(fh)

    today = date.today()
    month_to = args["MONTH_TO"] or f"{today.year:04d}-{today.month:02d}"
    only = {s.strip().upper() for s in args["ONLY_SYMBOLS"].split(",") if s.strip()}

    # Build the work list. An asset contributes its own pair plus every
    # pre-rename alias, and the alias months are the point: RNDRUSDT holds 33
    # months RENDERUSDT does not, MATICUSDT holds 66 that POLUSDT does not.
    # Downloading only the current ticker returns a clean-looking file that is
    # missing more history than it contains (data_sources.md section 11).
    work = []
    for asset in tracked["assets"]:
        if not asset.get("has_stream"):
            continue  # the five CMC-only assets have no Binance pair, by definition
        canonical = asset["binance_symbol"]
        if only and canonical.upper() not in only:
            continue
        sources = [(canonical, asset.get("binance_history_from") or ARCHIVE_FLOOR)]
        for alias in asset.get("binance_symbol_aliases", []):
            sources.append((alias["symbol"], alias.get("history_from") or ARCHIVE_FLOOR))
        for ticker, history_from in sources:
            start = max(history_from, args["MONTH_FROM"] or ARCHIVE_FLOOR, ARCHIVE_FLOOR)
            for month in month_range(start, month_to):
                work.append((canonical, ticker, month))

    cfg = {
        "s3": s3,
        "bucket": args["BRONZE_BUCKET"],
        "prefix": args["BRONZE_BACKFILL_PREFIX"].strip("/"),
        "force": args["FORCE"].lower() == "true",
    }

    print(f"backfill: {len(work)} asset-months queued, force={cfg['force']}, through {month_to}")

    rows, failures = [], []
    with ThreadPoolExecutor(max_workers=int(args["MAX_WORKERS"])) as pool:
        futures = {pool.submit(fetch_one, sym, tic, mon, cfg): (sym, tic, mon) for sym, tic, mon in work}
        for done, future in enumerate(as_completed(futures), start=1):
            symbol, ticker, month = futures[future]
            try:
                rows.append(future.result())
            except Exception as exc:  # noqa: BLE001 -- recorded, then re-raised in aggregate below
                failures.append({"symbol": symbol, "ticker": ticker, "month": month, "error": str(exc)})
            if done % 200 == 0:
                print(f"  {done}/{len(work)} done, {len(failures)} failed")

    written = [r for r in rows if r["status"] == "written"]
    summary = {
        "run_at_utc": datetime.now(timezone.utc).isoformat(),
        "queued": len(work),
        "written": len(written),
        "skipped": sum(1 for r in rows if r["status"] == "skipped"),
        "absent": sum(1 for r in rows if r["status"] == "absent"),
        "empty": sum(1 for r in rows if r["status"] == "empty"),
        "failed": len(failures),
        "rows_total": sum(r.get("rows", 0) for r in written),
        "bytes_gz_total": sum(r.get("bytes_gz", 0) for r in written),
        "time_unit_surprises": [r for r in written if r.get("time_unit_surprise")],
        "files": sorted(written, key=lambda r: (r["symbol"], r["month"])),
        "failures": failures,
    }

    # The manifest goes to ARTIFACTS, not to Bronze. It is not lake data, and
    # putting it under the archive prefix would also break Spark's `symbol=`
    # partition discovery on the way back out.
    manifest_key = f"{args['MANIFEST_PREFIX'].strip('/')}/run={summary['run_at_utc']}.json"
    s3.put_object(
        Bucket=args["MANIFEST_BUCKET"],
        Key=manifest_key,
        Body=json.dumps(summary, indent=2).encode(),
        ContentType="application/json",
        ServerSideEncryption="AES256",
    )

    print(json.dumps({k: v for k, v in summary.items() if k not in ("files", "failures")}, indent=2))
    print(f"manifest: s3://{args['MANIFEST_BUCKET']}/{manifest_key}")

    if failures:
        # Fail the job. A partial backfill that reports success is the worst
        # outcome available here: the gap is invisible until a model trains on
        # it. Re-running is cheap -- everything already written is skipped.
        raise SystemExit(f"{len(failures)} asset-months failed; see the manifest")


if __name__ == "__main__":
    main()
