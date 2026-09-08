#!/usr/bin/env bash
# Build the DuckDB Lambda layer.  roadmap.md Phase 10.
#
# A PRECONDITION OF serving_enabled = true, stated here and in the roadmap so it
# is not discovered on the day someone flips the flag -- which is exactly how
# Phase 5's unbuilt producer image became a wake-up blocker.
#
# The layer is built rather than committed: ~61 MB unpacked, ~20 MB zipped, and
# a binary wheel in git is a thing that rots without looking like it has.
#
# The version is PINNED and must match the one tests/test_indicators.py runs
# against. Serving on a different DuckDB version than the tested one is
# training/serving skew with extra steps -- it would not error, it would
# silently disagree at the edges.
set -euo pipefail

DUCKDB_VERSION="${DUCKDB_VERSION:-1.2.2}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${HERE}/build/layer/python"

rm -rf "${HERE}/build/layer"
mkdir -p "${TARGET}"

# --platform/--only-binary is what makes this reproducible from any machine:
# without them pip would build for the LOCAL platform, and a wheel compiled on
# WSL is not a wheel that runs on Lambda's Amazon Linux.
pip install \
  --quiet \
  --platform manylinux2014_x86_64 \
  --python-version "${PYTHON_VERSION}" \
  --only-binary=:all: \
  --target "${TARGET}" \
  "duckdb==${DUCKDB_VERSION}"

echo "built ${TARGET} ($(du -sh "${HERE}/build/layer" | cut -f1))"
echo "python3 -c 'import duckdb' must resolve to ${DUCKDB_VERSION} in the tests too"
