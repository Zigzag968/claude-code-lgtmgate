#!/usr/bin/env bash
# capture-incident.sh — thin wrapper: all logic lives in capture-incident.cjs (a script does the
# mechanical work). Usage: capture-incident.sh <runId> <issue> <label> [--out DIR] [--from DIR]
set -u
command -v node >/dev/null 2>&1 || { echo "capture-incident: node is required but not on PATH" >&2; exit 2; }
exec node "$(dirname "$0")/capture-incident.cjs" "$@"
