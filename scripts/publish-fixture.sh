#!/usr/bin/env bash
# publish-fixture.sh — thin wrapper: all logic lives in publish-fixture.cjs (a script does the
# mechanical work). Usage: publish-fixture.sh <raw capture> [<out name>] [--out-dir DIR] [--fp FILE]
set -u
command -v node >/dev/null 2>&1 || { echo "publish-fixture: node is required but not on PATH" >&2; exit 2; }
exec node "$(dirname "$0")/publish-fixture.cjs" "$@"
