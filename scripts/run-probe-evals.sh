#!/usr/bin/env bash
# Runs the probe eval cases (evals/probe-*/) through `claude plugin eval`, LOCALLY.
# Run by the Lead at the E2 gate and whenever the probe layer changes. Never from CI: it needs the
# Lead's own Claude login and spends tokens (cost ceiling per case below). Nothing is published.
# CI only validates the cases offline (scripts/test-probe-evals.sh). bash 3.2 safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

if ! command -v claude >/dev/null 2>&1; then
  echo "run-probe-evals: claude CLI not found on PATH" >&2
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$ROOT"
MAX_COST="${PROBE_EVALS_MAX_COST_USD:-3}"

fail=0
for c in probe-provision probe-pr-state probe-pr-write; do
  claude plugin eval . --case "$c" --runs 10 --max-cost-usd "$MAX_COST" --no-publish \
    --allow-tools Bash --ablation none --threshold 0.95 --output-dir "$ROOT/evals/results/$c"
  rc=$?
  echo "== $c: exit=$rc"
  [ "$rc" -eq 0 ] || fail=1
done

exit "$fail"
