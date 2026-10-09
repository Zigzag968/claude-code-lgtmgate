#!/usr/bin/env bash
# Self-test of scripts/publish-fixture.cjs (+ its .sh wrapper), fully hermetic: the raw capture is a
# SYNTHETIC one generated from the public smoke fixture into a temp directory (planted unique words in
# the scout plan, the diagnose evidence, the nick summary and the brief), and everything is published
# into temp output directories. The real Claude Code projects directory and fixtures/incidents are never touched.
#
# Cases: `ok: published ...` (what the published file holds and how it replays), `ok: protected ...`,
# `ok: coupled ...`, `ok: printed ...`, `ok: publishing twice ...`, `ok: no temp copy ...`,
# `ok: refuses ...` (each refusal names its cause and writes nothing), `ok: usage ...`.
# The stub engines (--fp) are test doubles for the engine body; the PEM header is assembled from fragments.
# bash 3.2 compatible. Trailer: [test-publish-fixture] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
export ROOT
# the repo must come out of the suite exactly as it went in: no stub engine or publisher writes into the working tree
TREE0="$(git status --short --untracked-files=all 2>&1)"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/scripts/lib/harness.sh"
LIB="$ROOT/tests/scripts/lib"
. "$LIB/publish-fixture-setup.sh"
. "$LIB/publish-fixture-write-cases.sh"
. "$LIB/publish-fixture-replay-cases.sh"

TREE1="$(git status --short --untracked-files=all 2>&1)"
if [ "$TREE0" = "$TREE1" ]; then ok "the suite leaves the working tree untouched"; else bad "the suite changed the working tree: before='$TREE0' after='$TREE1'"; fi

rm -rf "$TMP"
RESULT=ok; [ "$FAIL" -gt 0 ] && RESULT=fail
echo "[test-publish-fixture] status=$RESULT passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
