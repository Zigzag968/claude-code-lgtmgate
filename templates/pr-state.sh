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
# -> {"now":"<ISO>","headRefName":..,"headRefOid":..,"bodyDigest":"<12 hex>","mergeable":..,
#     "mergeStateStatus":..,"lastCommitDate":..,"commitCount":N,"reviewCommentIds":["<id>",..],
#     "openIssues":[{"number":N,"createdAt":..,"url":..}]|null,"openIssuesTruncated":false}
# "now" comes from `date -u` HERE: the workflow script itself may not read the wall clock (harness ban on
# argless new Date(), claude-agent-pipeline#144/#135), and no LLM interprets it any more (incident #14).
# openIssues is read only with --since (open issues created at or after ISO). The scan keeps its
# server-side `created:>=` bound; REVIEWER_WINDOW_SCAN_SAFETY_LIMIT is a belt-and-suspenders ceiling:
# a result of exactly that many issues is the truncation signal -> openIssues null, openIssuesTruncated
# true (lgtmgate#18).
# Requires jq and gh. bash 3.2 compatible. Never uses rm.

REVIEWER_WINDOW_SCAN_SAFETY_LIMIT=1000

PR=""; WT=""; REPO=""; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}" ;;
    --wt) WT="${2:-}" ;;
    --repo) REPO="${2:-}" ;;
    --since) SINCE="${2:-}" ;;
    *) ;;
  esac
  [ $# -ge 2 ] && shift 2 || shift
done

main() {
  local now view body digest pr_json issues n
  local repo_args=""
  local issues_json="null" truncated="false"

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$WT" ] && cd "$WT"

  pr_json='{"headRefName":null,"headRefOid":null,"bodyDigest":null,"mergeable":null,"mergeStateStatus":null,"lastCommitDate":null,"commitCount":null,"reviewCommentIds":null}'

  if [ -n "$PR" ]; then
    if [ -n "$REPO" ]; then
      view="$(gh pr view "$PR" -R "$REPO" --json headRefName,headRefOid,body,mergeable,mergeStateStatus,commits,comments 2>/dev/null)"
    else
      view="$(gh pr view "$PR" --json headRefName,headRefOid,body,mergeable,mergeStateStatus,commits,comments 2>/dev/null)"
    fi
    if [ -n "$view" ] && printf '%s' "$view" | jq -e 'type == "object"' >/dev/null 2>&1; then
      body="$(printf '%s' "$view" | jq -r '.body // ""')"
      digest="$(printf '%s\n' "$body" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12)"
      pr_json="$(printf '%s' "$view" | jq -c --arg digest "$digest" '{
        headRefName: (.headRefName // null),
        headRefOid: (.headRefOid // null),
        bodyDigest: (if $digest == "" then null else $digest end),
        mergeable: (.mergeable // null),
        mergeStateStatus: (.mergeStateStatus // null),
        lastCommitDate: (((.commits // []) | last | .committedDate) // null),
        commitCount: (if .commits == null then null else (.commits | length) end),
        reviewCommentIds: (if .comments == null then null else [.comments[] | select(.isMinimized == false) | select((.body // "") | startswith("<!-- pipeline-review-round")) | .id] end)
      }' 2>/dev/null)"
      [ -n "$pr_json" ] || pr_json='{"headRefName":null,"headRefOid":null,"bodyDigest":null,"mergeable":null,"mergeStateStatus":null,"lastCommitDate":null,"commitCount":null,"reviewCommentIds":null}'
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
