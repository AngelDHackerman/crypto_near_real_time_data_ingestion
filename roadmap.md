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

**Account:** `913524903233` · **Region:** `us-east-1` · **Env suffix:** `crypto`

---

## ⏸️ Current state: DORMANT

**The pipeline is deliberately not running.** All three EventBridge rules are
DISABLED in AWS, and `terraform.tfvars` sets `eventbridge_rule_enabled = false`
to match that reality. Nothing is ingesting, nothing is being processed, nothing
is billing beyond storage.

This is intentional, not an outage. Waking it up while the code is still being
restructured would mean accumulating data in a Bronze layout that Phase 6 is
going to change anyway, and burning CMC credits on an asset list that Phase 4 is
going to replace.

**Wake-up conditions — both must be met:**

1. The Terraform refactor is complete (Phase 3 done, modules in place, plan clean).
2. Kinesis ingestion is deployed (Phase 5 done, streaming path verified end to end).

Only then are the EventBridge rules re-enabled, deliberately and as code — by
flipping `eventbridge_rule_enabled` to `true`, never by clicking in the console.
Until that moment the correct state of this project is **asleep**.

---

## Progress tracker

| # | Phase | Status | Branch / PR | Notes |
|---|-------|--------|-------------|-------|
| 0 | Unblock HTTPS egress from WSL | ✅ Done | — | `aws sts get-caller-identity` works |
| 1 | Recover `terraform.tfstate` by import | ✅ Done | `phase-1/state-recovery-and-roadmap` → `master` | 55 imported, 6 added, 3 changed, **0 destroyed**; plan clean |
| 2 | Remote backend on S3 | ⬜ Not started | | Kills the local-state risk for good |
| 3 | Terraform refactor into modules | ⬜ Not started | | Uses `moved {}` blocks, zero-diff plan |
| 4 | Data source strategy (Binance WS + CMC) | ⬜ Not started | | Decision phase, no infra. Fixed 50-asset list |
| 5 | Streaming ingestion (Kinesis + Firehose + producer) | ⬜ Not started | | Depends on 4. **Project wakes up here.** Producer hosting undecided |
| 6 | Bronze layout, Silver adaptation, catalog cleanup | ⬜ Not started | | Retires the crawler |
| 7 | Feature engineering | ⬜ Not started | | Extends existing Gold jobs |
| 8 | Model training | ⬜ Not started | | Serverless, no VPC |
| 9 | Model registry | ⬜ Not started | | |
| 10 | Serving / inference | ⬜ Not started | | |
| 11 | Monitoring & alerting (SNS refactor) | ⬜ Not started | | |
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

## Phase 2 — Remote backend on S3

**Goal:** eliminate the root cause of this whole mess. The state is still a local
file; one more machine migration and it is lost again.

**Scope**

- Create an S3 state bucket (`crypto-tf-state-913524903233`, mirroring the
  existing `loteria-tf-state-913524903233` from the neighbour project) with
  versioning enabled, SSE, and public access fully blocked.
- Chicken-and-egg: create the bucket with a small bootstrap config using local
  state, then `terraform import` it into the main config.
- Add the `backend "s3"` block using **native S3 locking** (`use_lockfile = true`)
  — no DynamoDB table needed on modern Terraform.
- `terraform init -migrate-state` to move the local state up.
- Delete the local `terraform.tfstate*` files only after verifying the remote
  state is readable and the plan is still clean.

**DoD**
- [ ] State bucket exists, versioned, encrypted, public access blocked
- [ ] `backend "s3"` configured with `use_lockfile = true`
- [ ] `terraform init -migrate-state` completed successfully
- [ ] `terraform plan` still reports `No changes` reading from the remote state
- [ ] Local `terraform.tfstate` deleted; state bucket managed by Terraform itself
- [ ] Concurrent-run lock verified (a second plan blocks while one is running)

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

## Phase 3 — Terraform refactor into modules

**Goal:** turn 20 flat `.tf` files into a readable module structure.

**Why after the import, not before:** modularising changes state addresses
(`aws_s3_bucket.lake_raw_data` → `module.storage.aws_s3_bucket.lake_raw_data`).
Refactoring on top of a known-good state, using `moved {}` blocks, keeps the plan
at zero diffs. Refactoring first would have meant importing into module addresses
that had never been validated, with no safety net.

**Target structure**

```
terraform/
├── modules/
│   ├── storage/        # 3 buckets + versioning + sse + lifecycle
│   ├── ingestion/      # lambda + eventbridge  (later: kinesis + firehose)
│   ├── catalog/        # glue databases + crawler + athena workgroup
│   ├── processing/     # the 4 glue jobs
│   ├── orchestration/  # step functions + eventbridge -> sfn
│   └── observability/  # sns + failure rules + alarms
└── envs/
    └── crypto/         # main.tf, backend.tf, versions.tf, terraform.tfvars
```

**Key principle:** IAM lives inside the module of the resource it serves. Today
`iam_lambda.tf`, `iam_sfn.tf`, `iam_glue_job_gold.tf` etc. sit apart from what
they grant access to, which is exactly what makes the codebase hard to read.

**Also folded into this phase** (deliberate changes, each on its own reviewed plan)

- Rename the four pinned auto-generated identifiers to readable names
  (three event `target_id`s + the Glue inline policy name).
- Tighten IAM: `iam_sfn.tf` grants Glue actions on `Resource = ["*"]`, which
  contradicts the project's own least-privilege rule.
- Remove the unused `top10_list_symbol` variable.
- Introduce `default_tags` on the provider (kept out of Phase 1 on purpose — it
  would have retagged every deployed resource and flooded the import plan).
- Run `terraform fmt -recursive` (kept out of Phase 1 to keep that diff readable).
- Add `outputs.tf` — there is none today.

**DoD**
- [ ] All resources live inside modules; `envs/crypto/` holds only composition
- [ ] Every module has its own `versions.tf` with pinned providers
- [ ] `moved {}` blocks for every relocated address
- [ ] `terraform plan` reports `No changes` after the refactor
- [ ] `terraform fmt -check -recursive` passes
- [ ] IAM `Resource = "*"` either scoped to ARNs or justified in a comment
- [ ] `moved {}` blocks removed in a follow-up commit once applied

**Prompt to run**

> Phase 3 of roadmap.md: refactor the Terraform codebase into modules
> (storage / ingestion / catalog / processing / orchestration / observability)
> with an `envs/crypto/` composition layer. Move IAM into the module of the
> resource it serves. Use `moved {}` blocks for every relocated address so the
> plan stays at zero diffs — that is the acceptance criterion, verify it.
> Then, as separate reviewed commits: rename the pinned auto-generated
> identifiers, scope the `Resource = "*"` IAM statements, drop the unused
> `top10_list_symbol`, add `default_tags`, add `outputs.tf`, and run
> `terraform fmt -recursive`.

---

## Phase 4 — Data source strategy

**Goal:** decide what actually feeds the pipeline, before writing any Kinesis
code. This decision reshapes everything downstream.

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

**Also decided:** expand coverage from the current 11 assets to **50**.
This changes the CMC credit math (`quotes/latest` bills per 100 items, so 50 ids
still costs 1 credit/call; hourly = ~730 credits/month, comfortably under quota).

**Decided: the asset list is STATIC — a hand-picked set of 50, not a live top-50
ranking.** A dynamic `listings/latest` lookup would silently change the tracked
universe every time a coin moves in or out of the market-cap top 50, which is
drift by another name: the training set stops being reproducible, features get
null gaps where an asset entered or left, and a dataset from six months ago
becomes uninterpretable. The list is therefore curated once, committed as code,
and changed only by an explicit commit.

The current 11 ids are provisional. The final 50 will be chosen deliberately —
selection criteria still to be worked out, but the shape that matters for ML is
diversity of behaviour, not market-cap rank: large caps, alternate L1s, at least
one stablecoin as a negative control (near-zero volatility — if the model emits
signals on it, the model is broken), and something high-volatility.

**Scope**

- Curate and freeze the 50-asset CMC id list; commit it as code with a short note
  on why each asset is in it.
- Map the Binance symbol universe to the CMC id universe. They will not overlap
  perfectly: some assets have no Binance USDT pair. Decide the join key and what
  happens to assets present in one source only.
- Document why two sources, and what the Silver-layer join between them looks like.
  This join is the most interesting thing to defend in an interview — far more so
  than "I poll an API".

**DoD**
- [ ] Final 50-asset list curated and frozen, with the CMC id ↔ Binance symbol mapping written down
- [ ] Selection rationale recorded per asset (why this one is tracked)
- [ ] List committed as code; no runtime `listings/latest` lookup anywhere
- [ ] CMC credit budget recomputed and documented under the free tier
- [ ] Silver-layer join strategy between the two sources documented
- [ ] Decision and rationale written into `README.md`, not just this roadmap

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

- `aws_kinesis_stream` in `ON_DEMAND` mode.
- Producer holding the Binance WebSocket open, batching `put_records` with
  `PartitionKey` = asset symbol (preserves per-asset ordering within a shard).
- Dedicated IAM role for the producer: `kinesis:PutRecord` / `PutRecords` scoped
  to the stream ARN, never `*`.
- `aws_kinesis_firehose_delivery_stream` from the stream into the existing bronze
  bucket, with `buffering_size` / `buffering_interval` matched to actual volume.
- Dedicated IAM role for Firehose (read the source stream, write the destination
  bucket).
- Retune the existing CMC Lambda: 5 min → 1 hour, 11 assets → top 50.

**⚠️ OPEN DECISION — where the producer runs. Deliberately unresolved.**

This is the first decision in the project that introduces a recurring bill, and
it is not going to be rushed or defaulted into. No producer code gets written
until it is settled. The options, with their real trade-offs:

| Option | Cost | What it buys | What it costs you |
|---|---|---|---|
| **ECS/Fargate 24/7** | ~$10–15/mo at 0.25 vCPU | A genuinely always-on streaming consumer; front-loads the Phase 12 Docker/Fargate learning | First permanent bill in the project; runs whether or not anyone is looking |
| **Time-boxed Fargate** | ~$10–15 once | Same architecture, captured as screenshots/video/metrics for the portfolio, then scaled to zero | The demo is a recording, not a live system |
| **Lambda + Binance REST** | ~free | No fixed cost, no CMC-style credit ceiling | Still polling, not streaming — weakens the core claim of the project |
| **Other** | — | Still worth exploring: Kinesis Data Streams consumers, App Runner, EC2 spot, a scheduled Fargate task | Not yet investigated |

A WebSocket needs a persistent process, so Lambda's 15-minute ceiling rules it
out for options 1–2. Note the tension worth thinking through: option 3 is free
but undercuts the "near real time" claim in the project's own name, while option
1 is the only one that is genuinely always-on.

**Status: to be decided by Angel.** Not a default, not a recommendation to be
quietly adopted — an explicit choice to be made and then written down here with
its reasoning.

**DoD**
- [ ] Kinesis stream in ON_DEMAND, defined in Terraform
- [ ] Producer running, connected, writing records with symbol as partition key
- [ ] Producer IAM role scoped to the stream ARN
- [ ] Firehose delivering into the bronze bucket, buffering tuned and justified
- [ ] CMC Lambda retuned to hourly / top-50
- [ ] Producer hosting decision made **explicitly**, with its monthly cost and
      reasoning written into this file before any producer code is written
- [ ] End-to-end verified: a Binance tick lands as an object in S3
- [ ] EventBridge rules re-enabled via `eventbridge_rule_enabled = true` — this is
      the phase where the project wakes up (see *Current state: DORMANT*)

**Prompt to run**

> Phase 5 of roadmap.md: build the streaming ingestion path. Add a Kinesis stream
> in ON_DEMAND mode, a Firehose delivery stream into the existing bronze bucket,
> and the Binance WebSocket producer, each with its own least-privilege IAM role
> scoped by ARN. Retune the CMC Lambda to hourly and the top-50 asset list.
> Before writing ANY producer code, stop and walk me through the hosting decision
> (Fargate 24/7 vs time-boxed vs Lambda REST polling vs anything I have not
> considered) with real monthly costs — this is my call to make, not yours to
> default into. Once I have decided, build it and verify end-to-end that a Binance
> tick reaches S3. This is also the phase where the project wakes up: re-enable
> the EventBridge rules through `eventbridge_rule_enabled`, never in the console.

---

## Phase 6 — Bronze layout, Silver adaptation, catalog cleanup

**Goal:** absorb the layout change Firehose forces, and retire the crawler.

**The problem.** Firehose writes `YYYY/MM/DD/HH/` prefixes, not Hive-style. The
current bronze layout is `id={coin_id}/year=/month=/day=/hour=/`, produced by the
Lambda. If Firehose writes its native prefix, **the Silver job stops finding the
data**.

Two options:

1. **Firehose dynamic partitioning** with custom prefixes
   (`symbol=!{partitionKeyFromQuery:symbol}/year=!{timestamp:yyyy}/...`).
   Preserves the layout, but costs extra per GB partitioned and needs JQ parsing
   or a transformation Lambda.
2. **Keep Firehose's native prefix and adapt the Silver job** to read from
   `bronze_stream/`. The Silver job re-partitions anyway.

**Leaning towards option 2** — less engineering, lower cost, identical Silver
output. Non-negotiable either way: the event timestamp must travel **inside the
payload**, not only in the S3 path.

**Catalog cleanup.** Gold already uses partition projection with manual DDL — the
Gold crawlers are commented out in `glue_crawlers_catalog.tf` and there are three
`sql/athena_projections_*.sql` files. Only Silver still depends on a crawler.
Migrating Silver to projection lets the crawler be deleted, which in turn lets
four states be removed from the Step Functions machine.

**Step Functions changes** (findings recorded from the Phase 0 review)

- The `StartCrawler` → `Wait 180s` → `GetCrawler` → `Choice` polling loop can be
  deleted entirely once Silver uses projection. Four fewer states, ~3 minutes less
  per run, no crawler cost.
- **There is no `Catch` anywhere.** Retries are `States.ALL × 3` and nothing else.
  On failure the execution dies and the EventBridge failure rule fires SNS — it
  works, but the alert cannot say *which step* failed. Add a `Catch` routing to a
  `NotifyFailure` state that carries the failed state name.
- The daily Silver→Gold machine itself stays valid under streaming. Only the
  producer of bronze changes, not how bronze is processed.

**DoD**
- [ ] Firehose partitioning option chosen, with the cost trade-off documented
- [ ] Silver job reads the new bronze layout; output schema unchanged
- [ ] Event timestamp present inside the payload
- [ ] Silver migrated to partition projection; Silver crawler deleted
- [ ] Crawler polling states removed from the state machine
- [ ] `Catch` → `NotifyFailure` added, alert names the failed state
- [ ] Athena queries return the same results as before the migration

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

## Phase 7 — Feature engineering

**Goal:** compute the technical indicators the model will train on.

**Scope**

- Extend the existing Gold jobs (`gold_features_base`, `gold_ohlc`,
  `gold_ml_training`) with RSI, moving averages, volume-derived features.
- Orchestrate at the right cadence — with streaming data, the daily trigger may
  no longer be the right grain.
- Define and freeze the output feature schema that Phase 8 will consume.

**DoD**
- [ ] Indicators implemented and unit-verified against a known reference series
- [ ] Feature schema documented and versioned
- [ ] Job cadence chosen and justified against the streaming grain
- [ ] Features queryable in Athena, with no null explosion at series boundaries

**Prompt to run**

> Phase 7 of roadmap.md: implement feature engineering. Extend the existing Gold
> Glue jobs with RSI, moving averages and volume features. Verify the indicator
> maths against a known reference series rather than trusting the output. Define
> and freeze the feature schema that model training will consume, and pick the job
> cadence that matches the streaming grain. Watch for nulls at window boundaries.

---

## Phase 8 — Model training

**Goal:** the ML core. First place with genuinely delicate IAM.

**Decided: no VPC.** Putting the training job in a VPC means a NAT Gateway
(~$32/month plus transfer) or four interface endpoints (~$7/month each for
ecr.api, ecr.dkr, logs, sts). A training job that only reads S3 does not justify
it. Knowing *when not to* reach for a VPC is as defensible as knowing how to build
one — and it will be documented as an explicit decision, not an omission.

**Scope**

- SageMaker Training/Processing jobs over the feature dataset.
- SageMaker execution role — S3, ECR, CloudWatch Logs, scoped by ARN.
- `aws_ecr_repository` for the training image, with pinned image versioning
  consistent with the project's `version = x.y.z` discipline.
- Trained model artifact stored in S3 with versioning and lifecycle.

**DoD**
- [ ] Training job runs end-to-end from Terraform-defined infrastructure
- [ ] Execution role scoped by ARN, no wildcards
- [ ] ECR repository with an explicit image tagging scheme
- [ ] Model artifact in S3, versioned, with a lifecycle policy
- [ ] Baseline metric recorded — the number Phase 13 will measure degradation against
- [ ] The "no VPC" decision documented with its cost reasoning

**Prompt to run**

> Phase 8 of roadmap.md: build model training on SageMaker. No VPC — document the
> cost reasoning for that decision. Create the ECR repository with explicit image
> versioning, the SageMaker execution role scoped by ARN with no wildcards, and
> store the model artifact in versioned S3. Record the baseline metric that Phase 13
> will use as its degradation reference.

---

## Phase 9 — Model registry

**Scope**

- `aws_sagemaker_model_package_group` to version models and mark which version is
  staging vs production.
- Hook into CI/CD so promotion from staging to production needs no manual step.

**DoD**
- [ ] Model package group defined in Terraform
- [ ] At least two model versions registered, with a clear staging/production marker
- [ ] Promotion is scripted, not clicked

**Prompt to run**

> Phase 9 of roadmap.md: add the SageMaker model package group and the
> staging/production promotion mechanism. Register at least two model versions to
> prove versioning works, and make promotion scripted rather than manual.

---

## Phase 10 — Serving / inference

**Scope**

- `aws_sagemaker_model` → `aws_sagemaker_endpoint_configuration` →
  `aws_sagemaker_endpoint`.
- Serverless inference preferred, consistent with the Phase 8 no-VPC decision and
  to avoid an always-on endpoint bill.
- If a VPC is ever justified for serving (a private endpoint has a real argument,
  unlike training), it goes here — no NAT, S3 gateway endpoint plus the needed
  interface endpoints, using a pinned public VPC module.

**DoD**
- [ ] Endpoint responds to an inference request
- [ ] Serverless (or the always-on cost explicitly accepted and written down)
- [ ] Latency measured and recorded — Phase 13's CI/CD gates against it
- [ ] Endpoint fully defined in Terraform

**Prompt to run**

> Phase 10 of roadmap.md: deploy the inference endpoint (model → endpoint config →
> endpoint), preferring serverless inference to avoid always-on cost. Measure and
> record baseline latency, since Phase 13's model CI/CD will gate on it.

---

## Phase 11 — Monitoring & alerting

**Goal:** alerting as code, and fix what the Phase 0 review found in the current
SNS setup.

**Findings to fix**

- **The topic policy only allows `events.amazonaws.com` to publish.** When
  CloudWatch alarms are added for buy/sell signals and model drift, they will
  publish as `cloudwatch.amazonaws.com` and **silently fail**. This will cost
  debugging time if not fixed up front.
- **One topic mixes two audiences.** "Pipeline failed" (operational) and "buy
  signal on BTC" (business) in the same topic means the email subscription becomes
  noise and gets ignored. Split into `-ops-alerts` and `-model-signals`.
- The existing email subscription (`angeldariaux@gmail.com`) is confirmed and now
  imported into state. Revisit whether email is the right channel for signals —
  SNS → Lambda → Slack webhook demos far better than an inbox.

**Scope**

- `aws_cloudwatch_metric_alarm` + the split SNS topics, all in Terraform.
- Evaluate SageMaker Model Monitor for production drift detection — the piece that
  separates a "complete" portfolio project from one that merely predicts.

**DoD**
- [ ] Two topics split by audience, each with the right subscribers
- [ ] Topic policy permits every principal that actually needs to publish
- [ ] A CloudWatch alarm verified to reach its destination end-to-end
- [ ] Signal delivery channel decided (Slack vs email) and implemented
- [ ] Model Monitor evaluated; decision recorded either way

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
earlier — which is a good reason to lean that way.

**DoD**
- [ ] Multi-stage Dockerfile; image size measured and deliberately reduced
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
| Rename the 3 auto-generated event `target_id`s | Phase 3 | Pinned to AWS-generated values for the import |
| Rename the Glue inline policy `terraform-2025...` | Phase 3 | Same reason |
| `iam_sfn.tf` grants Glue on `Resource = ["*"]` | Phase 3 | Contradicts the project's least-privilege rule |
| Unused `top10_list_symbol` variable | Phase 3 | Declared, never referenced |
| `terraform fmt` across the whole codebase | Phase 3 | Kept out of Phase 1 to keep that diff readable |
| `default_tags` on the provider | Phase 3 | Kept out of Phase 1 — would have retagged everything |
| No `outputs.tf` anywhere | Phase 3 | |
| **Rename the `top10/` prefix to `assets/`** (or similar) | when convenient | The name already lies (11 assets today, 50 later). Not cosmetic: it means migrating objects in S3, rewriting the Athena projection DDL, and updating every Glue job argument and IAM ARN pattern. Cheapest moment is while the lake is small and dormant. Also touches `top10_list_id` / `top10_list_symbol` variable names |
| Curate the final 50-asset list | Phase 4 | Static and hand-picked, never a live ranking. The current 11 ids are provisional |
| **Producer hosting: Fargate 24/7 vs time-boxed vs Lambda polling** | Phase 5 | ⚠️ Open decision, Angel's call. First recurring cost in the project — not to be defaulted into |
| Firehose partitioning: dynamic vs native prefix | Phase 6 | Deep analysis required; affects Silver and cost |
| SNS topic policy blocks `cloudwatch.amazonaws.com` | Phase 11 | Alarms would fail silently |
| Split SNS into ops vs signals topics | Phase 11 | |
| Review the email subscription channel | Phase 11 | Slack webhook demos better |
| Step Functions has no `Catch` anywhere | Phase 6 | Alerts cannot say which step failed |
| Remove the crawler polling states | Phase 6 | Depends on Silver projection migration |
| Split into two state machines | Phase 13 | Before the feedback loop makes it unreadable |
| All 3 EventBridge rules are DISABLED in AWS | Phase 5 | Intentional — project is dormant. Re-enable only once Phase 3 and Phase 5 are both done |
| The neighbour `loteria-pipeline` project | after Phase 12 | Apply the container pattern there once internalised |

---

## Implementation order

Phases 0–1 are done. The remainder runs in numeric order, with one exception worth
naming: **Phase 4 (data source decision) must be settled before Phase 5**, because
choosing Binance WebSocket forces a persistent producer, which pulls part of Phase
12's Docker/Fargate work forward. That is a feature, not a problem — it front-loads
the learning that matters most.

**The project stays dormant through Phases 2, 3 and 4.** Those phases touch code,
structure and decisions — not running infrastructure. Phase 5 is the first one that
puts data back in motion, and the wake-up is a deliberate act with two
preconditions (see *Current state: DORMANT* at the top of this file), not a side
effect of an apply.
