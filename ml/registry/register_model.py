"""
Register a completed training job as a model package version.  roadmap.md Phase 9.

WHAT A REGISTRY IS FOR, AND WHY S3 IS NOT ONE
    The training job already writes model.tar.gz to S3, so it is fair to ask
    what a registry adds. Three things S3 cannot:

      - It binds an artifact to the METRICS it earned and the CODE that made it.
        An S3 key is a path; a model package version carries the validation
        numbers, the feature and label versions, and the training job name in
        one queryable record. Phase 13 compares a challenger against a champion,
        and that comparison needs the champion's numbers to still exist.
      - It has an APPROVAL STATE that deployment can gate on, so "which model is
        in production" is a fact the system holds rather than a fact a person
        remembers.
      - It carries an InferenceSpecification, so Phase 10 deploys a registry
        VERSION rather than an S3 URI plus a hand-copied image name.

    Registration is deliberately NOT approval. Every version lands as
    PendingManualApproval, and promote_model.py is the only thing that changes
    that -- using criteria that live in promotion_policy.py and have tests.
"""

from __future__ import annotations

import argparse
import json

import boto3

# The inference half of the same pinned container the training job used. It has
# to be the same family and the same version: a model serialised by XGBoost
# 1.7 and loaded by a different minor version is a failure mode that shows up
# as slightly wrong predictions rather than as an error.
XGBOOST_INFERENCE_IMAGES = {
    "us-east-1": "683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.7-1",
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--training-job-name", required=True)
    p.add_argument("--model-package-group", required=True)
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--metrics-uri", help="s3:// URI of the metrics.json the job wrote; read for the metadata below")
    args = p.parse_args()

    sm = boto3.client("sagemaker", region_name=args.region)
    s3 = boto3.client("s3", region_name=args.region)

    job = sm.describe_training_job(TrainingJobName=args.training_job_name)
    if job["TrainingJobStatus"] != "Completed":
        raise SystemExit(f"{args.training_job_name} is {job['TrainingJobStatus']}, not Completed")

    artifact = job["ModelArtifacts"]["S3ModelArtifacts"]

    metrics = {}
    metrics_uri = args.metrics_uri or artifact.rsplit("/output/", 1)[0] + "/output/metrics.json"
    try:
        bucket, key = metrics_uri[5:].split("/", 1)
        metrics = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
    except Exception as exc:  # noqa: BLE001
        # Registering without metrics is allowed, and promotion will then refuse
        # the version -- promotion_policy treats absent metrics as a rejection,
        # not as a zero. Failing here instead would lose the artifact entirely
        # over a missing side file.
        print(f"warning: could not read {metrics_uri}: {exc}")

    v = metrics.get("validation", {})
    metadata = {
        "training_job": args.training_job_name,
        "feature_block_version": str(metrics.get("feature_block_version", "unknown")),
        "label_version": str(v.get("label_version", metrics.get("label_version", "unknown"))),
        "pr_auc": str(v.get("pr_auc", "")),
        "positive_rate": str(v.get("positive_rate", "")),
        "lift": str(v.get("lift_over_baseline", "")),
        "rows_validation": str(v.get("rows", "")),
        # Every version starts here. Only promote_model.py writes "production".
        "stage": "candidate",
    }

    request = {
        "ModelPackageGroupName": args.model_package_group,
        "ModelPackageDescription": f"XGBoost signal model from {args.training_job_name}",
        "InferenceSpecification": {
            "Containers": [
                {
                    "Image": XGBOOST_INFERENCE_IMAGES[args.region],
                    "ModelDataUrl": artifact,
                }
            ],
            "SupportedContentTypes": ["text/csv", "application/json"],
            "SupportedResponseMIMETypes": ["text/csv", "application/json"],
            "SupportedRealtimeInferenceInstanceTypes": ["ml.t2.medium", "ml.m5.large"],
            "SupportedTransformInstanceTypes": ["ml.m5.large"],
        },
        # PendingManualApproval, always. Registration records that a model
        # exists; it does not decide that it is good.
        "ModelApprovalStatus": "PendingManualApproval",
        "CustomerMetadataProperties": {k: val for k, val in metadata.items() if val},
    }
    if metrics:
        request["ModelMetrics"] = {
            "ModelQuality": {"Statistics": {"ContentType": "application/json", "S3Uri": metrics_uri}}
        }

    resp = sm.create_model_package(**request)
    print(json.dumps({"model_package_arn": resp["ModelPackageArn"], "metadata": metadata}, indent=2))


if __name__ == "__main__":
    main()
