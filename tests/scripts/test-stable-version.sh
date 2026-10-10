#!/usr/bin/env bash
# Self-test of the stable-version class (#256): every version so far carried a prerelease suffix, so a self-test that
# compares, splits, greps or substitutes the engine version could assume that form and fail only on the first stable
# release (1.0.0 once broke a publish-fixture assertion, on the release pull request itself).
# Builds a scratch copy of the COMMITTED content (git archive HEAD) under the temporary directory, sets the manifest
# version and the BUILD version of the engine to one stable semver there only, and runs the listed tests, each in its
# own copy of it, in parallel. Counter-example: one listed test is edited to assume a prerelease form in another copy;
# the run of that copy must end non-zero and name the test. The working tree is never written.
# Cases: `ok: scratch ...`, `ok: stable ...` (one per listed test), `ok: counter-example ...`, `ok: the suite leaves ...`.
# Left out on purpose (they set their own versions, or need origin/main and the pinned commit): test-guards.sh,
# test-lead-merge.sh, test-plugin-versions.sh, test-init-specifics.sh (passes --plugin-version), test-canonical-guards.sh
# (its stamp-parity is the plain equality of the two values set here).
# bash 3.2 compatible. Trailer: [test-stable-version] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
export ROOT
# shellcheck source=lib/harness.sh
. "$ROOT/tests/scripts/lib/harness.sh"

STABLE=9.9.9
# The version-sensitive tests, as data: a command run at the root of the scratch copy. Kept from the hits of
# git grep -n -i 'beta\|prerelease\|BUILD.version\|plugin.json' -- tests scripts templates, the ones that read the engine
# version of the checkout (BUILD or the manifest) and compare, split, grep or substitute it.
VERSION_SENSITIVE=(
  'bash tests/scripts/test-publish-fixture.sh'                  # reads BUILD.version, asserts the published text holds no literal engine version
  'bash tests/scripts/test-capture-incident.sh'                 # reads BUILD.version, asserts no literal engine version in a capture or its summary
  'bash tests/scripts/test-run-offline.sh'                      # the @@ENGINE_VERSION@@ token, a bumped BUILD version, version probe tokenizing
  'bash tests/templates/test-probe-run.sh'                      # engine parity: a plugin root holding the engine version, one holding another
  'FLOW_SUITE_STRICT=1 node scripts/run-flow-suite.cjs'         # the plugin-version verdict and precedence cases, BUILD.version read by the engine
  'OFFLINE_STRICT=1 node scripts/run-offline.cjs --all fixtures' # fixtures quoting the engine version through the token
)
# The counter-example: this test gets COUNTER_LINE after its first line matching COUNTER_ANCHOR (the test's own ok/bad).
COUNTER_TEST=tests/scripts/test-run-offline.sh
COUNTER_ANCHOR='^TMP='
COUNTER_LINE='if grep -Eq "const BUILD = \{[^}]*version: .[0-9.]*-" workflows/deliver-pipeline.js; then ok "the engine version is a prerelease"; else bad "$0 assumes a prerelease engine version"; fi'

# the repo must come out of the suite exactly as it went in: everything below happens in the scratch directory
TREE0="$(git status --short --untracked-files=all 2>&1)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stable-version.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

set_stable() { # <dir>: the manifest version and the BUILD version of the copy become STABLE
  STABLE="$STABLE" node -e '
const fs = require("fs")
const dir = process.argv[1]
const edit = (file, re) => {
  const text = fs.readFileSync(dir + "/" + file, "utf8")
  if (!re.test(text)) process.exit(2)
  fs.writeFileSync(dir + "/" + file, text.replace(re, (all, head) => head + process.env.STABLE))
}
edit(".claude-plugin/plugin.json", /("version": ")[^"]+/)
edit("workflows/deliver-pipeline.js", /(const BUILD = \{[^}]*\bversion: \x27)[^\x27]+/)
' "$1"
}
versions_of() { # <dir>: "<manifest version> <BUILD version>" of the copy
  node -e '
const fs = require("fs")
const dir = process.argv[1]
const manifest = JSON.parse(fs.readFileSync(dir + "/.claude-plugin/plugin.json", "utf8")).version
const build = /const BUILD = \{[^}]*\bversion: \x27([^\x27]+)/.exec(fs.readFileSync(dir + "/workflows/deliver-pipeline.js", "utf8"))[1]
process.stdout.write(manifest + " " + build)
' "$1"
}
edit_counter() { # <dir>: COUNTER_TEST of the copy gets COUNTER_LINE after its first line matching COUNTER_ANCHOR
  FILE="$1/$COUNTER_TEST" ANCHOR="$COUNTER_ANCHOR" LINE="$COUNTER_LINE" node -e '
const fs = require("fs")
const lines = fs.readFileSync(process.env.FILE, "utf8").split("\n")
const at = lines.findIndex((line) => new RegExp(process.env.ANCHOR).test(line))
if (at < 0) process.exit(2)
lines.splice(at + 1, 0, process.env.LINE)
fs.writeFileSync(process.env.FILE, lines.join("\n"))
'
}
start_job() { # <name> <dir> <command>: the command runs at the root of <dir> in the background, its output and exit code kept in WORK
  ( cd "$2" && bash -c "$3" </dev/null > "$WORK/$1.out" 2>&1; echo $? > "$WORK/$1.rc" ) &
}
rc_of() { cat "$WORK/$1.rc" 2>/dev/null || echo missing; }

git archive HEAD > "$WORK/base.tar" && mkdir "$WORK/base" && tar -xf "$WORK/base.tar" -C "$WORK/base" || { echo "FAIL: cannot build the scratch copy of HEAD"; exit 1; }
if set_stable "$WORK/base" && [ "$(versions_of "$WORK/base")" = "$STABLE $STABLE" ]; then
  ok "scratch copy of HEAD: the manifest version and the BUILD version are both $STABLE"
else
  bad "scratch copy of HEAD: the versions could not be set to $STABLE (got: $(versions_of "$WORK/base" 2>&1))"
fi

i=0
for cmd in "${VERSION_SENSITIVE[@]}"; do
  i=$((i+1))
  cp -R "$WORK/base" "$WORK/job$i" && start_job "job$i" "$WORK/job$i" "$cmd"
done
cp -R "$WORK/base" "$WORK/edited"
if edit_counter "$WORK/edited"; then start_job counter "$WORK/edited" "bash $COUNTER_TEST"; else bad "counter-example: no line matching $COUNTER_ANCHOR in $COUNTER_TEST"; fi
wait

i=0
for cmd in "${VERSION_SENSITIVE[@]}"; do
  i=$((i+1))
  rc="$(rc_of "job$i")"
  if [ "$rc" = 0 ]; then ok "stable $STABLE: $cmd ($(tail -n 1 "$WORK/job$i.out"))"; else bad "stable $STABLE: $cmd exited $rc: $(tail -n 3 "$WORK/job$i.out" 2>/dev/null)"; fi
done

rc="$(rc_of counter)"
last="$(tail -n 1 "$WORK/counter.out" 2>/dev/null)"
failed_in_copy="$(printf '%s' "$last" | sed -n 's/.*failed=\([0-9][0-9]*\)$/\1/p')"
if [ "$rc" != 0 ] && [ "$rc" != missing ] && [ "${failed_in_copy:-0}" -gt 0 ] && grep -qF "FAIL: $COUNTER_TEST assumes a prerelease engine version" "$WORK/counter.out"; then
  ok "counter-example: $COUNTER_TEST edited to assume a prerelease form ends non-zero ($last) and names $COUNTER_TEST"
else
  bad "counter-example: the edited $COUNTER_TEST was not reported (rc=$rc, last line: $last)"
fi

TREE1="$(git status --short --untracked-files=all 2>&1)"
if [ "$TREE0" = "$TREE1" ]; then ok "the suite leaves the working tree untouched"; else bad "the suite changed the working tree: before='$TREE0' after='$TREE1'"; fi

RESULT=ok; [ "$FAIL" -gt 0 ] && RESULT=fail
echo "[test-stable-version] status=$RESULT passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
