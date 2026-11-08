#!/usr/bin/env bash
# PreToolUse(Workflow) — scoped to the lgtmgate engine (#520, epic #528, #605): a launch of the generated launch file has its
# `projectSpecificsRef` and `configRef` expanded to the full objects (verified by digest) through updatedInput, and every other
# launch form of the engine (by name, inline, the engine source) is refused. scripts/runtime/workflow-args-expand.cjs does the
# work; no model judges.
#
# A call that carries none of the words below never starts node (the check is a plain string match), so a foreign Workflow call
# costs a few milliseconds: the three reference names, the engine's registered name, its file name, its marker line and the
# launch directory. A call by name with no reference word must reach the refusal, hence the registered name. A missing `node`
# exits 127, which does not block the call: the engine itself refuses an unexpanded reference (`unexpanded-reference`) and any
# launch that is not from the launch file (`engine-launch-form`), docs/consumer-reference.md.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"
case "$input" in
  *projectSpecificsRef*|*configRef*|*planRef*|*lgtmgate:deliver-pipeline*|*deliver-pipeline.js*|*PHASE_TITLES*|*.pipeline/launch/*) ;;
  *) exit 0 ;;
esac
printf '%s' "$input" | exec node "$HOOK_DIR/../scripts/runtime/workflow-args-expand.cjs"
