#!/usr/bin/env bash
# positive, #195, #213 and fail-closed cases (sourced by tests/scripts/test-capture-incident.sh, never executed).
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
  NCALLS=$(node -e 'process.stdout.write(String(Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls).length))')
  case "$OUT" in *"calls=$NCALLS cached=0"*) ok "relaunch cached absent is false (cached=0, calls=$NCALLS)";; *) bad "cached count: $OUT";; esac
  case "$(cat "$CAP")" in *cached*) bad "relaunch capture carries a cached key";; *) ok "relaunch capture carries no run metadata";; esac
fi

# ---- #195: the plugin version probe answer follows the engine version, never the version of the day ----
# A real run with a pluginRoot and no probeRunPath journals the LITERAL engine version in that answer; lead-merge bumps the
# version at every merge, so a literal kept in a fixture goes red at the next bump. The capture writes the token instead
# when the answer is the run's engine (the repo's BUILD, or the version the run's pluginRoot names).
BUMPED="$TMP/engine-bumped.js"
bumped_engine "$BUMPED"
vprobe() { # <js over the version probe entry e>: evaluates against the captured file
  node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const e=f.calls["probe-123-lines-plugin-version-r0"];process.stdout.write(JSON.stringify(eval(process.argv[2])))' "$CAP" "$1"
}
newrun liveversion
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "live version"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@") && e.verify.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "live version: the version probe answer (line and verify) is the token in the capture" || bad "live version: token missing: $(vprobe 'e')"
  ENGV=$(node -e 'process.stdout.write(/const BUILD = \{[^}]*\bversion: \x27([^\x27]+)/.exec(require("fs").readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8"))[1])')
  case "$(cat "$CAP")" in *"PLUGIN-VERSION:$ENGV"*) bad "live version: the literal $ENGV is still in the capture";; *) ok "live version: no literal engine version left in the capture";; esac
  out=$(node scripts/run-offline.cjs "$CAP" --fp "$BUMPED" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "live version: the capture replays green against an engine whose version was bumped";; *) bad "live version: bumped replay: $out";; esac
  out=$(node scripts/run-offline.cjs "$CAP" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "live version: and against the engine of the repo";; *) bad "live version: replay: $out";; esac
  case "$OUT" in *" version-source=checkout retries="*) ok "buildStamp absent: the checkout BUILD rule still tokenizes (version-source=checkout)";; *) bad "no stamp, live version: summary: $OUT";; esac
fi

newrun oldrun
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "older run"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "older run: the answer naming the run's pluginRoot version is the token (replays against today's engine)" || bad "older run: $(vprobe 'e')"
  case "$OUT" in *" version-source=pluginRoot retries="*) ok "buildStamp absent: the pluginRoot segment rule still tokenizes (version-source=pluginRoot)";; *) bad "no stamp, older run: summary: $OUT";; esac
fi

newrun skewrun
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "skew incident"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:1.0.0-beta.3") && !e.line.includes("@@")')" = "true" ] && ok "skew incident: the stale root's version stays literal (the incident is the difference)" || bad "skew incident: $(vprobe 'e')"
fi

# ---- #213: the run's own buildStamp decides which answer is the run's engine ----
# The run record's `result.buildStamp` is the engine's declaration of its version. When it carries one, it is the only
# authority: an answer equal to it is stored as the token (so a capture of an older engine's run replays against a later
# engine), an answer that differs stays literal (a real skew replays as a skew). Without a usable stamp, the checkout BUILD /
# pluginRoot rules above apply. The summary names the source, never an answer.
newrun stampold
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "stamp older run"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@") && e.verify.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "buildStamp equal to the answer: line and verify are the token (the root names no version)" || bad "stamp old: $(vprobe 'e')"
  case "$(cat "$CAP")" in *"1.0.0-beta.3"*) bad "buildStamp equal to the answer: the literal is still in the capture";; *) ok "buildStamp equal to the answer: no literal version left in the capture";; esac
  case "$OUT" in *"[offline] status=ok"*"version-source=stamp retries="*) ok "buildStamp equal to the answer: the capture replays its own capture, version-source=stamp";; *) bad "stamp old: summary: $OUT";; esac
  out=$(node scripts/run-offline.cjs "$CAP" --fp "$BUMPED" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "buildStamp older run replays green against a bumped engine";; *) bad "stamp old: bumped replay: $out";; esac
  out=$(node scripts/run-offline.cjs "$CAP" 2>&1 | tail -n 1)
  case "$out" in *"status=ok passed=1"*) ok "buildStamp older run replays green against the engine of the repo";; *) bad "stamp old: replay: $out";; esac
  summary=$(printf '%s\n' "$OUT" | grep '^\[capture-incident\] status=')
  ENGV=$(node -e 'process.stdout.write(/const BUILD = \{[^}]*\bversion: \x27([^\x27]+)/.exec(require("fs").readFileSync(process.env.ROOT+"/workflows/deliver-pipeline.js","utf8"))[1])')
  case "$summary" in *"1.0.0-beta.3"*|*"$ENGV"*|*"PLUGIN-VERSION"*) bad "buildStamp summary prints a version: $summary";; *"version-source=stamp"*) ok "buildStamp summary names the source and prints no answer";; *) bad "buildStamp summary: $summary";; esac
fi

newrun stampdiff
cap "$RUN" 181 t --out "$OUTD"
if [ "$RC" -eq 1 ] && [ -f "$CAP" ]; then
  case "$OUT" in *"[capture-incident] status=refused"*) ok "buildStamp different from the answer: the capture refuses its own replay (a skew vs the recorded ready)";; *) bad "stamp diff: no refusal: $OUT";; esac
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:1.0.0-beta.3") && !e.line.includes("@@") && !e.verify.includes("@@")')" = "true" ] && ok "buildStamp different from the answer: the answer stays literal, the capture is kept" || bad "stamp diff: $(vprobe 'e')"
else
  bad "stamp diff: expected exit 1 with the capture kept, got exit $RC: $OUT"
fi

newrun stampskew
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "stamp skew incident"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:1.0.0-beta.3") && !e.line.includes("@@")')" = "true" ] && ok "buildStamp with a skew incident: the answer stays literal (the incident is the difference)" || bad "stamp skew: $(vprobe 'e')"
  [ "$(jsq 'f.expect.status')" = '"escalate"' ] && ok "buildStamp with a skew incident: the capture replays as the recorded escalate" || bad "stamp skew: expect $(jsq 'f.expect')"
  case "$OUT" in *" version-source=none retries="*) ok "buildStamp with a skew incident: version-source=none";; *) bad "stamp skew: summary: $OUT";; esac
fi

newrun stampbad
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "stamp unparseable"; then
  [ "$(vprobe 'e.line.includes("PLUGIN-VERSION:@@ENGINE_VERSION@@")')" = "true" ] && ok "buildStamp unparseable: falls back to the pluginRoot segment (token)" || bad "stamp bad: $(vprobe 'e')"
  case "$OUT" in *" version-source=pluginRoot retries="*) ok "buildStamp unparseable: version-source=pluginRoot";; *) bad "stamp bad: summary: $OUT";; esac
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
      *"$want"*) if [ -e "$CAP" ]; then bad "${KIND:-fail-closed} $name: a capture was written"; else ok "${KIND:-fail-closed} $name"; fi;;
      *) bad "${KIND:-fail-closed} $name: output does not name '$want': $OUT";;
    esac
  else
    bad "${KIND:-fail-closed} $name: expected exit 1, got $RC: $OUT"
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
VICTIM="$REPO/tracked/victim.txt"
OUTSIDE="$TMP/outside.txt"
printf 'tracked content\n' > "$VICTIM"
git -C "$REPO" add tracked/victim.txt
git -C "$REPO" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init tracked/victim.txt
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

# a HARD LINK at the output file is a regular file whose inode is shared: truncating it would
# overwrite the other path (a tracked file, a file outside the repo). The descriptor is checked
# (nlink === 1) before anything is written.
hardlink_case() { # name link-source
  name="$1"; source="$2"
  printf 'tracked content\n' > "$VICTIM"; printf 'outside content\n' > "$OUTSIDE"
  newrun base
  mkdir -p "$OUTD"
  ln "$source" "$CAP"
  before=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  cap "$RUN" 181 t --out "$OUTD"
  after=$(cksum < "$VICTIM")$(cksum < "$OUTSIDE")
  dirty=$(git -C "$REPO" status --porcelain -- tracked/victim.txt)
  last=$(printf '%s\n' "$OUT" | tail -n 1)
  case "$OUT" in
    *"refused:"*"$CAP"*"more than one hard link"*)
      if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=refused" ] && [ "$before" = "$after" ] && [ -z "$dirty" ]; then
        ok "fail-closed $name"
      else
        bad "fail-closed $name: rc=$RC last='$last' target changed or git dirty='$dirty'"
      fi;;
    *) bad "fail-closed $name: output does not refuse the hard link: rc=$RC target-changed=$([ "$before" = "$after" ] && echo no || echo YES) $OUT";;
  esac
}
hardlink_case "output file hard link to a tracked file" "$VICTIM"
hardlink_case "output file hard link to a file outside the repo" "$OUTSIDE"

# a FIFO at the output file must not hang the script (open(O_WRONLY) blocks without a reader)
newrun base
mkdir -p "$OUTD"
mkfifo "$CAP"
rm -f "$TMP/fifo.rc"
( cd "$REPO" && CLAUDE_PROJECTS_DIR="$PROJ" bash "$ROOT/scripts/capture-incident.sh" "$RUN" 181 t --out "$OUTD" >"$TMP/fifo.out" 2>&1; echo $? > "$TMP/fifo.rc" ) &
FIFO_PID=$!
tries=0
while [ ! -f "$TMP/fifo.rc" ] && [ "$tries" -lt 50 ]; do sleep 0.2; tries=$((tries+1)); done
if [ -f "$TMP/fifo.rc" ]; then
  wait "$FIFO_PID" 2>/dev/null
  RC=$(cat "$TMP/fifo.rc"); OUT=$(cat "$TMP/fifo.out"); last=$(printf '%s\n' "$OUT" | tail -n 1)
  case "$OUT" in
    *"refused:"*"$CAP"*"not a regular file"*)
      if [ "$RC" -eq 1 ] && [ "$last" = "[capture-incident] status=refused" ]; then ok "fail-closed output file is a FIFO"; else bad "fail-closed output file is a FIFO: rc=$RC last='$last'"; fi;;
    *) bad "fail-closed output file is a FIFO: output does not refuse it: rc=$RC $OUT";;
  esac
else
  # hung: hold the FIFO open read-write for a moment (a stray blocked open succeeds against it) until the job ends
  tries=0
  while [ ! -f "$TMP/fifo.rc" ] && [ "$tries" -lt 10 ]; do ( exec 9<>"$CAP"; sleep 1 ); tries=$((tries+1)); done
  bad "fail-closed output file is a FIFO: the script was still blocked after 10 s (hang)"
fi

# a pre-existing REGULAR single-link ignored file is still overwritten (and fully truncated)
newrun base
mkdir -p "$OUTD"
node -e 'process.stdout.write("x".repeat(200000))' > "$CAP"
cap "$RUN" 181 t --out "$OUTD"
if expect_ok "overwrite regular file" && [ "$(jsq 'f.name')" = '"181-t"' ]; then
  ok "output file regular single-link ignored file is overwritten and truncated"
else
  bad "output file regular overwrite: rc=$RC $OUT"
fi

# a failed call whose LAST event for its key is `failed` is refused, even with an earlier result for that key
SCOUT_KEY=$(node -e 'const l=Object.keys(require(process.env.ROOT+"/fixtures/smoke/auto-lgtm.json").calls);process.stdout.write("v2:"+(1000+l.indexOf("scout-issue-123-1")).toString(16))') # same key rule as gen.cjs
failed_refusal() { # name mutation
  refusal "$1" "$2" "failed call scout-issue-123-1 key $SCOUT_KEY"
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

