"""
Measure the serving path's latency.  roadmap.md Phase 10.

Phase 9's promotion rule has a latency gate and Phase 13 turns it on. A gate
needs a measurement, and the measurement has to come from somewhere reproducible
-- so it comes from here, and the number it prints is written into the model
package's metadata as `latency_p95_ms` where promotion_policy.decide() reads it.

TWO THINGS IT DELIBERATELY DOES

  It reports COLD and WARM separately. A serverless endpoint's first request
  after idle pays 1-3 seconds of container start; averaging that into a p95
  produces a number that describes neither state. The gate is on the warm p95,
  because that is what a running system experiences -- and the cold number is
  printed beside it rather than hidden, because a system that idles between
  signals experiences it too.

  It reports the STAGE breakdown the handler returns. A p95 that regressed is
  only actionable if you know whether S3, the feature query or the model got
  slower; they have completely different fixes.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time

import boto3


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    # Nearest-rank, not interpolated. With 20 samples an interpolated p95 is a
    # weighted average of two observations, which reads as more precision than
    # 20 samples can support.
    k = max(0, min(len(ordered) - 1, int(round(p / 100.0 * len(ordered) + 0.5)) - 1))
    return ordered[k]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--function-name", required=True)
    p.add_argument("--symbol", default="BTCUSDT")
    p.add_argument("--warm-requests", type=int, default=20)
    p.add_argument("--region", default="us-east-1")
    args = p.parse_args()

    lam = boto3.client("lambda", region_name=args.region)
    payload = json.dumps({"symbol": args.symbol}).encode()

    def invoke():
        started = time.perf_counter()
        resp = lam.invoke(FunctionName=args.function_name, Payload=payload)
        wall = (time.perf_counter() - started) * 1000
        body = json.loads(json.loads(resp["Payload"].read())["body"])
        return wall, body

    cold_wall, cold_body = invoke()
    if "latency_ms" not in cold_body:
        raise SystemExit(f"the endpoint did not score: {cold_body}")

    warm, stages = [], {"s3_fetch": [], "features": [], "endpoint": []}
    for _ in range(args.warm_requests):
        wall, body = invoke()
        warm.append(wall)
        for stage in stages:
            stages[stage].append(body["latency_ms"][stage])

    result = {
        "symbol": args.symbol,
        "cold_start_ms": round(cold_wall, 1),
        "warm": {
            "n": len(warm),
            "p50_ms": round(percentile(warm, 50), 1),
            "p95_ms": round(percentile(warm, 95), 1),
            "max_ms": round(max(warm), 1),
            "mean_ms": round(statistics.mean(warm), 1),
        },
        "warm_stage_p95_ms": {k: round(percentile(v, 95), 1) for k, v in stages.items()},
        # The value promote_model.py writes into the model package metadata, and
        # promotion_policy.decide() thresholds on.
        "latency_p95_ms": round(percentile(warm, 95), 1),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
