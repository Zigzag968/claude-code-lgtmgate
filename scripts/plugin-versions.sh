#!/usr/bin/env bash
# Installed plugin versions (#233): scripts/plugin-versions.sh [--plugin <name>] [--target <version>]
# The Workflow that runs a delivery is the one of the plugin version INSTALLED for the project's scope, so a Lead who merges
# engine fixes keeps running the old engine until the plugin is updated and the session restarted. This script lists every
# install of the plugin (default: lgtmgate) that `claude plugin list --json` reports and compares each ENABLED one with the
# target version: --target, else the version of .claude-plugin/plugin.json on origin/main of the repository of the current
# directory (the Lead fetches first; this script never fetches and never writes).
# One line per install: <scope> project=<projectPath or -> channel=<marketplace> enabled=<true|false> version=<v>, followed by
#   ` MISMATCH: found <v>, target <t>` when the install is enabled and its version is not the target (string equality: a
#   disabled install never counts, like the stale channel left next to the beta one);
#   `CONFLICT: both channels enabled in scope=<scope> project=<p>: <m1>, <m2>` when two marketplaces are both enabled for the
#   same scope and project (the same plugin enabled from two channels).
# Last line: `plugin-versions: <n> install(s) of <plugin>, target <t>, <k> problem(s)`, or `plugin-versions: no install of
# <plugin> found`. Read-only: the only external call is `claude plugin list --json`.
# Exit: 0 clean (or no install), 1 any MISMATCH or CONFLICT, 2 cannot decide (no target, claude failed, the payload is not the
# expected list): it never reports "all fine" on something it could not read.
# Updating an install is a user-level action: the command is printed by the runbook (commands/deliver.md step 0), never run here.
set -uo pipefail

die2() { echo "plugin-versions: $*" >&2; exit 2; }

PLUGIN="lgtmgate"; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin) [ $# -ge 2 ] || die2 "--plugin needs a value"; PLUGIN="$2"; shift 2 ;;
    --target) [ $# -ge 2 ] || die2 "--target needs a value"; TARGET="$2"; shift 2 ;;
    *) die2 "usage: scripts/plugin-versions.sh [--plugin <name>] [--target <version>] (unknown argument: $1)" ;;
  esac
done
[ -n "$PLUGIN" ] || die2 "--plugin needs a non-empty name"

# 1. the target version
if [ -z "$TARGET" ]; then
  manifest="$(git show origin/main:.claude-plugin/plugin.json 2>/dev/null)" || manifest=""
  TARGET="$(printf '%s' "$manifest" | python3 -c '
import json, sys
v = json.load(sys.stdin).get("version")
if isinstance(v, str) and v:
    print(v)
else:
    sys.exit(1)' 2>/dev/null)" || TARGET=""
  [ -n "$TARGET" ] || die2 "cannot read the target version (pass --target <version>)"
fi

# 2. the installs, captured before any parsing (a failed claude is a failure, never an empty list)
listing="$(claude plugin list --json </dev/null)" || die2 "claude plugin list --json failed"

# 3-6. judge the payload; the JSON travels in the environment (python reads it, no unchecked pipe)
LISTING="$listing" python3 - "$PLUGIN" "$TARGET" <<'PY'
import json, os, sys

plugin, target = sys.argv[1], sys.argv[2]

def fail(msg):
    print("plugin-versions: " + msg, file=sys.stderr)
    sys.exit(2)

try:
    data = json.loads(os.environ["LISTING"])
except ValueError:
    fail("claude plugin list --json did not print JSON")
if not isinstance(data, list):
    fail("claude plugin list --json did not print a list")

rows = []
for e in data:
    eid = e.get("id") if isinstance(e, dict) else None
    if not isinstance(eid, str) or not eid.startswith(plugin + "@"):
        continue
    version, scope, enabled, proj = e.get("version"), e.get("scope"), e.get("enabled"), e.get("projectPath")
    if not (isinstance(version, str) and version and isinstance(scope, str) and scope and isinstance(enabled, bool)):
        fail("unexpected entry for %s (need a string version, a string scope and a boolean enabled)" % eid)
    if proj is not None and not isinstance(proj, str):
        fail("unexpected projectPath for %s" % eid)
    rows.append((scope, proj or "-", eid[len(plugin) + 1:], enabled, version))

if not rows:
    print("plugin-versions: no install of %s found" % plugin)
    sys.exit(0)

problems = 0
groups = {}
for scope, proj, market, enabled, version in rows:
    line = "%s project=%s channel=%s enabled=%s version=%s" % (scope, proj, market, "true" if enabled else "false", version)
    if enabled:
        groups.setdefault((scope, proj), set()).add(market)
        if version != target:
            line += " MISMATCH: found %s, target %s" % (version, target)
            problems += 1
    print(line)
for (scope, proj) in sorted(groups):
    if len(groups[(scope, proj)]) > 1:
        print("CONFLICT: both channels enabled in scope=%s project=%s: %s" % (scope, proj, ", ".join(sorted(groups[(scope, proj)]))))
        problems += 1
print("plugin-versions: %d install(s) of %s, target %s, %d problem(s)" % (len(rows), plugin, target, problems))
sys.exit(1 if problems else 0)
PY
