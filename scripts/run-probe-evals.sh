#!/usr/bin/env bash
# Runs the probe eval cases (evals/probe-*/) through `claude plugin eval`, LOCALLY.
# Run by the Lead at the E2 gate and whenever the probe layer changes. Never from CI: it needs the
# Lead's own Claude login and spends tokens (cost ceiling per case below). Nothing is published.
# CI only validates the cases offline (scripts/test-probe-evals.sh). bash 3.2 safe.
# --trust-plugin: this script evaluates this repository's own plugin, launched on purpose by the Lead;
# without it a non-interactive run (cloud session, no TTY) refuses to start.
#
# On macOS, run it in a Linux container instead: `claude plugin eval` refuses to run on the host
# (Docker Desktop symlinks, anthropics/claude-code#94308) and its Bash sandbox needs bubblewrap + socat.
#   - claude setup-token ; export CLAUDE_CODE_OAUTH_TOKEN=<token>
#   - bash scripts/run-probe-evals-docker.sh   (image: .devcontainer/, runs this script inside)
#
# Usage: run-probe-evals.sh [case...]   (default: probe-provision probe-pr-state probe-pr-write)
#
# Running it on macOS
#   - Keychain item `lgtmgate-eval-token`, holding a token created with `claude setup-token`.
#   - One line: CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s lgtmgate-eval-token -w)" bash scripts/run-probe-evals-docker.sh
#   - The cost printed is an estimate: it draws on the subscription quota, nothing is billed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

if ! command -v claude >/dev/null 2>&1; then
  echo "run-probe-evals: claude CLI not found on PATH" >&2
  exit 1
fi

# Eval runs get an allowlisted env only (EVAL_* passes); the prompts locate the plugin through it.
export EVAL_PLUGIN_ROOT="$ROOT"
MAX_COST="${PROBE_EVALS_MAX_COST_USD:-3}"

fail=0
[ "$#" -gt 0 ] || set -- probe-provision probe-pr-state probe-pr-write
for c in "$@"; do
  claude plugin eval . --case "$c" --runs 10 --max-cost-usd "$MAX_COST" --no-publish \
    --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir "$ROOT/evals/results/$c"
  rc=$?
  echo "== $c: exit=$rc"
  [ "$rc" -eq 0 ] || fail=1
done

exit "$fail"
