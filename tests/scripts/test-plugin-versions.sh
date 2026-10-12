#!/usr/bin/env bash
# Regression test for scripts/plugin-versions.sh (#233). Offline: a fake `claude` on PATH prints a canned
# `claude plugin list --json` payload (fields copied from a real one: id, version, scope, enabled, installPath,
# projectPath, projectEnabled, hasUserConfig) and logs its argv; the target version comes from --target or from a
# throwaway git repo under $TMPDIR. The real `claude`, the network and the real tree are never touched.
# Cases: install equal to the target, stale install, disabled stale install, both channels enabled in one scope and
# project, the real user-scope shape (stable disabled, beta enabled), channels in different scopes or projects,
# other plugins ignored, target from origin/main, fail closed (exit 2) on every unexpected payload, no install,
# --plugin, shadowed installs (a more specific scope of the same channel applies to --project), the loaded plugin root
# (--loaded-root, LOADED-CACHE and its printed uninstall command), installs of another project (listed, not counted),
# a CLI-disabled install that the project's own settings enable (#480, exit 2), one marketplace declared with different
# sources across user, project and local settings (MARKETPLACE-CONFLICT, #501), the CONFLICT runbook (#516: the deliver step 0 stops, the printed disable command of each channel), and read-only (the fake only ever sees `plugin list --json`).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/plugin-versions.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/plugin-versions-test.XXXXXX")"
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$BASE/bin"
cat > "$BASE/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
if [ "$*" = "plugin list --json" ]; then
  cat "$FAKE_LIST"
  exit "${FAKE_RC:-0}"
fi
echo "fake claude: unexpected: $*" >&2
exit 99
FAKE
chmod +x "$BASE/bin/claude"
FAKE_LOG="$BASE/claude.log"; : > "$FAKE_LOG"
export FAKE_LOG
# isolate every case from the real home: the user settings file is read from here
export CLAUDE_CONFIG_DIR="$BASE/userclaude"; mkdir -p "$CLAUDE_CONFIG_DIR"

# entry <id> <version> <scope> <enabled true|false> [<projectPath>]: one object of the payload, neutral fake paths
entry() {
  local proj=""
  [ -z "${5:-}" ] || proj=",\"projectPath\":\"$5\""
  printf '{"id":"%s","version":"%s","scope":"%s","enabled":%s,"installPath":"/cache/%s/%s","installedAt":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-02T00:00:00.000Z"%s,"projectEnabled":false,"hasUserConfig":false}' \
    "$1" "$2" "$3" "$4" "$1" "$2" "$proj"
}
# list <file> <entry...>: a JSON array of the entries
list() {
  local f="$1" sep=""; shift
  printf '[' > "$f"
  while [ $# -gt 0 ]; do printf '%s%s' "$sep" "$1" >> "$f"; sep=","; shift; done
  printf ']\n' >> "$f"
}

OUT=""; RC=0
# pv <list-file> [args...]: run the script from $BASE/norepo (no origin/main) against the fake claude; OUT = stdout+stderr
pv() {
  local f="$1"; shift
  mkdir -p "$BASE/norepo"
  OUT="$(cd "$BASE/norepo" && PATH="$BASE/bin:$PATH" FAKE_LIST="$f" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
last_line() { printf '%s\n' "$OUT" | tail -n 1; }

BETA='lgtmgate@zigzag-plugins-beta'; STABLE='lgtmgate@zigzag-plugins'
T='1.0.0-beta.27'

# 1. an enabled install equal to the target: clean
list "$BASE/l1.json" "$(entry "$BETA" "$T" user true)"
pv "$BASE/l1.json" --target "$T"
[ "$RC" -eq 0 ] && has 'user project=- channel=zigzag-plugins-beta enabled=true version=1.0.0-beta.27' && ! has MISMATCH && ! has CONFLICT \
  && [ "$(last_line)" = "plugin-versions: 1 install(s) of lgtmgate, target $T, 0 problem(s)" ] \
  && ok "equal install: exit 0, the line shows scope, project, channel, enabled and version, no problem" || bad "equal install (rc=$RC): $OUT"

# 2. an enabled stale install: MISMATCH naming the version found and the target
list "$BASE/l2.json" "$(entry "$BETA" 1.0.0-beta.3 user true)"
pv "$BASE/l2.json" --target "$T"
[ "$RC" -eq 1 ] && has 'MISMATCH: found 1.0.0-beta.3, target 1.0.0-beta.27' && [ "$(last_line)" = "plugin-versions: 1 install(s) of lgtmgate, target $T, 1 problem(s)" ] \
  && ok "enabled stale install: exit 1, MISMATCH names the version found and the target" || bad "stale install (rc=$RC): $OUT"
# the order does not matter: a NEWER enabled install is a mismatch too (string equality, the #195 idiom)
list "$BASE/l2b.json" "$(entry "$BETA" 1.0.0-beta.99 user true)"
pv "$BASE/l2b.json" --target "$T"
[ "$RC" -eq 1 ] && has 'MISMATCH: found 1.0.0-beta.99' && ok "an enabled install above the target is a mismatch too" || bad "newer install (rc=$RC): $OUT"
# the version is compared whole, never by prefix
list "$BASE/l2c.json" "$(entry "$BETA" 1.0.0-beta.2 user true)"
pv "$BASE/l2c.json" --target 1.0.0-beta.27
[ "$RC" -eq 1 ] && has 'MISMATCH: found 1.0.0-beta.2, target 1.0.0-beta.27' && ok "versions are compared whole (beta.2 is not beta.27)" || bad "prefix compare (rc=$RC): $OUT"

# 3. a disabled stale install never counts
list "$BASE/l3.json" "$(entry "$STABLE" 0.8.61 user false)"
pv "$BASE/l3.json" --target "$T"
[ "$RC" -eq 0 ] && ! has MISMATCH && has 'channel=zigzag-plugins enabled=false version=0.8.61' \
  && ok "disabled stale install: exit 0, listed, no MISMATCH" || bad "disabled stale (rc=$RC): $OUT"

# 4. both channels enabled in one scope and project: CONFLICT
list "$BASE/l4.json" "$(entry "$STABLE" "$T" user true)" "$(entry "$BETA" "$T" user true)"
pv "$BASE/l4.json" --target "$T"
[ "$RC" -eq 1 ] && has 'CONFLICT: both channels enabled in scope=user project=-: zigzag-plugins, zigzag-plugins-beta' && ! has MISMATCH \
  && ok "both channels enabled in one scope: exit 1, CONFLICT names the scope and both channels" || bad "channel conflict (rc=$RC): $OUT"
list "$BASE/l4b.json" "$(entry "$STABLE" "$T" local true /work/proj-a)" "$(entry "$BETA" "$T" local true /work/proj-a)"
pv "$BASE/l4b.json" --target "$T" --project /work/proj-a
[ "$RC" -eq 1 ] && has 'CONFLICT: both channels enabled in scope=local project=/work/proj-a' \
  && ok "both channels enabled in the same project of a local scope: CONFLICT" || bad "local conflict (rc=$RC): $OUT"

# 5. the real user-scope shape (stable disabled, beta enabled), and channels in different scopes or projects: clean
list "$BASE/l5.json" "$(entry "$STABLE" 0.8.61 user false)" "$(entry "$BETA" "$T" user true)"
pv "$BASE/l5.json" --target "$T"
[ "$RC" -eq 0 ] && ! has CONFLICT && ! has MISMATCH && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target $T, 0 problem(s)" ] \
  && ok "stable disabled next to beta enabled in one scope: exit 0, no conflict" || bad "real shape (rc=$RC): $OUT"
list "$BASE/l5b.json" "$(entry "$BETA" "$T" user true)" "$(entry "$STABLE" "$T" local true /work/proj-a)"
pv "$BASE/l5b.json" --target "$T" --project /work/proj-a
[ "$RC" -eq 0 ] && ! has CONFLICT && ok "two channels enabled in DIFFERENT scopes: exit 0" || bad "different scopes (rc=$RC): $OUT"
list "$BASE/l5c.json" "$(entry "$BETA" "$T" local true /work/proj-a)" "$(entry "$STABLE" "$T" local true /work/proj-b)"
pv "$BASE/l5c.json" --target "$T" --project /work/proj-a
[ "$RC" -eq 0 ] && ! has CONFLICT && ok "two channels enabled in two projects of the local scope: exit 0" || bad "different projects (rc=$RC): $OUT"

# 6. entries of other plugins (stale, even enabled) and a plugin whose name only starts like ours are ignored
list "$BASE/l6.json" "$(entry 'other@market' 0.0.1 user true)" "$(entry 'lgtmgate-extra@market' 0.0.1 user true)" "$(entry "$BETA" "$T" user true)"
pv "$BASE/l6.json" --target "$T"
[ "$RC" -eq 0 ] && ! has 'version=0.0.1' && [ "$(last_line)" = "plugin-versions: 1 install(s) of lgtmgate, target $T, 0 problem(s)" ] \
  && ok "other plugins (and lgtmgate-extra) are ignored: exit 0, one install counted" || bad "other plugins (rc=$RC): $OUT"
# --plugin selects another plugin
pv "$BASE/l6.json" --target 9.9.9 --plugin other
[ "$RC" -eq 1 ] && has 'MISMATCH: found 0.0.1, target 9.9.9' && has 'install(s) of other' && ok "--plugin <name> checks that plugin instead" || bad "--plugin (rc=$RC): $OUT"

# 7. no --target: the version of origin/main's manifest, read from the repo of the current directory (never fetched)
git init -q --bare -b main "$BASE/tgt-origin.git"
git clone -q "$BASE/tgt-origin.git" "$BASE/tgt-work" 2>/dev/null
( cd "$BASE/tgt-work" && git config user.email t@t && git config user.name t && mkdir -p .claude-plugin \
  && printf '{\n  "name": "lgtmgate",\n  "version": "%s"\n}\n' "$T" > .claude-plugin/plugin.json \
  && git add -A && git commit -qm init && git push -q origin HEAD:main && git fetch -q origin ) >/dev/null 2>&1
pvrepo() { # <list-file> [args...]: like pv, from the throwaway repo that has an origin/main
  local f="$1"; shift
  OUT="$(cd "$BASE/tgt-work" && PATH="$BASE/bin:$PATH" FAKE_LIST="$f" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
pvrepo "$BASE/l1.json"
[ "$RC" -eq 0 ] && has "target $T" && ok "no --target: the target is the origin/main manifest version (exit 0, printed)" || bad "target from origin/main (rc=$RC): $OUT"
pvrepo "$BASE/l2.json"
[ "$RC" -eq 1 ] && has "MISMATCH: found 1.0.0-beta.3, target $T" && ok "no --target: a stale install against origin/main's version is a mismatch" || bad "stale vs origin/main (rc=$RC): $OUT"
mkdir -p "$BASE/norepo"
( cd "$BASE/norepo" && git init -q . ) >/dev/null 2>&1
pv "$BASE/l1.json"
[ "$RC" -eq 2 ] && has 'cannot read the target version (pass --target <version>)' \
  && ok "no --target and no origin/main: exit 2 naming --target" || bad "no target (rc=$RC): $OUT"
# an unreadable manifest on origin/main: exit 2 as well
git init -q --bare -b main "$BASE/bad-origin.git"
git clone -q "$BASE/bad-origin.git" "$BASE/bad-work" 2>/dev/null
( cd "$BASE/bad-work" && git config user.email t@t && git config user.name t && mkdir -p .claude-plugin \
  && printf 'not json\n' > .claude-plugin/plugin.json && git add -A && git commit -qm init && git push -q origin HEAD:main && git fetch -q origin ) >/dev/null 2>&1
OUT="$(cd "$BASE/bad-work" && PATH="$BASE/bin:$PATH" FAKE_LIST="$BASE/l1.json" bash "$SCRIPT" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && has 'cannot read the target version' && ok "no --target and a manifest that is not JSON: exit 2" || bad "bad manifest (rc=$RC): $OUT"

# 8. fail closed (exit 2) on anything unexpected, never "all fine"
list "$BASE/l8.json" "$(entry "$BETA" "$T" user true)"
FAKE_RC=1 pv "$BASE/l8.json" --target "$T"
[ "$RC" -eq 2 ] && ok "claude exits non-zero: exit 2" || bad "claude fails (rc=$RC): $OUT"
printf 'this is not json\n' > "$BASE/l8b.json"
pv "$BASE/l8b.json" --target "$T"
[ "$RC" -eq 2 ] && ok "claude prints non-JSON: exit 2" || bad "non-JSON (rc=$RC): $OUT"
printf '{"plugins":[]}\n' > "$BASE/l8c.json"
pv "$BASE/l8c.json" --target "$T"
[ "$RC" -eq 2 ] && ok "claude prints a JSON object instead of a list: exit 2" || bad "JSON object (rc=$RC): $OUT"
printf '[{"id":"%s","scope":"user","enabled":true}]\n' "$BETA" > "$BASE/l8d.json"
pv "$BASE/l8d.json" --target "$T"
[ "$RC" -eq 2 ] && has "$BETA" && ok "a matching entry without a version: exit 2 naming the id" || bad "no version (rc=$RC): $OUT"
printf '[{"id":"%s","version":"%s","scope":"user"}]\n' "$BETA" "$T" > "$BASE/l8e.json"
pv "$BASE/l8e.json" --target "$T"
[ "$RC" -eq 2 ] && ok "a matching entry without enabled: exit 2" || bad "no enabled (rc=$RC): $OUT"
printf '[{"id":"%s","version":"%s","scope":"user","enabled":"yes"}]\n' "$BETA" "$T" > "$BASE/l8f.json"
pv "$BASE/l8f.json" --target "$T"
[ "$RC" -eq 2 ] && ok "a matching entry whose enabled is not a boolean: exit 2" || bad "enabled not boolean (rc=$RC): $OUT"
printf '[{"id":"%s","version":"%s","enabled":true}]\n' "$BETA" "$T" > "$BASE/l8g.json"
pv "$BASE/l8g.json" --target "$T"
[ "$RC" -eq 2 ] && ok "a matching entry without a scope: exit 2" || bad "no scope (rc=$RC): $OUT"
# an unexpected entry of ANOTHER plugin is not our business
printf '[42,{"id":"other@m"},%s]\n' "$(entry "$BETA" "$T" user true)" > "$BASE/l8h.json"
pv "$BASE/l8h.json" --target "$T"
[ "$RC" -eq 0 ] && ok "an entry that is not ours and not well-formed is ignored, ours is read: exit 0" || bad "foreign junk entry (rc=$RC): $OUT"
pv "$BASE/l1.json" --bogus
[ "$RC" -eq 2 ] && ok "an unknown option: exit 2" || bad "unknown option (rc=$RC): $OUT"

# 9. no install of the plugin
printf '[]\n' > "$BASE/l9.json"
pv "$BASE/l9.json" --target "$T"
[ "$RC" -eq 0 ] && [ "$(last_line)" = 'plugin-versions: no install of lgtmgate found' ] && ok "no install at all: exit 0 with a no-install note" || bad "no install (rc=$RC): $OUT"
list "$BASE/l9b.json" "$(entry 'other@market' 0.0.1 user true)"
pv "$BASE/l9b.json" --target "$T"
[ "$RC" -eq 0 ] && [ "$(last_line)" = 'plugin-versions: no install of lgtmgate found' ] && ok "installs of other plugins only: exit 0 with a no-install note" || bad "other only (rc=$RC): $OUT"

# 11. shadowed installs (#421: `enabled` is per plugin id, so a user entry next to an applicable local one is shadowed) and the loaded cache
P=/work/proj-a
LOC="$(entry "$BETA" 1.3.0 local true $P)"; USR="$(entry "$BETA" 1.1.0 user true)"
list "$BASE/l11a.json" "$USR" "$LOC"
pv "$BASE/l11a.json" --target 1.3.0 --project $P
[ "$RC" -eq 0 ] && ! has MISMATCH && ! has CONFLICT && has 'SHADOWED by local install version 1.3.0' && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target 1.3.0, 0 problem(s)" ] \
  && ok "a user install shadowed by an applicable local one: exit 0, SHADOWED note, no MISMATCH, no CONFLICT" || bad "shadowed user (rc=$RC): $OUT"
list "$BASE/l11b.json" "$(entry "$STABLE" 1.3.0 user true)" "$USR" "$LOC"
pv "$BASE/l11b.json" --target 1.3.0 --project $P
[ "$RC" -eq 0 ] && ! has MISMATCH && ! has CONFLICT && has 'version=1.1.0 SHADOWED' && ok "a stable user next to a shadowed beta user: no CONFLICT, no MISMATCH on the shadowed one" || bad "two channels (rc=$RC): $OUT"
list "$BASE/l11c.json" "$USR" "$(entry "$BETA" 1.3.0 local true /work/proj-b)"
pv "$BASE/l11c.json" --target 1.3.0 --project $P
[ "$RC" -eq 1 ] && has 'MISMATCH: found 1.1.0' && ! has SHADOWED && has 'OTHER-PROJECT' && ok "a local entry of ANOTHER project does not shadow: the user mismatch still counts" || bad "other project (rc=$RC): $OUT"
list "$BASE/l11d.json" "$USR" "$(entry "$BETA" 1.3.0 project true $P)"
pv "$BASE/l11d.json" --target 1.3.0 --project $P
[ "$RC" -eq 0 ] && has 'SHADOWED by project install version 1.3.0' && ok "a project-scope entry shadows a user one" || bad "project shadows user (rc=$RC): $OUT"
list "$BASE/l11e.json" "$USR" "$(entry "$BETA" 1.2.0 local true $P)"
pv "$BASE/l11e.json" --target 1.3.0 --project $P
[ "$RC" -eq 1 ] && has 'MISMATCH: found 1.2.0' && ! has 'MISMATCH: found 1.1.0' && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target 1.3.0, 1 problem(s)" ] \
  && ok "a stale local install next to a shadowed user one: exit 1 with exactly one problem" || bad "stale local (rc=$RC): $OUT"
mkdir -p "$BASE/proj-cwd"
list "$BASE/l11f.json" "$USR" "$(entry "$BETA" 1.3.0 local true "$BASE/proj-cwd")"
OUT="$(cd "$BASE/proj-cwd" && PATH="$BASE/bin:$PATH" FAKE_LIST="$BASE/l11f.json" bash "$SCRIPT" --target 1.3.0 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && has SHADOWED && ok "without --project the current directory is the project" || bad "default project (rc=$RC): $OUT"
list "$BASE/l11g.json" "$USR" "$LOC"
pv "$BASE/l11g.json" --target 1.3.0 --project $P --loaded-root /cache/$BETA/1.1.0
[ "$RC" -eq 1 ] && has 'LOADED-CACHE: the loaded plugin root is the user install lgtmgate@zigzag-plugins-beta version 1.1.0' && has 'the install for this project is local version 1.3.0' \
  && has 'claude plugin uninstall lgtmgate@zigzag-plugins-beta --scope user' && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target 1.3.0, 1 problem(s)" ] \
  && ok "loaded root is the shadowed user install: exit 1, LOADED-CACHE names it and prints the uninstall command" || bad "loaded cache (rc=$RC): $OUT"
pv "$BASE/l11g.json" --target 1.3.0 --project $P --loaded-root /cache/$BETA/1.3.0
[ "$RC" -eq 0 ] && ! has LOADED-CACHE && ok "loaded root equal to the project install: exit 0, nothing about it" || bad "loaded ok (rc=$RC): $OUT"
pv "$BASE/l11g.json" --target 1.3.0 --project $P --loaded-root /cache/elsewhere/9.9.9
[ "$RC" -eq 2 ] && has 'matches no listed install' && ok "a loaded root matching no listed install: exit 2" || bad "loaded unknown (rc=$RC): $OUT"
pv "$BASE/l11g.json" --target 1.3.0 --project
r1=$RC; pv "$BASE/l11g.json" --target 1.3.0 --loaded-root
[ "$r1" -eq 2 ] && [ "$RC" -eq 2 ] && ok "--project or --loaded-root without a value: exit 2" || bad "missing values (rc=$r1/$RC): $OUT"

# 12. an enabled install scoped to ANOTHER project is listed, never counted (the CLI's `enabled` is per plugin id for the cwd)
list "$BASE/l12a.json" "$(entry "$STABLE" "$T" local true /work/proj-a)" "$(entry "$BETA" "$T" local true /work/proj-a)"
pv "$BASE/l12a.json" --target "$T"
[ "$RC" -eq 0 ] && has OTHER-PROJECT && ! has CONFLICT && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target $T, 0 problem(s)" ] \
  && ok "two channels enabled in ANOTHER project: OTHER-PROJECT, no CONFLICT, exit 0" || bad "other project conflict (rc=$RC): $OUT"
list "$BASE/l12b.json" "$(entry "$BETA" 1.0.0-beta.3 local true /work/proj-b)" "$(entry "$BETA" 1.0.0-beta.4 project true /work/proj-c)"
pv "$BASE/l12b.json" --target "$T"
[ "$RC" -eq 0 ] && ! has MISMATCH && [ "$(printf '%s\n' "$OUT" | grep -c OTHER-PROJECT)" -eq 2 ] && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target $T, 0 problem(s)" ] \
  && ok "an enabled stale install of ANOTHER project is OTHER-PROJECT, not counted: exit 0" || bad "other project stale (rc=$RC): $OUT"
pv "$BASE/l12b.json" --target "$T" --project /work/proj-b
[ "$RC" -eq 1 ] && has 'MISMATCH: found 1.0.0-beta.3' && [ "$(printf '%s\n' "$OUT" | grep -c OTHER-PROJECT)" -eq 1 ] && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target $T, 1 problem(s)" ] \
  && ok "the same install counts when its project is the current one (OTHER-PROJECT only for the others)" || bad "current project counts (rc=$RC): $OUT"

# 13. #480: under the sandbox the CLI cannot read the project's settings files and reports its own install disabled
# (observed payload: scope local, enabled false, projectEnabled false) while the file enables it: exit 2, never LOADED-CACHE
P13="$BASE/proj13"; mkdir -p "$P13/.claude"
RC13="1.3.0-rc.2"
list "$BASE/l13.json" "$(entry "$BETA" "$RC13" local false "$P13")"
printf '{"enabledPlugins":{"%s":true}}\n' "$BETA" > "$P13/.claude/settings.local.json"
pv "$BASE/l13.json" --target "$RC13" --project "$P13" --loaded-root "/cache/$BETA/$RC13"
[ "$RC" -eq 2 ] && ! has LOADED-CACHE && ! has 'claude plugin uninstall' && has "$BETA" && has 'outside the sandbox' \
  && ok "CLI-disabled install enabled by the project settings: exit 2, no LOADED-CACHE, no uninstall command" || bad "cli-disabled, file enabled (rc=$RC): $OUT"
rm -f "$P13/.claude/settings.local.json"
printf '{"enabledPlugins":{"%s":true}}\n' "$BETA" > "$P13/.claude/settings.json"
pv "$BASE/l13.json" --target "$RC13" --project "$P13" --loaded-root "/cache/$BETA/$RC13"
[ "$RC" -eq 2 ] && ! has LOADED-CACHE && ok "the project's settings.json enabling it gives exit 2 as well" || bad "settings.json (rc=$RC): $OUT"
for v in '{"enabledPlugins":{"'$BETA'":false}}' '{"other":1}' '{not json' '[]'; do
  printf '%s\n' "$v" > "$P13/.claude/settings.json"
  pv "$BASE/l13.json" --target "$RC13" --project "$P13" --loaded-root "/cache/$BETA/$RC13"
  [ "$RC" -eq 1 ] && has LOADED-CACHE && ok "settings not enabling it ($v): the old result, LOADED-CACHE exit 1" || bad "settings $v (rc=$RC): $OUT"
done
rm -f "$P13/.claude/settings.json"
pv "$BASE/l13.json" --target "$RC13" --project "$P13" --loaded-root "/cache/$BETA/$RC13"
[ "$RC" -eq 1 ] && has LOADED-CACHE && ok "no settings file: the old result, LOADED-CACHE exit 1" || bad "no settings (rc=$RC): $OUT"
printf '{"enabledPlugins":{"%s":true}}\n' "$BETA" > "$P13/.claude/settings.local.json"
list "$BASE/l13b.json" "$(entry "$BETA" "$RC13" local true "$P13")"
pv "$BASE/l13b.json" --target "$RC13" --project "$P13" --loaded-root "/cache/$BETA/$RC13"
[ "$RC" -eq 0 ] && ok "CLI and file agree (enabled): exit 0" || bad "agree enabled (rc=$RC): $OUT"

# 14. #501: one marketplace declared with different sources in the user, project and local settings
P14="$BASE/projD"; mkdir -p "$P14/.claude"
U14="$CLAUDE_CONFIG_DIR/settings.json"; PS14="$P14/.claude/settings.json"; PL14="$P14/.claude/settings.local.json"
GH='{"source":{"source":"github","repo":"o/r"}}'; URL='{"source":{"source":"url","url":"https://x/m.json"}}'
reset14() { rm -f "$U14" "$PS14" "$PL14"; }
decl() { printf '{"extraKnownMarketplaces":{"%s":%s}}\n' "$2" "$3" > "$1"; }
list "$BASE/l14.json" "$(entry "$BETA" "$T" user true)"
reset14; decl "$U14" m1 "$GH"; decl "$PS14" m1 "$URL"
pv "$BASE/l14.json" --target "$T" --project "$P14"
[ "$RC" -eq 1 ] && has 'MARKETPLACE-CONFLICT: m1' && has "$U14" && has "$PS14" && has 'github o/r' && has 'url https://x/m.json' && [ "$(last_line)" = "plugin-versions: 1 install(s) of lgtmgate, target $T, 1 problem(s)" ] \
  && ok "a github and a url source for one marketplace in user and project settings: exit 1 naming both files" || bad "decl github vs url (rc=$RC): $OUT"
reset14; decl "$PS14" m1 "$GH"; decl "$PL14" m1 "$URL"
pv "$BASE/l14.json" --target "$T" --project "$P14"
[ "$RC" -eq 1 ] && has 'MARKETPLACE-CONFLICT: m1' && has "$PS14" && has "$PL14" && ok "project settings vs local settings: exit 1 naming both files" || bad "decl project vs local (rc=$RC): $OUT"
reset14; decl "$U14" m1 "$GH"; decl "$PS14" m1 "$GH"
pv "$BASE/l14.json" --target "$T" --project "$P14"
[ "$RC" -eq 0 ] && ! has MARKETPLACE-CONFLICT && ok "the same source in two files: exit 0" || bad "decl identical (rc=$RC): $OUT"
reset14; decl "$U14" m1 "$GH"; decl "$PS14" m2 "$URL"
pv "$BASE/l14.json" --target "$T" --project "$P14"
[ "$RC" -eq 0 ] && ! has MARKETPLACE-CONFLICT && ok "different names, each declared once: exit 0" || bad "decl different names (rc=$RC): $OUT"
reset14; decl "$U14" m1 "$GH"; decl "$PS14" m1 '{"source":{"source":"github","repo":"o/r","path":".claude-plugin/marketplace-beta.json"}}'
pv "$BASE/l14.json" --target "$T" --project "$P14"
[ "$RC" -eq 1 ] && has 'MARKETPLACE-CONFLICT: m1' && ok "a github source with an extra path key against the plain one: exit 1 (whole-object comparison)" || bad "decl extra key (rc=$RC): $OUT"
reset14; decl "$U14" m1 "$GH"; decl "$PS14" m1 "$URL"
pv "$BASE/l9.json" --target "$T" --project "$P14"
[ "$RC" -eq 1 ] && has 'MARKETPLACE-CONFLICT: m1' && [ "$(last_line)" = 'plugin-versions: no install of lgtmgate found' ] && ok "a declaration conflict with no install: exit 1, the no-install line stays last" || bad "decl no install (rc=$RC): $OUT"
reset14; decl "$U14" m1 "$GH"; printf '{not json\n' > "$PS14"
pv "$BASE/l14.json" --target "$T" --project "$P14"
[ "$RC" -eq 0 ] && ! has MARKETPLACE-CONFLICT && ok "a settings file that is not JSON is skipped: exit 0" || bad "decl bad json (rc=$RC): $OUT"
reset14

# 15. #516 runbook: a CONFLICT stops the deliver launch, and the line prints the disable command of each channel
SKILL="$ROOT/skills/deliver/SKILL.md"
BUL="$(grep -E '^- .*`CONFLICT` line' "$SKILL" 2>/dev/null)"
if [ -n "$BUL" ] && case "$BUL" in *stop*"claude plugin disable lgtmgate@"*RESTART*consumer-reference*) true ;; *) false ;; esac; then
  ok "runbook: the deliver step 0 CONFLICT bullet stops the launch, names the disable command, the RESTART and its entry"
else
  bad "runbook: deliver SKILL.md has no CONFLICT bullet with stop / claude plugin disable lgtmgate@ / RESTART / consumer-reference: $BUL"
fi
pv "$BASE/l4.json" --target "$T"
[ "$RC" -eq 1 ] && has 'claude plugin disable lgtmgate@zigzag-plugins-beta --scope user' && has 'claude plugin disable lgtmgate@zigzag-plugins --scope user' && has 'then restart the session' \
  && ok "runbook: the CONFLICT line prints the disable command of each channel and the restart" || bad "runbook conflict line (rc=$RC): $OUT"
# the printed form is the runbook's `claude plugin disable lgtmgate@<unwanted channel> --scope <scope>` with the placeholders filled
TPL="$(printf '%s' "$BUL" | grep -o 'claude plugin disable lgtmgate@<[^>]*> --scope <[^>]*>' | head -n 1)"
FILLED="$(printf '%s' "$TPL" | sed -e 's/<unwanted channel>/zigzag-plugins-beta/' -e 's/<scope>/user/')"
[ -n "$TPL" ] && has "$FILLED" && ok "runbook: the printed command has the shape the runbook documents" || bad "runbook shape (template '$TPL', filled '$FILLED'): $OUT"

# 10. read-only: the fake saw `plugin list --json` and nothing else, across every case above
if [ -s "$FAKE_LOG" ] && [ "$(sort -u "$FAKE_LOG")" = "plugin list --json" ]; then
  ok "read-only: every claude call of every case was exactly 'plugin list --json'"
else
  bad "read-only: the fake claude saw other calls: $(sort -u "$FAKE_LOG" | tr '\n' ';')"
fi
if ! grep -vE '^[[:space:]]*#|LOADED-CACHE:|CONFLICT:' "$SCRIPT" | grep -qE 'plugin (update|install|enable|disable|uninstall)|git (fetch|pull|push)|jq'; then
  ok "read-only: the script holds no update/install/enable/disable, no fetch and no jq"
else
  bad "read-only: the script mentions a write command, a fetch or jq"
fi

echo "[plugin-versions test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
