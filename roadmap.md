# Roadmap — `crypto_near_real_time_data_ingestion`

From a batch ingestion pipeline to a full ML/MLOps system on AWS.

**Project goal:** demonstrate end-to-end capability — architecture, data engineering,
ML and MLOps — deployed on AWS with Terraform, as a portfolio piece.
This is **not** a trading project: the model and its alerts are a technical
demonstration, not an investment tool.

**Ground rules for every phase**

- Every resource is defined in Terraform. Nothing is clicked in the AWS console.
- Provider and module versions are pinned exactly (`version = "x.y.z"`), never
  with floating constraints, so `init` can never introduce false drift.
- IAM permissions are minimal and scoped by ARN. `Resource = "*"` requires a
  written justification in a comment.
- Serverless first. Avoid anything that bills 24/7 unless the demo requires it,
  and when it does, make the cost explicit and time-boxed.
- **One bucket per purpose, and the purpose is in the name.** A medallion bucket
  holds only its own layer's data. Everything that is *not* lake data — Glue job
  scripts, Lambda and producer packages, Spark `tmp/` and Spark UI logs, Athena
  query results, and any other one-off — lives in the **artifacts** bucket. The
  Terraform state bucket holds state and nothing else, and no runtime role is
  granted access to it. See Phase 2 (the state bucket) and Phase 2.1 (the lake).

**Account:** `913524903233` · **Region:** `us-east-1` · **Env suffix:** `crypto`

---

## ⏸️ Current state: DORMANT

**The pipeline is deliberately not running.** All three EventBridge rules are
DISABLED in AWS, and `terraform.tfvars` sets `eventbridge_rule_enabled = false`
to match that reality. Nothing is ingesting, nothing is being processed, and
after Phase 2.1 emptied the lake there is nothing left to bill either — four
empty buckets and ~170 KB of Terraform state.

**The state itself is no longer at risk.** Since Phase 2 it lives in
`crypto-tf-state-913524903233`, versioned and locked natively by S3. Losing the
laptop no longer loses the project.

This is intentional, not an outage. Both of the *technical* reasons it started
with are now spent: Phase 4 froze the asset list, so waking up no longer burns
CMC credits on a list about to be replaced, and Phase 6 settled the Bronze
layout, so data landing now would land in its final shape. What keeps the
project asleep is no longer a pending change — it is the standing cost decision
below.

Stronger still: **Phase 2.1 already deleted the lake** — 294,507 objects and
versions removed on purpose. The four buckets exist and are empty, so there is
now literally nothing to lose by staying asleep.

**Wake-up condition — revised 2026-09-01, and now a single one: the project is
built.** It was two technical preconditions (refactor done, streaming deployed);
both are met or in hand, and the condition was replaced by an explicit decision to
**stay asleep through every remaining phase and wake up once, at the end**.

The reason is cost, and it is not hypothetical. A Kinesis provisioned shard bills
**$10.95/month from the moment it exists**, at zero traffic — waking up in Phase 5
would mean paying a recurring bill for years of phases before anything serves a
prediction. So dormancy stopped being "wait until the code is stable" and became a
standing constraint on the design.

**What that constraint forces:** every billable resource gets a Terraform gate
defaulting to off, and a gate is `count = 0` when the resource bills merely by
existing — a disabled schedule is free, a created shard is not. Three flags
carry this today, all `false`:

| Flag | Gates | Cost when open | Guards |
|---|---|---:|---|
| `eventbridge_rule_enabled` | the CMC extractor's schedule | ~$0 (CMC free tier) | a bill |
| `sfn_daily_schedule_enabled` | the daily Silver → Gold schedule, now **six** Glue job runs a day | Glue DPU-hours per run | a bill |
| `streaming_enabled` | the Kinesis stream, the Firehose delivery stream, the producer's `desired_count` | ~$25/mo | a bill |
| `serving_enabled` | the SageMaker model, endpoint config, endpoint and inference Lambda | **$0 at rest** (serverless, per-request) | **an apply that would fail** |
| `slack_enabled` | the Slack notifier Lambda and its SNS subscription | $0 | **a credential that does not exist** |

**The last two are not cost gates, and reading them as such is a mistake this
table exists to prevent.** `serving_enabled = true` does not start a bill —
serverless inference costs nothing at rest — it fails the apply, because an
`aws_sagemaker_model` requires a model artifact that no training run has
produced yet. `slack_enabled = true` costs nothing either; it creates a
subscription that fails on every message until a human pastes a webhook into
Secrets Manager. Three different reasons a flag defaults to false, and only one
of them is money.

`sfn_daily_schedule_enabled` is new in Phase 6, and it was a gap being closed
rather than a feature. That rule had **no `state` in Terraform at all**: the fact that the
daily pipeline was switched off lived in the AWS console and was asserted
nowhere in this repository. A dormancy that only the console knows about is one
apply away from ending.

Everything that is free to exist — VPC without a NAT Gateway, security groups, IAM
roles, ECR repositories, task definitions, log groups, Glue jobs, the state machine
— is applied for real. The lake is fully built and fully asleep.

Waking up is flipping those flags, deliberately and as code, never by clicking in
the console. Until that moment the correct state of this project is **asleep**.

**Preconditions standing between the flags and a working wake-up.** Each is
recorded in two places, because an implicit precondition is one you discover on
the day it blocks you.

1. **The producer image has never been built and its ECR repository is empty**
   (Phase 5). Flipping `streaming_enabled` today starts a task that dies on
   `CannotPullContainerError`. Phase 12's CI/CD pipeline builds that image
   anyway. **This is the only one that blocks the ingestion wake-up.**
2. **The full 4.4 GB backfill has not run** (Phase 7). The job is built and
   rehearsed on four asset-months against the live archive; the full load needs
   the apply first, takes hours, and is the one part of Phases 7–11 that costs
   real money — a few dollars of FLEX Glue, ~$0.15/month of S3.
3. **No model exists**, so `serving_enabled` cannot be true (Phases 8–10).
   Training → registry → promotion, in that order; the scripts and their
   decision rules are written and tested.
4. **The Slack webhook and the DuckDB Lambda layer** (Phases 10–11). One is a
   paste into Secrets Manager, the other is `serving/inference/build_layer.sh`.
5. **The new ops-alerts email subscription needs confirming** (Phase 11). AWS
   cannot confirm one on anyone's behalf, and the destroyed topic's confirmation
   does not transfer.

Phases 8 through 11 add **nothing to the recurring bill**: an IAM role, an empty
ECR repository, a model package group, two SNS topics, three CloudWatch alarms
inside the free tier, and a Secrets Manager secret. The lake is fully built, the
ML half is fully built, and both are asleep.

Phase 3 deliberately did not wake anything, and this was checked rather than
assumed: all three rules were re-read from AWS after the apply and are still
`DISABLED`.

---

## Progress tracker

| # | Phase | Status | Branch / PR | Notes |
|---|-------|--------|-------------|-------|
| 0 | Unblock HTTPS egress from WSL | ✅ Done | — | `aws sts get-caller-identity` works |
| 1 | Recover `terraform.tfstate` by import | ✅ Done | `phase-1/state-recovery-and-roadmap` → `master` | 55 imported, 6 added, 3 changed, **0 destroyed**; plan clean |
| 2 | Remote backend on S3 | ✅ Done | `phase-2/remote-backend` → `master` [#2] | State on `crypto-tf-state-913524903233`, native S3 locking. Plan clean, local state deleted |
| 2.1 | One bucket per layer, clean slate | ✅ Done | `phase-2.1/storage-refactor` → `master` [#1] | 4 buckets created, 3 destroyed, 294,507 objects/versions deleted. Plan clean |
| 3 | Terraform refactor into modules | ✅ Done | `phase-3/terraform-modules` | 69 `moved {}` blocks, **0 destroyed** on the structural apply. 6 modules + `envs/crypto/`. Plan clean |
| 4 | Data source strategy (Binance WS + CMC) | ✅ Done | `phase-4/data-source-strategy` | 50 ids frozen in `config/tracked_assets.json`, 45 streamed + 5 CMC-only. CMC quota 86% → 7.3%. No infra touched |
| 5 | Streaming ingestion (Kinesis + Firehose + producer) | ✅ Done | `phase-5/streaming-ingestion` [#5] | **Does NOT wake the project.** 19 added, 2 changed, **0 destroyed**, **$0/month** — no Kinesis or Firehose exists behind `streaming_enabled = false`. Producer verified against live Binance locally. Tick-to-S3 check deferred to the wake-up |
| 6 | Bronze layout, Silver adaptation, catalog cleanup | ✅ Done | `phase-6/bronze-layout-silver-projection` | **10 added, 4 changed, 10 destroyed**, plan clean afterwards. Not 0-destroyed on purpose: 5 of the destroys are the approved rename's ForceNew blast radius, 5 are the crawler and its IAM. Project still dormant — three rules `DISABLED`, no Kinesis stream |
| 7 | Feature engineering | ✅ Done | `phase-7/feature-engineering` | **16 added, 8 changed, 0 destroyed**. Backfill job rehearsed against the live archive and real S3; indicator maths is one SQL file verified by 13 tests on DuckDB, no Spark needed. `source` promoted to a partition key. Gold catalog migrated out of hand-run DDL, which found an 11-id projection hiding 40 assets. Full 4.4 GB load and the overlap check wait for the apply and the wake-up |
| 8 | Model training | ✅ Done | `phase-8/model-training` | 5 resources, all free. XGBoost binary classifier on AWS's managed container, pinned — the ECR repo exists but **nothing references it**, applying Phase 5's lesson rather than repeating it. Purged time split with an embargo, PR-AUC quoted against the positive rate. 16 more tests, no Spark or AWS needed. The run itself and the baseline metric wait for data |
| 9 | Model registry | ✅ Done | `phase-9/model-registry` | 2 resources, both free. The promotion RULE is a pure function with 13 tests -- margin over champion, absolute floor, minimum validation rows, and a hard block when the label or feature version changed, because then the numbers are not comparable. Registering two real versions waits for data |
| 10 | Serving / inference | ✅ Done | `phase-10/serving-inference` | **0 resources added** — all gated. Forcing the flag plans 30, so the gated path is verified rather than assumed. Serverless (no VPC: serverless inference cannot take one, and the provisioned alternative is ~3x the whole project's cost). Inference recomputes features from the SAME indicators.sql on DuckDB, pinned to the tested version, which is what removes training/serving skew by construction. 10 more tests |
| 11 | Monitoring & alerting (SNS refactor) | ✅ Done | `phase-11/monitoring-alerting` | **33 added, 10 changed, 3 destroyed** — the destroys are the old topic, its policy and its confirmed email subscription, so there is one confirmation email to click. The policy fix was a precondition, not a cleanup: no alarm in this phase could have published. Added an `aws:SourceAccount` condition the original finding did not ask for. Model Monitor declined with reasons; data capture enabled, which hands Phase 13 its prediction log |
| 12 | Containerization + GitHub Actions CI/CD | ⬜ Not started | | Learn in depth, do not delegate |
| 13 | Model feedback loop | ⬜ Not started | | **Main goal of the project** |

Status legend: ⬜ Not started · 🟡 In progress · ✅ Done · ⏸️ Blocked

---

## Phase 0 — Unblock HTTPS egress ✅

**Problem:** `aws` CLI calls hung (exit 124) from the WSL shell. ICMP worked, TLS
did not. Nothing in Phase 1 was executable until this was fixed.

**DoD:** `aws sts get-caller-identity` returns account `913524903233`. ✅

---

## Phase 1 — Recover `terraform.tfstate` by import ✅

The original state file was local-only and was destroyed during the move from
Guatemala to Uruguay. Everything remained deployed in AWS, orphaned from
Terraform. This phase re-adopted it without recreating anything.

**What was done**

1. **Reconstructed `terraform/terraform.tfvars` from the live account.**
   It was never in git (`.gitignore` excludes `*.tfvars`), and `variables.tf`
   declares 22 required variables with no defaults. Values were read back via
   AWS CLI from the Lambda env vars, Glue job arguments, crawler targets and the
   Athena workgroup — never guessed, because bucket names are immutable and a
   wrong value would have been planned as destroy + recreate of the data lake.
   This is how `environment = "crypto"` was recovered.

2. **Pinned versions** — `provider.tf` said `aws >= 5.0` while the lock file held
   `5.100.0`. Any `init -upgrade` would have pulled provider v6, whose S3
   breaking changes would have filled the import plan with false drift.
   Now pinned to `aws 5.100.0`, `archive 2.7.1`, `terraform ~> 1.15.0`, plus
   `allowed_account_ids` so wrong credentials fail fast.

3. **Added `prevent_destroy = true`** to the three S3 buckets as a guard rail
   before the first plan was ever run.

4. **Resolved ambiguous auto-generated identifiers.** Three
   `aws_cloudwatch_event_target` resources and one `aws_iam_role_policy` had no
   explicit name, so AWS assigned random `terraform-2025...` IDs. Those were read
   with `aws events list-targets-by-rule` / `aws iam list-role-policies` and
   pinned in code — without them the resources are not addressable by import and
   every plan would propose a replacement.

5. **Fixed a real bug** in `iam_lambda.tf`: a `data "aws_secretsmanager_secret"`
   looked up by hardcoded name the very same secret that `secrets_manager.tf`
   creates as a resource. An implicit dependency Terraform cannot see, which
   breaks on a clean destroy/apply. Now references the resource directly.

6. **Imported via declarative `import {}` blocks** (55 addresses) rather than 55
   CLI calls — reviewable in the diff, idempotent, re-runnable.

**Deliberately excluded from the import**

- The four `aws_s3_object` Glue scripts: `etag`/`source` always show drift on
  import. Letting Terraform create them just re-uploads identical objects.
- `aws_iam_role_policy_attachment.glue_service` and `.attach_service_role`:
  declared in code but **not attached in AWS** — someone detached the managed
  `AWSGlueServiceRole` manually. That is genuine drift, corrected by the apply.

**Result:** `55 imported, 6 added, 3 changed, 0 destroyed`. Follow-up plan reports
*"No changes. Your infrastructure matches the configuration."*
State backed up outside the repo at `~/crypto-tfstate-backup-20260823.json`.

**Also discovered:** all three EventBridge rules are **DISABLED** in AWS — the
pipeline is not currently running. `terraform.tfvars` sets
`eventbridge_rule_enabled = false` to match reality.

**DoD** ✅
- [x] `terraform.tfvars` reconstructed from live AWS, no guessed values
- [x] Provider versions pinned exactly
- [x] `prevent_destroy` on all three buckets
- [x] `terraform plan` → `No changes`
- [x] State backed up outside the repo

---

## Phase 2 — Remote backend on S3 ✅

**Goal:** eliminate the root cause of this whole mess. The state was still a local
file; one more machine migration and it would have been lost again.

**Done.** State now lives at
`s3://crypto-tf-state-913524903233/crypto/terraform.tfstate` — versioned,
encrypted, and locked natively by S3.

**Why a dedicated bucket and not the artifacts bucket.** Reusing it was considered
and rejected. Three reasons, all found in this repository's own code rather than
in style preference. Two of them describe the code *as it was when the decision
was made* — Phase 2.1 has since fixed them — but they are kept here because the
conclusion does not depend on them being current:

1. Its lifecycle rule expires noncurrent versions after 90 days across the
   **whole bucket** (`expire-old-artifact-versions` today; back then
   `expire-old-artifacts` with `filter { prefix = "" }`). Version history is the
   only thing that saves a corrupted apply, and there the entire state history
   would carry a 90-day fuse. Working around it means carving prefix exceptions
   into lifecycle rules. Not doing that juggling. **Still true today**, and on its
   own it settles the question.
2. The Silver Glue role (`iam_glue_job_silver.tf`) held `s3:PutObject` and
   `s3:DeleteObject` on `artifacts.../*` with **no prefix restriction**. A data
   processing role must not be able to delete the Terraform state. Phase 2.1
   scoped that role, but the lesson survives it: anything with write access to
   that bucket is one careless policy edit away from being able to delete state.
3. Athena writes query results there on a 30-day expiry. Adding state would make
   it a bucket doing four unrelated jobs under one blast radius.

A bucket itself costs nothing — storage and requests bill identically either way.
So the state gets its own bucket, and **no runtime role is ever granted access
to it**.

**Scope**

- Create an S3 state bucket, `crypto-tf-state-913524903233`, with versioning
  enabled, SSE, and public access fully blocked. The account-id suffix is what makes
  the name safe: bare `crypto-tf-state` and `crypto-tfstate` are already taken by
  other AWS accounts, since S3 names are global rather than per-account.
- Chicken-and-egg: create the bucket with a small bootstrap config using local
  state, then `terraform import` it into the main config.
- Add the `backend "s3"` block using **native S3 locking** (`use_lockfile = true`)
  — no DynamoDB table needed on modern Terraform.
- `terraform init -migrate-state` to move the local state up.
- Delete the local `terraform.tfstate*` files only after verifying the remote
  state is readable and the plan is still clean.

**DoD**
- [x] State bucket `crypto-tf-state-913524903233` exists, versioned, SSE (AES256), public access blocked
- [x] `backend "s3"` configured with `use_lockfile = true` (`terraform/backend.tf`)
- [x] `terraform init -migrate-state` completed successfully — 87 resources now read from S3
- [x] `terraform plan` still reports `No changes` reading from the remote state
- [x] Local `terraform.tfstate` / `.tfstate.backup` deleted; the bucket is managed by this same config (`terraform/tfstate.tf`)
- [x] Concurrent-run lock verified: a second `plan` was rejected with `412 PreconditionFailed` while the first held the lock, and named the holder (`OperationTypePlan`, `hp@Angel-Hackerman-Lab`)
- [x] No lifecycle rule on the state bucket — old versions are the undo history and must never expire
- [x] No runtime role (Lambda, Glue, Step Functions, Athena, crawler) has any statement naming the state bucket; checked that none of them carries a wildcard S3 resource either

**What actually happened**

The bootstrap ran as planned: `terraform/bootstrap-tfstate/` created the four
resources with local state, they were imported one by one into the main config,
and the plan came back at **zero diffs** before the backend block was touched —
so the import was proven clean while the state was still local and recoverable.
That directory was **deleted** after the import: two configs declaring the same
bucket is a footgun, and the procedure is recorded here to rebuild it if ever
needed.

`init -migrate-state` truncated the local `terraform.tfstate` to 0 bytes and left
the pre-migration copy in `terraform.tfstate.backup`; both were deleted after the
remote read was verified. A full copy is at
`~/crypto-tfstate-backup-before-phase2-migrate-20260825-1200.json`.

The state key is `crypto/terraform.tfstate` — the `crypto/` prefix leaves room for
the `envs/<env>/` layout Phase 3 introduces without another state migration.

**One consequence to remember:** this config now manages the bucket its own state
lives in. A real `terraform destroy` needs `terraform state rm` on the four
`tf_state` resources first, then a manual empty-and-delete. `prevent_destroy` is
set, so an accidental one fails loudly rather than deleting the state mid-apply.

**Prompt to run**

> Phase 2 of roadmap.md: move Terraform state to a remote S3 backend.
> Create the state bucket `crypto-tf-state-913524903233` with versioning, SSE and
> public access blocked, using a bootstrap config; then import it into the main
> config so Terraform manages its own backend bucket. Configure `backend "s3"`
> with native locking (`use_lockfile = true`), run `terraform init -migrate-state`,
> and verify `terraform plan` still reports "No changes" against the remote state.
> Only then delete the local state files. Do not change any other resource in this
> phase — the plan must stay at zero diffs throughout.

---

## Phase 2.1 — One bucket per layer, clean slate ✅

**Goal:** fix the storage layout before anything else is built on top of it.
Silver and Gold shared a single bucket, the artifacts bucket was called
`artifacts-crypto-data-crypto` (the word twice), and every lifecycle rule and IAM
statement was assembled out of prefix filters. Bucket names are immutable, so this
was not a rename: new buckets, plus the deliberate deletion of the old ones.

**Decided: the data was deleted, not migrated.** The lake held 261,782
bronze objects (587 MB) and 4,268 curated objects (140 MB) — an incomplete series,
over a provisional 11-asset list that Phase 4 replaces with a curated 50, produced
by a polling design that Phase 5 replaces with streaming. It is not training data
for any model this project will ship, and carrying it forward would preserve a
dataset that gets thrown away anyway. The project starts from zero. This is also
the cheapest moment it will ever be: the pipeline is dormant and nothing depends
on the current objects.

**Naming convention:** `crypto-<purpose>-<account_id>`, with the medallion buckets
carrying an explicit `-layer` suffix. Same shape as the neighbour project's
`loteria-tf-state-913524903233` in this shared account.

The account id is not decoration. **S3 bucket names are globally unique across
every AWS account on earth**, and the id suffix is the standard way to guarantee a
name is free — a project-scoped name like `crypto-tf-state` is already taken by a
stranger, as was verified before settling on this convention. Dropping the suffix
would mean racing the rest of the internet for generic names; keeping it means the
name is ours by construction.

| Bucket | What it holds |
|---|---|
| `crypto-bronze-layer-913524903233` | Raw ingested payloads, nothing else |
| `crypto-silver-layer-913524903233` | Cleaned and typed Silver tables, nothing else |
| `crypto-gold-layer-913524903233` | Gold datasets: features base, OHLC, ML training |
| `crypto-artifacts-913524903233` | **Everything that is not lake data** — Glue job scripts, Lambda and producer packages, Spark `tmp/`, Spark UI logs, Athena query results, and any future one-off |
| `crypto-tf-state-913524903233` | Terraform state only. No runtime role gets access |

That fourth row is the standing rule for the whole project: when something new
needs somewhere to live and it is not lake data, it goes in **artifacts**. No new
bucket gets created for code, packages, scratch output or query results.

**Decided: the top-level prefix is the SOURCE, not the layer.** Once the bucket
names the layer, repeating it in the prefix is noise — `top10/silver/` inside a
silver bucket says nothing twice — and `top10` was already a lie (11 assets today,
50 after Phase 4). Phase 4 introduces two sources, so that is what the prefix
carries:

| Bucket | Prefix |
|---|---|
| `crypto-bronze-layer-913524903233` | `cmc/` — joined by `binance/` in Phase 5 |
| `crypto-silver-layer-913524903233` | `cmc/` and `binance/`, until the Phase 4 join defines the merged shape |
| `crypto-gold-layer-913524903233` | `gold_features_base/`, `gold_ohlc/`, `gold_ml_training/` — Gold is source-agnostic by definition, it is already the join |
| `crypto-artifacts-913524903233` | `jobs/`, `producer/`, `tmp/`, `_spark_ui/`, `athena/queries/` |

This is the layout that makes the Phase 4 story legible in an interview: you can
point at `bronze/cmc/` and `bronze/binance/` and the two-source architecture is
visible from the bucket listing alone.

The bronze prefix *below* `cmc/` and `binance/` was left provisional here, for
Phase 6 to settle against whatever Firehose writes. It is settled now, and it
turned out that Firehose writes whatever it is told to: `binance/year=/month=/
day=/hour=/`, Hive-style and free. What is fixed *here* is the top level.

**Scope**

1. **Empty the three existing buckets first.** Terraform cannot delete a bucket
   that still holds objects, and — this is the part that bites — a *versioned*
   bucket is not empty just because its current objects are gone: every noncurrent
   version and every delete marker counts. Two equivalent ways:
   - `force_destroy = true` on the old buckets, applied as its own commit before
     the rewrite. Note that Terraform reads `force_destroy` from **state**, so it
     must be applied *before* the resources leave the config — otherwise the
     destroy fails with `BucketNotEmpty`.
   - Or delete the versions directly (`list-object-versions` + `delete-objects`),
     which collapses the whole phase into a single apply.

   Budget real time for this. The curated bucket showed 4,268 current objects but
   **over 56,000 versions**; bronze holds 261,782 current objects and proportionally
   more.
2. Rewrite `s3.tf` as four buckets under the new convention, each with versioning,
   SSE and public access blocked, and **lifecycle rules that apply to the bucket
   instead of to a prefix filter**. Note that public access blocking is currently
   *not in the code at all* — the live buckets are only covered by the AWS
   account-level default. Declare it explicitly. This removes a latent bug: today's rules match
   on `top10/silver/` and `top10/gold/`, and any prefix rename would have switched
   them off silently, with no error.
3. Repoint every reference. The Python is safe — every Glue job and the Lambda
   already read bucket and prefix from job arguments and env vars, nothing is
   hardcoded there. What actually changes:
   - `terraform.tfvars` and `variables.tf`
   - the four Glue job argument blocks, `lambda.tf`, `athena.tf`,
     `glue_crawlers_catalog.tf`
   - the IAM documents, now scoped by **bucket ARN** — which deletes the
     `_$folder$` ARN triples in `iam_glue_job_gold.tf`
   - the five files in `sql/` carrying hardcoded `LOCATION` and
     `storage.location.template` values
4. Apply: three buckets destroyed, four created, everything else updated in place.
5. **The Silver crawler must be REPLACED, not updated.** It runs with
   `recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"`, and AWS makes the S3 target
   immutable under that setting: `UpdateCrawler` is rejected with
   *"Amazon S3 target is immutable when Crawl new folders only is selected"*.
   Use `terraform apply -replace=aws_glue_crawler.silver_crawler`.

   Replacement is the correct action here rather than a workaround: the crawler's
   internal record of which folders it has already seen refers to a bucket that no
   longer exists, so a fresh crawler is what is actually wanted. It is safe because
   `sfn.tf` references it by name (`var.silver_crawler_name`), not by resource
   attribute, and the name does not change.
6. Drop the Glue catalog tables pointing at the old locations and re-run the Athena
   projection DDL against the new buckets. The tables come back empty by design.
7. The new buckets carry `prevent_destroy = true` from creation — there is no
   window in which they are unprotected.
8. While every reference is being rewritten anyway, collapse the indirection: the
   `aws_s3_bucket` resources become the **single source of truth** for their own
   names, and every other file references `aws_s3_bucket.<x>.id` / `.arn` instead of
   a `bucket_*_name` variable. Holding the same name in both `s3.tf` and
   `terraform.tfvars` is precisely what made the Phase 1 recovery dangerous: a typo
   in tfvars planned a destroy+recreate of the data lake.

**Findings from the execution** — three things that cost real time and are worth
knowing before repeating this on another project:

1. **A versioned bucket is not empty when its current objects are gone.** The
   curated bucket showed 4,268 current objects and turned out to hold 32,388
   versions; bronze held 262,031. `DeleteBucket` returns `409 BucketNotEmpty`
   until every version *and* delete marker is gone. Budget the time.
2. **`force_destroy` is read from state, not from config.** Setting it in the same
   change that removes the resource does nothing — Terraform plans the destroy from
   the prior state. It has to be applied as its own earlier step, or the versions
   deleted out of band.
3. **Lake Formation governs this catalog.** `DROP TABLE` through Athena and
   `glue delete-table` both fail with *"Insufficient Lake Formation permission(s)"*
   even for an account admin, until an explicit `DROP` grant is issued:
   `aws lakeformation grant-permissions --principal DataLakePrincipalIdentifier=<arn>
   --resource '{"Table":{...}}' --permissions DROP`. See `Lake_Formation_Checklist.md`.

**Why here and not later.** It cannot live inside Phase 3 — that phase's
acceptance criterion is a zero-diff plan, and destroying three buckets is not zero
diffs. Doing it *before* Phase 3 means the `storage/` module gets written once,
against the final four-bucket shape, instead of being rewritten immediately after
being frozen.

**It was meant to run after Phase 2, and it did not.** The whole point of the
ordering was that the state should already be safe in its own bucket before any
phase started destroying buckets. In practice 2.1 went first, against the local
state file, with nothing but a manual copy
(`~/crypto-tfstate-backup-before-phase21-20260824-2247.json`) standing between a
bad apply and a repeat of Phase 1. It came out clean, but the ordering was right
and it was skipped — recorded here rather than quietly renumbered, because the
next time the temptation appears the reasoning should be visible.

**DoD**
- [x] Explicit `aws_s3_bucket_public_access_block` on all four buckets — it was missing from the code entirely; only the AWS account default had been protecting them
- [x] Old buckets emptied of every object **version** and delete marker — 294,507 in total
- [x] Four buckets created: bronze, silver, gold, artifacts — versioned, SSE, public access blocked
- [x] Three old buckets destroyed; `aws s3api list-buckets` shows no `lake-*` and no `artifacts-crypto-data-crypto`
- [x] Every lifecycle rule applies at bucket level. The two that keep a prefix in artifacts scope one content type inside the bucket; they do not stand in for a missing bucket boundary
- [x] IAM scoped by bucket ARN; the nine `_$folder$` entries are gone, and the Silver role no longer holds blanket delete on artifacts
- [x] `top10/` gone from every prefix, path and DDL file, replaced by `cmc/` (and `binance/` from Phase 5)
- [x] The five `sql/` files repointed. Catalog tables moved with `ALTER ... SET LOCATION` rather than DROP+CREATE, which keeps the four `gold_ohlc_*` views intact
- [x] Silver crawler **replaced** (not updated) — its S3 target is immutable under `CRAWL_NEW_FOLDERS_ONLY`
- [x] Stale `silver_silver` dropped (wrong name *and* wrong location); `crypto_silver_db` is empty until the crawler creates `silver_cmc`
- [x] `bucket_lake_raw_name` / `bucket_silver_gold_name` / `bucket_artifacts_name` variables deleted; nothing reconstructs a bucket name from tfvars
- [x] `terraform plan` reports `No changes`
- [x] State left alone. NOTE: this phase ran **before** Phase 2, so it executed against the local state file, backed up first to `~/crypto-tfstate-backup-before-phase21-20260824-2247.json`

**Prompt to run**

> Phase 2.1 of roadmap.md: refactor storage into one bucket per layer, deleting the
> current data on purpose. The existing objects are worthless (incomplete series,
> provisional 11-asset list, polling-era design) — do not migrate them. First empty
> the three existing buckets of every object version and delete marker (they are
> versioned, so current objects are not the whole story), either via `force_destroy`
> applied before the resources leave the config, or by deleting the versions directly. Then rewrite `s3.tf` as `crypto-bronze-layer-913524903233` / `crypto-silver-layer-913524903233` / `crypto-gold-layer-913524903233` / `crypto-artifacts-913524903233`
> with bucket-level lifecycle rules (no prefix filters), repoint tfvars, the Glue job
> arguments, `lambda.tf`, `athena.tf`, the crawler, the IAM documents (scoped by bucket
> ARN — drop the `_$folder$` entries) and the five `sql/` DDL files. Replace the
> `top10/` prefix everywhere with the SOURCE as the top-level prefix — `cmc/` now,
> `binance/` from Phase 5. Apply, drop the stale Glue catalog tables, re-run the
> Athena projection DDL, then restore `prevent_destroy = true` and remove
> `force_destroy`. Verify `terraform plan` is clean and that no old bucket survives.

---

## Phase 3 — Terraform refactor into modules ✅

**Goal:** turn 20 flat `.tf` files into a readable module structure.

**Why after the import, not before:** modularising changes state addresses
(`aws_s3_bucket.bronze` → `module.storage.aws_s3_bucket.bronze`).
Refactoring on top of a known-good state, using `moved {}` blocks, keeps the plan
at zero diffs. Refactoring first would have meant importing into module addresses
that had never been validated, with no safety net.

**Target structure**

```
terraform/
├── modules/
│   ├── storage/        # 4 buckets (bronze/silver/gold/artifacts) + versioning + sse + lifecycle
│   ├── ingestion/      # lambda + eventbridge  (later: kinesis + firehose)
│   ├── catalog/        # glue databases + crawler + athena workgroup
│   ├── processing/     # the 4 glue jobs
│   ├── orchestration/  # step functions + eventbridge -> sfn
│   └── observability/  # sns + failure rules + alarms
└── envs/
    └── crypto/         # main.tf, backend.tf, tfstate.tf, versions.tf, terraform.tfvars
```

**As built**, every module carries `main.tf` + `variables.tf` + `outputs.tf` +
`versions.tf`, and `envs/crypto/` also holds `providers.tf`, `variables.tf` and
`outputs.tf`. Two placement calls worth naming: the `aws_s3_object` Glue script
uploads went to `processing/`, not `storage/` — a job script is a deployment
artifact of the job that runs it, and storage owns buckets rather than what goes
in them — and the Athena workgroup went to `catalog/`, since it is the query
surface over the Glue databases rather than a thing of its own.

**Decided: the state bucket does NOT go into `modules/storage/`.** `tfstate.tf`
stays at the env level, next to `backend.tf`. `modules/storage/` is the lake —
bronze, silver, gold, artifacts — and the state bucket is infrastructure *of* the
infrastructure, not a layer of it. Bundling them would also make it possible to
instantiate `module.storage` for a second environment and silently get a second
state bucket in the bargain.

**Careful with the backend when files move.** `backend.tf` moves directory, but
the bucket and key must not change: re-run `terraform init` in `envs/crypto/`
pointing at the same `crypto-tf-state-913524903233` / `crypto/terraform.tfstate`.
That is a re-init, not a second migration — if Terraform offers to migrate state,
something is wrong with the path. The `crypto/` key prefix was chosen in Phase 2
precisely so this move needs no state migration.

**Key principle:** IAM lives inside the module of the resource it serves. Today
`iam_lambda.tf`, `iam_sfn.tf`, `iam_glue_job_gold.tf` etc. sit apart from what
they grant access to, which is exactly what makes the codebase hard to read.

**Also folded into this phase** (deliberate changes, each on its own reviewed plan)

- Rename the four pinned auto-generated identifiers to readable names
  (three event `target_id`s + the Glue inline policy name).
- Tighten IAM: `iam_sfn.tf` grants Glue actions on `Resource = ["*"]`, which
  contradicts the project's own least-privilege rule.
- Remove the unused `top10_list_symbol` variable — declared in `variables.tf`,
  set in `terraform.tfvars`, referenced by nothing. Rename `top10_list_id` to
  match the naming cleanup Phase 2.1 already applied to the S3 prefixes.
  (`gold_spark_ui_prefix` was already deleted in Phase 2.1; what it left behind is
  an orphan comment in `variables.tf` — *"Prefijos para Spark UI y TempDir dentro
  del bucket GOLD"* — now sitting above an unrelated variable. Delete it.)
- Introduce `default_tags` on the provider (kept out of Phase 1 on purpose — it
  would have retagged every deployed resource and flooded the import plan).
- Run `terraform fmt -recursive` (kept out of Phase 1 to keep that diff readable).
- Add `outputs.tf` — there is none today.

**DoD**
- [x] All resources live inside modules; `envs/crypto/` holds only composition — 69 of 73 addresses are under `module.*`; the only 4 left at env level are the `tf_state` resources, which is the point
- [x] Every module has its own `versions.tf` with pinned providers — Terraform does **not** inherit `required_providers` into child modules, so without this a module may resolve a different provider version than the env that calls it
- [x] `moved {}` blocks for every relocated address — 69
- [x] `terraform plan` reports `No changes` after the refactor
- [x] `backend.tf` and `tfstate.tf` live in `envs/crypto/`; `terraform init` there reused the same bucket and key and did **not** offer to migrate state
- [x] The state bucket stayed out of `modules/storage/`
- [x] `terraform fmt -check -recursive` passes
- [x] IAM `Resource = "*"` either scoped to ARNs or justified in a comment
- [x] `moved {}` blocks removed in a follow-up commit once applied
- [x] Cleanup + `default_tags` applied: `4 added, 38 changed, 4 destroyed`. Final plan reports `No changes`
- [x] Verified in AWS, not just in the plan: no `terraform-2025…` identifier survives, and all three EventBridge rules are still `DISABLED` — the phase did **not** wake the project up

**What actually happened**

The refactor itself came out exactly as designed: **69 resources moved with zero
diff**. Two things are worth recording because they will recur.

**1. Relative paths are resolved from the ROOT MODULE directory — and Phase 3
moves that directory.** This is the one place a "zero-diff" module refactor
cannot be zero-diff, and it is structural rather than a mistake:

| Resource | Attribute | Was | Now |
|---|---|---|---|
| `aws_lambda_function.fetch_top10_crypto` | `filename` | `../extractor_bronze_lambda/build/…` | `./../../../extractor_bronze_lambda/build/…` |
| 4 × `aws_s3_object` Glue scripts | `source` | `../glue_jobs_silver_gold/…` | `./../../../glue_jobs_silver_gold/…` |

`source` and `filename` are stored in state, so changing the string is a diff —
even though `etag` and `source_code_hash` stayed identical in the plan, which is
the proof the bytes never changed. The structural apply was therefore
`0 added, 5 changed, 0 destroyed`, and the follow-up plan reports *"No changes."*

There was an alternative — patch those five strings directly in the state file,
since AWS has no notion of either attribute — and it was **rejected on purpose**.
Re-uploading identical bytes is cheap and honest; hand-editing state to
manufacture a prettier plan summary is not.

**2. Names are now owned by the resources that create them.** The Glue job and
crawler names reached the state machine through five tfvars variables — a second
copy of a name the resource already defines, and exactly the duplication that
made the Phase 1 recovery dangerous. They are now module outputs, so a job
rename can no longer silently desynchronise the orchestration that calls it. The
plan confirmed all five values were identical, so this cost zero diffs.

Also deleted, all declared and referenced by nothing: `top10_list_symbol`,
`gold_job_name`, `glue_version`, `glue_worker_type`, `glue_number_of_workers`,
`secrets_manager_name`. `top10_list_id` became `tracked_asset_ids`.

**One caveat recorded rather than fixed.** Scoping the crawler's inline policy to
the Silver database does **not** lower its effective ceiling today, because
`AWSGlueServiceRole` is still attached and that AWS managed policy grants
`glue:*` on `*`. What the scoping buys is that detaching the managed policy
becomes a one-line change instead of a rewrite. **Moot since Phase 6, which
deleted the crawler, the role and the managed-policy attachment together.**

**Prompt to run**

> Phase 3 of roadmap.md: refactor the Terraform codebase into modules
> (storage / ingestion / catalog / processing / orchestration / observability)
> with an `envs/crypto/` composition layer. Move IAM into the module of the
> resource it serves. Use `moved {}` blocks for every relocated address so the
> plan stays at zero diffs — that is the acceptance criterion, verify it.
> Move `backend.tf` and `tfstate.tf` into `envs/crypto/` keeping the SAME bucket
> and key, so the re-init is not a state migration; keep the state bucket out of
> `modules/storage/`. Then, as separate reviewed commits: rename the pinned
> auto-generated identifiers, scope the `Resource = "*"` IAM statements, drop the
> unused `top10_list_symbol` and the orphan Spark UI comment in `variables.tf`,
> add `default_tags`, add `outputs.tf`, and run `terraform fmt -recursive`.

---

## Phase 4 — Data source strategy ✅

**Goal:** decide what actually feeds the pipeline, before writing any Kinesis
code. This decision reshapes everything downstream.

**Done.** The full decision record is [`data_sources.md`](./data_sources.md); the
frozen universe is [`config/tracked_assets.json`](./config/tracked_assets.json).
No Terraform was touched and nothing was woken up.

**The problem with the current source.** The Lambda polls CoinMarketCap every
5 minutes ≈ 8,640 calls/month. CMC's free tier is 10,000 credits/month, and
`quotes/latest` costs 1 credit per call. The pipeline is already at ~86% of quota
— the 5-minute cadence is the free-tier ceiling, not a design choice. CMC's REST
`quotes/latest` is polling; putting Kinesis in front of it does not make it
streaming, and that architecture collapses under the first follow-up question in
an interview.

**Decision (made):** two sources with different roles.

| Source | Role | Cadence |
|---|---|---|
| **Binance WebSocket** | Real-time price/volume ticks — the actual streaming feed | continuous |
| **CoinMarketCap REST** | Market cap, circulating supply, dominance — data no exchange provides | hourly (down from 5 min) |

CMC is **not** replaced, it is repositioned. Market cap, supply and dominance are
properties of an *asset*, not of a *trading pair*: an exchange only knows what
trades on it. CMC also supplies cross-validation against a single venue's price,
covers the five tracked assets that have no Binance pair at all, and keeps writing
if the WebSocket drops, so an outage degrades the pipeline to coarse instead of
blind.

**Also decided:** expand coverage from the current 11 assets to **50**.
Confirmed against CMC's own billing rule: `quotes/latest` costs 1 credit per call
per 100 cryptocurrencies returned, so 50 ids in one batched call still costs
**1 credit** — going from 11 to 50 assets costs nothing. Hourly = **730
credits/month, 7.3% of the free tier**, down from 86.4%.

**Decided: the asset list is STATIC — a hand-picked set of 50, not a live top-50
ranking.** A dynamic `listings/latest` lookup would silently change the tracked
universe every time a coin moves in or out of the market-cap top 50, which is
drift by another name: the training set stops being reproducible, features get
null gaps where an asset entered or left, and a dataset from six months ago
becomes uninterpretable. The list is therefore curated once, committed as code,
and changed only by an explicit commit.

**Decided: the selection criterion is diversity of BEHAVIOUR, not market-cap
rank.** The top 50 by market cap is fifty variations of the same thing — liquid
assets that mostly track Bitcoin. The final set is built from ten cohorts: 8 beta
anchors, 4 stablecoins (the negative control), 2 gold-pegged tokens (a non-crypto
risk factor inside the crypto tape), 10 alt-L1s, 3 L2s, 6 PoW/legacy payments,
7 DeFi, 4 AI/compute, 4 memecoins, and 2 assets chosen precisely because the
stream cannot see them. Ten of the provisional 11 ids survive; BAT (`1697`) is
dropped as behaviourally redundant.

**Decided: Silver stays source-separated and the join happens in GOLD.** This
closes the question Phase 2.1 left open. Silver's contract is "Bronze, cleaned and
typed" — merging two sources is a modelling decision. And the grains do not match:
joining at Silver would mean either downsampling the stream to hourly, throwing
away the entire point of Phase 5, or upsampling CMC to tick grain, which fabricates
rows that were never observed. Gold's prefixes were already made dataset names in
Phase 2.1 on the grounds that Gold "is already the join"; this makes that literal.

**DoD** ✅
- [x] Final 50-asset list curated and frozen, with the CMC id ↔ Binance symbol mapping written down — `config/tracked_assets.json`, generated and validated against live data, not hand-typed
- [x] Selection rationale recorded per asset (why this one is tracked) — one line per asset, in the file and in `data_sources.md`
- [x] List committed as code; no runtime `listings/latest` lookup anywhere
- [x] CMC credit budget recomputed and documented under the free tier — 730/10,000 credits/month (7.3%), and 24/~333 per day
- [x] Silver-layer join strategy between the two sources documented — as-of backward join on `cmc_id`, executed in Gold, with staleness as a column
- [x] Decision and rationale written into `README.md`, not just this roadmap
- [x] No Terraform changed, nothing woken up — the project is still dormant

**What actually happened**

Four things came out of the execution that were not in the plan.

**1. The mapping cannot be keyed on the ticker symbol, and this was proved rather
than assumed.** Building the CMC ↔ Binance mapping against live data surfaced four
distinct ways a symbol join silently corrupts a series: **case** (CMC writes
`XAUt`, Binance's base asset is `XAUT`), **rename** (`RNDR` → `RENDER`, CMC id
`5690` unchanged — `RNDRUSDT` no longer exists on Binance), **re-issue** (MATIC
`3890` → POL `28321`; id `3890` still resolves today, as symbol `MATIC`, with
`status = untracked`), and plain **collision** (several distinct CMC entries share
a symbol). The join key is `cmc_id`, `binance_symbol` is an attribute of it, and
`config/tracked_assets.json` is the bridge table read by the Lambda, the producer
and the Gold job alike.

**2. Five of the fifty have no Binance stream, and that is the point.** USDT
(`825`) is *structurally* unstreamable — it is Binance's quote asset, so
`USDTUSDT` cannot exist. XMR (`328`) and DAI (`4943`) were **delisted**: their
pairs still appear in `exchangeInfo` as tombstones, every one of them `BREAK`.
HYPE (`32196`) and KAS (`20396`) have **zero rows in any role or status** — never
listed at all — and HYPE is a **top-10 asset by market cap**, which is the cleanest
possible proof that the stream is not a superset of the market. The distinction
matters operationally: a `BREAK` symbol accepts a subscription and then delivers
nothing, which is exactly the silent failure `has_stream` exists to prevent. `has_stream` is therefore a config flag the jobs
read, never an assumption in code — a future delisting is a one-line commit rather
than an incident. Single-source assets are **excluded** from the high-frequency
dataset rather than null-padded into it; padding would invent a regular series
where none was observed.

**3. The ingestion path costs more than the producer host — by a lot, if built
naively.** Across the 45 streamed pairs Binance reported **15,960,612 trades in
24 h**, ~185 events/second. A raw WebSocket client then measured the per-stream
rates directly on the wire. Kinesis on-demand **rounds every record up to 1 KB**
and the frames are 146–360 bytes, so one-record-per-event billing costs ~4× the
bytes actually sent. All-in monthly, same data either way:

   | Build | Total |
   |---|---:|
   | `@trade` + `@kline` + `@bookTicker`(8), unbatched, on-demand | **$217.46** |
   | drop `@bookTicker` | $81.34 |
   | `@aggTrade` instead of `@trade` | $47.78 |
   | batch to ~5 KB records | $36.38 |
   | **1 provisioned shard instead of on-demand** | **$12.62** |

   Phase 5 frames its open hosting decision around $10–15/month for Fargate. The
   ingestion path is the larger number, and the 17× spread between the two ends of
   that table is entirely stream selection, batching and capacity mode. Three
   consequences, all handed to Phase 5 rather than acted on here:
   - **`@aggTrade` instead of `@trade`** — measured **3.86× fewer frames** live,
     4.01×/4.69× on a replayed BTCUSDT/ETHUSDT minute, no information lost at a
     one-minute grain.
   - **`@bookTicker` is out of the baseline.** It was recommended before it was
     measured; measuring reversed it. At **123.5 msg/s on BTCUSDT alone** it is
     7.7× that symbol's `@aggTrade` rate, and BTC-only `@bookTicker` moves as much
     data per month as `@aggTrade` + `@kline_1m` over all 45 symbols combined.
   - **`ON_DEMAND` looks like the wrong default.** Measured throughput is
     **17.4 KB/s and ~70 records/s**, against a single provisioned shard's 1 MB/s
     and 1,000 records/s — 60× and 14× headroom, at **$10.95/month flat** versus
     **$29.20/month in on-demand stream-hour charges before a byte is written**.
     It also changes which streams are affordable: provisioned bills 25 KB PUT
     units rather than GB, so batched BTC+ETH `@bookTicker` would add ~$2/month
     there against well over $100 unbatched on on-demand.

**4. Not a single CMC credit was spent, and the API key was never read.** CMC ids
and market caps were verified against CoinMarketCap's own public listing endpoint
(`api.coinmarketcap.com/data-api/v3/...`), which needs no key. The Binance symbol
universe, volumes and trade counts came from `api.binance.com` public endpoints.
Every command is recorded in `data_sources.md` §13 so the whole curation is
reproducible.

**5. There is a free historical archive, and nothing in this roadmap knew about
it.** Phases 7, 8 and 13 need years of data; a stream switched on in Phase 5
produces weeks. Binance publishes its full kline history at `data.binance.vision`,
no key and no quota: **3,135 asset-months, ~133 million 1-minute candles, ~4.4 GB
compressed, $0**, and it bypasses Kinesis entirely. It reaches **2017-07** and no
further — Binance opened that month, so there is no 13-year history to fetch for
any asset, which happens to land exactly where crypto stops being a different
market. Crucially the stitch is **exact**: the archived file and the live
`@kline_1m` event carry the same twelve fields computed by the same exchange over
the same bucket, `number_of_trades` and the taker-buy volumes included — so the
backfill carries order flow, not just OHLCV. Written up in `data_sources.md` §11.

**A Phase 0 false alarm, recorded so it is not re-diagnosed.**
`aws sts get-caller-identity` timed out (exit 124) mid-phase, which looks exactly
like the Phase 0 egress failure. It was not: an active VPN was intercepting the
traffic. With the VPN off the call returns
`arn:aws:iam::913524903233:user/angel-adming` normally. Worth knowing that the
Phase 0 symptom has a second, far more mundane cause.

**Prompt to run**

> Phase 4 of roadmap.md: finalise the two-source data strategy. Help me curate a
> FIXED list of 50 CMC ids — hand-picked, not a live top-50 ranking, because a
> dynamic list would make the training set non-reproducible. Propose selection
> criteria based on diversity of behaviour, then map the list to Binance WebSocket
> symbols and flag every asset that exists in one source but not the other.
> Recompute the CMC credit budget at hourly cadence and confirm it fits the free
> tier. Document the Silver-layer join between the streaming feed and the hourly
> metadata feed. This phase is analysis and documentation only — no Terraform
> changes, and no infrastructure is woken up.

---

## Phase 5 — Streaming ingestion

**Goal:** replace polling with a genuine streaming path.

**Scope**

- `aws_kinesis_stream` in **PROVISIONED mode with one shard** — decided below
  against the Phase 4 measurements (~185 events/s, ~17.4 KB/s and ~70 records/s
  after batching), not inherited as a default. See `data_sources.md` §9.
- Producer holding the Binance WebSocket open, batching `put_records` with
  `PartitionKey` = asset symbol (preserves per-asset ordering within a shard).
- Dedicated IAM role for the producer: `kinesis:PutRecord` / `PutRecords` scoped
  to the stream ARN, never `*`.
- `aws_kinesis_firehose_delivery_stream` from the stream into the existing bronze
  bucket, with `buffering_size` / `buffering_interval` matched to actual volume.
- Dedicated IAM role for Firehose (read the source stream, write the destination
  bucket).
- **The producer ships as a container image to ECR**, not as a zip to the artifacts
  bucket. This is a deliberate deviation from the Phase 2.1 storage rule and it is
  worth naming: a Fargate task *pulls an image*, it cannot download a zip from S3
  and run it. Shipping both would recreate exactly the two-owners-for-one-fact
  problem that rule exists to prevent. The rule still binds everything that really
  is an artifact file — Glue scripts stay under `jobs/`. No new S3 bucket is created.
- Retune the existing CMC Lambda: 5 min → 1 hour, 11 assets → the frozen 50.
- **Read the asset list from `config/tracked_assets.json`**, not from a literal in
  tfvars — the producer takes its subscription list from the same file, filtered on
  `has_stream`, so the two sources cannot drift apart in what they track.
- Subscribe `@aggTrade` + `@kline_1m` on all 45 streamed symbols — 90 streams,
  against a 1,024-per-connection limit. **No `@bookTicker` in the baseline**: it
  measured at 123.5 msg/s on BTCUSDT alone, 7.7× that symbol's `@aggTrade` rate.
  Batch writes to ~5 KB records. Handle the 24-hour forced disconnect, the
  `serverShutdown` event and the 20 s ping / 1 min pong contract as routine paths,
  not error paths (`data_sources.md` §8).

**✅ DECIDED — where the producer runs, and the capacity mode.**

Both open questions were settled on **2026-09-01**, against the Phase 4
measurements, before any producer code was written. Recorded here with their costs
because this is the first recurring bill in the project and it should read as a
choice, not a default.

**Decision 1: the producer runs on ECS/Fargate, 24/7, at 0.25 vCPU / 0.5 GB.**

| Line item | Monthly |
|---|---:|
| Fargate compute — 0.25 vCPU × $0.04048 + 0.5 GB × $0.004445, × 730 h | $9.01 |
| Public IPv4 address — $0.005/h × 730 h | $3.65 |
| **Producer host total** | **~$12.66** |

The alternatives and why they lost: **time-boxed Fargate** turns the demo into a
recording and makes every Phase 13 iteration a manual start/stop; **Lambda +
Binance REST** is free but is still polling, which contradicts the project's own
name and collapses under the first follow-up question in an interview. The honest
argument *against* 24/7 is worth recording too: since the Phase 4 backfill supplies
the training history for free, the stream's marginal value is the tick-level block
and the "near real time" claim itself — not the ability to train a model. That was
judged worth $12.66/month, given Phase 13 needs a live consumer.

**The task runs in a public subnet with a public IP and a security group with no
inbound rules.** This is not incidental: a private subnet would need a NAT Gateway
at **~$33/month**, which costs more than triple the compute it exists to serve. The
producer only makes outbound connections, so it does not need one.

**`desired_count` is a Terraform variable**, exactly like `eventbridge_rule_enabled`
— scaling the producer to zero is a commit, never a click, and the dormancy pattern
established in Phase 2.1 is preserved rather than abandoned the moment something
costs money.

**Decision 2: `ON_DEMAND` is rejected — one provisioned shard.**

The Phase 4 scope flagged this as inherited-by-default rather than chosen. Measured
throughput is **17.4 KB/s and ~70 records/s**, against a single shard's 1 MB/s and
1,000 records/s: **60× and 14× headroom**. One shard is **$10.95/month flat**
against **$29.20/month in on-demand stream-hour charges before a byte is written**
($12.62 vs $36.38 all-in with Firehose and S3, for identical data). On-demand earns
its premium on unpredictable spiky load; this load is small and now measured.

Second-order benefit, carried forward to Phase 7: provisioned bills **25 KB PUT
units** rather than GB, so batched BTC+ETH `@bookTicker` would cost ~$2/month here
against well over $100 unbatched on on-demand. If spread and microprice features are
ever wanted, this decision is what leaves that door open.

**Running total once Phase 5 is live: ~$25/month** ($12.66 producer + $12.62
ingestion path). Set a CloudWatch billing alarm as part of this phase — the point of
measuring all of this is defeated if nobody notices it drifting.

**Decision 3: the project does NOT wake up in this phase. Dormancy is now
permanent until the whole project is built.**

This overrides what this phase said until 2026-09-01, and it changes the design
rather than just the schedule. Two of the three numbers above are **not idle
costs**:

| Resource | Cost while dormant | Why |
|---|---:|---|
| Kinesis provisioned shard | **$10.95/mo** | A shard bills **from creation**, at zero traffic. On-demand is worse: $29.20/mo in stream-hours before a byte is written |
| Firehose delivery stream | $0 | Billed per GB ingested; nothing ingested, nothing billed |
| ECS service at `desired_count = 0` | $0 | No task, no vCPU-hours, no public IP |
| ECR repository | ~$0.10/mo | 500 MB free tier; a ~120 MB image sits inside it |
| VPC, subnets, IGW, SG, IAM, log groups | $0 | Free to exist. **No NAT Gateway** — that would be $33/mo of pure idle cost |

So "build it but leave it switched off" is not achievable by setting
`desired_count = 0` alone: **the Kinesis stream and Firehose must not exist at
all** while dormant, or the project starts paying $10.95/month for a phase that is
still years from serving a prediction.

**The gate is `streaming_enabled`, a single Terraform variable defaulting to
`false`**, applied with `count` to exactly the billable resources — the stream, the
Firehose delivery stream, and the producer's desired count. Everything else is
applied for real, today: VPC, security group, ECR repository, task definition, IAM
roles, log groups. The consequence is the one that matters — **`terraform apply`
on this phase creates a complete, reviewable, plan-clean streaming stack that costs
$0/month**, and waking it up later is one variable, not a rebuild.

This is the same pattern as `eventbridge_rule_enabled`, extended from "a schedule
is disabled" to "a billable resource does not exist". Both stay `false`.

**What this costs the DoD.** "End-to-end verified: a Binance tick lands as an object
in S3" is not provable with the gate closed. It is therefore split: the stack is
verified by `terraform plan`/`apply` and by running the producer against Binance
locally (the WebSocket is public and free, so the producer can be proved to connect,
parse and batch without any AWS resource existing). The single end-to-end assertion
— a tick in S3 — is **explicitly deferred**, and it is the first thing done when the
project is woken up.

**DoD**
- [x] `ON_DEMAND` vs one provisioned shard decided against the Phase 4 measurements, with the choice written down — **one provisioned shard**
- [x] Producer hosting decision made **explicitly**, with its monthly cost and
      reasoning written into this file before any producer code is written —
      **Fargate 24/7, ~$12.66/month**
- [x] `streaming_enabled` gate defaulting to `false`, applied with `count` to every billable resource
- [x] Kinesis stream in PROVISIONED mode, one shard, defined in Terraform (created only behind the gate)
- [x] Producer written, connected, batching per symbol with the symbol as partition key
- [x] Producer IAM role scoped to the stream ARN — composed, not read from the resource, so the policy survives the gate being shut
- [x] Firehose delivering into the bronze bucket, buffering tuned and justified (5 MiB / 300 s, and why not 60 s)
- [x] ~~Producer package uploaded to `crypto-artifacts-913524903233/producer/`~~ — **superseded**: it ships as an ECR image. A Fargate task pulls an image, it cannot run a zip from S3. No new bucket either way
- [x] Producer task in a **public subnet with a public IP, no NAT Gateway**, security group with no inbound rules
- [x] `desired_count` exposed as a Terraform variable, mirroring `eventbridge_rule_enabled`
- [x] CMC Lambda retuned to hourly / the frozen 50, reading `config/tracked_assets.json`
- [x] Cost guard in place, so it is already watching on the day the gate opens — AWS Budgets, not a CloudWatch billing alarm; see the reasoning in `modules/observability/main.tf`
- [x] Producer proved against the live Binance WebSocket **locally** — 45 symbols, 90 streams, one connection, zero drops — with no AWS resource created
- [x] `terraform plan` clean, and `apply` proving the ungated scaffold costs $0/month — **19 added, 2 changed, 0 destroyed**
- [ ] ~~End-to-end verified: a Binance tick lands as an object in S3~~ — **deferred**, see Decision 3; first task on wake-up
- [ ] ~~EventBridge rules re-enabled~~ — **deferred**. `eventbridge_rule_enabled` and
      `streaming_enabled` both stay `false`; the project does not wake up in this phase

**What actually happened**

**1. The producer was proved against live Binance without a single AWS resource
existing.** `DRY_RUN=1 python producer/producer.py` reads
`config/tracked_assets.json`, opens one connection carrying all 90 streams and
counts what arrives. A 155-second sample on 2026-09-01:

| | |
|---|---:|
| Symbols / streams / connections | 45 / 90 / **1** |
| Events received | 8,384 — **52.2/s** |
| Kinesis records produced | 817 — **5.1/s** |
| Events per record | **10.3** |
| Throughput | **12.6 KB/s** |
| Dropped / retried / reconnects | **0 / 0 / 0** |

**2. Phase 4's record rate was wrong by 14×, in the safe direction.**
`data_sources.md` §9 costed the tuned build at "70 rec/s **after batching**" — it
batched the *bytes* in its model but kept the unbatched *record count*, which is
inconsistent. Batching per symbol actually yields **5.1 records/s**. Against one
provisioned shard's 1,000 records/s that is **196× headroom**, not 14×, and the
PUT-payload-unit charge falls to ~$0.19/month, so the $12.62 estimate is now
almost entirely the $10.95 shard. The capacity-mode decision does not change —
it gets stronger.

**3. The event rate landed exactly where the `@aggTrade` measurement predicted.**
Phase 4 counted ~185 trade events/s across the 45 pairs and measured `@aggTrade`
at 3.86× fewer frames, which implies ~48/s. Measured: 52.2/s. That is the first
independent confirmation that the `@trade` → `@aggTrade` substitution behaves as
measured rather than as hoped.

**4. Two failure modes were designed for rather than discovered later.**
`put_records` returns **HTTP 200 with a `FailedRecordCount`** — individual
records can be throttled while the call "succeeds", so code that only catches
exceptions loses them silently, and silent loss in a market feed is
indistinguishable from a quiet market. It is retried explicitly. And the queue
is **bounded**: unbounded, a Kinesis outage becomes an OOM kill several minutes
later that reads as a crash instead of as the throughput problem it is. Overflow
is dropped and counted.

**5. A hang was found and fixed before it could ship.** `main()` waited on the
stop signal alone. `consume()` reconnects from any exception, so it "should
only" finish when asked — but if it ever did exit, the process would sit there
holding a healthy ECS task producing nothing, which is worse than crashing
because nothing alerts on it. It now waits on the stop signal **or** the
consumer dying, and exits non-zero so ECS records a failure.

**6. The one deliberate deviation from a standing project rule.** Phase 2.1 sends
build artifacts to `crypto-artifacts-<acct>/`. The producer ships as an ECR image
instead, because a Fargate task pulls an image and cannot run a zip from S3.
Shipping both would put one fact in two places — exactly what that rule exists to
prevent. The Glue scripts still obey it. Recorded here rather than left for a
reader to notice.

**7. The tracked-asset list left tfvars, and that mattered more than it looked.**
`tracked_asset_ids` is now derived in `main.tf` from
`config/tracked_assets.json`. `terraform.tfvars` is **gitignored**, so the old
copy was invisible to code review and free to differ on every machine, while the
Lambda, the producer and the Gold join all believed they tracked the same
universe. One owner per fact, the same rule Phase 2.1 applied to bucket names.

**8. Commenting the Kinesis code out was considered as the dormancy mechanism,
and rejected.** The proposal was to leave the stream and Firehose in the file as
comments and uncomment them on deployment day. The goal is right — the resource
must not exist — but as a mechanism it is strictly worse than `count`, on five
counts:

| | `count` gate | Commented out |
|---|---|---|
| Validated by `validate` / `fmt` / `plan`? | Yes, every run | **No.** It rots silently; a provider upgrade breaks it and you find out on the day you uncomment it |
| Can you prove it turns on correctly? | Yes — see below | **Impossible.** There is no way to plan what is not code |
| Is switching it on reviewable? | One boolean, in git | A diff that uncomments ~100 lines, which nobody reads properly |
| Turning it back off | `false`, and Terraform destroys both resources | Comment out **four resources across two files**, coordinated by hand; miss one and the shard keeps billing |
| Exercised in CI (Phase 12)? | Yes, the plan covers it | Invisible |

The last row of that table is the one that decides it: the Firehose, its IAM role
and its policy all reference the stream, so commenting the stream out forces a
coordinated multi-file edit every single time the switch is thrown. `count` does
that coordination itself.

**The proof, which commented code cannot produce.** `terraform plan
-var="streaming_enabled=true"` goes from **19 to 24 resources** — the stream, the
Firehose, its role, its policy and its log group — without creating anything. The
gated code is type-checked, its references resolved and its plan concrete, while
still costing nothing.

**9. Applied, and verified in AWS rather than in the plan.** `terraform apply`:
**19 added, 2 changed, 0 destroyed.** Read back from state afterwards:

| Invariant | Value |
|---|---|
| Kinesis / Firehose resources in state | **NONE** |
| ECS `desired_count` | **0** |
| Producer security group ingress rules | **0** |
| NAT Gateways | **none created** |
| EventBridge extractor rule | **DISABLED**, `rate(1 hour)` |
| Lambda `TOP_LIST_ID` | **50 ids** |
| Account budget | **$40/month**, watching |

The lake is now fully built and fully asleep. Monthly cost of everything this
phase added: **$0**.

**Prompt to run**

> Phase 5 of roadmap.md: build the streaming ingestion path. The two open
> decisions are settled and written into the phase — one PROVISIONED shard, and
> the producer on Fargate 24/7 in a public subnet with no NAT Gateway. Add the
> Kinesis stream, a Firehose delivery stream into the existing bronze bucket, and
> the Binance WebSocket producer, each with its own least-privilege IAM role scoped
> by ARN. Subscribe `@aggTrade` + `@kline_1m` on the 45 symbols with
> `has_stream: true` in `config/tracked_assets.json`, batching to ~5 KB records.
> Retune the CMC Lambda to hourly and the frozen 50, reading the same file.
> Add a CloudWatch billing alarm so it is watching before the gate ever opens.
> **Nothing is woken up.** Put every billable resource behind a `streaming_enabled`
> variable defaulting to false, applied with `count` — a Kinesis shard bills from
> creation, so "disabled" is not enough, it must not exist. The apply must create a
> complete streaming stack that costs $0/month. Prove the producer against the live
> Binance WebSocket locally instead; the end-to-end tick-to-S3 check waits for the
> wake-up at the end of the project.

---

## Phase 6 — Bronze layout, Silver adaptation, catalog cleanup ✅

**Goal:** absorb the layout change Firehose forces, and retire the crawler.

**Already settled in Phase 2.1:** which bucket each layer lives in, and the fact
that `top10/` is gone. What remained here was only the *internal* layout of the
bronze bucket underneath the `binance/` prefix, and everything the catalog had
to become once the crawler went away.

---

### The partitioning decision — and the premise that turned out to be wrong

This phase was written around a problem that does not exist. The scope said:

> Firehose writes `YYYY/MM/DD/HH/` prefixes, not Hive-style. […] If Firehose
> writes its native prefix, **the Silver job stops finding the data**.

**That is only true of the DEFAULT prefix.** Firehose's `timestamp` namespace
works in an ordinary custom prefix, with dynamic partitioning switched off and
no surcharge, and AWS's own documentation carries this exact form as an example:

```
myPrefix/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/
```

So there was never a trade-off between "Hive layout" and "free" — only between
"partition by symbol" and "free". Phase 5 had already written the free one.
**Verified against the AWS docs and pricing page on 2026-09-05**, and the
numbers are recorded in `modules/ingestion/streaming.tf` so the choice can be
re-checked rather than believed.

**Decided: option 2, the native prefix.** What option 1 would have bought is a
`symbol=` level in the path, at measured volume (47 GB/month, 45 symbols):

| Line item | Rate | At our volume |
|---|---|---:|
| Data processed through dynamic partitioning | $0.020 / GB | $0.94/mo |
| Objects delivered to S3 (dynamic partitioning charge) | $0.005 / 1,000 | $1.94/mo |
| S3 PUT on those same objects | $0.005 / 1,000 | $1.94/mo |
| JQ processing | $0.07 / JQ-hour | unit is ambiguous in AWS's own docs — $0 to $51/mo |

**~$4.80/month before JQ, on a $12.62/month ingestion path — +38%** — to buy a
path component that is *already a field in every payload* (`s`).

Three reasons beyond the money, any one of which is on its own decisive:

1. **It is a one-way door.** Dynamic partitioning can only be enabled when a
   Firehose stream is *created*, and once enabled **it can never be disabled**.
2. **It would multiply the object count by 45.** Each symbol gets its own
   buffer, so 288 objects/day of ~1 MB becomes 12,960/day of ~24 KB — precisely
   the small-file problem the 300 s buffer was chosen to avoid, reintroduced at
   45×, and the daily Silver job would open all of them to read the same bytes.
3. **Our records are aggregated.** The producer batches ~15–35 events into one
   newline-delimited Kinesis record, so dynamic partitioning would additionally
   need multi-record deaggregation — another mode to configure and another
   place data can be dropped silently.

**What the choice costs, stated rather than hidden.** `!{timestamp:...}`
evaluates to the **approximate arrival timestamp of the oldest record in the
object being written**, not to the event time. So Bronze's
`year=/month=/day=/hour=` is an **arrival-time** partition: an object under
`hour=14/` routinely holds events from 13:55, because that is when the buffer
opened. Anything reading that path as event time is wrong at every hour
boundary, silently.

That is why "the event timestamp must travel inside the payload" was
non-negotiable, and it is enforced in two places: the producer never strips
Binance's `E`/`T` and adds `_ingested_at`, and the Silver job derives
`event_time_utc` from the payload and re-partitions Silver on it.

Dynamic partitioning *could* have fixed the skew, via `partitionKeyFromQuery`
on the payload's own timestamp — the one thing it genuinely buys. Rejected
anyway: Silver re-partitions on event time regardless, so the fix would have
been paid for twice and used once.

---

### Silver: a second job, not a rewrite of the first

`data_sources.md` §10 had already settled that **Silver stays source-separated
and the join happens in Gold**, so the Binance stream gets its own job rather
than a set of shape branches inside the CoinMarketCap one. A Binance frame
shares not one field with a CMC `quotes/latest` document; merging them would
mean a CoinMarketCap schema change can break the stream.

`glue_jobs_silver_gold/silver/silver_binance_job.py` writes **two** datasets,
because the stream carries two grains and flattening them would mean either
nulls in two thirds of every row or a fabricated join key:

| Dataset | Grain | Dedup key |
|---|---|---|
| `silver/binance/trades/dt=…/hour=…/` | one row per `@aggTrade` | `(symbol, agg_trade_id)` |
| `silver/binance/klines/dt=…/hour=…/` | one row per 1-minute bar | `(symbol, open_time_utc)` |

Three details worth naming:

- **The wire schema is declared, not inferred.** The two event types share only
  four top-level fields, so an inferred schema depends on which rows Spark
  happens to sample — a quiet hour with no klines would produce a *different*
  schema from a busy one.
- **Decimals are cast from Binance's strings, never from inferred floats.**
  Prices span eight orders of magnitude here (BTC ~1e5, SHIB ~1e-5).
- **Kline dedup prefers a closed bar over an open one.** A 1-minute bar is
  re-sent every ~2 seconds while it is open, so the same bar arrives ~30 times,
  each more complete. That is the normal path, not an error path.

The CMC Silver job is **untouched** — its output schema, including its
`y/m/d/h` partition columns, is exactly what it was.

### Catalog: the crawler is gone, and Terraform owns the tables

Gold already used partition projection with hand-run DDL. Copying that pattern
for Silver would have made this phase a **regression in automation**: a
Terraform-managed crawler that built the table on every run would be replaced by
a human remembering to run a `.sql` file. The crawler was the wrong tool, but it
was automated. So the three Silver tables are `aws_glue_catalog_table`
resources, and harmonising Gold's three `.sql` files with them is in the backlog.

Deleted with the crawler: its IAM role, the inline least-privilege policy, and
the `AWSGlueServiceRole` attachment that granted `glue:*` on `"*"` and made that
scoping cosmetic — a caveat Phase 3 recorded honestly and Phase 6 closes.

### Step Functions

- **Four states gone** — `StartCrawler` → `Wait 180s` → `GetCrawler` → `Choice`
  — and with them ~3 minutes per run and a `Default` branch that sent any
  unexpected crawler state back to `Wait`, i.e. **looped forever on a failed
  crawl**.
- **`Catch` added to every task**, routing to one `NotifyFailure` state that
  publishes to SNS. The trick that lets a single shared state name the failed
  step is the `ResultPath` on each catcher: each writes into
  `$.failure.<ThatStateName>`, so the serialised object's only key *is* the
  step that died. `$$.State.Name` inside `NotifyFailure` would say
  "NotifyFailure", and a `Pass` state per task would add five states to save one
  line.
- **`NotifyFailure` is followed by a `Fail` state, deliberately**, so the
  execution still ends `FAILED` and the EventBridge rule keeps firing as a
  backstop — a `Catch` cannot see an `ABORTED` execution, a machine-level
  `TIMED_OUT`, or a failure of the SNS publish itself. The price is two emails
  on an ordinary failure. That is the right way round: a duplicate alert costs a
  delete, a missing one costs the incident.
- **`SilverBinanceJob` joined the chain**, ahead of Gold. No Gold job reads it
  yet; Phase 7's feature work does, and a Silver failure should stop the run
  rather than let Gold build on a layer that did not refresh.

### The two names that lied

Backlog item, approved for this phase on 2026-09-01, and done here because
`name` is ForceNew on both and both resources are DISABLED, so this is the cheap
moment:

| Was | Now | Why it lied |
|---|---|---|
| `fetch-top10-crypto-crypto` | `cmc-extractor-crypto` | never 10 assets (11, then 50); "crypto" twice |
| `schedule-fetch-top10-5-min-bronze-crypto` | `schedule-cmc-extractor-crypto` | not 10, not 5-minute (hourly since Phase 5), and "bronze" is already implied |

The cadence is deliberately **not** in the new name: `schedule_expression` is a
variable, and a name repeating a variable's value is a second copy that cannot
be kept in sync. **This is why Phase 6's plan is not 0-destroyed, and that is
expected, not drift.**

**DoD**
- [x] Firehose partitioning option chosen, with the cost trade-off documented
- [x] Silver job reads the new bronze layout; CMC output schema unchanged
- [x] Event timestamp present inside the payload, and read from there
- [x] Silver migrated to partition projection; Silver crawler deleted
- [x] Crawler polling states removed from the state machine
- [x] `Catch` → `NotifyFailure` added, alert names the failed state
- [ ] **Athena queries return the same results as before the migration** —
      cannot be closed here and is not pretended otherwise. The lake is empty
      (Phase 2.1 deleted it) and the pipeline is dormant, so there is no
      "before" to compare against. The check itself is written down in
      `sql/athena_verification_silver_phase6.sql` and runs at the wake-up.

**Applied 2026-09-06: 10 added, 4 changed, 10 destroyed**, and
`terraform plan -detailed-exitcode` returns 0 afterwards.

It was *written* with no credentials reachable in the working shell, so the
static checks carried the weight until Angel ran it: `fmt -check -recursive`,
`validate`, a reachability and dangling-transition check over the state machine
JSON rendered from the real `locals` block, and a compile of the new Glue job.
Every one of those held; the apply matched the predicted categories exactly.

Verified after the apply, in this order: the three Silver tables exist with
`projection.enabled = true`, `GetCrawler` returns `EntityNotFoundException`, the
deployed state machine definition contains `NotifyFailure` and
`SilverBinanceJob` and none of the three crawler states, and — the one that
matters most — **the project is still asleep**: all three EventBridge rules
`DISABLED`, `list-streams` empty, producer at `desired_count = 0`.

**One thing to expect at the wake-up.** The first scheduled run after
`streaming_enabled` is flipped can fail on `SilverBinanceJob` with a
"Path does not exist" — Firehose has not flushed its first 5-minute buffer yet,
so `bronze/binance/` has never been written. It is a one-off; re-run the
execution. The job deliberately does not swallow it: a `try/except` there would
also hide a genuine unreadable-Bronze failure on every day after the first.

**One-time step before the first apply — needed, and done.** The deleted
crawler had left its table in `crypto_silver_db` with the prefix `silver_`.
Terraform will not adopt an existing table, so it had to be dropped by hand
first or the apply would have failed with `AlreadyExistsException` — which the
`plan` does not catch, because the collision only exists at create time. It was
a schema with no data behind it (Phase 2.1 deleted the lake), so this cost
nothing. Kept here because a future rebuild from scratch will not hit it, and
someone re-reading this should know why the step existed:

```bash
aws glue get-tables --database-name crypto_silver_db --query 'TableList[].Name'
aws glue delete-table --database-name crypto_silver_db --name <orphan>
```

**Prompt to run**

> Phase 6 of roadmap.md: adapt Bronze/Silver to Firehose and clean up the catalog.
> First decide the Firehose partitioning approach (dynamic partitioning with
> custom Hive prefixes vs native prefix + adapted Silver job) and document the
> cost trade-off. Ensure the event timestamp is inside the payload. Migrate the
> Silver table to partition projection, delete the Silver crawler, and remove the
> StartCrawler/Wait/GetCrawler/Choice states from the state machine. Add a `Catch`
> to a `NotifyFailure` state that reports which step failed. Verify Athena returns
> identical results before and after.

---

## Phase 7 — Feature engineering ✅

**Goal:** compute the technical indicators the model will train on — and first,
give it something to compute them over.

**Applied:** *pending Angel's apply.* Plan is **16 added, 8 changed, 0
destroyed**, verified against the live account on 2026-09-06. The project stays
dormant: both EventBridge rules re-read from AWS after planning are still
`DISABLED` and `kinesis list-streams` is empty.

---

### The backfill, and three traps that were verified rather than assumed

`data_sources.md` §11 established that Binance publishes its entire 1-minute
history free at `data.binance.vision`. Building the job that fetches it turned
up three things the document did not know, each found by fetching real files:

**1. The archive changes its timestamp unit half-way through, and nothing says
so.** Files up to and including **2024-12 are milliseconds**; from **2025-01
they are microseconds**. Fetched either side of the boundary:

```
2024-11  1730419200000     (13 digits, ms)
2024-12  1733011200000     (13 digits, ms)
2025-01  1735689600000000  (16 digits, us)
2025-02  1738368000000000  (16 digits, us)
```

§11 says the archive and the live `@kline_1m` event are "the same twelve
fields". That is true of the fields and **not of their units**. Reading a
microsecond value as milliseconds does not error — it places January 2025 in the
year 56,000, which a partition filter then *hides* rather than reports. Bronze
keeps the file as published; the unit is detected **from the magnitude, not from
the month**, in the Silver job, so a re-published old file cannot break it.

**2. The checksum covers the ZIP, not the CSV.** So the digest is verified
*before* extraction, and what lands in Bronze is the extracted CSV — Spark
cannot read a member of a ZIP, and a Bronze object no reader can open is an
archive, not raw data. Verified: the published digest for
`BTCUSDT-1m-2018-01.zip` matches the locally computed one.

**3. `history_months` in the config is a measurement, not a boundary.** It was
counted on 2026-08-27 and the archive grows monthly, so the job walks from
`binance_history_from` to the current month and treats a **404 as "that month
does not exist"** rather than as an error. A delisting looks exactly like that
from here — `XMRUSDT` simply stops in 2024-02 — so the walk records the gap
instead of failing on it. A 503 is *not* collapsed into the same bucket: a bad
afternoon at the CDN must never masquerade as a hole in Binance's history.

**The archive gets its own top-level Bronze prefix, `binance_archive/`, and that
is a correctness constraint rather than tidiness.** The streaming Silver job
reads `binance/` **recursively as newline-delimited JSON**; a CSV placed
underneath it would be handed to a JSON parser, which does not fail loudly so
much as it yields a frame of nulls.

**Rehearsed for real, not just compiled.** The script runs unchanged outside
Glue, and it was run against the live archive and the real Bronze bucket on
2026-09-06: four asset-months written, checksums verified, both timestamp eras
handled, the manifest written to artifacts. Two things fell out that are worth
recording because they confirm the documents rather than the code:

- `BTCUSDT-1m-2018-01` came back with **exactly 44,515 rows** — the figure
  `data_sources.md` §11 quotes, against January's 44,640 minutes.
- Re-running wrote **0 and skipped 2**. A 4.4 GB load over the public internet
  *will* be interrupted, and the correct response to an interruption is to run
  it again, not to work out what it got through.
- The `RENDERUSDT` walk queued four asset-months and recorded **two as absent**:
  the `RNDRUSDT` alias publishes nothing in 2025 because the rename was in 2024.
  A gap correctly classified rather than an error.

### `source` became a partition key, and a column could not have done the job

Phase 6 wrote `source` on the klines table as a plain column and left "backfill"
for this phase. Carrying that out exposed something a column cannot express:
**Phase 7 is the first phase with two writers into one dataset**, and both key
their Spark partitions on `(dt, hour)`.

Spark offers two write modes and both are wrong across two writers. `append`
makes a re-run duplicate everything — and this job gets re-run. Dynamic
partition overwrite is idempotent, which is what a resumable load needs, but it
replaces a whole partition directory, so a backfilled month overlapping the
stream would **silently delete the streamed rows for those hours**.

Promoting `source` to the first partition key gives each writer its own subtree.
Both can then use the write mode that suits them — the stream appends because
bookmarks make it incremental, the backfill overwrites because it re-derives
whole months from immutable files — and neither can touch the other. It is still
one table and `source` is still a column to any query.

Done now rather than deferred because the table is **empty**: Phase 2.1 deleted
the lake, so this costs a schema edit and no migration. Same reasoning Phase 6
used for its two renames — do the structural change at the moment nothing is
behind it.

### The indicator maths is a SQL file, and that is why it is tested

The features are not `.withColumn()` chains. They are
[`glue_jobs_silver_gold/gold/indicators.sql`](./glue_jobs_silver_gold/gold/indicators.sql),
expanded by one shared module and executed by **Spark on Glue and DuckDB in the
unit test**. The maths therefore has one owner, like bucket names (Phase 2.1),
job names (Phase 3) and the asset list (Phase 5) — and, unlike any of those, it
can be verified on a laptop with no JVM and no AWS.

`tests/test_indicators.py` runs **13 tests in 0.6 s**, in three layers, because
any one alone is weak:

1. **Hand-computed literals** on series small enough to check on paper. This is
   the layer that catches a definition *both* implementations misunderstand —
   an independent implementation written by the same person on the same
   afternoon is not independent about the definition, only about the code.
2. **An independent Python implementation** of every window, compared row by
   row. Catches frame off-by-ones, null handling and gap semantics.
3. **Adversarial series** — a 30-minute halt, a flat stablecoin, a single-bar
   symbol — one per claim the SQL's header makes, so a claim that stops being
   true fails a test instead of ageing quietly into a lie.

**Nothing is recursive, stated as a limitation rather than hidden.** Wilder's
RSI, EMA and MACD define today's value in terms of yesterday's *output*, which
SQL windows cannot express and Spark can only fake with a row-by-row UDF over
133 million rows. So `rsi_14` is **Cutler's RSI** — a published variant using
simple moving averages, *not* an approximation of Wilder's — and the tests check
it against its own definition.

**Every frame is `RANGE`-on-time, never `ROWS`.** The series is gappy, and
`ROWS BETWEEN 59 PRECEDING` counts rows, so across a halt a "60-minute" average
silently becomes a 90-minute one. Counting time makes the window hold fewer
bars instead, and `bars_in_60m` reports that rather than hiding it.

**A flat series returns null, not the conventional midpoint.** RSI 50 and a
Bollinger z of 0 on a stablecoin pinned at 1.0000 are *fabricated observations* —
and the universe carries stablecoins precisely as a negative control
(`data_sources.md` §5). A model that signals on them is broken; it should not be
handed the inputs that let it.

### The label is cost-aware, and the rows are sampled for a statistical reason

Binary: does the forward log return over 60 minutes exceed **20 bps**? That is
a round-trip Binance taker fee before slippage. "The price went up" would mark a
great many moves that **lost money**, and a model that predicts them perfectly is
worthless. It also makes the positive class a minority, which is why Phase 8's
baseline metric is **PR-AUC and not accuracy** — on a class this imbalanced,
"always predict no" scores well and does nothing.

Rows are kept on a **60-minute epoch-anchored grid**. At a 60-minute horizon the
labels of two adjacent minutes share 59 minutes of outcome; they are not
independent observations, and scoring them as such inflates every validation
number. The stride makes consecutive retained rows have disjoint label windows.

This remains a technical demonstration. The threshold makes the target *mean*
something; it does not make the output actionable.

### The cadence question Phase 6 left open: the machine stays daily

A stream feeding a once-a-day batch sounds like a mismatch. It is not one here:

- Nothing downstream is latency-sensitive — the output is a **training set**, and
  a model retrained daily at most cannot use one rebuilt hourly.
- **The serving path does not read these tables.** Phase 10 computes features at
  request time from the last 1440 minutes, running the same `indicators.sql` in
  a different engine. Inference freshness is bounded by Firehose's five-minute
  buffer, not by this schedule. An hourly batch would not make one prediction
  fresher.
- It would cost ~24× for that, because Glue bills a one-minute minimum per run
  per worker and the chain is now six jobs.

The grain of the *data* is one minute and the grain of the *pipeline* is one
day, and nothing between them needs the difference closed.

**What makes a daily run over 133 million rows affordable** is that every window
is time-bounded and the longest spans 1440 minutes, so a day's features need
that day plus a bounded tail — `PROCESS_MODE=incremental` with a two-day
look-back and a warm-up window on top. The full 2017 rebuild is the same job
with `--PROCESS_MODE full`, run once, by hand. Without the warm-up the bug is
silent: indicators restart from nothing at every midnight and the model sees a
daily sawtooth that is an artefact of the scheduler.

### Gold's catalog moved into Terraform, and the migration found a live defect

Backlog item, assigned here because this is the phase that rewrites the Gold
jobs. The three hand-run `.sql` files are superseded by
`terraform/modules/catalog/gold_tables.tf`, and migrating them turned up drift
that was never going to announce itself:

- `gold_ohlc` pinned `asset_id` to an **enum of eleven ids** — the provisional
  list from before Phase 4 — one of which (BAT, `1697`) is no longer in the
  project at all. **40 of the 50 tracked assets would have been invisible to
  Athena**, not missing with an error.
- `gold_features_base` and `gold_ohlc` carried two different, unrelated
  projection start dates.

The enums are now generated from `config/tracked_assets.json`, which removes the
possibility rather than fixing this instance of it. The four `gold_ohlc_*` views
are **not** recreated: each was `SELECT * WHERE g = '<grain>'`, which the
partition key already expresses, and an Athena view stores a base64 blob of its
own plan — so a column added to the table leaves four views describing a shape
that no longer exists.

**DoD**
- [x] Backfill job written, and **rehearsed against the live archive and real S3**
- [x] Aliases stitched — the walk queues every pre-rename ticker and classifies
      an absent month as absent rather than as a failure
- [x] Checksums verified against the published `.CHECKSUM`, before extraction
- [x] Streaming and backfill form one continuous table with a `source` column —
      now a partition key, so both writers are idempotent
- [x] Missing minutes treated as missing: nothing is forward-filled, `RANGE`
      frames shrink across a gap, `minutes_since_prev` and `bars_in_60m` carry it
- [x] Indicators implemented and unit-verified — 13 tests, three layers, no Spark
- [x] Feature schema documented and versioned — [`feature_schema.md`](./feature_schema.md), `v1`
- [x] Job cadence chosen and justified against the streaming grain
- [ ] **The full 4.4 GB load has not run**, and neither has the Silver/Gold
      chain over it. It needs the apply first, and it is the one part of this
      phase that costs real money (a few dollars of FLEX Glue, ~$0.15/month of
      S3). Four asset-months are loaded as a rehearsal.
- [ ] **Backfill vs stream on the overlap window** — impossible today: the
      stream has never run, so there is no stream half to compare against. The
      query is written down in `sql/athena_verification_phase7.sql` §3 and runs
      at the wake-up. This is the same honesty Phase 6 applied to its own
      Athena check.
- [ ] **Features queryable in Athena with no null explosion at boundaries** —
      the check exists (`§5` of the same file) and needs data behind it.

**Prompt to run**

> Phase 7 of roadmap.md: implement feature engineering. FIRST backfill the free
> Binance kline archive from `data.binance.vision` into Bronze — 2017 onward,
> stitching the pre-rename aliases in `config/tracked_assets.json` — and resample
> the streamed data to the same 1-minute grain in Gold so the two form one
> continuous series, with a `source` column and an overlap-window validation.
> Then extend the existing Gold
> Glue jobs with RSI, moving averages and volume features. Verify the indicator
> maths against a known reference series rather than trusting the output. Define
> and freeze the feature schema that model training will consume, and pick the job
> cadence that matches the streaming grain. Watch for nulls at window boundaries.

---

## Phase 8 — Model training ✅

**Goal:** the ML core. First place with genuinely delicate IAM.

**Applied:** *pending Angel's apply.* Cumulative plan with Phase 7 is **21
added, 9 changed, 0 destroyed** — Phase 8's own share is 5 resources and one
lifecycle rule. Nothing here bills anything: an IAM role, an empty ECR
repository and an S3 lifecycle rule are all free to exist.

---

### The target, decided

Binary classification: **does the forward log return over 60 minutes exceed 20
bps?** The threshold is a round-trip Binance taker fee before slippage, so the
positive class means "moved enough to have covered its own costs" rather than
merely "moved up" — a distinction that decides whether the model is measuring
anything. Full reasoning in [`feature_schema.md`](./feature_schema.md).

**The baseline metric is PR-AUC, quoted against the positive rate.** Not
accuracy, and not ROC-AUC. On a minority class, a model that always predicts
"no signal" scores whatever the negative rate is — 90-something percent — while
being worth nothing; it is the easiest way to report a good number for a useless
model. ROC-AUC is better but still flatters imbalance, because the
false-positive rate has an enormous denominator. Precision-recall uses the
model's own output as the denominator, which is the quantity that matters.

An absolute PR-AUC is uninterpretable on its own, so every run also records
`positive_rate` and `lift_over_baseline`. **Phase 13's degradation threshold is
on the lift, not on the raw score** — the positive rate itself drifts with
volatility, so a falling PR-AUC can mean a calmer market rather than a worse
model.

### Decided: no VPC, and here is what that saved

Putting the training job in a VPC costs a NAT Gateway (~$32/month plus transfer)
or four interface endpoints (ecr.api, ecr.dkr, logs, sts, ~$7/month each — the
S3 gateway endpoint is the only free one). **Either is roughly the cost of the
entire awake project**, spent so a job that reads one S3 prefix and writes
another can avoid a public endpoint.

What it would buy: nothing this workload needs. No private data source, no
on-premises system, no compliance boundary. The job's only calls are to S3, ECR
and CloudWatch — AWS services reached over AWS's network with SigV4 either way.
Data does not traverse the public internet in the sense people mean when they
ask for a VPC; it traverses AWS's backbone with or without one.

Where a VPC does have a real argument is **Phase 10, serving** — a private
endpoint only the VPC can reach is a security posture rather than a ritual. The
project has also already built a VPC, in Phase 5, and also deliberately without
a NAT Gateway. The pattern is consistent: pay for network isolation where it
protects something.

### The lesson from Phase 5, applied rather than repeated

Phase 5 created an ECR repository **and** a task definition pulling `:latest`
from it, then never built the image — which is still the one precondition
standing between the wake-up flags and a working wake-up.

Phase 8 therefore trains on **AWS's managed XGBoost container**, pinned exactly
(`683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.7-1`) like
every provider version in this repository. The ECR repository asked for by this
phase's scope **is** created — but **nothing references it**, and that is the
whole reason it is safe. An empty repository is free and harmless; an empty
repository that something points at is a time bomb. Phase 12 builds and pushes
in the same pipeline run, which is the only arrangement where an image and the
thing that needs it cannot drift apart.

**The tagging scheme, decided now so Phase 12 only implements it:** the
repository is `IMMUTABLE`, and tags are `<semver>-<git short sha>` — e.g.
`1.4.2-a3f91c0`. `latest` is never used. A mutable tag means the image behind
`v1.4.2` can be replaced, so a model's recorded provenance stops being a fact.

### The split is purged, and that is the part most likely to be wrong

A random split of a price series puts minute *t+1* in training and minute *t* in
validation; the model "predicts" what it has already seen and validation looks
excellent. So the split is chronological — and **a chronological split is still
not enough**, because the label looks *forward*. A row at the last minute of
training is labelled by the following hour, which is the first hour of
validation: the leak arrives through the labels rather than through the
features.

The fix is an **embargo** — delete a band at least as wide as the label horizon
either side of each boundary. Those rows are dropped, not moved, because they
are the only ones whose outcome spans the cut. At a 60-minute horizon and a
60-minute stride this costs about ninety rows across 45 assets and two
boundaries. That is what correctness costs here.

**Verified, not asserted.** `ml/training/splitting.py` holds the split and the
metric — the two things in a training pipeline that are wrong most often and
visible least often — with no ML dependencies at all, so
`tests/test_splitting.py` runs them in under a second with no GPU, container or
AWS account. **16 tests**, including a negative control that proves a zero
embargo *does* leak, and a test that an always-no model scores exactly the
positive rate. Total suite is now **29 tests**.

### Raw price levels are excluded from the features, deliberately

Not "every column except the label". Two exclusion lists, and the second is the
interesting one: **open/high/low/close, volume, market cap and the moving
averages are dropped**. BTCUSDT trades near $2,000 in 2017 and near $100,000 in
2025, so a raw price is a nearly perfect proxy for the **date**. A tree model
will happily split on it and learn "2021 was a good year" — which validates well
on any split sharing a regime and predicts nothing. Ratios, returns and z-scores
carry the same information without the clock, which is what the feature table
was built to provide.

The ordered feature list is written **beside the model artifact**, not only into
the metrics. Feature order is part of an XGBoost model's interface, and a
serving path that guesses it produces confident nonsense rather than an error.

### Terraform owns the durable half only

There is no `aws_sagemaker_training_job`, and there should not be. A training
job is an **execution**: it starts, produces an artifact, ends. "This job has
run" is not a state you converge on, and modelling it as one means an apply
either recreates it forever or never again. So Terraform owns the role, the
repository and the output locations; `ml/training/launch_training.py` owns the
run. The same boundary Phase 7 drew around the backfill.

The launcher uses **boto3 and not the SageMaker SDK** — about twenty more lines,
one less dependency whose version resolution has silently changed the chosen
image for people before, and an image URI that is pinned rather than
`retrieve()`d.

**DoD**
- [x] Execution role scoped by ARN **and by prefix** — `s3:ListBucket` is a
      bucket-level action, so the prefix had to be a condition or the grant
      quietly became "list the whole bucket". No `s3:DeleteObject` anywhere
- [x] ECR repository with an explicit image tagging scheme — immutable,
      `<semver>-<sha>`, referenced by nothing until Phase 12
- [x] Model artifact in S3, versioned, with a lifecycle policy — to Standard-IA
      at 90 days, **never expired**: Phase 9 registers versions that point at
      these objects and Phase 13 compares against champions that may be months
      old
- [x] The "no VPC" decision documented with its cost reasoning
- [x] Split, metric and class weighting unit-verified without Spark, SageMaker
      or AWS
- [ ] **Training job runs end-to-end** — deferred with the rest of the wake-up.
      It needs the Phase 7 apply, the full 4.4 GB load and the Gold chain over
      it. The command is one line and is recorded below
- [ ] **Baseline metric recorded** — the number Phase 13 measures against. It
      cannot exist before a run does, and inventing a placeholder would be worse
      than an empty box

**Running it, once the data is there**

```bash
cd terraform/envs/crypto && terraform output
python3 ml/training/launch_training.py \
  --role-arn         "$(terraform -chdir=terraform/envs/crypto output -raw sagemaker_execution_role_arn)" \
  --training-data-uri "$(terraform -chdir=terraform/envs/crypto output -raw training_data_uri)" \
  --artifacts-bucket crypto-artifacts-913524903233 \
  --wait
```

Cost of one run: an `ml.m5.xlarge` is ~$0.23/hour and the job is bounded at two
hours by `MaxRuntimeInSeconds`, so the ceiling is about **$0.46** and the
expected cost is well under that. Bounded deliberately — an unbounded training
job is an unbounded bill, in an account shared with other projects.

**Prompt to run**

> Phase 8 of roadmap.md: build model training on SageMaker. No VPC — document the
> cost reasoning for that decision. Create the ECR repository with explicit image
> versioning, the SageMaker execution role scoped by ARN with no wildcards, and
> store the model artifact in versioned S3. Record the baseline metric that Phase 13
> will use as its degradation reference.

---

## Phase 9 — Model registry ✅

**Goal:** version models, and make promotion a rule rather than a click.

**Applied:** *pending Angel's apply.* Cumulative plan **23 added, 9 changed, 0
destroyed**; Phase 9's own share is two resources, both free — a model package
group and an unattached IAM policy.

---

### What a registry adds that an S3 key does not

The training job already writes `model.tar.gz` to S3, so it is fair to ask what
this buys. Three things a path cannot:

- **It binds an artifact to the metrics it earned and the code that made it.**
  Phase 13 compares a challenger against a champion, and that needs the
  champion's numbers to still exist months later.
- **It has an approval state deployment can gate on**, so "which model is in
  production" is a fact the system holds rather than one a person remembers.
- **It carries an `InferenceSpecification`**, so Phase 10 deploys a registry
  *version* rather than an S3 URI plus a hand-copied image name.

### "Scripted, not clicked" means the *criteria* are code

A script that calls `UpdateModelPackage` is not what that phrase means —
clicking Approve and running a script that approves unconditionally are the same
decision made by the same person, one of them just faster.

So the rule lives in `ml/registry/promotion_policy.py`: **no boto3, no AWS, a
pure function**, with 13 tests that run in milliseconds. `promote_model.py`
talks to SageMaker and contains no judgement at all.

**The rule, and why each clause is there:**

| Gate | Value | Why it exists |
|---|---|---|
| Beat the champion by a margin | **+5% relative lift** | Two models trained on overlapping windows differ by noise in the third decimal. Promoting on *any* improvement makes noise the champion the next candidate must beat — the registry then random-walks upward while every step looks like progress |
| Absolute lift floor | **1.10** | A model that barely beats flagging every row should not ship, whatever it beats the incumbent by |
| Minimum validation rows | **5,000** | A validation set this small cannot distinguish a good model from a lucky one |
| Same `label_version` **and** `feature_block_version` | exact match | A model trained on a 240-minute horizon shows a bigger lift than one trained on 60 minutes *for reasons that have nothing to do with the model*. The comparison is only meaningful within one target and one feature set — which is why both versions travel on every feature row and into the registry |
| p95 latency | **≤ 500 ms**, off by default | Phase 10 measures it; Phase 13 turns the gate on. **Not asserted rather than assumed to pass** — a gate that silently never fires is worse than no gate |

**Every failing reason is reported, not just the first.** A candidate rejected
for three reasons and one rejected for one are different situations, and the
person reading the log is deciding what to change.

### Two smaller decisions worth naming

**Registration is not approval.** Every version lands as
`PendingManualApproval`, and `promote_model.py` is the only thing that moves it.
A rejected candidate is marked **`Rejected`**, not left pending — a queue of
Pending versions nobody looked at is indistinguishable from a queue the rule has
not run on yet.

**Promote before demote.** If the process dies between the two calls there are
briefly *two* production markers, which a human can see and fix. The other order
leaves a window with **none**, and "nothing is in production" is the state a
deploy reads as "deploy nothing".

**Staging vs production is `CustomerMetadataProperties.stage`**, not the
approval status. `ModelApprovalStatus` has three values and they answer "is this
allowed to ship"; the stage answers "what is it doing now". Overloading one
field for both makes an archived former champion indistinguishable from a
rejected candidate.

### The IAM policy is written and attached to nothing

Promotion runs by hand today and from Phase 12's GitHub Actions later. Creating
the **role** now would mean guessing Phase 12's trust policy — OIDC provider,
repository, branch conditions — months before it is written, and a role with a
wrong trust policy is worse than no role. The **policy** is not a guess: it is
exactly the calls the two scripts make, so it is written and reviewed now and
attached in one line when the role exists. An unattached policy grants nothing.

**DoD**
- [x] Model package group defined in Terraform
- [x] Promotion is scripted — and, more to the point, the criteria are code with
      tests rather than a rule someone applies
- [x] A clear staging/production marker, separate from the approval status
- [ ] **At least two model versions registered** — needs two training runs,
      which need data. Deferred with the rest of the wake-up; the registration
      and promotion paths are written and their decision logic is verified

**Prompt to run**

> Phase 9 of roadmap.md: add the SageMaker model package group and the
> staging/production promotion mechanism. Register at least two model versions to
> prove versioning works, and make promotion scripted rather than manual.

---

## Phase 10 — Serving / inference ✅

**Goal:** turn a symbol into a scored signal, without an always-on bill.

**Applied:** *pending Angel's apply.* Phase 10 adds **zero resources to the
current plan** — everything is behind `serving_enabled = false`. Verified not to
be vapour: planning with the flag forced true renders **30 added, 9 changed, 0
destroyed**, so the gated path is real code that Terraform can build rather than
configuration nobody has ever evaluated.

---

### The gate here protects the apply, not the bill

Worth stating because in `tfvars` it looks identical to `streaming_enabled`, and
it is a different kind of switch. `streaming_enabled` guards a **recurring
bill** — a Kinesis shard costs $10.95/month from creation. This one guards the
**apply**: an `aws_sagemaker_model` requires a real model artifact, so `true`
before a training run has produced one fails the plan rather than creating
something expensive. Serverless inference itself is **$0 at rest**.

**Two preconditions are written down rather than left to be discovered**, which
is the lesson from Phase 5's unbuilt producer image:

1. a promoted model package ARN, from `ml/registry/promote_model.py`
2. the DuckDB Lambda layer built — `serving/inference/build_layer.sh`

### The VPC question the roadmap parked here, answered

Phase 8 said the argument for a VPC is genuinely stronger for serving than for
training. Having got here the answer is still no, and the first reason is a fact
rather than a preference: **SageMaker Serverless Inference does not support
`VpcConfig` at all.** So the choice is not "serverless, with or without a VPC":

| | Cost | |
|---|---|---|
| Serverless, no VPC | **$0 at rest**, per-request | 1–3 s cold start |
| Provisioned in a VPC | ~$50/month always-on, **plus** a NAT Gateway or four interface endpoints | no cold start |

The second is roughly **triple the entire awake project's cost, permanently**,
to serve a demonstration endpoint.

And it is worth being precise about what it would buy, because "private
endpoint" sounds like more than it is here. **A SageMaker endpoint is not a
public URL.** It is an AWS API reached through `InvokeEndpoint`, authenticated
with SigV4 and authorised by IAM — there is no anonymous access to remove. A VPC
endpoint changes the *network path*: it keeps traffic off the public internet
and lets a security group and an endpoint policy constrain who can reach it,
which is a real control against a compromised-credential exfiltration path, and
not the "otherwise anyone could call it" the phrase usually implies.

For one caller in an account with a $40 budget, that is not worth triple the
running cost. If this ever served real signals to real money the calculation
changes, and the change is a provisioned endpoint config with a `VpcConfig`
block — which is why the decision is recorded rather than left as an absence.

### Inference recomputes features; it does not read the Gold table

This is the claim Phase 7's daily-cadence argument rests on, so it had to be
built rather than asserted. The Lambda pulls the last ~50 hours of 1-minute bars
from Silver, runs **`indicators.sql` — the same file, through the same expander
— on DuckDB**, and scores the newest row.

**That is also the answer to training/serving skew.** The classic way a model
degrades unnoticed is that served features differ subtly from trained ones: a
different window convention, a different null policy. It is subtle by
definition — if it were obvious the model would fail loudly instead of quietly
getting worse. Here there is no synchronisation to maintain, because there is
one file. Phase 7 wrote the maths as SQL for the testing argument; this is the
second thing that buys.

The residual risk is *engine* semantics rather than definition drift, and it is
bounded two ways: `tests/test_indicators.py` checks the DuckDB side against an
independent implementation, and **the DuckDB version in the Lambda layer is
pinned to the version the tests run on** (1.2.2). Serving on a different version
than the tested one is training/serving skew with extra steps.

**A missing feature is an error, never a zero.** XGBoost accepts a row of NaNs
and returns a confident number, so a symbol whose recent history is too thin
raises `InsufficientHistory` and returns **422** — the service is fine, this
symbol cannot be scored, and a retry will not help. Keeping that distinct from a
500 is what will keep Phase 11's alarms meaningful. A flat stablecoin lands here
too, by design: its RSI and Bollinger position are null (`feature_schema.md`),
which is correct for a table and unusable for a scoring request.

`serving/inference/feature_request.py` has **10 tests** that build real Parquet
with DuckDB rather than mocking the reader — which is how the test suite covers
a detail a mock would have hidden: `source` is a *partition key* in Silver, so
it is in the S3 path and never in the file. Including a symbol allow-list test,
because DuckDB cannot take a prepared parameter inside `CREATE VIEW` and the
symbol arrives in a request payload.

### Latency is measured by a script, because a gate needs a number

`serving/inference/measure_latency.py` reports **cold and warm separately** — a
serverless endpoint's first request after idle pays 1–3 s of container start,
and averaging that into a p95 produces a number describing neither state. The
gate is on the warm p95; the cold number is printed beside it because a system
that idles between signals experiences it too. It also reports the **per-stage**
p95 the handler returns, since a regression in S3, in the feature query and in
the model have completely different fixes.

**DoD**
- [x] Endpoint fully defined in Terraform — model → endpoint config → endpoint,
      deployed from a **registry version** rather than an S3 URI plus a
      hand-copied image name
- [x] Serverless, with the always-on alternative costed and rejected in writing
- [x] The serving path implemented and unit-tested without AWS
- [ ] **Endpoint responds to an inference request** — needs a trained,
      registered, promoted model. Deferred with the rest of the wake-up
- [ ] **Latency measured and recorded** — the tool exists and the promotion gate
      that consumes it exists and is switched off until there is a number.
      Deliberately *not asserted* rather than assumed to pass

**Prompt to run**

> Phase 10 of roadmap.md: deploy the inference endpoint (model → endpoint config →
> endpoint), preferring serverless inference to avoid always-on cost. Measure and
> record baseline latency, since Phase 13's model CI/CD will gate on it.

---

## Phase 11 — Monitoring & alerting ✅

**Goal:** alerting as code, and fix what the Phase 0 review found.

**Applied:** *pending Angel's apply.* Cumulative plan **33 added, 10 changed,
3 destroyed**. The three destroys are the old SNS topic, its policy and its
email subscription — expected, and the reason is below.

---

### The policy defect was worse than it was written down as

Phase 3 recorded it as "CloudWatch alarms will publish as
`cloudwatch.amazonaws.com` and **silently fail**". True, and the consequence is
sharper than it reads: **no alarm added in this phase could have worked.** An
SNS publish denied by a topic policy does not raise anywhere the caller can see.
The alarm goes to `ALARM`, reports that it notified, and nobody is notified. It
is not an error — it is a silence, and a silence in the alerting path is
indistinguishable from "nothing is wrong".

Phase 5 had already been forced to route around it: the budget's notifications
go by email *directly* rather than through SNS.

**And the fix adds something the original finding did not ask for.**
`cloudwatch.amazonaws.com` is not *this account's* CloudWatch — it is the
CloudWatch service, everywhere. Allowing it to publish with no condition lets an
alarm in **any AWS account** publish to this topic; anyone who learns the ARN can
page this project's owner at will. Every statement now carries an
`aws:SourceAccount` condition. That is the confused-deputy problem, and it would
have been introduced by the very change that fixed the first defect.

### Two topics, and the destroys they cost

`-ops-alerts` (email) and `-model-signals` (Slack). "The nightly pipeline
failed" and "BTC crossed a threshold" are read by different people at different
urgencies, and one arrives far more often — mixed into one inbox, the
operational alert is the one that gets filtered.

**An SNS topic name is ForceNew, so this destroys the existing topic and its
CONFIRMED email subscription. After the apply there is a confirmation email to
click.** Stated plainly because it is a manual step, and the moment to pay it is
now: the project is dormant and nothing is publishing, so no alert can be lost
in the window. Same reasoning Phase 6 used for its two renames.

**The signals topic deliberately has no email fallback.** A fallback that
duplicates every signal into the inbox recreates exactly the problem the split
solves — and invisibly, because the Slack path would look healthy while messages
kept arriving somewhere.

### Slack, and why it needs a Lambda

SNS can POST to an HTTPS endpoint and a Slack webhook is one, so the direct
subscription looks tempting. It does not work: SNS sends its own JSON envelope,
Slack expects `text` or `blocks`, Slack answers 400, SNS retries for an hour and
gives up, and **nothing says the alert was lost**. Something has to translate.

The webhook lives in **Secrets Manager**, not in an environment variable: it is
a bearer credential — anyone holding it can post to the channel as this app — and
a Lambda env var is readable by anyone with `lambda:GetFunction`, a much wider
set of principals. Terraform owns the secret *container* and writes a
placeholder; a human sets the value, exactly as with the CoinMarketCap key.
`ignore_changes` on the version is what stops the next apply from silently
restoring `REPLACE_ME`.

**`slack_enabled` is a third kind of gate**, and the three are worth
distinguishing since they look identical in tfvars:

| Flag | Guards |
|---|---|
| `streaming_enabled` | a **recurring bill** — a Kinesis shard costs from creation |
| `serving_enabled` | an **apply that would fail** — `aws_sagemaker_model` needs a real artifact |
| `slack_enabled` | a **credential that does not exist yet** |

**The notifier's own failures go to ops, by email.** Routing "Slack delivery is
broken" through Slack is the one alert that cannot work.

### The alarms, and the setting that decides whether they work

Three exist while the project is dormant; the rest appear with the gate they
belong to, so the alarm count tracks what is actually running. That is also a
cost decision — the first 10 alarms per account are free and each one after is
$0.10/month, in an account shared with other projects.

**Every alarm sets `treat_missing_data` explicitly, and the value differs by
what the metric means.** This is the setting that quietly decides whether an
alarm is real:

- **`notBreaching` for error counts.** No data means nothing failed. The default
  (`missing`) would leave these in `INSUFFICIENT_DATA` forever on an idle
  pipeline — which looks exactly like an alarm that is fine.
- **`breaching` for liveness.** The producer alarm is the one that matters here:
  a dead ECS service stops publishing `RunningTaskCount` altogether, so treating
  absence as healthy would make it blind to precisely the outage it exists for.
  **That is the defining failure of a streaming ingest** — nothing errors, the
  WebSocket simply stops being read, and the first sign is a gap in a table
  nobody queries for a week.

The endpoint latency alarm uses **the same 500 ms** as Phase 9's promotion gate,
on purpose: a model that would not be promoted today should not keep serving
unnoticed.

### SageMaker Model Monitor: evaluated, declined, and the useful half kept

**Declined.** Model Monitor needs a scheduled Processing job — roughly
**$7/month** at the smallest useful size, about a quarter of this project's
entire awake cost — to watch an endpoint with one caller. And what it detects is
**input drift**: has the feature distribution moved. Phase 13 builds something
strictly stronger for this project's purpose — whether the predictions were
actually **right**, measured against realised prices. Paying for a weaker proxy
alongside it would be paying twice to learn less.

**Data capture is turned on anyway**, and it is the part that pays. It is nearly
free (S3 puts, no compute) and writes every request and response to S3, which is
three things at once:

1. **Phase 13's first DoD** — "signals persisted with timestamp and prediction"
   — satisfied by the platform rather than by a table this project would
   otherwise write and maintain.
2. The ground-truth job's input: what was predicted, and when.
3. **The option on Model Monitor, kept open.** Enabling it later needs history,
   and history cannot be collected retroactively — which is exactly why this
   belongs in Phase 11 and not in Phase 13.

At 100%, not a sample: at this volume a sample saves nothing and would make the
feedback loop's denominator an estimate.

**DoD**
- [x] Two topics split by audience, each with the right subscribers
- [x] Topic policy permits every principal that actually needs to publish — and
      only from this account
- [x] Metric alarms added, gated so they cannot outlive what they watch
- [x] Signal channel decided and implemented: Slack for signals, email for ops
- [x] Model Monitor evaluated; declined, with the reasoning, and data capture
      enabled so the decision stays reversible
- [ ] **An alarm verified to reach its destination end-to-end** — needs
      something to alarm on. The pipeline is dormant and no alarm has ever
      fired. It is the first thing to check at the wake-up, alongside the Athena
      queries Phases 6 and 7 left written down

**Two manual steps after the apply**, both consequences of decisions above
rather than oversights:

1. **Confirm the new ops-alerts email subscription** — AWS cannot confirm one on
   anyone's behalf, and the old topic's confirmation does not transfer.
2. **Paste the Slack webhook** into
   `near-real-time-crypto-slack-webhook-crypto` in Secrets Manager, then set
   `slack_enabled = true`. Until then the signals topic exists with no
   subscriber, which is the correct state for a topic nothing publishes to yet.

**Prompt to run**

> Phase 11 of roadmap.md: rework alerting. Split the SNS topic into `-ops-alerts`
> and `-model-signals`, and fix the topic policy so CloudWatch alarms can actually
> publish — right now only `events.amazonaws.com` is permitted, so alarms would
> fail silently. Add the metric alarms, decide between Slack webhook and email for
> signals, and evaluate SageMaker Model Monitor for drift. Verify an alarm reaches
> its destination end to end.

---

## Phase 12 — Containerization & orchestration

**Personal goal:** reach the same "from memory" fluency here as with
Terraform/AWS. Understand it deeply — do not delegate this phase to AI.

**Scope**

- **Docker** — package training/inference code as an image instead of relying on
  SageMaker's managed environment. Image layers, multi-stage builds, image size
  and its effect on cold start.
- **ECS/Fargate** — the serverless way to run those containers. Understand the
  real differences from SageMaker endpoints: full environment control vs managed
  simplicity, cost, scaling, and when each one wins.
- **Kubernetes** — understand why it exists next to ECS/Fargate (cross-cloud
  portability, ecosystem, granular orchestration control) and when that added
  complexity is actually justified.
- **Write down the reasoning** for choosing one over the other, e.g. Fargate for
  inference plus GitHub Actions for image CI/CD, with no Kubernetes unless the
  project grows into multiple coordinated services.
- **GitHub Actions** — build the image, push to ECR, run model validations
  (wired to Phase 13), deploy to Fargate or update the endpoint.

Note: if Phase 5 lands the producer on Fargate, part of this learning happens
earlier — which is a good reason to lean that way. It did.

**⚠️ INHERITED FROM PHASE 5 — an unbuilt image, and it blocks the wake-up.**

Phase 5 created the ECR repository `crypto-binance-producer-crypto` and a task
definition that pulls `:latest` from it. **That image has never been built and the
repository is empty.** So the wake-up is not actually one variable today: setting
`streaming_enabled = true` would start an ECS task that fails with
`CannotPullContainerError`.

This was a deliberate deferral, not an oversight — building and publishing images
is what this phase is *for*, and its GitHub Actions pipeline has to build that
image anyway. But it is recorded here rather than left implicit, because the cost
of an implicit precondition is discovering it on wake-up day.

Worth naming honestly: `producer/Dockerfile` has **never been executed**. That is
the same category of risk as the commented-out Terraform rejected in Phase 5 —
code nothing validates, which rots quietly and fails on the day someone is in a
hurry. The first build is therefore a verification, not a formality.

**DoD**
- [ ] Multi-stage Dockerfile; image size measured and deliberately reduced
- [ ] **The Phase 5 producer image built and pushed to ECR**, closing the wake-up
      precondition above — and `producer/Dockerfile` proved to build and run at all
- [ ] Container runs on Fargate, defined in Terraform
- [ ] GitHub Actions pipeline: build → push to ECR → validate → deploy
- [ ] Written comparison of SageMaker vs Fargate vs Kubernetes for **this** project
- [ ] Able to explain every piece without notes — the actual bar for this phase

**Prompt to run**

> Phase 12 of roadmap.md: containerization and CI/CD. **Explain before generating**
> — the point of this phase is that I understand it, not that it works. Walk me
> through image layers and multi-stage builds, then the real trade-offs between
> SageMaker endpoints, ECS/Fargate and Kubernetes for this specific project, before
> writing any Dockerfile or workflow. Then build the multi-stage Dockerfile, the
> Fargate service in Terraform, and the GitHub Actions pipeline (build → ECR →
> validate → deploy). Ask me to justify choices back to you.

---

## Phase 13 — Model feedback loop

**Main goal of the project.** The system should not only predict, but evaluate its
own predictions against market reality and retrain automatically when performance
degrades — all orchestrated as code, with no manual step. This is the phase that
separates a Data Engineer from an ML Engineer, and the one to defend in interviews.

**Scope**

- **Automated ground truth** — every buy/exit signal is recorded with a timestamp;
  a scheduled job (EventBridge + Lambda, or Step Functions) returns X hours/days
  later, compares the prediction against the real price and writes a correct/incorrect
  label with no manual work.
- **Degradation-triggered retraining** — a rolling performance metric (e.g. accuracy
  over the last N predictions) with a threshold; falling below it fires a training
  job whose output competes against production (challenger vs champion) before
  being promoted. Wires into Phase 9.
- **Real model CI/CD** — every candidate model runs automated validations
  (does the metric improve? does endpoint latency stay within budget?) before
  promotion.

**Architecture note:** do not grow the existing state machine into this. Split into
two — `data-pipeline-sfn` and `ml-pipeline-sfn`. The feedback loop adds enough
branching that one machine becomes unreadable.

**DoD**
- [ ] Signals persisted with timestamp and prediction
- [ ] Ground-truth job labels predictions automatically, verified over a real window
- [ ] Rolling metric computed and queryable
- [ ] Threshold breach demonstrably fires a retraining run
- [ ] Challenger vs champion comparison implemented; a worse model is rejected
- [ ] Promotion gated on metric improvement **and** latency budget
- [ ] Orchestration split into two state machines
- [ ] Full loop demonstrated end to end without manual intervention

**Prompt to run**

> Phase 13 of roadmap.md: build the model feedback loop — the main goal of this
> project. Persist every signal with its timestamp and prediction; add the scheduled
> ground-truth job that returns later, compares against real prices and labels
> automatically. Compute a rolling performance metric with a threshold that fires
> retraining, and implement challenger-vs-champion so a worse model is rejected.
> Gate promotion on both metric improvement and endpoint latency. Split
> orchestration into `data-pipeline-sfn` and `ml-pipeline-sfn` rather than growing
> the existing machine. Prove the loop runs end to end with no manual step.

---

## Backlog — carried items

Small things found during the Phase 0/1 review that do not belong to any single
phase. Each is tagged with where it gets resolved.

| Item | Resolve in | Notes |
|---|---|---|
| Rename the 3 auto-generated event `target_id`s | Phase 3 ✅ | Now `cmc-extractor-lambda`, `daily-gold-pipeline`, `sfn-failure-to-sns`. `target_id` is ForceNew, so each was a delete+create of one pointer |
| Rename the Glue inline policy `terraform-2025...` | Phase 3 ✅ | Now `silver-job-s3-access` |
| `iam_sfn.tf` grants Glue on `Resource = ["*"]` | Phase 3 ✅ | Scoped to the 4 job ARNs + the 1 crawler ARN. A redundant `Logs` statement (a strict subset of the delivery statement) was deleted with it |
| Unused `top10_list_symbol` variable | Phase 3 ✅ | Deleted, along with 5 more dead declarations found the same way: `gold_job_name`, `glue_version`, `glue_worker_type`, `glue_number_of_workers`, `secrets_manager_name` |
| `backend.tf` / `tfstate.tf` must move to `envs/crypto/` | Phase 3 ✅ | Moved. `init` reused the same bucket and key and offered no migration, exactly as the Phase 2 `crypto/` key prefix was chosen to allow |
| `terraform.tfvars` exists only on one machine | Phase 3 → **still open** | Moved to `envs/crypto/` with the rest of the root module, but that changes where it lives, not how durable it is. Still gitignored, still one copy. Decide: SSM Parameter Store, or accept a documented manual backup |
| `terraform fmt` across the whole codebase | Phase 3 ✅ | `fmt -check -recursive` passes |
| `default_tags` on the provider | Phase 3 ✅ | `Project` / `Environment` / `ManagedBy` / `Repository`. 39 tags-only in-place updates, nothing replaced |
| No `outputs.tf` anywhere | Phase 3 ✅ | Added at env level, plus one per module |
| **Drop the `top10/` prefix** | Phase 2.1 ✅ | The name already lies (11 assets today, 50 later). Free there: the data is deleted, so there is nothing to migrate — only DDL, Glue arguments and IAM ARNs to rewrite. The `top10_list_id` / `top10_list_symbol` variable names follow in Phase 3 |
| **Silver and Gold share one bucket** | Phase 2.1 ✅ | Forces lifecycle rules and IAM to be built on prefix filters instead of bucket ARNs |
| **Artifacts bucket is named `artifacts-crypto-data-crypto`** | Phase 2.1 ✅ | Names are immutable, so the fix is a new bucket under the `<env>-<purpose>-<account>` convention |
| Prefix-filtered lifecycle rules break silently on a rename | Phase 2.1 ✅ | `top10/silver/` and `top10/gold/` filters would stop matching with no error |
| Glue crawler S3 target is immutable under `CRAWL_NEW_FOLDERS_ONLY` | Phase 2.1 ✅ → Phase 6 ✅ | Any future target change needed `-replace`, not an update. Moot now: Phase 6 deleted the crawler |
| **Delete the current lake data — deliberate clean slate** | Phase 2.1 ✅ | Incomplete series, provisional 11-asset list, polling-era design. Angel's call: start from zero rather than migrate |
| Unused `gold_spark_ui_prefix` variable | Phase 2.1 ✅ | Deleted there; its orphaned comment was swept in Phase 3 ✅ |
| Curate the final 50-asset list | Phase 4 ✅ | Frozen in `config/tracked_assets.json`: 50 ids across 10 behavioural cohorts, 45 with a Binance USDT pair, 5 CMC-only. BAT (`1697`) dropped from the provisional 11 |
| Wire `tracked_asset_ids` to `config/tracked_assets.json` | Phase 5 | Phase 4 wrote the file but changed no Terraform. tfvars still holds the literal 11 ids; Terraform should read the list with `jsondecode(file(...))` so the asset list has one owner, same rule as bucket and job names |
| Kinesis `ON_DEMAND` vs 1 provisioned shard | Phase 5 | Measured load is 17.4 KB/s and ~70 rec/s vs a shard's 1 MB/s / 1,000 rec/s. On-demand costs $29.20/mo in stream-hours alone before a byte is written; a shard is $10.95/mo flat, and its 25 KB PUT-unit billing also makes `@bookTicker` affordable later. See `data_sources.md` §9 |
| Use `@aggTrade`, not `@trade`; keep `@bookTicker` out of the baseline | Phase 5 | `@aggTrade` is 3.86× fewer frames with no loss at a 1-minute grain. `@bookTicker` was recommended before being measured and is 7.7× BTC's `@aggTrade` rate — measuring it reversed the call. Naive build $217/mo, tuned $12.62/mo |
| Batch producer writes to ~5 KB records | Phase 5 | Kinesis on-demand rounds every record up to 1 KB and the frames are 146–360 bytes, so one-record-per-event bills ~4× the bytes actually sent |
| **Producer hosting: Fargate 24/7 vs time-boxed vs Lambda polling** | Phase 5 | ⚠️ Open decision, Angel's call. First recurring cost in the project — not to be defaulted into |
| **The producer image has never been built; ECR is empty** | Phase 12 | Phase 5's task definition pulls `:latest` from `crypto-binance-producer-crypto` and nothing has ever been pushed there, so `streaming_enabled = true` would fail with `CannotPullContainerError`. Deferred deliberately — Phase 12's GitHub Actions pipeline builds that image anyway — but it is a **wake-up precondition**, not a nice-to-have. `producer/Dockerfile` has also never been executed, which is the same unvalidated-code risk Phase 5 rejected elsewhere |
| **Two deployed names now lie, and Phase 5 made it worse** | Phase 6 ✅ | The EventBridge rule is `schedule-fetch-top10-5-min-bronze-crypto` and the Lambda is `fetch-top10-crypto-crypto`. Neither was ever accurate — the list was 11, not 10 — and Phase 5 made both wrong twice over: 50 assets, hourly. `name` is ForceNew on both, so fixing them is a destroy+create. Deliberately NOT done in Phase 5, to keep its plan at **0 destroyed**; Phase 6 already touches this surface and both resources are DISABLED, so it is the cheap moment. The same reasoning Phase 3 used to rename the EventBridge `target_id`. Angel approved the rename for Phase 6, so that phase's plan is NOT 0-destroyed and that is expected, not drift. **Done:** now `cmc-extractor-crypto` and `schedule-cmc-extractor-crypto`. The cadence is deliberately absent from the new name — `schedule_expression` is a variable, and a name repeating a variable's value is a second copy that cannot be kept in sync |
| **Backfill the Binance kline archive from 2017** | Phase 7 ✅ | Free at `data.binance.vision`, no key: 3,135 asset-months, ~133M 1-minute candles, ~4.4 GB, $0, and it bypasses Kinesis. Reaches 2017-07 (Binance's own start), not 13 years. Use klines, never aggTrades — one month of BTCUSDT aggTrades is 362 MB against 2.1 MB for klines |
| Resample the stream to 1-minute bars in Gold to meet the backfill | Phase 7 ✅ | The archive and the live `@kline_1m` event are the same twelve fields from the same exchange, so the stitch is exact. Carry `source ∈ {backfill, stream}` and validate on the overlap |
| Stitch pre-rename tickers when backfilling | Phase 7 ✅ | `RNDRUSDT` holds 33 months RENDER does not; `MATICUSDT` holds 66 months POL does not. `binance_symbol_aliases` in `config/tracked_assets.json` exists for this |
| Layer the feature schema by data availability | Phase 7 ✅ | 1-minute OHLCV features span 2017→now; tick-derived features start at Phase 5. One flat schema would be mostly null where it matters |
| Optional: BTC-quoted pairs for pre-2019 depth | Phase 7 | `ZECBTC`, `LINKBTC`, `XMRBTC` reach 16 months further than their USDT pairs. Needs a synthetic USD series (`price_btc × BTCUSDT`), so flag provenance and never mix it in silently |
| Firehose partitioning: dynamic vs native prefix | Phase 6 ✅ | **Native prefix.** The premise was wrong — `!{timestamp:...}` works in a plain prefix with no surcharge, so Phase 5 had already written the free Hive layout. Dynamic partitioning would have added ~$4.80/mo (+38%) for a `symbol=` level that is already a payload field, and it is a one-way door: enable-at-creation only, never disableable. Full numbers in `modules/ingestion/streaming.tf` |
| Gold's tables are hand-run DDL; Silver's are Terraform | Phase 7 ✅ | Phase 6 made the three Silver tables `aws_glue_catalog_table` resources rather than adding to `sql/athena_projections_*.sql`, because replacing an automated crawler with a manual DDL step would have been a regression in automation. That leaves two mechanisms in one catalog. Phase 7 already rewrites the Gold jobs, so it is the cheap moment to move their three `.sql` files across |
| Widen `streaming_projection_start_date` when the backfill lands | Phase 7 ✅ | Defaults to `2026-09-01`. A row written OUTSIDE a projected `dt` range is INVISIBLE to Athena rather than an error, so the 2017 backfill must widen this in the SAME change that writes those rows, or it will look like the backfill silently did nothing |
| The daily trigger may be the wrong grain over a stream | Phase 7 ✅ | Phase 6 left the state machine daily and added `SilverBinanceJob` to the chain. A stream feeding a once-a-day batch is a cadence question Phase 7 inherits, not a defect |
| Phase 6 was written without AWS credentials | Phase 6 ✅ | Static checks only while writing it — `fmt`, `validate`, an ASL reachability check, a Python compile. Angel applied it on 2026-09-06 and the plan matched the predicted categories: 10 added, 4 changed, 10 destroyed, clean plan afterwards. The orphan Silver table did exist and had to be dropped first |
| SNS topic policy blocks `cloudwatch.amazonaws.com` | Phase 11 ✅ | Alarms would fail silently |
| Split SNS into ops vs signals topics | Phase 11 ✅ | |
| Review the email subscription channel | Phase 11 ✅ | Slack webhook demos better |
| Step Functions has no `Catch` anywhere | Phase 6 ✅ | Every task catches to one `NotifyFailure` → SNS → `Fail`. Each catcher's `ResultPath` is `$.failure.<StateName>`, so the alert's JSON key IS the step that died |
| Remove the crawler polling states | Phase 6 ✅ | Four states and ~3 min/run gone, plus a `Default` branch that looped forever on a FAILED crawl |
| Split into two state machines | Phase 13 | Before the feedback loop makes it unreadable |
| All 3 EventBridge rules are DISABLED in AWS | Phase 5 | Intentional — project is dormant. Re-enable only once Phase 3 and Phase 5 are both done. **Phase 3 is now done**, so Phase 5 is the only remaining precondition |
| **The three Gold job names still say `cmc`** | Phase 12 | `gold-base-features-cmc-crypto`, `gold-ohlc-day-cmc-crypto`, `gold-ml-training-cmc-crypto`. Gold is source-agnostic by definition — Phase 2.1 made its prefixes dataset names for that reason — and since Phase 7 the ML job has not read a CoinMarketCap table at all. `name` is ForceNew, so this is a destroy+create; free, because the jobs are idle and the lake behind them is empty. Deliberately NOT bundled into Phase 7: Phase 6's rename was approved as its own decision with its own destroy count, and quietly attaching three more destroys to an unrelated phase is how a plan stops being reviewable |
| **The Binance archive switches ms → µs at 2025-01** | Phase 7 ✅ | Not in `data_sources.md` §11, which says the archive and the stream are "the same twelve fields" — true of the fields, not of their units. Verified against four real months either side of the boundary. Detected from the VALUE's magnitude rather than from the month, so a re-published old file cannot break it. Reading µs as ms does not error; it puts January 2025 in the year 56,000, which a partition filter then hides |
| **The full 4.4 GB backfill has not been run** | after the Phase 7 apply | The job is built and rehearsed on four asset-months. The full load needs `terraform apply` first, takes hours, and is the one part of Phase 7 that costs real money: a few dollars of FLEX Glue plus ~$0.15/month of S3. Run it with `--PROCESS_MODE full` on the Gold jobs afterwards |
| The neighbour `loteria-pipeline` project | after Phase 12 | Apply the container pattern there once internalised |

---

## Implementation order

Phases 0, 1, 2 and 2.1 are done. The remainder runs in numeric order. Two
sequencing points worth naming.

**Phase 2.1 sat between the backend and the module refactor for a reason** — and
in the event, half of that reason was ignored. It was supposed to come after
Phase 2, so the state would already be safe in its own bucket before a phase
started destroying buckets; it actually ran first, against the local state file.
The other half held: it came before Phase 3, because Phase 3's acceptance
criterion is a zero-diff plan and destroying three buckets is not zero diffs, and
because writing the `storage/` module once, against the final four-bucket shape,
beats rewriting it the week after it is frozen.

And: **Phase 4 (data source decision) had to be settled before Phase 5**, because
choosing Binance WebSocket forces a persistent producer, which pulls part of Phase
12's Docker/Fargate work forward. That is a feature, not a problem — it front-loads
the learning that matters most. Phase 4 is now done, so Phase 5 is unblocked on
everything except its own hosting decision.

**The project stays dormant through every phase.** It already had through 2, 2.1,
3 and 4; Phase 5 was written as the phase that would put data back in motion, and
on 2026-09-01 that was reversed — the wake-up moved to the end of the project, once
the whole stack exists (see *Current state: DORMANT* at the top of this file).
The reason is that a Kinesis shard bills from creation rather than from use, so
waking up in Phase 5 would mean carrying a recurring bill through years of phases
that do not need it. Dormancy is therefore not a waiting room any more, it is a
design constraint: billable resources are gated to `count = 0`, and the wake-up
stays a deliberate act, never a side effect of an apply.
