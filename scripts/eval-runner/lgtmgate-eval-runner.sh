#!/bin/bash
# lgtmgate eval runner: LaunchAgent job body (#81). bash 3.2 safe. Run by launchd on WatchPaths, never by a Claude session.
# - Env (set by the plist): SPOOL, REPO_URL (default: the public repo). Optional: WORK_DIR (default ~/Library/Caches/lgtmgate/eval-work).
# - Everything the job touches lives on the boot disk: macOS TCC blocks a launchd job from reading /Volumes/*.
# - Spool: inbox/<id>.trigger -> running/ -> done/<id>.{trigger,log,rc,summary}.
# - Trigger = ONE line: a git branch name of the repo, then optional space-separated case names. Untrusted data.
# - Each trigger: fresh shallow clone of the branch into WORK_DIR/<id>, eval runs there, clone deleted after.
# - rc: 0 ok, 64 refused trigger, 65 Keychain read failed, 66 docker missing, 67 clone failed, other = eval exit code.
set -u
set +x

if [ -z "${SPOOL:-}" ]; then
  echo "lgtmgate-eval-runner: SPOOL must be set (see scripts/eval-runner/install.sh)" >&2
  exit 2
fi
REPO_URL="${REPO_URL:-https://github.com/Zigzag968/claude-code-lgtmgate.git}"
WORK_DIR="${WORK_DIR:-$HOME/Library/Caches/lgtmgate/eval-work}"

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

valid_branch() { # valid_branch <name>: charset, no "..", no leading "-", <= 100 chars
  case "$1" in
    ""|-*|*..*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  [ "${#1}" -le 100 ]
}

# remove_clone <dir>: only a non-empty id directly under WORK_DIR
remove_clone() {
  case "$1" in
    "$WORK_DIR"/?*) rm -rf "$1" ;;
  esac
}

process() {
  local f="$1" id line branch cases token rc clone sha
  id="$(basename "$f" .trigger)"
  mv "$f" "$SPOOL/running/$id.trigger" || return 0
  line=""
  IFS= read -r line < "$SPOOL/running/$id.trigger" || true
  branch="${line%% *}"
  cases=""
  case "$line" in *" "*) cases="${line#* }" ;; esac

  valid_branch "$branch" || { refuse "$id" 64 "invalid branch name"; return 0; }

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

  clone="$WORK_DIR/$id"
  mkdir -p "$WORK_DIR" || { refuse "$id" 67 "cannot create WORK_DIR"; return 0; }
  remove_clone "$clone"
  if ! git clone --quiet --depth 1 --branch "$branch" "$REPO_URL" "$clone" > "$SPOOL/running/$id.clone.err" 2>&1; then
    { echo "lgtmgate-eval-runner: refused: git clone failed for branch $branch"; cat "$SPOOL/running/$id.clone.err"; } > "$SPOOL/done/$id.log"
    rm -f "$SPOOL/running/$id.clone.err"
    remove_clone "$clone"
    finish "$id" 67
    return 0
  fi
  rm -f "$SPOOL/running/$id.clone.err"
  sha="$(git -C "$clone" rev-parse HEAD 2>/dev/null || echo unknown)"

  [ -f "$clone/scripts/run-probe-evals-docker.sh" ] || { remove_clone "$clone"; refuse "$id" 64 "scripts/run-probe-evals-docker.sh missing on branch $branch"; return 0; }
  command -v docker >/dev/null 2>&1 || { remove_clone "$clone"; refuse "$id" 66 "docker not found on PATH"; return 0; }

  token="$(security find-generic-password -a "${USER:-$(id -un)}" -s lgtmgate-eval-token -w 2>/dev/null)" || token=""
  if [ -z "$token" ]; then
    remove_clone "$clone"
    refuse "$id" 65 "Keychain item lgtmgate-eval-token not found or locked; see docs (header of scripts/run-probe-evals.sh)"
    return 0
  fi

  echo "== commit $sha branch $branch" > "$SPOOL/done/$id.log"
  ( cd "$clone" && CLAUDE_CODE_OAUTH_TOKEN="$token" bash scripts/run-probe-evals-docker.sh "$@" ) >> "$SPOOL/done/$id.log" 2>&1
  rc=$?
  token=""
  remove_clone "$clone"
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
