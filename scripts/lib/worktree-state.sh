#!/usr/bin/env bash
# worktree-state.sh — sourced helper (never executed directly, never exits the caller). Bash 3.2 compatible.
#
# One classification of a pipeline worktree, shared by scripts/worktree-inventory.sh and scripts/cleanup-worktree.sh (#168).
# wt_classify sets WT_ISSUE WT_PR WT_TREE WT_AHEAD WT_RUN WT_CLASS. First match wins:
#   detached (no branch) | in-flight | dirty | open-pr | unknown (PR lookup failed)   -> never removed
#   merged | closed-unmerged | no-pr-empty (no PR, 0 commits ahead of base)            -> removable
#   ahead (no PR, >= 1 commit ahead of base)                                          -> never removed
# PR state: one REST call per worktree (no GraphQL). In flight: same convention as hooks/Stop-supervise-runs.sh.

_WT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/lib-worktree-root.sh
. "$_WT_LIB_DIR/../../hooks/lib-worktree-root.sh"

_wt_phys() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# wt_main_tree <path>: the main tree of the repository holding <path>
wt_main_tree() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}'
}

# wt_root <dir>: the physical worktree root resolved from <dir>'s repository (nothing when unresolvable)
wt_root() {
  local r
  r="$(cd "$1" 2>/dev/null && resolve_worktree_root)"
  [ -n "$r" ] || return 0
  _wt_phys "$r"
}

# wt_base_ref <main>: origin/<baseBranch> when that ref exists, else the local <baseBranch> (default main)
wt_base_ref() {
  local base=main v
  if [ -f "$1/.claude/pipeline.config.json" ] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.baseBranch // empty' "$1/.claude/pipeline.config.json" 2>/dev/null)"
    if [ -n "$v" ]; then base="$v"; fi
  fi
  if git -C "$1" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null 2>&1; then
    printf 'origin/%s' "$base"
  else
    printf '%s' "$base"
  fi
}

# wt_pr_state <main> <branch>: NONE | OPEN | MERGED | CLOSED | UNKNOWN (REST, run from the main tree)
wt_pr_state() {
  local out
  out="$(cd "$1" && gh api "repos/{owner}/{repo}/pulls?state=all&head={owner}:$2&per_page=5" \
    --jq '(sort_by(.number)|last) as $p | if $p==null then "NONE" elif $p.merged_at!=null then "MERGED" elif $p.state=="open" then "OPEN" else "CLOSED" end' 2>/dev/null)" || out=""
  case "$out" in NONE|OPEN|MERGED|CLOSED) printf '%s' "$out" ;; *) printf 'UNKNOWN' ;; esac
}

# wt_issue_of <branch>: the trailing issue-<N> of a branch name (nothing otherwise)
wt_issue_of() {
  local n
  case "$1" in *issue-[0-9]*) ;; *) return 0 ;; esac
  n="${1##*issue-}"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$n"
}

# wt_inflight <main> <worktree> <issue>: rc 0 when a run is in flight on that worktree.
# State file <main>/.pipeline/issue-<N>.json with status in-progress|plan|dev|review; with no state file or no issue
# number, any file under <worktree>/.pipeline touched within supervision.staleMinutes (default 30).
wt_inflight() {
  local sf st mins=30 cfg v hit
  if [ -n "$3" ]; then
    sf="$1/.pipeline/issue-$3.json"
    if [ -f "$sf" ]; then
      st="$(tr '\n' ' ' < "$sf" 2>/dev/null | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
      case "$st" in in-progress|plan|dev|review) return 0 ;; *) return 1 ;; esac
    fi
  fi
  cfg="$1/.claude/pipeline.config.json"
  if [ -f "$cfg" ]; then
    v="$(grep -o '"staleMinutes"[[:space:]]*:[[:space:]]*[0-9]\+' "$cfg" 2>/dev/null | grep -o '[0-9]\+$' | head -1 || true)"
    if [ -n "${v:-}" ]; then mins="$v"; fi
  fi
  if [ -d "$2/.pipeline" ]; then
    hit="$(find "$2/.pipeline" -type f -mmin "-$mins" 2>/dev/null | head -1)"
    if [ -n "$hit" ]; then return 0; fi
  fi
  return 1
}

# wt_classify <main> <worktree> <branch>: sets WT_ISSUE WT_PR WT_TREE WT_AHEAD WT_RUN WT_CLASS
wt_classify() {
  local main="$1" wt="$2" branch="$3" base st
  WT_ISSUE=""; WT_PR="-"; WT_TREE=clean; WT_AHEAD=0; WT_RUN=no; WT_CLASS=""
  if [ -n "$branch" ]; then WT_ISSUE="$(wt_issue_of "$branch")"; fi
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then WT_TREE=dirty; fi
  if [ -z "$branch" ]; then WT_AHEAD="-"; WT_CLASS=detached; return 0; fi
  if wt_inflight "$main" "$wt" "$WT_ISSUE"; then WT_RUN=yes; fi
  base="$(wt_base_ref "$main")"
  WT_AHEAD="$(git -C "$main" rev-list --count "$base..$branch" 2>/dev/null)" || WT_AHEAD="?"
  case "$WT_AHEAD" in ''|*[!0-9]*) WT_AHEAD="?" ;; esac
  st="$(wt_pr_state "$main" "$branch")"
  case "$st" in
    NONE) WT_PR=none ;; OPEN) WT_PR=open ;; MERGED) WT_PR=merged ;; CLOSED) WT_PR=closed ;; *) WT_PR=unknown ;;
  esac
  if [ "$WT_RUN" = yes ]; then WT_CLASS=in-flight
  elif [ "$WT_TREE" = dirty ]; then WT_CLASS=dirty
  else
    case "$st" in
      OPEN) WT_CLASS=open-pr ;;
      MERGED) WT_CLASS=merged ;;
      CLOSED) WT_CLASS=closed-unmerged ;;
      NONE) if [ "$WT_AHEAD" = 0 ]; then WT_CLASS=no-pr-empty; else WT_CLASS=ahead; fi ;;
      *) WT_CLASS=unknown ;;
    esac
  fi
  return 0
}

# wt_each <dir>: one "path<TAB>branch" line per linked, non-main worktree of <dir>'s repository that sits under the worktree root
wt_each() {
  local root p b pp
  root="$(wt_root "$1")"
  [ -n "$root" ] || return 0
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v RS= -F'\n' '
    { p=""; b=""
      for (i = 1; i <= NF; i++) { if ($i ~ /^worktree /) p = substr($i, 10); else if ($i ~ /^branch /) b = substr($i, 19) }
      n++; if (n > 1) printf "%s\t%s\n", p, b }' | while IFS="$(printf '\t')" read -r p b; do
    [ -d "$p" ] || continue
    pp="$(_wt_phys "$p")"
    case "$pp" in "$root"/*) printf '%s\t%s\n' "$pp" "$b" ;; esac
  done
}
