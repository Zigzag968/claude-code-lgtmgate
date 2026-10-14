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
#   - bash scripts/run-probe-evals-docker.sh   (image: .devcontainer/, runs this script inside; the wrapper
#     reads the Keychain item itself and runs scripts/eval-preflight.sh)
#   - On the host this script refuses with `eval-not-runnable` (exit 3) before any eval call or results file.
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
# Summary (#454): after the gate, the run writes $RESULTS_DIR/eval-summary.json = the content digest of
# evals/ templates/ hooks/ agents/ scripts/ (scripts/eval-digest.cjs), the gate verdict and its last line;
# nothing is written when the tree changed during the run. The Lead publishes it by copying it to
# docs/gate/e2-eval.json (committed), which scripts/gate-check.sh reads from any checkout.
#
# Running it on macOS
#   - Keychain item `lgtmgate-eval-token`, holding a token created with `claude setup-token`.
#   - One line: bash scripts/run-probe-evals-docker.sh
#   - The cost printed is an estimate: it draws on the subscription quota, nothing is billed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

if ! command -v claude >/dev/null 2>&1; then
  echo "run-probe-evals: claude CLI not found on PATH" >&2
  exit 1
fi
# A host refusal is "not runnable", never a failed probe run: exit before any eval call or results file.
if [ "$(uname -s)" = "Darwin" ]; then
  bash "$SCRIPT_DIR/eval-preflight.sh" host || exit $?
fi

# Eval runs get an allowlisted env only (EVAL_* passes); the prompts locate the plugin through it.
export EVAL_PLUGIN_ROOT="$ROOT"
MAX_COST="${PROBE_EVALS_MAX_COST_USD:-3}"
RESULTS_DIR="${PROBE_EVALS_RESULTS_DIR:-$ROOT/evals/results}"

[ "$#" -gt 0 ] || set -- probe-provision probe-pr-state probe-pr-write
before="$(node "$SCRIPT_DIR/eval-digest.cjs" --root "$ROOT" 2>/dev/null)"
for c in "$@"; do
  rm -f "$RESULTS_DIR/$c/aggregate-result.json" || { echo "run-probe-evals: cannot clear the previous results of $c" >&2; exit 1; }
  # --threshold 0.95 is a per-case MEAN check, kept only as a quick signal: the gate below decides.
  claude plugin eval . --case "$c" --runs 10 --max-cost-usd "$MAX_COST" --no-publish \
    --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir "$RESULTS_DIR/$c"
  rc=$?
  echo "== $c: claude exit=$rc (informational, the gate below decides)"
done

gate_out="$(bash "$SCRIPT_DIR/probe-eval-gate.sh" "$RESULTS_DIR" "$@" 2>&1)"
rc=$?
printf '%s\n' "$gate_out"

# Summary (#454): record the digest of the tree the eval ran on, so freshness is judged by content.
after="$(node "$SCRIPT_DIR/eval-digest.cjs" --root "$ROOT" 2>/dev/null)"
if [ -n "$before" ] && [ "$before" = "$after" ]; then
  verdict=FAIL; [ "$rc" -eq 0 ] && verdict=PASS
  last_line="$(printf '%s\n' "$gate_out" | tail -n 1)"
  node "$SCRIPT_DIR/eval-digest.cjs" --root "$ROOT" --write "$RESULTS_DIR/eval-summary.json" --gate "$verdict" --line "$last_line" \
    || echo "run-probe-evals: warning: could not write $RESULTS_DIR/eval-summary.json" >&2
else
  echo "run-probe-evals: tree changed during the run, no summary written" >&2
fi
exit "$rc"
