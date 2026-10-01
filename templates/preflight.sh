#!/usr/bin/env bash
# preflight.sh — the grouped pre-Dev / branch-guard reads of the engine, as ONE script (E2.4, #83).
#
# Run through probe-run.cjs (--parser preflight): the script EXECUTES the reads, an LLM only copies the
# PROBE line, a hook attests it. Always exits 0 and prints exactly ONE compact JSON line on stdout
# (nothing else on stdout, stderr silenced). A read that fails is reported as null, never as an error.
#
# Usage:
#   bash preflight.sh dev    --wt DIR --issue N --base BRANCH [--repo OWNER/REPO] [--targets 'a b c'] [--stamp S]
#   bash preflight.sh branch --wt DIR [--pr N] [--repo OWNER/REPO] [--stamp S]
# --stamp is ignored: it only makes the command text differ per launch (probe-run record reuse).
#
# dev    -> {"mode":"dev","planStale":[..]|null,"openSubIssues":["12",..]|null,"gitDir":"<abs>"|null,"writable":true|false|null}
# branch -> {"mode":"branch","headRef":"<name>"|null,"branchPrefix":"<string>"|null}
# Requires jq and git (gh for the sub-issue / head-ref reads). bash 3.2 compatible. Never uses rm.

MODE="${1:-}"
[ $# -gt 0 ] && shift
WT=""; ISSUE=""; BASE=""; REPO=""; TARGETS=""; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wt) WT="${2:-}" ;;
    --issue) ISSUE="${2:-}" ;;
    --base) BASE="${2:-}" ;;
    --repo) REPO="${2:-}" ;;
    --targets) TARGETS="${2:-}" ;;
    --pr) PR="${2:-}" ;;
    --stamp) ;;
    *) ;;
  esac
  [ $# -ge 2 ] && shift 2 || shift
done

# Compact JSON array of strings from stdin lines (empty input -> []).
lines_json() { jq -Rsc 'split("\n") | map(select(length > 0))'; }

dev() {
  local plan_stale="null" subs="null" gitdir="null" writable="null" out total repo gd probe

  # planStale: files of the plan targets that moved on origin/<base> since the frozen base.
  if [ -n "$TARGETS" ] && [ -n "$WT" ] && [ -n "$BASE" ]; then
    git -C "$WT" fetch origin "$BASE" -q >/dev/null 2>&1
    set -f
    # shellcheck disable=SC2086
    if out="$(git -C "$WT" diff --name-only "HEAD...origin/$BASE" -- $TARGETS 2>/dev/null)"; then
      plan_stale="$(printf '%s\n' "$out" | lines_json)"
    fi
    set +f
  fi

  # openSubIssues: open sub-issue numbers of the epic (as strings).
  if [ -n "$ISSUE" ]; then
    repo="$REPO"
    if [ -z "$repo" ] && [ -n "$WT" ]; then
      repo="$(cd "$WT" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    fi
    if [ -n "$repo" ] && total="$(gh issue view "$ISSUE" -R "$repo" --json subIssuesSummary --jq '.subIssuesSummary.total // 0' 2>/dev/null)"; then
      if [ "$total" = "0" ]; then
        subs="[]"
      elif out="$(gh api "repos/$repo/issues/$ISSUE/sub_issues" --jq '.[] | select(.state=="open") | .number' 2>/dev/null)"; then
        subs="$(printf '%s\n' "$out" | lines_json)"
      fi
    fi
  fi

  # gitDir / writable: touch + unlink a marker in the real git dir (never rm: #99).
  if [ -n "$WT" ] && gd="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$gd" ]; then
    gitdir="$(jq -nc --arg g "$gd" '$g')"
    probe="$gd/.pipeline-write-probe-${ISSUE:-0}-$$"
    if touch "$probe" 2>/dev/null && unlink "$probe" 2>/dev/null; then writable="true"; else writable="false"; fi
  fi

  jq -nc --argjson ps "$plan_stale" --argjson si "$subs" --argjson gd "$gitdir" --argjson w "$writable" \
    '{mode:"dev", planStale:$ps, openSubIssues:$si, gitDir:$gd, writable:$w}'
}

branch() {
  local head="null" prefix="null" ref cfg

  # headRef: the PR head branch, straight from gh.
  if [ -n "$PR" ]; then
    if [ -n "$REPO" ]; then
      ref="$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName 2>/dev/null)"
    else
      ref="$(gh pr view "$PR" --json headRefName --jq .headRefName 2>/dev/null)"
    fi
    [ -n "$ref" ] && head="$(jq -nc --arg r "$ref" '$r')"
  fi

  # branchPrefix: the worktree's own config ("" when the key is absent, null when unreadable).
  cfg="$WT/.claude/pipeline.config.json"
  if [ -n "$WT" ] && [ -f "$cfg" ] && ref="$(jq -r '.branchPrefix // empty' "$cfg" 2>/dev/null)"; then
    prefix="$(jq -nc --arg p "$ref" '$p')"
  fi

  jq -nc --argjson h "$head" --argjson p "$prefix" '{mode:"branch", headRef:$h, branchPrefix:$p}'
}

case "$MODE" in
  dev) dev 2>/dev/null ;;
  branch) branch 2>/dev/null ;;
  *) printf '{"mode":null}\n' ;;
esac
exit 0
