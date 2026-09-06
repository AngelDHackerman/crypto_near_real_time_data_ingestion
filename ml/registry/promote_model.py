"""
Promote a candidate to production, or refuse to.  roadmap.md Phase 9.

This file contains NO JUDGEMENT. It reads the registry, hands two records to
promotion_policy.decide(), and carries out whatever that returns. The criteria
are in promotion_policy.py because that is the part worth reviewing in a diff
and worth having tests for -- a promotion script whose rule is buried in an if
statement halfway down a boto3 call is a console click with extra steps.

`--dry-run` is the default posture in CI until Phase 13 wires this to an
automatic retrain: it prints the decision and every reason without changing a
thing, so the rule can be watched making calls before it is allowed to make
them.
"""

from __future__ import annotations

import argparse
import json

import boto3

from promotion_policy import Candidate, decide


def _to_candidate(pkg_detail) -> Candidate:
    meta = pkg_detail.get("CustomerMetadataProperties", {}) or {}

    def num(key):
        try:
            return float(meta[key])
        except (KeyError, ValueError, TypeError):
            return None

    return Candidate(
        version=str(pkg_detail.get("ModelPackageVersion", "?")),
        pr_auc=num("pr_auc"),
        positive_rate=num("positive_rate"),
        lift=num("lift"),
        feature_block_version=meta.get("feature_block_version", "unknown"),
        label_version=meta.get("label_version", "unknown"),
        rows_validation=int(num("rows_validation") or 0),
        latency_p95_ms=num("latency_p95_ms"),
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model-package-group", required=True)
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--candidate-arn", help="defaults to the newest version in the group")
    p.add_argument("--require-latency", action="store_true", help="Phase 13 turns this on")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    sm = boto3.client("sagemaker", region_name=args.region)

    versions = sm.list_model_packages(
        ModelPackageGroupName=args.model_package_group, SortBy="CreationTime", SortOrder="Descending"
    )["ModelPackageSummaryList"]
    if not versions:
        raise SystemExit(f"{args.model_package_group} has no versions")

    details = [sm.describe_model_package(ModelPackageName=v["ModelPackageArn"]) for v in versions]

    candidate_detail = next(
        (d for d in details if d["ModelPackageArn"] == args.candidate_arn), None
    ) if args.candidate_arn else details[0]
    if candidate_detail is None:
        raise SystemExit(f"{args.candidate_arn} is not a version of {args.model_package_group}")

    champion_detail = next(
        (
            d
            for d in details
            if (d.get("CustomerMetadataProperties") or {}).get("stage") == "production"
            and d["ModelPackageArn"] != candidate_detail["ModelPackageArn"]
        ),
        None,
    )

    candidate = _to_candidate(candidate_detail)
    champion = _to_candidate(champion_detail) if champion_detail else None
    decision = decide(candidate, champion, require_latency=args.require_latency)

    print(
        json.dumps(
            {
                "candidate": candidate_detail["ModelPackageArn"],
                "champion": champion_detail["ModelPackageArn"] if champion_detail else None,
                "promote": decision.promote,
                "reasons": decision.reasons,
                "dry_run": args.dry_run,
            },
            indent=2,
        )
    )

    if args.dry_run:
        return
    if not decision.promote:
        # Rejected candidates are marked Rejected rather than left Pending. A
        # queue of Pending versions nobody looked at is indistinguishable from a
        # queue of versions the rule has not run on yet.
        sm.update_model_package(
            ModelPackageArn=candidate_detail["ModelPackageArn"],
            ModelApprovalStatus="Rejected",
            ApprovalDescription="; ".join(decision.reasons)[:1024],
        )
        raise SystemExit(1)

    # Promote, then demote -- in that order. If the process dies between the two
    # there are briefly two production markers, which a human can see and fix.
    # The other order leaves a window with NONE, and "nothing is in production"
    # is the state a deploy reads as "deploy nothing".
    sm.update_model_package(
        ModelPackageArn=candidate_detail["ModelPackageArn"],
        ModelApprovalStatus="Approved",
        ApprovalDescription="; ".join(decision.reasons)[:1024],
        CustomerMetadataProperties={**(candidate_detail.get("CustomerMetadataProperties") or {}), "stage": "production"},
    )
    if champion_detail:
        sm.update_model_package(
            ModelPackageArn=champion_detail["ModelPackageArn"],
            CustomerMetadataProperties={
                **(champion_detail.get("CustomerMetadataProperties") or {}),
                "stage": "archived",
            },
        )
    print(f"promoted {candidate_detail['ModelPackageArn']}")


if __name__ == "__main__":
    main()
