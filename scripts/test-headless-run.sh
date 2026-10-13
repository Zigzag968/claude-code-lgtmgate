#!/usr/bin/env bash
# Self-test of scripts/run-workflow-headless.sh (#245): a fake `claude` on PATH records its argv,
# no network, no real session. Checks the assembled no-prompt command line and every refusal.
# bash 3.2 compatible. Trailer: [test-headless-run] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/headless-run-selftest.$$"; mkdir -p "$TMP/bin"
WRAP=scripts/run-workflow-headless.sh
SHIPPED=scripts/headless-settings.json

# expect <label> <expected> <actual>
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
# has <label> <file> <fixed string>
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: [$3] not found in $2"; fi; }

# The result file the fake session announces, and the fake claude itself.
echo '{"summary":"fake","result":{}}' > "$TMP/result.json"
cat > "$TMP/bin/claude" <<STUB
#!/usr/bin/env bash
echo called >> "$TMP/called"
for a in "\$@"; do printf '%s\n' "\$a"; done > "$TMP/argv"
printf '{"type":"system","subtype":"task_notification","output_file":"$TMP/result.json"}\n'
STUB
chmod +x "$TMP/bin/claude"

# run <name> <args...>   runs the wrapper with the fake claude; stdout -> $TMP/<name>.out, stderr -> $TMP/<name>.err
run() {
  name="$1"; shift
  rm -f "$TMP/argv" "$TMP/called"
  PATH="$TMP/bin:$PATH" bash "$WRAP" "$@" </dev/null > "$TMP/$name.out" 2> "$TMP/$name.err"
  echo $?
}

# (a) valid call
rc=$(run valid --out "$TMP/o.json" --max-turns 5 --max-budget-usd 1.5 --settings "$SHIPPED")
expect "valid call exits 0" 0 "$rc"
expect "valid call trailer" "[wf-headless] status=ok out=$TMP/o.json" "$(tail -n 1 "$TMP/valid.out")"
if grep -q '^\[wf-headless\] stream-log=' "$TMP/valid.out"; then ok "stream-log line printed"; else bad "stream-log line missing"; fi
expect "output_file copied to --out" "$(cat "$TMP/result.json")" "$(cat "$TMP/o.json" 2>/dev/null)"
argline="$(tr '\n' ' ' < "$TMP/argv")"
case "$argline" in *"--permission-mode dontAsk "*) ok "argv: --permission-mode dontAsk" ;; *) bad "argv lacks --permission-mode dontAsk: $argline" ;; esac
case "$argline" in *"--permission-prompts none "*) ok "argv: --permission-prompts none" ;; *) bad "argv lacks --permission-prompts none: $argline" ;; esac
case "$argline" in *"--max-turns 5 "*) ok "argv: --max-turns 5" ;; *) bad "argv lacks --max-turns 5: $argline" ;; esac
case "$argline" in *"--max-budget-usd 1.5 "*) ok "argv: --max-budget-usd 1.5" ;; *) bad "argv lacks --max-budget-usd 1.5: $argline" ;; esac
case "$argline" in *"--settings $SHIPPED "*) ok "argv: --settings file" ;; *) bad "argv lacks --settings: $argline" ;; esac
case "$argline" in *"--allowed-tools"*|*"bypass"*|*"dangerously"*) bad "argv carries a forbidden word: $argline" ;; *) ok "argv has no --allowed-tools and no bypass" ;; esac

# (a2) default settings file resolved next to the script
rc=$(run default --out "$TMP/o2.json" --max-turns 3 --max-budget-usd 1)
expect "default settings accepted" 0 "$rc"
case "$(tr '\n' ' ' < "$TMP/argv")" in *"--settings scripts/headless-settings.json "*) ok "default --settings is the shipped file" ;; *) bad "default --settings not the shipped file: $(tr '\n' ' ' < "$TMP/argv")" ;; esac

# refused <label> <stderr cause> <args...>
refused() {
  label="$1"; cause="$2"; shift 2
  rc=$(run refused "$@")
  expect "$label: exit 2" 2 "$rc"
  has "$label: cause named" "$TMP/refused.err" "$cause"
  expect "$label: trailer is error" "[wf-headless] status=error out=$TMP/o3.json" "$(tail -n 1 "$TMP/refused.out")"
  if [ -e "$TMP/called" ]; then bad "$label: claude was called"; else ok "$label: claude not called"; fi
}

# (b) bypass flags
refused "dangerously-skip-permissions" "--dangerously-skip-permissions is refused" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd 1 --dangerously-skip-permissions
refused "allow-dangerously-skip-permissions" "--allow-dangerously-skip-permissions is refused" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd 1 --allow-dangerously-skip-permissions
# (c) permission mode
refused "permission-mode bypassPermissions" "--permission-mode is refused" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd 1 --permission-mode bypassPermissions
refused "permission-mode acceptEdits" "--permission-mode is refused" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd 1 --permission-mode acceptEdits
# (d) settings file naming a bypass mode, or missing
echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > "$TMP/bad-settings.json"
refused "bypass settings file" "names a bypass mode" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd 1 --settings "$TMP/bad-settings.json"
refused "missing settings file" "is missing" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd 1 --settings "$TMP/nope.json"
# (e) (f) caps
refused "missing --max-turns" "--max-turns <n> is required" \
  --out "$TMP/o3.json" --max-budget-usd 1
refused "missing --max-budget-usd" "--max-budget-usd <x> is required" \
  --out "$TMP/o3.json" --max-turns 3
refused "non-numeric --max-turns" "--max-turns must be" \
  --out "$TMP/o3.json" --max-turns lots --max-budget-usd 1
refused "non-numeric --max-budget-usd" "--max-budget-usd must be" \
  --out "$TMP/o3.json" --max-turns 3 --max-budget-usd cheap

# (g) the shipped settings file itself carries no bypass and is accepted (case a above)
if grep -Eq 'bypassPermissions|skipDangerousModePermissionPrompt|dangerously' "$SHIPPED"; then bad "shipped settings names a bypass mode"; else ok "shipped settings names no bypass mode"; fi

rm -rf "$TMP"
if [ "$FAIL" -eq 0 ]; then st=ok; else st=fail; fi
echo "[test-headless-run] status=$st passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
