#!/usr/bin/env bash
# PreToolUse(Workflow) — expand the references of a launch of the lgtmgate engine (#520, epic #528): `projectSpecificsRef`
# and `configRef` become the full objects (verified by digest) through updatedInput, and a launch by name gets a copy of the
# engine with the issue number in its progress titles. scripts/runtime/workflow-args-expand.cjs does the work; no model judges.
#
# A call that carries none of the three reference names never starts node (the check below is a plain string match), so a
# foreign Workflow call costs a few milliseconds. A missing `node` exits 127, which does not block the call: the engine
# itself refuses an unexpanded reference (`unexpanded-reference`, docs/consumer-reference.md).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"
case "$input" in
  *projectSpecificsRef*|*configRef*|*planRef*) ;;
  *) exit 0 ;;
esac
printf '%s' "$input" | exec node "$HOOK_DIR/../scripts/runtime/workflow-args-expand.cjs"
