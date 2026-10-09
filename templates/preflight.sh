#!/usr/bin/env bash
# preflight.sh — the grouped pre-Dev / branch-guard reads of the engine, as ONE script (E2.4, #83).
#
# Run through probe-run.cjs (--parser preflight): the script EXECUTES the reads, an LLM only copies the
# PROBE line, a hook attests it. Always exits 0 and prints exactly ONE compact JSON line on stdout
# (nothing else on stdout, stderr silenced). A read that fails is reported as null, never as an error.
#
# Usage:
#   bash preflight.sh dev    --wt DIR --issue N --base BRANCH [--repo OWNER/REPO] [--targets 'a b c'] [--engine true] [--stamp S]
#   bash preflight.sh branch --wt DIR [--pr N] [--repo OWNER/REPO] [--stamp S]
# --stamp is ignored: it only makes the command text differ per launch (probe-run record reuse).
#
# dev    -> {"mode":"dev","planStale":[..]|null,"openSubIssues":["12",..]|null,"gitDir":"<abs>"|null,"writable":true|false|null,
#            "layout":{"verdict":"CONFORMING"|"NOT_CONFORMING","issues":[..]}|null}
#   layout (#307): with --engine true, empty files are created at the planned --targets in <wt>/.pipeline/layout-probe and
#   ls-lint runs on that tree WITHOUT file arguments (the folder and exists rules only fire so). null = not checked.
# branch -> {"mode":"branch","headRef":"<name>"|null,"branchPrefix":"<string>"|null[,"readFailed":"<class>"]}
#   readFailed (#239): the PR head-ref read failed AND its `gh` stderr was readable; the CAUSE as one word of a closed
#   set (tls|auth|rate-limit|not-found|other, templates/gh-read-class.sh). The stderr goes to a file under
#   <wt>/.pipeline/ and is classified; only the class leaves the script, never the text. A silent failure keeps
#   today's exact line (no key).
# Requires jq and git (gh for the sub-issue / head-ref reads). bash 3.2 compatible. Never uses rm.

MODE="${1:-}"
[ $# -gt 0 ] && shift
WORKTREE=""; ISSUE=""; BASE=""; REPO=""; TARGETS=""; PR=""; ENGINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wt) WORKTREE="${2:-}" ;;
    --issue) ISSUE="${2:-}" ;;
    --base) BASE="${2:-}" ;;
    --repo) REPO="${2:-}" ;;
    --targets) TARGETS="${2:-}" ;;
    --pr) PR="${2:-}" ;;
    --engine) ENGINE="${2:-}" ;;
    --stamp) ;;
    *) ;;
  esac
  [ $# -ge 2 ] && shift 2 || shift
done

SD="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# The cause classifier (#239). A missing sibling means "no class", never a broken probe.
if [ -f "$SD/gh-read-class.sh" ]; then . "$SD/gh-read-class.sh"; else gh_read_class() { return 0; }; fi

# Compact JSON array of strings from stdin lines (empty input -> []).
lines_json() { jq -Rsc 'split("\n") | map(select(length > 0))'; }

dev() {
  local plan_stale="null" subs="null" gitdir="null" writable="null" layout="null" out total repo gd probe d bin t lout lrc tlist
  local -a target_paths

  # planStale: files of the plan targets that moved on origin/<base> since the frozen base.
  if [ -n "$TARGETS" ] && [ -n "$WORKTREE" ] && [ -n "$BASE" ]; then
    git -C "$WORKTREE" fetch origin "$BASE" -q >/dev/null 2>&1
    IFS=' ' read -r -a target_paths <<< "$TARGETS"
    if out="$(git -C "$WORKTREE" diff --name-only "HEAD...origin/$BASE" -- "${target_paths[@]+"${target_paths[@]}"}" 2>/dev/null)"; then
      plan_stale="$(printf '%s\n' "$out" | lines_json)"
    fi
  fi

  # layout (#307): the planned paths, as empty files in a scratch tree, against the repo's ls-lint rules.
  if [ "$ENGINE" = "true" ] && [ -n "$TARGETS" ] && [ -n "$WORKTREE" ] && [ -f "$WORKTREE/.ls-lint.yml" ]; then
    bin=""
    if [ -x "$WORKTREE/node_modules/.bin/ls-lint" ]; then bin="$WORKTREE/node_modules/.bin/ls-lint"; else bin="$(command -v ls-lint 2>/dev/null)"; fi
    d="$WORKTREE/.pipeline/layout-probe"
    if [ -n "$bin" ] && mkdir -p "$d" 2>/dev/null && find "$d" -mindepth 1 -delete 2>/dev/null; then
      IFS=' ' read -r -a tlist <<< "$TARGETS"
      for t in "${tlist[@]}"; do
        case "$t" in /*|..|../*|*/..|*/../*) continue ;; esac
        mkdir -p "$d/$(dirname "$t")" 2>/dev/null && : > "$d/$t" 2>/dev/null
      done
      lout="$(cd "$d" && "$bin" -config "$WORKTREE/.ls-lint.yml" 2>&1)"; lrc=$?
      if [ "$lrc" = "0" ]; then
        layout='{"verdict":"CONFORMING","issues":[]}'
      elif [ "$lrc" = "1" ]; then
        layout="$(printf '%s\n' "$lout" | jq -Rsc 'split("\n") | map(select(length > 0)) | .[:10] | {verdict:"NOT_CONFORMING", issues:.}')" || layout="null"
      fi
    fi
  fi

  # openSubIssues: open sub-issue numbers of the epic (as strings).
  if [ -n "$ISSUE" ]; then
    repo="$REPO"
    if [ -z "$repo" ] && [ -n "$WORKTREE" ]; then
      repo="$(cd "$WORKTREE" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
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
  if [ -n "$WORKTREE" ] && gd="$(git -C "$WORKTREE" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$gd" ]; then
    gitdir="$(jq -nc --arg g "$gd" '$g')"
    probe="$gd/.pipeline-write-probe-${ISSUE:-0}-$$"
    if touch "$probe" 2>/dev/null && unlink "$probe" 2>/dev/null; then writable="true"; else writable="false"; fi
  fi

  jq -nc --argjson ps "$plan_stale" --argjson si "$subs" --argjson gd "$gitdir" --argjson w "$writable" --argjson ly "$layout" \
    '{mode:"dev", planStale:$ps, openSubIssues:$si, gitDir:$gd, writable:$w, layout:$ly}'
}

branch() {
  local head="null" prefix="null" ref config errf="/dev/null" cls=""

  # The stderr of the head-ref read, kept in a file so a failure can be NAMED (never printed).
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] && mkdir -p "$WORKTREE/.pipeline" 2>/dev/null; then errf="$WORKTREE/.pipeline/preflight-branch.err"; fi

  # headRef: the PR head branch, straight from gh.
  if [ -n "$PR" ]; then
    if [ -n "$REPO" ]; then
      ref="$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName 2>"$errf")" || cls="$(gh_read_class "$(head -c 4000 "$errf" 2>/dev/null)")"
    else
      ref="$(gh pr view "$PR" --json headRefName --jq .headRefName 2>"$errf")" || cls="$(gh_read_class "$(head -c 4000 "$errf" 2>/dev/null)")"
    fi
    [ -n "$ref" ] && head="$(jq -nc --arg r "$ref" '$r')"
  fi

  # branchPrefix: the worktree's own config ("" when the key is absent, null when unreadable).
  config="$WORKTREE/.claude/pipeline.config.json"
  if [ -n "$WORKTREE" ] && [ -f "$config" ] && ref="$(jq -r '.branchPrefix // empty' "$config" 2>/dev/null)"; then
    prefix="$(jq -nc --arg p "$ref" '$p')"
  fi

  jq -nc --argjson h "$head" --argjson p "$prefix" --arg rf "$cls" \
    '{mode:"branch", headRef:$h, branchPrefix:$p} + (if $rf == "" then {} else {readFailed:$rf} end)'
}

case "$MODE" in
  dev) dev 2>/dev/null ;;
  branch) branch 2>/dev/null ;;
  *) printf '{"mode":null}\n' ;;
esac
exit 0
