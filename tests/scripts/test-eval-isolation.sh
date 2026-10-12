#!/usr/bin/env bash
# Offline test (#234): the container run by scripts/run-probe-evals-docker.sh mounts the repo only.
# Sentinel markers at the Docker, Claude and AWS credential paths of a fake HOME must be under no mount
# source and in no recorded docker argument. Limit: this proves the docker invocation (mounts, env names,
# flags), not a real read inside a container; that one is the maintainer's run of the wrapper. Fakes only.
# bash 3.2 safe.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$ROOT/scripts/run-probe-evals-docker.sh"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/eval-isolation-test.XXXXXX")"
# The wrapper mkdirs evals/results; an empty dir left behind makes gate-check stop skipping the eval metric.
[ -d "$ROOT/evals/results" ] && HAD_RESULTS=1 || HAD_RESULTS=0
trap 'rm -rf "$WORK"; [ "$HAD_RESULTS" = 1 ] || rmdir "$ROOT/evals/results" 2>/dev/null' EXIT

pass_count=0
fail_count=0
check() {
  if [ "$2" -eq 1 ]; then echo "PASS - $1"; pass_count=$((pass_count + 1))
  else echo "FAIL - $1"; fail_count=$((fail_count + 1)); fi
}

FH="$WORK/home"
MARK="SENTINEL-$RANDOM-$RANDOM-$RANDOM"
mkdir -p "$FH/.docker" "$FH/.claude" "$FH/.aws"
for f in "$FH/.docker/config.json" "$FH/.claude/.credentials.json" "$FH/.aws/credentials"; do
  printf '%s\n' "$MARK" > "$f"
done

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ncase "$*" in *" -w"*|*"-w") echo fake-token ;; esac\nexit 0\n' > "$FAKEBIN/security"
cat > "$FAKEBIN/docker" <<'SH'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_WORK/docker.args"; done
printf -- '--call--\n' >> "$FAKE_WORK/docker.args"
exit 0
SH
chmod +x "$FAKEBIN"/*

env -u CLAUDE_CODE_OAUTH_TOKEN PATH="$FAKEBIN:$PATH" HOME="$FH" FAKE_WORK="$WORK" bash "$W" probe-provision >/dev/null 2>&1
RC=$?
ok=0; [ "$RC" -eq 0 ] && [ -s "$WORK/docker.args" ] && ok=1
check "the wrapper reaches docker run with fakes (exit $RC)" "$ok"

# mount sources: the argument after each -v, before the first colon
SRC="$WORK/mount.src"
awk 'prev=="-v"{split($0,p,":"); print p[1]} {prev=$0}' "$WORK/docker.args" > "$SRC"
ok=0; [ "$(grep -c '' "$SRC")" -eq 2 ] && [ "$(sed -n 1p "$SRC")" = "$ROOT" ] && [ "$(sed -n 2p "$SRC")" = "$ROOT/evals/results" ] && ok=1
check "exactly two -v sources: the repo root, then evals/results" "$ok"
VOLS="$WORK/mount.vol"
awk 'prev=="-v"{print $0} {prev=$0}' "$WORK/docker.args" > "$VOLS"
ok=0; [ "$(grep -c '' "$VOLS")" -eq 2 ] && [ "$(sed -n 1p "$VOLS")" = "$ROOT:/workspace:ro" ] && [ "$(sed -n 2p "$VOLS")" = "$ROOT/evals/results:/workspace/evals/results" ] && ok=1
check "the repo mount is read-only and the evals/results mount is writable" "$ok"

# no sentinel path is equal to or under any mount source (after realpath)
cat > "$WORK/under.cjs" <<'JS'
const fs = require('fs'), path = require('path')
const [srcFile, ...sentinels] = process.argv.slice(2)
const srcs = fs.readFileSync(srcFile, 'utf8').split('\n').filter(Boolean).map((s) => fs.realpathSync(s))
let bad = 0
for (const s of sentinels) {
  const real = fs.realpathSync(s)
  for (const m of srcs) { const r = path.relative(m, real); if (r === '' || (!r.startsWith('..') && !path.isAbsolute(r))) bad++ }
}
process.exit(bad ? 1 : 0)
JS
ok=0; node "$WORK/under.cjs" "$SRC" "$FH/.docker/config.json" "$FH/.claude/.credentials.json" "$FH/.aws/credentials" && ok=1
check "Docker, Claude and AWS credential paths are under no mount source" "$ok"

ok=1; grep -qF -- "$MARK" "$WORK/docker.args" && ok=0
check "no sentinel marker in any recorded docker argument" "$ok"
ok=1; grep -qF -- "$FH" "$WORK/docker.args" && ok=0
check "the fake HOME path is in no recorded docker argument" "$ok"

ok=1
grep -qE '^(--privileged|--pid|--cap-add|--network|--net|--device|--volumes-from)' "$WORK/docker.args" && ok=0
grep -q 'docker.sock' "$WORK/docker.args" && ok=0
check "no privileged, pid, capability, network, device or docker.sock option" "$ok"

ok=1
awk 'prev=="-e"{print $0} {prev=$0}' "$WORK/docker.args" | while read -r n; do
  case "$n" in CLAUDE_CODE_OAUTH_TOKEN) ;; *) exit 1 ;; esac
done || ok=0
[ "$(awk 'prev=="-e"{c++} {prev=$0} END{print c+0}' "$WORK/docker.args")" -eq 1 ] || ok=0
check "every -e is a bare allowlisted credential variable name" "$ok"

ok=0; [ "$(grep -c -- '--security-opt' "$WORK/docker.args")" -eq 2 ] && ok=1
check "only the two bubblewrap --security-opt flags are present" "$ok"

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
