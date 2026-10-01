#!/usr/bin/env bash
# pr-write.sh — the review-phase PR/issue/project WRITES of the engine, as ONE script (E2.6a, #85).
#
# Run through probe-run.cjs (--parser pr-write, --no-reuse: a write is never replayed from a stored
# record): the script EXECUTES the read and the write, an LLM only copies the PROBE line, a hook attests
# it. Every op READS FIRST and writes nothing when the read failed (no blind write, no duplicate write).
# Always exits 0 and prints exactly ONE compact JSON line on stdout (nothing else on stdout, stderr
# silenced):
#   {"op":"<op>","result":"written|skipped|failed","reason":<string|null>,"bytes":<int|null>}
# The PR body never transits a model reply: it moves through files under .pipeline/ only (#87).
#
# Usage:
#   bash pr-write.sh <op> [--wt DIR] [--repo OWNER/REPO] <op args>
#
# Ops:
#   issue-comment --number N --marker M --body B
#       read the issue's comments; one starting with M -> skipped/marker-present; else gh issue comment.
#   pr-comment --pr N --marker M --body B
#       same, on the PR.
#   minimize --id ID
#       read isMinimized; true -> skipped/already-minimized; else the minimizeComment mutation (OUTDATED).
#   status --issue N --project-number P --project-id ID --field-id F --option-id O
#       read the issue's project item and its current single-select option; not on the project ->
#       skipped/not-on-project (never an edit with an empty id); option already set -> skipped/already-set;
#       else gh project item-edit.
#   body-splice --pr N --mode decision-log|acceptance --text T
#       read the body, splice (templates/pr-body-splice.cjs), unchanged -> skipped/unchanged; acceptance
#       markers absent -> failed/no-markers (never appends); write; re-read; guard (>= 90 % of the pre
#       length and both acceptance markers) else restore the pre body -> failed/guard-failed-restored.
# reasons on failed: bad-args, read-failed, write-failed, splice-failed, no-markers, guard-failed-restored.
# Requires jq, gh and node (body-splice). bash 3.2 compatible. Never uses rm.

OP="${1:-}"
[ $# -ge 1 ] && shift

WT=""; REPO=""; PR=""; NUMBER=""; MARKER=""; BODY=""; ID=""; ISSUE=""; PNUM=""; PID=""; FID=""; OID=""; MODE=""; TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wt) WT="${2:-}" ;;
    --repo) REPO="${2:-}" ;;
    --pr) PR="${2:-}" ;;
    --number) NUMBER="${2:-}" ;;
    --marker) MARKER="${2:-}" ;;
    --body) BODY="${2:-}" ;;
    --id) ID="${2:-}" ;;
    --issue) ISSUE="${2:-}" ;;
    --project-number) PNUM="${2:-}" ;;
    --project-id) PID="${2:-}" ;;
    --field-id) FID="${2:-}" ;;
    --option-id) OID="${2:-}" ;;
    --mode) MODE="${2:-}" ;;
    --text) TEXT="${2:-}" ;;
    *) ;;
  esac
  [ $# -ge 2 ] && shift 2 || shift
done

SD="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

emit() {
  jq -nc --arg op "$OP" --arg r "$1" --arg why "${2:-}" --arg b "${3:-}" \
    '{op:$op, result:$r, reason:(if $why == "" then null else $why end), bytes:(if $b == "" then null else ($b | tonumber) end)}'
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# comment_op <issue|pr> <number>: shared by issue-comment and pr-comment.
comment_op() {
  local kind="$1" num="$2" view n file
  if ! is_num "$num" || [ -z "$MARKER" ] || [ -z "$BODY" ]; then emit failed bad-args; return; fi
  view="$(gh "$kind" view "$num" ${REPO:+-R "$REPO"} --json comments 2>/dev/null)" || { emit failed read-failed; return; }
  n="$(printf '%s' "$view" | jq -e --arg m "$MARKER" '.comments | map(select((.body // "") | startswith($m))) | length' 2>/dev/null)" || { emit failed read-failed; return; }
  if [ "$n" -gt 0 ]; then emit skipped marker-present; return; fi
  mkdir -p .pipeline
  file=".pipeline/pr-write-${kind}-comment-${num}.md"
  printf '%s\n' "$BODY" > "$file" || { emit failed write-failed; return; }
  if gh "$kind" comment "$num" ${REPO:+-R "$REPO"} --body-file "$file" >/dev/null 2>&1; then
    emit written "" "$(wc -c < "$file" | tr -d ' ')"
  else
    emit failed write-failed
  fi
}

minimize_op() {
  local cur
  if [ -z "$ID" ]; then emit failed bad-args; return; fi
  cur="$(gh api graphql -f query='query($id:ID!){node(id:$id){... on Minimizable{isMinimized}}}' -f id="$ID" --jq '.data.node.isMinimized' 2>/dev/null)" || { emit failed read-failed; return; }
  case "$cur" in
    true) emit skipped already-minimized; return ;;
    false) ;;
    *) emit failed read-failed; return ;;
  esac
  if gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' -f id="$ID" >/dev/null 2>&1; then
    emit written
  else
    emit failed write-failed
  fi
}

status_op() {
  local owner name res item cur
  if ! is_num "$ISSUE" || ! is_num "$PNUM" || [ -z "$PID" ] || [ -z "$FID" ] || [ -z "$OID" ]; then emit failed bad-args; return; fi
  if [ -n "$REPO" ]; then
    owner="${REPO%%/*}"; name="${REPO#*/}"
  else
    owner="$(gh repo view --json owner -q .owner.login 2>/dev/null)" || { emit failed read-failed; return; }
    name="$(gh repo view --json name -q .name 2>/dev/null)" || { emit failed read-failed; return; }
  fi
  # The ISSUE's own project items, never a board scan (a scan of the board stops at its first 30 items).
  res="$(gh api graphql -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){issue(number:$number){projectItems(first:20){nodes{id project{number} fieldValues(first:20){nodes{... on ProjectV2ItemFieldSingleSelectValue{optionId field{... on ProjectV2FieldCommon{id}}}}}}}}}}' \
    -f owner="$owner" -f repo="$name" -F number="$ISSUE" 2>/dev/null)" || { emit failed read-failed; return; }
  item="$(printf '%s' "$res" | jq -r --argjson p "$PNUM" '[.data.repository.issue.projectItems.nodes[]? | select(.project.number==$p)] | first | .id // ""' 2>/dev/null)" || { emit failed read-failed; return; }
  if [ -z "$item" ]; then emit skipped not-on-project; return; fi
  cur="$(printf '%s' "$res" | jq -r --argjson p "$PNUM" --arg f "$FID" '[.data.repository.issue.projectItems.nodes[]? | select(.project.number==$p) | .fieldValues.nodes[]? | select((.field.id // "") == $f) | .optionId] | first // ""' 2>/dev/null)"
  if [ "$cur" = "$OID" ]; then emit skipped already-set; return; fi
  if gh project item-edit --id "$item" --field-id "$FID" --project-id "$PID" --single-select-option-id "$OID" >/dev/null 2>&1; then
    emit written
  else
    emit failed write-failed
  fi
}

body_splice_op() {
  local pre_len post_len rc
  if ! is_num "$PR" || [ -z "$TEXT" ]; then emit failed bad-args; return; fi
  case "$MODE" in decision-log|acceptance) ;; *) emit failed bad-args; return ;; esac
  mkdir -p .pipeline
  gh pr view "$PR" ${REPO:+-R "$REPO"} --json body -q .body > ".pipeline/pr-body-$PR.pre.md" 2>/dev/null || { emit failed read-failed; return; }
  pre_len="$(wc -c < ".pipeline/pr-body-$PR.pre.md" | tr -d ' ')"
  printf '%s\n' "$TEXT" > ".pipeline/pr-body-$PR.text.md" || { emit failed splice-failed; return; }
  node "$SD/pr-body-splice.cjs" splice "$MODE" ".pipeline/pr-body-$PR.pre.md" ".pipeline/pr-body-$PR.text.md" ".pipeline/pr-body-$PR.md" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 3 ]; then emit failed no-markers; return; fi
  if [ "$rc" -ne 0 ]; then emit failed splice-failed; return; fi
  if cmp -s ".pipeline/pr-body-$PR.pre.md" ".pipeline/pr-body-$PR.md"; then emit skipped unchanged; return; fi
  gh pr edit "$PR" ${REPO:+-R "$REPO"} --body-file ".pipeline/pr-body-$PR.md" >/dev/null 2>&1 || { emit failed write-failed; return; }
  gh pr view "$PR" ${REPO:+-R "$REPO"} --json body -q .body > ".pipeline/pr-body-$PR.post.md" 2>/dev/null
  post_len="$(wc -c < ".pipeline/pr-body-$PR.post.md" | tr -d ' ')"
  if node "$SD/pr-body-splice.cjs" guard "$pre_len" ".pipeline/pr-body-$PR.post.md" >/dev/null 2>&1; then
    emit written "" "$post_len"
  else
    gh pr edit "$PR" ${REPO:+-R "$REPO"} --body-file ".pipeline/pr-body-$PR.pre.md" >/dev/null 2>&1
    emit failed guard-failed-restored "$post_len"
  fi
}

main() {
  [ -n "$WT" ] && cd "$WT"
  case "$OP" in
    issue-comment) comment_op issue "$NUMBER" ;;
    pr-comment) comment_op pr "$PR" ;;
    minimize) minimize_op ;;
    status) status_op ;;
    body-splice) body_splice_op ;;
    *) emit failed bad-args ;;
  esac
}

main 2>/dev/null
exit 0
