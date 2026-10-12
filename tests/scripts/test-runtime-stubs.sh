#!/usr/bin/env bash
# Each forwarder at an old path reaches the real script in scripts/runtime/ (#312). Removed with the stubs after one release.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
check() { if [ "$2" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# exact-output parity: stub and real give the same stdout, stderr and exit code with no argument
for pair in "templates/probe-run.cjs scripts/runtime/probe-run.cjs" "scripts/agent-context.cjs scripts/runtime/agent-context.cjs" "scripts/init-specifics.cjs scripts/runtime/init-specifics.cjs" "templates/pr-body-splice.cjs scripts/runtime/pr-body-splice.cjs"; do
  set -- $pair
  s_out="$(cd "$ROOT" && node "$1" --no-such-flag 2>&1 </dev/null)"; s_rc=$?
  r_out="$(cd "$ROOT" && node "$2" --no-such-flag 2>&1 </dev/null)"; r_rc=$?
  [ "$s_rc" = "$r_rc" ] && [ "$s_out" = "$r_out" ] && ok=1 || ok=0
  check "$1 forwards to $2 (same output and exit code)" "$ok"
done
for n in pr-state pr-write preflight; do
  s_out="$(cd "$ROOT" && bash "templates/$n.sh" --no-such-flag 2>&1 </dev/null)"; s_rc=$?
  r_out="$(cd "$ROOT" && bash "scripts/runtime/$n.sh" --no-such-flag 2>&1 </dev/null)"; r_rc=$?
  [ "$s_rc" = "$r_rc" ] && [ "$s_out" = "$r_out" ] && ok=1 || ok=0
  check "templates/$n.sh forwards to scripts/runtime/$n.sh (same output and exit code)" "$ok"
done

# module.exports of the node stubs equals the real module's
for pair in "templates/probe-run.cjs scripts/runtime/probe-run.cjs" "scripts/agent-context.cjs scripts/runtime/agent-context.cjs" "scripts/init-specifics.cjs scripts/runtime/init-specifics.cjs" "templates/pr-body-splice.cjs scripts/runtime/pr-body-splice.cjs"; do
  set -- $pair
  k="$(cd "$ROOT" && node -e "const a=require('./$1'),b=require('./$2');process.stdout.write(a===b||JSON.stringify(Object.keys(a).sort())===JSON.stringify(Object.keys(b).sort())?'1':'0')" 2>/dev/null)"
  [ "$k" = 1 ] && ok=1 || ok=0
  check "require('$1') exports the keys of $2" "$ok"
done

# the sourced stub defines gh_read_class
t="$(bash -c ". '$ROOT/templates/gh-read-class.sh' && type gh_read_class >/dev/null 2>&1 && echo 1" 2>/dev/null)"
[ "$t" = 1 ] && ok=1 || ok=0
check "sourcing templates/gh-read-class.sh defines gh_read_class" "$ok"

# every stub names the real folder in its first lines
for f in templates/probe-run.cjs templates/pr-state.sh templates/pr-write.sh templates/preflight.sh templates/pr-body-splice.cjs templates/gh-read-class.sh scripts/agent-context.cjs scripts/init-specifics.cjs; do
  head -n 3 "$ROOT/$f" | grep -q scripts/runtime && ok=1 || ok=0
  check "$f is a forwarder" "$ok"
done

echo "[test-runtime-stubs] status=$([ "$fail" = 0 ] && echo ok || echo fail) passed=$pass failed=$fail"
[ "$fail" = 0 ]
