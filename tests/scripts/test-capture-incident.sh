#!/usr/bin/env bash
# Self-test of scripts/capture-incident.cjs (+ its .sh wrapper), fully hermetic: the Workflow run
# is a SYNTHETIC one generated into a temp "projects" directory (CLAUDE_PROJECTS_DIR), the output
# goes to a temp git repo. The real Claude Code projects directory is never read.
#
# The generator composes only the key sets the reader whitelists (see the header of
# capture-incident.cjs). It proves the reader against that observed layout, not against Claude
# Code's live storage: the first real capture validates the layout, loudly.
#
# Cases: `ok: relaunch ...` (final pass identified by agentId, captured entries replayed),
# `ok: fail-closed ...` (each refusal names its cause and writes nothing), `ok: retried call ...` (a call the engine
# retried: folded under its engine label, or refused), `ok: usage ...`, `ok: buildStamp ...` (the run's own stamp decides which version-probe answer is tokenized).
# bash 3.2 compatible. Trailer: [test-capture-incident] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
# shellcheck source=lib/harness.sh
LIB="$ROOT/tests/scripts/lib"
. "$LIB/capture-incident-setup.sh"
. "$LIB/capture-incident-cases.sh"
. "$LIB/capture-incident-retry-cases.sh"

rm -rf "$TMP"
RESULT=ok; [ "$FAIL" -gt 0 ] && RESULT=fail
echo "[test-capture-incident] status=$RESULT passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
