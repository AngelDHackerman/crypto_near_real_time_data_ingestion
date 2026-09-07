"""
Start a SageMaker training job.  roadmap.md Phase 8.

WHY THIS IS A SCRIPT AND NOT A TERRAFORM RESOURCE
    There is no `aws_sagemaker_training_job`, and there should not be. A
    training job is an EXECUTION, not a piece of infrastructure: it starts,
    consumes an input, produces an artifact and ends. Terraform's model is
    desired state, and "this job has run" is not a state you converge on -- an
    apply would either recreate it forever or never again.

    So Terraform owns the durable half (the role, the repository, the buckets
    and their lifecycle) and this owns the ephemeral half. Same boundary the
    backfill draws in Phase 7, and the same one Phase 12's pipeline will call.

WHY boto3 AND NOT THE SAGEMAKER SDK
    The SDK would package the source directory, upload it, guess the image URI
    and call CreateTrainingJob. Doing it explicitly is about twenty more lines
    and removes a dependency whose version resolution has changed the image
    chosen underneath people before. Everything below is visible, and the image
    is PINNED -- which the SDK's `retrieve()` deliberately is not.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import tarfile
import time
from datetime import datetime, timezone

import boto3

HERE = os.path.dirname(os.path.abspath(__file__))

# AWS's managed XGBoost container. The account id is AWS's own per-region
# registry for SageMaker built-in algorithms, and 1.7-1 is pinned for the same
# reason every provider version in this project is pinned: a floating tag can
# change what runs without changing anything in the repository.
XGBOOST_IMAGES = {
    "us-east-1": "683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.7-1",
}

# Regexes SageMaker applies to the training log to turn printed lines into
# CloudWatch metrics. They must match what train.py prints; if they drift, the
# job still succeeds and the metrics are simply absent -- which is why Phase 11
# alarms on the metric's absence as well as on its value.
METRIC_DEFINITIONS = [
    {"Name": "validation:pr_auc", "Regex": r"validation_pr_auc=([0-9\.]+);"},
    {"Name": "validation:positive_rate", "Regex": r"validation_positive_rate=([0-9\.]+);"},
    {"Name": "validation:lift", "Regex": r"validation_lift=([0-9\.]+);"},
]


def build_source_tarball() -> bytes:
    """Package the training directory exactly as script mode expects it.

    A .tar.gz whose members sit at the ROOT, not under a directory: the
    container extracts it and then runs `python <sagemaker_program>` from that
    directory, so one extra level of nesting produces a "no such file" from
    inside a container that has already been billed for.
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name in ("train.py", "splitting.py", "requirements.txt"):
            tar.add(os.path.join(HERE, name), arcname=name)
    return buf.getvalue()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--role-arn", required=True)
    p.add_argument("--training-data-uri", required=True, help="s3://<gold>/gold_ml_training/")
    p.add_argument("--artifacts-bucket", required=True)
    p.add_argument("--code-prefix", default="ml/code")
    p.add_argument("--model-prefix", default="ml/models")
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--instance-type", default="ml.m5.xlarge")
    p.add_argument("--volume-size-gb", type=int, default=50)
    p.add_argument("--max-runtime-seconds", type=int, default=7200)
    p.add_argument("--feature-block-version", default="v1")
    p.add_argument("--embargo-seconds", type=int, default=3600)
    p.add_argument("--wait", action="store_true")
    args = p.parse_args()

    s3 = boto3.client("s3", region_name=args.region)
    sm = boto3.client("sagemaker", region_name=args.region)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    job_name = f"crypto-signal-xgb-{stamp}"

    code_key = f"{args.code_prefix.strip('/')}/{job_name}/sourcedir.tar.gz"
    s3.put_object(
        Bucket=args.artifacts_bucket,
        Key=code_key,
        Body=build_source_tarball(),
        ServerSideEncryption="AES256",
    )
    # Keyed by JOB NAME, not overwritten in place. The code that produced a
    # model has to remain fetchable for as long as the model does, or Phase 9's
    # registry entries point at a lineage that no longer exists.
    code_uri = f"s3://{args.artifacts_bucket}/{code_key}"

    request = {
        "TrainingJobName": job_name,
        "RoleArn": args.role_arn,
        "AlgorithmSpecification": {
            "TrainingImage": XGBOOST_IMAGES[args.region],
            "TrainingInputMode": "File",
            "MetricDefinitions": METRIC_DEFINITIONS,
        },
        "HyperParameters": {
            # The two magic ones that turn the managed container into script
            # mode. They are hyperparameters by convention, not by nature.
            "sagemaker_program": "train.py",
            "sagemaker_submit_directory": code_uri,
            "feature-block-version": args.feature_block_version,
            "embargo-seconds": str(args.embargo_seconds),
        },
        "InputDataConfig": [
            {
                "ChannelName": "train",
                "DataSource": {
                    "S3DataSource": {
                        "S3DataType": "S3Prefix",
                        "S3Uri": args.training_data_uri,
                        "S3DataDistributionType": "FullyReplicated",
                    }
                },
                # Parquet, so the container must not try to parse it. The split
                # happens inside train.py because it is a PURGED time split --
                # SageMaker's channel-level split would be random, which is the
                # leak this whole design exists to avoid.
                "ContentType": "application/x-parquet",
                "InputMode": "File",
            }
        ],
        "OutputDataConfig": {"S3OutputPath": f"s3://{args.artifacts_bucket}/{args.model_prefix.strip('/')}/"},
        "ResourceConfig": {
            "InstanceType": args.instance_type,
            "InstanceCount": 1,
            "VolumeSizeInGB": args.volume_size_gb,
        },
        # A bounded run, always. An unbounded training job is an unbounded bill,
        # and this account is shared with other projects.
        "StoppingCondition": {"MaxRuntimeInSeconds": args.max_runtime_seconds},
        "Tags": [
            {"Key": "Project", "Value": "near-real-time-crypto"},
            {"Key": "ManagedBy", "Value": "launch_training.py"},
        ],
        # No VpcConfig. That is the Phase 8 decision, written where it takes
        # effect: a training job that only reads S3 does not justify a NAT
        # Gateway (~$32/month) or four interface endpoints (~$7/month each).
        # See roadmap.md Phase 8.
    }

    sm.create_training_job(**request)
    print(json.dumps({"training_job": job_name, "code": code_uri, "image": XGBOOST_IMAGES[args.region]}, indent=2))

    if not args.wait:
        return
    while True:
        desc = sm.describe_training_job(TrainingJobName=job_name)
        status = desc["TrainingJobStatus"]
        print(f"  {status} -- {desc.get('SecondaryStatus')}")
        if status in ("Completed", "Failed", "Stopped"):
            if status == "Completed":
                print(f"model artifact: {desc['ModelArtifacts']['S3ModelArtifacts']}")
                for m in desc.get("FinalMetricDataList", []):
                    print(f"  {m['MetricName']}={m['Value']}")
            else:
                print(desc.get("FailureReason", "no reason given"))
                raise SystemExit(1)
            return
        time.sleep(30)


if __name__ == "__main__":
    main()
