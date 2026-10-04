#!/usr/bin/env bash
# Regression test for scripts/plugin-versions.sh (#233). Offline: a fake `claude` on PATH prints a canned
# `claude plugin list --json` payload (fields copied from a real one: id, version, scope, enabled, installPath,
# projectPath, projectEnabled, hasUserConfig) and logs its argv; the target version comes from --target or from a
# throwaway git repo under $TMPDIR. The real `claude`, the network and the real tree are never touched.
# Cases: install equal to the target, stale install, disabled stale install, both channels enabled in one scope and
# project, the real user-scope shape (stable disabled, beta enabled), channels in different scopes or projects,
# other plugins ignored, target from origin/main, fail closed (exit 2) on every unexpected payload, no install,
# --plugin, and read-only (the fake only ever sees `plugin list --json`).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
pv "$BASE/l4b.json" --target "$T"
[ "$RC" -eq 1 ] && has 'CONFLICT: both channels enabled in scope=local project=/work/proj-a' \
  && ok "both channels enabled in the same project of a local scope: CONFLICT" || bad "local conflict (rc=$RC): $OUT"

# 5. the real user-scope shape (stable disabled, beta enabled), and channels in different scopes or projects: clean
list "$BASE/l5.json" "$(entry "$STABLE" 0.8.61 user false)" "$(entry "$BETA" "$T" user true)"
pv "$BASE/l5.json" --target "$T"
[ "$RC" -eq 0 ] && ! has CONFLICT && ! has MISMATCH && [ "$(last_line)" = "plugin-versions: 2 install(s) of lgtmgate, target $T, 0 problem(s)" ] \
  && ok "stable disabled next to beta enabled in one scope: exit 0, no conflict" || bad "real shape (rc=$RC): $OUT"
list "$BASE/l5b.json" "$(entry "$BETA" "$T" user true)" "$(entry "$STABLE" "$T" local true /work/proj-a)"
pv "$BASE/l5b.json" --target "$T"
[ "$RC" -eq 0 ] && ! has CONFLICT && ok "two channels enabled in DIFFERENT scopes: exit 0" || bad "different scopes (rc=$RC): $OUT"
list "$BASE/l5c.json" "$(entry "$BETA" "$T" local true /work/proj-a)" "$(entry "$STABLE" "$T" local true /work/proj-b)"
pv "$BASE/l5c.json" --target "$T"
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

# 10. read-only: the fake saw `plugin list --json` and nothing else, across every case above
if [ -s "$FAKE_LOG" ] && [ "$(sort -u "$FAKE_LOG")" = "plugin list --json" ]; then
  ok "read-only: every claude call of every case was exactly 'plugin list --json'"
else
  bad "read-only: the fake claude saw other calls: $(sort -u "$FAKE_LOG" | tr '\n' ';')"
fi
if ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE 'plugin (update|install|enable|disable|uninstall)|git (fetch|pull|push)|jq'; then
  ok "read-only: the script holds no update/install/enable/disable, no fetch and no jq"
else
  bad "read-only: the script mentions a write command, a fetch or jq"
fi

echo "[plugin-versions test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
