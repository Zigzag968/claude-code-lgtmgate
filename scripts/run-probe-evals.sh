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
# Automated runs (macOS)
#   - A LaunchAgent outside any Claude session runs the Docker eval and reads the token from the Keychain.
#     The Claude session never sees the token; it only drops a trigger file and reads the results.
#   - One-time install (human, once):
#     - bash scripts/eval-runner/install.sh <spool-dir> <allowed-root>   (writes files, loads nothing)
#     - claude setup-token
#     - security add-generic-password -a "$USER" -s lgtmgate-eval-token -T /usr/bin/security -w   (prompts for the token)
#     - launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.lgtmgate.eval-runner.plist
#   - Trigger (session): LGTMGATE_EVAL_SPOOL=<spool-dir> bash scripts/eval-runner/trigger.sh [--wait <s>] <worktree> [cases...]
#     - prints the id; --wait polls every 10 s, prints the summary, exits with the eval rc (124 on timeout)
#   - Results: <spool-dir>/done/<id>.{log,rc,summary,trigger}; launchd output in <spool-dir>/launchd.log
#     - rc: 0 ok, 64 trigger refused (path outside <allowed-root>, not a git worktree, bad case name),
#       65 Keychain item missing or locked, 66 docker missing
#   - Uninstall: bash scripts/eval-runner/install.sh --uninstall
#     - then optionally: security delete-generic-password -a "$USER" -s lgtmgate-eval-token
#   - Risks:
#     - the container runs with seccomp=unconfined (bubblewrap needs user namespaces)
#     - the token is a 1-year subscription credential: if leaked, revoke it at claude.ai and run setup-token again
#     - the job runs only while a GUI session is logged in (LaunchAgent), and needs Docker Desktop running
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
[ "$#" -gt 0 ] || set -- probe-provision probe-pr-state probe-pr-write
for c in "$@"; do
  claude plugin eval . --case "$c" --runs 10 --max-cost-usd "$MAX_COST" --no-publish \
    --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir "$ROOT/evals/results/$c"
  rc=$?
  echo "== $c: exit=$rc"
  [ "$rc" -eq 0 ] || fail=1
done

exit "$fail"
