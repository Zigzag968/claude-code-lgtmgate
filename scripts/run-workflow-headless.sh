#!/usr/bin/env bash
# run-workflow-headless.sh (#54, D12) — the deterministic, non-model-mediated proof
# channel for a Workflow-tool run in --print mode. Per P4 (this repo, 2026-08-22): the
# tool_result in --print mode is only "Workflow launched in background. Task ID: …" —
# the real return arrives on a LATER task_notification stream-json event carrying
# output_file: <abs path>, itself holding {summary, logs[], result{...},
# workflowProgress[], totalTokens}. This script runs the session, scans the
# stream-json output for that event, and COPIES output_file to --out in the SAME
# invocation — the source is a session tmp path, never hand it across Bash calls
# (see .claude/rules/git-workflow.md "Cross-mode file handoff").
#
# Usage: printf '%s' '<prompt>' | bash scripts/run-workflow-headless.sh \
#          [--plugin-dir <path>] --out <path>
#
# The prompt MUST arrive on stdin — a trailing prompt arg after --allowed-tools
# errors "Input must be provided" (recorded on claude-agent-pipeline#50).
#
# Last stdout line (trailer, always): [wf-headless] status=<ok|no-result|error> out=<path>

set -u

OUT=""
PLUGIN_DIR_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --plugin-dir) PLUGIN_DIR_ARGS+=(--plugin-dir "$2"); shift 2 ;;
    *) echo "run-workflow-headless.sh: unknown arg '$1'" >&2; shift ;;
  esac
done

if [ -z "$OUT" ]; then
  echo "run-workflow-headless.sh: --out <path> is required" >&2
  echo "[wf-headless] status=error out="
  exit 2
fi

RAW="$(mktemp "${TMPDIR:-/tmp}/wf-headless-raw.XXXXXXXX")"

# bash 3.2 (macOS /usr/bin/env bash) trips 'set -u' on an empty array expansion — same trap
# documented in scripts/provision-worktree.sh:152. Guarded form => zero words when unset.
claude --print --output-format stream-json --verbose --model claude-sonnet-5 \
  --allowed-tools Workflow ${PLUGIN_DIR_ARGS[@]+"${PLUGIN_DIR_ARGS[@]}"} > "$RAW" 2>&1
CLAUDE_EXIT=$?

OUTPUT_FILE="$(python3 -c "
import json
path = None
with open('$RAW') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        # task_notification events carry output_file at the top level or nested
        # under a 'notification'/'task_notification' key — accept either shape.
        for c in (obj, obj.get('notification') or {}, obj.get('task_notification') or {}):
            if isinstance(c, dict) and c.get('output_file'):
                path = c['output_file']
print(path or '')
")"

if [ -z "$OUTPUT_FILE" ] || [ ! -f "$OUTPUT_FILE" ]; then
  echo "run-workflow-headless.sh: no output_file found in the stream (raw session log: $RAW, claude exit $CLAUDE_EXIT)" >&2
  if [ "$CLAUDE_EXIT" -ne 0 ]; then
    echo "[wf-headless] status=error out=$OUT"
    exit 1
  fi
  echo "[wf-headless] status=no-result out=$OUT"
  exit 1
fi

cp "$OUTPUT_FILE" "$OUT"
echo "[wf-headless] status=ok out=$OUT"
