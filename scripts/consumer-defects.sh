#!/usr/bin/env bash
# Count the defects a consumer met, per release (#431). Read-only: one `gh api` GET on the issues of the
# repository (paginated once, no GraphQL, no write) and `git for-each-ref` on the tags of the current directory.
# For each release window (up to the first tag, between two tags, after the last tag) it prints the number of issues
# carrying the label created in that window, the number still open and the date of the last one; the last line is
# `[consumer-defects] total=<n> open=<k> last=<date>`. Exit 0, or 2 when the listing or the tags cannot be read.
# Usage: scripts/consumer-defects.sh [--repo <owner>/<name>] [--label <name>]   (default label: found-by:consumer)
set -uo pipefail

LABEL="found-by:consumer"; REPO="{owner}/{repo}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "consumer-defects: --repo needs a value" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --label) [ $# -ge 2 ] || { echo "consumer-defects: --label needs a value" >&2; exit 2; }; LABEL="$2"; shift 2 ;;
    *) echo "consumer-defects: unknown option: $1" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/consumer-defects.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Tags, oldest first, with their date in UTC (a lightweight tag carries the date of its commit).
if ! TZ=UTC git for-each-ref --sort=creatordate --format='%(refname:short)%09%(creatordate:format-local:%Y-%m-%dT%H:%M:%SZ)' 'refs/tags/v[0-9]*' > "$TMP/tags" 2>/dev/null; then
  echo "consumer-defects: cannot read the tags of the current directory" >&2
  exit 2
fi

# Issues with the label, all states, pull requests dropped: number, state, creation date.
if ! gh api --paginate "repos/$REPO/issues?labels=$LABEL&state=all&per_page=100" \
  --jq '.[]|select(.pull_request|not)|[.number,.state,.created_at]|@tsv' > "$TMP/issues" 2> "$TMP/err"; then
  echo "consumer-defects: cannot read the issues listing: $(head -c 300 "$TMP/err")" >&2
  exit 2
fi
if grep -qvE '^[0-9]+	(open|closed)	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$' "$TMP/issues"; then
  echo "consumer-defects: the issues listing has an unexpected line" >&2
  exit 2
fi

awk -F'\t' -v tagsfile="$TMP/tags" '
  BEGIN { n = 0 }
  FILENAME == tagsfile { tag[n] = $1; tdate[n] = $2; n++; next }
  {
    w = n
    for (i = 0; i < n; i++) if ($3 <= tdate[i]) { w = i; break }
    count[w]++; total++
    if ($2 == "open") { opened[w]++; open_total++ }
    if ($3 > last[w]) last[w] = $3
    if ($3 > last_all) last_all = $3
  }
  END {
    for (i = 0; i <= n; i++) {
      name = (i == n) ? "unreleased" : tag[i]
      from = (i == 0) ? "-" : substr(tdate[i - 1], 1, 10)
      to = (i == n) ? "-" : substr(tdate[i], 1, 10)
      printf "[consumer-defects] window=%s from=%s to=%s created=%d open=%d last=%s\n", name, from, to, count[i] + 0, opened[i] + 0, (last[i] == "" ? "-" : substr(last[i], 1, 10))
    }
    printf "[consumer-defects] total=%d open=%d last=%s\n", total + 0, open_total + 0, (last_all == "" ? "-" : substr(last_all, 1, 10))
  }
' "$TMP/tags" "$TMP/issues"
