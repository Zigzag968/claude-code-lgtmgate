#!/usr/bin/env bash
# Read a GH Project "Pipeline Status" reliably for an issue number.
# `gh project item-list --format json` is reliable only for resolving the item id; for the VALUE
# it omits the key when null and lags a recent write — so read the value via GraphQL.
# Usage: gh-pipeline-status.sh <issue-number>   →  prints the status name (or "null").
set -uo pipefail

N="${1:?usage: gh-pipeline-status.sh <issue-number>}"

# Resolve the CALLING project's own ghProject.owner/projectNumber from its pipeline.config.json —
# this script is installed verbatim into every consumer project (commands/init.md), so it must
# never hardcode a board here. Anchor on the script's OWN file location (not $PWD) so the lookup
# works identically from either mirrored copy (templates/ vs .claude/scripts/, different depths).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
CONFIG_FILE="${AGENT_PIPELINE_CONFIG_FILE:-${REPO_ROOT:+$REPO_ROOT/.claude/pipeline.config.json}}"

if [ -z "${CONFIG_FILE:-}" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "gh-pipeline-status.sh: no pipeline.config.json found (set \$AGENT_PIPELINE_CONFIG_FILE, or run from inside a repo with <repo-root>/.claude/pipeline.config.json)" >&2
  exit 1
fi

OWNER="$(jq -r '.ghProject.owner // empty' "$CONFIG_FILE")"
PROJECT_NUMBER="$(jq -r '.ghProject.projectNumber // empty' "$CONFIG_FILE")"

if [ -z "$OWNER" ] || [ -z "$PROJECT_NUMBER" ]; then
  echo "gh-pipeline-status.sh: $CONFIG_FILE is missing ghProject.owner / ghProject.projectNumber" >&2
  exit 1
fi

# --limit 1000 bounds the board scan for a repo-agnostic caller: this helper has no
# owner/repo to run an issue-side GraphQL projectItems lookup against (unlike
# updateStatus() in workflows/deliver-pipeline.js, which knows its own repo and uses that
# lookup instead), so it stays a board scan, just no longer capped at the gh default of 30.
ITEM="$(gh project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 1000 \
  | jq -r --argjson n "$N" '.items[] | select(.content.number == $n) | .id')"
[ -n "${ITEM:-}" ] || { echo "no project item for issue #$N" >&2; exit 1; }

gh api graphql -f query='{ node(id:"'"$ITEM"'"){ ... on ProjectV2Item {
  fieldValueByName(name:"Pipeline Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }' \
  -q '.data.node.fieldValueByName.name // "null"'
