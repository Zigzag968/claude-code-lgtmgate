#!/usr/bin/env bash
# PreToolUse(Bash) — see scripts/backlog_guard.py for the full rules:
#   deny (exit 2): (1) RAW gh label writes that touch an owned-axis label, in the backlog modes that route
#                  every write through the plugin (propose, write-supervised); (2) a bare `gh issue create`
#                  in write-supervised/free (opt-out `guard_issue_create: false`); (3) any raw gh/gh-api label
#                  write naming a declared axis with a value NOT in .claude/backlog.yml, in every mode but off;
#   ask  (exit 0, permissionDecision "ask"): OPT-IN through `apply_prompt: ask` in .claude/backlog.yml (default
#                  silent). When enabled, an agent command that runs the plugin CLI with an apply subcommand
#                  (label-sync/catchup/rollback --apply, or rollback.sh --apply), in every mode except off.
#
# INERT WITHOUT CONFIG: the very first thing this script does is test for the repo's .claude/backlog.yml
# (resolved like the lgtmgate hooks resolve their config: CLAUDE_PROJECT_DIR, else the cwd). No file
# means exit 0 before stdin is read, before jq, before python: a repo that never opted in pays nothing.
[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/backlog.yml" ] || exit 0

set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

# Fast exit unless the command mentions gh as a word, the plugin CLI, or its generated rollback wrapper.
printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])gh([^[:alnum:]_-]|$)|backlog_cli\.py|rollback\.sh' || exit 0

reason="$(python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" guard --command "$cmd" 2>/dev/null)"
rc=$?
# 0 = allow; 1 = deny; 3 = ask the human; anything else (crash, python missing) = fail open.
if [ "$rc" -eq 3 ]; then
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
fi
[ "$rc" -eq 1 ] || exit 0

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
printf '%s\n' "$reason" >&2
exit 2
