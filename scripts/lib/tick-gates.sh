#!/usr/bin/env bash
# Tick steps of scripts/lead-merge.sh step 1c (#9, #196). Sourced by it. bash 3.2 safe. Defines functions only.
#   lm_tick_pick_review <tmpdir>   picks Morgan's latest verdict from <tmpdir>/comments.json into <tmpdir>/review.txt and
#                                  refuses a verdict a push followed
#   lm_tick_ids <csv> <tmpdir>     ticks the boxes of these ids (pr-body-splice.cjs tick-ids), then lm_tick_write
#   lm_tick_write <tmpdir>         writes <tmpdir>/newbody.txt when it differs from body.txt, re-reads the body, re-runs the gate
# shellcheck disable=SC2154  # the globals below are set by the main script
# They read and set the globals PR, REPO, SCRIPT_DIR, pr_head, body, rc and use die() of the main script.

lm_tick_pick_review() {
  local tick_tmp="$1" pick_rc=0 head_sha head_date verdict_at
  PR="$PR" python3 - "$tick_tmp/comments.json" "$tick_tmp/verdict_at.txt" > "$tick_tmp/review.txt" <<'PY' || pick_rc=$?
import json, os, re, sys
raw, dec, i, comments = open(sys.argv[1]).read(), json.JSONDecoder(), 0, []
while i < len(raw):
    if raw[i].isspace():
        i += 1; continue
    obj, i = dec.raw_decode(raw, i)
    comments.extend(obj if isinstance(obj, list) else [obj])
marker = re.compile(r"<!-- pipeline-review-round pr=%s( sha=[0-9a-fA-F]{40})? -->" % os.environ["PR"])
def marked(c):
    lines = (c.get("body") or "").replace("\r", "").split("\n")
    return lines, bool(lines) and bool(marker.fullmatch(lines[0].strip()))
best = None
for n, c in enumerate(comments):
    lines, is_marked = marked(c)
    if is_marked and len([l for l in lines[1:] if l.strip()]) >= 2:
        best = n
if best is None:
    sys.exit(1)
if any(marked(c)[1] for c in comments[best + 1:]):
    sys.exit(2)  # a later marker comment (e.g. a Nick push-note): the verdict is stale
open(sys.argv[2], "w").write(comments[best].get("created_at") or "")
print(comments[best]["body"])
PY
  case "$pick_rc" in
    0) ;;
    2) die "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first" ;;
    *) die "PR #$PR has no Morgan review comment (marker '<!-- pipeline-review-round pr=$PR -->' with a multi-line verdict); nothing ticked, nothing merged" ;;
  esac
  # the PR head must not be newer than the verdict (REST: pulls/<N> head sha -> commits/<sha> committer date)
  head_sha="$pr_head"
  head_date="$(gh api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date)" || die "cannot read the commit date of $head_sha"
  verdict_at="$(cat "$tick_tmp/verdict_at.txt")"
  [ -n "$head_date" ] && [ -n "$verdict_at" ] || die "tick-from-review: cannot compare the head commit date with the verdict date; nothing ticked"
  python3 -c 'import sys; sys.exit(0 if sys.argv[1] <= sys.argv[2] else 1)' "$head_date" "$verdict_at" \
    || die "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first"
  printf '%s\n' "$body" > "$tick_tmp/body.txt"
}

lm_tick_write() {
  local tick_tmp="$1"
  if ! cmp -s "$tick_tmp/body.txt" "$tick_tmp/newbody.txt"; then
    bash "$SCRIPT_DIR/runtime/pii-guard.sh" check < "$tick_tmp/newbody.txt" > "$tick_tmp/pii.txt" 2>/dev/null || die "tick-from-review: pii-guard refused ($(sed 's/^pii-refused://' "$tick_tmp/pii.txt")); nothing written"
    gh api -X PATCH "repos/$REPO/pulls/$PR" -F "body=@$tick_tmp/newbody.txt" >/dev/null || die "cannot PATCH the PR #$PR body"
  fi
  body="$(gh pr view "$PR" -R "$REPO" --json body -q .body)" || die "cannot re-read PR #$PR body"
  rc=0
  printf '%s\n' "$body" | acceptance_check_body || rc=$?
  [ "$rc" -eq 0 ] || die "PR #$PR acceptance gate still failing after --tick-from-review (rc=$rc); nothing bumped, nothing merged"
}

lm_tick_ids() {
  local csv="$1" tick_tmp="$2" ids_rc=0
  printf '%s\n' "$body" > "$tick_tmp/body.txt"
  node "$SCRIPT_DIR/runtime/pr-body-splice.cjs" tick-ids "$tick_tmp/body.txt" "$tick_tmp/newbody.txt" "$csv" || ids_rc=$?
  case "$ids_rc" in
    0) ;;
    2) die "--tick-ids needs a comma list of ids" ;;
    3) die "PR #$PR has no acceptance markers; nothing ticked" ;;
    5) die "tick-ids: an id has no box in PR #$PR; nothing ticked" ;;
    6) die "tick-ids: an id is a [human-gate] box, never ticked by a script; nothing ticked" ;;
    *) die "tick-ids failed" ;;
  esac
  lm_tick_write "$tick_tmp"
}
