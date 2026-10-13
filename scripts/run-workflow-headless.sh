#!/usr/bin/env bash
# run-workflow-headless.sh (#54, D12; headless profile #245) — the deterministic, non-model-mediated
# proof channel for a Workflow-tool run in --print mode, run with a no-prompt permission profile.
# Per P4 (this repo, 2026-08-22): the
# tool_result in --print mode is only "Workflow launched in background. Task ID: …" —
# the real return arrives on a LATER task_notification stream-json event carrying
# output_file: <abs path>, itself holding {summary, logs[], result{...},
# workflowProgress[], totalTokens}. This script runs the session, scans the
# stream-json output for that event, and COPIES output_file to --out in the SAME
# invocation — the source is a session tmp path, never hand it across Bash calls
# (see .claude/rules/git-workflow.md "Cross-mode file handoff").
#
# Usage: printf '%s' '<prompt>' | bash scripts/run-workflow-headless.sh \
#          [--plugin-dir <path>] [--settings <file>] --max-turns <n> --max-budget-usd <x> --out <path>
#
# Profile (docs/headless.md): the session runs with --permission-mode dontAsk and
# --permission-prompts none, so a tool outside the allow list is denied, never asked. The allow
# list lives in the settings file only (default: headless-settings.json next to this script).
# Both caps are required. Refused (exit 2, cause on stderr): any bypass flag, any --permission-mode
# (the mode is fixed), a missing settings file, a settings file naming a bypass mode, a missing or
# non-numeric cap.
#
# The prompt MUST arrive on stdin — a trailing prompt arg after --allowed-tools
# errors "Input must be provided" (recorded on claude-agent-pipeline#50).
#
# Stdout: [wf-headless] stream-log=<path> (before the run), then the trailer, always last:
#   [wf-headless] status=<ok|no-result|error> out=<path>
# A denial can exit 0: the status is judged from the output_file, never from the exit code.

set -u

OUT=""
SETTINGS=""
MAX_TURNS=""
MAX_BUDGET=""
REFUSAL=""
PLUGIN_DIR_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --plugin-dir) PLUGIN_DIR_ARGS+=(--plugin-dir "${2:-}"); { shift; [ $# -gt 0 ] && shift; } ;;
    --settings) SETTINGS="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --max-turns) MAX_TURNS="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --max-budget-usd) MAX_BUDGET="${2:-}"; { shift; [ $# -gt 0 ] && shift; } ;;
    --dangerously-skip-permissions|--allow-dangerously-skip-permissions)
      REFUSAL="$1 is refused: the headless profile never bypasses permissions (docs/headless.md)"; shift ;;
    --permission-mode)
      REFUSAL="--permission-mode is refused: the mode is fixed to dontAsk (docs/headless.md)"; { shift; [ $# -gt 0 ] && shift; } ;;
    *) echo "run-workflow-headless.sh: unknown arg '$1'" >&2; shift ;;
  esac
done

refuse() {
  echo "run-workflow-headless.sh: $1" >&2
  echo "[wf-headless] status=error out=$OUT"
  exit 2
}

if [ -z "$OUT" ]; then
  echo "run-workflow-headless.sh: --out <path> is required" >&2
  echo "[wf-headless] status=error out="
  exit 2
fi

[ -z "$REFUSAL" ] || refuse "$REFUSAL"

if [ -z "$SETTINGS" ]; then
  SETTINGS="$(dirname "$0")/headless-settings.json"
fi
[ -f "$SETTINGS" ] || refuse "settings file '$SETTINGS' is missing (see docs/headless.md)"
if grep -Eq 'bypassPermissions|skipDangerousModePermissionPrompt|dangerously' "$SETTINGS"; then
  refuse "settings file '$SETTINGS' names a bypass mode: refused (docs/headless.md)"
fi
[ -n "$MAX_TURNS" ] || refuse "--max-turns <n> is required (docs/headless.md)"
[ -n "$MAX_BUDGET" ] || refuse "--max-budget-usd <x> is required (docs/headless.md)"
case "$MAX_TURNS" in ''|*[!0-9]*) refuse "--max-turns must be a positive integer, got '$MAX_TURNS'" ;; esac
case "$MAX_BUDGET" in ''|*[!0-9.]*|.|*.*.*) refuse "--max-budget-usd must be a number, got '$MAX_BUDGET'" ;; esac

RAW="$(mktemp "${TMPDIR:-/tmp}/wf-headless-raw.XXXXXXXX")"
echo "[wf-headless] stream-log=$RAW"

# bash 3.2 (macOS /usr/bin/env bash) trips 'set -u' on an empty array expansion — same trap
# documented in scripts/provision-worktree.sh:152. Guarded form => zero words when unset.
claude --print --output-format stream-json --verbose --model claude-sonnet-5 \
  --permission-mode dontAsk --permission-prompts none \
  --max-turns "$MAX_TURNS" --max-budget-usd "$MAX_BUDGET" --settings "$SETTINGS" \
  ${PLUGIN_DIR_ARGS[@]+"${PLUGIN_DIR_ARGS[@]}"} > "$RAW" 2>&1
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
