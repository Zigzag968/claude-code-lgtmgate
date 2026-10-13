#!/usr/bin/env bash
# Self-test of scripts/canary-preflight.sh (#235): fake `git`, `gh` and `claude` on PATH, no network,
# no real git state. Each failing prerequisite must exit non-zero and name its cause and its fix.
# bash 3.2 compatible. Trailer: [test-canary-preflight] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/canary-preflight-selftest.$$"; mkdir -p "$TMP/bin" "$TMP/consumer/.claude"
SCRIPT=scripts/canary-preflight.sh
CONSUMER="$TMP/consumer"
TARGET=1.4.0

expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: [$3] not found in $2"; fi; }

echo '{"baseBranch":"main","repo":"acme/canary"}' > "$CONSUMER/.claude/pipeline.config.json"

# fake git: behaviour driven by env FAKE_BEHIND
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-C" ] && shift 2
case "$1" in
  rev-parse) echo .git ;;
  fetch) exit 0 ;;
  rev-list) echo "${FAKE_BEHIND:-0}" ;;
  remote) echo "git@github.com:acme/canary.git" ;;
  *) exit 1 ;;
esac
STUB
# fake gh: labels driven by env FAKE_LABELS
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_LABELS:-}"
STUB
# fake claude: `plugin list --json` driven by env FAKE_PLUGIN_VERSION (empty = no install)
cat > "$TMP/bin/claude" <<STUB
#!/usr/bin/env bash
if [ -z "\${FAKE_PLUGIN_VERSION:-}" ]; then echo '[]'; exit 0; fi
printf '[{"id":"lgtmgate@beta","version":"%s","scope":"local","enabled":true,"projectPath":"$CONSUMER"}]\n' "\$FAKE_PLUGIN_VERSION"
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/gh" "$TMP/bin/claude"

# run <name>   (env set by the caller)
run() {
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" --consumer "$CONSUMER" --issue 235 --target "$TARGET" </dev/null > "$TMP/$1.out" 2> "$TMP/$1.err"
  echo $?
}

# (a) all prerequisites present
rc=$(FAKE_BEHIND=0 FAKE_PLUGIN_VERSION=$TARGET FAKE_LABELS="type:feature status:ready" run ok)
expect "all present: exit 0" 0 "$rc"
expect "all present: last line" "canary-preflight: ok" "$(tail -n 1 "$TMP/ok.out")"

# (b) clone behind
rc=$(FAKE_BEHIND=3 FAKE_PLUGIN_VERSION=$TARGET FAKE_LABELS="status:ready" run behind)
expect "clone behind: exit 1" 1 "$rc"
has "clone behind: cause" "$TMP/behind.out" "FAIL clone-behind"
has "clone behind: fix" "$TMP/behind.out" "Fix: git -C $CONSUMER merge --ff-only origin/main"
expect "clone behind: last line" "canary-preflight: 1 problem(s)" "$(tail -n 1 "$TMP/behind.out")"

# (c) stale plugin
rc=$(FAKE_BEHIND=0 FAKE_PLUGIN_VERSION=1.3.0 FAKE_LABELS="status:ready" run stale)
expect "stale plugin: exit 1" 1 "$rc"
has "stale plugin: cause" "$TMP/stale.out" "FAIL stale-plugin"
has "stale plugin: detail" "$TMP/stale.out" "MISMATCH: found 1.3.0, target $TARGET"
has "stale plugin: fix" "$TMP/stale.out" "Fix: claude plugin update lgtmgate@beta --scope local"

# (d) no plugin installed
rc=$(FAKE_BEHIND=0 FAKE_PLUGIN_VERSION="" FAKE_LABELS="status:ready" run noplugin)
expect "no plugin: exit 1" 1 "$rc"
has "no plugin: cause" "$TMP/noplugin.out" "FAIL no-plugin"
has "no plugin: fix" "$TMP/noplugin.out" "Fix: install lgtmgate for the consumer scope"

# (e) non-terminal state file
mkdir -p "$CONSUMER/.pipeline"
echo '{"status":"dev"}' > "$CONSUMER/.pipeline/run1.json"
rc=$(FAKE_BEHIND=0 FAKE_PLUGIN_VERSION=$TARGET FAKE_LABELS="status:ready" run state)
expect "state left: exit 1" 1 "$rc"
has "state left: cause" "$TMP/state.out" "FAIL state-left"
has "state left: fix" "$TMP/state.out" "Fix: capture the raw run data"
rm -f "$CONSUMER/.pipeline/run1.json"

# (f) issue not status:ready
rc=$(FAKE_BEHIND=0 FAKE_PLUGIN_VERSION=$TARGET FAKE_LABELS="type:feature" run label)
expect "issue not ready: exit 1" 1 "$rc"
has "issue not ready: cause" "$TMP/label.out" "FAIL issue-not-ready"
has "issue not ready: fix" "$TMP/label.out" "Fix: gh api -X POST repos/acme/canary/issues/235/labels"

# (g) several problems are all reported
rc=$(FAKE_BEHIND=1 FAKE_PLUGIN_VERSION=1.3.0 FAKE_LABELS="" run many)
expect "several problems: exit 1" 1 "$rc"
expect "several problems: count" "canary-preflight: 3 problem(s)" "$(tail -n 1 "$TMP/many.out")"

# (h) cannot decide: no pipeline config
mv "$CONSUMER/.claude/pipeline.config.json" "$TMP/cfg.bak"
rc=$(FAKE_BEHIND=0 FAKE_PLUGIN_VERSION=$TARGET FAKE_LABELS="status:ready" run noconfig)
expect "no config: exit 2" 2 "$rc"
has "no config: stderr" "$TMP/noconfig.err" "no .claude/pipeline.config.json"
mv "$TMP/cfg.bak" "$CONSUMER/.claude/pipeline.config.json"

rm -rf "$TMP"
if [ "$FAIL" -eq 0 ]; then st=ok; else st=fail; fi
echo "[test-canary-preflight] status=$st passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
