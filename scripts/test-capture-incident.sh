#!/usr/bin/env bash
# Self-test of scripts/capture-incident.cjs (+ its .sh wrapper), fully hermetic: the Workflow run
# is a SYNTHETIC one generated into a temp "projects" directory (CLAUDE_PROJECTS_DIR), the output
# goes to a temp git repo. The real Claude Code projects directory is never read.
#
# The generator composes only the key sets the reader whitelists (see the header of
# capture-incident.cjs). It proves the reader against that observed layout, not against Claude
# Code's live storage: the first real capture validates the layout, loudly.
#
# Cases: `ok: relaunch ...` (final pass identified by agentId, captured entries replayed),
# `ok: fail-closed ...` (each refusal names its cause and writes nothing), `ok: usage ...`.
# bash 3.2 compatible. Trailer: [test-capture-incident] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/capture-incident-selftest.$$"
mkdir -p "$TMP"
TMP="$(cd "$TMP" && pwd -P)"
PROJ="$TMP/projects"
REPO="$TMP/repo"
OUTD="$REPO/captures"
CAP="$OUTD/181-t.json"
RUN=wf_test1

git init -q "$REPO"
printf '.pipeline/\ncaptures/\n' > "$REPO/.gitignore"
mkdir -p "$REPO/tracked"

cat > "$TMP/gen.cjs" <<'JS'
// node gen.cjs <projectsDir> <runId> <mutation> [session]
const fs = require('fs')
const path = require('path')
const [projectsDir, runId, mut, session = 'sess1'] = process.argv.slice(2)
const smoke = JSON.parse(fs.readFileSync(path.join(process.env.ROOT, 'fixtures/smoke/auto-lgtm.json'), 'utf8'))
const runDir = path.join(projectsDir, '-proj', session, 'subagents', 'workflows', runId)
const recFile = path.join(projectsDir, '-proj', session, 'workflows', runId + '.json')
fs.mkdirSync(runDir, { recursive: true })
fs.mkdirSync(path.dirname(recFile), { recursive: true })

const rows = [{ type: 'launched' }]
const started = (agentId, key, label) => ({ type: 'started', agentId, key, label, phase: 'p' })
const result = (agentId, key, value) => ({ type: 'result', agentId, key, result: value })

// stale first pass (a relaunch): the same label with a DECOY value
rows.push(started('stale-1', 'v2:aaa111', 'diagnose-issue-123'))
rows.push(result('stale-1', 'v2:aaa111', { decoy: true }))
if (mut === 'earlierdied') rows.push(started('stale-2', 'v2:bbb222', 'scout-issue-123-1'))

// final pass
const final = Object.keys(smoke.calls).map((label, i) => ({ label, agentId: 'ag-' + i, key: 'v2:' + (1000 + i).toString(16), value: smoke.calls[label] }))
const extra = []
if (mut === 'ordering') {
  extra.push({ label: 'decoy-repeat', agentId: 'ag-r1', key: 'v2:r1', value: 'first' })
  extra.push({ label: 'decoy-repeat', agentId: 'ag-r2', key: 'v2:r2', value: 'second' })
}
if (mut === 'arrayvalue') extra.push({ label: 'decoy-array', agentId: 'ag-a1', key: 'v2:a1', value: ['a', 'b'] })
const progress = final.concat(extra)
const journalOrder = mut === 'ordering' ? final.concat(extra.slice().reverse()) : progress
for (const a of journalOrder) {
  rows.push(started(a.agentId, a.key, a.label))
  rows.push(result(a.agentId, a.key, a.value))
}

const rec = {
  runId, status: 'completed', args: Object.assign({}, smoke.args, { simulate: { x: 1 } }),
  result: { status: 'ready' }, agentCount: progress.length,
  workflowProgress: [{ type: 'workflow_phase', title: 'p' }].concat(progress.map((a, i) => ({
    type: 'workflow_agent', index: i, label: a.label, agentId: a.agentId, state: 'done',
  }))),
}
if (mut === 'cachedtrue') rec.workflowProgress[1].cached = true

const lastResult = () => rows.map((r, i) => (r.type === 'result' && r.agentId === 'ag-' + (final.length - 1)) ? i : -1).filter((i) => i >= 0)[0]
switch (mut) {
  case 'unlabeled': { const r = rows.find((x) => x.type === 'started' && x.agentId === 'ag-3'); delete r.label; break }
  case 'orphan': rows.push(result('ag-x', 'v2:zzz', 'x')); break
  case 'unfinished': rows.splice(lastResult(), 1); break
  case 'failedonly': rows[lastResult()] = { type: 'failed', agentId: 'ag-' + (final.length - 1), key: final[final.length - 1].key }; break
  case 'badkey': { const r = rows.find((x) => x.type === 'started' && x.agentId === 'ag-2'); r.key = 'abc123'; break }
  case 'noargs': delete rec.args; break
  case 'killed': rec.status = 'killed'; break
  case 'countmismatch': rec.agentCount += 1; break
  case 'noresultstatus': rec.result = {}; break
  case 'noagentid': delete rec.workflowProgress[2].agentId; break
  // ag-3 (scout-issue-123-1, key K): the LAST event of K among result/failed rows decides.
  case 'failedlast': { // started old-3 K, result K OLD, started ag-3 K, failed K
    const si = rows.findIndex((x) => x.type === 'started' && x.agentId === 'ag-3')
    const K = rows[si].key
    rows.splice(si, 2, started('old-3', K, rows[si].label), result('old-3', K, { decoy: 'OLD' }), rows[si], { type: 'failed', agentId: 'ag-3', key: K })
    break
  }
  case 'failedafter': { // started ag-3 K, result K, failed K
    const si = rows.findIndex((x) => x.type === 'started' && x.agentId === 'ag-3')
    rows.splice(si + 2, 0, { type: 'failed', agentId: 'ag-3', key: rows[si].key })
    break
  }
  case 'failedretry': { // started ag-3 K, failed K, result K (a retry)
    const si = rows.findIndex((x) => x.type === 'started' && x.agentId === 'ag-3')
    rows.splice(si + 1, 0, { type: 'failed', agentId: 'ag-3', key: rows[si].key })
    break
  }
  default: break
}
if (mut !== 'nojournal') fs.writeFileSync(path.join(runDir, 'journal.jsonl'), rows.map((r) => JSON.stringify(r)).join('\n') + '\n')
if (mut !== 'norecord') fs.writeFileSync(recFile, JSON.stringify(rec))
JS
export ROOT

# newrun <mutation> [runId] [session]: a fresh synthetic projects dir + empty output dir
newrun() {
  rm -rf "$PROJ" "$OUTD" "$REPO/.pipeline"
  node "$TMP/gen.cjs" "$PROJ" "${2:-$RUN}" "$1" "${3:-sess1}"
}
# cap [args...]: run the capture from inside the temp repo; sets OUT (stdout+stderr) and RC
cap() {
  OUT=$(cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$@" 2>&1); RC=$?
}
# jsq <js expression over f>: evaluates against the captured file, prints the result as JSON
jsq() {
  node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify(eval(process.argv[2])))' "$CAP" "$1"
}
expect_ok() { # name; asserts a successful capture
  [ "$RC" -eq 0 ] && return 0
  bad "$1: exit $RC: $OUT"; return 1
}

# ---- positive: a relaunched run ---------------------------------------------------------------

newrun base
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch base"; then
  want=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["diagnose-issue-123"]))')
  got=$(jsq 'f.calls["diagnose-issue-123"]')
  nosim=$(jsq '"simulate" in f.args')
  mode=$(node -e 'process.stdout.write((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$CAP")
  if [ "$got" = "$want" ] && [ "$nosim" = "false" ] && [ "$mode" = "600" ]; then
    ok "relaunch kept the final-pass entry (not the stale decoy), dropped args.simulate, file mode 600"
  else
    bad "relaunch final-pass entry: got=$got nosim=$nosim mode=$mode"
  fi
  case "$OUT" in *"[offline] status=ok"*) ok "relaunch capture replays status=ok";; *) bad "relaunch replay: $OUT";; esac
  case "$OUT" in *"unanswered call"*) bad "relaunch has an unanswered call: $OUT";; *) ok "relaunch no unanswered call";; esac
  case "$OUT" in *"next: scripts/publish-fixture.sh"*) ok "next step printed";; *) bad "no next step: $OUT";; esac
  case "$OUT" in *"calls=15 cached=0"*) ok "relaunch cached absent is false (cached=0, calls=15)";; *) bad "cached count: $OUT";; esac
  case "$(cat "$CAP")" in *cached*) bad "relaunch capture carries a cached key";; *) ok "relaunch capture carries no run metadata";; esac
fi

newrun ordering
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch ordering"; then
  got=$(jsq 'f.calls["decoy-repeat"]')
  [ "$got" = '["first","second"]' ] && ok "relaunch order follows workflowProgress, not the journal ($got)" || bad "relaunch order: $got"
fi

newrun arrayvalue
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch array"; then
  got=$(jsq 'f.calls["decoy-array"]')
  [ "$got" = '[["a","b"]]' ] && ok "relaunch array result wrapped ($got)" || bad "relaunch array wrap: $got"
fi

newrun cachedtrue
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch cached"; then
  case "$OUT" in *"cached=1"*) ok "relaunch cached agents are counted";; *) bad "cached=1 expected: $OUT";; esac
fi

newrun earlierdied
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch earlier-pass"; then
  case "$OUT" in *"note:"*"died call scout-issue-123-1"*) ok "relaunch earlier-pass died call tolerated (note only)";; *) bad "earlier-pass note missing: $OUT";; esac
fi

newrun base
cap "$RUN" 181 t
if expect_ok "default out" && [ -f "$REPO/.pipeline/captures/181-t.json" ]; then
  ok "default out lands in .pipeline/captures"
else
  bad "default out: $OUT"
fi

# ---- fail-closed: every refusal names its cause and writes nothing ---------------------------

# refusal <case name> <mutation> <expected substring> [capture args...]
refusal() {
  name="$1"; mut="$2"; want="$3"; shift 3
  newrun "$mut"
  if [ "$#" -gt 0 ]; then cap "$@"; else cap "$RUN" 181 t --out "$OUTD"; fi
  if [ "$RC" -eq 1 ]; then
    case "$OUT" in
      *"$want"*) if [ -e "$CAP" ]; then bad "fail-closed $name: a capture was written"; else ok "fail-closed $name"; fi;;
      *) bad "fail-closed $name: output does not name '$want': $OUT";;
    esac
  else
    bad "fail-closed $name: expected exit 1, got $RC: $OUT"
  fi
}

refusal "journal missing" nojournal "journal.jsonl: missing file"
refusal "record missing" norecord "$RUN.json: missing file"
refusal "unlabeled started" unlabeled "missing label"
refusal "orphan result" orphan "orphan result for key v2:zzz"
refusal "unfinished started" unfinished "died call"
refusal "failed without result" failedonly "died call"
refusal "key prefix not v2" badkey "does not start with v2:"
refusal "record without args" noargs "missing args"
refusal "killed record" killed "status is killed"
refusal "agentCount mismatch" countmismatch "agentCount"
refusal "record without result.status" noresultstatus "missing result.status"
refusal "workflowProgress entry without agentId" noagentid "agentId"
refusal "out not ignored" base "is not ignored by git" "$RUN" 181 t --out "$REPO/tracked"
refusal "run not found" base "not found" wf_nothere 181 t --out "$OUTD"

# out outside any work tree (the ceiling keeps git from discovering a repository above the temp dir)
newrun base
mkdir -p "$TMP/nogit"
OUT=$(cd "$REPO" && GIT_CEILING_DIRECTORIES="$TMP" CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$RUN" 181 t --out "$TMP/nogit/out" 2>&1); RC=$?
case "$OUT" in
  *"not inside a git work tree"*) if [ "$RC" -eq 1 ] && [ ! -e "$TMP/nogit/out" ]; then ok "fail-closed out outside a work tree"; else bad "fail-closed out outside a work tree: rc=$RC or out dir created"; fi;;
  *) bad "fail-closed out outside a work tree: $OUT";;
esac

# the same run id under two sessions is never guessed
newrun base
node "$TMP/gen.cjs" "$PROJ" "$RUN" base sess2
cap "$RUN" 181 t --out "$OUTD"
case "$OUT" in
  *"ambiguous"*) if [ "$RC" -eq 1 ] && [ ! -e "$CAP" ]; then ok "fail-closed ambiguous run"; else bad "fail-closed ambiguous run: rc=$RC or capture written"; fi;;
  *) bad "fail-closed ambiguous run: $OUT";;
esac

# a symlink at the output FILE is never followed (the guard proved the link path ignored, not its target)
# capsep [args...]: like cap, but stdout and stderr kept apart (OUT = stdout, ERR = stderr)
capsep() {
  OUT=$(cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$@" 2>"$TMP/stderr.txt"); RC=$?
  ERR=$(cat "$TMP/stderr.txt")
}
VICTIM="$REPO/tracked/victim.txt"
OUTSIDE="$TMP/outside.txt"
printf 'tracked content\n' > "$VICTIM"
git -C "$REPO" add tracked/victim.txt
printf 'outside content\n' > "$OUTSIDE"
symlink_case() { # name link-target
  name="$1"; target="$2"
  printf 'tracked content\n' > "$VICTIM"; printf 'outside content\n' > "$OUTSIDE"; rm -f "$TMP/does-not-exist.txt"
  newrun base
  mkdir -p "$OUTD"
  ln -s "$target" "$CAP"
  before=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  cap "$RUN" 181 t --out "$OUTD"
  after=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  case "$OUT" in
    *"refused:"*"$CAP"*"symlink"*"status=refused"*)
      if [ "$RC" -eq 1 ] && [ "$before" = "$after" ] && [ -L "$CAP" ]; then ok "fail-closed $name"; else bad "fail-closed $name: rc=$RC target changed or link replaced"; fi;;
    *) bad "fail-closed $name: output does not refuse the symlink: rc=$RC $OUT";;
  esac
}
symlink_case "output file symlinked to a tracked file" "../tracked/victim.txt"
symlink_case "output file symlinked outside the repo" "$OUTSIDE"
symlink_case "output file dangling symlink" "$TMP/does-not-exist.txt"
[ ! -e "$TMP/does-not-exist.txt" ] && ok "fail-closed dangling symlink target not created" || bad "fail-closed dangling symlink target was created"

# a failed call whose LAST event for its key is `failed` is refused, even with an earlier result for that key
failed_refusal() { # name mutation
  refusal "$1" "$2" "failed call scout-issue-123-1 key v2:3eb"
}
failed_refusal "failed after an earlier pass result" failedlast
failed_refusal "failed after its own result" failedafter

newrun failedretry
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "relaunch failed-then-result"; then
  want=$(node -e 'process.stdout.write(JSON.stringify(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls["scout-issue-123-1"]))')
  got=$(jsq 'f.calls["scout-issue-123-1"]')
  [ "$got" = "$want" ] && ok "relaunch failed then a later result (retry) keeps the later result" || bad "relaunch retry: got=$got"
fi

# unexpected file-system errors end as a status line, never a stack trace
error_case() { # name; asserts the result of the last capsep
  name="$1"
  last=$(printf '%s\n' "$OUT" | tail -n 1)
  stack=$(printf '%s\n' "$ERR" | grep -cE '^[[:space:]]+at |node:internal' || true)
  left=$(ls -A "$OUTD" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=error" ] && [ "$stack" = "0" ] && [ "$left" = "0" ] \
     && printf '%s\n' "$ERR" | grep -q '^error: [A-Z]'; then
    ok "error $name: status=error, one stderr line, no stack, nothing written"
  else
    bad "error $name: rc=$RC last='$last' stack=$stack left=$left err=$ERR"
  fi
}
newrun base
mkdir -p "$OUTD"; chmod 500 "$OUTD"
capsep "$RUN" 181 t --out "$OUTD"
chmod 700 "$OUTD"
error_case "read-only output directory"
LONG=$(printf 'a%.0s' $(seq 1 300))
newrun base
mkdir -p "$OUTD"
capsep "$RUN" 181 "$LONG" --out "$OUTD"
error_case "300-character label"

# ---- usage errors (exit 2, before any filesystem access) ---------------------------------------

usage_case() { # name expected-substring args...
  name="$1"; want="$2"; shift 2
  cap "$@"
  case "$OUT" in
    *"$want"*"status=usage-error"*) [ "$RC" -eq 2 ] && ok "usage $name" || bad "usage $name: exit $RC";;
    *) bad "usage $name: $OUT";;
  esac
}
usage_case "bad runId" "runId" '../x' 181 t --out "$OUTD"
usage_case "bad issue" "issue" "$RUN" 12a t --out "$OUTD"
usage_case "bad label" "label" "$RUN" 181 Up --out "$OUTD"
usage_case "unknown flag" "--force" "$RUN" 181 t --force
usage_case "flag without value" "--out" "$RUN" 181 t --out

rm -rf "$TMP"
STATUS=ok; [ "$FAIL" -gt 0 ] && STATUS=fail
echo "[test-capture-incident] status=$STATUS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
