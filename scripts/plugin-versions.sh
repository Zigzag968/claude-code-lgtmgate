#!/usr/bin/env bash
# Installed plugin versions (#233): scripts/plugin-versions.sh [--plugin <name>] [--target <version>] [--project <dir>] [--loaded-root <path>]
# The Workflow that runs a delivery is the one of the plugin version INSTALLED for the project's scope, so a Lead who merges
# engine fixes keeps running the old engine until the plugin is updated and the session restarted. This script lists every
# install of the plugin (default: lgtmgate) that `claude plugin list --json` reports and compares each ENABLED one with the
# target version: --target, else the version of .claude-plugin/plugin.json on origin/main of the repository of the current
# directory (the Lead fetches first; this script never fetches and never writes).
# Rule (#421): `enabled` is the state of the plugin id for the directory the CLI runs from, the same on every entry of that id.
# An entry applies to the project (--project, default the current directory) when it is user scope, or its projectPath is or
# contains the project. Among the applicable entries of one channel the most specific scope loads (local, project, user): the
# others are SHADOWED, listed with a note and never counted; an enabled local or project entry that does not apply is listed,
# never counted (OTHER-PROJECT; an unknown scope is still counted). --loaded-root is the plugin root the session loaded (the runbook
# substitutes it in the command text); when it is not an enabled, non-shadowed install of the project, LOADED-CACHE is a problem.
# One line per install: <scope> project=<projectPath or -> channel=<marketplace> enabled=<true|false> version=<v>, followed by
#   ` MISMATCH: found <v>, target <t>` when the install is enabled and its version is not the target (string equality: a
#   disabled install never counts, like the stale channel left next to the beta one);
#   ` SHADOWED by <scope> install version <v>` when a more specific install of the same channel applies to the project;
#   ` OTHER-PROJECT: not loaded for this project, not counted` when the install is enabled, local or project scope, and its
#   project does not contain the project;
#   `CONFLICT: both channels enabled in scope=<scope> project=<p>: <m1>, <m2>` when two marketplaces are both enabled for the
#   same scope and project (the same plugin enabled from two channels);
#   `MARKETPLACE-CONFLICT: <name> is declared with different sources: <file> (<kind> <value>), ...` when one marketplace name
#   is declared in two or more of the user, project and local settings files (`extraKnownMarketplaces`) with different `source`
#   objects (whole-object comparison); one problem per name, whatever the plugin;
#   `LOADED-CACHE: ... remove the loaded one: claude plugin uninstall <plugin>@<channel> --scope <scope>` (printed, never run).
# Last line: `plugin-versions: <n> install(s) of <plugin>, target <t>, <k> problem(s)`, or `plugin-versions: no install of
# <plugin> found`. Read-only: the only external call is `claude plugin list --json`; the three settings files are read.
# Exit: 0 clean (or no install), 1 any MISMATCH, CONFLICT, MARKETPLACE-CONFLICT or LOADED-CACHE, 2 cannot decide (no target, claude failed, the payload
# is not the expected list, the loaded root matches no listed install, the CLI reports a local or project install of this project disabled while that project's
# .claude/settings.local.json or settings.json enables it: the sandbox hides that file from the CLI, #480): it never reports "all fine" on something it could not read.
# Updating an install is a user-level action: the command is printed by the runbook (skills/deliver/SKILL.md step 0), never run here.
set -uo pipefail

die2() { echo "plugin-versions: $*" >&2; exit 2; }

PLUGIN="lgtmgate"; TARGET=""; PROJECT="$PWD"; LOADED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin) [ $# -ge 2 ] || die2 "--plugin needs a value"; PLUGIN="$2"; shift 2 ;;
    --target) [ $# -ge 2 ] || die2 "--target needs a value"; TARGET="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --loaded-root) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--loaded-root needs a value"; LOADED="$2"; shift 2 ;;
    *) die2 "usage: scripts/plugin-versions.sh [--plugin <name>] [--target <version>] [--project <dir>] [--loaded-root <path>] (unknown argument: $1)" ;;
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
LISTING="$listing" python3 - "$PLUGIN" "$TARGET" "$PROJECT" "$LOADED" <<'PY'
import json, os, sys

plugin, target, project, loaded = sys.argv[1:5]
RANK = {"user": 1, "project": 2, "local": 3}
rp = os.path.realpath(project)

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
    ip = e.get("installPath")
    if ip is not None and not isinstance(ip, str):
        fail("unexpected installPath for %s" % eid)
    applies = scope == "user" or (proj is not None and (rp == os.path.realpath(proj) or rp.startswith(os.path.realpath(proj).rstrip(os.sep) + os.sep)))
    if applies and scope in ("local", "project") and not enabled:
        for fn in ("settings.local.json", "settings.json"):
            try:
                with open(os.path.join(proj, ".claude", fn)) as fh:
                    ep = json.load(fh).get("enabledPlugins")
            except (OSError, ValueError, AttributeError):
                continue
            if isinstance(ep, dict) and ep.get(eid) is True:
                fail("cannot decide: the CLI reports %s disabled for the %s install of %s, but %s enables it (under the sandbox the CLI cannot read that file); run the same command outside the sandbox to confirm"
                     % (eid, scope, proj, os.path.join(proj, ".claude", fn)))
    rows.append({"scope": scope, "proj": proj or "-", "market": eid[len(plugin) + 1:], "enabled": enabled, "version": version,
                 "path": ip, "applies": applies and scope in RANK})

def declaration_problems():
    """One line per marketplace name declared with different sources across the user, project and local settings."""
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    files = [os.path.join(cfg, "settings.json"), os.path.join(project, ".claude", "settings.json"),
             os.path.join(project, ".claude", "settings.local.json")]
    seen = {}
    for path in files:
        try:
            with open(path) as fh:
                decl = json.load(fh).get("extraKnownMarketplaces")
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(decl, dict):
            continue
        for name, val in decl.items():
            src = val.get("source") if isinstance(val, dict) else None
            if src is not None:
                seen.setdefault(name, []).append((path, src))
    lines = []
    for name in sorted(seen):
        decls = seen[name]
        if len({json.dumps(src, sort_keys=True) for _, src in decls}) < 2:
            continue
        def kind(src):
            if not isinstance(src, dict):
                return "? %s" % json.dumps(src, sort_keys=True)
            for k in ("repo", "url", "path"):
                if k in src:
                    return "%s %s" % (src.get("source", "?"), src[k])
            return "%s ?" % src.get("source", "?")
        lines.append("MARKETPLACE-CONFLICT: %s is declared with different sources: %s. Fix: declare %s once, or give every declaration the same source (edit %s)"
                     % (name, ", ".join("%s (%s)" % (pth, kind(src)) for pth, src in decls), name, decls[-1][0]))
    return lines

decl_lines = declaration_problems()

if not rows:
    for l in decl_lines:
        print(l)
    print("plugin-versions: no install of %s found" % plugin)
    sys.exit(1 if decl_lines else 0)

def shadow(r):
    best = None
    for o in rows:
        if o["applies"] and o["market"] == r["market"] and RANK[o["scope"]] > RANK[r["scope"]] and (best is None or RANK[o["scope"]] > RANK[best["scope"]]):
            best = o
    return best if r["applies"] else None

for r in rows:
    r["shadow"] = shadow(r)
good = [r for r in rows if r["enabled"] and r["applies"] and not r["shadow"]]
hit = []
if loaded:
    rl = os.path.realpath(loaded)
    hit = [r for r in rows if r["path"] and os.path.realpath(r["path"]) == rl]
    if not hit:
        fail("the loaded plugin root matches no listed install of %s" % plugin)

problems = 0
groups = {}
for r in rows:
    line = "%s project=%s channel=%s enabled=%s version=%s" % (r["scope"], r["proj"], r["market"], "true" if r["enabled"] else "false", r["version"])
    if r["enabled"] and r["shadow"]:
        line += " SHADOWED by %s install version %s" % (r["shadow"]["scope"], r["shadow"]["version"])
    elif r["enabled"] and r["scope"] in RANK and not r["applies"]:
        line += " OTHER-PROJECT: not loaded for this project, not counted"
    elif r["enabled"]:
        groups.setdefault((r["scope"], r["proj"]), set()).add(r["market"])
        if r["version"] != target:
            line += " MISMATCH: found %s, target %s" % (r["version"], target)
            problems += 1
    print(line)
for (scope, proj) in sorted(groups):
    if len(groups[(scope, proj)]) > 1:
        print("CONFLICT: both channels enabled in scope=%s project=%s: %s" % (scope, proj, ", ".join(sorted(groups[(scope, proj)]))))
        problems += 1
for l in decl_lines:
    print(l)
    problems += 1
if hit and not any(r in good for r in hit):
    cur = "%s version %s" % (good[0]["scope"], good[0]["version"]) if good else "none enabled"
    for r in hit:
        print("LOADED-CACHE: the loaded plugin root is the %s install %s@%s version %s; the install for this project is %s; remove the loaded one: claude plugin uninstall %s@%s --scope %s"
              % (r["scope"], plugin, r["market"], r["version"], cur, plugin, r["market"], r["scope"]))
    problems += 1
print("plugin-versions: %d install(s) of %s, target %s, %d problem(s)" % (len(rows), plugin, target, problems))
sys.exit(1 if problems else 0)
PY
