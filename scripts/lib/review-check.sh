#!/usr/bin/env bash
# Shared review-freshness check (#157). Sourced by scripts/lead-merge.sh and hooks/block-merge-unchecked.sh so both
# apply the SAME rule. bash 3.2 safe. Defines functions only; no side effect on source.
#
# A review VERDICT is a PR comment whose first line is exactly the marker
#   <!-- pipeline-review-round pr=<N> sha=<40hex> -->
# (Morgan's verdict; the commit-hygiene squash note re-attests the squashed head the same way). Nick's push-notes keep the
# bare marker `<!-- pipeline-review-round pr=<N> -->` and are never a review: only the sha-bearing form counts.
#
#   review_fresh_state <pr> <head-sha>   comments JSON on stdin (`gh api repos/<r>/issues/<pr>/comments --paginate`:
#                                        one JSON array per page, concatenated)
#     stdout `ok <sha>`     the LATEST verdict was made on <head-sha>
#     stdout `stale <sha>`  the latest verdict was made on <sha> != <head-sha>
#     stdout `none`         no comment carries the sha-bearing marker for this PR
#     rc 0 always; a non-zero rc means the comments could not be parsed
#   review_own_commits_only <reviewed> <head> <base-ref>   (git, run inside the PR checkout; objects already fetched)
#     rc 0 iff <reviewed> is an ancestor of <head> and every commit on the first-parent line <reviewed>..<head> is
#     lead-merge's own: a `chore: bump X.Y.Z (lead-merge)` commit touching only the version files, or a merge whose extra
#     parents are all already on <base-ref> (the base brought in). A re-run after a partial run sees such a head.

review_fresh_state() {
  python3 -c '
import json, re, sys
pr, head = sys.argv[1], sys.argv[2].lower()
raw, dec, i, comments = sys.stdin.read(), json.JSONDecoder(), 0, []
while i < len(raw):
    if raw[i].isspace():
        i += 1; continue
    obj, i = dec.raw_decode(raw, i)
    comments.extend(obj if isinstance(obj, list) else [obj])
pat = re.compile(r"^<!--\s*pipeline-review-round\s+pr=%s\s+sha=([0-9a-fA-F]{40})\s*-->$" % re.escape(pr))
reviewed = None
for c in comments:
    first = ((c.get("body") or "").replace("\r", "").split("\n") or [""])[0].strip()
    m = pat.match(first)
    if m:
        reviewed = m.group(1).lower()
print("none" if reviewed is None else ("ok " if reviewed == head else "stale ") + reviewed)
' "$1" "$2"
}

review_own_commits_only() {
  local reviewed="$1" head="$2" base="$3" c line p
  git merge-base --is-ancestor "$reviewed" "$head" 2>/dev/null || return 1
  for c in $(git rev-list --first-parent "$reviewed..$head"); do
    line="$(git rev-list --parents -n 1 "$c")"
    set -- $line
    shift
    if [ "$#" -gt 1 ]; then
      shift
      for p in "$@"; do git merge-base --is-ancestor "$p" "$base" 2>/dev/null || return 1; done
    else
      case "$(git log -1 --format=%s "$c")" in
        "chore: bump "*" (lead-merge)") ;;
        *) return 1 ;;
      esac
      [ -z "$(git diff --name-only "$c^" "$c" | grep -vxF -e .claude-plugin/plugin.json -e workflows/deliver-pipeline.js || true)" ] || return 1
    fi
  done
  return 0
}
