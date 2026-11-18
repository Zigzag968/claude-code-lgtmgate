#!/usr/bin/env bash
# Regression test for hooks/PostToolUse-review-attest.sh (#631, #632).
# Temp dirs under $TMPDIR only, no network. Needs jq (skips with a note otherwise).
# P1, P2 and P3 are three real hook payloads captured by an agent of an earlier plan run with a nested `claude -p`
# (agent_type general-purpose there, the plugin was not loaded); transcript_path cut, cwd and the socket path elided.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)"
HOOK="$SCRIPT_DIR/PostToolUse-review-attest.sh"
REG="$SCRIPT_DIR/plugin-hooks.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP - jq not installed"
  echo "[review-attest-hooks] status=ok passed=0 failed=0"
  exit 0
fi

TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/review-attest-test.XXXXXX")"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass_count=$((pass_count + 1))
  else echo "FAIL - $1"; fail_count=$((fail_count + 1)); fi
}
skip() { echo "SKIP - $1"; }

P1='{"session_id":"caadcae1-364f-4f44-9c67-c8b1a3ed8be8","transcript_path":"<cut>","cwd":"<capture-dir>","prompt_id":"385a5a8a-25ca-47ad-b81e-87b35e958c61","permission_mode":"dontAsk","agent_id":"adc65da7059f12194","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"echo hello-631","description":"Echo hello-631 marker"},"tool_use_id":"toolu_01HjFJHzm9GfYApDE7wnqhBz","error":"Sandbox is enabled but failed to initialize: EPERM: operation not permitted, listen '"'"'<sock>'"'"'. Sandboxing is disabled for the rest of this session; restart to retry.","is_interrupt":false,"duration_ms":165}'
P2='{"session_id":"caadcae1-364f-4f44-9c67-c8b1a3ed8be8","transcript_path":"<cut>","cwd":"<capture-dir>","prompt_id":"385a5a8a-25ca-47ad-b81e-87b35e958c61","permission_mode":"dontAsk","agent_id":"adc65da7059f12194","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"ls /nonexistent-631-path","description":"List a nonexistent path to test error output"},"tool_use_id":"toolu_01DHEa19mWK2Epy8kQvfpj2A","error":"Exit code 1\nls: /nonexistent-631-path: No such file or directory","is_interrupt":false,"duration_ms":10}'
P3='{"session_id":"d75c0810-f8ba-4095-9697-8531c179ce4d","transcript_path":"<cut>","cwd":"<capture-dir>","prompt_id":"adba8c90-93e9-4559-af0b-1eda00a06bf6","permission_mode":"dontAsk","agent_id":"a54909b9d10eacff2","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo hello-631-ok","description":"Echo test string"},"tool_response":{"stdout":"hello-631-ok","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_014PELAJ85VkmgntX6VFgH26","duration_ms":9}'

NONCE="0123456789abcdef"

# fresh: a worktree dir D holding .pipeline/review-nonce, a record dir CPD
fresh() {
  D="$(mktemp -d "$WORK/wt.XXXXXX")"
  mkdir -p "$D/.pipeline"
  printf '%s\n' "$NONCE" > "$D/.pipeline/review-nonce"
  CPD="$(mktemp -d "$WORK/rec.XXXXXX")"
  REC="$CPD/review-attest-$NONCE.jsonl"
}
# the command the engine composes for a worktree directory
box_cmd() { local q="${D//\'/\'\\\'\'}"; printf "cd '%s' && %s" "$q" "$1"; }
# mk <payload> <agent|-> <command> [error|-] [bg-json|-]: replace only agent_type, tool_input.command (and error, run_in_background)
mk() {
  printf '%s' "$1" | jq -c --arg at "$2" --arg cmd "$3" --arg err "${4:--}" --argjson bg "${5:-null}" --arg hasbg "${5:+yes}" '
    .tool_input.command = $cmd
    | (if $at == "-" then del(.agent_type) else .agent_type = $at end)
    | (if $err != "-" then .error = $err else . end)
    | (if $hasbg == "yes" then .tool_input.run_in_background = $bg else . end)'
}
run_hook() { CLAUDE_PLUGIN_DATA="$CPD" bash "$HOOK"; }
rec_lines() { [ -f "$REC" ] && wc -l < "$REC" | tr -d ' ' || echo 0; }

# ---- [631] observed payload
fresh
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo hello-631-ok')" | run_hook
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '"\(.event)|\(.exit)|\(.nonce)|\(.agent_type)"' "$REC")" = "post|0|$NONCE|lgtmgate:Morgan" ] && ok=1 || ok=0
check "[631] observed payload: P3 (PostToolUse) with a cd prefix and Morgan is recorded with exit 0" "$ok"
fresh
mk "$P2" lgtmgate:Morgan "$(box_cmd 'ls /nonexistent-631-path')" | run_hook
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '"\(.event)|\(.exit)"' "$REC")" = "failure|1" ] && ok=1 || ok=0
check "[631] observed payload: P2 (Exit code 1) with a cd prefix and Morgan is recorded with exit 1" "$ok"
fresh
mk "$P1" lgtmgate:Morgan "$(box_cmd 'echo hello-631')" | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] observed payload: P1 (bare sandbox-initialisation failure) records nothing" "$ok"
fresh
for P in "$P1" "$P2" "$P3"; do printf '%s' "$P" | run_hook; done
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] observed payload: P1, P2 and P3 unchanged (general-purpose, no cd prefix) record nothing" "$ok"

# ---- [631] agent_type
for AT in lgtmgate:Morgan lgtmgate:morgan; do
  fresh
  mk "$P3" "$AT" "$(box_cmd 'echo ok')" | run_hook
  [ "$(rec_lines)" = "1" ] && [ "$(jq -r '.agent_type' "$REC")" = "$AT" ] && ok=1 || ok=0
  check "[631] agent_type: $AT is recorded, kept as received" "$ok"
done
for AT in morgan Morgan otherplugin:morgan general-purpose lgtmgate:probe lgtmgate:Nick xmorgan lgtmgate:morgan2 "" -; do
  fresh
  OUT="$(mk "$P3" "$AT" "$(box_cmd 'echo ok')" | run_hook 2>&1)"
  [ "$(rec_lines)" = "0" ] && [ -z "$OUT" ] && ok=1 || ok=0
  label="$AT"; [ -z "$label" ] && label="(empty)"; [ "$label" = "-" ] && label="(absent)"
  check "[631] agent_type: $label records nothing and prints nothing" "$ok"
done

# ---- [631] background
for BG in absent null false; do
  fresh
  case "$BG" in
    absent) mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | run_hook ;;
    null) mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" - null | run_hook ;;
    false) mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" - false | run_hook ;;
  esac
  [ "$(rec_lines)" = "1" ] && [ "$(jq -r '.exit' "$REC")" = "0" ] && ok=1 || ok=0
  check "[631] background: run_in_background $BG is recorded (exit 0)" "$ok"
done
for BG in true '"true"' 0; do
  fresh
  mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" - "$BG" | run_hook
  [ "$(rec_lines)" = "0" ] && ok=1 || ok=0
  check "[631] background: run_in_background $BG records nothing" "$ok"
done
fresh
mk "$P2" lgtmgate:Morgan "$(box_cmd 'ls /nonexistent-631-path')" - true | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] background: a failure event with run_in_background true records nothing" "$ok"

# ---- [631] record location
fresh
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | (cd "$D" && CLAUDE_PLUGIN_DATA="$CPD" bash "$HOOK")
FOUND="$(find "$D" -name 'review-attest*' 2>/dev/null | wc -l | tr -d ' ')"
[ -f "$REC" ] && [ "$FOUND" = "0" ] && ok=1 || ok=0
check "[631] record location: the record is in CLAUDE_PLUGIN_DATA and nothing named review-attest* is under the worktree or the cwd" "$ok"

# ---- key, exit, quote
fresh
CMD="$(box_cmd 'git status --porcelain')"
mk "$P3" lgtmgate:Morgan "$CMD" | run_hook
WANT="$(printf '%s' "$CMD" | shasum -a 256 | cut -c1-16)"
[ "$(jq -r '.key' "$REC")" = "$WANT" ] && ok=1 || ok=0
check "[631] key equals an independent shasum of the exact command" "$ok"
fresh
D="$(mktemp -d "$WORK/o'b.XXXXXX")"
mkdir -p "$D/.pipeline"; printf '%s\n' "$NONCE" > "$D/.pipeline/review-nonce"
CMD="$(box_cmd 'git status --porcelain')"
mk "$P3" lgtmgate:Morgan "$CMD" | run_hook
WANT="$(printf '%s' "$CMD" | shasum -a 256 | cut -c1-16)"
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '.key' "$REC")" = "$WANT" ] && ok=1 || ok=0
check "[631] a directory holding a quote is decoded and recorded, key of the exact command" "$ok"
V1="$(printf '%s' "cd '/w/x' && git status --porcelain" | shasum -a 256 | cut -c1-16)"
V2="$(printf '%s' "cd '/w/o'\\''b' && git status --porcelain" | shasum -a 256 | cut -c1-16)"
[ "$V1" = "ea2b8547dee67be2" ] && [ "$V2" = "aac05bf38d926eac" ] && ok=1 || ok=0
check "[631] the key formula matches the literal vectors of the flow suite" "$ok"
fresh
mk "$P2" lgtmgate:Morgan "$(box_cmd 'false')" 'Exit code 3
boom' | run_hook
[ "$(jq -r '.exit' "$REC")" = "3" ] && ok=1 || ok=0
check "[631] Exit code 3 is recorded as exit 3" "$ok"

# ---- a failing cd is not an executed command
fresh
mk "$P2" lgtmgate:Morgan "cd '$WORK/missing-dir' && ls" 'Exit code 1
cd: no such file' | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] a cd target that does not exist records nothing" "$ok"
fresh
: > "$WORK/a-file"
mk "$P2" lgtmgate:Morgan "cd '$WORK/a-file' && ls" 'Exit code 1
not a directory' | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] a cd target that is a regular file records nothing" "$ok"
if [ "$(id -u)" = "0" ]; then skip "[631] a directory without search permission (root)"; else
  fresh
  mkdir -p "$WORK/noexec/.pipeline"; printf '%s\n' "$NONCE" > "$WORK/noexec/.pipeline/review-nonce"; chmod 000 "$WORK/noexec"
  mk "$P2" lgtmgate:Morgan "cd '$WORK/noexec' && ls" 'Exit code 1
denied' | run_hook
  chmod 755 "$WORK/noexec"
  [ "$(rec_lines)" = "0" ] && ok=1 || ok=0
  check "[631] a cd target without search permission records nothing" "$ok"
fi

# ---- an unwritable record directory
fresh
: > "$WORK/rec-file"
OUT="$(mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | CLAUDE_PLUGIN_DATA="$WORK/rec-file" bash "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$WORK/rec-file/review-attest-$NONCE.jsonl" ] && ok=1 || ok=0
check "[631] CLAUDE_PLUGIN_DATA a regular file: exit 0, nothing recorded, no output" "$ok"
if [ "$(id -u)" = "0" ]; then skip "[631] mode-555 record directory (root)"; else
  fresh
  chmod 555 "$CPD"
  OUT="$(mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | run_hook 2>&1)"; RC=$?
  chmod 755 "$CPD"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(rec_lines)" = "0" ] && ok=1 || ok=0
  check "[631] a mode-555 record directory: exit 0, nothing recorded, no output" "$ok"
fi

# ---- other refusals
fresh
mk "$P2" lgtmgate:Morgan "$(box_cmd 'false')" | jq -c '.is_interrupt = true' | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] an interrupt records nothing" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "echo ok" | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] a command without the cd prefix whose cwd is not the project directory records nothing" "$ok"
fresh
rm "$D/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] a missing nonce file records nothing" "$ok"
fresh
printf 'not-a-nonce\n' > "$D/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | run_hook
[ "$(rec_lines)" = "0" ] && [ -z "$(ls "$CPD")" ] && ok=1 || ok=0
check "[631] a malformed nonce records nothing" "$ok"
fresh
printf '%s\n' "$NONCE" > "$WORK/real-nonce"
rm "$D/.pipeline/review-nonce"; ln -s "$WORK/real-nonce" "$D/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | run_hook
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[631] a review-nonce that is a symlink to a valid nonce records nothing" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | env -u CLAUDE_PLUGIN_DATA bash "$HOOK"
[ -z "$(ls "$CPD")" ] && ok=1 || ok=0
check "[631] an unset CLAUDE_PLUGIN_DATA records nothing" "$ok"
fresh
(cd "$WORK" && mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | CLAUDE_PLUGIN_DATA="relative-rec" bash "$HOOK")
[ ! -e "$WORK/relative-rec" ] && ok=1 || ok=0
check "[631] a relative CLAUDE_PLUGIN_DATA records nothing" "$ok"
fresh
JQ_BIN="$(command -v jq)"; BASH_BIN="$(command -v bash)"
NOJQ="$(mktemp -d "$WORK/nojq.XXXXXX")"
for t in cat head tr cut mkdir date shasum sha256sum printf; do p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$NOJQ/$t"; done
mk "$P3" lgtmgate:Morgan "$(box_cmd 'echo ok')" | PATH="$NOJQ" CLAUDE_PLUGIN_DATA="$CPD" "$BASH_BIN" "$HOOK"
[ "$(rec_lines)" = "0" ] && [ -x "$JQ_BIN" ] && ok=1 || ok=0
check "[631] no jq on PATH records nothing" "$ok"

# ---- [662] the bare form: the CLI refuses the cd prefix, the reviewer runs the command from the worktree
# withcwd <dir|-> sets the payload cwd (- deletes it); run_pd <dir> runs the hook with CLAUDE_PROJECT_DIR set to it
withcwd() { if [ "$1" = "-" ]; then jq -c 'del(.cwd)'; else jq -c --arg d "$1" '.cwd = $d'; fi; }
run_pd() { CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_DATA="$CPD" bash "$HOOK"; }
key_of() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }
BARE='git status --porcelain src test'
ISOLATION='This session is isolated in the worktree /w/x, but this command changes directory to a location computed at runtime before running git. Refusing to run it. Run the equivalent from /w/x without the redirect.'

fresh
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '.key' "$REC")" = "$(key_of "$(box_cmd "$BARE")")" ] && ok=1 || ok=0
check "[662] bare call from the worktree cwd is recorded under the key of the cd line" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "$(box_cmd "$BARE")" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '.key' "$REC")" = "$(key_of "$(box_cmd "$BARE")")" ] && ok=1 || ok=0
check "[662] prefixed call is still recorded under the same key" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D/" | run_pd "$D//"
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '.key' "$REC")" = "$(key_of "$(box_cmd "$BARE")")" ] && ok=1 || ok=0
check "[662] bare call with a trailing slash on cwd and on CLAUDE_PROJECT_DIR gets the same key" "$ok"
fresh
D="$(mktemp -d "$WORK/o'b.XXXXXX")"
mkdir -p "$D/.pipeline"; printf '%s\n' "$NONCE" > "$D/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '.key' "$REC")" = "$(key_of "$(box_cmd "$BARE")")" ] && ok=1 || ok=0
check "[662] bare call with a quote in the worktree path gets the key of the quoted cd line" "$ok"
fresh
mk "$P2" lgtmgate:Morgan "$BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "1" ] && [ "$(jq -r '"\(.event)|\(.exit)"' "$REC")" = "failure|1" ] && ok=1 || ok=0
check "[662] bare failure (Exit code 1) is recorded with exit 1" "$ok"
fresh
D1="$D"
D2="$(mktemp -d "$WORK/wt2.XXXXXX")"
mkdir -p "$D2/.pipeline"; printf '%s\n' "fedcba9876543210" > "$D2/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D2" | run_pd "$D2"
K2="$(jq -r '.key' "$CPD/review-attest-fedcba9876543210.jsonl")"
D="$D2"; W2="$(key_of "$(box_cmd "$BARE")")"
[ "$K2" = "$W2" ] && [ "$K2" != "$(key_of "$(printf "cd '%s' && %s" "$D1" "$BARE")")" ] && ok=1 || ok=0
check "[662] bare call from another worktree with its own nonce gets another key" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "cd '$WORK/missing-dir' && $BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] failing cd with cwd as the worktree records nothing and does not fall back to the bare branch" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "cd 'oops && $BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] malformed cd with cwd as the worktree records nothing and does not fall back to the bare branch" "$ok"
fresh
D2="$(mktemp -d "$WORK/wt2.XXXXXX")"
mkdir -p "$D2/.pipeline"; printf '%s\n' "$NONCE" > "$D2/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D2" | (cd "$D" && run_pd "$D")
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] hook run from the worktree with a payload cwd elsewhere records nothing" "$ok"
fresh
mk "$P2" lgtmgate:Morgan "$BARE" "$ISOLATION" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] PostToolUseFailure carrying the worktree isolation message records nothing" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D" | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_DATA="$CPD" bash "$HOOK"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] CLAUDE_PROJECT_DIR absent records nothing" "$ok"
fresh
D2="$(mktemp -d "$WORK/wt2.XXXXXX")"
mkdir -p "$D2/.pipeline"; printf '%s\n' "$NONCE" > "$D2/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D" | run_pd "$D2"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] CLAUDE_PROJECT_DIR different records nothing" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "1" ] && ok=1 || ok=0
check "[662] CLAUDE_PROJECT_DIR equal records the call" "$ok"
fresh
CTL="$D"$'\n'
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$CTL" | run_pd "$CTL"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] cwd with a control character records nothing" "$ok"
fresh
rm "$D/.pipeline/review-nonce"
mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] cwd without a nonce records nothing" "$ok"
fresh
ok=1
for C in relative/dir "" -; do
  mk "$P3" lgtmgate:Morgan "$BARE" | withcwd "$C" | run_pd "$D"
  [ "$(rec_lines)" = "0" ] || ok=0
done
check "[662] relative or empty or absent cwd records nothing" "$ok"
fresh
mk "$P3" general-purpose "$BARE" | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] agent general-purpose records nothing" "$ok"
fresh
mk "$P3" lgtmgate:Morgan "$BARE" - true | withcwd "$D" | run_pd "$D"
[ "$(rec_lines)" = "0" ] && ok=1 || ok=0
check "[662] run_in_background true records nothing" "$ok"

# ---- registration
jq -e '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("PostToolUse-review-attest.sh"))' "$REG" >/dev/null 2>&1 && ok=1 || ok=0
check "[631] plugin-hooks.json registers the review hook under PostToolUse (matcher Bash)" "$ok"
jq -e '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("PostToolUse-review-attest.sh"))' "$REG" >/dev/null 2>&1 && ok=1 || ok=0
check "[631] plugin-hooks.json registers the review hook under PostToolUseFailure (matcher Bash)" "$ok"
jq -e '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("PostToolUse-probe-attest.sh"))' "$REG" >/dev/null 2>&1 && ok=1 || ok=0
check "[631] the probe attest hook is still registered under PostToolUse" "$ok"

if [ "$fail_count" -eq 0 ]; then st=ok; else st=fail; fi
echo "[review-attest-hooks] status=$st passed=$pass_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
