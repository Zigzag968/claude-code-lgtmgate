#!/usr/bin/env bash
# The E2 gate metrics (epic #66, issue #158), executable. `gate-check.sh e2 [--ci]` prints ONE line per
# metric, `<PASS|FAIL|SKIP> <metric>: <detail>`, from evidence in the repository, then one summary
# line (`gate e2: ... -> PASS|FAIL|INCOMPLETE`), and exits 1 when a metric FAILs. Offline: no `claude`
# call, no network. node is the JSON/regex reader, as in probe-eval-gate.sh. bash 3.2 safe.
#
# Metrics
#   incidents  `OFFLINE_STRICT=1 node scripts/run-offline.cjs --all fixtures` is green AND every E2
#              incident (E2_INCIDENTS below: #10 #14 #27 #32 #40) still has a fixtures/incidents/<n>-*.json
#              (run-offline alone passes when a fixture is deleted).
#   eval       (a) every evals/probe-*/ case still pins its probe-line and verify-ok graders: probe-line is
#              `^\s*<the whole PROBE line, regex-escaped>\s*$` on the last message (name, exit, 64-hex sha,
#              64-hex cmd, json), verify-ok is the tool_result `VERIFY ok line=PROBE name= exit= sha=` of the
#              SAME line, neither with flags, so a generic or weakened grader fails; (b) scripts/probe-eval-gate.sh
#              on evals/results (>= 29/30 fully passed runs). tests/scripts/test-probe-evals.sh proves the pinned line
#              equals the real one by running the case; (a) is the offline contract of the grader text.
#   canary     docs/gate/e2-canary.json lists >= 2 distinct canary runs (distinct `pr`), each ending `ready`
#              or `merged`, each with no non-terminal `.pipeline/*.json` state left. Record format, numbers
#              are those of the canary repository:
#                {"runs":[{"issue":1,"pr":3,"status":"merged","pipelineStates":[{"file":"x.json","status":"merged"}]}]}
#              pipelineStates = every `.pipeline/*.json` found when the run ended (`[]` if none). Non-terminal =
#              an in-flight status of hooks/Stop-supervise-runs.sh (INFLIGHT below). A malformed record FAILs.
#
# --ci: for a run where evidence produced outside the repository is absent (guards CI). A metric whose
# evidence is missing there reports SKIP instead of FAIL: the eval results (evals/results is git-ignored,
# written by scripts/run-probe-evals.sh) and a canary record that is absent or lists fewer than 2 qualifying
# runs. Evidence that IS in the repository is enforced either way (incident fixtures and replay, grader
# pins, a malformed canary record). Without --ci (the gate) nothing is skipped. A run with SKIP and no FAIL
# ends `-> INCOMPLETE`, exit 0: it is not gate evidence.
#
# Env (test seams, optional)
#   GATE_ROOT                repo root holding fixtures/, evals/, docs/gate/ (default: parent of scripts/);
#                            the engine and run-offline.cjs always come from this script's own checkout
#   PROBE_EVALS_RESULTS_DIR  results dir (default: <root>/evals/results), same variable as run-probe-evals.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="${GATE_ROOT:-$SELF_ROOT}"

E2_INCIDENTS="10 14 27 32 40"
INFLIGHT="in-progress plan dev review"   # the in-flight whitelist of hooks/Stop-supervise-runs.sh
CANARY_NEED=2
CANARY_RECORD="docs/gate/e2-canary.json"

usage() { echo "usage: gate-check.sh e2 [--ci]" >&2; exit 2; }
[ "${1:-}" = "e2" ] || usage
shift
CI_MODE=0
for a in "$@"; do
  case "$a" in --ci) CI_MODE=1 ;; *) usage ;; esac
done
command -v node >/dev/null 2>&1 || { echo "gate-check: node not found on PATH" >&2; exit 2; }

n_pass=0; n_fail=0; n_skip=0
emit() { # <PASS|FAIL|SKIP> <metric> <detail>
  case "$1" in PASS) n_pass=$((n_pass + 1)) ;; FAIL) n_fail=$((n_fail + 1)) ;; SKIP) n_skip=$((n_skip + 1)) ;; esac
  echo "$1 $2: $3"
}
oneline() { printf '%s' "${1//$'\n'/ | }"; }

# The two node readers live in functions: a heredoc inside $(...) breaks bash 3.2 on unbalanced quotes.
pins_js() { cat <<'JS'
const fs = require('fs')
const path = require('path')
const evals = process.argv[1]
const bad = []
const front = (file) => { try { return fs.readFileSync(file, 'utf8').split(/^---$/m)[1] || '' } catch (e) { return null } }
const field = (fm, k) => { const m = fm.match(new RegExp('^' + k + ': *(.*)$', 'm')); return m ? m[1].trim() : '' }
const scalar = (v) => (v.length > 1 && v[0] === "'" && v[v.length - 1] === "'" ? v.slice(1, -1).replace(/''/g, "'") : v)
let names = []
try { names = fs.readdirSync(evals).filter((n) => /^probe-/.test(n) && fs.statSync(path.join(evals, n)).isDirectory()).sort() } catch (e) { bad.push('evals: cannot list ' + evals) }
for (const required of ['probe-provision', 'probe-pr-state', 'probe-pr-write']) {
  if (!names.includes(required)) bad.push(required + ': case directory missing')
}
for (const c of names) {
  const pl = front(path.join(evals, c, 'graders', 'probe-line.md'))
  const vo = front(path.join(evals, c, 'graders', 'verify-ok.md'))
  if (pl === null) { bad.push(c + ': graders/probe-line.md missing'); continue }
  if (vo === null) { bad.push(c + ': graders/verify-ok.md missing'); continue }
  let lit = null
  const pat = scalar(field(pl, 'pattern'))
  if (field(pl, 'type') !== 'regex' || field(pl, 'target') !== 'last_message' || field(pl, 'flags') !== '') bad.push(c + ': probe-line.md must be type regex, target last_message, no flags')
  else if (pat.slice(0, 4) !== '^\\s*' || pat.slice(-4) !== '\\s*$') bad.push(c + ': probe-line.md pattern is not anchored ^\\s*...\\s*$')
  else {
    const body = pat.slice(4, -4)
    if (!/^(?:[^\\.*+?^${}()|[\]]|\\[.*+?^${}()|[\]\\])*$/.test(body)) bad.push(c + ': probe-line.md pattern holds an unescaped regex metacharacter (not a pinned literal)')
    else lit = body.replace(/\\(.)/g, '$1')
  }
  const m = lit && lit.match(/^PROBE name=([A-Za-z0-9_-]+) exit=(\d+) sha=([0-9a-f]{64}) cmd=([0-9a-f]{64}) json=\{.*\}$/)
  if (lit && !m) bad.push(c + ': probe-line.md literal is not a whole PROBE line (name, exit, 64-hex sha, 64-hex cmd, json)')
  if (m) {
    const want = '"type":"tool_result","content":"(?:[^"\\\\]|\\\\.)*VERIFY ok line=PROBE name=' + m[1] + ' exit=' + m[2] + ' sha=' + m[3]
    if (field(vo, 'type') !== 'regex' || field(vo, 'target') !== 'trace' || field(vo, 'flags') !== '') bad.push(c + ': verify-ok.md must be type regex, target trace, no flags')
    else if (scalar(field(vo, 'pattern')) !== want) bad.push(c + ': verify-ok.md pattern is not the tool_result VERIFY ok line of the probe-line sha')
  }
}
if (bad.length) { for (const b of bad) console.log(b); process.exit(1) }
console.log('grader pins ok (' + names.length + ' cases)')
JS
}

canary_js() { cat <<'JS'
const fs = require('fs')
const path = require('path')
const [root, rel, need, inflight] = process.argv.slice(1)
const NEED = Number(need)
const INFLIGHT = inflight.split(' ')
const FINAL = ['ready', 'merged']
let j
try { j = JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8')) } catch (e) {
  if (e && e.code === 'ENOENT') { console.log('0/' + NEED + ' qualifying canary runs: ' + rel + ' not found (format: header of scripts/gate-check.sh)'); process.exit(3) }
  console.log(rel + ' unreadable: not valid JSON'); process.exit(1)
}
if (!j || !Array.isArray(j.runs)) { console.log(rel + ' malformed: no runs[] array'); process.exit(1) }
const bad = []
const posInt = (v) => Number.isInteger(v) && v > 0
j.runs.forEach((r, i) => {
  const at = rel + ' runs[' + i + ']'
  if (!r || typeof r !== 'object') { bad.push(at + ': not an object'); return }
  if (!posInt(r.issue) || !posInt(r.pr)) bad.push(at + ': issue and pr must be positive integers')
  if (typeof r.status !== 'string') bad.push(at + ': status must be a string')
  if (!Array.isArray(r.pipelineStates) || !r.pipelineStates.every((s) => s && typeof s.file === 'string' && typeof s.status === 'string')) bad.push(at + ': pipelineStates must be an array of {file, status}')
})
if (bad.length) { console.log(bad.join(' | ')); process.exit(1) }
const seen = new Set()
const notes = []
let ok = 0
for (const r of j.runs) {
  const open = r.pipelineStates.filter((s) => INFLIGHT.includes(s.status))
  if (!FINAL.includes(r.status)) notes.push('pr ' + r.pr + ': status ' + r.status + ' is not ' + FINAL.join('/'))
  else if (open.length) notes.push('pr ' + r.pr + ': non-terminal .pipeline state ' + open.map((s) => s.file + '=' + s.status).join(','))
  else if (seen.has(r.pr)) notes.push('pr ' + r.pr + ': listed twice')
  else { seen.add(r.pr); ok++ }
}
console.log(ok + '/' + NEED + ' qualifying canary runs in ' + rel + (notes.length ? ' (' + notes.join('; ') + ')' : '') + (ok < NEED ? '; format: header of scripts/gate-check.sh' : ''))
process.exit(ok >= NEED ? 0 : 3)
JS
}

metric_incidents() {
  local n missing="" listed="" out rc last passed="" problems=""
  for n in $E2_INCIDENTS; do
    listed="$listed #$n"
    set -- "$ROOT"/fixtures/incidents/"$n"-*.json
    [ -f "$1" ] || missing="$missing #$n"
  done
  out="$(OFFLINE_STRICT=1 node "$SCRIPT_DIR/run-offline.cjs" --all "$ROOT/fixtures" --fp "$SELF_ROOT/workflows/deliver-pipeline.js" 2>&1)"
  rc=$?
  last="$(printf '%s\n' "$out" | tail -n 1)"
  case "$last" in
    "[offline] status=ok passed="*) passed="${last#*passed=}"; passed="${passed%% *}" ;;
  esac
  if [ "$rc" -ne 0 ] || [ -z "$passed" ] || [ "$passed" -eq 0 ]; then
    problems="replay not green (exit $rc): ${last:-no result line}"
  fi
  [ -n "$missing" ] && problems="${problems:+$problems; }no fixtures/incidents/<n>-*.json for$missing"
  if [ -z "$problems" ]; then
    emit PASS incidents "replay ${last#\[offline\] }; fixtures present for$listed"
  else
    emit FAIL incidents "$problems"
  fi
}

metric_eval() {
  local pins prc results out rc
  pins="$(node -e "$(pins_js)" "$ROOT/evals" 2>&1)"
  prc=$?
  if [ "$prc" -ne 0 ]; then
    emit FAIL eval "$(oneline "$pins")"
    return
  fi
  results="${PROBE_EVALS_RESULTS_DIR:-$ROOT/evals/results}"
  if [ ! -d "$results" ]; then
    if [ "$CI_MODE" -eq 1 ]; then
      emit SKIP eval "$pins; no results dir (git-ignored, written by scripts/run-probe-evals.sh), not required with --ci"
    else
      emit FAIL eval "$pins; no results dir: run scripts/run-probe-evals-docker.sh first"
    fi
    return
  fi
  out="$(bash "$SCRIPT_DIR/probe-eval-gate.sh" "$results" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then emit PASS eval "$pins; $(oneline "$out")"; else emit FAIL eval "$pins; $(oneline "$out")"; fi
}

metric_canary() {
  local out rc
  out="$(node -e "$(canary_js)" "$ROOT" "$CANARY_RECORD" "$CANARY_NEED" "$INFLIGHT" 2>&1)"
  rc=$?
  case "$rc" in
    0) emit PASS canary "$(oneline "$out")" ;;
    3) if [ "$CI_MODE" -eq 1 ]; then emit SKIP canary "$(oneline "$out"); not required with --ci"; else emit FAIL canary "$(oneline "$out")"; fi ;;
    *) emit FAIL canary "$(oneline "$out")" ;;
  esac
}

metric_incidents
metric_eval
metric_canary

verdict=PASS
[ "$n_skip" -gt 0 ] && verdict=INCOMPLETE
[ "$n_fail" -gt 0 ] && verdict=FAIL
echo "gate e2: $n_pass PASS, $n_fail FAIL, $n_skip SKIP -> $verdict"
[ "$n_fail" -eq 0 ]
exit $?
