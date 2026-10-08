#!/usr/bin/env bash
# pr-state.sh — the review-phase PR-state reads of the engine, as ONE script (E2.5, #84).
#
# Run through probe-run.cjs (--parser pr-state, --no-reuse: live state): the script EXECUTES the reads,
# an LLM only copies the PROBE line, a hook attests it. Always exits 0 and prints exactly ONE compact
# JSON line on stdout (nothing else on stdout, stderr silenced). A read that fails is reported as null,
# never as an error. Read-only: writes nothing to the PR or the issues.
#
# Usage:
#   bash pr-state.sh --pr N [--wt DIR] [--repo OWNER/REPO] [--since ISO]
#
# -> {"now":"<ISO>","headRefName":..,"headRefOid":..,"bodyDigest":"<12 hex>","acceptanceChecked":[N,..]|null,
#     "decisionLog":["- round N — ..",..]|null,"mergeable":..,"mergeStateStatus":..,"lastCommitDate":..,"commitCount":N,"ciState":"green|failing|pending|none"|null,"ciChecks":{"<check name>":"green|failing|pending"}|null,"reviewCommentIds":["<id>",..],"files":["<path>",..]|null,
#     "openIssues":[{"number":N,"createdAt":..,"url":..}]|null,"openIssuesTruncated":false}
# "now" comes from `date -u` HERE: the workflow script itself may not read the wall clock (harness ban on
# argless new Date(), claude-agent-pipeline#144/#135), and no LLM interprets it any more (incident #14).
# acceptanceChecked (#183): the ids of the acceptance boxes ticked in the body (templates/pr-body-splice.cjs, op checked: the
# same fence-aware block reader the tick uses); null when the body or node could not be read. The engine reads it for the
# human-gate boxes only: a gate is settled iff its id is listed here (a person ticked it); any other box needs a proof of the round.
# ciState (#184): the state of EVERY check on the PR head, read from the statusCheckRollup of the same `gh pr view` call (no new
# call, no new flag). Per entry: a StatusContext reads its `state`, a CheckRun its `conclusion` once `status` is COMPLETED, else
# PENDING. Only the LATEST entry per check counts (the rollup keeps superseded runs, `gh pr checks` drops them): per (CheckRun name,
# workflowName) the greatest startedAt, an entry with none (or the zero date of a queued run) being the newest attempt; a
# StatusContext per context by createdAt, else the last occurrence. Any value outside SUCCESS/NEUTRAL/SKIPPED/PENDING/EXPECTED -> "failing"; else a PENDING/EXPECTED one -> "pending";
# else "green". No check on the head -> "none"; the rollup absent (gh failed) -> null. The engine's ready gate reads it.
# ciChecks (#184): the same per-entry classification kept PER CHECK, {"<name>": "green|failing|pending"} (CheckRun .name,
# StatusContext .context; SKIPPED/NEUTRAL are green; one name under two workflows: the worst of the two latest entries). {} when the head has no
# check, null when the rollup is absent. The engine reads it to judge only the checks the repo's config.ciChecks names (an
# optional check, CodeQL for one, must not hold the ready gate); the command line stays the same, so no recorded cmd= changes.
# files (#229): the repo-relative paths the PR changes, from the `files` field of the same `gh pr view` call (no new call, the command
# line is unchanged). gh caps that field at 100 entries, so a list of 100 or more may be truncated and is reported null (the engine
# then keeps its previous behaviour); null too when gh failed. The engine cross-checks a reviewer's committedInPr claim against it.
# decisionLog (#164): the round lines (`- round ...`, trimmed) of the real decision-log block of the body (templates/pr-body-splice.cjs,
# op entries); [] when the body holds no block; null when the body or node could not be read. The engine seeds its log from it,
# so a relaunch at entryStage review keeps the rounds of the earlier runs in the ONE block.
# openIssues is read only with --since (open issues created at or after ISO). The scan keeps its
# server-side `created:>=` bound; REVIEWER_WINDOW_SCAN_SAFETY_LIMIT is a belt-and-suspenders ceiling:
# a result of exactly that many issues is the truncation signal -> openIssues null, openIssuesTruncated
# true (lgtmgate#18).
# Requires jq, gh and node (acceptanceChecked). bash 3.2 compatible. Never uses rm.

REVIEWER_WINDOW_SCAN_SAFETY_LIMIT=1000
SD="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

PR=""; WORKTREE=""; REPO=""; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}" ;;
    --wt) WORKTREE="${2:-}" ;;
    --repo) REPO="${2:-}" ;;
    --since) SINCE="${2:-}" ;;
    *) ;;
  esac
  [ $# -ge 2 ] && shift 2 || shift
done

main() {
  local now view body digest pr_json issues n checked ac_json dl dl_json
  local repo_args=""
  local issues_json="null" truncated="false"

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$WORKTREE" ] && cd "$WORKTREE"

  pr_json='{"headRefName":null,"headRefOid":null,"bodyDigest":null,"acceptanceChecked":null,"decisionLog":null,"mergeable":null,"mergeStateStatus":null,"lastCommitDate":null,"commitCount":null,"ciState":null,"ciChecks":null,"reviewCommentIds":null,"files":null}'

  if [ -n "$PR" ]; then
    if [ -n "$REPO" ]; then
      view="$(gh pr view "$PR" -R "$REPO" --json headRefName,headRefOid,body,mergeable,mergeStateStatus,commits,comments,statusCheckRollup,files 2>/dev/null)"
    else
      view="$(gh pr view "$PR" --json headRefName,headRefOid,body,mergeable,mergeStateStatus,commits,comments,statusCheckRollup,files 2>/dev/null)"
    fi
    if [ -n "$view" ] && printf '%s' "$view" | jq -e 'type == "object"' >/dev/null 2>&1; then
      body="$(printf '%s' "$view" | jq -r '.body // ""')"
      digest="$(printf '%s\n' "$body" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12)"
      ac_json=null
      if checked="$(printf '%s' "$body" | node "$SD/pr-body-splice.cjs" checked - 2>/dev/null)"; then
        ac_json="$(printf '%s\n' "$checked" | jq -Rc 'split(",") | map(select(length > 0) | tonumber)' 2>/dev/null)" || ac_json=null
        [ -n "$ac_json" ] || ac_json=null
      fi
      dl_json=null
      if dl="$(printf '%s' "$body" | node "$SD/pr-body-splice.cjs" entries - 2>/dev/null)"; then
        dl_json="$(printf '%s\n' "$dl" | jq -c 'if type == "array" and all(.[]; type == "string") then . else null end' 2>/dev/null)" || dl_json=null
        [ -n "$dl_json" ] || dl_json=null
      fi
      pr_json="$(printf '%s' "$view" | jq -c --arg digest "$digest" --argjson ac "$ac_json" --argjson dl "$dl_json" 'def entry_state: if .__typename == "StatusContext" then (.state // "PENDING") elif .status == "COMPLETED" then (.conclusion // "PENDING") else "PENDING" end;
      def entry_class: if IN("SUCCESS","NEUTRAL","SKIPPED") then "green" elif IN("PENDING","EXPECTED") then "pending" else "failing" end;
      def latest_entries: to_entries | map(.value + {i: .key}) | group_by([.__typename == "StatusContext", (if .__typename == "StatusContext" then .context else .name end), (.workflowName // "")]) | map(sort_by([((.startedAt // .createdAt // "") as $t | if $t == "" or ($t | startswith("0001")) then "9999" else $t end), .i]) | last);
      {
        headRefName: (.headRefName // null),
        headRefOid: (.headRefOid // null),
        bodyDigest: (if $digest == "" then null else $digest end),
        acceptanceChecked: $ac,
        decisionLog: $dl,
        mergeable: (.mergeable // null),
        mergeStateStatus: (.mergeStateStatus // null),
        lastCommitDate: (((.commits // []) | last | .committedDate) // null),
        commitCount: (if .commits == null then null else (.commits | length) end),
        ciState: (if .statusCheckRollup == null then null elif (.statusCheckRollup | length) == 0 then "none" else (.statusCheckRollup | latest_entries | map(entry_state)) as $s | if any($s[]; IN("SUCCESS","NEUTRAL","SKIPPED","PENDING","EXPECTED") | not) then "failing" elif any($s[]; IN("PENDING","EXPECTED")) then "pending" else "green" end end),
        ciChecks: (if .statusCheckRollup == null then null else (.statusCheckRollup | latest_entries | map({k: (if .__typename == "StatusContext" then .context else .name end), v: (entry_state | entry_class)}) | map(select(.k | type == "string")) | group_by(.k) | map({key: .[0].k, value: (if any(.[]; .v == "failing") then "failing" elif any(.[]; .v == "pending") then "pending" else "green" end)}) | from_entries) end),
        reviewCommentIds: (if .comments == null then null else [.comments[] | select(.isMinimized == false) | select((.body // "") | startswith("<!-- pipeline-review-round")) | .id] end),
        files: (if .files == null then null elif (.files | length) >= 100 then null else [.files[] | .path] end)
      }' 2>/dev/null)"
      [ -n "$pr_json" ] || pr_json='{"headRefName":null,"headRefOid":null,"bodyDigest":null,"acceptanceChecked":null,"decisionLog":null,"mergeable":null,"mergeStateStatus":null,"lastCommitDate":null,"commitCount":null,"ciState":null,"ciChecks":null,"reviewCommentIds":null,"files":null}'
    fi
  fi

  if [ -n "$SINCE" ]; then
    [ -n "$REPO" ] && repo_args="$REPO"
    if [ -n "$repo_args" ]; then
      issues="$(gh issue list --state open --search "created:>=$SINCE" -R "$repo_args" --limit "$REVIEWER_WINDOW_SCAN_SAFETY_LIMIT" --json number,createdAt,url 2>/dev/null)"
    else
      issues="$(gh issue list --state open --search "created:>=$SINCE" --limit "$REVIEWER_WINDOW_SCAN_SAFETY_LIMIT" --json number,createdAt,url 2>/dev/null)"
    fi
    if [ -n "$issues" ] && n="$(printf '%s' "$issues" | jq -e 'if type == "array" then length else empty end' 2>/dev/null)"; then
      if [ "$n" -ge "$REVIEWER_WINDOW_SCAN_SAFETY_LIMIT" ]; then
        truncated="true"
      else
        issues_json="$(printf '%s' "$issues" | jq -c '[.[] | {number, createdAt, url}]' 2>/dev/null)"
        [ -n "$issues_json" ] || issues_json="null"
      fi
    fi
  fi

  jq -nc --arg now "$now" --argjson pr "$pr_json" --argjson oi "$issues_json" --argjson tr "$truncated" \
    '{now:$now} + $pr + {openIssues:$oi, openIssuesTruncated:$tr}'
}

main 2>/dev/null
exit 0
