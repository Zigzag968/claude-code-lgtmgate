#!/usr/bin/env bash
# Regression test for scripts/lead-merge.sh (#74). Offline: a fake `gh` on PATH logs every call
# to a file; the git side is a throwaway repo + bare origin under $TMPDIR (the real worktree is
# never touched). Cases: open box, missing markers, happy path order, no auto-merge flag,
# --merge used, CI failure, idempotent re-run, main moved (own bump + unrelated commit) after the
# branch was cut, conflicting main, remote head ahead of local, stale/no-checks polling, base without
# required checks (#156), review freshness (#157: review on the head, commit after the review, no marker, bare marker,
# own commits on a re-run, head moved between the check and the sync, --tick-from-review on a stale review),
# prerelease versions (1.0.0-beta.N: next merge bumps the counter, a hand bump above main is kept, non-semver refused).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export HARNESS_OK_PREFIX=PASS
# shellcheck source=lib/harness.sh
. "$ROOT/tests/scripts/lib/harness.sh"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
. "$LIB/lead-merge-acceptance-lib.sh"
. "$LIB/lead-merge-gate-cases.sh"
. "$LIB/lead-merge-release-cases.sh"

echo "[lead-merge test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
