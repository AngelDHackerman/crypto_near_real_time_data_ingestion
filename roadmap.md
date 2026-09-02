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

This is intentional, not an outage. Waking it up while the code is still being
restructured would mean accumulating data in a Bronze layout that Phase 6 is
going to change anyway. (The second reason — burning CMC credits on an asset list
Phase 4 was going to replace — is now spent: Phase 4 froze the list.)

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
defaulting to off, and a gate is `count = 0`, not merely "disabled" — a disabled
schedule is free, a created shard is not. Two flags carry this today, both `false`:

| Flag | Gates | Cost when open |
|---|---|---:|
| `eventbridge_rule_enabled` | the CMC extractor's schedule | ~$0 (CMC free tier) |
| `streaming_enabled` | the Kinesis stream, the Firehose delivery stream, the producer's `desired_count` | ~$25/mo |

Everything that is free to exist — VPC without a NAT Gateway, security groups, IAM
roles, ECR repositories, task definitions, log groups, Glue jobs, the state machine
— is applied for real. The lake is fully built and fully asleep.

Waking up is flipping those flags, deliberately and as code, never by clicking in
the console. Until that moment the correct state of this project is **asleep**.

**One precondition stands between the flags and a working wake-up.** Phase 5 built
the ECR repository and a task definition that pulls `:latest`, but **the producer
image has never been built and the repository is empty** — so flipping
`streaming_enabled` today starts a task that dies on `CannotPullContainerError`.
Closing it is Phase 12's job, where the CI/CD pipeline builds that image anyway.
Recorded in both places because an implicit precondition is one you discover on
the day it blocks you.

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
| 6 | Bronze layout, Silver adaptation, catalog cleanup | ⬜ Not started | | Retires the crawler. Buckets/prefixes already settled in 2.1 |
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

The bronze prefix *below* `cmc/` and `binance/` is still provisional — Phase 6
replaces the partitioning underneath with whatever Firehose writes. What is fixed
here is the top level.

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
becomes a one-line change instead of a rewrite. Moot in Phase 6, which deletes
the crawler.

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

## Phase 6 — Bronze layout, Silver adaptation, catalog cleanup

**Goal:** absorb the layout change Firehose forces, and retire the crawler.

**Already settled in Phase 2.1:** which bucket each layer lives in, and the fact
that `top10/` is gone. What remains here is only the *internal* layout of the
bronze bucket — the shape Firehose writes underneath the `binance/` prefix.

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

- **Backfill the history first, then compute features over the whole span.**
  Download the free Binance kline archive (`data_sources.md` §11) into
  `bronze/binance/`, stitching the pre-rename aliases from
  `config/tracked_assets.json`, and **resample the streaming data to the same
  1-minute grain in Gold** so old and new are one continuous table. The archive
  and the live `@kline_1m` event are the same twelve fields from the same
  exchange, so this is a concatenation, not an approximation. Carry
  `source ∈ {backfill, stream}` as a column and validate the two against each
  other on the overlap window.
- Extend the existing Gold jobs (`gold_features_base`, `gold_ohlc`,
  `gold_ml_training`) with RSI, moving averages, volume-derived features.
- **Layer the feature schema by data availability.** A core block computable from
  1-minute OHLCV alone spans 2017 to now; tick-derived features only start when the
  stream does. One flat schema would be mostly null in its most interesting columns.
- Orchestrate at the right cadence — with streaming data, the daily trigger may
  no longer be the right grain.
- Define and freeze the output feature schema that Phase 8 will consume.

**DoD**
- [ ] Historical archive backfilled into Bronze, aliases stitched, checksums verified
- [ ] Streaming data resampled to 1-minute bars in Gold; backfill and stream form one continuous series with a `source` column
- [ ] Backfill vs stream compared on the overlap window; any field-level divergence explained
- [ ] Missing minutes treated as missing, never forward-filled (Binance's own archive has gaps: 44,515 of 44,640 minutes in `BTCUSDT-1m-2018-01`)
- [ ] Indicators implemented and unit-verified against a known reference series
- [ ] Feature schema documented and versioned
- [ ] Job cadence chosen and justified against the streaming grain
- [ ] Features queryable in Athena, with no null explosion at series boundaries

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

**Depends on the Phase 7 backfill.** Training on a stream started in Phase 5 means
training on weeks of data. The 2017-onward archive (`data_sources.md` §11) is what
makes this phase possible at all.

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
| Glue crawler S3 target is immutable under `CRAWL_NEW_FOLDERS_ONLY` | Phase 2.1 ✅ | Any future target change needs `-replace`, not an update. Moot once Phase 6 deletes the crawler |
| **Delete the current lake data — deliberate clean slate** | Phase 2.1 ✅ | Incomplete series, provisional 11-asset list, polling-era design. Angel's call: start from zero rather than migrate |
| Unused `gold_spark_ui_prefix` variable | Phase 2.1 ✅ | Deleted there; its orphaned comment was swept in Phase 3 ✅ |
| Curate the final 50-asset list | Phase 4 ✅ | Frozen in `config/tracked_assets.json`: 50 ids across 10 behavioural cohorts, 45 with a Binance USDT pair, 5 CMC-only. BAT (`1697`) dropped from the provisional 11 |
| Wire `tracked_asset_ids` to `config/tracked_assets.json` | Phase 5 | Phase 4 wrote the file but changed no Terraform. tfvars still holds the literal 11 ids; Terraform should read the list with `jsondecode(file(...))` so the asset list has one owner, same rule as bucket and job names |
| Kinesis `ON_DEMAND` vs 1 provisioned shard | Phase 5 | Measured load is 17.4 KB/s and ~70 rec/s vs a shard's 1 MB/s / 1,000 rec/s. On-demand costs $29.20/mo in stream-hours alone before a byte is written; a shard is $10.95/mo flat, and its 25 KB PUT-unit billing also makes `@bookTicker` affordable later. See `data_sources.md` §9 |
| Use `@aggTrade`, not `@trade`; keep `@bookTicker` out of the baseline | Phase 5 | `@aggTrade` is 3.86× fewer frames with no loss at a 1-minute grain. `@bookTicker` was recommended before being measured and is 7.7× BTC's `@aggTrade` rate — measuring it reversed the call. Naive build $217/mo, tuned $12.62/mo |
| Batch producer writes to ~5 KB records | Phase 5 | Kinesis on-demand rounds every record up to 1 KB and the frames are 146–360 bytes, so one-record-per-event bills ~4× the bytes actually sent |
| **Producer hosting: Fargate 24/7 vs time-boxed vs Lambda polling** | Phase 5 | ⚠️ Open decision, Angel's call. First recurring cost in the project — not to be defaulted into |
| **The producer image has never been built; ECR is empty** | Phase 12 | Phase 5's task definition pulls `:latest` from `crypto-binance-producer-crypto` and nothing has ever been pushed there, so `streaming_enabled = true` would fail with `CannotPullContainerError`. Deferred deliberately — Phase 12's GitHub Actions pipeline builds that image anyway — but it is a **wake-up precondition**, not a nice-to-have. `producer/Dockerfile` has also never been executed, which is the same unvalidated-code risk Phase 5 rejected elsewhere |
| **Two deployed names now lie, and Phase 5 made it worse** | Phase 6 — **approved 2026-09-01** | The EventBridge rule is `schedule-fetch-top10-5-min-bronze-crypto` and the Lambda is `fetch-top10-crypto-crypto`. Neither was ever accurate — the list was 11, not 10 — and Phase 5 made both wrong twice over: 50 assets, hourly. `name` is ForceNew on both, so fixing them is a destroy+create. Deliberately NOT done in Phase 5, to keep its plan at **0 destroyed**; Phase 6 already touches this surface and both resources are DISABLED, so it is the cheap moment. The same reasoning Phase 3 used to rename the EventBridge `target_id`. Angel approved the rename for Phase 6, so that phase's plan will NOT be 0-destroyed and that is expected, not drift |
| **Backfill the Binance kline archive from 2017** | Phase 7 | Free at `data.binance.vision`, no key: 3,135 asset-months, ~133M 1-minute candles, ~4.4 GB, $0, and it bypasses Kinesis. Reaches 2017-07 (Binance's own start), not 13 years. Use klines, never aggTrades — one month of BTCUSDT aggTrades is 362 MB against 2.1 MB for klines |
| Resample the stream to 1-minute bars in Gold to meet the backfill | Phase 7 | The archive and the live `@kline_1m` event are the same twelve fields from the same exchange, so the stitch is exact. Carry `source ∈ {backfill, stream}` and validate on the overlap |
| Stitch pre-rename tickers when backfilling | Phase 7 | `RNDRUSDT` holds 33 months RENDER does not; `MATICUSDT` holds 66 months POL does not. `binance_symbol_aliases` in `config/tracked_assets.json` exists for this |
| Layer the feature schema by data availability | Phase 7 | 1-minute OHLCV features span 2017→now; tick-derived features start at Phase 5. One flat schema would be mostly null where it matters |
| Optional: BTC-quoted pairs for pre-2019 depth | Phase 7 | `ZECBTC`, `LINKBTC`, `XMRBTC` reach 16 months further than their USDT pairs. Needs a synthetic USD series (`price_btc × BTCUSDT`), so flag provenance and never mix it in silently |
| Firehose partitioning: dynamic vs native prefix | Phase 6 | Deep analysis required; affects Silver and cost |
| SNS topic policy blocks `cloudwatch.amazonaws.com` | Phase 11 | Alarms would fail silently |
| Split SNS into ops vs signals topics | Phase 11 | |
| Review the email subscription channel | Phase 11 | Slack webhook demos better |
| Step Functions has no `Catch` anywhere | Phase 6 | Alerts cannot say which step failed |
| Remove the crawler polling states | Phase 6 | Depends on Silver projection migration |
| Split into two state machines | Phase 13 | Before the feedback loop makes it unreadable |
| All 3 EventBridge rules are DISABLED in AWS | Phase 5 | Intentional — project is dormant. Re-enable only once Phase 3 and Phase 5 are both done. **Phase 3 is now done**, so Phase 5 is the only remaining precondition |
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
