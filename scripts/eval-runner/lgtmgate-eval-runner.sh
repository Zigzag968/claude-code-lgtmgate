#!/bin/bash
# lgtmgate eval runner: LaunchAgent job body (#81). bash 3.2 safe. Run by launchd on WatchPaths, never by a Claude session.
# - Env (set by the plist): SPOOL, ALLOWED_ROOT.
# - Spool: inbox/<id>.trigger -> running/ -> done/<id>.{trigger,log,rc,summary}.
# - Trigger = ONE line: absolute worktree path, then optional space-separated case names. Untrusted data.
# - rc: 0 ok, 64 refused trigger, 65 Keychain read failed, 66 docker missing, other = eval exit code.
set -u
set +x

if [ -z "${SPOOL:-}" ] || [ -z "${ALLOWED_ROOT:-}" ]; then
  echo "lgtmgate-eval-runner: SPOOL and ALLOWED_ROOT must be set (see scripts/eval-runner/install.sh)" >&2
  exit 2
fi

PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
export PATH

mkdir -p "$SPOOL/inbox" "$SPOOL/running" "$SPOOL/done" || exit 2
LOCK="$SPOOL/lock"

acquire_lock() {
  local other
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
  other="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK"   # stale lock (owner gone)
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
  return 1
}

acquire_lock || exit 0
trap 'rm -rf "$LOCK"' EXIT

# finish <id> <rc> : atomically publish rc last, after log and summary
finish() {
  local id="$1" rc="$2"
  grep '^== ' "$SPOOL/done/$id.log" > "$SPOOL/done/$id.summary" 2>/dev/null || : > "$SPOOL/done/$id.summary"
  echo "$rc" > "$SPOOL/done/$id.rc.tmp" && mv "$SPOOL/done/$id.rc.tmp" "$SPOOL/done/$id.rc"
  mv "$SPOOL/running/$id.trigger" "$SPOOL/done/$id.trigger" 2>/dev/null || true
}

refuse() { # refuse <id> <rc> <reason>
  echo "lgtmgate-eval-runner: refused: $3" > "$SPOOL/done/$1.log"
  finish "$1" "$2"
}

process() {
  local f="$1" id line wt real allowed cases token rc
  id="$(basename "$f" .trigger)"
  mv "$f" "$SPOOL/running/$id.trigger" || return 0
  line=""
  IFS= read -r line < "$SPOOL/running/$id.trigger" || true
  wt="${line%% *}"
  cases=""
  case "$line" in *" "*) cases="${line#* }" ;; esac

  [ -n "$wt" ] && [ -d "$wt" ] || { refuse "$id" 64 "worktree path missing or not a directory"; return 0; }
  real="$(cd -P "$wt" 2>/dev/null && pwd -P)" || { refuse "$id" 64 "cannot resolve worktree path"; return 0; }
  allowed="$(cd -P "$ALLOWED_ROOT" 2>/dev/null && pwd -P)" || { refuse "$id" 64 "ALLOWED_ROOT not resolvable"; return 0; }
  case "$real/" in
    "$allowed"/?*) ;;
    *) refuse "$id" 64 "worktree is not under ALLOWED_ROOT"; return 0 ;;
  esac
  git -C "$real" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { refuse "$id" 64 "not a git worktree"; return 0; }
  [ -f "$real/scripts/run-probe-evals-docker.sh" ] || { refuse "$id" 64 "scripts/run-probe-evals-docker.sh missing"; return 0; }

  # case names: strict charset, then word-split without globbing
  set -f
  # shellcheck disable=SC2086
  set -- $cases
  set +f
  for c in "$@"; do
    case "$c" in
      *[!A-Za-z0-9._-]*|"") refuse "$id" 64 "invalid case name"; return 0 ;;
    esac
  done

  command -v docker >/dev/null 2>&1 || { refuse "$id" 66 "docker not found on PATH"; return 0; }

  token="$(security find-generic-password -a "${USER:-$(id -un)}" -s lgtmgate-eval-token -w 2>/dev/null)" || token=""
  if [ -z "$token" ]; then
    refuse "$id" 65 "Keychain item lgtmgate-eval-token not found or locked; see docs (header of scripts/run-probe-evals.sh)"
    return 0
  fi

  ( cd "$real" && CLAUDE_CODE_OAUTH_TOKEN="$token" bash scripts/run-probe-evals-docker.sh "$@" ) > "$SPOOL/done/$id.log" 2>&1
  rc=$?
  token=""
  finish "$id" "$rc"
}

# loop until the inbox is empty: triggers dropped during a run are caught here
while :; do
  found=0
  for f in "$SPOOL"/inbox/*.trigger; do
    [ -f "$f" ] || continue
    found=1
    process "$f"
  done
  [ "$found" -eq 1 ] || break
done
exit 0
