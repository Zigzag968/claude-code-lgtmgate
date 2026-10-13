#!/usr/bin/env bash
# Regression test for scripts/doctor.cjs (#521). Offline: a fake `claude` on PATH prints a canned `claude plugin list --json`
# payload (the only seam, like tests/scripts/test-plugin-versions.sh), every project is a throwaway git repository with a
# local bare origin under $TMPDIR, and CLAUDE_CONFIG_DIR is isolated. The real `claude`, the network, the real home and the
# real tree are never touched. The doctor runs the REAL existing scripts of this repository (plugin root = this repo).
# Cases: --help (six checks, the script each calls, the disk check is new), a clean setup (verdict ok), two enabled channels
# (stop with the disable commands), a check that cannot run (verdict incomplete, never ok), one case per other finding,
# writes nothing (tree, git status and stash identical before and after), exit codes (stop outranks not-run, warn exits 0).
# Trailer: [test-doctor] status=<ok|fail> passed=<n> failed=<n>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/scripts/doctor.cjs"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

T="$(node -p 'require(process.argv[1]).version' "$ROOT/.claude-plugin/plugin.json")"
BETA='lgtmgate@zigzag-plugins-beta'; STABLE='lgtmgate@zigzag-plugins'

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
export CLAUDE_CONFIG_DIR="$BASE/userclaude"; mkdir -p "$CLAUDE_CONFIG_DIR"
unset SSL_CERT_FILE GIT_SSL_CAINFO LGTMGATE_WORKTREE_ROOT FAKE_RC

# entry <id> <version> <scope> <enabled> <installPath> [<projectPath>]: one object of the payload
entry() {
  local proj=""
  [ -z "${6:-}" ] || proj=",\"projectPath\":\"$6\""
  printf '{"id":"%s","version":"%s","scope":"%s","enabled":%s,"installPath":"%s"%s,"projectEnabled":false,"hasUserConfig":false}' "$1" "$2" "$3" "$4" "$5" "$proj"
}
list() {
  local f="$1" sep=""; shift
  printf '[' > "$f"
  while [ $# -gt 0 ]; do printf '%s%s' "$sep" "$1" >> "$f"; sep=","; shift; done
  printf ']\n' >> "$f"
}

# mkproj <name> <with minPluginVersion 1|0> [<body file>]: a git project whose origin/main holds the config and one Nick context file
mkproj() {
  local d="$BASE/$1" o="$BASE/$1.git" body="${3:-}"
  git init -q --bare -b main "$o"
  git clone -q "$o" "$d" 2>/dev/null
  mkdir -p "$d/.claude" "$d/docs"
  node -e '
    const [file, root, withMin, version] = process.argv.slice(1)
    const config = { baseBranch: "main", worktreeRoot: root + "/wt", agentContext: { Nick: ["docs/nick.md"] }, preflight: { envSymlink: "ignore" } }
    if (withMin === "1") config.minPluginVersion = version
    require("fs").writeFileSync(file, JSON.stringify(config, null, 2) + "\n")
  ' "$d/.claude/pipeline.config.json" "$BASE" "$2" "$T"
  if [ -n "$body" ]; then cp "$body" "$d/docs/nick.md"; else printf 'Run the test suite before every push.\n' > "$d/docs/nick.md"; fi
  ( cd "$d" && git config user.email t@t && git config user.name t && git add -A && git commit -qm init && git push -q origin HEAD:main && git fetch -q origin ) >/dev/null 2>&1
}

OUT=""; RC=0
# dr <project> [args...]: the doctor on a project, against the plugin root = this repository; OUT = stdout+stderr
dr() {
  local p="$1"; shift
  OUT="$(PATH="$BASE/bin:$PATH" FAKE_LIST="$BASE/list.json" node "$DOCTOR" --root "$BASE/$p" --plugin-root "$ROOT" --min-free-gb 0 "$@" 2>&1)"; RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
findings() { printf '%s\n' "$OUT" | grep -cE '^(stop|warn|not-run) '; }
verdict() { printf '%s\n' "$OUT" | tail -n 1; }

CLEAN="$(entry "$BETA" "$T" user true "$ROOT")"
list "$BASE/list.json" "$CLEAN"
mkproj clean 1

# 1. --help: six checks, the existing script each calls, the disk check reads `new`
OUT="$(node "$DOCTOR" --help 2>&1)"; RC=$?
n=0; missing=""
for id in installs config template-drift ca-bundle disk agents-context; do
  case "$OUT" in *"  $id: "*) n=$((n + 1)) ;; *) missing="$missing $id" ;; esac
done
scripts_ok=1
for s in $(printf '%s\n' "$OUT" | grep -o 'calls scripts/[^;]*' | sed 's/^calls //'); do [ -f "$ROOT/$s" ] || scripts_ok=0; done
calls="$(printf '%s\n' "$OUT" | grep -c 'calls scripts/')"
[ "$RC" -eq 0 ] && [ "$n" -eq 6 ] && [ "$calls" -eq 5 ] && [ "$scripts_ok" -eq 1 ] && has 'disk: free disk space under the worktree root; new;' \
  && ok "help: six checks listed, five call an existing script of the repository, the disk check reads new" || bad "help (rc=$RC n=$n calls=$calls missing=$missing scripts_ok=$scripts_ok): $OUT"
node "$DOCTOR" --bogus >/dev/null 2>&1; r1=$?
node "$DOCTOR" --min-free-gb >/dev/null 2>&1; r2=$?
node "$DOCTOR" --min-free-gb abc >/dev/null 2>&1; r3=$?
[ "$r1" -eq 2 ] && [ "$r2" -eq 2 ] && [ "$r3" -eq 2 ] && ok "an unknown option, a missing value and a bad number: exit 2" || bad "usage errors (rc=$r1/$r2/$r3)"

# 2. a clean setup: verdict ok, exit 0, no finding line
dr clean
[ "$RC" -eq 0 ] && [ "$(findings)" -eq 0 ] && [ "$(verdict)" = '[doctor] verdict=ok stop=0 warn=0 not-run=0' ] \
  && ok "clean setup: verdict ok, exit 0, no finding line" || bad "clean (rc=$RC): $OUT"

# 3. two channels enabled in one project: stop with the disable command of each channel
list "$BASE/list.json" "$(entry "$STABLE" "$T" user true "$ROOT")" "$CLEAN"
dr clean
[ "$RC" -eq 1 ] && has 'stop channel-conflict:' && has 'claude plugin disable lgtmgate@zigzag-plugins --scope user' && has 'claude plugin disable lgtmgate@zigzag-plugins-beta --scope user' \
  && [ "$(verdict)" = '[doctor] verdict=stop stop=1 warn=0 not-run=0' ] \
  && ok "two enabled channels: stop channel-conflict with the disable command of each channel, verdict stop, exit 1" || bad "two channels (rc=$RC): $OUT"

# 4. a check that cannot run: the verdict is never ok
list "$BASE/list.json" "$CLEAN"
OUT="$(FAKE_RC=1 PATH="$BASE/bin:$PATH" FAKE_LIST="$BASE/list.json" node "$DOCTOR" --root "$BASE/clean" --plugin-root "$ROOT" --min-free-gb 0 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && has 'not-run check-not-run: installs:' && has 'verdict=incomplete' && ! has 'verdict=ok' \
  && ok "claude fails (plugin-versions exit 2): not-run check-not-run, verdict incomplete, exit 2, no verdict=ok" || bad "cannot run (rc=$RC): $OUT"
mkdir -p "$BASE/noman"; ln -s "$ROOT/scripts" "$BASE/noman/scripts"; ln -s "$ROOT/hooks" "$BASE/noman/hooks"
dr clean --plugin-root "$BASE/noman"
[ "$RC" -eq 2 ] && has 'not-run check-not-run: installs: cannot read the target version' && has 'verdict=incomplete' && ! has 'verdict=ok' \
  && ok "no plugin manifest and no --target: not-run, verdict incomplete, exit 2" || bad "no target (rc=$RC): $OUT"
dr clean --plugin-root "$BASE/noman" --target "$T"
[ "$RC" -eq 2 ] && has 'matches no listed install' && ok "a loaded root that matches no install: not-run, never ok" || bad "unmatched loaded root (rc=$RC): $OUT"

# 5. the other findings, one fixture each
list "$BASE/list.json" "$(entry "$BETA" 1.0.0 user true "$ROOT")"
dr clean
[ "$RC" -eq 1 ] && has 'stop version-mismatch:' && has "claude plugin update lgtmgate@zigzag-plugins-beta --scope user" && ok "a stale enabled install: stop version-mismatch with the update command" || bad "version-mismatch (rc=$RC): $OUT"

list "$BASE/list.json" "$(entry "$BETA" 1.0.0 user true "$ROOT")" "$(entry "$BETA" "$T" local true /cache/other "$BASE/clean")"
dr clean
[ "$RC" -eq 1 ] && has 'stop loaded-cache:' && has 'claude plugin uninstall lgtmgate@zigzag-plugins-beta --scope user' && ok "the loaded root is a shadowed install: stop loaded-cache with the uninstall command" || bad "loaded-cache (rc=$RC): $OUT"

list "$BASE/list.json" "$CLEAN" "$(entry "$BETA" "$T" local true /cache/other /work/other-project)"
dr clean
[ "$RC" -eq 0 ] && has 'warn installs-elsewhere:' && has 'claude plugin uninstall lgtmgate@zigzag-plugins-beta --scope local' && has 'verdict=warn' \
  && ok "an install of another project: warn installs-elsewhere with the uninstall command, verdict warn, exit 0" || bad "installs-elsewhere (rc=$RC): $OUT"

list "$BASE/list.json" "$CLEAN"
OUT="$(SSL_CERT_FILE="$BASE/missing.pem" PATH="$BASE/bin:$PATH" FAKE_LIST="$BASE/list.json" node "$DOCTOR" --root "$BASE/clean" --plugin-root "$ROOT" --min-free-gb 0 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && has 'stop ca-bundle-stale:' && has 'restart the session' && ok "SSL_CERT_FILE names a missing file: stop ca-bundle-stale" || bad "ca-bundle-stale (rc=$RC): $OUT"

dr clean --min-free-gb 99999999
[ "$RC" -eq 1 ] && has 'stop low-disk-space:' && has "df -h $BASE/wt" && ok "free space below the minimum: stop low-disk-space with the df command" || bad "low-disk-space (rc=$RC): $OUT"

head -c 7000 /dev/zero | tr '\0' 'a' > "$BASE/body-big.txt"; printf '\n' >> "$BASE/body-big.txt"
mkproj big 1 "$BASE/body-big.txt"
dr big
[ "$RC" -eq 0 ] && has 'warn agents-context-oversize:' && has '/lgtmgate:context audit' && ok "a role text above its cap: warn agents-context-oversize, exit 0" || bad "oversize (rc=$RC): $OUT"

mkproj nomin 0
dr nomin
[ "$RC" -eq 0 ] && has 'warn config-warn:' && has 'recommended key missing: minPluginVersion' && has '/lgtmgate:init' && ok "a recommended config key missing: warn config-warn with the script's own lines" || bad "config-warn (rc=$RC): $OUT"

mkproj drift 1
printf '@.claude/rules/pr-acceptance.md\n' > "$BASE/drift/CLAUDE.md"
dr drift
[ "$RC" -eq 0 ] && has 'warn template-drift-warn:' && has 'imports .claude/rules/pr-acceptance.md' && ok "an obsolete import of the acceptance rule: warn template-drift-warn with the script's lines" || bad "template-drift-warn (rc=$RC): $OUT"

printf 'Bad <project_specifics> tag.\n' > "$BASE/body-bad.txt"
mkproj refused 1 "$BASE/body-bad.txt"
dr refused
[ "$RC" -eq 1 ] && has 'stop agents-context-refused:' && has 'agent-context.cjs exit 3' && ok "a refused context file: stop agents-context-refused, exit 1" || bad "agents-context-refused (rc=$RC): $OUT"

# 6. writes nothing
snapshot() {
  node -e '
    const fs = require("fs"), path = require("path")
    const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name)).flatMap((e) => {
      if (e.name === ".git") return []
      const p = path.join(dir, e.name)
      if (e.isDirectory()) return walk(p)
      const s = fs.statSync(p)
      return [`${p} ${s.size} ${s.mtimeMs}`]
    })
    console.log(walk(process.argv[1]).join("\n"))
  ' "$1"
  git -C "$1" status --porcelain
  git -C "$1" stash list
}
list "$BASE/list.json" "$(entry "$STABLE" "$T" user true "$ROOT")" "$CLEAN"
BEFORE="$(snapshot "$BASE/clean")"; BEFORE_OUT="$(snapshot "$BASE/drift")"
dr clean
r_stop=$RC
dr drift
AFTER="$(snapshot "$BASE/clean")"; AFTER_OUT="$(snapshot "$BASE/drift")"
if [ "$r_stop" -eq 1 ] && [ "$BEFORE" = "$AFTER" ] && [ "$BEFORE_OUT" = "$AFTER_OUT" ] && [ ! -e "$BASE/clean/.claude/pipeline.config.local.json" ] && [ ! -e "$BASE/wt" ]; then
  ok "writes nothing: tree, git status and stash identical before and after a stop run and a warn run, no local config, no worktree root created"
else
  bad "writes nothing (stop rc=$r_stop): $(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -n 5)"
fi
if [ -s "$FAKE_LOG" ] && [ "$(sort -u "$FAKE_LOG")" = "plugin list --json" ]; then
  ok "read-only: every claude call of every case was exactly 'plugin list --json'"
else
  bad "read-only: the fake claude saw other calls: $(sort -u "$FAKE_LOG" | tr '\n' ';')"
fi

# 7. exit codes: a stop outranks a not-run, a warn exits 0
list "$BASE/list.json" "$CLEAN"
OUT="$(SSL_CERT_FILE="$BASE/missing.pem" PATH="$BASE/bin:$PATH" FAKE_LIST="$BASE/list.json" node "$DOCTOR" --root "$BASE/clean" --plugin-root "$BASE/noman" --min-free-gb 0 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && [ "$(verdict)" = '[doctor] verdict=stop stop=1 warn=0 not-run=1' ] && ok "a stop next to a not-run: verdict stop, exit 1" || bad "stop outranks not-run (rc=$RC): $OUT"
dr nomin
[ "$RC" -eq 0 ] && has 'verdict=warn' && ok "a warn alone: exit 0" || bad "warn exit (rc=$RC): $OUT"

# 8. the doctor does not reimplement a check and reads no environment
if ! grep -vE '^[[:space:]]*//' "$DOCTOR" "$ROOT/scripts/lib/doctor-checks.cjs" | grep -qE 'process\.env|writeFile|appendFile|mkdirSync|accept-oversize|git.*fetch'; then
  ok "doctor.cjs and its table read no process.env, write no file, never fetch, never accept an oversize"
else
  bad "doctor source mentions an environment read, a write, a fetch or --accept-oversize"
fi

if [ "$FAIL" -eq 0 ]; then status=ok; else status=fail; fi
echo "[test-doctor] status=$status passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
