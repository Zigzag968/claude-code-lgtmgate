#!/usr/bin/env bash
# The probe eval gate (#81): at least 95 % of the runs FULLY passed, where a run is fully passed only
# when its score is 1 (all 4 graders). 3 cases x 10 runs = 30 runs, so at least 29 of 30.
# This is a run count, NOT the case mean: with 4 graders per case, two runs at 0.75 give a mean of
# 0.95 and would pass a mean threshold while two runs in ten carried a corrupted PROBE line.
#
# Reads <results-dir>/<case>/aggregate-result.json, as written by `claude plugin eval --output-dir`
# (2.1.286): cases[] with .name, and cases[].arms.with[] = one entry per run, each with .score
# (0..1, mean of the weighted graders) and .error (null on a clean run).
# Offline, no `claude` call. node is the JSON reader: the eval image is node:20-based and the probe
# commands need it anyway. bash 3.2 safe.
#
# Usage: probe-eval-gate.sh <results-dir> [case...]   (default: probe-provision probe-pr-state probe-pr-write)
# Output: one line per case, then `gate: <K>/<N> fully passed runs (need >= <M>/<N>) -> PASS|FAIL`.
# Exit: 0 PASS, 1 FAIL (too few fully passed runs, or a case under 10 runs), 2 FAIL (a results file
# is missing, unreadable or malformed, or the usage is wrong). The exit code is node's: no pipe.
set -u

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "usage: probe-eval-gate.sh <results-dir> [case...]" >&2
  exit 2
fi
command -v node >/dev/null 2>&1 || { echo "probe-eval-gate: node not found on PATH" >&2; exit 2; }
if [ "$#" -lt 2 ]; then set -- "$1" probe-provision probe-pr-state probe-pr-write; fi

exec node - "$@" <<'JS'
const fs = require('fs')
const path = require('path')
const [dir, ...cases] = process.argv.slice(2)
const MIN_RUNS = 10          // runs per case the gate requires
const PCT = 95               // share of fully passed runs required

let fully = 0, total = 0, shortCase = false, broken = false
for (const name of cases) {
  const file = path.join(dir, name, 'aggregate-result.json')
  let runs = null, why = ''
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'))
    const c = (j.cases || []).find((x) => x && x.name === name)
    if (!c) why = 'no case "' + name + '" in the file'
    else if (!c.arms || !Array.isArray(c.arms.with)) why = 'no arms.with[] run list'
    else if (j.partial === true) why = 'partial run (aborted before the end)'
    else runs = c.arms.with
  } catch (e) {
    why = e && e.code === 'ENOENT' ? 'file missing' : 'file unreadable'
  }
  if (!runs) {
    console.log(name + ': results unusable (' + why + '): ' + file)
    broken = true
    continue
  }
  // fully passed = score 1 (every grader) on a run that did not error
  const k = runs.filter((r) => r && typeof r.score === 'number' && r.score >= 1 && r.error == null).length
  fully += k
  total += runs.length
  const few = runs.length < MIN_RUNS
  if (few) shortCase = true
  console.log(name + ': ' + k + '/' + runs.length + ' runs fully passed' + (few ? ' (fewer than ' + MIN_RUNS + ' runs)' : ''))
}

// denominator: the runs the suite owes (MIN_RUNS per case), or more if a case ran more
const denom = Math.max(total, MIN_RUNS * cases.length)
const need = Math.ceil((PCT * denom) / 100)
const pass = !broken && !shortCase && fully >= need
console.log('gate: ' + fully + '/' + denom + ' fully passed runs (need >= ' + need + '/' + denom + ') -> ' + (pass ? 'PASS' : 'FAIL'))
process.exit(pass ? 0 : broken ? 2 : 1)
JS
