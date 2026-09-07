# =============================================================================
# Import the three Gold tables from the manual-DDL era  (roadmap.md, Phase 7)
#
# Phase 7 moved the Gold catalog out of three hand-run .sql files and into
# Terraform. The files were run, so the tables EXIST in Glue -- created by
# `hadoop` from the Athena console in October 2025 -- and the first apply after
# the migration failed with AlreadyExistsException on all three. Terraform was
# not wrong: it had no idea they were there.
#
# Imported rather than deleted-and-recreated, for the same reason Phase 1 used
# `import {}` blocks for 55 addresses instead of 55 CLI calls: the drift is then
# visible in a plan that a human reads, rather than erased by a delete nobody
# reviews. What the plan converges is exactly the defect the module header
# describes -- gold_ohlc's asset_id enum still lists the provisional ELEVEN ids
# from before Phase 4, and the three dt ranges start on three unrelated dates.
#
# A Glue table update is in place: no destroy, and nothing is at stake behind
# them anyway -- Phase 2.1 emptied the lake and the Gold bucket has zero objects,
# so these are schemas over nothing.
#
# The account id is a literal for the same reason it is one in backend.tf: this
# is an identifier of the thing being adopted, not a value the config computes.
#
# DELETE THIS FILE once the import has been applied. An import block that has
# already run is a no-op, but leaving it turns a one-time recovery into
# permanent scenery -- and the next reader has to work out whether it still
# matters.
# =============================================================================

import {
  to = module.catalog.aws_glue_catalog_table.gold_features_base
  id = "913524903233:crypto_gold_db:gold_features_base"
}

import {
  to = module.catalog.aws_glue_catalog_table.gold_ohlc
  id = "913524903233:crypto_gold_db:gold_ohlc"
}

import {
  to = module.catalog.aws_glue_catalog_table.gold_ml_training
  id = "913524903233:crypto_gold_db:gold_ml_training"
}
