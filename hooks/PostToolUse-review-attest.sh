#!/usr/bin/env bash
# PostToolUse + PostToolUseFailure (Bash) - witness that a box command really ran in the review window (#631, #632).
# Records one JSON line per Bash call of the reviewer in one of two forms: `cd '<dir>' && <rest>` (<dir> quoted the way
# the engine writes it, each quote as '\'') or the bare command, the form Claude Code's worktree isolation guard leaves
# the reviewer for a git box (#662). The bare form is recorded only when the payload cwd equals $CLAUDE_PROJECT_DIR
# (trailing slashes removed on both sides; absent, empty, relative or different records nothing), under the key of the
# cd line built from that directory. cwd comes from session tracking (anthropics/claude-code#76708).
# It records when <dir>/.pipeline/review-nonce holds a nonce.
# The line goes to ${CLAUDE_PLUGIN_DATA}/review-attest-<nonce>.jsonl, outside the worktree: {nonce, agent_id,
# agent_type, tool_use_id, key, event, exit, ts}. key = first 16 hex of the sha256 of the exact engine line `cd '<dir>' && <command>`;
# the command text is never recorded. A call that executed and exited non-zero counts (event failure, first line of
# `error` = `Exit code N`); a call that never ran does not (bare error, failing cd, interrupt).
# The only agent_type accepted is lgtmgate:morgan in any casing (the engine gives Morgan lgtmgate:Morgan); any other
# string records nothing, the engine then shows review-record-empty. A call run in the background is not recorded.
# Resistance to forgery: the record resists a reviewer only under an enabled Bash sandbox with the unsandboxed retry
# denied (allowUnsandboxedCommands false, or dontAsk) and no excludedCommands pattern over a writing command;
# otherwise it only witnesses that a call ran.
# Prune: each append removes review-attest-*.jsonl files in the record directory older than 30 days (find -mtime +30); a run resumed later finds no record and demotes its bound boxes (fail closed) (#635).
# DEBT(#636): an unsandboxed retry of the reviewer's call is not detected.
# DEBT(#640): a foreground call moved to the background at its timeout may be recorded before it exits (payload unobserved).
# Never blocks: every failed test is a silent exit 0 with nothing written.
set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

jqi() { printf '%s' "$INPUT" | jq "$@" 2>/dev/null; }

[ "$(jqi -r '.tool_name // empty')" = "Bash" ] || exit 0
AGENT_TYPE="$(jqi -r '.agent_type // empty')" || exit 0
[ "$(printf '%s' "$AGENT_TYPE" | tr '[:upper:]' '[:lower:]')" = "lgtmgate:morgan" ] || exit 0
[ "$(jqi -r '((.tool_input.run_in_background // false) == false)')" = "true" ] || exit 0

EVENT="$(jqi -r '.hook_event_name // empty')"
EXIT_CODE=0
KIND=post
case "$EVENT" in
  PostToolUse) ;;
  PostToolUseFailure)
    [ "$(jqi -r '.is_interrupt // false')" != "true" ] || exit 0
    FIRST="$(jqi -r '(.error // "") | split("\n")[0]')" || exit 0
    [[ "$FIRST" =~ ^Exit\ code\ ([0-9]+)$ ]] || exit 0
    EXIT_CODE="${BASH_REMATCH[1]}"
    KIND=failure ;;
  *) exit 0 ;;
esac

# jq -j keeps the command byte for byte; the sentinel protects trailing newlines from the substitution.
CMD="$(jqi -j '.tool_input.command // empty'; printf x)" || exit 0
CMD="${CMD%x}"
[ -n "$CMD" ] || exit 0

# Two forms. Prefixed: cd '<dir>' && <rest>, <dir> decoded from the '\'' encoding. Bare: any other command, taken
# only when the payload cwd equals $CLAUDE_PROJECT_DIR; <dir> is then that value. A prefixed command that fails a test
# never falls back to the bare form.
ESC="'\\''"
DIR=""
REST=""
KEYSTR="$CMD"
S="${CMD#cd \'}"
if [ "$S" != "$CMD" ]; then
  while :; do
    case "$S" in *\'*) ;; *) exit 0 ;; esac
    DIR="$DIR${S%%\'*}"
    S="${S#*\'}"
    if [ "${S:0:3}" = "${ESC:1}" ]; then
      DIR="$DIR'"
      S="${S:3}"
    elif [ "${S:0:4}" = " && " ]; then
      REST="${S:4}"
      break
    else
      exit 0
    fi
  done
  [ -n "$REST" ] || exit 0
else
  CWDV="$(jqi -j '.cwd // empty'; printf x)" || exit 0
  CWDV="${CWDV%x}"
  PD="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$CWDV" ] && [ -n "$PD" ] || exit 0
  case "$CWDV" in /*) ;; *) exit 0 ;; esac
  case "$PD" in /*) ;; *) exit 0 ;; esac
  [[ "$CWDV" =~ [[:cntrl:]] ]] && exit 0
  [[ "$PD" =~ [[:cntrl:]] ]] && exit 0
  while [ "${#CWDV}" -gt 1 ] && [ "${CWDV%/}" != "$CWDV" ]; do CWDV="${CWDV%/}"; done
  while [ "${#PD}" -gt 1 ] && [ "${PD%/}" != "$PD" ]; do PD="${PD%/}"; done
  [ "$CWDV" = "$PD" ] || exit 0
  DIR="$CWDV"
  QT="'"
  QD="${DIR//$QT/$ESC}"
  KEYSTR="cd '$QD' && $CMD"
fi
case "$DIR" in /*) ;; *) exit 0 ;; esac
# a call whose cd could not run is not an executed command; the exit line cannot tell it from a failed command
[ -d "$DIR" ] && [ -x "$DIR" ] || exit 0

NF="$DIR/.pipeline/review-nonce"
[ -f "$NF" ] && [ ! -L "$NF" ] || exit 0
NONCE="$(head -c 17 "$NF" 2>/dev/null | head -n 1)" || exit 0
[[ "$NONCE" =~ ^[0-9a-f]{16}$ ]] || exit 0

if command -v shasum >/dev/null 2>&1; then
  KEY="$(printf '%s' "$KEYSTR" | shasum -a 256 | cut -c1-16)"
else
  KEY="$(printf '%s' "$KEYSTR" | sha256sum | cut -c1-16)"
fi
[[ "$KEY" =~ ^[0-9a-f]{16}$ ]] || exit 0

RD="${CLAUDE_PLUGIN_DATA:-}"
case "$RD" in /*) ;; *) exit 0 ;; esac
mkdir -p "$RD" 2>/dev/null || exit 0
[ -d "$RD" ] && [ -w "$RD" ] || exit 0

ENTRY="$(jq -cn --arg n "$NONCE" --arg a "$(jqi -r '.agent_id // empty')" --arg at "$AGENT_TYPE" \
  --arg t "$(jqi -r '.tool_use_id // empty')" --arg k "$KEY" --arg ev "$KIND" --argjson x "$EXIT_CODE" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{nonce:$n, agent_id:$a, agent_type:$at, tool_use_id:$t, key:$k, event:$ev, exit:$x, ts:$ts}' 2>/dev/null)" || exit 0
[ -n "$ENTRY" ] || exit 0
printf '%s\n' "$ENTRY" >> "$RD/review-attest-$NONCE.jsonl" 2>/dev/null
find "$RD" -maxdepth 1 -type f -name 'review-attest-*.jsonl' -mtime +30 -delete 2>/dev/null
exit 0
