#!/usr/bin/env bash
# fixture shared by the lead-merge tests (sourced, never executed): the fake gh and claude on $BASE/bin, setup/run/review_at/head_of/main_commit.
# Needs $ROOT and $BASE. Split from lead-merge-gate-cases.sh (#731) so tests/scripts/test-lead-merge-install.sh runs a real lead-merge without the gate cases.
SCRIPT="$ROOT/scripts/lead-merge.sh"
RUN_FLAGS=""
mkdir -p "$BASE/bin"
cat > "$BASE/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr checks --help" ]; then
  [ "${FAKE_HAS_REQUIRED:-1}" -eq 1 ] && echo "      --required   Only show checks that are required"
  exit 0
fi
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefOid*)
        stale="$(cat "$FAKE_LOG.stale" 2>/dev/null || echo "${FAKE_STALE:-0}")"
        if [ "$stale" -gt 0 ]; then
          echo $((stale - 1)) > "$FAKE_LOG.stale"
          echo '{"headRefOid":"0000000","statusCheckRollup":[]}'
        else
          echo "{\"headRefOid\":\"$(git --git-dir="$FAKE_REMOTE" rev-parse "$FAKE_BRANCH")\",\"statusCheckRollup\":[{\"name\":\"ci\"}]}"
        fi ;;
      *headRefName*) echo "$FAKE_BRANCH" ;;
      *) cat "$FAKE_BODY" ;;
    esac ;;
  "pr update-branch") echo "fake gh: update-branch must not be called" >&2; exit 98 ;;
  "pr checks")
    case "$*" in
      *--json*) # no-required-checks mode (#156): the head's checks as JSON; FAKE_PENDING polls report a pending check first
        pend="$(cat "$FAKE_LOG.pending" 2>/dev/null || echo "${FAKE_PENDING:-0}")"
        if [ "$pend" -gt 0 ]; then
          echo $((pend - 1)) > "$FAKE_LOG.pending"
          echo '[{"name":"ci","bucket":"pending"}]'
        else
          json="${FAKE_CHECKS_JSON:-}"; [ -n "$json" ] || json='[{"name":"ci","bucket":"pass"}]' # a `}` inside ${..:-..} ends it early
          echo "$json"
        fi
        exit 0 ;;
    esac
    case "$* ${FAKE_PROTECTION:-classic}" in
      *--required*none404|*--required*none403) # a base without required checks never reports one (#156)
        echo "no required checks reported on the 'feat/x' branch"; exit 1 ;;
    esac
    noreq="$(cat "$FAKE_LOG.noreq" 2>/dev/null || echo "${FAKE_NOREQ:-0}")"
    if [ "$noreq" -gt 0 ]; then
      echo $((noreq - 1)) > "$FAKE_LOG.noreq"
      echo "no required checks reported on the 'feat/x' branch"; exit 1
    fi
    [ "${FAKE_CHECKS_RC:-0}" -eq 0 ] || exit "$FAKE_CHECKS_RC" ;;
  "pr merge") [ -z "${FAKE_DIRTY_FILE:-}" ] || : > "$FAKE_DIRTY_FILE"; [ "${FAKE_MERGE_RC:-0}" -eq 0 ] || exit "$FAKE_MERGE_RC" ;; # FAKE_DIRTY_FILE: a file left untracked by the merge (#168)
  "api repos/o/r/branches/"*) # protection probe (#156); FAKE_PROTECTION = classic (default) | none404 | ruleset | none403 | error | ratelimit
    case "${FAKE_PROTECTION:-classic}" in
      classic) echo '{"strict":true,"contexts":["ci"],"checks":[{"context":"ci","app_id":null}]}' ;;
      none403) echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'
               echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1 ;;
      error) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
      ratelimit) echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1 ;;
      *) echo '{"message":"Branch not protected","status":"404"}'; echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  "api repos/o/r/rules/"*) # ruleset probe (#156): payload shape observed on a ruleset-protected branch
    case "${FAKE_PROTECTION:-classic}" in
      ruleset) echo '[{"type":"deletion","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":1},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"do_not_enforce_on_create":false,"required_status_checks":[{"context":"ci"}]},"ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":1}]' ;;
      none403) echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1 ;;
      *) echo '[]' ;;
    esac ;;
  "api repos/"*"/pulls?state=all"*) echo "${FAKE_PR_STATE:-MERGED}" ;; # post-merge cleanup lookup (#168): the PR state word of the branch
  "api repos/o/r/commits/"*) echo "${FAKE_HEAD_DATE:-2025-12-31T00:00:00Z}" ;; # --tick-from-review head date (#9)
  "api repos/o/r/pulls/7")
    case "$*" in
      *head.sha*) echo "${FAKE_HEAD_SHA:-$(git --git-dir="$FAKE_REMOTE" rev-parse "$FAKE_BRANCH")}" ;; # the real remote head; FAKE_HEAD_SHA = a lagging REST read (#157)
      *merged_at*) [ "${FAKE_MERGED:-true}" = true ] && echo "2026-10-01T00:00:00Z" || echo null ;;
      *) echo "${FAKE_MERGED:-true}" ;;
    esac ;;
  "api repos/o/r/issues/"*)
    inum="$(printf '%s' "${2##*/}" | sed -E 's/^0+([0-9])/\1/')" # the real API serves issue 30 for /issues/030
    [ -e "$FAKE_ISSUES/$inum.fail" ] && { echo "gh: HTTP 502" >&2; exit 1; } # <n>.fail: the REST read of issue <n> errors (#174)
    case "$*" in
      *comments*) cat "$FAKE_COMMENTS" 2>/dev/null || echo '[]' ;; # --tick-from-review (#9)
      *labels*) n="$inum"; cat "$FAKE_ISSUES/$n.labels" 2>/dev/null || echo "closed" ;; # declared-exception lookup (#122)
      *) n="$inum"; cat "$FAKE_ISSUES/$n" 2>/dev/null || echo open ;;
    esac ;;
  "api -X") case "$*" in
      *"PATCH repos/o/r/pulls/7"*) # --tick-from-review (#9): record the PATCH, update the served body
        all="$*"; f="${all##*body=@}"; cp "$f" "$FAKE_BODY" && cp "$f" "$FAKE_LOG.patch" ;;
      *"issues/"*) ;; *) echo "fake gh: unexpected: $*" >&2; exit 99 ;; esac ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 99 ;;
esac
exit 0
FAKE
chmod +x "$BASE/bin/gh"
# fake claude (#731): lead-merge now updates the local install after a bump, so no run may reach the real CLI. `plugin list --json` prints
# $FAKE_CLAUDE_LIST (default: no install), `plugin update ...` is logged to $FAKE_CLAUDE_LOG and exits $FAKE_UPDATE_RC (default 0).
cat > "$BASE/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_CLAUDE_LOG:-}" ] || echo "$PWD :: $*" >> "$FAKE_CLAUDE_LOG"
case "$*" in
  "plugin list --json") if [ -n "${FAKE_CLAUDE_LIST:-}" ]; then cat "$FAKE_CLAUDE_LIST"; else echo '[]'; fi ;;
  "plugin update "*) exit "${FAKE_UPDATE_RC:-0}" ;;
  *) echo "fake claude: unexpected: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$BASE/bin/claude"

# fixture: bare origin + working clone on feat/x one commit ahead of main
setup() {
  local d="$BASE/$1"
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  ( cd "$d/work" && git config user.email t@t && git config user.name t \
    && mkdir -p .claude-plugin workflows \
    && printf '{\n  "name": "lgtmgate",\n  "version": "0.8.80",\n  "x": 1\n}\n' > .claude-plugin/plugin.json \
    && printf "const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' }\n" > workflows/deliver-pipeline.js \
    && git add -A && git commit -qm init && git push -q origin HEAD:main \
    && git checkout -q -b feat/x && echo change > f.txt && git add -A && git commit -qm feat \
    && git push -q origin feat/x ) >/dev/null 2>&1
  echo "$d"
}

review_at() { # <dir> <sha>: $d/comments.json = one multi-line verdict whose marker carries <sha> (pages concatenated like gh --paginate)
  printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- pipeline-review-round pr=7 sha=%s -->\\nLGTM\\nevery box proven"}]\n' "$2" > "$1/comments.json"
}
head_of() { git --git-dir="$1/origin.git" rev-parse feat/x; }
run() { # <dir> <body-file> [checks-rc]; serves a review on the CURRENT head unless $d/comments.keep pins the fixture (#157)
  local d="$1"
  [ -e "$d/comments.keep" ] || review_at "$d" "$(head_of "$d")"
  : > "$d/log"; : > "$d/pushes"; rm -f "$d/log.stale" "$d/log.patch" "$d/log.noreq" "$d/log.pending"; mkdir -p "$d/issues"
  [ -n "${FAKE_STALE:-}" ] && echo "$FAKE_STALE" > "$d/log.stale"
  printf '#!/bin/sh\necho "$1" >> "%s/pushes"\n' "$d" > "$d/origin.git/hooks/update"; chmod +x "$d/origin.git/hooks/update"
  ( cd "${RUN_CWD:-$d/work}" && PATH="$BASE/bin:$PATH" FAKE_LOG="$d/log" FAKE_BODY="$2" FAKE_BRANCH=feat/x \
      FAKE_REMOTE="$d/origin.git" FAKE_CHECKS_RC="${3:-0}" FAKE_ISSUES="$d/issues" FAKE_COMMENTS="$d/comments.json" LEAD_MERGE_POLL_SLEEP=0 bash "$SCRIPT" 7 -R o/r $RUN_FLAGS ) > "$d/out" 2>&1
}
# push a commit to origin/main from a second clone: main_commit <dir> <bump 0|1> <file> <content>
main_commit() {
  local d="$1" bump="$2"
  [ -d "$d/other" ] || git clone -q "$d/origin.git" "$d/other" 2>/dev/null
  ( cd "$d/other" && git config user.email t@t && git config user.name t && git checkout -q main \
    && if [ "$bump" = 1 ]; then
         sed -i.bak 's/"version": "0.8.80"/"version": "0.8.81"/' .claude-plugin/plugin.json
         sed -i.bak "s/version: '0.8.80'/version: '0.8.81'/" workflows/deliver-pipeline.js; rm -f ./*.bak .claude-plugin/*.bak workflows/*.bak
       fi \
    && printf '%s\n' "$4" > "$3" && git add -A && git commit -qm "main: $3" && git push -q origin main ) >/dev/null 2>&1
}

