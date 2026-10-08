#!/usr/bin/env bash
# Runs the probe eval cases (evals/probe-*/) through `claude plugin eval`, LOCALLY.
# Run by the Lead at the E2 gate and whenever the probe layer changes. Never from CI: it needs the
# Lead's own Claude login and spends tokens (cost ceiling per case below). Nothing is published.
# CI only validates the cases offline (tests/scripts/test-probe-evals.sh). bash 3.2 safe.
# --trust-plugin: this script evaluates this repository's own plugin, launched on purpose by the Lead;
# without it a non-interactive run (cloud session, no TTY) refuses to start.
#
# On macOS, run it in a Linux container instead: `claude plugin eval` refuses to run on the host
# (Docker Desktop symlinks, anthropics/claude-code#94308) and its Bash sandbox needs bubblewrap + socat.
#   - claude setup-token ; export CLAUDE_CODE_OAUTH_TOKEN=<token>
#   - bash scripts/run-probe-evals-docker.sh   (image: .devcontainer/, runs this script inside)
#
# Usage: run-probe-evals.sh [case...]   (default: probe-provision probe-pr-state probe-pr-write)
# Not in the default set: pr-write-b64 (#212), the copy fidelity of the real tick format (a long --text-b64 token under
# --expect-cmd, parser pr-write); run it by name: run-probe-evals.sh pr-write-b64
#
# The gate (#81): at least 29 of the 30 runs (3 cases x 10) FULLY passed, i.e. score 1 on all 4 graders.
# scripts/probe-eval-gate.sh counts the runs from each case's aggregate-result.json and decides the exit
# code. `claude plugin eval --threshold` compares the case MEAN (two runs at 0.75 still give 0.95), so it
# is NOT the gate: its exit code is only printed. A stale results file is deleted before each case, so a
# run that dies early cannot be gated on an older pass.
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
RESULTS_DIR="${PROBE_EVALS_RESULTS_DIR:-$ROOT/evals/results}"

[ "$#" -gt 0 ] || set -- probe-provision probe-pr-state probe-pr-write
for c in "$@"; do
  rm -f "$RESULTS_DIR/$c/aggregate-result.json" || { echo "run-probe-evals: cannot clear the previous results of $c" >&2; exit 1; }
  # --threshold 0.95 is a per-case MEAN check, kept only as a quick signal: the gate below decides.
  claude plugin eval . --case "$c" --runs 10 --max-cost-usd "$MAX_COST" --no-publish \
    --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir "$RESULTS_DIR/$c"
  rc=$?
  echo "== $c: claude exit=$rc (informational, the gate below decides)"
done

bash "$SCRIPT_DIR/probe-eval-gate.sh" "$RESULTS_DIR" "$@"
exit $?
