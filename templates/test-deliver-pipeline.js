export const meta = {
  name: 'test-deliver-pipeline',
  description: 'Flow test suite for deliver-pipeline.js — deterministic cases via simulate mode (live count in the suite\'s own "Results: N/N passed" trailer). Runnable via node scripts/run-flow-suite.cjs (agents, CI) or the Workflow tool (Lead).',
  whenToUse: 'Verify deliver-pipeline flow logic (gate, trace, status) without spawning real agents.',
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const results = []

async function testCase(name, fn) {
  try {
    const { ok, msg } = await fn()
    results.push({ name, ok, msg: ok ? 'PASS' : (msg || 'assertion failed') })
    log(`${ok ? 'PASS' : 'FAIL'} — ${name}${ok ? '' : `: ${msg || 'assertion failed'}`}`)
  } catch (e) {
    results.push({ name, ok: false, msg: `threw: ${e.message}` })
    log(`FAIL — ${name}: threw: ${e.message}`)
  }
}

function eq(label, actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    return { ok: false, msg: `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}` }
  }
  return null
}

function includes(label, actual, value) {
  if (!actual.includes(value)) {
    return { ok: false, msg: `${label}: expected to include ${JSON.stringify(value)}, got ${JSON.stringify(actual)}` }
  }
  return null
}

// Returns the sorted test IDs (T<n>[a-z]* / F<n>[a-z]*) that occur more than once in `names`.
// Names without a leading ID are ignored; T104 and T104a are distinct IDs.
function duplicateTestIds(names) {
  const seen = new Set()
  const dups = new Set()
  for (const n of names) {
    const m = /^(?:T\d+[a-z]*|F\d+[a-z]*)(?=\s)/.exec(String(n))
    if (!m) continue
    if (seen.has(m[0])) dups.add(m[0])
    else seen.add(m[0])
  }
  return [...dups].sort()
}

// Stack-agnostic fake config — structurally complete so generic interpolation works.
// In simulate mode, callAgent is mocked and updateStatus is best-effort, so none of these
// commands/IDs are ever executed. Values are deliberately bogus.
const CONFIG = {
  ghProject: {
    owner: 'test-owner',
    projectNumber: 1,
    projectId: 'PVT_test',
    fieldId: 'PVTSSF_test',
    statusOptions: {
      'Backlog': 'opt-backlog',
      'Plan': 'opt-plan',
      'Dev': 'opt-dev',
      'Review': 'opt-review',
      'PR Ready': 'opt-pr-ready',
      'Blocked': 'opt-blocked',
      'Merged': 'opt-merged',
    },
  },
  baseBranch: 'develop',
  branchPrefix: 'features/',
  worktreeRoot: '/tmp/lgtmgate-worktrees',
  conventionsRule: '.claude/rules/conventions.md',
  commands: {
    build: 'echo build',
    test: 'echo test',
    format: 'echo format',
  },
  ciChecks: ['build-and-test', 'lint'],
  regressionGuard: {
    testGlob: 'Tests/',
    testFnPattern: 'func test',
  },
}

// Base args shared across all cases
const BASE = { issue: 1, brief: 'test feature', wtPath: '/tmp/lgtmgate-test', config: CONFIG }

// Run a pipeline case and return its result.
// `workflow('<name>')` resolves through the workflow REGISTRY — the copy in the checkout the
// session started in, never the branch worktree's. Correct post-merge; PRE-MERGE it silently
// exercises the OLD pipeline, so a gate under test reads as broken when it is merely absent
// from the resolved file (#526: T45/T47 "failed" against a pre-gate pipeline that was never
// the file under review). Validating a branch therefore passes an explicit path:
//   Workflow({ scriptPath: '<worktree>/.claude/workflows/test-deliver-pipeline.js',
//              args: { fpScriptPath: '<worktree>/.claude/workflows/deliver-pipeline.js' } })
// Absent that arg the name resolution stands, which is what a post-merge run wants.
//
// #54 resolution rule, this repo's own copy: the canonical pipeline is now
// `workflows/deliver-pipeline.js` (the plugin's default-scanned workflow-component
// directory — the component resolves as `lgtmgate:deliver-pipeline`), while this suite
// stays at `templates/test-deliver-pipeline.js` (its own migration is S3c's). Validating a
// branch of THIS repo therefore passes scriptPath '<worktree>/templates/test-deliver-pipeline.js'
// and args.fpScriptPath '<worktree>/workflows/deliver-pipeline.js' — `--fp` is ALWAYS passed
// explicitly by `scripts/run-flow-suite.cjs` (which defaults it to `workflows/deliver-pipeline.js`,
// unconditionally setting `suiteArgs.fpScriptPath`), so the `FP_REF` bare-name fallback below is
// UNREACHABLE in this repo. The bare name IS what resolves a CONSUMER project's own copy
// pre-S4 (`commands/init.md:21` still copies this suite into every consumer's
// `.claude/workflows/test-deliver-pipeline.js`, where the artifact under test is that
// consumer's own `.claude/workflows/deliver-pipeline.js`) — correct for consumers today, and
// deliberately NOT flipped here: flipping it would silently validate the plugin's pipeline
// instead of the consumer's branch, the same wrong-artifact class inverted. The default flips
// in S4, atomically with the consumer copies it describes.
// The probes below catch a resolution to an OLDER pre-gate copy; they CANNOT catch a
// resolution to a NEWER downstream copy (this suite run unpinned against a newer reference
// copy once read as 44/45, a harness artifact, not a port defect). Always pin
// fpScriptPath pre-merge.
const SUITE_ARGS = (typeof args === 'undefined' ? null
  : (typeof args === 'string' ? JSON.parse(args) : args)) || {}
const FP_REF = SUITE_ARGS.fpScriptPath ? { scriptPath: SUITE_ARGS.fpScriptPath } : 'deliver-pipeline'
// #86 — the engine reads only `simulate.probes` and carries no `??` default on a seam. Cases keep
// writing the flat legacy keys (`simulate: { sam: ... }`); run() translates them into
// `simulate.probes` and applies every static default here, with the same nullish semantics the
// engine `??` had (an explicit null/undefined still falls back). dryRun calls pass through.
const SIM_DEFAULTS = {
  samAcceptanceChecklist: '- [ ] (simulated acceptance item)',
  alreadyDoneCheck: { isAlreadyDone: false, isIssueClosed: false, isMerged: false },
  theo: { confirmed: true, evidence: '(simulated)', actualCause: '' },
  provision: { ok: true, exitCode: 0, linked: [], missing: [] },
  provisionBehindCount: 0,
  planStaleFiles: [],
  openSubIssues: [],
  gitDirWritable: { writable: true, gitDir: null },
  windowStart: '1970-01-01T00:00:00Z',
  artifactFloor: null,
  behindCount: 0,
  mergeState: null,
}
function toProbes(sim) {
  if (!sim) return sim
  const probes = { ...sim }
  for (const k of Object.keys(SIM_DEFAULTS)) probes[k] = sim[k] ?? SIM_DEFAULTS[k]
  return { probes }
}
async function run(overrides) {
  const a = { ...BASE, ...overrides }
  return await workflow(FP_REF, 'simulate' in a ? { ...a, simulate: toProbes(a.simulate) } : a)
}

// Guard: confirm we resolved the NEW, simulate-aware deliver-pipeline — not an older copy.
// Runs in dryRun (zero spawns). If the wrong version is resolved, abort LOUDLY before any
// simulate case runs, so a name mis-resolution can never spawn real Sam/Nick/Morgan agents.
const _probe = await run({ dryRun: true, mode: 'manual' })
if (_probe.status !== 'dry-run-ok' || _probe.mode !== 'manual' || _probe.entryStage === undefined) {
  throw new Error(
    'Wrong deliver-pipeline resolved (dry-run is missing mode/entryStage). Pre-merge, pass ' +
    "args.fpScriptPath = '<worktree>/workflows/deliver-pipeline.js'.")
}

// Capability probe (#526) — the dry-run shape above is satisfied by EVERY pipeline version, so
// it cannot tell a stale resolution from a fresh one: a pre-gate copy slipped through it and
// surfaced as two "failing" cases instead of a wrong-file abort. This probe exercises the
// artifact-proof gate itself (simulate mode, zero spawns). A pipeline that lets an LGTM whose
// declared artifact does NOT exist settle anywhere but the revision pause is either the wrong
// copy or a regressed gate — both must abort the suite, never read as a mere case failure.
const _gateProbe = await run({
  mode: 'semi',
  proceedThrough: 'dev',
  simulate: {
    sam: 'GO',
    morgan: [{
      verdict: 'LGTM',
      artifactProofs: [{ item: 'probe', path: 'probe.md', exists: false, mtime: '2026-01-02T00:00:00Z', bytes: 1 }],
    }],
    artifactFloor: '2026-01-01T00:00:00Z',
  },
})
if (_gateProbe.status !== 'needs-revision') {
  throw new Error(
    `Resolved deliver-pipeline has NO artifact-proof gate (#526): an LGTM declaring a MISSING ` +
    `artifact returned status '${_gateProbe.status}' instead of 'needs-revision'. Either the ` +
    `wrong copy was resolved — pass args.fpScriptPath = ` +
    `'<worktree>/workflows/deliver-pipeline.js' to test a branch — or the gate regressed.`)
}

// ---------------------------------------------------------------------------
// Test cases (see the "Results: N/N passed" trailer above for the live count)
// ---------------------------------------------------------------------------

// --- local-mechanism notes:start ---
// Beyond the mechanisms common to any deployment of this pipeline, this suite covers several
// mechanisms specific to this repo's own dogfooding of the plugin on itself (branch-conformance
// guards, provisioning edge cases, agentType registry-gap replays, etc.) — each LOCAL case below
// is noted with the mechanism it exercises and the issue that introduced it, so a reader can tell
// generic pipeline behavior apart from this repo's own operational hardening.
// LOCAL: T58 nick.branch = dispatch branch → escalate/branch-mismatch, no Review — repo-local mechanism (branch-conformance guard, lgtmgate#29).
// LOCAL: T59/T60/T61 branch-check agent prose normalization (extract a validated bare ref out of free text; ambiguous prose falls back to nick.branch) — repo-local mechanism (lgtmgate#71).
// LOCAL: T61a/T61b/T61c cross-repo re-routed branchPrefix reconciliation (worktree pipeline.config.json re-check before escalating) — repo-local mechanism (lgtmgate#131).
// LOCAL: T44a provision.extraLinks traversal segment rejected before any agent call — repo-local mechanism (claude-agent-pipeline#51 hardening).
// LOCAL: F2 provision missing-script gate: no links → skip and continue; hard link → escalate — repo-local mechanism (claude-agent-pipeline#60 R7).
// LOCAL: F3 provision no-script branch on optional-only links pins the documented KNOWN EDGE (raw length vs optional-filtered argv) — repo-local mechanism (claude-agent-pipeline#64).
// LOCAL: T54a/T54b/T54c/T54d agentType registry-gap harness signature replays (#54) — repo-local mechanism.
// LOCAL: nick delivers with prNumber:0 + testsPass:true/false (no-PR terminal delivery) — repo-local mechanism.
// LOCAL: T70a/T70b/T70c/T70d preflight.envSymlink gating (required/forbidden/ignore/invalid) — repo-local mechanism (#70).
// LOCAL: T77b/T77f/T77m this repo's own oneWayDoorPaths / oneWayDoorKinds, read from SUITE_ARGS.repoConfig (passed only by this repo's scripts/run-flow-suite.cjs; absent = SKIP) — repo-local config (#77).
// LOCAL: T163c this repo's own engineRepo flag, read from SUITE_ARGS.repoConfig (absent = SKIP) — repo-local config (#163).
// --- local-mechanism notes:end ---

// 1. auto, sam:GO, morgan:[LGTM] → ready, full trace, no pause
await testCase('auto / GO / LGTM → ready with full trace', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  const err = e1 || e2
  return err ? err : { ok: true }
})

// 1b. config.repo set → flow still completes end-to-end. config.repo threads `-R <repo>`
//     into the gh prompts (mocked in simulate); this proves the interpolation never throws
//     and the cross-repo path leaves the flow result unchanged. (#363)
await testCase('config.repo set → ready (cross-repo threading does not break the flow)', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, repo: 'owner/code-repo' },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 2. auto, sam:GO, morgan:[REQUIRED_CHANGES, LGTM] → ready, rounds:1
await testCase('auto / GO / REQUIRED_CHANGES then LGTM → ready rounds:1', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 1)
  const err = e1 || e2
  return err ? err : { ok: true }
})

// 3. auto, sam:NO-GO → no-go, trace ends ['Plan','Blocked']
await testCase('auto / NO-GO → no-go, trace ends [Plan,Blocked]', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'NO-GO' } })
  const e1 = eq('status', r.status, 'no-go')
  const traceEnd = r.trace.slice(-2)
  const e2 = eq('trace.slice(-2)', traceEnd, ['Plan', 'Blocked'])
  const err = e1 || e2
  return err ? err : { ok: true }
})

// 4. semi, proceedThrough:null, sam:GO → plan-ready
await testCase('semi / proceedThrough:null → plan-ready', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: null,
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e = eq('status', r.status, 'plan-ready')
  return e ? e : { ok: true }
})

// 5. semi, proceedThrough:'plan', sam:GO → plan-ready (authorization stops at plan) (#308)
await testCase('semi / proceedThrough:plan → plan-ready (authorization stops at plan)', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'plan',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e = eq('status', r.status, 'plan-ready')
  return e ? e : { ok: true }
})

// 6. semi, proceedThrough:'dev', sam:GO, morgan:[REQUIRED_CHANGES, LGTM] → needs-revision, round:0
await testCase('semi / proceedThrough:dev / REQUIRED_CHANGES → needs-revision round:0', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'dev',
    simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['x'] }, { verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'needs-revision')
  const e2 = eq('round', r.round, 0)
  const err = e1 || e2
  return err ? err : { ok: true }
})

// 7. semi, proceedThrough:'review', sam:GO, morgan:[REQUIRED_CHANGES, LGTM] → ready, rounds:1
await testCase('semi / proceedThrough:review / REQUIRED_CHANGES loop → ready rounds:1', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'review',
    simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['x'] }, { verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 1)
  const err = e1 || e2
  return err ? err : { ok: true }
})

// 8. manual, proceedThrough:null, sam:GO → plan-ready
await testCase('manual / proceedThrough:null → plan-ready', async () => {
  const r = await run({
    mode: 'manual',
    proceedThrough: null,
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e = eq('status', r.status, 'plan-ready')
  return e ? e : { ok: true }
})

// 9. manual, proceedThrough:'plan' → plan-ready
await testCase('manual / proceedThrough:plan → plan-ready', async () => {
  const r = await run({
    mode: 'manual',
    proceedThrough: 'plan',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e = eq('status', r.status, 'plan-ready')
  return e ? e : { ok: true }
})

// 10. manual, proceedThrough:'dev' → dev-done
await testCase('manual / proceedThrough:dev → dev-done', async () => {
  const r = await run({
    mode: 'manual',
    proceedThrough: 'dev',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e = eq('status', r.status, 'dev-done')
  return e ? e : { ok: true }
})

// T187 (#187) — an explicit proceedThrough is honoured in every mode. gate() used to return "no pause" for
// mode:'auto' before it read proceedThrough, so a design-step relaunch (proceedThrough:'plan', the contract of
// the design-step-required runbook row) ran past the plan checkpoint into Dev with no sign-off.
await testCase('T187a auto / proceedThrough:plan → plan-ready, no Dev/Review chained', async () => {
  const r = await run({
    mode: 'auto',
    proceedThrough: 'plan',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'plan-ready')
  const e2 = r.trace.includes('Dev') ? { ok: false, msg: `trace must not include Dev, got ${JSON.stringify(r.trace)}` } : null
  const e3 = r.trace.includes('Review') ? { ok: false, msg: `trace must not include Review, got ${JSON.stringify(r.trace)}` } : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

await testCase('T187b auto / design-step trigger + proceedThrough:plan → plan-ready, never Dev', async () => {
  const r = await run({
    mode: 'auto',
    proceedThrough: 'plan',
    simulate: {
      theo: {
        confirmed: true, evidence: 'e', actualCause: '',
        persistentStateSignal: true, authSecurityBoundarySignal: true, deployConfigSignal: false,
        immatureVendorApiSignal: false, designStepSignalEvidence: 'e',
      },
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'plan-ready')
  const e2 = r.trace.includes('Dev') ? { ok: false, msg: `trace must not include Dev, got ${JSON.stringify(r.trace)}` } : null
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T187c auto / no proceedThrough → ready, runs through with no new pause', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T187d semi / proceedThrough:plan → plan-ready (unchanged by #187)', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'plan',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'plan-ready')
  const e2 = eq('trace', r.trace, ['Plan'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T187e auto / proceedThrough:dev / REQUIRED_CHANGES → needs-revision round:0 (same as semi)', async () => {
  const r = await run({
    mode: 'auto',
    proceedThrough: 'dev',
    simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['x'] }, { verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'needs-revision')
  const e2 = eq('round', r.round, 0)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T187f auto / proceedThrough:review / REQUIRED_CHANGES loop → ready rounds:1', async () => {
  const r = await run({
    mode: 'auto',
    proceedThrough: 'review',
    simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['x'] }, { verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 1)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 11. entryStage:'review', no prNumber → throws with correct message
await testCase('entryStage:review without prNumber → throws', async () => {
  try {
    await run({ entryStage: 'review', simulate: { morgan: [{ verdict: 'LGTM' }] } })
    return { ok: false, msg: 'expected throw, but did not throw' }
  } catch (e) {
    if (e.message.includes('entryStage=review requires prNumber')) {
      return { ok: true }
    }
    return { ok: false, msg: `wrong error message: ${e.message}` }
  }
})

// 12. entryStage:'review', prNumber:42, morgan:[LGTM] → ready, pr:42, trace:['Review','PR Ready']
await testCase('entryStage:review / prNumber:42 → skips Plan+Dev, ready pr:42', async () => {
  const r = await run({
    entryStage: 'review',
    prNumber: 42,
    simulate: { morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('pr', r.pr, 42)
  const e3 = eq('trace', r.trace, ['Review', 'PR Ready'])
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// 13. dryRun:true, mode:'manual' → dry-run-ok, mode:'manual', entryStage:'plan'
await testCase('dryRun:true → dry-run-ok passthrough', async () => {
  const r = await run({ dryRun: true, mode: 'manual' })
  const e1 = eq('status', r.status, 'dry-run-ok')
  const e2 = eq('mode', r.mode, 'manual')
  const e3 = eq('entryStage', r.entryStage, 'plan')
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// 14. auto, sam:GO, morgan[0]:null (session-limit death) → review-died, PR preserved
await testCase('null Morgan round 0 (2026-07-21 crash) → review-died PR preserved', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [null] },
  })
  const e1 = eq('status', r.status, 'review-died')
  const e2 = eq('pr', r.pr, 999)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 15. auto, sam:GO, round 0 REQUIRED_CHANGES + round 1 SAME items → escalate
await testCase('no-progress (round 1 items ⊇ round 0) → escalate', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['a', 'b'] },
        { verdict: 'REQUIRED_CHANGES', items: ['a', 'b'] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'no-progress')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 16. entryStage:'dev', alreadyDoneCheck: substantiated issue-closed → already-done
await testCase('entryStage:dev / already-done guard → already-done', async () => {
  const r = await run({
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: { isAlreadyDone: true, isIssueClosed: true, issueState: 'CLOSED', isMerged: false },
    },
  })
  const e = eq('status', r.status, 'already-done')
  return e ? e : { ok: true }
})

// 16b. entryStage:'dev', alreadyDoneCheck: checkFailed + fabricated mergedAt → NOT already-done
// (a gh tool failure must never be trusted into an already-done abort)
await testCase('entryStage:dev / already-done guard checkFailed → flow continues, NOT already-done', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: {
        isAlreadyDone: true,
        isMerged: true,
        mergedAt: '2026-07-27T06:53:00Z',
        checkFailed: true,
        error: 'HTTP 401: Bad credentials',
      },
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e = eq('status', r.status, 'ready')
  return e ? e : { ok: true }
})

// 16c. entryStage:'dev', alreadyDoneCheck: bare {isAlreadyDone:true} → NOT already-done
// (unsubstantiated boolean alone must not abort the run)
await testCase('entryStage:dev / already-done guard bare boolean → flow continues, NOT already-done', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: { isAlreadyDone: true },
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e = eq('status', r.status, 'ready')
  return e ? e : { ok: true }
})

// 16d. entryStage:'dev', alreadyDoneCheck: substantiated merged row on the expected branch → already-done
// (true-positive path must still work — CONFIG.branchPrefix is 'features/', BASE.issue is 1)
await testCase('entryStage:dev / already-done guard substantiated merge → already-done', async () => {
  const r = await run({
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: {
        isAlreadyDone: true,
        isMerged: true,
        mergedAt: '2026-07-31T10:52:36Z',
        mergedPr: 446,
        mergedHeadRef: 'features/issue-1',
        issueCreatedAt: '2026-07-29T07:45:22Z',
      },
    },
  })
  const e = eq('status', r.status, 'already-done')
  return e ? e : { ok: true }
})

// 16e. entryStage:'dev', alreadyDoneCheck: merged row on the expected branch but the merged PR's
// OWN body does not close #issue (lgtmgate#197 — a multi-slice epic reuses the identical
// branch name across slices; slice 1's merged PR must not false-positive slice 2's guard) →
// flow continues, NOT already-done
await testCase('entryStage:dev / already-done guard merged-but-does-not-close-issue -> flow continues, NOT already-done', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: {
        isAlreadyDone: true,
        isIssueClosed: false,
        issueState: 'OPEN',
        isMerged: true,
        mergedAt: '2026-09-13T22:38:26Z',
        mergedPr: 167,
        mergedHeadRef: 'features/issue-1',
        mergedPrClosesIssue: false,
        issueCreatedAt: '2026-09-01T00:00:00Z',
      },
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e = eq('status', r.status, 'ready')
  return e ? e : { ok: true }
})

// T9031 (#31) — the already-done result carries the guard's own diagnostic, so a false positive is
// diagnosable from the returned JSON without reading the engine source. Merged path: every field is set.
await testCase('T9031 already-done result carries the guard diagnostic (merged path)', async () => {
  const r = await run({
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: {
        isAlreadyDone: true,
        isIssueClosed: false,
        issueState: 'OPEN',
        isMerged: true,
        mergedAt: '2026-07-31T10:52:36Z',
        mergedPr: 446,
        mergedHeadRef: 'features/issue-1',
        mergedPrClosesIssue: true,
        issueCreatedAt: '2026-07-29T07:45:22Z',
      },
    },
  })
  const e = eq('status', r.status, 'already-done')
    || eq('guard.reason', r.guard && r.guard.reason, 'merged')
    || eq('guard.mergedPr', r.guard && r.guard.mergedPr, 446)
    || eq('guard.mergedHeadRef', r.guard && r.guard.mergedHeadRef, 'features/issue-1')
    || eq('guard.mergedPrClosesIssue', r.guard && r.guard.mergedPrClosesIssue, true)
    || eq('guard.issueState', r.guard && r.guard.issueState, 'OPEN')
  return e ? e : { ok: true }
})

// T9031b (#31) — issue-closed path: the merged-PR fields are absent on the guard result and read null.
await testCase('T9031b already-done result carries the guard diagnostic (issue-closed path)', async () => {
  const r = await run({
    entryStage: 'dev',
    simulate: {
      alreadyDoneCheck: { isAlreadyDone: true, isIssueClosed: true, issueState: 'CLOSED', isMerged: false },
    },
  })
  const e = eq('status', r.status, 'already-done')
    || eq('guard.reason', r.guard && r.guard.reason, 'issue-closed')
    || eq('guard.issueState', r.guard && r.guard.issueState, 'CLOSED')
    || eq('guard.mergedPr', r.guard && r.guard.mergedPr, null)
    || eq('guard.mergedHeadRef', r.guard && r.guard.mergedHeadRef, null)
    || eq('guard.mergedPrClosesIssue', r.guard && r.guard.mergedPrClosesIssue, null)
  return e ? e : { ok: true }
})

// T183a (#183, resumeReason present) — a mergeable-conflicting-driven entryStage:'dev' resume
// carries the resume reason, the PR number and the escalate-issue number into nickPromptPreview,
// so Nick reasons from the PR's live state instead of concluding "already done".
await testCase('T183a resumeReason:mergeable-conflicting → RESUME REASON note in nickPromptPreview', async () => {
  const r = await run({
    entryStage: 'dev',
    prNumber: 4242,
    resumeReason: 'mergeable-conflicting',
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.nickPromptPreview
  const e1 = includes('nickPromptPreview', p, 'RESUME REASON (#183)')
  const e2 = includes('nickPromptPreview', p, 'mergeable-conflicting')
  const e3 = includes('nickPromptPreview', p, '4242')
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T183b (#183, negative control) — an ordinary entryStage:'dev' resume (resumeReason omitted)
// stays byte-identical: no RESUME REASON note leaks in.
await testCase('T183b resumeReason omitted → no RESUME REASON note in nickPromptPreview', async () => {
  const r = await run({
    entryStage: 'dev',
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = r.nickPromptPreview.includes('RESUME REASON')
    ? { ok: false, msg: `expected nickPromptPreview NOT to include "RESUME REASON", got ${JSON.stringify(r.nickPromptPreview)}` }
    : null
  return err ? err : { ok: true }
})

// T174a (#174) — Sam bundles an epic + 2 fully-resolved absorbed issues; Nick's composed
// Closes# line must list every one (root cause: GitHub only auto-closes an issue explicitly
// tagged with a closing keyword in the merging PR body).
await testCase('T174a bundled epic + 2 fully-resolved absorbed issues -> Closes # line lists all three', async () => {
  const r = await run({
    issue: 162,
    mode: 'auto',
    simulate: { sam: 'GO', samAbsorbedIssues: ['91', '123'], morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('nickPromptPreview', r.nickPromptPreview, 'Closes #162, Closes #91, Closes #123')
  return err ? err : { ok: true }
})

// T174b (#174, negative control) — an issue Sam's plan flags partial/residual is simply never
// added to absorbedIssues; the composed line must not reference it, while still closing the
// epic and the genuinely fully-resolved sibling.
await testCase('T174b partial/non-absorbed issue is excluded from the Closes # line', async () => {
  const r = await run({
    issue: 162,
    mode: 'auto',
    simulate: { sam: 'GO', samAbsorbedIssues: ['91'], morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.nickPromptPreview
  const e1 = includes('nickPromptPreview', p, 'Closes #162, Closes #91')
  const e2 = p.includes('Closes #119')
    ? { ok: false, msg: `expected nickPromptPreview NOT to include "Closes #119" (partial issue), got ${JSON.stringify(p)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T183c (#183, validation) — an unrecognized resumeReason value throws under dryRun, same idiom
// as T70d (zero agent spawns).
await testCase('T183c resumeReason invalid value → throws under dryRun (zero agent spawns)', async () => {
  try {
    await run({
      mode: 'manual',
      dryRun: true,
      resumeReason: 'bogus',
    })
    return { ok: false, msg: 'expected run() to throw, it did not' }
  } catch (e) {
    if (!e.message.includes('Invalid resumeReason')) {
      return { ok: false, msg: `wrong error message: ${e.message}` }
    }
    return { ok: true }
  }
})

// 17. auto, sam:GO, preflight[0] fails then preflight[1] passes → ready, no extra Morgan round
await testCase('preflight fails then passes → ready (no extra Morgan round consumed)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      preflight: [
        { pass: false, issues: ['Missing .env symlink'] },
        { pass: true, issues: [] },
      ],
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e = eq('status', r.status, 'ready')
  return e ? e : { ok: true }
})

// #182/#183 helpers, defined before the cases that use them (the #228 / human-gate cases below run in id mode).
// The engine's pure `acceptanceItems` block is extracted from its source and run through `new Function` (as T163 does
// for engineRules), so the property and table cases exercise the real functions, never a copy. t182Block() returns null
// only when the suite was not given the pipeline source (the case then logs SKIP); a source without the markers THROWS,
// so the case FAILs instead of passing vacuously.
const t182Block = () => {
  const src = SUITE_ARGS.fpSource
  if (!src) return null
  const block = extractBetween(src, '// --- acceptanceItems:start ---', '// --- acceptanceItems:end ---')
  if (!block) throw new Error('acceptanceItems:start/:end markers not found in the pipeline source')
  // eslint-disable-next-line no-new-func
  return new Function(block + '\nreturn { numberItems, renderLine, renderChecklist, parseChecklist, itemsFromPlan, validateAcceptanceItems, planLacksItems, mapBoxes, nickBlockNote, morganBoxesNote, boxLineId, lineKey, humanGateLine, onlyHumanGateLines, parkUntickable, morganItemsRule, reviewProgress, ciScope, ciAbsent, ciBlocker, verdictProblem }')()
}
const T182_ITEMS = [
  { text: '`node scripts/guards.cjs; echo $?` prints `0` as its last line', humanGate: false },
  { text: 'the maintainer confirms the plan wording reads well', humanGate: true },
  { text: '`node scripts/run-flow-suite.cjs | tail -n 1` ends with `failed=0`', humanGate: false },
]
// What numberItems must make of T182_ITEMS: { id, text, humanGate } in this key order (the suite compares JSON).
const T182_CANON = T182_ITEMS.map((it, i) => ({ id: i + 1, text: it.text, humanGate: it.humanGate }))
// The lines `items` must render to, written BY HAND: an oracle independent of renderChecklist.
const t182Lines = (items, ids = true) =>
  items.map((it, i) => `- [ ] ${ids ? `<!-- ac:${i + 1} --> ` : ''}${it.humanGate ? '[human-gate] ' : ''}${it.text}`)
// A Sam return carrying the items as data AND their lines in the plan text, as the contract asks.
const t182Sam = (items, ids = true) => ({
  plan: '## Plan\n1. change it\n\n## Acceptance checklist\n' + t182Lines(items, ids).join('\n') + '\n',
  acceptanceItems: items,
})
// A permissive plan-check model: when a plan is refused, only the script can have refused it.
const T182_CONFORMING = { 1: { verdict: 'CONFORMING' }, 2: { verdict: 'CONFORMING' } }
const t182Refusals = (r) => (r.trace || []).filter((t) => String(t).startsWith('acceptance-items-refused:'))
// The body of a PR whose human gate a person already ticked (T182_ITEMS): the gate is settled by the body alone (#183).
const t182GateTickedBody = () => {
  const lines = t182Lines(T182_ITEMS)
  return 'Closes #182\n\n<!-- acceptance:start -->\n' + [lines[0], '- [x] ' + lines[1].slice(6), lines[2]].join('\n') + '\n<!-- acceptance:end -->\n'
}
const t182Skip = (id) => { log(`SKIP — ${id}: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)`); return { ok: true } }

// 18. T18 — human-gate short-circuit at round 0 (#183: an id run, the gate is the item's id, never its text)
// Morgan returns only the HUMAN TEST GATE box → pipeline terminates ready-pending-human
// at round 0 (not a REQUIRED_CHANGES loop). Directly replays the real incident.
await testCase('T18 human-gate short-circuit round 0 → ready-pending-human', async () => {
  const gate = { text: 'HUMAN TEST GATE: human runs `python -m app.render --render-id abc123-... --publish`, verifies the output renders correctly, posts approval on the PR', humanGate: true }
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam([gate]) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: t182Lines([gate]) }],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('round', r.round, 0)
  const e3 = eq('humanGateItems.length', r.humanGateItems?.length, 1)
  const e4 = eq('resumable', r.resumable, true)
  return e1 || e2 || e3 || e4 || { ok: true }
})

// 19. T19 — mixed round loops on real blocker, then terminates
// round0: [human-gate box + real blocker] → loops; round1: [human-gate only] → ready-pending-human
await testCase('T19 mixed round loops on real blocker then human-gate terminates', async () => {
  const items = [{ text: 'human live-render check, post approval on PR', humanGate: true }, { text: '`grep -c FOO file` prints `1`', humanGate: false }]
  const lines = t182Lines(items)
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(items) },
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [lines[0], lines[1]] },
        { verdict: 'REQUIRED_CHANGES', items: [lines[0]] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('round', r.round, 1)
  const e3 = eq('humanGateItems.length', r.humanGateItems?.length, 1)
  return e1 || e2 || e3 || { ok: true }
})

// 20. T20 — normalization catches cosmetic rewording (Part 2)
// Two cosmetically-reworded copies of one id-less blocker trigger the no-progress escalate (#183: the key of a line
// without an `<!-- ac:N -->` id is its lowercased, whitespace-collapsed text without trailing punctuation).
// Would fail under an exact-string key, passes under the normalized one.
await testCase('T20 normalization catches cosmetic rewording → no-progress escalate', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['Fix URL validation regex'] },
        { verdict: 'REQUIRED_CHANGES', items: ['fix  url validation regex.'] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'no-progress')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 21. T21 — genuinely different blockers still loop (no false early-stop from normalization)
// round0 'fix A', round1 'fix B' are distinct → loop continues → LGTM at round2
await testCase('T21 genuinely different blockers loop without false early-stop', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['fix A'] },
        { verdict: 'REQUIRED_CHANGES', items: ['fix B'] },
        { verdict: 'LGTM' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 2)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 22. T22 — human ticks the box → clean LGTM on re-launch (resume path)
// entryStage:'review' with Morgan returning LGTM → status:'ready'. Regression guard
// for the resumable contract: after human ticks, the re-launch must terminate cleanly.
await testCase('T22 human ticks box, re-launch via entryStage:review → ready (resumable contract)', async () => {
  const r = await run({
    entryStage: 'review',
    prNumber: 267,
    simulate: {
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('pr', r.pr, 267)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 23. T23 — Nick pushes nothing on a correction round → nick-no-op escalate (no re-review)
//     Opt-in simulate : headSha[1] posé sans headSha[2] => SHA inchangé après le round Nick.

await testCase('T23 Nick no-op on correction round (SHA unchanged) → escalate nick-no-op', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['fix the null guard'] }, { verdict: 'LGTM' }],
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'nick-no-op')
  const e3 = eq('round', r.round, 1)
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T23b (issue #97) — the no-op gate widens from SHA-only to SHA-OR-body: Nick's fix landed as a
// PR-body-only edit (no new commit — SHA unchanged), so the OLD gate would have falsely
// escalated nick-no-op. headSha[1] posé sans headSha[2] => SHA inchangé (comme T23). prBodySig[1]
// != prBodySig[2] => body CHANGED between the two probes of the same round => continues to
// re-review instead of escalating.
await testCase('T23b Nick body-only fix (SHA unchanged, body changed) → continues to re-review, not no-op', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['fix the acceptance box wording'] }, { verdict: 'LGTM' }],
      headSha: { 1: 'sha-abc123' },
      prBodySig: { 1: 'body-v1', 2: 'body-v2' },
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'nick-body-only-fix:1')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// ── #228, #183 — verified-untickable terminal status ───────────────────────────────────────
// Morgan PROVED every box but the workflow's tick (the pr-write probe, `--mode tick`) is refused. The run parks for the
// Lead (`verified-untickable`) instead of dispatching a Nick round that ends `escalate nick-no-op`. The refusal is read
// from the probe result (here simulate.probes.acceptanceSync === false), never from Morgan's prose. Fail-safe: human
// gates, empty proofs and ciGreen:false never park. Id runs: Sam returns the items, Morgan returns `boxes`.
const UNT_ITEMS = [
  { text: '`node scripts/run-flow-suite.cjs` ends `failed=0`', humanGate: false },
  { text: '`diff templates/pr-acceptance.md .claude/rules/pr-acceptance.md` prints nothing', humanGate: false },
]
const UNT_LINES = t182Lines(UNT_ITEMS)
const UNT_PROOF = '$ cmd\n(verbatim output)'
const untBoxes = (...proven) => proven.map((p, i) => ({ id: i + 1, proven: p, proof: p ? UNT_PROOF : '' }))
const nickTrace = (r) => ((r.trace || []).some(t => /^nick/i.test(String(t))) ? { ok: false, msg: `Nick dispatched: trace=${JSON.stringify(r.trace)}` } : null)

await testCase('T228a all boxes proven, the tick refused (auto) → verified-untickable, no Nick round, no reason', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(UNT_ITEMS) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [UNT_LINES[0], UNT_LINES[1]], boxes: untBoxes(true, true) }],
      acceptanceSync: false,
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('round', r.round, 0)
  const e3 = eq('untickableItems.length', r.untickableItems?.length, 2)
  const e4 = eq('resumable', r.resumable, true)
  const e5 = eq('reason', r.reason, undefined)
  const e6 = eq('item verbatim', r.untickableItems?.[0]?.item, UNT_LINES[0])
  const e7 = eq('proof carried', r.untickableItems?.[0]?.proof, UNT_PROOF)
  const e8 = eq('id carried', r.untickableItems?.map(i => i.id), [1, 2])
  const e9 = includes('trace', r.trace, 'verified-untickable:0')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || nickTrace(r) || e9 || { ok: true }
})

await testCase('T228b semi mode, entryStage:review → verified-untickable (returns before gate(review))', async () => {
  const r = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 231,
    planText: t182Sam(UNT_ITEMS).plan,
    simulate: {
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [UNT_LINES[0], UNT_LINES[1]], boxes: untBoxes(true, true) }],
      acceptanceSync: false,
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('untickableItems.length', r.untickableItems?.length, 2)
  return e1 || e2 || { ok: true }
})

await testCase('T228d a refused tick + a human-gate box → ready-pending-human carrying both lists', async () => {
  const items = [UNT_ITEMS[0], { text: 'human confirms the D5 status name', humanGate: true }]
  const lines = t182Lines(items)
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(items) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [lines[1]], boxes: untBoxes(true, false) }],
      acceptanceSync: false,
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('humanGateItems', r.humanGateItems, [lines[1]])
  const e3 = eq('untickableItems.length', r.untickableItems?.length, 1)
  const e4 = eq('untickable item', r.untickableItems?.[0]?.item, lines[0])
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T228e a checklist-wording owner with a whitespace proof → fail-safe legacy path → escalate nick-no-op', async () => {
  const line = '- [ ] `grep -c FOO file` prints exactly 1'
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [line], itemOwners: [{ item: line, itemOwner: 'checklist-wording-defect', proof: '   ' }] }, { verdict: 'LGTM' }],
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'nick-no-op')
  const e3 = eq('untickableItems', r.untickableItems, undefined)
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T228f ciGreen:false with every box proven and the tick refused → not parked (legacy path)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam([UNT_ITEMS[0]]) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', ciGreen: false, items: [UNT_LINES[0]], boxes: untBoxes(true) }, { verdict: 'LGTM', boxes: untBoxes(true) }],
      acceptanceSync: false,
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = r.status === 'verified-untickable' ? { ok: false, msg: 'parked despite ciGreen:false' } : null
  const e2 = eq('status', r.status, 'escalate')
  const e3 = eq('reason', r.reason, 'nick-no-op')
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T228g round 0 a refused tick + a real code blocker loops, round 1 only the refused tick → verified-untickable at round 1', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(UNT_ITEMS) },
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [UNT_LINES[1]], boxes: untBoxes(true, false) },
        { verdict: 'REQUIRED_CHANGES', items: [UNT_LINES[0]], boxes: untBoxes(true, true) },
      ],
      acceptanceSync: false,
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('round', r.round, 1)
  const e3 = eq('untickableItems.length', r.untickableItems?.length, 2)
  return e1 || e2 || e3 || { ok: true }
})

// 24. T24 — plan-verification gate: round-1 NOT_CONFORMING loops back to Sam, round-2
//     CONFORMING proceeds through Dev/Review to ready. simulate.planCheck indexed by
//     planAttempt (1-based).
await testCase('T24 planCheck NOT_CONFORMING then CONFORMING → loops back, proceeds to ready', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      planCheck: {
        1: { verdict: 'NOT_CONFORMING', issues: ['no output contract'] },
        2: { verdict: 'CONFORMING' },
      },
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e = eq('status', r.status, 'ready')
  return e ? e : { ok: true }
})

// 25. T25 — plan-verification gate: NOT_CONFORMING at both attempts (bounded by the default
//     maxPlanAttempts:2) escalates instead of looping forever.
await testCase('T25 planCheck NOT_CONFORMING x2 (maxPlanAttempts) → escalate plan-not-conforming', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      planCheck: {
        1: { verdict: 'NOT_CONFORMING', issues: ['x'] },
        2: { verdict: 'NOT_CONFORMING', issues: ['x'] },
      },
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-not-conforming')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 26. T26 (#308) — resumed run: semi + proceedThrough:'plan' MUST stop at plan-ready,
//     never chaining Dev/Review (the #295 incident that opened PR #302).
await testCase('T26 semi / proceedThrough:plan → plan-ready, no Dev/Review chained', async () => {
  const r = await run({
    mode: 'semi',
    entryStage: 'plan',
    proceedThrough: 'plan',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'plan-ready')
  const e2 = r.trace.includes('Dev') ? { ok: false, msg: `trace must not include Dev, got ${JSON.stringify(r.trace)}` } : null
  const e3 = r.trace.includes('Review') ? { ok: false, msg: `trace must not include Review, got ${JSON.stringify(r.trace)}` } : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// 27. Diagnose stage — mandatory, refuted: Theo refutes → diagnosis-refuted, no Sam/Nick/Morgan spent
await testCase('Diagnose (mandatory) / Theo refutes → diagnosis-refuted, trace [Blocked]', async () => {
  const r = await run({
    simulate: {
      theo: { confirmed: false, evidence: 'ran the repro script, symptom did not occur', actualCause: 'stale cache, not the claimed logic bug' },
      // sam/morgan deliberately absent — if the pipeline reached Plan/Review despite the
      // refutation, callAgent('sam'/'morgan', ...) under simulate falls back to its default
      // GO/LGTM fixture, which would mask a bug here (still returning a plausible-looking
      // 'ready'). Asserting status + trace below is the actual regression guard.
    },
  })
  const e1 = eq('status', r.status, 'diagnosis-refuted')
  const e2 = eq('trace', r.trace, ['Blocked'])
  const e3 = includes('evidence', r.evidence, 'did not occur')
  const e4 = includes('actualCause', r.actualCause, 'stale cache')
  return (e1 || e2 || e3 || e4) ? (e1 || e2 || e3 || e4) : { ok: true }
})

// 28. Diagnose stage — mandatory, confirmed: Theo confirms → falls through to normal ready flow
await testCase('Diagnose (mandatory) / Theo confirms → falls through to Plan, ready', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      theo: { confirmed: true, evidence: 'ran the repro script, symptom reproduced as described', actualCause: '' },
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 29. Diagnose stage — no arg/tag needed at all: default `simFixture('theo')` (confirmed:true)
//     transparently passes through to the normal ready flow. Regression guard that the
//     mandatory gate never requires special-casing by the caller (nightly or otherwise).
await testCase('Diagnose (mandatory) / no theo fixture supplied → default-confirms, unchanged ready flow', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 30. T30 (#333, reopened) — Morgan's window catches an issue created during her round-0
//     window → orchestrator FLAGS it (comment only, trace records reviewer-window-issue-
//     flagged:<n>), terminal status unaffected. No close path exists any more (the fix for
//     #333 the first time round was itself the defect: an unattributed number-diff closed
//     31 issues across 3 repos, including a human-reopened one — see the plan for #333
//     reopened).
await testCase('T30 issue created in round-0 window → flagged, trace records it, status unchanged', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      issueWindow: { 0: { windowEnd: '9999-12-31T23:59:59Z', issues: [{ number: 501, createdAt: '2026-01-01T00:00:01Z', url: 'https://example.test/501' }] } },
      windowStart: '2026-01-01T00:00:00Z',
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'reviewer-window-issue-flagged:501')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 31. T31 (#333) negative control — same run WITHOUT an issueWindow/morganIssues fixture must
//     produce ZERO reviewer-window-issue-flagged:* trace entries (guards T1/T28/T29's exact-trace
//     assertions against a false positive, and guards against a regression that always flags).
await testCase('T31 no issueWindow fixture → trace has zero reviewer-window-issue-flagged entries', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const flagged = r.trace.filter(t => String(t).startsWith('reviewer-window-issue-flagged'))
  if (flagged.length !== 0) {
    return { ok: false, msg: `expected zero reviewer-window-issue-flagged entries, got ${JSON.stringify(flagged)}` }
  }
  return { ok: true }
})

// T32 (#333, reopened) — real-case replay: an issue created INSIDE
// the reviewer window is flagged, and the trace carries NO token matching /close/i anywhere —
// the exact production incident (unattributed number-diff auto-close) must now produce a
// non-destructive flag, never a close.
await testCase('T32 real-case replay (issue created inside reviewer window) → flagged, never closed', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      windowStart: '2026-09-01T17:20:09Z',
      issueWindow: { 0: { windowEnd: '2026-09-01T18:00:29Z', issues: [{ number: 257, createdAt: '2026-09-01T17:38:44Z', url: 'https://github.com/example-org/example-repo/issues/257' }] } },
    },
  })
  const e1 = includes('trace', r.trace, 'reviewer-window-issue-flagged:257')
  const closeTokens = r.trace.filter(t => /close/i.test(String(t)))
  const e2 = closeTokens.length !== 0
    ? { ok: false, msg: `expected zero close-shaped trace tokens, got ${JSON.stringify(closeTokens)}` }
    : null
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T33 (#333, reopened) — a reopen is not a creation: an issue whose createdAt PREDATES the
// review window (it was created long before, then reopened during the window — reopening never
// changes createdAt) must yield ZERO flags. The old number-diff mechanism could not see this and
// wrongly re-closed a human-reopened issue in production.
await testCase('T33 reopened issue (createdAt predates window) → zero flags', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      windowStart: '2026-09-01T17:20:09Z',
      issueWindow: { 0: { windowEnd: '2026-09-01T18:00:29Z', issues: [{ number: 333, createdAt: '2026-07-24T10:00:00Z', url: 'https://example.test/333' }] } },
    },
  })
  const flagged = r.trace.filter(t => String(t).startsWith('reviewer-window-issue-flagged'))
  if (flagged.length !== 0) {
    return { ok: false, msg: `expected zero flags for a reopened (pre-window createdAt) issue, got ${JSON.stringify(flagged)}` }
  }
  return { ok: true }
})

// T34 (#333, reopened) — an issue created AFTER the window closed (post-review, unrelated to
// this round) must yield ZERO flags — the window is bounded on both ends, not just from below.
// Not gated by its own acceptance-checklist box (§5 only cites T32/T33); kept as
// the plan's step-4 third case for completeness.
await testCase('T34 issue created after window end → zero flags', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      windowStart: '2026-09-01T17:20:09Z',
      issueWindow: { 0: { windowEnd: '2026-09-01T18:00:29Z', issues: [{ number: 999, createdAt: '2026-09-01T18:05:00Z', url: 'https://example.test/999' }] } },
    },
  })
  const flagged = r.trace.filter(t => String(t).startsWith('reviewer-window-issue-flagged'))
  if (flagged.length !== 0) {
    return { ok: false, msg: `expected zero flags for a post-window creation, got ${JSON.stringify(flagged)}` }
  }
  return { ok: true }
})

// 33. T119 (#14) — planCheck item 4: an orphan acceptance criterion (in the checklist, no
//     plan step) yields NOT_CONFORMING; bounded to escalate, and the orphan list surfaces in
//     planCheckIssues so the Lead sees exactly what is unaddressed.
await testCase('T119 planCheck orphan criterion → escalate, orphans in planCheckIssues', async () => {
  const orphan = 'orphan criterion: "/v/<id> renders" has no plan step'
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      planCheck: {
        1: { verdict: 'NOT_CONFORMING', issues: [orphan] },
        2: { verdict: 'NOT_CONFORMING', issues: [orphan] },
      },
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-not-conforming')
  const e3 = includes('planCheckIssues', r.planCheckIssues, orphan)
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// 34. T120 (#14) — Theo lane-check: a user-visible issue on the mechanical ('Sam') lane →
//     laneOk:false → status 'lane-refused', requiredScout surfaced, no Sam/Nick/Morgan spent.
await testCase('T120 Theo laneOk:false → lane-refused, requiredScout surfaced', async () => {
  const r = await run({
    simulate: {
      theo: { confirmed: true, laneOk: false, requiredScout: 'ScoutX', evidence: 'issue edits the /v/<id> route template — user-visible', actualCause: '' },
      // sam/morgan absent — a lane-refused run must NOT reach Plan/Review.
    },
  })
  const e1 = eq('status', r.status, 'lane-refused')
  const e2 = eq('requiredScout', r.requiredScout, 'ScoutX')
  const e3 = eq('trace', r.trace, ['Blocked'])
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// ---------------------------------------------------------------------------
// Real-incident replay — PR comment hygiene (minimizeSupersededReviewComments)
// ---------------------------------------------------------------------------

// T35 — a minimizedComments fixture (round 1, i.e. the scan right after
// Nick's round-1 push-note and BEFORE Morgan's round-1 verdict) → trace records the
// minimized comment id.
await testCase('T35 review-comment hygiene / minimizedComments fixture → trace records review-comment-minimized:<id>', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }],
      minimizedComments: { 1: ['IC_x'] },
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'review-comment-minimized:IC_x')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T36 negative control — same 2-round REQUIRED_CHANGES→LGTM flow WITHOUT a
// minimizedComments fixture must produce ZERO review-comment-minimized:* trace entries
// (guards against a regression that always "minimizes" regardless of fixture).
await testCase('T36 no minimizedComments fixture → trace has zero review-comment-minimized entries', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }],
    },
  })
  const minimized = r.trace.filter(t => String(t).startsWith('review-comment-minimized'))
  if (minimized.length !== 0) {
    return { ok: false, msg: `expected zero review-comment-minimized entries, got ${JSON.stringify(minimized)}` }
  }
  return { ok: true }
})

// ---------------------------------------------------------------------------
// Real-incident replay — deterministic provision_worktree.sh gate (D2)
// ---------------------------------------------------------------------------

// T37 — provisioning fails (simulate.provision.ok=false) → escalate,
// reason 'provision-failed', missing sources surfaced on the result.
await testCase('T37 provision fails → escalate / reason provision-failed', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      provision: { ok: false, missing: ['/x/.venv'], exitCode: 2 },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'provision-failed')
  const e3 = eq('missing', r.missing, ['/x/.venv'])
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T38 negative control — provisioning succeeds (default fixture,
// ok:true) → flow completes exactly as before, trace unchanged.
await testCase('T38 provision succeeds (default fixture) → ready, trace unchanged', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// ---------------------------------------------------------------------------
// #384 fixtures + helpers — decision-log body composer + pre-handoff squash gate
// ---------------------------------------------------------------------------

// Synthetic fixture modeling the shape of a real-world PR body at scale (this repo is open
// source; an earlier version of this fixture captured verbatim content from a private
// repository's PR and has been replaced with an equivalent synthetic body of the same
// structure — same section order, same all-checked acceptance block including one
// [human-gate] item, same zero decision-log markers). See buildPaddedBody20k below for the
// ~20 KB real-world size class this models (#87 truncation regression).
const PR385_BODY_REAL = "Closes #292\n\n## Summary\n- Adds `reviewMarker` (`<!-- pipeline-review-round pr=<N> -->`) that the review loop stamps as the first line of Morgan's verdict comments and Nick's push-notes.\n- Adds `minimizeSupersededReviewComments(round)`: best-effort, marker-scoped pass that minimizes (collapses, never deletes) prior-round marked comments before each Morgan spawn (initial + loop re-review), running AFTER Nick's push in the loop so his round-N note is minimized too.\n- Marker-only targeting — all pipeline agents share ONE GitHub token, so author filtering is useless/dangerous; unmarked (human) comments are never touched. Fails safe: scan/mutation errors are caught and logged, never thrown.\n- Scope: directions 1+2 from Sam's plan only. Directions 3 (decision-log body section), 4 (artifact-first body), and the commit-hygiene squash note are deferred to a follow-up.\n\n## Test plan\n- `node scripts/run-flow-suite.cjs` (Lead-run; agents have no Workflow tool) — asserts trace includes `review-comment-minimized:IC_x` on a 2-round REQUIRED_CHANGES→LGTM flow with a `minimizedComments` fixture; negative control is the same flow with no fixture → zero `review-comment-minimized:` trace entries.\n- `python3 -m unittest discover plugins/backlog/tests` — all green.\n- `bash templates/test-canonical-guards.sh` — all green.\n- No Python files touched by this PR (JS-only change to `workflows/`).\n\n## Feature flag\nNone — no-opt-out hygiene pass on the existing review-loop seam, matching the plan's scope table.\n\n## Risk\nLow. Best-effort/non-throwing by construction (mirrors `reconcileMorganIssues`). Worst case on a `gh`/GraphQL hiccup: a comment simply stays visible (fail-safe), never mis-minimized, since targeting requires the literal `<!-- pipeline-review-round` marker prefix that only this pipeline ever writes.\n\n<!-- acceptance:start -->\n- [x] `node scripts/run-flow-suite.cjs` — all cases pass, incl. the 2 new minimize cases (trace assertion + negative control).\n- [x] `grep -n \"pipeline-review-round\" workflows/deliver-pipeline.js` returns >= 4 hits (marker const, helper filter, both Morgan prompts, Nick prompt).\n- [x] `minimizeSupersededReviewComments` filters on marker + `isMinimized==false` ONLY (no author filter) and contains no `throw` — confirm by reading the helper.\n- [x] Call order: minimize runs before BOTH Morgan spawns and, in the loop, AFTER Nick's push — confirm by reading source order.\n- [x] Lint clean and the pre-existing flow cases still green (no exact-trace regression).\n- [x] [human-gate] Dogfood: if THIS PR's review takes >=2 rounds, `gh pr view <pr> --json comments` shows round-0 verdict + Nick push-note as `isMinimized:true` while only the latest verdict stays visible.\n<!-- acceptance:end -->\n\n## Note\nNo further caveats — clean baseline, nothing deferred beyond what's listed in Scope above.\n\n"

function countOccurrences(str, sub) {
  return String(str).split(sub).length - 1
}

function countUncheckedBoxes(str) {
  return (String(str).match(/^\s*-\s*\[ \]/gm) || []).length
}

// T39 (#384, real named case) — the decision-log composer fed the REAL body of PR #385 through
// a REQUIRED_CHANGES→LGTM flow. Guards: markers stay singular, both round entries land, and the
// pre-existing acceptance boxes are untouched (no unchecked-box count drift).
await testCase('T39 decision-log real-case (PR #385 body) composition', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }],
      prBody: PR385_BODY_REAL,
    },
  })
  const body = r.prBodyPreview || ''
  const errs = []
  if (countOccurrences(body, '<!-- acceptance:start -->') !== 1) errs.push('acceptance:start not exactly 1')
  if (countOccurrences(body, '<!-- acceptance:end -->') !== 1) errs.push('acceptance:end not exactly 1')
  if (countOccurrences(body, '<!-- decision-log:start -->') !== 1) errs.push('decision-log:start not exactly 1')
  if (!body.includes('- round 0 — REQUIRED_CHANGES (1 blocker)')) errs.push('missing round 0 entry')
  if (!body.includes('- round 1 — LGTM')) errs.push('missing round 1 entry')
  if (countUncheckedBoxes(body) !== countUncheckedBoxes(PR385_BODY_REAL)) errs.push('unchecked-box count drifted')
  return errs.length ? { ok: false, msg: errs.join('; ') } : { ok: true }
})

// T40 (#384, idempotence) — a 3-verdict flow must still leave exactly ONE decision-log block
// (re-running/re-composing never duplicates the markers).
await testCase('T40 decision-log idempotence (3-verdict flow, single block)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['fix A'] },
        { verdict: 'REQUIRED_CHANGES', items: ['fix B'] },
        { verdict: 'LGTM' },
      ],
      prBody: PR385_BODY_REAL,
    },
  })
  const body = r.prBodyPreview || ''
  const n = countOccurrences(body, '<!-- decision-log:start -->')
  return n === 1 ? { ok: true } : { ok: false, msg: `expected exactly 1 decision-log:start, got ${n}` }
})

// T41 (#384, no trace regression) — decisionLog is populated as a SEPARATE return field while
// `trace` stays byte-identical to the pre-#384 shape (guards the 36 pre-existing exact-trace cases).
await testCase('T41 decisionLog populated while trace is unchanged (no regression)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('decisionLog', r.decisionLog, ['- round 0 — LGTM'])
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// ---------------------------------------------------------------------------
// Real-incident replay — commit-hygiene squash (squashBeforeHandoff)
// ---------------------------------------------------------------------------

// T42 — squash gate fires at 9 commits (a real observed count) when
// commitHygiene opts in.
await testCase('T42 squashBeforeHandoff fires at 9 commits (real #446 count)', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, commitHygiene: { squashBeforeHandoff: true, maxCommits: 3 } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], squashCommits: 9 },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, `commit-squashed:${r.pr}`)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T43 (negative control, two sub-assertions) — (a) below maxCommits with
// commitHygiene ON, (b) 9 commits with NO commitHygiene config at all (this repo's own
// default before opting in): both must yield ZERO commit-squashed: trace entries.
await testCase('T43 squash negative control (below threshold / commitHygiene unset) → zero entries', async () => {
  const rBelow = await run({
    mode: 'auto',
    config: { ...CONFIG, commitHygiene: { squashBeforeHandoff: true, maxCommits: 3 } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], squashCommits: 2 },
  })
  const rDefault = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], squashCommits: 9 },
  })
  const squashedBelow = rBelow.trace.filter(t => String(t).startsWith('commit-squashed'))
  const squashedDefault = rDefault.trace.filter(t => String(t).startsWith('commit-squashed'))
  if (squashedBelow.length !== 0) return { ok: false, msg: `below-threshold: expected zero, got ${JSON.stringify(squashedBelow)}` }
  if (squashedDefault.length !== 0) return { ok: false, msg: `default-config (no commitHygiene): expected zero, got ${JSON.stringify(squashedDefault)}` }
  return { ok: true }
})

// Fixture for T44 (#384 review round 1 fix) — mirrors the EXACT shape Morgan reproduced the bug
// against: an indented/fenced illustrative copy of the decision-log markers inside "## What this
// ships", plus the real, unindented, workflow-owned marker pair at the end of the body.
const FENCED_EXAMPLE_BODY =
  'Closes #384\n\n## What this ships\n\n' +
  '1. **Decision log in the body** — after every Morgan verdict the workflow rewrites a\n' +
  '   marker-delimited block, so the round history survives #292\'s comment collapse:\n' +
  '   ```\n' +
  '   <!-- decision-log:start -->\n' +
  '   ## Decision log\n' +
  '   - round 0 — REQUIRED_CHANGES (2 blockers)\n' +
  '   - round 1 — LGTM\n' +
  '   <!-- decision-log:end -->\n' +
  '   ```\n\n' +
  '## Acceptance checklist\n\n' +
  '<!-- decision-log:start -->\n<!-- decision-log:end -->\n'

// T44 (#384, real defect fixed after Morgan's round-1 REQUIRED_CHANGES) — upsertDecisionLog's
// un-anchored indexOf() matched the INDENTED example inside "## What this ships" instead of the
// real column-0 trailing block, corrupting the example and leaving the real block empty forever.
// PR385_BODY_REAL (used by T39/T40) has ZERO decision-log markers of any kind, so it could never
// catch this — this fixture reproduces the exact indented-example shape that broke.
await testCase('T44 decision-log upsert ignores indented/fenced example, targets real column-0 block', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['x', 'y', 'z'] }],
      prBody: FENCED_EXAMPLE_BODY,
    },
  })
  const body = r.prBodyPreview || ''
  const errs = []
  // The fenced illustrative example must survive byte-for-byte — its made-up entries are untouched.
  if (!body.includes('   - round 0 — REQUIRED_CHANGES (2 blockers)')) errs.push('fenced example round-0 line was mutated/lost')
  if (!body.includes('   - round 1 — LGTM')) errs.push('fenced example round-1 line was mutated/lost')
  // The REAL trailing (column-0) block must carry the ACTUAL verdict just recorded, not the example's.
  const realBlock = body.match(/^<!-- decision-log:start -->\n([\s\S]*?)\n<!-- decision-log:end -->/m)
  if (!realBlock) errs.push('real column-0 decision-log block not found')
  else if (!realBlock[1].includes('- round 0 — REQUIRED_CHANGES (3 blockers)')) errs.push('real block missing the actual round-0 entry')
  // Exactly one REAL (unindented) start marker — the indented fenced copy must not count.
  const realStarts = (body.match(/^<!-- decision-log:start -->$/gm) || []).length
  if (realStarts !== 1) errs.push(`expected exactly 1 column-0 decision-log:start, got ${realStarts}`)
  return errs.length ? { ok: false, msg: errs.join('; ') } : { ok: true }
})

// ---------------------------------------------------------------------------
// #526 fixtures — artifact-proof gate (staleArtifactBlockers, callMorganGuarded)
// ---------------------------------------------------------------------------

// Real #518 incident shape: the acceptance box claimed a fresh parity re-run, but only the
// previous day's report was on disk. Reused across T45/T47 (mode:'semi' + proceedThrough:'dev'
// mirrors case 6's pattern — plan/dev pass through unpaused, review pauses at round 0 on the
// FIRST REQUIRED_CHANGES, which is exactly what the JS-side guard must produce by OVERTURNING
// Morgan's own LGTM — never by the simulate fixture claiming REQUIRED_CHANGES directly).
const ARTIFACT_PROOF_ITEM = '- [ ] LIVE PARITY RUN (executed by me, two real external sources, not mocks)'
const ARTIFACT_PROOF_PATH = '.pipeline/parity-run-2026-08-03T12:50:44.md'
const ARTIFACT_FLOOR = '2026-08-04T09:00:00Z'

// T45 (#526, the real case) — LGTM with a STALE declared proof must be overturned to
// REQUIRED_CHANGES by the workflow, not trusted from Morgan's own verdict.
await testCase('T45 artifact-proof gate overturns LGTM on a stale artifact (#518 replay)', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'dev',
    simulate: {
      sam: 'GO',
      morgan: [{
        verdict: 'LGTM',
        artifactProofs: [{
          item: ARTIFACT_PROOF_ITEM,
          path: ARTIFACT_PROOF_PATH,
          exists: true,
          mtime: '2026-08-03T12:50:44Z', // predates the floor — stale
          bytes: 4096,
        }],
      }],
      artifactFloor: ARTIFACT_FLOOR,
    },
  })
  const e1 = eq('status', r.status, 'needs-revision')
  const e2 = eq('round', r.round, 0)
  const e3 = includes('items', r.items, ARTIFACT_PROOF_ITEM)
  const e4 = includes('trace', r.trace, 'artifact-proof-rejected:artifact-stale')
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T46 (#526, negative control) — same proof, but stamped AFTER the floor: zero blockers,
// the LGTM stands, and the trace is byte-identical to a plain LGTM run (no guard entries).
await testCase('T46 artifact-proof gate negative control (fresh artifact → ready, exact trace)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{
        verdict: 'LGTM',
        artifactProofs: [{
          item: ARTIFACT_PROOF_ITEM,
          path: ARTIFACT_PROOF_PATH,
          exists: true,
          mtime: '2026-08-04T10:29:49Z', // after the floor — fresh
          bytes: 4096,
        }],
      }],
      artifactFloor: ARTIFACT_FLOOR,
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T47 (#526) — a declared artifact that does not EXIST on disk must overturn LGTM regardless
// of mtime/floor; the run stays paused, never reaching 'ready'.
await testCase('T47 artifact-proof gate overturns LGTM on a missing artifact', async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'dev',
    simulate: {
      sam: 'GO',
      morgan: [{
        verdict: 'LGTM',
        artifactProofs: [{
          item: ARTIFACT_PROOF_ITEM,
          path: ARTIFACT_PROOF_PATH,
          exists: false,
          mtime: '2026-08-04T10:29:49Z',
          bytes: 4096,
        }],
      }],
      artifactFloor: ARTIFACT_FLOOR,
    },
  })
  const errs = []
  if (r.status === 'ready') errs.push({ ok: false, msg: `status: expected never 'ready', got 'ready'` })
  const e2 = includes('trace', r.trace, 'artifact-proof-rejected:artifact-absent')
  if (e2) errs.push(e2)
  return errs.length ? errs[0] : { ok: true }
})

// T9007 (#7) — an item-less LGTM whose OWN artifact proof entry is unusable (empty artifact, malformed entry)
// is a defect no dev round can repair: the run escalates `artifact-proof-rejected` before any Nick dispatch.
// A stale proof (Nick can regenerate the artifact) keeps the REQUIRED_CHANGES overturn (control).
await testCase('T9007 an item-less LGTM whose own artifact proof is unusable escalates artifact-proof-rejected, no Nick round', async () => {
  const emptyProof = { item: ARTIFACT_PROOF_ITEM, path: ARTIFACT_PROOF_PATH, exists: true, mtime: '2026-08-04T10:29:49Z', bytes: 0 }
  const reasons = (r) => (Array.isArray(r.blockers) ? r.blockers.map((b) => b && b.reason) : r.blockers)
  // 1. initial review: a zero-byte artifact
  const a = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM', artifactProofs: [emptyProof] }], artifactFloor: ARTIFACT_FLOOR },
  })
  const a1 = eq('empty: status', a.status, 'escalate')
  const a2 = eq('empty: reason', a.reason, 'artifact-proof-rejected')
  const a3 = eq('empty: round', a.round, 0)
  const a4 = includes('empty: trace', a.trace || [], 'artifact-proof-rejected:artifact-empty')
  const a5 = eq('empty: blockers', reasons(a), ['artifact-empty'])
  // 2. initial review: a null (malformed) proof entry
  const b = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM', artifactProofs: [null] }], artifactFloor: ARTIFACT_FLOOR },
  })
  const b1 = eq('malformed: status', b.status, 'escalate')
  const b2 = eq('malformed: reason', b.reason, 'artifact-proof-rejected')
  const b3 = eq('malformed: round', b.round, 0)
  const b4 = includes('malformed: trace', b.trace || [], 'artifact-proof-rejected:malformed-proof')
  const b5 = eq('malformed: blockers', reasons(b), ['malformed-proof'])
  // 3. re-review loop: round 1 ran Nick for the first verdict, none after the rejected proof
  const c = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM', artifactProofs: [emptyProof] }],
      artifactFloor: ARTIFACT_FLOOR,
    },
  })
  const c1 = eq('loop: status', c.status, 'escalate')
  const c2 = eq('loop: reason', c.reason, 'artifact-proof-rejected')
  const c3 = eq('loop: round', c.round, 1)
  const c4 = includes('loop: trace', c.trace || [], 'artifact-proof-rejected:artifact-empty')
  // 4. control: a stale proof is still repairable by Nick -> needs-revision, not escalate
  const d = await run({
    mode: 'semi',
    proceedThrough: 'dev',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM', artifactProofs: [{ ...emptyProof, mtime: '2026-08-03T12:50:44Z', bytes: 4096 }] }],
      artifactFloor: ARTIFACT_FLOOR,
    },
  })
  const d1 = eq('control: status', d.status, 'needs-revision')
  const d2 = includes('control: trace', d.trace || [], 'artifact-proof-rejected:artifact-stale')
  return a1 || a2 || a3 || a4 || a5 || nickTrace(a) || b1 || b2 || b3 || b4 || b5 || nickTrace(b)
    || c1 || c2 || c3 || c4 || d1 || d2 || { ok: true }
})

// T48 (#526, back-compat) — an LGTM with NO artifactProofs declared (the pre-#526 shape every
// existing flow case uses) must be completely unaffected: zero extra agent calls, exact trace.
await testCase('T48 artifact-proof gate back-compat (no artifactProofs → unaffected)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T49 — behindCount set → freshness note injected, trace + return field carry it.
await testCase('T49 worktree behind → freshness note surfaced (trace + worktreeBehind)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], behindCount: 21 },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'worktree-behind:21')
  const e3 = eq('worktreeBehind', r.worktreeBehind, 21)
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T50 (negative control) — no behindCount declared → default 0, no note, unaffected trace.
await testCase('T50 worktree fresh (no behindCount) → no freshness note, worktreeBehind:0', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('worktreeBehind', r.worktreeBehind, 0)
  const e3 = r.trace.some(t => String(t).startsWith('worktree-behind:'))
    ? { ok: false, msg: `trace: expected no worktree-behind entry, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T51 (#645, back-compat) — flag absent → the OFF path is byte-identical to pre-#645: no
// plan-audit* trace entry, exact legacy trace, status 'ready'.
await testCase('T51 planAudit absent → OFF, exact legacy trace, no plan-audit entries', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  const e3 = r.trace.some(t => String(t).startsWith('plan-audit'))
    ? { ok: false, msg: `trace: expected no plan-audit entry, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T52 (#645) — planAudit:true + SOUND round 1 → ready, trace has plan-audit:SOUND, no amend.
await testCase('T52 planAudit:true SOUND round 1 → ready, plan-audit:SOUND, no amend', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      audit: { 1: { verdict: 'SOUND', findings: [] } },
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'plan-audit:SOUND')
  const e3 = r.trace.some(t => String(t).startsWith('plan-audit-amend:'))
    ? { ok: false, msg: `trace: expected no amend entry, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T53 (#645) — S4 XSS replay shape: round 1 BLOCKING (SOUND-WITH-NOTES) sends ONE amendment,
// round 2 SOUND proceeds. Modeled on a real incident.
await testCase('T53 S4-shaped replay: blocking round 1 → one amend → SOUND round 2 → ready', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      planCheck: [{ verdict: 'CONFORMING' }, { verdict: 'CONFORMING' }],
      audit: {
        1: {
          verdict: 'SOUND-WITH-NOTES',
          findings: [{ severity: 'blocking', area: 'security', title: 'XSS', finding: 'f', fix: 'x', sources: ['https://docs.djangoproject.com/en/5.1/ref/utils/#django.utils.html.format_html'] }],
        },
        2: { verdict: 'SOUND', findings: [] },
      },
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const trace = r.trace
  const i1 = trace.indexOf('plan-audit:SOUND-WITH-NOTES')
  const i2 = trace.indexOf('plan-audit-amend:1')
  const i3 = trace.lastIndexOf('plan-audit:SOUND')
  const e2 = (i1 === -1 || i2 === -1 || i3 === -1 || !(i1 < i2 && i2 < i3))
    ? { ok: false, msg: `trace order wrong: ${JSON.stringify(trace)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T54 (#645) — NOT_SOUND twice (maxAuditRounds default 2) → escalate / plan-not-sound.
await testCase('T54 NOT_SOUND x2 (maxAuditRounds) → escalate plan-not-sound', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      planCheck: [{ verdict: 'CONFORMING' }, { verdict: 'CONFORMING' }],
      audit: {
        1: { verdict: 'NOT_SOUND', findings: [{ severity: 'blocking', title: 'bad', finding: 'f', fix: 'x' }] },
        2: { verdict: 'NOT_SOUND', findings: [{ severity: 'blocking', title: 'still bad', finding: 'f2', fix: 'x2' }] },
      },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-not-sound')
  const e3 = (Array.isArray(r.auditFindings) && r.auditFindings.length > 0)
    ? null : { ok: false, msg: `expected non-empty auditFindings, got ${JSON.stringify(r.auditFindings)}` }
  const e4 = eq('trace end', r.trace[r.trace.length - 1], 'Blocked')
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T55 (#645) — a blocking round 1 forces one amendment; the terminal round 2 (maxAuditRounds
// default 2) carries only a NOTE → proceed, no ping-pong / no escalation.
await testCase('T55 terminal round notes-only → ready, no ping-pong', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      planCheck: [{ verdict: 'CONFORMING' }, { verdict: 'CONFORMING' }],
      audit: {
        1: { verdict: 'SOUND-WITH-NOTES', findings: [{ severity: 'blocking', title: 'real', finding: 'f', fix: 'x' }] },
        2: { verdict: 'SOUND-WITH-NOTES', findings: [{ severity: 'note', title: 'minor', finding: 'f2', fix: 'x2' }] },
      },
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = (r.trace.filter(t => t === 'plan-audit-amend:2').length === 0)
    ? null : { ok: false, msg: `expected no second amendment, got ${JSON.stringify(r.trace)}` }
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T56 (#645) — an unrecognized/absent verdict is malformed output and must never pass the gate.
await testCase('T56 malformed audit verdict → escalate plan-audit-malformed', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      audit: { 1: { findings: [] } },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-audit-malformed')
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T57 (#645) — config.planAudit:true + arg planAudit:false → OFF (explicit false beats config).
await testCase('T57 config.planAudit:true + arg planAudit:false → OFF', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: false,
    config: { ...CONFIG, planAudit: true },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.some(t => String(t).startsWith('plan-audit'))
    ? { ok: false, msg: `trace: expected no plan-audit entry, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T58 (#29) — branch-conformance guard: Nick reports a PR opened from the raw dispatch
// branch (a foreign-prefixed branch) instead of ${branchPrefix}issue-N => fail loud BEFORE Review.
// Repo-local mechanism, not shared with other deployments of this pipeline — numbered
// after the last ported/excluded reference case (T57) to avoid colliding with the T35
// slot reserved above for the excluded upstream review-comment-hygiene case.
// morgan absent on purpose: if the guard did not fire, the default LGTM fixture would
// mask the bug behind a plausible-looking 'ready'.
await testCase('T58 nick.branch = dispatch branch → escalate/branch-mismatch, no Review', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', nick: { prNumber: 777, branch: 'feat-issue-1' } },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'branch-mismatch')
  const e3 = eq('actualBranch', r.actualBranch, 'feat-issue-1')
  const e4 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const e5 = r.trace.includes('Review')
    ? { ok: false, msg: `trace must not include Review, got ${JSON.stringify(r.trace)}` }
    : null
  return (e1 || e2 || e3 || e4 || e5) ? (e1 || e2 || e3 || e4 || e5) : { ok: true }
})

// T59 (#71) — branch-check agent answers with prose naming the EXPECTED ref (the real incident
// shape: "PR #776 is on branch `features/issue-1`."). The guard must extract the bare ref out of
// the sentence and NOT escalate — this is the defect this issue fixes.
await testCase('T59 branch-check prose names the expected ref → no escalation', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      nick: { prNumber: 776, branch: 'features/issue-1' },
      branchCheckRaw: 'PR #776 is on branch `features/issue-1`.',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.includes('branch-check-normalized')
    ? null
    : { ok: false, msg: `trace must include branch-check-normalized, got ${JSON.stringify(r.trace)}` }
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T60 (#71) — branch-check agent answers with prose naming a DIFFERENT ref than expected. The
// guard must still escalate, and actualBranch must be the extracted BARE ref, never the sentence.
// morgan absent on purpose: if the guard did not fire, the default LGTM fixture would mask the bug.
await testCase('T60 branch-check prose names a different ref → escalate with bare actualBranch', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      nick: { prNumber: 776, branch: 'features/issue-1' },
      branchCheckRaw: 'PR #776 is on branch `feat-issue-1`.',
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'branch-mismatch')
  const e3 = eq('actualBranch', r.actualBranch, 'feat-issue-1')
  const e4 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const e5 = r.trace.includes('Review')
    ? { ok: false, msg: `trace must not include Review, got ${JSON.stringify(r.trace)}` }
    : null
  return (e1 || e2 || e3 || e4 || e5) ? (e1 || e2 || e3 || e4 || e5) : { ok: true }
})

// T61 (#71) — branch-check agent answers with an ambiguous sentence naming BOTH the wrong and the
// right ref. The guard must NOT guess (never read this as conforming) — it falls back to the
// schema-typed nick.branch, i.e. the guard's pre-agent-check behaviour.
await testCase('T61 branch-check answer ambiguous → falls back to nick.branch', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      nick: { prNumber: 776, branch: 'feat-issue-1' },
      branchCheckRaw: 'PR #776 head is `feat-issue-1`, expected `features/issue-1`.',
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('actualBranch', r.actualBranch, 'feat-issue-1')
  const e3 = r.trace.includes('branch-check-unparsed')
    ? null
    : { ok: false, msg: `trace must include branch-check-unparsed, got ${JSON.stringify(r.trace)}` }
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T61a (#131) — reproduces a real incident (re-routed to lgtmgate#126):
// real target-repo headRef ('feat/issue-1') differs from the expectedBranch built from the
// caller's stale config.branchPrefix ('features/issue-1', CONFIG.branchPrefix), BUT the
// worktree's own pipeline.config.json confirms 'feat/' as the real prefix → reconciled, no escalation.
await testCase('T61a config.branchPrefix stale on a cross-repo re-route (feat/ real, features/ configured) → reconciled, no escalation (#131)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      nick: { prNumber: 127, branch: 'feat/issue-1' },
      configBranchPrefixRaw: 'feat/',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.includes('branch-check-reconciled')
    ? null
    : { ok: false, msg: `trace must include branch-check-reconciled, got ${JSON.stringify(r.trace)}` }
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T61b (#131, negative control) — the pipeline.config.json re-check does NOT confirm a different
// prefix (same value as the caller's config) and headRef is still a genuinely foreign branch: the
// guard must still escalate — proves reconciliation cannot mask a real mismatch (lgtmgate#29's
// original case).
await testCase('T61b pipeline.config.json re-check does not match either → still escalates (#131 negative control)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { nick: { prNumber: 777, branch: 'feat-issue-1' }, configBranchPrefixRaw: 'features/' },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'branch-mismatch')
  const e3 = r.trace.includes('branch-check-reconciled')
    ? { ok: false, msg: `trace must NOT include branch-check-reconciled, got ${JSON.stringify(r.trace)}` }
    : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T61c (#131) — re-check fails (ERROR sentinel): treated as unavailable, guard falls back to its
// pre-#131 behaviour (escalate).
await testCase('T61c pipeline.config.json re-check returns ERROR sentinel → treated as unavailable, still escalates (#131)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { nick: { prNumber: 777, branch: 'feat-issue-1' }, configBranchPrefixRaw: 'ERROR' },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('actualBranch', r.actualBranch, 'feat-issue-1')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T105a (#139) — extends the reconcileStaleBranchPrefix principle above to baseBranch/
// conventionsRule: on an entryStage:'dev' RESUME, the worktree's own pipeline.config.json
// reports different values than the caller-supplied config → both fields reconciled.
await testCase('T105a entryStage:dev resume / config baseBranch+conventionsRule stale → both reconciled (#139)', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'dev',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      configProjectRecheckRaw: JSON.stringify({ baseBranch: 'main', conventionsRule: '.claude/rules/pr-acceptance.md' }),
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.includes('config-baseBranch-reconciled')
    ? null
    : { ok: false, msg: `trace must include config-baseBranch-reconciled, got ${JSON.stringify(r.trace)}` }
  const e3 = r.trace.includes('config-conventionsRule-reconciled')
    ? null
    : { ok: false, msg: `trace must include config-conventionsRule-reconciled, got ${JSON.stringify(r.trace)}` }
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T105b (#139, cost-avoidance gate) — same configProjectRecheckRaw fixture but on a FRESH
// dispatch (entryStage:'plan', the default): the recheck must never fire — no reconciled
// markers in trace (mirrors the inverse fresh-vs-resume gate at the base-staleness preflight, T99/T100).
await testCase('T105b fresh dispatch (entryStage:plan) / configProjectRecheckRaw set → gate never fires, not reconciled (#139)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      configProjectRecheckRaw: JSON.stringify({ baseBranch: 'main', conventionsRule: '.claude/rules/pr-acceptance.md' }),
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.includes('config-baseBranch-reconciled')
    ? { ok: false, msg: `trace must NOT include config-baseBranch-reconciled on a fresh dispatch, got ${JSON.stringify(r.trace)}` }
    : null
  const e3 = r.trace.includes('config-conventionsRule-reconciled')
    ? { ok: false, msg: `trace must NOT include config-conventionsRule-reconciled on a fresh dispatch, got ${JSON.stringify(r.trace)}` }
    : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T105c (#139) — entryStage:'dev' resume, re-check returns the ERROR sentinel: treated as
// unavailable, no throw, guard falls back to the caller-supplied baseBranch/conventionsRule
// (pre-#139 behaviour) — mirrors T61c's ERROR-sentinel negative control.
await testCase('T105c entryStage:dev resume / configProjectRecheckRaw ERROR sentinel → no throw, not reconciled (#139)', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'dev',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      configProjectRecheckRaw: 'ERROR',
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.includes('config-baseBranch-reconciled')
    ? { ok: false, msg: `trace must NOT include config-baseBranch-reconciled, got ${JSON.stringify(r.trace)}` }
    : null
  const e3 = r.trace.includes('config-conventionsRule-reconciled')
    ? { ok: false, msg: `trace must NOT include config-conventionsRule-reconciled, got ${JSON.stringify(r.trace)}` }
    : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// Repo-local mechanism, LOCAL —
// see the "local-mechanism notes" block above — numbered
// T44a rather than T44 because T44 is now a ported upstream decision-log case (see above),
// and numbered after the last ported reference case (T58) to avoid colliding with any
// reference slot.
// Offline-reachable: config is a workflow arg, so the traversal validator (§3.1-C
// safeLinkPath) throws BEFORE any agent() call — no simulate fixture needed for the
// throw path itself.
await testCase('T44a provision.extraLinks traversal segment rejected before any agent call', async () => {
  try {
    await run({ mode: 'auto', config: { ...CONFIG, provision: { extraLinks: [{ src: '../../x', dst: 'y' }] } } })
    return { ok: false, msg: 'expected run() to throw on a traversal extraLinks entry, it did not' }
  } catch (e) {
    if (!/Invalid provision\.extraLinks entry/.test(e.message)) {
      return { ok: false, msg: `expected "Invalid provision.extraLinks entry" in the thrown error, got: ${e.message}` }
    }
    return { ok: true }
  }
})

// F2 (claude-agent-pipeline#60 R7) — provision missing-script gate. A consumer worktree of
// config.repo (#363) can carry no scripts/provision_worktree.sh of its own: the JS branches
// STATICALLY on provisionLinks.length, never left to the agent to decide. No hard link
// configured -> loud skip, run continues; >=1 hard link configured -> loud hard fail, escalate.
// Simulate mode never executes the shell branch itself — it exercises the JS control flow
// around the { ok, skipped, exitCode } shape the agent would have reported for each branch.
await testCase('F2 provision missing-script gate: no links → skip and continue; hard link → escalate', async () => {
  const noLinksRun = await run({
    mode: 'auto',
    config: { ...CONFIG, provision: { extraLinks: [] } },
    simulate: {
      provision: { ok: true, exitCode: 0, skipped: true, linked: [], missing: [] },
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status (no links, script absent)', noLinksRun.status, 'ready')

  const hardLinkRun = await run({
    mode: 'auto',
    config: { ...CONFIG, provision: { extraLinks: [{ src: 'MAIN/.env', dst: '.env' }] } },
    simulate: {
      provision: { ok: false, exitCode: 2, skipped: false, linked: [], missing: [] },
    },
  })
  const e2 = eq('status (hard link, script absent)', hardLinkRun.status, 'escalate')
  const e3 = eq('reason (hard link, script absent)', hardLinkRun.reason, 'provision-failed')

  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// F3 pins the documented KNOWN EDGE (deliver-pipeline.js:1409-1414) at its current, intentional
// behavior: the no-script branch keys on the RAW extraLinks length while provisionArgs keys on
// the optional-filtered subset, so an optional-only config still hard-fails instead of skipping.
// Asserts on r.provisionCmdPreview (the statically composed command string), never on
// simulate.provision — that object bypasses parseProvisionOutput entirely (deliver-pipeline.js
// :1454-1458) and would prove nothing about the argv/condition mismatch this case exists to pin.
await testCase('F3 provision no-script branch on optional-only links: KNOWN EDGE pins current hard-fail (not loud-skip)', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, provision: { extraLinks: [{ src: 'MAIN/.env', dst: '.env', optional: true }] } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.provisionCmdPreview
  const e1 = includes('provisionCmdPreview', p,
    'PROVISION-NO-SCRIPT $SCRIPT (1 hard link(s) configured - cannot provision)')
  const e2 = includes('provisionCmdPreview', p,
    'bash "$SCRIPT" "/tmp/lgtmgate-test"; else')
  const err = e1 || e2
  return err ? err : { ok: true }
})

// Repo-local mechanism — see the
// "local-mechanism notes" block above, numbered T54a-T54d
// after the last local case (T44a) to avoid colliding with any reference slot. Replays
// P1's captured registry-gap harness signature (a thrown "agent type '<name>' not found"
// error) via simulate.agentTypeUnresolved and proves callAgentSafe's #54 fallback control
// flow: budget-gated (never buys a 3rd spawn), never fires on the last attempt, and never
// masks a generic death (case d) as a registry gap.
function theoTrace(trace) {
  return trace.filter(t => t === 'agent-type-unresolved:theo' || /^agent-died:theo:\d+$/.test(t))
}

await testCase('T54a agentType registry gap on attempt 1 -> persona-fallback succeeds, control status reached', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { agentTypeUnresolved: { theo: [1] }, sam: 'NO-GO' },
  })
  const e1 = eq('status', r.status, 'no-go')
  const e2 = eq('theo trace', theoTrace(r.trace), ['agent-died:theo:1', 'agent-type-unresolved:theo'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T54b agentType registry gap on attempt 1, persona-fallback attempt also dies -> diagnose-died', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { agentTypeUnresolved: { theo: [1] }, theo: 'DIE' },
  })
  const e1 = eq('status', r.status, 'diagnose-died')
  const e2 = eq('theo trace', theoTrace(r.trace), ['agent-died:theo:1', 'agent-type-unresolved:theo', 'agent-died:theo:2'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T54c build stamp travels on every terminal return, dryRun AND normal', async () => {
  const dry = await run({ dryRun: true, mode: 'manual' })
  const normal = await run({ mode: 'auto', simulate: { sam: 'NO-GO' } })
  const stampRe = /^\[pipeline\] lgtmgate@/
  const e1 = stampRe.test(dry.buildStamp)
    ? null : { ok: false, msg: `dryRun buildStamp does not match ${stampRe}: ${JSON.stringify(dry.buildStamp)}` }
  const e2 = stampRe.test(normal.buildStamp)
    ? null : { ok: false, msg: `normal-run buildStamp does not match ${stampRe}: ${JSON.stringify(normal.buildStamp)}` }
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T54d agentType registry gap on the LAST attempt -> budget wins, no fallback, no 3rd spawn', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { agentTypeUnresolved: { theo: [2] }, theo: 'DIE' },
  })
  const e1 = eq('status', r.status, 'diagnose-died')
  const e2 = eq('theo trace', theoTrace(r.trace), ['agent-died:theo:1', 'agent-died:theo:2'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T214 (#214) — native coverage for agentDeathRouting(), callAgentSafe( wiring and
// STRUCTURED_OUTPUT_MANDATE injection. Death routing + wiring run
// end-to-end via simulate.<role>:'DIE'; the pure function and the mandate are asserted from the
// pipeline source text (SUITE_ARGS.fpSource, passed by scripts/run-flow-suite.cjs).
await testCase('T214a sam dies twice (retry-safe) -> plan-died, resumable, agent-died sam:1 + sam:2', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'DIE' } })
  const samDied = (r.trace || []).filter(t => typeof t === 'string' && t.startsWith('agent-died:sam:'))
  const e1 = eq('status', r.status, 'plan-died')
  const e2 = eq('resumable', r.resumable, true)
  const e3 = eq('sam death trace', samDied, ['agent-died:sam:1', 'agent-died:sam:2'])
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

await testCase('T214b nick dies (side-effectful) -> dev-died, resumable, exactly one agent-died:nick:1', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', nick: 'DIE' } })
  const nickDied = (r.trace || []).filter(t => typeof t === 'string' && t.startsWith('agent-died:nick:'))
  const e1 = eq('status', r.status, 'dev-died')
  const e2 = eq('resumable', r.resumable, true)
  const e3 = eq('nick death trace', nickDied, ['agent-died:nick:1'])
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

await testCase('T214c agentDeathRouting() table extracted from source markers', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T214c: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const block = extractBetween(src, '// --- agentDeathRouting:start ---', '// --- agentDeathRouting:end ---')
  if (!block) return { ok: false, msg: 'agentDeathRouting:start/:end markers not found in pipeline source' }
  // eslint-disable-next-line no-new-func
  const route = new Function(block + '\nreturn agentDeathRouting')()
  const checks = [
    eq('sam attempt 1 retries', route('sam', 1), { action: 'retry' }),
    eq('probe attempt 1 retries (RETRY_SAFE, #82)', route('probe', 1), { action: 'retry' }),
    eq('probe attempt 2 fails (agent-died)', route('probe', 2), { action: 'fail', status: 'agent-died', resumable: true }),
    eq('sam attempt 2 fails', route('sam', 2), { action: 'fail', status: 'plan-died', resumable: true }),
    eq('nick never retried', route('nick', 1), { action: 'fail', status: 'dev-died', resumable: true }),
    eq('morgan never retried', route('morgan', 1), { action: 'fail', status: 'review-died', resumable: true }),
    eq('theo maxAttempts 1 fails', route('theo', 1, 1), { action: 'fail', status: 'diagnose-died', resumable: true }),
    eq('unknown role -> agent-died', route('nobody', 1), { action: 'fail', status: 'agent-died', resumable: true }),
    eq('non-integer attempt treated as 1', route('sam', 'x'), { action: 'retry' }),
    eq('maxAttempts 0 falls back to 2', route('sam', 1, 0), { action: 'retry' }),
    eq('maxAttempts 0 fallback still caps at 2', route('sam', 2, 0), { action: 'fail', status: 'plan-died', resumable: true }),
  ]
  return checks.find(c => c) || { ok: true }
})

// T272 (#82) — probeCommands() extracted from its source markers: both commands start with the
// cd prefix the attest hook accepts, the script is single-quoted, --verify adds --attest and no --cmd.
await testCase('T272 probeCommands() extracted from source markers (#82)', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T272: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const block = extractBetween(src, '// --- probeCommands:start ---', '// --- probeCommands:end ---')
  if (!block) return { ok: false, msg: 'probeCommands:start/:end markers not found in pipeline source' }
  // eslint-disable-next-line no-new-func
  const pc = new Function(block + '\nreturn probeCommands')()
  const base = { wtPath: '/wt/issue-7', issue: 7, name: 'provision', cmd: "echo 'hi'", label: 'provision', round: 0 }
  const withRoot = pc({ ...base, pluginRoot: '/plug' })
  const cfgWins = pc({ ...base, pluginRoot: '/plug', probeRunPath: '/cfg/probe-run.cjs' })
  const fallback = pc({ ...base })
  const att = "--attest '/wt/issue-7/.pipeline/probe-attest.jsonl'"
  const checks = [
    eq('run starts with cd prefix + quoted plugin script', withRoot.run.startsWith("cd '/wt/issue-7' && node '/plug/templates/probe-run.cjs' "), true),
    eq('verify starts with the same prefix', withRoot.verify.startsWith("cd '/wt/issue-7' && node '/plug/templates/probe-run.cjs' --verify "), true),
    eq('run carries --cmd with the quoted command', withRoot.run.includes("--cmd 'echo '\\''hi'\\'''"), true),
    eq('run has no --verify', withRoot.run.includes('--verify'), false),
    eq('verify has --attest <wt>/.pipeline/probe-attest.jsonl', withRoot.verify.includes(att), true),
    eq('verify has no --cmd', withRoot.verify.includes('--cmd'), false),
    eq('config.probeRunPath wins over pluginRoot', cfgWins.run.includes("node '/cfg/probe-run.cjs' "), true),
    eq('fallback is the worktree copy', fallback.run.includes("node '/wt/issue-7/templates/probe-run.cjs' "), true),
    eq('same out dir in both', withRoot.run.includes("--out '/wt/issue-7/.pipeline/probes/issue-7'") && withRoot.verify.includes("--out '/wt/issue-7/.pipeline/probes/issue-7'"), true),
    eq('default run has no --no-reuse (provision record rule unchanged)', withRoot.run.includes('--no-reuse'), false),
    eq('noReuse run carries --no-reuse before --cmd (#83)', /--no-reuse --cmd /.test(pc({ ...base, pluginRoot: '/plug', noReuse: true }).run), true),
    eq('noReuse never reaches the verify command', pc({ ...base, pluginRoot: '/plug', noReuse: true }).verify.includes('--no-reuse'), false),
    eq('preflightProbe passes noReuse: true to probe() (live state, #83)', /async function preflightProbe[\s\S]*?probe\('preflight', cmd, \{[\s\S]*?noReuse: true/.test(src), true),
    // #212: the digest the engine composed travels to the script, which refuses a copy that does not hash to it
    ...(() => {
      const digest = 'a'.repeat(63) + 'b'
      const gated = pc({ ...base, pluginRoot: '/plug', noReuse: true, expectCmd: digest })
      return [
        eq('expectCmd run carries --expect-cmd <digest> BEFORE --cmd (cmdOfPrompt still finds the command)', gated.run.includes(` --expect-cmd ${digest} --cmd `), true),
        eq('expectCmd never reaches the verify command', gated.verify.includes('--expect-cmd'), false),
        eq('the default run has no --expect-cmd', withRoot.run.includes('--expect-cmd'), false),
        eq('prWrite gates the command (gateCmd: true)', /async function prWrite[\s\S]*?probe\('pr-write', cmd, \{[\s\S]*?gateCmd: true/.test(src), true),
        eq('the tick sends the block as --text-b64 base64Utf8(rendered)', src.includes("'--text-b64', base64Utf8(rendered)"), true),
        eq('the tick no longer sends the block as --text', src.includes("'--mode', 'tick', '--text', rendered"), false),
        eq('the plugin-version probe does not gate its command (a stale root must still answer)', src.split('\n').filter((l) => l.includes("probe('lines', pluginVersionCmd(pluginRoot)")).every((l) => !l.includes('gateCmd')), true),
        eq('preflightProbe does not gate its command', src.slice(src.indexOf('async function preflightProbe'), src.indexOf('async function prWrite')).includes('gateCmd'), false),
      ]
    })(),
  ]
  return checks.find(c => c) || { ok: true }
})

// T273 (#82) — the probe role has the same persona-in-prompt fallback as Theo, and the two fail-closed
// prerequisites carry a distinct reason: static checks on the source (no simulate seam exists for probe()).
await testCase('T273 probe(): persona fallback wired, no-attestation and probe-run-not-found reasons (#82)', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T273: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const checks = [
    eq('probe call carries personaFallback: PROBE_PERSONA', /agentType: 'lgtmgate:probe'[^\n]*personaFallback: PROBE_PERSONA/.test(src), true),
    eq('PROBE_PERSONA is the probe-run copier persona', /const PROBE_PERSONA =[\s\S]*?probe-run\.cjs/.test(src), true),
    eq("no-attestation maps to its own probeReason", src.includes("verified.reason === 'no-attestation' ? 'no-attestation'"), true),
    eq('probe-run-not-found fails early', src.includes("if (!config.probeRunPath && !pluginRoot) return fail('probe-run-not-found')"), true),
    eq('escalation carries probeHint', src.includes('probeHint: PROBE_REASON_HINTS[provision.probeFailed]'), true),
  ]
  return checks.find(c => c) || { ok: true }
})

// T195 (#195) — a pluginRoot of another plugin version than the engine's build fails fast. The decision is
// pluginVersionVerdict(), a pure function extracted from its source markers (no simulate seam: the probe that
// reads the manifest has none, T273); the real command, the real probe-run.cjs and real manifests run in
// templates/test-probe-run.sh, the replayed incident in fixtures/incidents/195-stale-plugin-root.json.
const pluginVersionPieces = () => {
  const src = SUITE_ARGS.fpSource
  if (!src) return null
  const block = extractBetween(src, '// --- pluginVersion:start ---', '// --- pluginVersion:end ---')
  const m = /const BUILD = \{[^}]*\bversion: '([^']+)'/.exec(src)
  if (!block || !m) return { missing: true, src }
  // eslint-disable-next-line no-new-func
  const fns = new Function(block + '\nreturn { pluginVersionCmd, pluginVersionVerdict, pluginVersionOrder }')()
  return { ...fns, src, V: m[1] }
}
await testCase('T195a pluginRoot of the engine\'s own version passes unchanged (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195a: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (pv.missing) return { ok: false, msg: 'pluginVersion:start/:end markers or the BUILD version not found in pipeline source' }
  const { V, pluginVersionVerdict } = pv
  const same = pluginVersionVerdict({ engineVersion: V, pluginRoot: '/plug', exit: 0, lines: ['PLUGIN-VERSION:' + V] })
  const sim = await run({ mode: 'auto', pluginRoot: '/plug', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const checks = [
    eq('same version -> no verdict', same, null),
    eq('a simulate run with a pluginRoot reaches ready as before', sim.status, 'ready'),
    eq('and its trace is unchanged', sim.trace, ['Plan', 'Dev', 'Review', 'PR Ready']),
  ]
  return checks.find(c => c) || { ok: true }
})
await testCase('T195b a different plugin version escalates, the reason names both versions and the remedy (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195b: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (pv.missing) return { ok: false, msg: 'pluginVersion markers or the BUILD version not found in pipeline source' }
  const { V, pluginVersionVerdict } = pv
  const older = pluginVersionVerdict({ engineVersion: V, pluginRoot: '/old/root', exit: 0, lines: ['PLUGIN-VERSION:0.0.1-old'] })
  const newer = pluginVersionVerdict({ engineVersion: V, pluginRoot: '/new/root', exit: 0, lines: ['PLUGIN-VERSION:99.0.0'] })
  const checks = [
    eq('code', older && older.code, 'plugin-version-skew'),
    includes('names the root version', older.reason, '0.0.1-old'),
    includes('names the engine version', older.reason, V),
    eq('the reason carries no local path (a path in a GitHub paste is refused by the scrub hook)', older.reason.includes('/old/root'), false),
    includes('names the remedy', older.reason, 'pass the current plugin root and relaunch'),
    eq('a newer root is a skew too', newer && newer.code, 'plugin-version-skew'),
    includes('a newer root does not get the stale-root remedy', newer.reason, 'relaunch the workflow at the current version'),
    eq('a newer root is not told to pass the current root', newer.reason.includes('pass the current plugin root'), false),
    eq('the reason is never provision-failed', older.reason.startsWith('provision-failed'), false),
  ]
  return checks.find(c => c) || { ok: true }
})
await testCase('T195f the remedy follows the direction of the skew, a doubtful order gets the neutral one (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195f: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (pv.missing) return { ok: false, msg: 'pluginVersion markers or the BUILD version not found in pipeline source' }
  const { pluginVersionVerdict } = pv
  const OLDER = 'pass the current plugin root and relaunch'
  const NEWER = 'the engine is older than the plugin root: relaunch the workflow at the current version'
  const NEUTRAL = 'align the plugin root and the engine version, then relaunch'
  // [engine, root, remedy]: the order is numeric per field (beta.9 < beta.10), a release is above its pre-releases
  const cases = [
    ['1.0.0-beta.10', '1.0.0-beta.9', OLDER],
    ['1.0.0-beta.9', '1.0.0-beta.10', NEWER],
    ['1.0.0-beta.9', '0.9.9', OLDER],
    ['1.0.0-beta.9', '1.0.0', NEWER],
    ['1.0.0', '1.0.0-rc.1', OLDER],
    ['1.0.0-beta.9', '1.0.1-beta.1', NEWER],
    ['1.0.0-beta.9', '1.0.0-alpha.12', OLDER],
    ['1.0.0-beta.9', '1.0.0-beta.9+build.5', NEUTRAL],
    ['1.0.0-beta.9', 'not-a-version', NEUTRAL],
    ['1.0.0-beta.9', '1.0', NEUTRAL],
  ]
  for (const [engine, root, remedy] of cases) {
    const got = pluginVersionVerdict({ engineVersion: engine, exit: 0, lines: ['PLUGIN-VERSION:' + root] })
    const others = [OLDER, NEWER, NEUTRAL].filter((r) => r !== remedy)
    const bad = eq(`${root} vs engine ${engine}: a skew`, got && got.code, 'plugin-version-skew')
      || includes(`${root} vs engine ${engine}: remedy`, got.reason, remedy)
      || (others.some((o) => got.reason.includes(o)) ? { ok: false, msg: `${root} vs engine ${engine}: a remedy of another direction in "${got.reason}"` } : null)
    if (bad) return bad
  }
  return { ok: true }
})
await testCase('T195g the version is compared whole, never by prefix (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195g: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (pv.missing) return { ok: false, msg: 'pluginVersion markers or the BUILD version not found in pipeline source' }
  const { pluginVersionVerdict } = pv
  const v = (root) => pluginVersionVerdict({ engineVersion: '1.0.0-beta.9', exit: 0, lines: ['PLUGIN-VERSION:' + root] })
  const checks = [
    eq('the same version passes', v('1.0.0-beta.9'), null),
    eq('beta.90 is not beta.9', v('1.0.0-beta.90') && v('1.0.0-beta.90').code, 'plugin-version-skew'),
    eq('beta.9+x is not beta.9', v('1.0.0-beta.9+x') && v('1.0.0-beta.9+x').code, 'plugin-version-skew'),
    eq('beta.9 with a trailing space is not beta.9', v('1.0.0-beta.9 ') && v('1.0.0-beta.9 ').code, 'plugin-version-skew'),
    eq('a different case is not the same', v('1.0.0-BETA.9') && v('1.0.0-BETA.9').code, 'plugin-version-skew'),
  ]
  return checks.find(c => c) || { ok: true }
})
await testCase('T195c a missing or unreadable manifest, or no usable probe answer, fails closed with a readable reason (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195c: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (pv.missing) return { ok: false, msg: 'pluginVersion markers or the BUILD version not found in pipeline source' }
  const { V, pluginVersionVerdict } = pv
  const v = (o) => pluginVersionVerdict({ engineVersion: V, pluginRoot: '/r', exit: 0, lines: [], ...o })
  const cases = [
    ['manifest missing', v({ lines: ['PLUGIN-VERSION-ERROR:missing'] }), '(missing)'],
    ['manifest unreadable', v({ lines: ['PLUGIN-VERSION-ERROR:unreadable'] }), '(unreadable)'],
    ['manifest without a version', v({ lines: ['PLUGIN-VERSION-ERROR:no-version'] }), '(no-version)'],
    ['empty version', v({ lines: ['PLUGIN-VERSION:'] }), '(no usable answer)'],
    ['no line', v({ lines: [] }), '(no usable answer)'],
    ['two lines', v({ lines: ['PLUGIN-VERSION:' + V, 'extra'] }), '(no usable answer)'],
    ['command exit != 0', v({ exit: 127, lines: ['PLUGIN-VERSION:' + V] }), '(no usable answer)'],
  ]
  for (const [name, got, cause] of cases) {
    const bad = eq(name + ': code', got && got.code, 'plugin-version-unreadable')
      || includes(name + ': cause', got.reason, cause)
      || includes(name + ': names the manifest file', got.reason, '.claude-plugin/plugin.json')
      || eq(name + ': the reason carries no local path', got.reason.includes('/r/'), false)
      || includes(name + ': names the engine version', got.reason, V)
      || includes(name + ': names the remedy', got.reason, 'pass the current plugin root and relaunch')
    if (bad) return bad
  }
  return { ok: true }
})
await testCase('T195e a failure of the probe itself is the documented provision-failed, never plugin-version-unreadable (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195e: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (pv.missing) return { ok: false, msg: 'pluginVersion markers or the BUILD version not found in pipeline source' }
  const { V, pluginVersionVerdict } = pv
  // the hooks off (no-attestation), an unresolved agent type, a copy that altered the command: the probe never ran
  // to the point of reading the manifest, so the manifest is not what failed
  for (const reason of ['no-attestation', 'unparseable-line', 'cmd-mismatch', 'unparseable-verify', 'verify-hash-mismatch', 'sha-mismatch', 'probe-run-not-found']) {
    const got = pluginVersionVerdict({ engineVersion: V, pluginRoot: '/r', probeFailed: reason, lines: undefined })
    const bad = eq(reason + ': code', got && got.code, 'provision-failed')
      || eq(reason + ': reason is the documented one', got.reason, 'provision-failed')
    if (bad) return bad
  }
  // a probe that ran but printed a non-conforming answer stays plugin-version-unreadable (the manifest is what failed)
  const ran = pluginVersionVerdict({ engineVersion: V, pluginRoot: '/r', exit: 0, lines: ['PLUGIN-VERSION-ERROR:unreadable'] })
  return eq('a non-conforming answer is unreadable', ran && ran.code, 'plugin-version-unreadable') || { ok: true }
})
await testCase('T195d the check runs first, only when the templates come from pluginRoot, and writes no label (#195)', async () => {
  const pv = pluginVersionPieces()
  if (!pv) {
    log('SKIP — T195d: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const src = pv.src
  const gate = "if (!simulate && pluginRoot && !config.probeRunPath) {"
  const iGate = src.indexOf(gate)
  const iProvision = src.indexOf("await probe('provision',")
  if (iGate < 0) return { ok: false, msg: 'plugin-version gate not found in pipeline source' }
  const body = src.slice(iGate, src.indexOf('\n}\n', iGate))
  const checks = [
    eq('gate precedes the provision probe', iGate < iProvision, true),
    eq('gate reads the manifest through probe(lines) with noReuse', body.includes("probe('lines', pluginVersionCmd(pluginRoot), { label: 'plugin-version', noReuse: true"), true),
    eq('gate escalates on the existing status', body.includes("finish(STATUS['escalate'], { reason: skew.reason"), true),
    eq('the root path travels in its own result field, not in the reason', body.includes("{ reason: skew.reason, issue, pluginRoot, trace }"), true),
    eq('a failure of the probe itself keeps the provision-failed signature', body.includes("reason: 'provision-failed', issue, missing: [], exitCode: null, probeReason: pv.probeFailed, probeHint: PROBE_REASON_HINTS[pv.probeFailed]"), true),
    eq('gate writes no label (no updateStatus, no prWrite)', body.includes('updateStatus') || body.includes('prWrite'), false),
    eq('lines is registered in PROBES', src.includes("  'lines': 'lines',"), true),
  ]
  return checks.find(c => c) || { ok: true }
})

await testCase('T214d callAgent( only invoked by callAgentSafe + morgan; callAgentSafe( widely wired', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T214d: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const rawCalls = src.split('await callAgent(').length - 1
  const safeCalls = src.split('callAgentSafe(').length - 1
  const e1 = eq("count of 'await callAgent('", rawCalls, 2)
  const e2 = safeCalls >= 15
    ? null : { ok: false, msg: `expected >= 15 'callAgentSafe(' occurrences (definition + call sites), got ${safeCalls}` }
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

await testCase('T214e STRUCTURED_OUTPUT_MANDATE text + schema-gated finalPrompt injection present', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T214e: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const e1 = includes('mandate sentinel', src, 'FINAL-OUTPUT MANDATE (hard):')
  const e2 = includes('schema-gated finalPrompt', src,
    'opts && opts.schema ? `${prompt}\\n\\n${STRUCTURED_OUTPUT_MANDATE}` : prompt')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// No-PR terminal delivery — Nick can legitimately deliver without a PR (e.g. the
// deliverables were pre-existing PRs). Verified evidence (testsPass:true + summary) short-circuits
// Review straight to delivered-no-pr instead of throwing.
await testCase('nick delivers with prNumber:0 + testsPass:true → delivered-no-pr, no throw', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', nick: { prNumber: 0, testsPass: true } },
  })
  const e1 = eq('status', r.status, 'delivered-no-pr')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'delivered-no-pr'])
  const e3 = r.summary ? null : { ok: false, msg: `expected non-empty summary, got ${JSON.stringify(r.summary)}` }
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

await testCase('nick delivers with prNumber:0 + testsPass:false → escalate dev-stage-no-pr (no throw)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', nick: { prNumber: 0, testsPass: false } },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'dev-stage-no-pr')
  const e3 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'dev-stage-no-pr', 'Blocked'])
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// preflight.envSymlink (#70) — gates HARD preflight check 1. Repo-local knob, numbered
// T70a-T70d after the last local case (nick no-PR delivery).
await testCase('T70a preflight.envSymlink default (unset) → required, byte-identical check 1', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  const e3 = includes('preflightPromptPreview', r.preflightPromptPreview, '1. test -L "/tmp/lgtmgate-test/.env"')
  const e4 = r.preflightPromptPreview.includes('test ! -e')
    ? { ok: false, msg: `expected preflightPromptPreview NOT to include "test ! -e", got ${JSON.stringify(r.preflightPromptPreview)}` }
    : null
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

await testCase('T70b preflight.envSymlink forbidden → check 1 asserts absence', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, preflight: { envSymlink: 'forbidden' } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = includes('preflightPromptPreview', r.preflightPromptPreview, '1. test ! -e "/tmp/lgtmgate-test/.env"')
  const e2 = r.preflightPromptPreview.includes('test -L')
    ? { ok: false, msg: `expected preflightPromptPreview NOT to include "test -L", got ${JSON.stringify(r.preflightPromptPreview)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

await testCase('T70c preflight.envSymlink ignore → check 1 omitted, aggregation range shrinks to 2-3', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, preflight: { envSymlink: 'ignore' } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.preflightPromptPreview
  const e1 = p.includes('test -L') ? { ok: false, msg: `expected NOT to include "test -L", got ${JSON.stringify(p)}` } : null
  const e2 = p.includes('test ! -e') ? { ok: false, msg: `expected NOT to include "test ! -e", got ${JSON.stringify(p)}` } : null
  const e3 = includes('preflightPromptPreview', p, '2. git -C')
  const e4 = includes('preflightPromptPreview', p, '3. Unit suite still green')
  const e5 = includes('preflightPromptPreview', p, 'HARD checks 2-3 all pass')
  const err = e1 || e2 || e3 || e4 || e5
  return err ? err : { ok: true }
})

await testCase('T70d preflight.envSymlink invalid value → throws under dryRun (zero agent spawns)', async () => {
  try {
    await run({
      mode: 'manual',
      dryRun: true,
      config: { ...CONFIG, preflight: { envSymlink: 'yes' } },
    })
    return { ok: false, msg: 'expected run() to throw, it did not' }
  } catch (e) {
    if (!e.message.includes('Invalid preflight.envSymlink')) {
      return { ok: false, msg: `wrong error message: ${e.message}` }
    }
    return { ok: true }
  }
})

// T268-T269 (#13 / #12) — `config` is required and must be an object: a run without it (or with the
// JSON text instead of the parsed object) is refused by a throw BEFORE any stage runs, never
// executed on defaults. Non-dryRun with a full simulate: if the guard were missing the run would
// proceed to a real status instead of throwing.
for (const [id, tag, cfg] of [['a', 'absent', undefined], ['b', 'null', null], ['c', 'string', JSON.stringify(CONFIG)], ['d', 'array', []]]) {
  await testCase(`T268${id} config ${tag} -> refused before any stage (#13/#12)`, async () => {
    try {
      const r = await run({ mode: 'auto', config: cfg, simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
      return { ok: false, msg: `expected a throw, got status ${r.status}` }
    } catch (e) {
      return e.message.includes('Missing or invalid arg: config')
        ? { ok: true } : { ok: false, msg: `wrong error message: ${e.message}` }
    }
  })
}
await testCase('T269 explicit empty config object {} is still accepted (dry-run)', async () => {
  const r = await run({ mode: 'manual', dryRun: true, config: {} })
  return eq('status', r.status, 'dry-run-ok') || { ok: true }
})

// resolveWorktreeRoot (#61) — layered, machine-free worktree-root resolution, asserted via the
// simulate-only nickPromptPreview seam (mirrors preflightPromptPreview above). Numbered T71a-T71d.
await testCase('T71a resolveWorktreeRoot: relative logical default -> absolute in the Nick brief', async () => {
  const r = await run({
    mode: 'auto',
    wtPath: '/tmp/lgtmgate-worktrees/issue-1',
    config: { ...CONFIG, worktreeRoot: 'worktrees/lgtmgate' },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = includes('nickPromptPreview', r.nickPromptPreview, 'worktree root: /tmp/lgtmgate-worktrees')
  const e2 = r.nickPromptPreview.includes('worktrees/lgtmgate')
    ? { ok: false, msg: `expected nickPromptPreview NOT to include the raw relative default, got ${JSON.stringify(r.nickPromptPreview)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

await testCase('T71b resolveWorktreeRoot: $LGTMGATE_WORKTREE_ROOT beats local and versioned', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, worktreeRoot: '/tmp/lgtmgate-worktrees' },
    configLocal: { worktreeRoot: '/local/root' },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], env: { LGTMGATE_WORKTREE_ROOT: '/env/root' } },
  })
  const p = r.nickPromptPreview
  const e1 = includes('nickPromptPreview', p, 'worktree root: /env/root')
  const e2 = p.includes('/local/root') ? { ok: false, msg: `expected NOT to include "/local/root", got ${JSON.stringify(p)}` } : null
  const e3 = p.includes('/tmp/lgtmgate-worktrees') ? { ok: false, msg: `expected NOT to include "/tmp/lgtmgate-worktrees", got ${JSON.stringify(p)}` } : null
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

await testCase('T71c resolveWorktreeRoot: configLocal beats the versioned default', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, worktreeRoot: '/tmp/lgtmgate-worktrees' },
    configLocal: { worktreeRoot: '/local/root' },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.nickPromptPreview
  const e1 = includes('nickPromptPreview', p, 'worktree root: /local/root')
  const e2 = p.includes('/tmp/lgtmgate-worktrees') ? { ok: false, msg: `expected NOT to include "/tmp/lgtmgate-worktrees", got ${JSON.stringify(p)}` } : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

await testCase('T71d resolveWorktreeRoot: absolute versioned default passes through unchanged (non-regression)', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('nickPromptPreview', r.nickPromptPreview, 'worktree root: /tmp/lgtmgate-worktrees')
  return err ? err : { ok: true }
})

// #111: Nick's prompt only ever interpolated the plan (planBlock), never the raw issue brief —
// unlike Sam/Morgan, which both get brief AND plan. Asserts nickPromptPreview now carries the brief.
await testCase('T121 nickPrompt includes the raw issue brief alongside the plan (#111)', async () => {
  const marker = 'UNIQUE-BRIEF-MARKER-T104-xyz987'
  const r = await run({
    mode: 'auto',
    brief: marker,
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('nickPromptPreview', r.nickPromptPreview, marker)
  return err ? err : { ok: true }
})

// #76: R2 fixture item is generated by the workflow JS from the `issueType` launch arg + Sam's targets.
const R2_ITEM = 'fixtures/incidents/'
// #163: the R2 item is engine-repo only (config.engineRepo === true); T76a-c run on an engine config so they keep
// testing the trigger, T163b pins that a consumer config never carries it.
const R2_ENGINE_CONFIG = { ...CONFIG, engineRepo: true }
const r2Run = (issueType, targets, config = R2_ENGINE_CONFIG) => run({
  mode: 'auto',
  brief: 'r2-rule-probe',
  config,
  ...(issueType ? { issueType } : {}),
  simulate: { sam: 'GO', samTargetFiles: targets, morgan: [{ verdict: 'LGTM' }] },
})
const r2Absent = (p) => ['no-fixture', R2_ITEM, 'Refs #', 'R2 fixture rule']
  .map(v => p.includes(v) ? { ok: false, msg: `nickPromptPreview: unexpected ${JSON.stringify(v)}` } : null).find(Boolean) || null

await testCase('T76a issueType bug + workflows/ target -> nickPrompt carries the R2 item, no-fixture and Refs # (#76)', async () => {
  const r = await r2Run('bug', ['workflows/deliver-pipeline.js'])
  const p = r.nickPromptPreview
  const err = includes('nickPromptPreview', p, 'fixture `fixtures/incidents/')
    || includes('nickPromptPreview', p, 'replayed red on base and green on the branch by `scripts/run-offline.cjs`')
    || includes('nickPromptPreview', p, 'no-fixture')
    || includes('nickPromptPreview', p, 'Refs #')
  return err ? err : { ok: true }
})

await testCase('T76b issueType feature + workflows/ target -> nickPrompt carries no R2 text (#76)', async () => {
  const r = await r2Run('feature', ['workflows/deliver-pipeline.js'])
  const err = r2Absent(r.nickPromptPreview)
  return err ? err : { ok: true }
})

await testCase('T76c issueType bug + no workflows/ target -> nickPrompt carries no R2 text (#76)', async () => {
  const r = await r2Run('bug', ['agents/nick.md'])
  const err = r2Absent(r.nickPromptPreview)
  return err ? err : { ok: true }
})

// ---------------------------------------------------------------------------
// #87 fixtures — recordDecision's deterministic single-shell-chain body sync
// ---------------------------------------------------------------------------

// Pads PR385_BODY_REAL (the synthetic PR-body fixture defined above) up to ~20 KB by
// inserting filler paragraphs right after the "## Summary" heading — the acceptance
// block, decision-log markers and every other section stay untouched byte-for-byte. Mirrors
// the real-world size class that triggered the #87 truncation regression.
function buildPaddedBody20k(base) {
  const marker = '## Summary\n'
  const idx = base.indexOf(marker)
  if (idx === -1) throw new Error('T87a fixture: "## Summary" marker not found in base body')
  const insertAt = idx + marker.length
  const target = 20000
  const needed = Math.max(0, target - base.length)
  let filler = ''
  let i = 0
  while (filler.length < needed) {
    filler += `Filler paragraph ${i} — realistic padding text describing additional context, ` +
      `rationale and detail for this section, used only to grow the fixture body toward a ` +
      `20 KB real-world size for the byte-identity regression test (issue #87).\n\n`
    i++
  }
  filler = filler.slice(0, needed)
  return base.slice(0, insertAt) + filler + base.slice(insertAt)
}

const PR385_BODY_20K = buildPaddedBody20k(PR385_BODY_REAL)

function extractBetween(str, startMarker, endMarker) {
  const s = String(str).indexOf(startMarker)
  const e = String(str).indexOf(endMarker)
  if (s === -1 || e === -1) return null
  return String(str).slice(s, e + endMarker.length)
}

// T87a (#87, real-scale fixture) — the SAME decision-log composer T39 exercises (extracted in
// #87 step 1 into composeDecisionLogBlock + spliceDecisionLogBlock), fed a 20 KB body through a
// 2-round REQUIRED_CHANGES→LGTM flow. Guards the byte-identity property the #87 bug broke: the
// acceptance-checklist block must survive UNCHANGED outside the decision-log region.
await testCase('T87a decision-log composer on a 20 KB body — acceptance block byte-identical, both rounds land, single block', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }],
      prBody: PR385_BODY_20K,
    },
  })
  const body = r.prBodyPreview || ''
  const errs = []
  const beforeAcc = extractBetween(PR385_BODY_20K, '<!-- acceptance:start -->', '<!-- acceptance:end -->')
  const afterAcc = extractBetween(body, '<!-- acceptance:start -->', '<!-- acceptance:end -->')
  if (beforeAcc === null || afterAcc === null) errs.push('acceptance block not found')
  else if (beforeAcc !== afterAcc) errs.push('acceptance block content drifted')
  if (countOccurrences(body, '<!-- decision-log:start -->') !== 1) errs.push('decision-log:start not exactly 1')
  if (!body.includes('- round 0 — REQUIRED_CHANGES (1 blocker)')) errs.push('missing round 0 entry')
  if (!body.includes('- round 1 — LGTM')) errs.push('missing round 1 entry')
  if (countUncheckedBoxes(body) !== countUncheckedBoxes(PR385_BODY_20K)) errs.push('unchecked-box count drifted')
  return errs.length ? { ok: false, msg: errs.join('; ') } : { ok: true }
})

// T87b (#87, guard probe) — direct probe of the REAL production bodyWriteGuardOk (never a
// hand-duplicated copy) via the additive simulate.recordDecisionGuardProbe lever, which is a
// no-op on every pre-existing case that doesn't set it (mirrors simulate.artifactFloor /
// simulate.behindCount). False on a body truncated well below the 90% floor; true on a
// full-length body still carrying both acceptance markers.
await testCase('T87b bodyWriteGuardOk guard probe — false on truncated body, true on full body', async () => {
  const rTruncated = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      recordDecisionGuardProbe: { preLen: 20000, newBody: 'x'.repeat(500) },
    },
  })
  const rFull = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      recordDecisionGuardProbe: {
        preLen: 20000,
        newBody: 'y'.repeat(20000) + '<!-- acceptance:start -->\n<!-- acceptance:end -->',
      },
    },
  })
  const e1 = eq('guardProbeResult (truncated)', rTruncated.guardProbeResult, false)
  const e2 = eq('guardProbeResult (full)', rFull.guardProbeResult, true)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T87c (#87, negative control) — `command grep -cF "pr-body-read" workflows/deliver-pipeline.js`
// must print 0 (the old lossy-relay labels are gone). This is a Morgan-run shell acceptance
// item, NOT a JS test case — a hand-written JS equivalent could silently drift from the real
// grep, so it stays out of this suite by design (see the PR acceptance checklist).

// ---------------------------------------------------------------------------
// T88-T97 — audit-budget ceiling, auditTrace/roundOneAboveTarget convergence
// note, and the design-step-trigger gate (Theo's independent risk classification, never a
// self-declared tag). Incident: the Lead bumped maxAuditRounds 3->7 across 5 relaunches, burning
// a large token budget on a non-convergent blocker series (5,6,3,3,6) — this file's own doctrine already
// said "audit budget is 2 rounds, never extended", nothing enforced it.
// ---------------------------------------------------------------------------

await testCase('T88 maxAuditRounds:3 without a reason → throws under dryRun (zero agent spawns)', async () => {
  try {
    await run({ mode: 'manual', dryRun: true, maxAuditRounds: 3 })
    return { ok: false, msg: 'expected run() to throw, it did not' }
  } catch (e) {
    if (!e.message.includes('exceeds the doctrine ceiling') || !e.message.includes('maxAuditRoundsOverrideReason')) {
      return { ok: false, msg: `wrong error message: ${e.message}` }
    }
    return { ok: true }
  }
})

await testCase('T89 maxAuditRounds:3 + whitespace-only reason → still throws (blank is not a justification)', async () => {
  try {
    await run({ mode: 'manual', dryRun: true, maxAuditRounds: 3, maxAuditRoundsOverrideReason: '   ' })
    return { ok: false, msg: 'expected run() to throw, it did not' }
  } catch (e) {
    if (!e.message.includes('exceeds the doctrine ceiling')) {
      return { ok: false, msg: `wrong error message: ${e.message}` }
    }
    return { ok: true }
  }
})

await testCase('T90 maxAuditRounds:2 (the ceiling itself) never requires a reason — boundary regression', async () => {
  const r = await run({ mode: 'manual', dryRun: true, maxAuditRounds: 2 })
  const e1 = eq('status', r.status, 'dry-run-ok')
  const e2 = eq('maxAuditRoundsOverrideReason', r.maxAuditRoundsOverrideReason, null)
  const err = e1 || e2
  return err ? err : { ok: true }
})

await testCase('T91 maxAuditRounds:3 + a real reason → dry-run-ok, both fields echoed', async () => {
  const r = await run({
    mode: 'manual', dryRun: true, maxAuditRounds: 3,
    maxAuditRoundsOverrideReason: 'CS-6-shaped risk class justifies one extra round',
  })
  const e1 = eq('status', r.status, 'dry-run-ok')
  const e2 = eq('maxAuditRounds', r.maxAuditRounds, 3)
  const e3 = eq('maxAuditRoundsOverrideReason', r.maxAuditRoundsOverrideReason, 'CS-6-shaped risk class justifies one extra round')
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

await testCase('T92 auditTrace shape on a clean round-1 SOUND pass (semi mode, stops at plan-ready)', async () => {
  const r = await run({
    mode: 'semi',
    planAudit: true,
    simulate: { sam: 'GO', audit: { 1: { verdict: 'SOUND', findings: [] } } },
  })
  const e1 = eq('status', r.status, 'plan-ready')
  const e2 = eq('auditTrace', r.auditTrace, [{ round: 1, verdict: 'SOUND', blockingCount: 0, structuralMistakeCount: 0 }])
  const e3 = eq('roundOneAboveTarget', r.roundOneAboveTarget, false)
  const e4 = eq('blockingSeries', r.blockingSeries, [0])
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

await testCase('T93 auditTrace on a 2-round NOT_SOUND escalation (count exactly 1 each round) → roundOneAboveTarget false', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      planCheck: [{ verdict: 'CONFORMING' }, { verdict: 'CONFORMING' }],
      audit: {
        1: { verdict: 'NOT_SOUND', findings: [{ severity: 'blocking', title: 'bad', finding: 'f', fix: 'x' }] },
        2: { verdict: 'NOT_SOUND', findings: [{ severity: 'blocking', title: 'still bad', finding: 'f2', fix: 'x2' }] },
      },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('auditTrace', r.auditTrace, [
    { round: 1, verdict: 'NOT_SOUND', blockingCount: 1, structuralMistakeCount: 0 },
    { round: 2, verdict: 'NOT_SOUND', blockingCount: 1, structuralMistakeCount: 0 },
  ])
  const e3 = eq('roundOneAboveTarget', r.roundOneAboveTarget, false)
  const e4 = eq('blockingSeries', r.blockingSeries, [1, 1])
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

await testCase('T94 round-1-with-2-blockers → roundOneAboveTarget true (proves the flag actually fires)', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      planCheck: [{ verdict: 'CONFORMING' }, { verdict: 'CONFORMING' }],
      audit: {
        1: { verdict: 'NOT_SOUND', findings: [
          { severity: 'blocking', title: 'a', finding: 'f', fix: 'x' },
          { severity: 'blocking', title: 'b', finding: 'f2', fix: 'x2' },
        ] },
        2: { verdict: 'NOT_SOUND', findings: [{ severity: 'blocking', title: 'still bad', finding: 'f3', fix: 'x3' }] },
      },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('roundOneBlockingCount', r.roundOneBlockingCount, 2)
  const e3 = eq('roundOneAboveTarget', r.roundOneAboveTarget, true)
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

await testCase('T95 mixed debtClass round → blockingCount/structuralMistakeCount independent, routing unaffected by debtClass', async () => {
  const r = await run({
    mode: 'semi',
    planAudit: true,
    simulate: {
      sam: 'GO',
      audit: {
        1: {
          verdict: 'SOUND-WITH-NOTES',
          findings: [
            { severity: 'blocking', debtClass: 'structural-mistake', title: 'a', finding: 'f', fix: 'x' },
            { severity: 'blocking', debtClass: 'fenced-debt', title: 'b', finding: 'f2', fix: 'x2' },
          ],
        },
      },
    },
  })
  // A SOUND-WITH-NOTES verdict with 2 blocking findings must still amend (routing keys on
  // severity, never on verdict alone or on debtClass) — this run stops at plan-ready because
  // maxAuditRounds defaults to 2 and round 1 already forces an amendment; assert round 1's
  // recorded counts before the (simulated, SOUND) round 2 completes it.
  const e1 = eq('auditTrace[0]', r.auditTrace[0], { round: 1, verdict: 'SOUND-WITH-NOTES', blockingCount: 2, structuralMistakeCount: 1 })
  const e2 = includes('trace', r.trace, 'plan-audit-amend:1')
  const err = e1 || e2
  return err ? err : { ok: true }
})

await testCase('T96 CS-6-shaped replay at the DEFAULT ceiling (2 rounds) — demonstrates non-convergence itself', async () => {
  const r = await run({
    mode: 'auto',
    planAudit: true,
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      planCheck: [{ verdict: 'CONFORMING' }, { verdict: 'CONFORMING' }],
      audit: {
        1: { verdict: 'SOUND-WITH-NOTES', findings: Array.from({ length: 5 }, (_, i) => ({ severity: 'blocking', title: `f${i}`, finding: 'x', fix: 'y' })) },
        2: { verdict: 'SOUND-WITH-NOTES', findings: Array.from({ length: 6 }, (_, i) => ({ severity: 'blocking', title: `g${i}`, finding: 'x', fix: 'y' })) },
      },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-not-sound')
  const e3 = eq('blockingSeries', r.blockingSeries, [5, 6])
  const e4 = eq('roundOneAboveTarget', r.roundOneAboveTarget, true)
  const e5 = eq('maxAuditRoundsOverrideReason', r.maxAuditRoundsOverrideReason, null)
  const err = e1 || e2 || e3 || e4 || e5
  return err ? err : { ok: true }
})

// T97 (B1-B3) — design-step trigger: Theo's independent classification (>=2 of persistent-state /
// auth-security / deploy-config) blocks the run BEFORE Sam plans, unless architectureDecisionApproved
// or proceedThrough:'plan' (the scoped architecture-only pass) is asserted.
await testCase('T97a design-step trigger fires (2/3 signals) → design-step-required, Sam never invoked', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      theo: {
        confirmed: true, evidence: 'e', actualCause: '',
        persistentStateSignal: true, authSecurityBoundarySignal: true, deployConfigSignal: false,
        immatureVendorApiSignal: false, designStepSignalEvidence: 'Domain model persists state; ALLOWED_HOSTS is an auth boundary',
      },
      sam: 'GO',
    },
  })
  const e1 = eq('status', r.status, 'design-step-required')
  const e2 = eq('designStepSignalCount', r.designStepSignalCount, 2)
  const e3 = r.trace.some(t => String(t).startsWith('scout-issue'))
    ? { ok: false, msg: `expected Sam never invoked, trace: ${JSON.stringify(r.trace)}` } : null
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

await testCase('T97b design-step trigger fires on the immature-vendor-API signal ALONE (not folded into the 2-of-3 count)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      theo: {
        confirmed: true, evidence: 'e', actualCause: '',
        persistentStateSignal: false, authSecurityBoundarySignal: false, deployConfigSignal: false,
        immatureVendorApiSignal: true, designStepSignalEvidence: 'Cloud Run domain mappings: preview, not production-ready',
      },
      sam: 'GO',
    },
  })
  const err = eq('status', r.status, 'design-step-required')
  return err ? err : { ok: true }
})

await testCase('T97c design-step trigger + architectureDecisionApproved:true → gate does not fire, Sam proceeds', async () => {
  const r = await run({
    mode: 'semi',
    architectureDecisionApproved: true,
    simulate: {
      theo: {
        confirmed: true, evidence: 'e', actualCause: '',
        persistentStateSignal: true, authSecurityBoundarySignal: true, deployConfigSignal: true,
        immatureVendorApiSignal: false, designStepSignalEvidence: 'e',
      },
      sam: 'GO',
    },
  })
  const err = eq('status', r.status, 'plan-ready')
  return err ? err : { ok: true }
})

await testCase("T97d design-step trigger + proceedThrough:'plan' → gate does not fire, scoped architecture-only pass proceeds", async () => {
  const r = await run({
    mode: 'semi',
    proceedThrough: 'plan',
    simulate: {
      theo: {
        confirmed: true, evidence: 'e', actualCause: '',
        persistentStateSignal: true, authSecurityBoundarySignal: true, deployConfigSignal: true,
        immatureVendorApiSignal: false, designStepSignalEvidence: 'e',
      },
      sam: 'GO',
    },
  })
  const err = eq('status', r.status, 'plan-ready')
  return err ? err : { ok: true }
})

await testCase('T97e no design-step signals (0/3, no immature API) → gate never fires, ordinary run proceeds', async () => {
  const r = await run({
    mode: 'semi',
    simulate: {
      theo: { confirmed: true, evidence: 'e', actualCause: '', persistentStateSignal: false, authSecurityBoundarySignal: false, deployConfigSignal: false, immatureVendorApiSignal: false },
      sam: 'GO',
    },
  })
  const err = eq('status', r.status, 'plan-ready')
  return err ? err : { ok: true }
})

// T77 (#77, R3) — 5th design-step signal computed by the script from Sam's plan announcement and
// targetFiles, against what the repo declares: `config.oneWayDoorKinds` (status|agent|hook|seam) and
// `config.oneWayDoorPaths`, both default none. A declared kind announced, or a declared path targeted,
// ends the run in design-step-required; a repo that declares nothing is never stopped nor asked.
const T77_THEO = { confirmed: true, evidence: 'e', actualCause: '', persistentStateSignal: false, authSecurityBoundarySignal: false, deployConfigSignal: false, immatureVendorApiSignal: false }
// #153: a plan returned by Sam must carry the checklist lines she also returns; a custom samPlan therefore
// ends with the default simulated checklist, as the default simulated plan does.
const T77_CK = '\n' + SIM_DEFAULTS.samAcceptanceChecklist
// The four kinds the mechanism knows; T77a/T77d/T77k pin it with them explicitly, T77m pins that this
// repo's own config still declares them.
const T77_KINDS = ['status', 'agent', 'hook', 'seam']
const T77_KCONFIG = { ...CONFIG, oneWayDoorKinds: T77_KINDS }
// samOneWayDoorText / oneWayDoorKindsOf, extracted from the engine's pure `oneWayDoor` block (null when
// the suite does not get the pipeline source).
const t77Block = () => {
  const src = SUITE_ARGS.fpSource
  if (!src) return null
  const block = extractBetween(src, '// --- oneWayDoor:start ---', '// --- oneWayDoor:end ---')
  // eslint-disable-next-line no-new-func
  return block ? new Function(block + '\nreturn { samOneWayDoorText, oneWayDoorKindsOf }')() : null
}
await testCase('T77a R3: a plan announcing a new status, kinds declared → design-step-required with a <=10-line summary', async () => {
  const r = await run({
    mode: 'semi',
    config: T77_KCONFIG,
    simulate: { theo: T77_THEO, sam: 'GO', samPlan: '## Plan\n1. add it\none-way-door: status — new `foo-blocked` terminal status\n' + T77_CK },
  })
  const e1 = eq('status', r.status, 'design-step-required')
  const e2 = eq('oneWayDoorHits', JSON.stringify(r.oneWayDoorHits), JSON.stringify(['status']))
  const e3 = String(r.reason || '').split('\n').length <= 10 && String(r.reason).includes('foo-blocked')
    ? null : { ok: false, msg: `bad summary: ${JSON.stringify(r.reason)}` }
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T77b / T77f / T77m use this repo's own declared paths and kinds (SUITE_ARGS.repoConfig, passed by
// scripts/run-flow-suite.cjs): the engine knows no path and no kind by itself.
const OWD_REPO_PATHS = Array.isArray(SUITE_ARGS.repoConfig?.oneWayDoorPaths) ? SUITE_ARGS.repoConfig.oneWayDoorPaths : null
await testCase('T77b R3: targetFiles touching hooks/plugin-hooks.json with this repo\'s oneWayDoorPaths → design-step-required (path)', async () => {
  if (!OWD_REPO_PATHS) {
    log('SKIP — T77b: SUITE_ARGS.repoConfig.oneWayDoorPaths absent (suite not run via scripts/run-flow-suite.cjs from the repo root)')
    return { ok: true }
  }
  for (const file of ['hooks/plugin-hooks.json', 'hooks/SessionStart/inject_stub.py', 'hooks/lib-worktree-root.sh']) {
    const r = await run({
      mode: 'semi',
      config: { ...CONFIG, oneWayDoorPaths: OWD_REPO_PATHS },
      simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK, samTargetFiles: [file] },
    })
    const err = eq(`status for ${file}`, r.status, 'design-step-required') || eq(`hits for ${file}`, JSON.stringify(r.oneWayDoorHits), JSON.stringify(['path']))
    if (err) return err
  }
  return { ok: true }
})

await testCase('T77c R3 negative: no announcement (`one-way-door: none`, ordinary targets, test scripts under hooks/) → plan-ready, R3 does not trigger', async () => {
  const r = await run({
    mode: 'semi',
    config: { ...T77_KCONFIG, oneWayDoorPaths: OWD_REPO_PATHS || [] },
    simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK, samTargetFiles: ['workflows/deliver-pipeline.js', 'hooks/test-block-merge-unchecked.sh'] },
  })
  const err = eq('status', r.status, 'plan-ready')
  return err ? err : { ok: true }
})

await testCase('T77d R3 + architectureDecisionApproved:true → an announced declared kind no longer stops the run', async () => {
  const r = await run({
    mode: 'semi',
    config: T77_KCONFIG,
    architectureDecisionApproved: true,
    simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'one-way-door: agent — new reviewer agent' + T77_CK },
  })
  const err = eq('status', r.status, 'plan-ready')
  return err ? err : { ok: true }
})

// T208 (#208) — the relaunch contract of the design-step stop. proceedThrough is validated up front (a typo
// is refused with a readable reason on the existing escalate status) and echoed by dryRun; proceedThrough:'plan'
// resolves the one-way-door stop exactly as it resolves Theo's trigger (stopping at plan-ready); a launch entering
// at dev|review cannot bypass an unapproved one-way-door plan.
const T208_PLAN = 'one-way-door: status — x\n' + T77_CK
const t208NoDev = (r) => (r.trace || []).includes('Dev') ? { ok: false, msg: `trace must not include Dev, got ${JSON.stringify(r.trace)}` } : null
await testCase('T208a proceedThrough validation: a typo ("Plan") is refused up front on escalate with a reason naming the value', async () => {
  const r = await run({ mode: 'auto', proceedThrough: 'Plan', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'escalate')
  const reason = String(r.reason || '')
  const e2 = reason.includes('proceedThrough') && reason.includes('"Plan"') ? null : { ok: false, msg: `reason must name proceedThrough and "Plan", got ${JSON.stringify(r.reason)}` }
  const e3 = r.plan === undefined ? null : { ok: false, msg: 'nothing must run: no plan field expected' }
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T208b proceedThrough validation: dryRun echoes the resolved value, and refuses a bad one too', async () => {
  const set = await run({ dryRun: true, proceedThrough: 'plan' })
  const none = await run({ dryRun: true })
  const bad = await run({ dryRun: true, proceedThrough: 'ship' })
  return eq('dry-run status', set.status, 'dry-run-ok')
    || eq('echo of plan', set.proceedThrough, 'plan')
    || eq('echo when absent', none.proceedThrough, null)
    || eq('bad value status', bad.status, 'escalate')
    || { ok: true }
})

await testCase('T208c design-step one-way-door relaunch: proceedThrough:plan → plan-ready carrying oneWayDoorHits, never Dev (semi and auto)', async () => {
  for (const mode of ['semi', 'auto']) {
    const r = await run({ mode, proceedThrough: 'plan', config: T77_KCONFIG, simulate: { theo: T77_THEO, sam: 'GO', samPlan: T208_PLAN } })
    const err = eq(`status (${mode})`, r.status, 'plan-ready')
      || eq(`oneWayDoorHits (${mode})`, JSON.stringify(r.oneWayDoorHits), JSON.stringify(['status']))
      || t208NoDev(r)
    if (err) return err
  }
  return { ok: true }
})

await testCase('T208d design-step one-way-door relaunch: proceedThrough:dev at entryStage plan does not lift the stop', async () => {
  const r = await run({ mode: 'semi', proceedThrough: 'dev', config: T77_KCONFIG, simulate: { theo: T77_THEO, sam: 'GO', samPlan: T208_PLAN } })
  return eq('status', r.status, 'design-step-required') || t208NoDev(r) || { ok: true }
})

await testCase('T208e design-step relaunch: entry at dev without approval, planText announcing a declared kind → design-step-required with a readable reason', async () => {
  const r = await run({ entryStage: 'dev', mode: 'semi', config: T77_KCONFIG, planText: T208_PLAN, simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const reason = String(r.reason || '')
  return eq('status', r.status, 'design-step-required')
    || eq('oneWayDoorHits', JSON.stringify(r.oneWayDoorHits), JSON.stringify(['status']))
    || (reason.includes('architectureDecisionApproved:true') ? null : { ok: false, msg: `reason must name architectureDecisionApproved:true, got ${JSON.stringify(r.reason)}` })
    || t208NoDev(r)
    || { ok: true }
})

await testCase('T208f design-step relaunch: entry at dev with architectureDecisionApproved:true proceeds; a plan announcing none, or a kind the repo did not declare, also proceeds', async () => {
  const sim = { sam: 'GO', morgan: [{ verdict: 'LGTM' }] }
  const approved = await run({ entryStage: 'dev', mode: 'semi', config: T77_KCONFIG, architectureDecisionApproved: true, planText: T208_PLAN, simulate: sim })
  const none = await run({ entryStage: 'dev', mode: 'semi', config: T77_KCONFIG, planText: 'one-way-door: none\n' + T77_CK, simulate: sim })
  const undeclared = await run({ entryStage: 'dev', mode: 'semi', config: CONFIG, planText: T208_PLAN, simulate: sim })
  return eq('approved', approved.status, 'ready')
    || eq('announces none', none.status, 'ready')
    || eq('kind not declared', undeclared.status, 'ready')
    || { ok: true }
})

await testCase('T208g design-step relaunch: entry at review without approval is refused too', async () => {
  const r = await run({ entryStage: 'review', prNumber: 190, mode: 'semi', config: T77_KCONFIG, planText: T208_PLAN, simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  return eq('status', r.status, 'design-step-required') || eq('oneWayDoorHits', JSON.stringify(r.oneWayDoorHits), JSON.stringify(['status'])) || { ok: true }
})

await testCase('T208h design-step relaunch: entry at dev|review without planText (absent, empty, blank) on a repo declaring kinds or paths → design-step-required naming planText; approval or no declaration proceeds as before', async () => {
  const sim = { sam: 'GO', morgan: [{ verdict: 'LGTM' }] }
  const configs = { kinds: T77_KCONFIG, paths: { ...CONFIG, oneWayDoorPaths: ['workflows/'] } }
  for (const [label, config] of Object.entries(configs)) {
    for (const [blank, extra] of [['absent', {}], ['empty', { planText: '' }], ['blank', { planText: '  \n ' }]]) {
      for (const entry of [{ entryStage: 'dev' }, { entryStage: 'review', prNumber: 190 }]) {
        const r = await run({ ...entry, mode: 'auto', config, ...extra, simulate: sim })
        const reason = String(r.reason || '')
        const err = eq(`status (${label}, ${blank}, ${entry.entryStage})`, r.status, 'design-step-required')
          || (reason.includes('planText') && reason.includes('architectureDecisionApproved:true') ? null : { ok: false, msg: `reason must name planText and architectureDecisionApproved:true, got ${JSON.stringify(r.reason)}` })
          || ((r.trace || []).includes('one-way-door-entry:no-plan-text') ? null : { ok: false, msg: `trace must carry one-way-door-entry:no-plan-text, got ${JSON.stringify(r.trace)}` })
          || t208NoDev(r)
        if (err) return err
      }
    }
  }
  const approved = await run({ entryStage: 'dev', mode: 'auto', config: T77_KCONFIG, architectureDecisionApproved: true, simulate: sim })
  const undeclared = await run({ entryStage: 'dev', mode: 'auto', config: CONFIG, simulate: sim })
  const emptyDeclared = await run({ entryStage: 'dev', mode: 'auto', config: { ...CONFIG, oneWayDoorKinds: [], oneWayDoorPaths: [] }, simulate: sim })
  return eq('approved without planText', approved.status, 'ready')
    || eq('nothing declared', undeclared.status, 'ready')
    || eq('empty declarations', emptyDeclared.status, 'ready')
    || { ok: true }
})

await testCase('T208i design-step relaunch: the already-done guard wins over the entry check (no Blocked write, status already-done)', async () => {
  const r = await run({
    entryStage: 'dev', mode: 'semi', config: T77_KCONFIG, planText: T208_PLAN,
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], alreadyDoneCheck: { isAlreadyDone: true, isIssueClosed: true, issueState: 'CLOSED', isMerged: false } },
  })
  const blocked = (r.trace || []).filter((t) => /one-way-door|Blocked/.test(String(t)))
  return eq('status', r.status, 'already-done')
    || (blocked.length === 0 ? null : { ok: false, msg: `no design-step trace nor Blocked write expected, got ${JSON.stringify(blocked)}` })
    || { ok: true }
})

await testCase('T208j proceedThrough validation: every non-stage value (0, false, true, 1, [], {}, "") is refused with invalid-proceedThrough', async () => {
  for (const v of [0, false, true, 1, [], {}, '']) {
    const r = await run({ mode: 'auto', proceedThrough: v, simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
    const err = eq(`status for ${JSON.stringify(v)}`, r.status, 'escalate')
      || (String(r.reason || '').startsWith('invalid-proceedThrough') ? null : { ok: false, msg: `reason must start with invalid-proceedThrough for ${JSON.stringify(v)}, got ${JSON.stringify(r.reason)}` })
    if (err) return err
  }
  return { ok: true }
})

await testCase('T208k design-step one-way-door relaunch: proceedThrough:review at entryStage plan does not lift the stop either (only "plan" does)', async () => {
  const r = await run({ mode: 'semi', proceedThrough: 'review', config: T77_KCONFIG, simulate: { theo: T77_THEO, sam: 'GO', samPlan: T208_PLAN } })
  return eq('status', r.status, 'design-step-required') || t208NoDev(r) || { ok: true }
})

// T77e (#77) — the product-direction line goes to Sam and Morgan only: Nick's prompt carries none, and no
// prompt of the engine names docs/codemap.md. The engine imports no doc: agents receive each repo's own
// instructions natively. The rules themselves live in the repo's docs, never in the prompt (no DEBT marker).
await testCase('T77e Nick prompt carries no product-direction line and names no doc; Sam and Morgan get the tool-neutral line', async () => {
  const r = await run({
    entryStage: 'dev',
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const p = String(r.nickPromptPreview || '')
  if (!p) return { ok: false, msg: 'nickPromptPreview empty' }
  if (p.includes('PRODUCT DIRECTION')) return { ok: false, msg: 'nickPromptPreview carries the product-direction line; it is for Sam and Morgan only' }
  if (p.includes('docs/codemap.md')) return { ok: false, msg: 'nickPromptPreview names docs/codemap.md; no agent prompt gets it' }
  if (p.includes('DEBT(#')) return { ok: false, msg: 'nickPromptPreview carries DEBT marker syntax; the rule belongs to the repo docs' }
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T77e source checks: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (src.includes('docs/codemap.md')) return { ok: false, msg: 'workflow source names docs/codemap.md; no agent prompt gets it' }
  if (src.includes('ARCH_IMPORT_')) return { ok: false, msg: 'an ARCH_IMPORT_* read instruction is still present; the engine imports no doc' }
  for (const use of ['${SAM_ONE_WAY_DOOR}${SAM_PRODUCT_DIRECTION}', '`${MORGAN_PRODUCT_DIRECTION}`']) {
    if (!src.includes(use)) return { ok: false, msg: `workflow source lacks ${use}` }
  }
  return { ok: true }
})

// T77f (#77) — docs/critical-paths.md is a one-way door of this repo (its oneWayDoorPaths): a plan targeting
// it stops at the design step, detected from targetFiles alone (no announcement needed).
await testCase('T77f R3: targetFiles touching docs/critical-paths.md with this repo\'s oneWayDoorPaths → design-step-required (path)', async () => {
  if (!OWD_REPO_PATHS) {
    log('SKIP — T77f: SUITE_ARGS.repoConfig.oneWayDoorPaths absent (suite not run via scripts/run-flow-suite.cjs from the repo root)')
    return { ok: true }
  }
  const r = await run({
    mode: 'semi',
    config: { ...CONFIG, oneWayDoorPaths: OWD_REPO_PATHS },
    simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK, samTargetFiles: ['docs/critical-paths.md'] },
  })
  const err = eq('status', r.status, 'design-step-required') || eq('hits', JSON.stringify(r.oneWayDoorHits), JSON.stringify(['path']))
  return err ? err : { ok: true }
})

// T77h (#77, consumer neutrality) — the one-way-door PATHS are per-project config (`oneWayDoorPaths`), never
// engine knowledge: a consumer config without the key (or with `[]`) is not stopped by a plan that touches
// hooks/ scripts or docs/critical-paths.md, whatever Sam targets.
await testCase('T77h R3 consumer: no oneWayDoorPaths in config, plan touches hooks/foo.sh + docs/critical-paths.md → no design-step stop', async () => {
  for (const config of [CONFIG, { ...CONFIG, oneWayDoorPaths: [] }]) {
    const r = await run({
      mode: 'semi',
      config,
      simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK, samTargetFiles: ['hooks/foo.sh', 'hooks/plugin-hooks.json', 'docs/critical-paths.md'] },
    })
    const err = eq('status', r.status, 'plan-ready') || eq('oneWayDoorHits', r.oneWayDoorHits, undefined)
    if (err) return err
  }
  return { ok: true }
})

await testCase('T77i R3: oneWayDoorPaths set to hooks/*.sh + docs/critical-paths.md, same plan → design-step-required (path), summary names the file', async () => {
  const r = await run({
    mode: 'semi',
    config: { ...CONFIG, oneWayDoorPaths: ['hooks/*.sh', 'docs/critical-paths.md'] },
    simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK, samTargetFiles: ['hooks/foo.sh', 'docs/critical-paths.md'] },
  })
  const e1 = eq('status', r.status, 'design-step-required') || eq('hits', JSON.stringify(r.oneWayDoorHits), JSON.stringify(['path']))
  if (e1) return e1
  const lines = String(r.reason || '').split('\n')
  return lines.length <= 10 && String(r.reason).includes('hooks/foo.sh') && String(r.reason).includes('oneWayDoorPaths: hooks/*.sh')
    ? { ok: true } : { ok: false, msg: `bad summary: ${JSON.stringify(r.reason)}` }
})

// T77j — matching style of an entry: `<dir>/` prefix, `*` within a segment, `**` across segments, `?` one
// character, `!<entry>` exclusion that wins over any other entry, anything else an exact path.
await testCase('T77j R3 path entries: prefix, *, **, ?, ! exclusion and exact path match as documented', async () => {
  const config = { ...CONFIG, oneWayDoorPaths: ['hooks/*.sh', '!hooks/test-*', 'docs/', 'src/**.gen.ts', 'lib/v?.js', 'Makefile'] }
  const stops = async (file) => {
    const r = await run({
      mode: 'semi',
      config,
      simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK, samTargetFiles: [file] },
    })
    return r.status === 'design-step-required'
  }
  const expectations = [
    ['hooks/a.sh', true], ['hooks/test-a.sh', false], ['hooks/sub/a.sh', false], ['hooks/a.py', false],
    ['docs/x/y.md', true], ['documents/x.md', false],
    ['src/a/b/c.gen.ts', true], ['src/c.gen.ts', true], ['src/c.ts', false],
    ['lib/v1.js', true], ['lib/v10.js', false], ['lib/v/.js', false],
    ['Makefile', true], ['sub/Makefile', false],
  ]
  for (const [file, want] of expectations) {
    const got = await stops(file)
    if (got !== want) return { ok: false, msg: `oneWayDoorPaths vs ${file}: stops=${got}, expected ${want}` }
  }
  return { ok: true }
})

// T77k — with the four kinds declared, each announced kind stops the run; `none`, a placeholder and any
// other word (`guard`, `rule`, `migration`) have no effect, alone or next to a real kind.
await testCase('T77k R3 announcement, four kinds declared: only status|agent|hook|seam stop the run; none, a placeholder and any other word do not', async () => {
  const runPlan = async (planText) => run({
    mode: 'semi',
    config: T77_KCONFIG,
    simulate: { theo: T77_THEO, sam: 'GO', samPlan: `plan\n${planText}` + T77_CK },
  })
  for (const kind of T77_KINDS) {
    const r = await runPlan(`one-way-door: ${kind} — new ${kind}`)
    const err = eq(`status for kind ${kind}`, r.status, 'design-step-required') || eq(`hits for ${kind}`, JSON.stringify(r.oneWayDoorHits), JSON.stringify([kind]))
    if (err) return err
  }
  for (const line of ['one-way-door: none', 'one-way-door: none — nothing here', 'announce with `one-way-door: <kind> — <what>`',
    'one-way-door: guard — new guard', 'one-way-door: rule — new rule', 'one-way-door: migration — add the users table']) {
    const r = await runPlan(line)
    const err = eq(`status for ${JSON.stringify(line)}`, r.status, 'plan-ready') || eq(`hits for ${JSON.stringify(line)}`, r.oneWayDoorHits, undefined)
    if (err) return err
  }
  const mixed = await runPlan('one-way-door: guard — new guard\none-way-door: hook — new hook')
  return eq('status for guard + hook', mixed.status, 'design-step-required') || eq('hits for guard + hook', JSON.stringify(mixed.oneWayDoorHits), JSON.stringify(['hook'])) || { ok: true }
})

// T77l (#77, consumer neutrality) — the one-way-door KINDS are per-project config too: a consumer config
// without `oneWayDoorKinds` (or with `[]`) gives Sam no kind question at all, and an announced
// `one-way-door: hook` (an application webhook, say) does not stop the run.
await testCase('T77l R3 consumer: no oneWayDoorKinds in config → no kind question for Sam, `one-way-door: hook` does not stop the run', async () => {
  for (const config of [CONFIG, { ...CONFIG, oneWayDoorKinds: [] }]) {
    const r = await run({
      mode: 'semi',
      config,
      simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: hook — new webhook handler\none-way-door: status — new order status' + T77_CK },
    })
    const err = eq('status', r.status, 'plan-ready') || eq('oneWayDoorHits', r.oneWayDoorHits, undefined)
    if (err) return err
    if ((r.trace || []).some(t => String(t).startsWith('one-way-door:'))) return { ok: false, msg: `one-way-door trace on a consumer run: ${JSON.stringify(r.trace)}` }
  }
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T77l prompt checks: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  if (!src.split('\n').includes('const SAM_ONE_WAY_DOOR = samOneWayDoorText(config.oneWayDoorKinds)')) {
    return { ok: false, msg: 'SAM_ONE_WAY_DOOR is not built from config.oneWayDoorKinds' }
  }
  const fns = t77Block()
  if (!fns) return { ok: false, msg: 'oneWayDoor:start/:end markers not found in pipeline source' }
  for (const raw of [undefined, null, [], ['bogus'], 'hook']) {
    const text = fns.samOneWayDoorText(raw)
    if (text !== '') return { ok: false, msg: `samOneWayDoorText(${JSON.stringify(raw)}) asks Sam about kinds: ${JSON.stringify(text)}` }
  }
  return { ok: true }
})

// T77m (#77) — this repo still declares the four kinds (its own `.claude/pipeline.config.json`): each one
// announced stops the run, and Sam is asked about all four.
await testCase('T77m R3 this repo: its oneWayDoorKinds declare status, agent, hook, seam and each stops the run', async () => {
  if (!SUITE_ARGS.repoConfig) {
    log('SKIP — T77m: SUITE_ARGS.repoConfig absent (suite not run via scripts/run-flow-suite.cjs from the repo root)')
    return { ok: true }
  }
  const kinds = SUITE_ARGS.repoConfig.oneWayDoorKinds
  const e0 = eq('repo oneWayDoorKinds', JSON.stringify(kinds), JSON.stringify(T77_KINDS))
  if (e0) return e0
  const config = { ...CONFIG, oneWayDoorKinds: kinds, oneWayDoorPaths: OWD_REPO_PATHS || [] }
  for (const kind of T77_KINDS) {
    const r = await run({
      mode: 'semi',
      config,
      simulate: { theo: T77_THEO, sam: 'GO', samPlan: `plan\none-way-door: ${kind} — new ${kind}` + T77_CK, samTargetFiles: ['workflows/deliver-pipeline.js'] },
    })
    const err = eq(`status for ${kind}`, r.status, 'design-step-required') || eq(`hits for ${kind}`, JSON.stringify(r.oneWayDoorHits), JSON.stringify([kind]))
    if (err) return err
  }
  const fns = t77Block()
  if (!fns) {
    log('SKIP — T77m prompt checks: oneWayDoor block not available (SUITE_ARGS.fpSource absent)')
    return { ok: true }
  }
  const text = fns.samOneWayDoorText(kinds)
  for (const kind of [...T77_KINDS, 'none']) {
    if (!text.includes(`\`one-way-door: ${kind}`)) return { ok: false, msg: `this repo's Sam is not asked to announce \`one-way-door: ${kind}\`: ${JSON.stringify(text)}` }
  }
  return { ok: true }
})

// T77o (#77) — a non-empty list declares exactly what is asked and what stops: a repo declaring only `hook`
// asks Sam about `hook` alone and is stopped by `one-way-door: hook`, never by `one-way-door: status`.
await testCase('T77o R3 subset: oneWayDoorKinds ["hook"] → only hook is asked and stops the run', async () => {
  const config = { ...CONFIG, oneWayDoorKinds: ['HOOK', 'bogus', 'hook', 7] }
  const runPlan = (line) => run({ mode: 'semi', config, simulate: { theo: T77_THEO, sam: 'GO', samPlan: `plan\n${line}` + T77_CK } })
  const rs = await runPlan('one-way-door: status — new status')
  const e1 = eq('status for an undeclared kind', rs.status, 'plan-ready') || eq('hits for an undeclared kind', rs.oneWayDoorHits, undefined)
  if (e1) return e1
  const rh = await runPlan('one-way-door: hook — new hook')
  const e2 = eq('status for the declared kind', rh.status, 'design-step-required') || eq('hits for the declared kind', JSON.stringify(rh.oneWayDoorHits), JSON.stringify(['hook']))
  if (e2) return e2
  const fns = t77Block()
  if (!fns) {
    log('SKIP — T77o prompt checks: oneWayDoor block not available (SUITE_ARGS.fpSource absent)')
    return { ok: true }
  }
  const e3 = eq('normalized kinds', JSON.stringify(fns.oneWayDoorKindsOf(config.oneWayDoorKinds)), JSON.stringify(['hook']))
  if (e3) return e3
  const text = fns.samOneWayDoorText(config.oneWayDoorKinds)
  if (!text.includes('`one-way-door: hook — <what>`') || !text.includes('`one-way-door: none`')) return { ok: false, msg: `hook question missing: ${JSON.stringify(text)}` }
  for (const other of ['status', 'agent', 'seam']) {
    if (text.includes(`one-way-door: ${other}`)) return { ok: false, msg: `undeclared kind ${other} asked: ${JSON.stringify(text)}` }
  }
  return { ok: true }
})

// T77n (#77) — the repo's stated product direction is advisory for Morgan: her line (both review prompts)
// signals a conflict, never blocks on it, and keeps blocking to the acceptance checklist and the CI; Sam's
// names the direction or principle a plan trades off, only if the project instructions state one.
// Source-anchored: the engine reads no file in simulate mode.
await testCase('T77n product direction is advisory for Morgan (signalled, never blocking); Sam names the principle traded off', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T77n: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const lines = src.split('\n')
  const morgan = lines.find(l => l.startsWith('const MORGAN_PRODUCT_DIRECTION = ')) || ''
  const sam = lines.find(l => l.startsWith('const SAM_PRODUCT_DIRECTION = ')) || ''
  if (!morgan || !sam) return { ok: false, msg: 'MORGAN_PRODUCT_DIRECTION or SAM_PRODUCT_DIRECTION missing' }
  for (const must of ["signal a conflict with the repo's stated product direction, never block on it",
    "block on the acceptance checklist, the CI, the repo's conventions rule and the regression guard", 'never in `items`']) {
    if (!morgan.includes(must)) return { ok: false, msg: `MORGAN_PRODUCT_DIRECTION lacks: ${must}` }
  }
  // No sentence ties the product direction to a blocking verdict.
  for (const sentence of morgan.split('. ')) {
    for (const blocking of ['FAIL', 'REQUIRED_CHANGES', 'REGRESSION_DETECTED']) {
      if (sentence.includes(blocking)) return { ok: false, msg: `MORGAN_PRODUCT_DIRECTION ties the direction to ${blocking}: ${sentence.slice(0, 160)}` }
    }
  }
  const morganUses = src.split('`${MORGAN_PRODUCT_DIRECTION}`').length - 1
  if (morganUses !== 2) return { ok: false, msg: `MORGAN_PRODUCT_DIRECTION used in ${morganUses} review prompt(s), expected 2 (first review + re-review)` }
  if (!sam.includes('if your project instructions state a product direction or principles, name the one your plan trades off')) {
    return { ok: false, msg: 'SAM_PRODUCT_DIRECTION does not ask Sam, conditionally, to name the principle a plan trades off' }
  }
  const samUses = src.split('${SAM_PRODUCT_DIRECTION}').length - 1
  if (samUses !== 1) return { ok: false, msg: `SAM_PRODUCT_DIRECTION used ${samUses} time(s), expected 1 (the scout prompt)` }
  return { ok: true }
})

// T77g (#77, consumer neutrality) — a product direction is the TARGET repo's own, stated in its own
// instructions, or absent. A run on a repo that states none behaves as it did before: the two
// product-direction lines are conditional or advisory, carry no rule text of this repo, and require no read.
// Source-anchored: the engine reads no file in simulate mode.
await testCase('T77g consumer neutrality: a repo stating no product direction → same run; the product-direction lines name no rule of this repo', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  if (e1) return e1
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T77g source checks: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const lines = src.split('\n')
  for (const name of ['SAM_PRODUCT_DIRECTION', 'MORGAN_PRODUCT_DIRECTION']) {
    const line = lines.find(l => l.startsWith(`const ${name} = `)) || ''
    if (!line) return { ok: false, msg: `workflow source lacks const ${name}` }
    for (const banned of ['callAgent', 'simulate', 'DEBT', 'R1', 'R2', 'R3', 'ratchet', 'lgtmgate', 'critical-paths', 'codemap', 'one-way',
      'Never list', 'exception:', '.md', 'Read ', 'repo root']) {
      if (line.includes(banned)) return { ok: false, msg: `${name} injects rule text of this repo or a required read (${banned}) into a consumer prompt` }
    }
  }
  // The one-way-door announcement Sam gets is built from the repo's declared kinds only: with the four kinds
  // it names exactly them and `none` (no arbitrary <kind>), and it carries no rule text of this repo.
  if (!lines.includes('const SAM_ONE_WAY_DOOR = samOneWayDoorText(config.oneWayDoorKinds)')) return { ok: false, msg: 'SAM_ONE_WAY_DOOR is not built from config.oneWayDoorKinds' }
  const fns = t77Block()
  if (!fns) return { ok: false, msg: 'oneWayDoor:start/:end markers not found in pipeline source' }
  const owd = fns.samOneWayDoorText(T77_KINDS)
  for (const kind of [...T77_KINDS, 'none']) {
    if (!owd.includes(`\`one-way-door: ${kind}`)) return { ok: false, msg: `samOneWayDoorText(four kinds) does not announce \`one-way-door: ${kind}\`` }
  }
  if (owd.includes('<kind>')) return { ok: false, msg: 'samOneWayDoorText names an arbitrary <kind>: only declared kinds and none are parsed' }
  for (const banned of ['callAgent', 'simulate', 'DEBT', 'R1', 'R2', 'R3', 'ratchet', 'lgtmgate', 'critical-paths', 'codemap', 'ARCHITECTURE.md', 'VISION.md']) {
    if (owd.includes(banned)) return { ok: false, msg: `samOneWayDoorText injects rule text of this repo (${banned}) into a prompt` }
  }
  return { ok: true }
})

// T77p (#77, consumer neutrality) — the engine imposes no file name on a consumer: agents receive each
// repo's own instructions natively, so no prompt of the engine names VISION.md, ARCHITECTURE.md or
// AGENTS.md. Every prompt is built from the engine source, so the source naming none of them (comments
// included) proves it; the prompt previews of a full run and of a plan-gate run are checked too.
await testCase('T77p consumer neutrality: no engine prompt names VISION.md, ARCHITECTURE.md or AGENTS.md', async () => {
  const names = ['VISION.md', 'ARCHITECTURE.md', 'AGENTS.md']
  const runs = [
    await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } }),
    await run({ mode: 'semi', config: T77_KCONFIG, simulate: { theo: T77_THEO, sam: 'GO', samPlan: 'plan\none-way-door: none' + T77_CK } }),
  ]
  const e1 = eq('full run status', runs[0].status, 'ready') || eq('plan-gate run status', runs[1].status, 'plan-ready')
  if (e1) return e1
  if (!String(runs[0].nickPromptPreview || '')) return { ok: false, msg: 'nickPromptPreview empty on the full run' }
  for (const r of runs) {
    const out = JSON.stringify(r)
    const hit = names.find(n => out.includes(n))
    if (hit) return { ok: false, msg: `run result (prompt previews included) names ${hit}` }
  }
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T77p source checks: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  for (const n of names) {
    const line = src.split('\n').find(l => l.includes(n))
    if (line !== undefined) return { ok: false, msg: `engine source names ${n}: ${line.trim().slice(0, 120)}` }
  }
  return { ok: true }
})

// T163 (#163, consumer neutrality) — the engine's own rules (Sam's layer rule naming the simulate seams and the
// status/agent/hook/seam question, Nick's R2 item naming fixtures/incidents) reach a run only when the target
// repo's own config says it IS this plugin: `engineRepo: true`. Any other value or absence is a consumer.
const T163_ENGINE_WORDS = ['simulate', 'seam', 'agent()', 'fixtures/incidents']
// isEngineRepo / samLayerRule, extracted from the engine's pure `engineRules` block (null when the suite does
// not get the pipeline source). Sam's prompt is not observable in simulate mode, so the Sam-side cases are
// source-anchored, as T77g, T77l, T77n and T77p are.
const t163Block = () => {
  const src = SUITE_ARGS.fpSource
  if (!src) return null
  const block = extractBetween(src, '// --- engineRules:start ---', '// --- engineRules:end ---')
  // eslint-disable-next-line no-new-func
  return block ? new Function(block + '\nreturn { isEngineRepo, samLayerRule }')() : null
}
await testCase('T163a consumer Sam prompt: no engineRepo flag -> neutral PLAN RULE, none of simulate, seam, agent(), fixtures/incidents', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T163a: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const lines = src.split('\n')
  if (!lines.includes('const SAM_LAYER_RULE = samLayerRule(config)')) return { ok: false, msg: 'SAM_LAYER_RULE is not built from samLayerRule(config)' }
  const fns = t163Block()
  if (!fns) return { ok: false, msg: 'engineRules:start/:end markers not found in pipeline source' }
  // Fail closed: only the boolean true marks the engine; every other config shape gets the neutral rule.
  const banned = [...T163_ENGINE_WORDS, 'LAYER RULE']
  for (const cfg of [CONFIG, {}, { ...CONFIG, engineRepo: false }, { ...CONFIG, engineRepo: 'true' }, { ...CONFIG, engineRepo: 1 }, null, undefined]) {
    const text = fns.samLayerRule(cfg)
    if (!text.includes('PLAN RULE:') || !text.includes('patch-avoided:')) return { ok: false, msg: `neutral rule lacks PLAN RULE / patch-avoided: for ${JSON.stringify(cfg && cfg.engineRepo)}: ${JSON.stringify(text)}` }
    const hit = banned.find(w => text.includes(w))
    if (hit) return { ok: false, msg: `consumer Sam rule carries engine vocabulary (${hit}) for ${JSON.stringify(cfg && cfg.engineRepo)}: ${JSON.stringify(text)}` }
  }
  // The rest of the static Sam prompt: the scout prompt body (whole-line comments dropped) and the two
  // constants it interpolates besides the layer rule and the per-project one-way-door text.
  const promptBody = extractBetween(src, 'const samScoutPrompt = (', '// Plan phase')
  if (!promptBody) return { ok: false, msg: 'samScoutPrompt body not found in pipeline source' }
  const staticSam = [
    promptBody.split('\n').filter(l => !l.trim().startsWith('//')).join('\n'),
    lines.find(l => l.startsWith('const SAM_PRODUCT_DIRECTION = ')) || '',
    lines.find(l => l.startsWith('const ACCEPTANCE_PROOF_RULE = ')) || '',
  ]
  if (staticSam.some(s => s === '')) return { ok: false, msg: 'SAM_PRODUCT_DIRECTION or ACCEPTANCE_PROOF_RULE missing' }
  for (const part of staticSam) {
    const hit = T163_ENGINE_WORDS.find(w => part.includes(w))
    if (hit) return { ok: false, msg: `static Sam prompt carries engine vocabulary (${hit}): ${part.slice(0, 120)}` }
  }
  return { ok: true }
})

await testCase('T163b consumer Nick prompt: bug + workflows/ target on a consumer config -> no R2 item, no run-offline', async () => {
  const r = await r2Run('bug', ['workflows/checkout.ts'], CONFIG)
  const p = String(r.nickPromptPreview || '')
  if (p === '') return { ok: false, msg: 'nickPromptPreview empty on the consumer run' }
  const err = r2Absent(p)
  if (err) return err
  return p.includes('run-offline') ? { ok: false, msg: 'nickPromptPreview: unexpected "run-offline"' } : { ok: true }
})

await testCase('T163c this repo: engineRepo is true -> Sam keeps the engine layer rule and Nick keeps the R2 item', async () => {
  if (!SUITE_ARGS.repoConfig) {
    log('SKIP — T163c: SUITE_ARGS.repoConfig absent (suite not run via scripts/run-flow-suite.cjs from the repo root)')
    return { ok: true }
  }
  const flag = SUITE_ARGS.repoConfig.engineRepo
  const e0 = eq('repo engineRepo', flag, true)
  if (e0) return e0
  const r = await r2Run('bug', ['workflows/deliver-pipeline.js'], { ...CONFIG, engineRepo: flag })
  const p = String(r.nickPromptPreview || '')
  for (const must of ['fixture `fixtures/incidents/', 'no-fixture', 'Refs #']) {
    if (!p.includes(must)) return { ok: false, msg: `this repo's Nick prompt lacks the R2 text ${JSON.stringify(must)}` }
  }
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T163c Sam checks: SUITE_ARGS.fpSource absent')
    return { ok: true }
  }
  const fns = t163Block()
  if (!fns) return { ok: false, msg: 'engineRules:start/:end markers not found in pipeline source' }
  const text = fns.samLayerRule(SUITE_ARGS.repoConfig)
  for (const must of ['LAYER RULE:', '`simulate.*` seam', 'an `agent()`', 'a hook or a seam', 'patch-avoided:']) {
    if (!text.includes(must)) return { ok: false, msg: `this repo's Sam layer rule lacks ${JSON.stringify(must)}: ${JSON.stringify(text)}` }
  }
  const uses = src.split('${SAM_LAYER_RULE}').length - 1
  return uses === 1 ? { ok: true } : { ok: false, msg: `SAM_LAYER_RULE interpolated ${uses} time(s) in the Sam prompt, expected 1` }
})

// T98a (#103, advisory default) — a plan target moved upstream → note+trace+return fields carry
// it, no routing change (status stays 'ready').
await testCase('T98a plan-stale advisory → trace + planStaleFiles + planTargetsChecked, status unaffected', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      samTargetFiles: ['workflows/deliver-pipeline.js', 'agents/nick.md'],
      planStaleFiles: ['workflows/deliver-pipeline.js'],
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'plan-stale:1')
  const e3 = eq('planStaleFiles', r.planStaleFiles, ['workflows/deliver-pipeline.js'])
  const e4 = eq('planTargetsChecked', r.planTargetsChecked, 2)
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T98b (#103, negative control) — no targetFiles declared → probe never runs, off-path unchanged.
await testCase('T98b no targetFiles → probe skipped, no plan-stale trace, planTargetsChecked:0', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.some(t => String(t).startsWith('plan-stale:'))
    ? { ok: false, msg: `trace: expected no plan-stale entry, got ${JSON.stringify(r.trace)}` }
    : null
  const e3 = eq('planTargetsChecked', r.planTargetsChecked, 0)
  const e4 = eq('planStaleFiles', r.planStaleFiles, null)
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T98c (#103, gate + sanitization) — planFreshness:'gate' escalates BEFORE Nick is spawned, and
// the shell-metacharacter target is dropped by safePlanTargets (planTargetsChecked counts only
// the sanitized entry).
await testCase('T98c plan-stale gate → escalate/plan-stale before Nick, unsafe target sanitized', async () => {
  const r = await run({
    mode: 'auto',
    planFreshness: 'gate',
    simulate: {
      sam: 'GO',
      samTargetFiles: ['workflows/deliver-pipeline.js', '; rm -rf / #'],
      planStaleFiles: ['workflows/deliver-pipeline.js'],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-stale')
  const e3 = eq('staleFiles', r.staleFiles, ['workflows/deliver-pipeline.js'])
  const e4 = eq('planTargetsChecked', r.planTargetsChecked, 1)
  const e5 = r.pr !== undefined
    ? { ok: false, msg: `pr: expected undefined (Nick never spawned), got ${JSON.stringify(r.pr)}` }
    : null
  const err = e1 || e2 || e3 || e4 || e5
  return err ? err : { ok: true }
})

// T99 (real incident) — a worktree whose frozen base was ALREADY
// behind origin/<baseBranch> at fresh dispatch escalates before Diagnose/Sam spend a single
// token: distinct from T98a-c (planFreshnessNote/plan-stale, which needs Sam's declared
// targetFiles and only checks AFTER a full plan round). Zero real agent calls beyond the cheap
// haiku freshness probe simulated here — Sam ('GO') and Morgan are never reached.
await testCase('T99 provision-stale (fresh dispatch, worktree behind at creation) → escalate before Diagnose', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { provisionBehindCount: 3, sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'provision-stale')
  const e3 = eq('behind', r.behind, 3)
  const e4 = eq('trace', r.trace, ['provision-stale:3', 'Blocked'])
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T100 (negative control, T99's sibling) — a RESUME (entryStage:'review') is never subject to
// the fresh-dispatch preflight, even with the same simulated behind-count: the frozen base is
// deliberately not reconciled mid-session (worktreeFreshnessNote's job, not this gate's).
await testCase('T100 provision-stale probe skipped on resume (entryStage:review) → proceeds to ready', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 42,
    simulate: { provisionBehindCount: 3, morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.includes('provision-stale:3')
    ? { ok: false, msg: `trace: expected no provision-stale entry on a resume, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T101 (lgtmgate#161) — no `models` arg, no `config.models` → dryRun exposes the new
// 'sonnet' default for all 3 overridable roles (scout/planAudit/morgan). Theo/Nick are not part
// of this resolution (out of scope, unconditional literals), so they are not asserted here.
await testCase('T101 models default (no models arg, no config.models) → dryRun exposes sonnet for all 3 roles', async () => {
  const r = await run({ dryRun: true, mode: 'manual' })
  const err = eq('models', r.models, { scout: 'sonnet', planAudit: 'sonnet', morgan: 'sonnet' })
  return err ? err : { ok: true }
})

// T102 — an explicit `models.scout:'opus'` arg overrides just that role; the other two roles
// stay on the 'sonnet' default (no config.models set).
await testCase("T102 models.scout:'opus' arg → dryRun exposes the override, other roles stay sonnet", async () => {
  const r = await run({ dryRun: true, mode: 'manual', models: { scout: 'opus' } })
  const err = eq('models', r.models, { scout: 'opus', planAudit: 'sonnet', morgan: 'sonnet' })
  return err ? err : { ok: true }
})

// T103 (same `??` idiom as T57's planAudit precedent) — arg wins over config.models per role;
// config.models alone still takes effect on a role the arg does not set; a role neither arg nor
// config sets falls through to the 'sonnet' default.
await testCase('T103 models arg wins over config.models (per-role, same ?? idiom as T57)', async () => {
  const r = await run({
    dryRun: true,
    mode: 'manual',
    models: { scout: 'opus' },
    config: { ...CONFIG, models: { scout: 'haiku', morgan: 'haiku' } },
  })
  const err = eq('models', r.models, { scout: 'opus', planAudit: 'sonnet', morgan: 'haiku' })
  return err ? err : { ok: true }
})

// T104 (#162, absorbs #91/#119, positive) — Morgan returns LGTM but the live mergeability recheck
// reports CONFLICTING (a sibling PR merged mid-flight, or a resumed round reasoning off stale
// state): escalate instead of a false-positive `ready`, using the file's existing
// status:'escalate'/reason:'<slug>' vocabulary.
await testCase('T104 mergeable CONFLICTING at LGTM handoff → escalate, not ready', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      mergeState: { mergeable: 'CONFLICTING', mergeStateStatus: 'DIRTY' },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'mergeable-conflicting')
  const e3 = includes('trace', r.trace, 'mergeable-conflicting:DIRTY')
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T105 (#162, negative control, mirrors T50) — no mergeState fixture declared → the recheck is a
// no-op (fail-open), LGTM still hands off as 'ready' unchanged, no mergeable-conflicting trace entry.
await testCase('T105 no mergeState fixture → ready unchanged, no mergeable-conflicting trace', async () => {
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.some(t => String(t).startsWith('mergeable-conflicting:'))
    ? { ok: false, msg: `trace: expected no mergeable-conflicting entry, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

// provisionCmdPreview (claude-agent-pipeline#72) — same simulate-only seam as
// preflightPromptPreview (T70a-d above): asserts the composed provisioning command carries
// PROVISION_ENV_SYMLINK through to scripts/provision_worktree.sh per preflight.envSymlink
// value, and that the `bash "$SCRIPT"` invocation itself is preserved around it. Numbered
// T104a-d.
await testCase('T104a provisionCmdPreview: envSymlink default (unset) -> PROVISION_ENV_SYMLINK="required"', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('provisionCmdPreview', r.provisionCmdPreview, 'PROVISION_ENV_SYMLINK="required" bash "$SCRIPT"')
  return err ? err : { ok: true }
})

await testCase('T104b provisionCmdPreview: envSymlink forbidden -> PROVISION_ENV_SYMLINK="forbidden"', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, preflight: { envSymlink: 'forbidden' } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('provisionCmdPreview', r.provisionCmdPreview, 'PROVISION_ENV_SYMLINK="forbidden" bash "$SCRIPT"')
  return err ? err : { ok: true }
})

await testCase('T104c provisionCmdPreview: envSymlink ignore -> PROVISION_ENV_SYMLINK="ignore"', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, preflight: { envSymlink: 'ignore' } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('provisionCmdPreview', r.provisionCmdPreview, 'PROVISION_ENV_SYMLINK="ignore" bash "$SCRIPT"')
  return err ? err : { ok: true }
})

await testCase('T104d provisionCmdPreview: SCRIPT invocation + extraLinks args preserved around the env-symlink prefix', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, provision: { extraLinks: [{ src: '.venv', dst: '.venv' }] } },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.provisionCmdPreview
  const e1 = includes('provisionCmdPreview', p, 'SCRIPT="/tmp/lgtmgate-test/scripts/provision_worktree.sh"')
  const e2 = includes('provisionCmdPreview', p,
    'if [ -f "$SCRIPT" ]; then PROVISION_ENV_SYMLINK="required" bash "$SCRIPT" "/tmp/lgtmgate-test" ".venv" ".venv"; else')
  const e3 = includes('provisionCmdPreview', p, '; fi')
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// ---------------------------------------------------------------------------
// #97 — no-op gate widened to SHA+body; review-loop plan/code blocker routing
// (T23b lives next to T23 above; T109-T115 below)
// ---------------------------------------------------------------------------

// T270 (#107, #183) — every Morgan blocker is a checklist box (structured itemOwner 'checklist-wording-defect' with
// proof, matched by the box's id) and plan amendment is off (default): park as verified-untickable, never a Nick round.
await testCase('T270 all blockers checklist-wording-defect (amend off) → verified-untickable, zero Nick round', async () => {
  const items = [{ text: '`grep -c FOO file` prints exactly 1', humanGate: false }]
  const line = t182Lines(items)[0]
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(items) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [line], itemOwners: [{ item: line, itemOwner: 'checklist-wording-defect', proof: '$ grep -c FOO file\n2' }] }],
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('untickableItems', r.untickableItems, [{ id: 1, item: line, proof: '$ grep -c FOO file\n2' }])
  return e1 || e2 || nickTrace(r) || { ok: true }
})

// T271 (#132) — a failed required check reaches Nick's preflight-fix prompt with the failing step name
// and the last 40 log lines (the 50-line tail is capped, the first lines are dropped).
await testCase('T271 failed required check → Nick preflight-fix prompt carries failing step name and log lines', async () => {
  const lines = []
  for (let i = 1; i <= 49; i++) lines.push(`log-line-${i}`)
  lines.push("KeyError: 'merge-state-42-0'")
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      preflight: [
        {
          pass: false,
          issues: ["PR #999 required check 'guards' is in FAILURE state on GitHub"],
          failedChecks: [{ name: 'guards', step: 'Run scripts/test-run-offline.sh', logTail: lines.join('\n') }],
        },
        { pass: true, issues: [] },
      ],
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const p = String(r.preflightFixPromptPreview || '')
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('step name', p, 'Run scripts/test-run-offline.sh')
  const e3 = includes('log line', p, "KeyError: 'merge-state-42-0'")
  const e4 = p.includes('log-line-1\n') ? { ok: false, msg: 'first line of the 50 must be dropped by the 40-line cap' } : null
  const e5 = includes('kept tail start', p, 'log-line-11\n')
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

// T109 — Morgan classifies a REQUIRED_CHANGES item as a checklist-wording-defect with a concrete
// proof; maxPlanAmendRounds:1 routes it to Sam for ONE amendment round instead of Nick. Every
// item was plan-routed (codeItems empty) so Nick is skipped entirely that round. Round 1 Morgan
// re-review (against the amended plan/checklist) returns LGTM.
await testCase('T109 plan-amend round (checklist-wording-defect, all items routed) → Sam amends, Nick skipped, ready', async () => {
  const r = await run({
    mode: 'auto',
    maxPlanAmendRounds: 1,
    simulate: {
      sam: 'GO',
      morgan: [
        {
          verdict: 'REQUIRED_CHANGES',
          items: ['Acceptance box: grep prints exactly 1 hit for FOO'],
          itemOwners: [{
            item: 'Acceptance box: grep prints exactly 1 hit for FOO',
            itemOwner: 'checklist-wording-defect',
            proof: 'grep returns 2 hits, item asserts 1',
          }],
        },
        { verdict: 'LGTM' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'plan-amend-round:1')
  const e3 = includes('trace', r.trace, 'nick-skipped-plan-only:1')
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T110 — neutral default: Morgan returns REQUIRED_CHANGES with no `itemOwners` at all. classifyBlockers
// degrades to the historical all-code-defect path byte-for-bit: no plan-route-shadow, no
// plan-amend-round trace, Nick fixes everything as before #97.
await testCase('T110 no itemOwners (neutral default) → ready, no plan-route/plan-amend trace', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['fix the null guard'] }, { verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const bad = (r.trace || []).find(t => /^plan-amend-round|^plan-route-shadow/.test(String(t)))
  const e2 = bad ? { ok: false, msg: `trace: unexpected routing entry ${JSON.stringify(bad)}` } : null
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T111 — budget exhausted: maxPlanAmendRounds:1, and the FRESH verdict after the one allowed
// amendment round still classifies the same item as a plan defect → plan-defect-persists,
// named as a plan defect rather than mislabelled no-progress.
await testCase('T111 plan-defect persists through the amendment round → escalate plan-defect-persists', async () => {
  const r = await run({
    mode: 'auto',
    maxPlanAmendRounds: 1,
    simulate: {
      sam: 'GO',
      morgan: [
        {
          verdict: 'REQUIRED_CHANGES',
          items: ['Acceptance box: names the output contract'],
          itemOwners: [{ item: 'Acceptance box: names the output contract', itemOwner: 'plan-defect', proof: 'the plan step never names an output contract' }],
        },
        {
          verdict: 'REQUIRED_CHANGES',
          items: ['Acceptance box: names the output contract'],
          itemOwners: [{ item: 'Acceptance box: names the output contract', itemOwner: 'plan-defect', proof: 'the amended plan step still never names one' }],
        },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'plan-defect-persists')
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T112 — shadow mode: maxPlanAmendRounds OMITTED (shipped default 0) with a fully-formed
// plan-defect classification. classifyBlockers still runs and traces plan-route-shadow, but
// routes NOTHING — Nick still receives every item, exactly like the pre-#97 flow.
await testCase('T112 shadow mode (maxPlanAmendRounds default 0) → classifies but routes nothing, ready', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        {
          verdict: 'REQUIRED_CHANGES',
          items: ['Acceptance box: names the output contract'],
          itemOwners: [{ item: 'Acceptance box: names the output contract', itemOwner: 'plan-defect', proof: 'the plan step never names an output contract' }],
        },
        { verdict: 'LGTM' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('trace', r.trace, 'plan-route-shadow:1')
  const bad = (r.trace || []).find(t => /^plan-amend-round/.test(String(t)))
  const e3 = bad ? { ok: false, msg: `trace: unexpected plan-amend-round entry ${JSON.stringify(bad)}` } : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T113 — simulate.acceptanceSpliceProbe drives the REAL spliceAcceptanceBlock (no hand-duplicated
// copy in this test file): (a) markers absent from the body → null, never appends; (b) a fenced,
// non-indented EXAMPLE marker pair earlier in the body is left untouched — only the LAST
// (real) marker pair is replaced.
await testCase('T113 acceptanceSpliceProbe (real function) — markers absent → null; fenced example before real pair → only last pair replaced', async () => {
  const r1 = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      acceptanceSpliceProbe: { body: 'No acceptance markers anywhere in this body.', checklist: '- [ ] a' },
    },
  })
  const e1 = eq('acceptanceSpliceProbe (markers absent)', r1.acceptanceSpliceProbe, null)

  const fencedExampleBody =
    'Some doc text explaining the format.\n' +
    '```\n' +
    '<!-- acceptance:start -->\n' +
    '- [ ] EXAMPLE fenced item — never touch this one\n' +
    '<!-- acceptance:end -->\n' +
    '```\n' +
    'More prose.\n' +
    '<!-- acceptance:start -->\n' +
    '- [ ] real item one\n' +
    '<!-- acceptance:end -->\n' +
    'Trailer text.'
  const r2 = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'LGTM' }],
      acceptanceSpliceProbe: { body: fencedExampleBody, checklist: '- [ ] amended item' },
    },
  })
  const out = String(r2.acceptanceSpliceProbe ?? '')
  const keptFencedExample = out.includes('EXAMPLE fenced item — never touch this one')
  const replacedRealOnly = out.includes('amended item') && !out.includes('real item one')
  const e2 = (!keptFencedExample || !replacedRealOnly)
    ? { ok: false, msg: `acceptanceSpliceProbe (fenced example before real pair) mis-spliced: ${JSON.stringify(out)}` }
    : null
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T114 — a plan owner with an EMPTY proof is fail-safe: classifyBlockers falls back to
// code-defect, so no plan-amend/plan-route-shadow trace fires regardless of maxPlanAmendRounds.
await testCase('T114 plan owner with empty proof → falls back to code-defect (no plan-amend/shadow trace)', async () => {
  const r = await run({
    mode: 'auto',
    maxPlanAmendRounds: 1,
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['fix the null guard'], itemOwners: [{ item: 'fix the null guard', itemOwner: 'plan-defect', proof: '' }] },
        { verdict: 'LGTM' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const bad = (r.trace || []).find(t => /^plan-amend-round|^plan-route-shadow/.test(String(t)))
  const e2 = bad ? { ok: false, msg: `trace: unexpected routing entry ${JSON.stringify(bad)}` } : null
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T115 — maxPlanAmendRounds validation mirrors T70d's pattern: an invalid value throws under
// dryRun (zero agent spawns), message names the arg.
await testCase('T115 maxPlanAmendRounds:-1 → throws under dryRun (zero agent spawns)', async () => {
  try {
    await run({
      mode: 'manual',
      dryRun: true,
      maxPlanAmendRounds: -1,
    })
    return { ok: false, msg: 'expected run() to throw, it did not' }
  } catch (e) {
    if (!e.message.includes('maxPlanAmendRounds')) {
      return { ok: false, msg: `wrong error message: ${e.message}` }
    }
    return { ok: true }
  }
})

// T116 (#193) — an open GitHub-native sub-issue NOT covered by this run's own samAbsorbedIssues
// bundle blocks the epic's own Closes# — the PR's first line must use a non-closing reference
// instead, and the gate note must be present.
await testCase('T116 uncovered open sub-issue → non-closing "(see #N)" reference, no Closes #N', async () => {
  const r = await run({
    issue: 162,
    mode: 'auto',
    simulate: { sam: 'GO', openSubIssues: ['91'], morgan: [{ verdict: 'LGTM' }] },
  })
  const p = r.nickPromptPreview
  const e1 = includes('nickPromptPreview', p, '`(see #162)`')
  const e2 = includes('nickPromptPreview', p, 'lgtmgate#193')
  // Negative assertion targets the backtick-quoted composed first-line literal specifically
  // (`` `Closes #162` ``) — the gate note itself legitimately double-quotes "Closes #162" as
  // prose explaining what it intentionally avoided, so a bare substring check would false-fail.
  const e3 = p.includes('`Closes #162`')
    ? { ok: false, msg: `expected nickPromptPreview NOT to include the composed literal "\`Closes #162\`" (uncovered sub-issue), got ${JSON.stringify(p)}` }
    : null
  const e4 = eq('subIssuesUncovered', r.subIssuesUncovered, ['91'])
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T117 (#193, negative control) — zero open sub-issues (the common case): the Closes# line stays
// byte-identical to before this change.
await testCase('T117 zero open sub-issues → Closes #N unchanged (common-case byte-identical)', async () => {
  const r = await run({
    issue: 162,
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('nickPromptPreview', r.nickPromptPreview, 'Closes #162')
  return err ? err : { ok: true }
})

// T118 (#193) — the one open sub-issue IS already in this run's own samAbsorbedIssues bundle, so
// it is NOT "uncovered" and the epic's own Closes# is not blocked.
await testCase('T118 open sub-issue already covered by samAbsorbedIssues → Closes #N not blocked', async () => {
  const r = await run({
    issue: 162,
    mode: 'auto',
    simulate: { sam: 'GO', samAbsorbedIssues: ['91'], openSubIssues: ['91'], morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('nickPromptPreview', r.nickPromptPreview, 'Closes #162')
  return err ? err : { ok: true }
})

// T122 — Morgan review fix (PR #121): off-path regression where an empty/absent `items` (MORGAN.items
// is optional; REQUIRED_CHANGES has never required items) silently skipped Nick because
// `dispatchNick` was gated on `nickItems.length > 0` even when nothing was plan-routed
// (`planRouted === false`). Exact repro fixture from the review comment: no `itemOwners` at all
// (fully off-path), Morgan round 1 returns REQUIRED_CHANGES with no `items`, headSha frozen across
// rounds → Nick MUST still be dispatched, run the no-op gate, and escalate nick-no-op — never reach
// `ready` via a silent `nick-skipped-plan-only` skip.
await testCase('T122 off-path empty items (no itemOwners) → Nick still dispatched, no-op gate fires, escalate nick-no-op', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      headSha: { 1: 'sha-frozen', 2: 'sha-frozen' },
      morgan: [{ verdict: 'REQUIRED_CHANGES' }, { verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'nick-no-op')
  const bad = (r.trace || []).find(t => /^nick-skipped-plan-only/.test(String(t)))
  const e3 = bad ? { ok: false, msg: `trace: unexpected skip entry ${JSON.stringify(bad)} — Nick must be dispatched off-path` } : null
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// ---------------------------------------------------------------------------
// #27 / #45 — preflight prompt hint interpolation + branch-conformance guard on resume
// ---------------------------------------------------------------------------

// T106 (#45) — the branch-conformance guard now also runs on an entryStage:'review' resume: a
// conforming branch must NOT escalate, matching the fresh-dispatch behaviour Dev already had.
await testCase('T106 branch-conformance guard also runs on entryStage:review resume, conforming branch → no escalate', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    simulate: { branchCheckRaw: 'features/issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = eq('status', r.status, 'ready')
  return err ? err : { ok: true }
})

// T107 (#45) — the guard fires on an entryStage:'review' resume with a mismatched branch too —
// this is the defect this issue fixes (a resumed run previously skipped the guard entirely, since
// the Dev block that owned it never runs when entryStage:'review'). morgan fixture present but
// must be unreached — same negative-control idiom as T58.
await testCase('T107 branch-conformance guard fires on entryStage:review resume with a mismatched branch → escalate, Review never completes', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    simulate: { branchCheckRaw: 'feat-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'branch-mismatch')
  const e3 = eq('actualBranch', r.actualBranch, 'feat-issue-1')
  const e4 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T232a (#232) — branchOverride is used verbatim as the expected branch.
await testCase('T232a branchOverride set → expectedBranch equals the override (not <prefix>issue-N)', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    branchOverride: 'feat/issue-216-v2',
    simulate: { branchCheckRaw: 'feat-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('expectedBranch', r.expectedBranch, 'feat/issue-216-v2')
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T232b (#232) — unset / whitespace-only override leaves the default untouched.
await testCase('T232b branchOverride unset or blank → expectedBranch unchanged (features/issue-1)', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    branchOverride: '   ',
    simulate: { branchCheckRaw: 'feat-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T232c (#232) — review resume on an override branch is accepted; negative control: with the
// override set, a config-prefix branch is NOT rescued by the stale-prefix reconcile.
await testCase('T232c branchOverride + matching PR head on review resume → ready; config-prefix head still escalates', async () => {
  const ok = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    branchOverride: 'feat/issue-216-v2',
    simulate: { branchCheckRaw: 'feat/issue-216-v2', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('status', ok.status, 'ready')
  const neg = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    branchOverride: 'feat/issue-216-v2',
    simulate: { branchCheckRaw: 'features/issue-1', configBranchPrefixRaw: 'features/', morgan: [{ verdict: 'LGTM' }] },
  })
  const e2 = eq('neg.status', neg.status, 'escalate')
  const e3 = eq('neg.reason', neg.reason, 'branch-mismatch')
  const bad = (neg.trace || []).includes('branch-check-reconciled')
  const e4 = bad ? { ok: false, msg: 'reconcile must be skipped when branchOverride is set' } : null
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T232d (#232) — a top-level branchPrefix arg that differs from config is ignored, loudly.
await testCase('T232d top-level branchPrefix arg differing from config → trace branch-prefix-arg-ignored, expectedBranch unchanged', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    branchPrefix: 'feat/',
    simulate: { branchCheckRaw: 'feat-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const e2 = (r.trace || []).includes('branch-prefix-arg-ignored') ? null : { ok: false, msg: `trace missing branch-prefix-arg-ignored: ${JSON.stringify(r.trace)}` }
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T232e (#232) — an override with shell-unsafe characters throws (it is interpolated into Nick's prompt).
await testCase('T232e branchOverride with unsafe characters → throws', async () => {
  try {
    await run({ mode: 'auto', dryRun: false, branchOverride: 'feat/x; rm -rf /', simulate: { sam: 'GO' } })
    return { ok: false, msg: 'expected run() to throw, it did not' }
  } catch (e) {
    return e.message.includes('Invalid branchOverride') ? { ok: true } : { ok: false, msg: `wrong error message: ${e.message}` }
  }
})

// T267a (#267) — config.branchPrefix absent → falls back to 'features/' AND traces the new
// branch-prefix-fallback-default token (previously silent).
await testCase('T267a config.branchPrefix absent → expectedBranch defaults, trace branch-prefix-fallback-default', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    config: { ...CONFIG, branchPrefix: undefined },
    simulate: { branchCheckRaw: 'nightly-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const e2 = (r.trace || []).includes('branch-prefix-fallback-default') ? null : { ok: false, msg: `trace missing branch-prefix-fallback-default: ${JSON.stringify(r.trace)}` }
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T267b (#267) — the real-world misuse pattern: branchPrefix passed top-level (not nested in
// config) while config itself has none. Both trace tokens fire together; the silent-drift
// symptom is doubly flagged, not fixed by itself (expectedBranch still defaults).
await testCase('T267b config.branchPrefix absent + top-level branchPrefix arg → both trace tokens fire', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    branchPrefix: 'feat/',
    config: { ...CONFIG, branchPrefix: undefined },
    simulate: { branchCheckRaw: 'nightly-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = eq('expectedBranch', r.expectedBranch, 'features/issue-1')
  const e2 = (r.trace || []).includes('branch-prefix-fallback-default') ? null : { ok: false, msg: `trace missing branch-prefix-fallback-default: ${JSON.stringify(r.trace)}` }
  const e3 = (r.trace || []).includes('branch-prefix-arg-ignored') ? null : { ok: false, msg: `trace missing branch-prefix-arg-ignored: ${JSON.stringify(r.trace)}` }
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
})

// T267c (#267, negative control) — config.branchPrefix genuinely set, even to a value matching
// the literal default string, must NOT trace branch-prefix-fallback-default.
await testCase('T267c config.branchPrefix genuinely set to "features/" → no fallback trace', async () => {
  const r = await run({
    mode: 'auto',
    entryStage: 'review',
    prNumber: 777,
    config: { ...CONFIG, branchPrefix: 'features/' },
    simulate: { branchCheckRaw: 'nightly-issue-1', morgan: [{ verdict: 'LGTM' }] },
  })
  const bad = (r.trace || []).includes('branch-prefix-fallback-default')
  return bad ? { ok: false, msg: `trace must not include branch-prefix-fallback-default when config.branchPrefix is set: ${JSON.stringify(r.trace)}` } : { ok: true }
})

// T108 (#27) — preflightPrompt()'s own "(see hint below)" sentence promised the SANDBOX_INSTALL_HINT
// text would follow; it never did (dette-by-omission since #54). Asserts the hint text is actually
// present in the composed prompt, not just referenced — SSLCertVerificationError is a substring
// unique to SANDBOX_INSTALL_HINT itself, so this fails if the interpolation is ever dropped again.
await testCase('T108 preflight prompt inlines the SANDBOX_INSTALL_HINT text its own "(see hint below)" sentence promises', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const e1 = includes('preflightPromptPreview', r.preflightPromptPreview, '(see hint below)')
  const e2 = includes('preflightPromptPreview', r.preflightPromptPreview, 'SSLCertVerificationError')
  const err = e1 || e2
  return err ? err : { ok: true }
})

// T263a (#263, real incident #262 companion) — a sandbox write-allowlist gap on the target
// repo's REAL .git/worktrees/<branch> internals (distinct from the worktree checkout path
// itself) is caught BEFORE Nick spawns, not discovered mid-stage.
await testCase('T263a (#263) worktree git-dir not writable → escalate before Nick spawn', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      gitDirWritable: { writable: false, gitDir: '/path/to/repo/.git/worktrees/issue-1' },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'worktree-git-dir-not-writable')
  const e3 = eq('gitDir', r.gitDir, '/path/to/repo/.git/worktrees/issue-1')
  const e4 = r.trace.includes('worktree-git-dir-not-writable:/path/to/repo/.git/worktrees/issue-1')
    ? null
    : { ok: false, msg: `trace: expected write-probe entry, got ${JSON.stringify(r.trace)}` }
  const e5 = r.pr !== undefined
    ? { ok: false, msg: `pr: expected undefined (Nick never spawned), got ${JSON.stringify(r.pr)}` }
    : null
  const err = e1 || e2 || e3 || e4 || e5
  return err ? err : { ok: true }
})

// T263b (#263, negative control) — a writable git-dir is a no-op: proceeds through Dev/Review
// to ready unchanged.
await testCase('T263b (#263) worktree git-dir writable → no escalate, proceeds to ready', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      gitDirWritable: { writable: true, gitDir: '/path/to/repo/.git/worktrees/issue-1' },
      morgan: [{ verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = r.trace.some(t => String(t).startsWith('worktree-git-dir-not-writable:'))
    ? { ok: false, msg: `trace: expected no write-probe escalate entry, got ${JSON.stringify(r.trace)}` }
    : null
  const err = e1 || e2
  return err ? err : { ok: true }
})

// ---------------------------------------------------------------------------
// Pure functions — worktreeFreshnessNote (extracted from workflows/deliver-pipeline.js)
// ---------------------------------------------------------------------------

// --- worktreeFreshnessNote:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Composes the reviewer-facing staleness warning for a shared worktree whose base is behind the
// remote base branch. Pure: no I/O, no closure over simulate/config/trace. Returns '' when
// the worktree is fresh or the count is unknown — so a fresh run's prompts are byte-identical.
function worktreeFreshnessNote(behind, baseBranch) {
  const n = Number(behind)
  if (!Number.isFinite(n) || n <= 0) return ''
  return (
    `WORKTREE FRESHNESS WARNING: this shared worktree's frozen base is ${n} commit${n === 1 ? '' : 's'} ` +
    `behind origin/${baseBranch}. Because of this: ` +
    `1) the local HEAD suite runs an older base while CI runs the merge ref, so a test-count / ` +
    `test-inventory difference between the local run and CI is expected by construction, not a ` +
    `regression; ` +
    `2) the regression baseline is captured from a freshly fetched origin/${baseBranch} overlay, so a ` +
    `test name present in the baseline log but absent from the HEAD run is a base-staleness artifact, ` +
    `never a HEAD regression — the HEAD minus baseline set-diff direction stays authoritative; ` +
    `3) when local and CI disagree, the CI raw log is the source of truth (gh run view <run-id> --log), ` +
    `not the local count; ` +
    `4) do not rebase, reset or otherwise move the worktree to reconcile the numbers — the frozen base ` +
    `is deliberate.`
  )
}
// --- worktreeFreshnessNote:end ---

// T109 (lgtmgate#215) — worktreeFreshnessNote returns empty string when behind is 0 or negative
await testCase('T109a worktreeFreshnessNote: behind:0 → empty string', async () => {
  const result = worktreeFreshnessNote(0, 'main')
  return eq('result', result, '') || { ok: true }
})

await testCase('T109b worktreeFreshnessNote: behind:-1 → empty string', async () => {
  const result = worktreeFreshnessNote(-5, 'develop')
  return eq('result', result, '') || { ok: true }
})

// T109c — worktreeFreshnessNote returns empty string when behind is not a finite number
await testCase('T109c worktreeFreshnessNote: behind:NaN → empty string', async () => {
  const result = worktreeFreshnessNote(NaN, 'main')
  return eq('result', result, '') || { ok: true }
})

await testCase('T109d worktreeFreshnessNote: behind:undefined → empty string', async () => {
  const result = worktreeFreshnessNote(undefined, 'main')
  return eq('result', result, '') || { ok: true }
})

// T109e — worktreeFreshnessNote coerces string "3" to number 3 via Number() and returns warning
await testCase('T109e worktreeFreshnessNote: behind:"3" (string coerced to number) → warning', async () => {
  const result = worktreeFreshnessNote('3', 'main')
  const hasWarning = result.includes('WORKTREE FRESHNESS WARNING')
  const hasPlural = result.includes('3 commits behind origin/main')
  if (!hasWarning || !hasPlural) {
    return { ok: false, msg: `expected warning with "3 commits" but got: ${result.substring(0, 150)}...` }
  }
  return { ok: true }
})

// T109f — worktreeFreshnessNote returns a warning message when behind is 1 (singular)
await testCase('T109f worktreeFreshnessNote: behind:1 → warning with singular "commit"', async () => {
  const result = worktreeFreshnessNote(1, 'main')
  const hasWarning = result.includes('WORKTREE FRESHNESS WARNING')
  const hasSingular = result.includes('1 commit behind origin/main')
  const notPlural = !result.includes('1 commits')
  if (!hasWarning || !hasSingular || !notPlural) {
    return { ok: false, msg: `expected singular "commit" but got: ${result.substring(0, 150)}...` }
  }
  return { ok: true }
})

// T109g — worktreeFreshnessNote returns a warning message when behind is > 1 (plural)
await testCase('T109g worktreeFreshnessNote: behind:3 → warning with plural "commits"', async () => {
  const result = worktreeFreshnessNote(3, 'develop')
  const hasWarning = result.includes('WORKTREE FRESHNESS WARNING')
  const hasPlural = result.includes('3 commits behind origin/develop')
  if (!hasWarning || !hasPlural) {
    return { ok: false, msg: `expected plural "commits" but got: ${result.substring(0, 150)}...` }
  }
  return { ok: true }
})

// T109h — worktreeFreshnessNote includes all four guidance points in the warning message
await testCase('T109h worktreeFreshnessNote: warning includes all four guidance points', async () => {
  const result = worktreeFreshnessNote(2, 'main')
  const hasPt1 = result.includes('1) the local HEAD suite runs an older base')
  const hasPt2 = result.includes('2) the regression baseline is captured from a freshly fetched')
  const hasPt3 = result.includes('3) when local and CI disagree, the CI raw log is the source of truth')
  const hasPt4 = result.includes('4) do not rebase, reset or otherwise move the worktree')
  if (!hasPt1 || !hasPt2 || !hasPt3 || !hasPt4) {
    return { ok: false, msg: `warning missing guidance point(s): pt1=${hasPt1} pt2=${hasPt2} pt3=${hasPt3} pt4=${hasPt4}` }
  }
  return { ok: true }
})

// T109i — worktreeFreshnessNote includes the correct baseBranch in the output
await testCase('T109i worktreeFreshnessNote: baseBranch parameter is interpolated correctly', async () => {
  const result1 = worktreeFreshnessNote(1, 'main')
  const result2 = worktreeFreshnessNote(1, 'develop')
  const result3 = worktreeFreshnessNote(1, 'feature/custom')
  const check1 = result1.includes('origin/main')
  const check2 = result2.includes('origin/develop')
  const check3 = result3.includes('origin/feature/custom')
  if (!check1 || !check2 || !check3) {
    return { ok: false, msg: `baseBranch not interpolated correctly: main=${check1} develop=${check2} feature=${check3}` }
  }
  return { ok: true }
})

// T109j — worktreeFreshnessNote handles large numbers (100+ commits behind)
await testCase('T109j worktreeFreshnessNote: behind:100 → plural "commits"', async () => {
  const result = worktreeFreshnessNote(100, 'main')
  const hasWarning = result.includes('WORKTREE FRESHNESS WARNING')
  const hasPlural = result.includes('100 commits behind origin/main')
  if (!hasWarning || !hasPlural) {
    return { ok: false, msg: `expected "100 commits" but got: ${result.substring(0, 150)}...` }
  }
  return { ok: true }
})

// T9030 (#30) — Morgan's initial AND re-review prompts treat an absent or empty acceptance block as
// REQUIRED_CHANGES. Source-level: the shared ACCEPTANCE_PRESENCE_RULE literal is present and is
// interpolated into both Morgan prompts.
await testCase('T9030 Morgan prompts (initial + re-review) treat an absent or empty acceptance block as REQUIRED_CHANGES', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T9030: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const e1 = includes('literal items line', src, 'Acceptance block absent or empty')
  const e2 = eq('interpolations in the Morgan prompts', src.split('${ACCEPTANCE_PRESENCE_RULE}').length - 1, 2)
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T9036 (#36, #37) — acceptance items are executed commands describing repo states only. Source-level:
// the shared rule is defined once, interpolated once (Sam prompt), and the blocking check sits in the
// planCheck prompt and the plan-audit prompt.
await testCase('T9036 ACCEPTANCE_PROOF_RULE defined once, interpolated once; ACCEPTANCE PROOF CHECK in planCheck and audit prompts', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T9036: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const e1 = eq('ACCEPTANCE_PROOF_RULE occurrences (definition + interpolation)', src.split('ACCEPTANCE_PROOF_RULE').length - 1, 2)
  const e2 = eq('interpolations in the Sam prompt', src.split('${ACCEPTANCE_PROOF_RULE}').length - 1, 1)
  const e3 = eq('ACCEPTANCE PROOF CHECK (planCheck + audit)', src.split('ACCEPTANCE PROOF CHECK').length - 1, 2)
  return (e1 || e2 || e3) ? (e1 || e2 || e3) : { ok: true }
})

// T130 (#130) — run identity: the first log() is `deliver #<issue> — <brief>`, `Setup` is the first
// declared phase and is entered before any agent call, and every agent label carries the issue number.
// Source-anchored: the suite-scope log() cannot intercept the pipeline's own log (run-flow-suite.cjs).
await testCase('T130 run identity: first log is deliver #<issue>, Setup phase first (#130)', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T130: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const idx = (needle) => src.indexOf(needle)
  const firstTitle = /title: ['"]([^'"]+)['"]/.exec(src)
  const e1 = eq('first meta phase title', firstTitle && firstTitle[1], 'Setup')
  if (e1) return e1
  const iLog = idx('log(`deliver #${issue} — ')
  const iSetup = idx("phase('Setup')")
  const iRoot = idx('log(`worktreeRoot: ')
  const iRecheck = idx('config-project-recheck-')
  const iProv = idx("label: 'provision'")
  const iDiag = idx("phase('Diagnose')")
  const order = [['deliver log', iLog], ['phase(Setup)', iSetup], ['worktreeRoot log', iRoot], ['config-project-recheck-', iRecheck], ["label: 'provision'", iProv], ["phase('Diagnose')", iDiag]]
  for (const [n, i] of order) if (i < 0) return { ok: false, msg: `${n} not found in pipeline source` }
  for (let k = 1; k < order.length; k++) {
    if (!(order[k - 1][1] < order[k][1])) return { ok: false, msg: `expected ${order[k - 1][0]} before ${order[k][0]}` }
  }
  const e2 = eq('old status label gone', src.includes('label: `status:'), false)
  // The status write is a pr-write probe (#85): its agent label is probe-${issue}-pr-write-status-<name>-r0.
  const e3 = eq('status write goes through prWrite', src.includes("prWrite('status'"), true)
  // probe() call sites (#82) pass a bare `label` + `onFail`; probe() itself builds the agent label
  // `probe-${issue}-<name>-<label>-r<round>`, so the issue number is still in every agent label.
  const bad = src.split('\n').filter(l => l.includes('label:') && !l.includes('${issue}') && !l.includes('onFail'))
  const e4 = eq('agent labels without ${issue}', bad.length, 0)
  return e2 || e3 || e4 || { ok: true }
})

// T86 (#86) — the engine reads only `simulate.probes`; every probe('x') call-site name is registered
// in PROBES; no seam carries a `?? ` default (defaults live in SIM_DEFAULTS above). Source-anchored,
// each detector has a negative control.
const engineCode = (src) => src.split('\n').filter(l => !/^\s*\/\//.test(l))
const probeCallNames = (src) => [...engineCode(src).join('\n').matchAll(/\bprobe\('([^']+)'/g)].map(m => m[1])
const probesRegistered = (src) => {
  const m = /const PROBES = \{([\s\S]*?)\n\}/.exec(src)
  return m ? [...m[1].matchAll(/^\s*'([^']+)'\s*:/gm)].map(x => x[1]) : []
}
const probesMissing = (src) => { const reg = probesRegistered(src); return [...new Set(probeCallNames(src))].filter(n => !reg.includes(n)) }
const seamDefaultLines = (src) => engineCode(src).filter(l => l.includes('simulate.probes') && l.includes('?? '))
const simulateKeys = (src) => [...new Set([...engineCode(src).join('\n').matchAll(/simulate\??\.([A-Za-z_][A-Za-z0-9_]*)/g)].map(m => m[1]))]

await testCase('T86a every probe(x) name used by the engine is registered in PROBES (#86)', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T86a: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const control = eq('negative control', probesMissing("const PROBES = {\n  'a': 'a',\n}\nawait probe('a', 1)\nawait probe('b', 2)\n"), ['b'])
  if (control) return control
  const e0 = eq('PROBES is populated', probesRegistered(src).length > 0, true)
  if (e0) return e0
  return eq('probe names missing from PROBES', probesMissing(src), []) || { ok: true }
})

await testCase('T86b no `??` on a `simulate.probes` read line in the engine (#86)', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T86b: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const control = eq('negative control', seamDefaultLines('const x = simulate.probes.a ?? 1\nconst y = simulate.probes.b\n').length, 1)
  if (control) return control
  return eq('simulate.probes read lines with a ?? default', seamDefaultLines(src), []) || { ok: true }
})

await testCase('T86c the engine reads only simulate.probes (#86)', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T86c: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const control = eq('negative control', simulateKeys('simulate.probes.a\nsimulate?.other\n'), ['probes', 'other'])
  if (control) return control
  return eq('simulate keys read by the engine', simulateKeys(src), ['probes']) || { ok: true }
})

// ---------------------------------------------------------------------------
// #182 / #169 — the acceptance checklist as data
// ---------------------------------------------------------------------------

// T182a (#182) — parse(render(x)) deep-equals x. First on the three-item list holding a human-gate item, with the
// rendered lines compared to a hand-written oracle; then as a property over 300 seeded random lists whose texts stress
// the reader (backtick, colon, brackets, angle brackets, bang, dash, em dash, accents, pipe, id and tag fragments).
await testCase('T182a acceptance items round-trip: parse(render(x)) deep-equals x (3-item list with a human gate, then 300 seeded lists)', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182a')
  const x = fns.numberItems(T182_ITEMS)
  const e1 = eq('numberItems', x, T182_CANON)
  const e2 = eq('parse(render(x))', fns.parseChecklist(fns.renderChecklist(x)), x)
  const e3 = eq('rendered lines against the hand-written oracle', fns.renderChecklist(x).split('\n'), t182Lines(T182_ITEMS))
  if (e1 || e2 || e3) return e1 || e2 || e3
  // Negative control: a reader that loses the human-gate flag must NOT reproduce x, so the equality above can fail.
  const flagLost = fns.parseChecklist(fns.renderChecklist(x)).map((it) => ({ ...it, humanGate: false }))
  const control = eq('negative control (a reader that drops the human-gate flag)', JSON.stringify(flagLost) === JSON.stringify(x), false)
  if (control) return control
  // The property. Fragments that the validator must refuse (id comment, tag, checkbox prefix) are in the alphabet:
  // those entries are skipped, so the generator is checked too (refused > 0, kept >= 200).
  let seed = 182
  const rnd = (n) => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return Math.floor((seed / 4294967296) * n) }
  const alphabet = ['a', 'b', 'Z', '0', '7', ' ', ' ', '`', ':', '[', ']', '<', '>', '!', '-', '-->', '—', 'é', 'à', 'ß', '|', '$', ';', '(', ')', '#',
    '`two words`', '`one`', '- [ ] ', '<!-- ac:9 -->', '[Human-Gate]', ' — proven: ok']
  let kept = 0
  let refused = 0
  let gates = 0
  let spans = 0
  for (let n = 0; n < 300; n++) {
    const entries = []
    for (let k = 1 + rnd(5); k > 0; k--) {
      let text = ''
      for (let c = 1 + rnd(20); c > 0; c--) text += alphabet[rnd(alphabet.length)]
      const entry = { text, humanGate: rnd(2) === 1 }
      if (fns.validateAcceptanceItems([entry]).length > 0) { refused++; continue }
      entries.push(entry)
    }
    if (entries.length === 0) continue
    kept += entries.length
    const items = fns.numberItems(entries)
    gates += items.filter((it) => it.humanGate).length
    spans += items.filter((it) => it.text.includes('`')).length
    const back = fns.parseChecklist(fns.renderChecklist(items))
    if (JSON.stringify(back) !== JSON.stringify(items)) {
      return { ok: false, msg: `list ${n}: parse(render(x)) differs: expected ${JSON.stringify(items)}, got ${JSON.stringify(back)}` }
    }
    const bare = fns.parseChecklist(items.map((it) => fns.renderLine(it, false)).join('\n'))
    if (JSON.stringify(bare) !== JSON.stringify(items)) {
      return { ok: false, msg: `list ${n}: parse of the id-less lines differs: expected ${JSON.stringify(items)}, got ${JSON.stringify(bare)}` }
    }
  }
  if (kept < 200 || refused === 0 || gates === 0 || spans === 0) {
    return { ok: false, msg: `the generator went vacuous: kept=${kept} refused=${refused} gates=${gates} backticked=${spans}` }
  }
  return { ok: true }
})

// T182b (#182) — a body is read back with or without ids (a body opened before #182 keeps parsing): only the checkbox
// lines of the LAST marker pair count (a fenced example pair earlier, a decision-log pair and a stray box are ignored),
// a ticked line keeps its suffix in `text`, a bare checklist without markers parses, a lone start marker reads nothing.
await testCase('T182b parseChecklist reads a body with or without ids to the same items; last marker pair only; ticked suffix kept', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182b')
  const body = (lines) => [
    '## What this ships', '', 'The block looks like this:', '```',
    '<!-- acceptance:start -->', '- [ ] an example box that must be ignored', '<!-- acceptance:end -->',
    '```', '', '## Acceptance checklist',
    '<!-- acceptance:start -->', ...lines, '<!-- acceptance:end -->', '',
    '<!-- decision-log:start -->', '## Decision log', '- round 0 — REQUIRED_CHANGES (1 blocker)', '<!-- decision-log:end -->', '',
    '- [ ] a stray box outside the block',
  ].join('\n')
  const e1 = eq('with ids', fns.parseChecklist(body(t182Lines(T182_ITEMS))), T182_CANON)
  const e2 = eq('legacy body, no ids', fns.parseChecklist(body(t182Lines(T182_ITEMS, false))), T182_CANON)
  const e3 = eq('CRLF line endings', fns.parseChecklist(body(t182Lines(T182_ITEMS)).split('\n').join('\r\n')), T182_CANON)
  const e4 = eq('bare checklist, no markers', fns.parseChecklist(t182Lines(T182_ITEMS).join('\n')), T182_CANON)
  const e5 = eq('a lone start marker reads nothing', fns.parseChecklist('<!-- acceptance:start -->\n' + t182Lines(T182_ITEMS).join('\n')), [])
  const e6 = eq('empty / absent text', [fns.parseChecklist(''), fns.parseChecklist(undefined), fns.parseChecklist(null)], [[], [], []])
  const proven = ' — proven: `node scripts/guards.cjs` -> 0'
  const e7 = eq('ticked lines keep their suffix', fns.parseChecklist([
    '<!-- acceptance:start -->',
    '- [x] <!-- ac:1 --> ' + T182_ITEMS[0].text + proven,
    '- [X] [human-gate] ' + T182_ITEMS[1].text + proven,
    '<!-- acceptance:end -->',
  ].join('\n')), [
    { id: 1, text: T182_ITEMS[0].text + proven, humanGate: false },
    { id: 2, text: T182_ITEMS[1].text + proven, humanGate: true },
  ])
  const e8 = eq('an id comment keeps its number', fns.parseChecklist('- [ ] <!-- ac:4 --> four\n- [ ] <!-- ac:9 --> [human-gate] nine'), [
    { id: 4, text: 'four', humanGate: false },
    { id: 9, text: 'nine', humanGate: true },
  ])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || { ok: true }
})

// T182c (#182, closes #169) — a human-gate item that carries a command is not a human gate, refused NOT_CONFORMING then
// passing once amended. The structured `command` field is refused by the script (the plan-check model is permissive
// here); a command written in the item's text passes the script and is refused by the plan-check model (simulated
// NOT_CONFORMING on the first pass, the sentence of HUMAN_GATE_CHECK_NOTE), through the same loop.
await testCase('T182c a human-gate item carrying a command is refused NOT_CONFORMING, then passes once amended (command field by the script, command in the text by the plan check)', async () => {
  const withCommand = T182_ITEMS.map((it) => (it.humanGate ? { ...it, command: 'node scripts/guards.cjs' } : it))
  const r1 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(withCommand), 2: t182Sam(T182_ITEMS) }, planCheck: T182_CONFORMING } })
  const e1 = eq('command field: status', r1.status, 'plan-ready')
  const e2 = eq('command field: refusals', t182Refusals(r1), ['acceptance-items-refused:1'])
  const withSpan = T182_ITEMS.map((it) => (it.humanGate ? { ...it, text: 'the maintainer confirms `node scripts/guards.cjs` is the right check' } : it))
  const judged = 'item 2: a human-gate item whose text holds a command that decides it'
  const refusedTwice = { 1: { verdict: 'NOT_CONFORMING', issues: [judged] }, 2: { verdict: 'NOT_CONFORMING', issues: [judged] } }
  const r2 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(withSpan), 2: t182Sam(withSpan) }, planCheck: refusedTwice } })
  const e3 = eq('command in the text, kept: status', r2.status, 'escalate')
  const e4 = eq('command in the text, kept: the issues are the plan check\'s', r2.planCheckIssues, [judged])
  const e5 = eq('command in the text, kept: no script refusal', t182Refusals(r2), [])
  const amended = { 1: { verdict: 'NOT_CONFORMING', issues: [judged] }, 2: { verdict: 'CONFORMING' } }
  const r3 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(withSpan), 2: t182Sam(T182_ITEMS) }, planCheck: amended } })
  const e6 = eq('command in the text, amended: status', r3.status, 'plan-ready')
  const e7 = eq('command in the text, amended: no script refusal', t182Refusals(r3), [])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || { ok: true }
})

// T182d (#182) — a genuine human gate (a judgement, no command) passes the plan gate untouched, and the block the
// script rendered reaches Nick verbatim, ids and tag included. An LGTM carries its `boxes` (#183: without them no box is
// proven, see T183n); the payload then carries them mapped by id.
await testCase('T182d a genuine human-gate item passes the plan gate; the rendered block reaches Nick verbatim', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T182_ITEMS) }, prBody: t182GateTickedBody(), morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: 'p1' }, { id: 2, proven: true, proof: 'p2' }, { id: 3, proven: true, proof: 'p3' }] }] } })
  const p = String(r.nickPromptPreview || '')
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('refusals', t182Refusals(r), [])
  const e3 = includes('Nick prompt carries the rendered lines', p, t182Lines(T182_ITEMS).join('\n'))
  const e4 = includes('Nick prompt asks for them verbatim', p, 'paste exactly these lines between the markers')
  const e5 = eq('boxes ids', (r.boxes || []).map((b) => b.id), [1, 2, 3])
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

// T182e (#182) — Morgan returns boxes [{ id, proven, proof }]; the script maps them by id to the rendered items and the
// payload carries them in item order. An id no item carries (9) is dropped and traced; the proof strings travel verbatim.
await testCase('T182e Morgan boxes are mapped by id to the rendered items, in item order; an unknown id is dropped and traced', async () => {
  const gateLine = t182Lines(T182_ITEMS)[1]
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T182_ITEMS) },
      morgan: [{
        verdict: 'REQUIRED_CHANGES',
        items: [gateLine],
        boxes: [
          { id: 3, proven: true, proof: 'failed=0' },
          { id: 1, proven: true, proof: '$ node scripts/guards.cjs\n0' },
          { id: 9, proven: true, proof: 'no such box' },
          { id: 2, proven: false, proof: '' },
        ],
      }],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('boxes', r.boxes, [
    { id: 1, text: T182_ITEMS[0].text, humanGate: false, proven: true, proof: '$ node scripts/guards.cjs\n0' },
    { id: 2, text: T182_ITEMS[1].text, humanGate: true, proven: false, proof: '' },
    { id: 3, text: T182_ITEMS[2].text, humanGate: false, proven: true, proof: 'failed=0' },
  ])
  const e3 = includes('trace', r.trace || [], 'boxes-unknown-id:9')
  const e4 = (r.trace || []).some((t) => String(t).startsWith('boxes-missing:')) ? { ok: false, msg: `unexpected boxes-missing in ${JSON.stringify(r.trace)}` } : null
  return e1 || e2 || e3 || e4 || { ok: true }
})

// T182f (#182, #169) — the refusal is not a one-off: a gate item that carries a `command` field is refused on every
// attempt, so the existing escalation applies (plan-not-conforming) and names the item and the command. Controls: the
// same command written only in the gate item's text passes the script (the plan-check model, permissive here, judges
// it), and a proven item may carry its command.
await testCase('T182f a human-gate item with a command field is refused on every attempt -> escalate plan-not-conforming; the command in the text alone and a proven item with a command pass the script', async () => {
  const cmdField = [{ text: 'the maintainer reads the output and judges the wording', humanGate: true, command: 'node -e "1"' }]
  const r1 = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(cmdField), 2: t182Sam(cmdField) }, planCheck: T182_CONFORMING } })
  const first = String((r1.planCheckIssues || [])[0] || '')
  const e1 = eq('status', r1.status, 'escalate')
  const e2 = eq('reason', r1.reason, 'plan-not-conforming')
  const e3 = includes('planCheckIssues[0] names the item', first, 'item 1')
  const e4 = includes('planCheckIssues[0] quotes the command', first, 'node -e "1"')
  const e5 = eq('refusals', t182Refusals(r1), ['acceptance-items-refused:1', 'acceptance-items-refused:2'])
  const inText = [{ text: 'the maintainer reads `node -e "1"` and judges the wording', humanGate: true }]
  const r2 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(inText) }, planCheck: T182_CONFORMING } })
  const e6 = eq('command in the text only: status', r2.status, 'plan-ready')
  const e7 = eq('command in the text only: refusals', t182Refusals(r2), [])
  const proven = [{ text: '`bash scripts/x.sh` exits 0', humanGate: false, command: 'bash scripts/x.sh' }]
  const r3 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(proven) }, planCheck: T182_CONFORMING } })
  const e8 = eq('proven item with a command: status', r3.status, 'plan-ready')
  const e9 = eq('proven item with a command: refusals', t182Refusals(r3), [])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || { ok: true }
})

// T182g (#182, #169) — the validator as a table: every refused shape names its item number, every accepted shape returns [].
await testCase('T182g validateAcceptanceItems: each refused shape names its item, each accepted shape passes', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182g')
  const refused = [
    ['not an array', 'a string', 'non-empty array'],
    ['an object, not an array', {}, 'non-empty array'],
    ['an empty array', [], 'non-empty array'],
    ['an entry without text', [{ humanGate: false }], 'item 1: must be an object with a string text'],
    ['a null entry', [{ text: 'ok' }, null], 'item 2: must be an object with a string text'],
    ['a non-string text', [{ text: 5 }], 'item 1: must be an object with a string text'],
    ['a blank text', [{ text: '   ' }], 'item 1: text must be one non-empty line'],
    ['a two-line text', [{ text: 'first\nsecond' }], 'item 1: text must be one non-empty line'],
    ['a checkbox prefix in the text', [{ text: 'ok' }, { text: '- [ ] already a box' }], 'item 2: text must not carry'],
    ['an id comment in the text', [{ text: '<!-- ac:1 --> already numbered' }], 'item 1: text must not carry'],
    ['the tag in the text, any case', [{ text: 'judge it [Human-Gate]' }], 'item 1: text must not carry'],
    ['a non-boolean humanGate', [{ text: 'ok', humanGate: 'yes' }], 'item 1: humanGate must be true or false'],
    ['a non-string command', [{ text: 'ok', command: 5 }], 'item 1: command must be a string'],
    ['a gate item with a command', [{ text: 'a person judges it', humanGate: true, command: 'node x.js' }], 'item 1: flagged humanGate but carries the command `node x.js`'],
    ['a gate item with a padded command', [{ text: 'ok' }, { text: 'a person judges it', humanGate: true, command: '  mvn test ' }], 'item 2: flagged humanGate but carries the command `mvn test`'],
  ]
  for (const [label, entries, want] of refused) {
    const issues = fns.validateAcceptanceItems(entries)
    if (issues.length === 0 || !issues[0].includes(want)) return { ok: false, msg: `${label}: expected an issue including ${JSON.stringify(want)}, got ${JSON.stringify(issues)}` }
  }
  const accepted = [
    ['plain items', [{ text: 'plain', humanGate: false }, { text: 'second' }]],
    ['a command on a non-gate item', [{ text: '`bash x.sh` exits 0', humanGate: false, command: 'bash x.sh' }]],
    ['a blank command on a gate item', [{ text: 'a person judges it', humanGate: true, command: '  ' }]],
    ['a single-token span on a gate item', [{ text: 'a person reads `README.md` first', humanGate: true }]],
    ['an unterminated backtick on a gate item', [{ text: 'a person reads `README.md and then judges', humanGate: true }]],
    ['a command in a gate item\'s text (the plan check judges it)', [{ text: 'a person runs `bash x.sh` first', humanGate: true }]],
    ['a command on an item whose humanGate is false', [{ text: 'a person judges it', humanGate: false, command: 'dotnet test' }]],
    ['an arrow inside the text', [{ text: 'the --> arrow is fine', humanGate: false }, { text: 'so is this --> one', humanGate: true }]],
  ]
  for (const [label, entries] of accepted) {
    const issues = fns.validateAcceptanceItems(entries)
    if (issues.length !== 0) return { ok: false, msg: `${label}: expected no issue, got ${JSON.stringify(issues)}` }
  }
  const both = fns.validateAcceptanceItems([{ text: '' }, { text: 'fine' }, { text: 'x', humanGate: 'no' }])
  const e1 = eq('one issue per bad item, in item order', both.map((s) => s.split(':')[0]), ['item 1', 'item 3'])
  return e1 || { ok: true }
})

// T182h (#182) — source-anchored: the new text is interpolated where the contract needs it, once per site, and the two
// prompt notes vanish without a block so a legacy run's prompts stay byte-identical.
await testCase('T182h source: ACCEPTANCE_ITEMS_RULE once, the Nick note once, the Morgan note twice, the human-gate note twice; notes are empty without a block', async () => {
  const src = SUITE_ARGS.fpSource
  const fns = t182Block()
  if (!src || !fns) return t182Skip('T182h')
  const count = (needle) => src.split(needle).length - 1
  const e1 = eq('ACCEPTANCE_ITEMS_RULE interpolations (Sam prompt)', count('${ACCEPTANCE_ITEMS_RULE}'), 1)
  const e2 = eq('nickBlockNote interpolations (Nick prompt)', count('${nickBlockNote(acceptanceBlock)}'), 1)
  const e3 = eq('morganBoxesNote interpolations (initial + re-review)', count('${morganBoxesNote(acceptanceBlock)}'), 2)
  const e4 = eq('HUMAN_GATE_CHECK_NOTE interpolations (plan-check + plan-audit)', count('${HUMAN_GATE_CHECK_NOTE}'), 2)
  const rule = src.split('\n').find((l) => l.startsWith('const ACCEPTANCE_ITEMS_RULE = ')) || ''
  const missing = ['acceptanceItems', '<!-- ac:N -->', '[human-gate]', 'a command written in its text is judged by the plan check'].filter((w) => !rule.includes(w))
  const e5 = missing.length ? { ok: false, msg: `ACCEPTANCE_ITEMS_RULE lacks ${JSON.stringify(missing)}` } : null
  const e6 = eq('both notes are empty without a block', [fns.nickBlockNote(''), fns.nickBlockNote(undefined), fns.morganBoxesNote(''), fns.morganBoxesNote(undefined)], ['', '', '', ''])
  const block = t182Lines(T182_ITEMS).join('\n')
  const e7 = includes('Nick note carries the block', fns.nickBlockNote(block), block)
  const e8 = includes('Morgan note carries the block', fns.morganBoxesNote(block), block)
  const e9 = includes('Morgan note names the id comment', fns.morganBoxesNote(block), '<!-- ac:n --> comment included')
  const e10 = includes('Morgan note asks for the boxes', fns.morganBoxesNote(block), 'return boxes')
  const e11 = includes('Sam schema carries acceptanceItems', src, '    acceptanceItems: {\n      type: \'array\',')
  const e12 = includes('Morgan schema carries boxes', src, '    boxes: {\n      type: \'array\',')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || e11 || e12 || { ok: true }
})

// T182i (#153, #182) — the plan gate judges the returned text: a summary plan that lacks the rendered item lines is
// refused without a plan-check call (one sentence plus one line per item to write), the id comment being optional.
await testCase('T182i a summary-only plan is refused with one line per missing item; a plan holding the lines without ids passes', async () => {
  const summary = { plan: '## Plan\nsummary only', acceptanceItems: T182_ITEMS }
  const r1 = await run({ mode: 'auto', simulate: { sam: { 1: summary, 2: summary }, planCheck: T182_CONFORMING } })
  const issues = r1.planCheckIssues || []
  const e1 = eq('status', r1.status, 'escalate')
  const e2 = eq('reason', r1.reason, 'plan-not-conforming')
  const e3 = eq('planCheckIssues.length', issues.length, 1 + T182_ITEMS.length)
  const e4 = includes('planCheckIssues[1] names the first line to write', String(issues[1] || ''), t182Lines(T182_ITEMS)[0])
  const r2 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(T182_ITEMS, false) }, planCheck: T182_CONFORMING } })
  const e5 = eq('lines without ids: status', r2.status, 'plan-ready')
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

// T182j (#182) — state preservation: the legacy Sam shape (a checklist string, no items) and a Morgan verdict that
// carries `boxes` anyway keep the pre-#182 path. No rendered block for Nick, no `boxes` on the payload, no new trace.
// (Green on the base engine too: nothing is rendered or mapped without Sam's items.)
await testCase('T182j legacy Sam shape: no rendered block for Nick, no boxes on the payload, no boxes- or acceptance-items- trace', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: 'x' }] }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = String(r.nickPromptPreview || '').includes('rendered the acceptance checklist') ? { ok: false, msg: 'Nick prompt carries a rendered block on the legacy path' } : null
  const e3 = eq('boxes', r.boxes, undefined)
  const bad = (r.trace || []).find((t) => String(t).startsWith('boxes-') || String(t).startsWith('acceptance-items-'))
  const e4 = bad ? { ok: false, msg: `unexpected trace entry ${JSON.stringify(bad)}` } : null
  return e1 || e2 || e3 || e4 || { ok: true }
})

// T182k (#97, #182) — the plan-amendment round takes the checklist as items too: the amended items are checked and
// rendered, and with the legacy string emptied they alone feed the acceptance-block sync (ready). A refused amendment
// (a gate item with a command) is not synced: the existing acceptance-sync-failed escalation, no new reason.
await testCase('T182k plan amendment with items: valid items feed the sync (ready); a refused amendment -> escalate acceptance-sync-failed', async () => {
  const wording = t182Lines(T182_ITEMS)[0]
  const r1 = await run({
    mode: 'auto',
    maxPlanAmendRounds: 1,
    simulate: {
      // No human gate here: the amendment re-renders the block with every box open, so a gate a person had ticked is open again.
      sam: { 1: t182Sam(T182_ITEMS.map((i) => ({ ...i, humanGate: false }))) },
      samAcceptanceChecklist: '',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [wording], itemOwners: [{ item: wording, itemOwner: 'checklist-wording-defect', proof: 'the command prints 1, the item says 0' }] },
        { verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: 'p1' }, { id: 2, proven: true, proof: 'p2' }, { id: 3, proven: true, proof: 'p3' }] },
      ],
    },
  })
  const e1 = eq('valid amendment: status', r1.status, 'ready')
  const e2 = includes('valid amendment: trace', r1.trace || [], 'plan-amend-round:1')
  const refused = [{ text: 'a person judges it', humanGate: true, command: 'node scripts/guards.cjs' }]
  const r2 = await run({
    mode: 'auto',
    maxPlanAmendRounds: 1,
    simulate: {
      sam: { 1: t182Sam(T182_ITEMS), 2: { acceptanceItems: refused } },
      samAcceptanceChecklist: '',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['fix the null guard'] },
        { verdict: 'REQUIRED_CHANGES', items: [wording], itemOwners: [{ item: wording, itemOwner: 'plan-defect', proof: 'the plan step never names the command' }] },
      ],
    },
  })
  const e3 = eq('refused amendment: status', r2.status, 'escalate')
  const e4 = eq('refused amendment: reason', r2.reason, 'acceptance-sync-failed')
  return e1 || e2 || e3 || e4 || { ok: true }
})

// T182l-n (#182, PR #190 review) — the default `semi` flow stops at plan-ready and the Lead relaunches at entryStage dev
// (then review) with `planText`: no Plan phase runs in that process, so the items are rebuilt from the plan's
// `<!-- ac:N -->` lines. The plan also holds a task list without ids, which must not become an item.
const t182PlanText = (ids = true) => '## Plan\n- [ ] step one: a task, not an acceptance item\n\n' + t182Sam(T182_ITEMS, ids).plan
await testCase('T182l a semi relaunch at entryStage dev with an id-bearing planText: the rebuilt block reaches Nick', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182l')
  const r = await run({ mode: 'semi', entryStage: 'dev', planText: t182PlanText(), simulate: { prBody: t182GateTickedBody(), morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: 'p1' }, { id: 2, proven: true, proof: 'p2' }, { id: 3, proven: true, proof: 'p3' }] }] } })
  const p = String(r.nickPromptPreview || '')
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('Nick prompt carries exactly the rendered block', p, fns.nickBlockNote(t182Lines(T182_ITEMS).join('\n')))
  const e3 = p.includes('step one') ? { ok: false, msg: 'a task-list line without an id reached the Nick prompt' } : null
  // The reader itself: a checklist written twice (artifact + index copy) keeps one item per id, and a plan without any
  // id yields null (the legacy path). A malformed id comment inside the checklist yields null too (all or nothing, T182r).
  const twice = t182PlanText() + '\n## Index copy\n' + t182Lines(T182_ITEMS).join('\n') + '\n'
  const e4 = eq('itemsFromPlan: one item per id', fns.itemsFromPlan(twice), T182_CANON)
  const e5 = eq('itemsFromPlan: no id -> null', [fns.itemsFromPlan(t182PlanText(false)), fns.itemsFromPlan(''), fns.itemsFromPlan(undefined)], [null, null, null])
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})
await testCase('T182m a semi relaunch at entryStage review with an id-bearing planText: Morgan boxes are mapped by id', async () => {
  const r = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 190,
    planText: t182PlanText(),
    simulate: {
      morgan: [{
        verdict: 'REQUIRED_CHANGES',
        items: [t182Lines(T182_ITEMS)[1]],
        boxes: [{ id: 2, proven: false, proof: '' }, { id: 1, proven: true, proof: '0' }, { id: 3, proven: true, proof: 'failed=0' }],
      }],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('boxes', r.boxes, [
    { id: 1, text: T182_ITEMS[0].text, humanGate: false, proven: true, proof: '0' },
    { id: 2, text: T182_ITEMS[1].text, humanGate: true, proven: false, proof: '' },
    { id: 3, text: T182_ITEMS[2].text, humanGate: false, proven: true, proof: 'failed=0' },
  ])
  const bad = (r.trace || []).find((t) => String(t).startsWith('boxes-'))
  const e3 = bad ? { ok: false, msg: `unexpected trace entry ${JSON.stringify(bad)}` } : null
  return e1 || e2 || e3 || { ok: true }
})
await testCase('T182n a relaunch with a legacy planText (no ids): no rendered block for Nick, no boxes from Morgan', async () => {
  const r1 = await run({ mode: 'semi', entryStage: 'dev', planText: t182PlanText(false), simulate: { morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('dev: status', r1.status, 'ready')
  const e2 = String(r1.nickPromptPreview || '').includes('rendered the acceptance checklist') ? { ok: false, msg: 'Nick prompt carries a rendered block for a legacy plan' } : null
  const r2 = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 190,
    planText: t182PlanText(false),
    simulate: { morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: 'x' }] }] },
  })
  const e3 = eq('review: status', r2.status, 'ready')
  const e4 = eq('review: boxes', r2.boxes, undefined)
  const bad = [...(r1.trace || []), ...(r2.trace || [])].find((t) => String(t).startsWith('boxes-'))
  const e5 = bad ? { ok: false, msg: `unexpected trace entry ${JSON.stringify(bad)}` } : null
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

// T182o-p (#169, PR #190 review) — the human-gate validator checks structure: the #169 incident, double-backtick
// commands, a path, a flag or a pipe written in a gate item's text all pass the script (the plan-check model judges a
// command in the text, HUMAN_GATE_CHECK_NOTE); the same item carrying that command in its `command` field is refused,
// quoting it. UI copy, a Markdown heading and a judgement pass either way.
const T182_INCIDENT = 'Visual check: the PR body pastes verbatim the output of node -e \'…render(…, { locale: "fr-FR" })\' … and the human confirms both'
const T182_UI_COPY = 'The empty-state copy `No items yet` reads naturally on a small screen'
const T182_HEADING = 'The `## What this ships` section reads well to a third party'
await testCase('T182o validator: a command in a gate item\'s text passes the script, the same command in its command field is refused; UI copy, a heading and a judgement pass', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182o')
  const gate = (text, command) => fns.validateAcceptanceItems([command === undefined ? { text, humanGate: true } : { text, humanGate: true, command }])
  const commands = [
    ['the #169 incident (bare invocation)', T182_INCIDENT, 'node -e \'…render(…, { locale: "fr-FR" })\''],
    ['a double-backtick command', 'the maintainer judges the output of ``npm test`` by eye', 'npm test'],
    ['a double-backtick span holding a backtick', 'a person reads ``git log --format=`%h` `` and judges', 'git log --format=`%h`'],
    ['a span whose first word is a path', 'a person runs `./build.sh release` and looks', './build.sh release'],
    ['a span with a flag', 'a person runs `mytool --dry-run` and looks', 'mytool --dry-run'],
    ['a span with a pipe', 'a person reads `cat x | head` and judges', 'cat x | head'],
    ['a bare executable then a path', 'a person runs bash scripts/x.sh and judges the colours', 'bash scripts/x.sh'],
  ]
  for (const [label, text, cmd] of commands) {
    const inText = gate(text)
    if (inText.length !== 0) return { ok: false, msg: `${label}, in the text only: expected no refusal from the script, got ${JSON.stringify(inText)}` }
    const inField = gate(text, cmd)
    if (inField.length !== 1 || !inField[0].startsWith('item 1: flagged humanGate but carries the command') || !inField[0].includes(cmd)) {
      return { ok: false, msg: `${label}, in the command field: expected one refusal quoting ${JSON.stringify(cmd)}, got ${JSON.stringify(inField)}` }
    }
  }
  const accepted = [
    ['UI copy in backticks', T182_UI_COPY],
    ['a Markdown heading in backticks', T182_HEADING],
    ['a genuine judgement', 'the maintainer confirms the plan wording reads well'],
    ['a judgement naming a file', 'the maintainer reads `scripts/lead-merge.sh` and judges the wording'],
    ['a judgement with an executable name as prose', 'the release notes say node 22 is the floor, the maintainer agrees'],
    ['a breadcrumb in backticks', 'on the device, `Settings > Privacy > Camera` lists the app'],
  ]
  for (const [label, text] of accepted) {
    const issues = gate(text)
    if (issues.length !== 0) return { ok: false, msg: `${label}: expected no issue, got ${JSON.stringify(issues)}` }
  }
  return { ok: true }
})
await testCase('T182p plan gate: the #169 incident carried as a command field is refused NOT_CONFORMING then passes once amended; written in the text only, it reaches the plan check; UI-copy and heading gates pass first time', async () => {
  const incident = T182_ITEMS.map((it) => (it.humanGate ? { ...it, command: 'node -e \'…render(…, { locale: "fr-FR" })\'' } : it))
  const r1 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(incident), 2: t182Sam(T182_ITEMS) }, planCheck: T182_CONFORMING } })
  const e1 = eq('incident as a command field: status', r1.status, 'plan-ready')
  const e2 = eq('incident as a command field: refusals', t182Refusals(r1), ['acceptance-items-refused:1'])
  const inText = T182_ITEMS.map((it) => (it.humanGate ? { ...it, text: T182_INCIDENT } : it))
  const judged = 'item 2: the human gate holds the node -e command that decides it'
  const r2 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(inText), 2: t182Sam(inText) }, planCheck: { 1: { verdict: 'NOT_CONFORMING', issues: [judged] }, 2: { verdict: 'NOT_CONFORMING', issues: [judged] } } } })
  const e3 = eq('incident in the text: status', r2.status, 'escalate')
  const e4 = eq('incident in the text: the issues are the plan check\'s', r2.planCheckIssues, [judged])
  const e5 = eq('incident in the text: no script refusal', t182Refusals(r2), [])
  const judgedOk = [{ text: T182_UI_COPY, humanGate: true }, { text: T182_HEADING, humanGate: true }]
  const r3 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(judgedOk) }, planCheck: T182_CONFORMING } })
  const e6 = eq('UI copy and heading: status', r3.status, 'plan-ready')
  const e7 = eq('UI copy and heading: refusals', t182Refusals(r3), [])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || { ok: true }
})

// T182q (#169, PR #190 review round 2) — the validator checks STRUCTURE only: a human-gate item is refused for a
// non-empty `command` field, never for its prose. Ordinary text with backticks or program-like words passes the script,
// at the validator and through the plan gate (a command written in the text is the plan-check model's to judge, see
// HUMAN_GATE_CHECK_NOTE); the same item carrying a `command` is refused, then the plan passes once amended.
const T182_PROSE = [
  'The empty-state copy `No items yet` reads naturally on a small screen',
  'The `## What this ships` section reads well to a third party',
  'the user can find "Export" in the share sheet',
  'make "Continue" the obvious next step',
  'go "back" returns to the list without losing the draft',
  'the team agrees the README keeps bundle exec rspec as its entry point',
]
await testCase('T182q validator checks structure only: prose with backticks or program-like words passes; a human-gate item with a command field is refused', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182q')
  for (const text of T182_PROSE) {
    const issues = fns.validateAcceptanceItems([{ text, humanGate: true }])
    if (issues.length !== 0) return { ok: false, msg: `${JSON.stringify(text)}: expected no refusal, got ${JSON.stringify(issues)}` }
    const withCommand = fns.validateAcceptanceItems([{ text, humanGate: true, command: 'bundle exec rspec' }])
    if (withCommand.length !== 1 || !withCommand[0].startsWith('item 1: flagged humanGate but carries the command `bundle exec rspec`')) {
      return { ok: false, msg: `${JSON.stringify(text)} with a command field: expected one refusal quoting it, got ${JSON.stringify(withCommand)}` }
    }
  }
  const prose = T182_PROSE.map((text) => ({ text, humanGate: true }))
  const r1 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(prose) }, planCheck: T182_CONFORMING } })
  const e1 = eq('prose gates: status', r1.status, 'plan-ready')
  const e2 = eq('prose gates: refusals', t182Refusals(r1), [])
  const withCommand = prose.map((it, i) => (i === 2 ? { ...it, command: 'bundle exec rspec' } : it))
  const r2 = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(withCommand), 2: t182Sam(prose) }, planCheck: T182_CONFORMING } })
  const e3 = eq('a gate with a command field: status', r2.status, 'plan-ready')
  const e4 = eq('a gate with a command field: refusals', t182Refusals(r2), ['acceptance-items-refused:1'])
  return e1 || e2 || e3 || e4 || { ok: true }
})

// T182r (#182, PR #190 review round 2) — itemsFromPlan is all-or-nothing: a checklist where some lines carry an id and
// others do not yields null (the legacy path: no block for Nick, no boxes), never a partial list that would drop the
// id-less item from the block Nick pastes. Same when the lines are spaced by blank lines, or an id comment is malformed.
const t182Mixed = (sep, middle = t182Lines(T182_ITEMS, false)[1]) =>
  '## Plan\n- [ ] step one: a task, not an acceptance item\n\n## Acceptance checklist\n' + [t182Lines(T182_ITEMS)[0], middle, t182Lines(T182_ITEMS)[2]].join(sep) + '\n'
await testCase('T182r a mixed plan (ids on lines 1 and 3, none on line 2) yields no items: a semi relaunch at entryStage dev gets no block note and no boxes', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182r')
  const e1 = eq('itemsFromPlan: mixed, adjacent / blank-separated / malformed id', [
    fns.itemsFromPlan(t182Mixed('\n')),
    fns.itemsFromPlan(t182Mixed('\n\n')),
    fns.itemsFromPlan(t182Mixed('\n', '- [ ] <!-- ac:x --> [human-gate] ' + T182_ITEMS[1].text)),
  ], [null, null, null])
  // Control: the same plan with the id on line 2 rebuilds all three items, so the null above is the mix, not the shape.
  const e2 = eq('itemsFromPlan: control, every line with its id', fns.itemsFromPlan(t182Mixed('\n', t182Lines(T182_ITEMS)[1])), T182_CANON)
  const r = await run({
    mode: 'semi',
    entryStage: 'dev',
    planText: t182Mixed('\n'),
    simulate: { morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: '0' }, { id: 3, proven: true, proof: 'failed=0' }] }] },
  })
  const e3 = eq('status', r.status, 'ready')
  const e4 = String(r.nickPromptPreview || '').includes('rendered the acceptance checklist') ? { ok: false, msg: 'Nick prompt carries a partial rendered block for a mixed plan' } : null
  const e5 = eq('boxes', r.boxes, undefined)
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

// T182s (#169, PR #190 review round 2) — source-anchored: the judgement of a command written in a human-gate item's text
// is the plan-check model's, through HUMAN_GATE_CHECK_NOTE, which says so plainly; the engine keeps no program-name list,
// path-prefix list, shell-operator list or prose/backtick parser for it (neutrality: no stack is known to the engine).
await testCase('T182s source: the human-gate note sends a command in the text to the plan check; no program-name list or prose parser in the engine', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) return t182Skip('T182s')
  const note = src.split('\n').find((l) => l.startsWith('const HUMAN_GATE_CHECK_NOTE = ')) || ''
  const missing = ['NOT conforming when its text contains a command that could decide it', 'a judgement about wording, layout or taste is conforming'].filter((w) => !note.includes(w))
  const e1 = missing.length ? { ok: false, msg: `HUMAN_GATE_CHECK_NOTE lacks ${JSON.stringify(missing)}` } : null
  const banned = ['COMMAND_NAMES', 'PATH_PREFIXES', 'SHELL_OPERATORS', 'holdsBareCommand', 'holdsCommandSpan', 'isCommandSpan', 'codeSpans'].filter((w) => src.includes(w))
  const e2 = eq('prose heuristics left in the engine', banned, [])
  return e1 || e2 || { ok: true }
})

// T182t (#182, PR #190 review round 3) — itemsFromPlan rebuilds a list only when the plan holds ONE checklist: every run of
// id-bearing checkbox lines is normalised to its { id, text, humanGate } sequence, and two runs that differ in any way
// (an example block before the real list, a stale copy with an extra line) give null, never a guess of which one is real.
// The same list written twice (artifact + index copy) stays accepted. No fence is parsed.
const t182Fenced = (lines) => '```\n' + lines.join('\n') + '\n```\n'
const T182_EXAMPLE = [
  '- [ ] <!-- ac:1 --> `node a.js` prints 3',
  '- [ ] <!-- ac:2 --> [human-gate] wording reads well',
  '- [ ] <!-- ac:3 --> `node b.js` exits 0',
  '- [ ] <!-- ac:4 --> an example fourth item',
]
const t182ExampleThenReal = '## Plan\nThe PR body has this shape:\n\n' + t182Fenced(T182_EXAMPLE) + '\n## Acceptance checklist\n' + t182Lines(T182_ITEMS).join('\n') + '\n'
const t182RealThenStale = '## Acceptance checklist\n' + t182Lines(T182_ITEMS).join('\n') + '\n\n## Index copy (stale)\n' +
  [...t182Lines(T182_ITEMS), '- [ ] <!-- ac:4 --> a stale fourth item'].join('\n') + '\n'
const t182Twice = '## Acceptance checklist\n' + t182Lines(T182_ITEMS).join('\n') + '\n\n## Index copy\n' + t182Lines(T182_ITEMS).join('\n') + '\n'
const t182Once = '## Plan\n- [ ] step one: a task, not an acceptance item\n\n## Acceptance checklist\n' + t182Lines(T182_ITEMS).join('\n') + '\n'
await testCase('T182t itemsFromPlan: two different id\'d checklists in a plan give null (example block then real list, real list then stale copy); the same list twice and a single list give the 3 items; a semi relaunch gets no block note and no boxes', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T182t')
  const e1 = eq('example block before the real checklist -> null', fns.itemsFromPlan(t182ExampleThenReal), null)
  const e2 = eq('real checklist then a stale copy with an extra ac:4 line -> null', fns.itemsFromPlan(t182RealThenStale), null)
  const e3 = eq('same checklist written twice -> the 3 items', fns.itemsFromPlan(t182Twice), T182_CANON)
  const e4 = eq('a single checklist -> the 3 items', fns.itemsFromPlan(t182Once), T182_CANON)
  // Any difference between two runs refuses: a flag, a text, an id order alone.
  const flagged = '## A\n' + t182Lines(T182_ITEMS).join('\n') + '\n\n## B\n' + t182Lines([T182_ITEMS[0], { ...T182_ITEMS[1], humanGate: false }, T182_ITEMS[2]]).join('\n') + '\n'
  const reworded = '## A\n' + t182Lines(T182_ITEMS).join('\n') + '\n\n## B\n' + t182Lines([{ ...T182_ITEMS[0], text: T182_ITEMS[0].text + ' today' }, T182_ITEMS[1], T182_ITEMS[2]]).join('\n') + '\n'
  const e5 = eq('copies differing by a flag / by a word -> null', [fns.itemsFromPlan(flagged), fns.itemsFromPlan(reworded)], [null, null])
  // The flow: a semi relaunch at entryStage dev with the example-then-real plan keeps no items.
  const r = await run({
    mode: 'semi',
    entryStage: 'dev',
    planText: t182ExampleThenReal,
    simulate: { morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: '0' }, { id: 2, proven: true, proof: 'x' }, { id: 3, proven: true, proof: 'failed=0' }] }] },
  })
  const e6 = eq('status', r.status, 'ready')
  const e7 = String(r.nickPromptPreview || '').includes('rendered the acceptance checklist') ? { ok: false, msg: 'Nick prompt carries a rendered block for a plan holding two different checklists' } : null
  const e8 = eq('boxes', r.boxes, undefined)
  const bad = (r.trace || []).find((t) => String(t).startsWith('boxes-'))
  const e9 = bad ? { ok: false, msg: `unexpected trace entry ${JSON.stringify(bad)}` } : null
  // Control: the same flow with the identical list written twice rebuilds the 3 items.
  const c = await run({ mode: 'semi', entryStage: 'dev', planText: t182Twice, simulate: { morgan: [{ verdict: 'LGTM' }] } })
  const e10 = includes('control: Nick prompt carries the block for the list written twice', String(c.nickPromptPreview || ''), fns.nickBlockNote(t182Lines(T182_ITEMS).join('\n')))
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || { ok: true }
})

// ---------------------------------------------------------------------------
// #183 — the acceptance checklist as data (2/2): the workflow ticks by id, the textual gates are gone
// ---------------------------------------------------------------------------
// (T183a-c above belong to an unrelated resume note.) Every case is an id run: Sam returns the items, Morgan returns
// `boxes` and quotes box lines with their `<!-- ac:N -->` comment. T183d-j are written against the engine behaviour,
// T183k is the source check of what must no longer exist.
const T183_PLAIN = [
  { text: '`node scripts/guards.cjs; echo $?` prints `0` as its last line', humanGate: false },
  { text: '`bash templates/test-probe-run.sh | tail -n 1` ends with `failed=0`', humanGate: false },
  { text: '`node scripts/run-flow-suite.cjs | tail -n 1` ends with `failed=0`', humanGate: false },
]
const t183Boxes = (...proven) => proven.map((p, i) => ({ id: i + 1, proven: p, proof: p ? `proof ${i + 1}` : '' }))
const t183Body = (lines) => 'Closes #183\n\n<!-- acceptance:start -->\n' + lines.join('\n') + '\n<!-- acceptance:end -->\n'

await testCase('T183d Morgan proving 2 of 3 boxes leaves exactly ids 1 and 3 ticked in the body, the human gate open', async () => {
  const lines = t182Lines(T182_ITEMS)
  const r = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 190,
    planText: t182PlanText(),
    simulate: {
      prBody: t183Body(lines),
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [lines[1]], boxes: t183Boxes(true, false, true) }],
    },
  })
  const p = String(r.prBodyPreview || '')
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = includes('box 1 ticked', p, '- [x] <!-- ac:1 --> ' + T182_ITEMS[0].text)
  const e3 = includes('the gate stays open, tag and text intact', p, lines[1])
  const e4 = includes('box 3 ticked', p, '- [x] <!-- ac:3 --> ' + T182_ITEMS[2].text)
  const e5 = eq('ticked boxes in the body', p.split('- [x] ').length - 1, 2)
  const e6 = includes('trace', r.trace || [], 'acceptance-ticked:0')
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T183e a refused tick returns verified-untickable with the box ids in untickableItems', async () => {
  const lines = t182Lines(T183_PLAIN)
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }],
      acceptanceSync: false,
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('untickableItems ids', (r.untickableItems || []).map((i) => i.id), [1, 2, 3])
  const e3 = eq('untickableItems lines', (r.untickableItems || []).map((i) => i.item), lines)
  const e4 = eq('resumable', r.resumable, true)
  const e5 = includes('trace', r.trace || [], 'acceptance-tick-refused:0')
  return e1 || e2 || e3 || e4 || e5 || nickTrace(r) || { ok: true }
})

await testCase('T183f a human gate is told by its id, not by a [human-gate] tag in Morgan\'s line', async () => {
  const untagged = '- [ ] <!-- ac:2 --> ' + T182_ITEMS[1].text
  const r = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T182_ITEMS) }, morgan: [{ verdict: 'REQUIRED_CHANGES', items: [untagged] }] } })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('humanGateItems.length', r.humanGateItems?.length, 1)
  // Control: the tag alone, on a line with no id comment, is no gate. It is a code blocker (Nick round, then LGTM).
  const tagOnly = '- [ ] [human-gate] ' + T182_ITEMS[1].text
  const c = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T182_ITEMS) }, prBody: t182GateTickedBody(), morgan: [{ verdict: 'REQUIRED_CHANGES', items: [tagOnly] }, { verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] } })
  const e3 = eq('control: status', c.status, 'ready')
  const e4 = c.humanGateItems === undefined ? null : { ok: false, msg: 'control: a tag without an id was taken for a human gate' }
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T183g a refused tick + an open human gate → ready-pending-human carrying humanGateItems and untickableItems', async () => {
  const lines = t182Lines(T182_ITEMS)
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T182_ITEMS) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [lines[1]], boxes: t183Boxes(true, false, true) }],
      acceptanceSync: false,
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('humanGateItems', r.humanGateItems, [lines[1]])
  const e3 = eq('untickableItems ids', (r.untickableItems || []).map((i) => i.id), [1, 3])
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T183h an LGTM with a non-gate box not proven is forced to REQUIRED_CHANGES, then ready once every box is proven', async () => {
  const lines = t182Lines(T183_PLAIN)
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [
        { verdict: 'LGTM', boxes: t183Boxes(true, false, true) },
        { verdict: 'LGTM', boxes: t183Boxes(true, true, true) },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 1)
  const e3 = includes('trace', r.trace || [], 'acceptance-open-lgtm:0')
  // The unproven box is what the first round blocks on: with a single verdict it is the REQUIRED_CHANGES items (gate(review) pauses a semi run).
  const s = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 190,
    planText: t182Sam(T183_PLAIN).plan,
    simulate: { morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, false, true) }] },
  })
  const e4 = eq('semi: status', s.status, 'needs-revision')
  const e5 = eq('semi: items', s.items, [lines[1]])
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

await testCase('T183i the same id reworded in two rounds is the same blocker → escalate no-progress; two different ids loop', async () => {
  const mk = (n, text) => `- [ ] <!-- ac:${n} --> ${text}`
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [mk(1, 'Fix URL validation regex')] },
        { verdict: 'REQUIRED_CHANGES', items: [mk(1, 'the url validation still rejects a valid host')] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'no-progress')
  const c = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [mk(1, 'fix A')] },
        { verdict: 'REQUIRED_CHANGES', items: [mk(2, 'fix B')] },
        { verdict: 'LGTM', boxes: t183Boxes(true, true, true) },
      ],
    },
  })
  const e3 = eq('control: status', c.status, 'ready')
  const e4 = eq('control: rounds', c.rounds, 2)
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T183j a checklist-wording blocker on an id is parked (CP-9): verified-untickable, no Nick round; an empty proof is a code blocker', async () => {
  const items = T183_PLAIN.slice(0, 2)
  const lines = t182Lines(items)
  const owner = (proof) => ({ item: lines[0], itemOwner: 'checklist-wording-defect', proof })
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(items) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [lines[0]], boxes: t183Boxes(false, true), itemOwners: [owner('$ grep -c FOO file\n2')] }],
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('untickableItems[0].id', r.untickableItems?.[0]?.id, 1)
  const e3 = eq('untickableItems[0].item', r.untickableItems?.[0]?.item, lines[0])
  const c = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(items) },
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [lines[0]], boxes: t183Boxes(false, true), itemOwners: [owner('')] }, { verdict: 'LGTM' }],
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e4 = eq('control: status', c.status, 'escalate')
  const e5 = eq('control: reason', c.reason, 'nick-no-op')
  return e1 || e2 || e3 || nickTrace(r) || e4 || e5 || { ok: true }
})

await testCase('T183k source: the normalisation and the textual gates are gone; Morgan is told the workflow ticks', async () => {
  const src = SUITE_ARGS.fpSource
  const fns = t182Block()
  if (!src || !fns) return t182Skip('T183k')
  const banned = ['normItem', 'HUMAN_GATE_RE', 'isHumanGate', 'allHumanGate', 'classifyUntickable', 'UNTICKABLE_LINE_RULE', 'proven-untickable']
  const present = banned.filter((w) => src.includes(w))
  const e1 = present.length ? { ok: false, msg: `the engine still holds ${JSON.stringify(present)}` } : null
  const note = fns.morganBoxesNote(t182Lines(T182_ITEMS).join('\n'))
  const e2 = includes('Morgan note: the workflow ticks', note, 'the workflow ticks by id the boxes you return as proven')
  const e3 = includes('Morgan note: Morgan does not edit the body', note, 'You do not edit the PR body')
  const e4 = includes('Morgan note: a gate is proven only when a person checked it', note, 'only when the PR body already shows it checked by a person')
  return e1 || e2 || e3 || e4 || { ok: true }
})

// ---------------------------------------------------------------------------
// #183 — review round: the tick keeps what it does not own, reads Morgan's boxes strictly, and says why it was refused
// ---------------------------------------------------------------------------
// Each case below was written red against the first #183 implementation (PR #198, review), then made green. Defects
// are the reviewer's: F1 lines Nick added to the block, F2 fenced marker examples, F3 LGTM without `boxes`, F4 ids
// renumbered by an amendment, F6 a proof-less "proven", F7 unproven boxes hidden by a refused tick, F8 a box a person
// already ticked, F9 the reason of a refused write, F10 a rejected artifact proof naming no box, F12 CRLF bodies, F13
// contradicting duplicate ids.
const t183Splice = () => {
  const src = SUITE_ARGS.fpSource
  if (!src) return null
  const block = extractBetween(src, '// --- prBodySplice:start ---', '// --- prBodySplice:end ---')
  if (!block) throw new Error('prBodySplice:start/:end markers not found in the pipeline source')
  // eslint-disable-next-line no-new-func
  return new Function(block + '\nreturn { spliceAcceptanceBlock, tickAcceptanceBlock, checkedAcceptanceIds, spliceDecisionLogBlock, decisionLogEntries, composeDecisionLogBlock }')()
}

// ---------------------------------------------------------------------------
// #164 — the decision log: ONE block per body whose rounds accumulate across review runs, and a round with only
// human-gate boxes open reads `pending human gate`, not REQUIRED_CHANGES
// ---------------------------------------------------------------------------
const DL_START = '<!-- decision-log:start -->'
const DL_END = '<!-- decision-log:end -->'

await testCase('T164a two review runs leave ONE decision-log pair holding both runs\' rounds', async () => {
  const body0 = PR385_BODY_REAL + DL_START + '\n' + DL_END + '\n'
  const r1 = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }], prBody: body0 } })
  const r2 = await run({ mode: 'auto', entryStage: 'review', prNumber: 190, simulate: { branchCheckRaw: 'features/issue-1', morgan: [{ verdict: 'LGTM' }], prBody: r1.prBodyPreview } })
  const body = String(r2.prBodyPreview || '')
  const lines = ['- round 0 — REQUIRED_CHANGES (1 blocker)', '- round 1 — LGTM', '- round 2 — LGTM']
  const e1 = eq('run 1 log', r1.decisionLog, lines.slice(0, 2))
  const e2 = eq('run 1 carries nothing', (r1.trace || []).filter((t) => String(t).startsWith('decision-log-carried')), [])
  const e3 = eq('run 2 status', r2.status, 'ready')
  const e4 = eq('start markers', countOccurrences(body, DL_START), 1)
  const e5 = eq('end markers', countOccurrences(body, DL_END), 1)
  const e6 = eq('both runs\' rounds inside the one block, in order', body.slice(body.indexOf(DL_START), body.indexOf(DL_END)).split('\n').filter((l) => l.startsWith('- round ')), lines)
  const e7 = eq('run 2 log', r2.decisionLog, lines)
  const e8 = includes('run 2 trace', r2.trace, 'decision-log-carried:2')
  const e9 = eq('acceptance block untouched', countUncheckedBoxes(body), countUncheckedBoxes(PR385_BODY_REAL))
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || { ok: true }
})

await testCase('T164b a round whose only open boxes are human gates logs pending human gate', async () => {
  const gate = { text: 'the maintainer reads the rendered page and posts approval', humanGate: true }
  const gate2 = { text: 'the maintainer confirms the second render', humanGate: true }
  const real = { text: '`grep -c FOO file` prints `1`', humanGate: false }
  const accBody = (items) => 'Closes #164\n\n<!-- acceptance:start -->\n' + t182Lines(items).join('\n') + '\n<!-- acceptance:end -->\n' + DL_START + '\n' + DL_END + '\n'
  // (i) the T18 shape: one gate -> pending human gate, never REQUIRED_CHANGES, in the log and in the body
  const a = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam([gate]) }, morgan: [{ verdict: 'REQUIRED_CHANGES', items: t182Lines([gate]) }], prBody: accBody([gate]) } })
  const e1 = eq('(i) status', a.status, 'ready-pending-human')
  const e2 = eq('(i) log', a.decisionLog, ['- round 0 — pending human gate (1 box)'])
  const e3 = includes('(i) body', String(a.prBodyPreview || ''), '- round 0 — pending human gate (1 box)')
  const e4 = eq('(i) no REQUIRED_CHANGES in the body block', String(a.prBodyPreview || '').split(DL_START)[1].includes('REQUIRED_CHANGES'), false)
  // (ii) the T19 shape: a gate and a real blocker, then the gate alone
  const l2 = t182Lines([gate, real])
  const b = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam([gate, real]) }, morgan: [{ verdict: 'REQUIRED_CHANGES', items: [l2[0], l2[1]] }, { verdict: 'REQUIRED_CHANGES', items: [l2[0]] }] } })
  const e5 = eq('(ii) status', b.status, 'ready-pending-human')
  const e6 = eq('(ii) log', b.decisionLog, ['- round 0 — REQUIRED_CHANGES (2 blockers)', '- round 1 — pending human gate (1 box)'])
  // (iii) two gates in one round
  const c = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam([gate, gate2]) }, morgan: [{ verdict: 'REQUIRED_CHANGES', items: t182Lines([gate, gate2]) }] } })
  const e7 = eq('(iii) log', c.decisionLog, ['- round 0 — pending human gate (2 boxes)'])
  // (iv) control: a non-gate item still reads REQUIRED_CHANGES
  const d = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }] } })
  const e8 = eq('(iv) log', d.decisionLog, ['- round 0 — REQUIRED_CHANGES (1 blocker)', '- round 1 — LGTM'])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || { ok: true }
})

await testCase('T164c block level: an indented end marker keeps one block, the entries reader', async () => {
  const fns = t183Splice()
  if (!fns) return t182Skip('T164c')
  // The shape of PR #146's body: the start marker at column 0, the heading, the rounds and the end marker indented.
  const pr146 = 'Closes #146\n\n## What this ships\n- x\n\n' + DL_START + '\n  ## Decision log\n  - round 0 — REQUIRED_CHANGES (1 blocker)\n  - round 1 — LGTM\n  ' + DL_END + '\n'
  const out = fns.spliceDecisionLogBlock(pr146, fns.composeDecisionLogBlock(['- round 0 — a', '- round 1 — b', '- round 2 — c']))
  const e1 = eq('one start marker', countOccurrences(out, DL_START), 1)
  const e2 = eq('one end marker', countOccurrences(out, DL_END), 1)
  const e3 = includes('new lines', out, '- round 2 — c\n' + DL_END)
  const e4 = eq('old lines gone', out.includes('REQUIRED_CHANGES'), false)
  const e5 = eq('entries of the indented shape, trimmed', fns.decisionLogEntries(pr146), ['- round 0 — REQUIRED_CHANGES (1 blocker)', '- round 1 — LGTM'])
  const e6 = eq('entries of a fenced example only', fns.decisionLogEntries(FENCED_EXAMPLE_BODY), [])
  const e7 = eq('entries of an empty body', fns.decisionLogEntries(''), [])
  // A fenced example AFTER the real column-0 block is never taken for the end of a block that has its own.
  const after = 'x\n\n' + DL_START + '\n- round 0 — LGTM\n' + DL_END + '\n\n```\n  ' + DL_START + '\n  - round 9 — example\n  ' + DL_END + '\n```\n'
  const e8 = eq('real block entries with a fenced example after it', fns.decisionLogEntries(after), ['- round 0 — LGTM'])
  const e9 = eq('the example after is untouched by a splice', fns.spliceDecisionLogBlock(after, fns.composeDecisionLogBlock(['- round 0 — LGTM', '- round 1 — LGTM'])).includes('  - round 9 — example'), true)
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || { ok: true }
})

// The shape of PR #146's body: three decision-log blocks (start at column 0, end marker indented), text between them and an
// acceptance block, the rounds of the three runs 0, 1 and 2 in body order.
const DL_ACC = '<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> a box\n<!-- acceptance:end -->'
const dlIndented = (line) => DL_START + '\n  ## Decision log\n  ' + line + '\n  ' + DL_END
const PR146_BODY = 'Closes #146\n\n## What this ships\n- x\n\n' + dlIndented('- round 0 — REQUIRED_CHANGES (1 blocker)') +
  '\n\nmiddle text\n\n' + dlIndented('- round 1 — REQUIRED_CHANGES (2 blockers)') + '\n\n## Acceptance checklist\n' + DL_ACC + '\n\n' +
  dlIndented('- round 2 — LGTM') + '\n'
const PR146_ROUNDS = ['- round 0 — REQUIRED_CHANGES (1 blocker)', '- round 1 — REQUIRED_CHANGES (2 blockers)', '- round 2 — LGTM']
// The body PR146_BODY once the three blocks are one, the new block `block` at the place of the last: every line outside the
// blocks, byte for byte, in its order.
const pr146Outside = (block) => 'Closes #146\n\n## What this ships\n- x\n\n' + '\nmiddle text\n\n' + '\n## Acceptance checklist\n' + DL_ACC + '\n\n' + block + '\n'

await testCase('T164d block level: a body with 2 or 3 decision-log blocks collapses to ONE pair, the rounds of all blocks in body order', async () => {
  const fns = t183Splice()
  if (!fns) return t182Skip('T164d')
  const block = fns.composeDecisionLogBlock([...PR146_ROUNDS, '- round 3 — LGTM'])
  const out = fns.spliceDecisionLogBlock(PR146_BODY, block)
  const e1 = eq('entries of the 3 blocks, in body order', fns.decisionLogEntries(PR146_BODY), PR146_ROUNDS)
  const e2 = eq('one start marker', countOccurrences(out, DL_START), 1)
  const e3 = eq('one end marker', countOccurrences(out, DL_END), 1)
  const e4 = eq('the outside text is byte-identical, the new block at the place of the last', out, pr146Outside(block))
  const e5 = eq('the acceptance block untouched', out.includes(DL_ACC), true)
  const e6 = eq('idempotent: the same splice again', fns.spliceDecisionLogBlock(out, block), out)
  // Two blocks, column-0 end markers.
  const two = 'a\n\n' + fns.composeDecisionLogBlock(['- round 0 — x']) + '\n\nb\n\n' + fns.composeDecisionLogBlock(['- round 1 — y']) + '\n'
  const block2 = fns.composeDecisionLogBlock(['- round 0 — x', '- round 1 — y', '- round 2 — z'])
  const e7 = eq('2 blocks: entries', fns.decisionLogEntries(two), ['- round 0 — x', '- round 1 — y'])
  const e8 = eq('2 blocks: one pair, outside text kept', fns.spliceDecisionLogBlock(two, block2), 'a\n\n\nb\n\n' + block2 + '\n')
  // A fenced example before the real blocks is not one of them.
  const fenced = fns.decisionLogEntries('```\n  ' + DL_START + '\n  - round 9 — example\n  ' + DL_END + '\n```\n' + PR146_BODY)
  const e9 = eq('a fenced example before the blocks is not carried', fenced, PR146_ROUNDS)
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || { ok: true }
})

await testCase('T164e a relaunch at entryStage review on the 3-block body ends with exactly one marker pair holding every round', async () => {
  const body = PR385_BODY_REAL + PR146_BODY
  const r = await run({ mode: 'auto', entryStage: 'review', prNumber: 146, simulate: { branchCheckRaw: 'features/issue-1', morgan: [{ verdict: 'LGTM' }], prBody: body } })
  const out = String(r.prBodyPreview || '')
  const lines = [...PR146_ROUNDS, '- round 3 — LGTM']
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('start markers', countOccurrences(out, DL_START), 1)
  const e3 = eq('end markers', countOccurrences(out, DL_END), 1)
  const e4 = eq('every round inside the one block, in order', out.slice(out.indexOf(DL_START), out.indexOf(DL_END)).split('\n').filter((l) => l.startsWith('- round ')), lines)
  const e5 = eq('log', r.decisionLog, lines)
  const e6 = includes('trace', r.trace, 'decision-log-carried:3')
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

// An unreadable prior block must never replace an existing one with a shorter one: with no prior read the run writes no
// decision-log block, leaves a trace token and keeps going. The flow suite cannot make the body unreadable while it exists, so the
// unreadable read is simulate.probes.prBody null (the body the read could not get); the run's own log is still returned.
await testCase('T164f no prior read of the decision log (unreadable body): no block written, a trace token, the run goes on', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'LGTM' }], prBody: null } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('no body written for the decision log', r.prBodyPreview, null)
  const e3 = eq('trace token, once', (r.trace || []).filter((t) => String(t).startsWith('decision-log-skipped')), ['decision-log-skipped:no-prior-read'])
  const e4 = eq('the run\'s own log is still returned', r.decisionLog, ['- round 0 — REQUIRED_CHANGES (1 blocker)', '- round 1 — LGTM'])
  // Control: a readable body is written (no token).
  const c = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], prBody: PR385_BODY_REAL } })
  const e5 = eq('control: no token', (c.trace || []).filter((t) => String(t).startsWith('decision-log-skipped')), [])
  const e6 = includes('control: block written', String(c.prBodyPreview || ''), '- round 0 — LGTM')
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

// M12: the wording `pending human gate` follows the same condition as the status ready-pending-human: a REQUIRED_CHANGES verdict
// whose open lines are all human gates. A regression verdict with only gate lines open is a regression, not a pending gate.
await testCase('T164g a regression verdict with only human-gate lines open does not read pending human gate', async () => {
  const gate = { text: 'the maintainer reads the rendered page and posts approval', humanGate: true }
  const lines = t182Lines([gate])
  const r = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam([gate]) }, morgan: [{ verdict: 'REGRESSION_DETECTED', items: lines }, { verdict: 'REQUIRED_CHANGES', items: lines }] } })
  const e1 = eq('log', r.decisionLog, ['- round 0 — REGRESSION_DETECTED (1 blocker)', '- round 1 — pending human gate (1 box)'])
  return e1 || { ok: true }
})

const T183_L3 = t182Lines(T183_PLAIN)
const T183_R2_LINE = '- [ ] fixture `fixtures/incidents/1-*.json` present, replayed red on the base and green on the branch by `scripts/run-offline.cjs`'
// A semi review of PR #190 on the 3 plain boxes, the body and Morgan's verdicts given.
const t183Review = (simulate, extra = {}) => run({ mode: 'semi', entryStage: 'review', prNumber: 190, planText: t182Sam(T183_PLAIN).plan, simulate, ...extra })
const t183Ticked = (p) => p.split('\n').filter((l) => l.startsWith('- [x] '))

await testCase('T183l a line Nick added to the acceptance block (no id) survives the tick, untouched and never ticked', async () => {
  const r = await t183Review({ prBody: t183Body([...T183_L3, T183_R2_LINE]), morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
  const p = String(r.prBodyPreview || '')
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('the 3 id boxes ticked', t183Ticked(p).length, 3)
  const e3 = eq('the extra line, open, once, after the rendered lines', p.split('\n').filter((l) => l === T183_R2_LINE), [T183_R2_LINE])
  const e4 = eq('order: rendered lines then the extra line', p.indexOf(T183_R2_LINE) > p.indexOf('- [x] <!-- ac:3 -->'), true)
  // Control: a line a person already ticked stays ticked.
  const c = await t183Review({ prBody: t183Body([...T183_L3, '- [x] a note a person ticked']), morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
  const e5 = includes('control: a ticked id-less line stays ticked', String(c.prBodyPreview || ''), '\n- [x] a note a person ticked\n')
  // The same at the block level (the engine block is the one pr-body-splice.cjs carries).
  const fns = t183Splice()
  if (!fns) return t182Skip('T183l')
  const out = fns.tickAcceptanceBlock(t183Body([...T183_L3, T183_R2_LINE]), T183_L3.join('\n'), [1, 2, 3], [])
  const e6 = includes('block level', out, '- [x] <!-- ac:3 --> ' + T183_PLAIN[2].text + '\n' + T183_R2_LINE + '\n<!-- acceptance:end -->')
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T183m marker pairs inside a fenced code block are ignored, before or after the real block: the real block is the one ticked', async () => {
  const fence = '```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n'
  const real = '<!-- acceptance:start -->\n' + T183_L3.join('\n') + '\n<!-- acceptance:end -->\n'
  const shapes = {
    before: 'Closes #183\n\n' + fence + '\n' + real,
    after: 'Closes #183\n\n' + real + '\n' + fence,
    both: 'Closes #183\n\n' + fence + '\n' + real + '\n' + fence,
  }
  for (const [name, body] of Object.entries(shapes)) {
    const r = await t183Review({ prBody: body, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
    const p = String(r.prBodyPreview || '')
    const e1 = eq(name + ': status', r.status, 'ready')
    const e2 = eq(name + ': the 3 real boxes ticked', t183Ticked(p).length, 3)
    const e3 = includes(name + ': the example is intact', p, fence)
    if (e1 || e2 || e3) return e1 || e2 || e3
  }
  const fns = t183Splice()
  if (!fns) return t182Skip('T183m')
  const e4 = eq('splice acceptance: the real block replaced, the example intact', fns.spliceAcceptanceBlock(shapes.both, '- [ ] <!-- ac:1 --> new'),
    'Closes #183\n\n' + fence + '\n<!-- acceptance:start -->\n- [ ] <!-- ac:1 --> new\n<!-- acceptance:end -->\n\n' + fence)
  const e5 = eq('a body whose only pair is fenced has no block', fns.tickAcceptanceBlock('x\n' + fence, T183_L3.join('\n'), [1], []), null)
  return e4 || e5 || { ok: true }
})

await testCase('T183n an LGTM without `boxes` is an LGTM with no box proven: needs-revision, every box blocks', async () => {
  const absent = await t183Review({ prBody: t183Body(T183_L3), morgan: [{ verdict: 'LGTM' }] })
  const empty = await t183Review({ prBody: t183Body(T183_L3), morgan: [{ verdict: 'LGTM', boxes: [] }] })
  const e1 = eq('absent: status', absent.status, 'needs-revision')
  const e2 = eq('absent: items', absent.items, T183_L3)
  const e3 = eq('absent: trace', (absent.trace || []).filter((t) => /^(boxes-|acceptance-)/.test(String(t))), ['boxes-missing:1', 'boxes-missing:2', 'boxes-missing:3', 'acceptance-open-lgtm:0'])
  const e4 = eq('same trace as boxes: []', (empty.trace || []).filter((t) => /^(boxes-|acceptance-)/.test(String(t))), (absent.trace || []).filter((t) => /^(boxes-|acceptance-)/.test(String(t))))
  const e5 = eq('same items as boxes: []', empty.items, absent.items)
  const e6 = eq('no box ticked', t183Ticked(String(absent.prBodyPreview || '')), [])
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T183o a plan amendment resets the blocker history: a different box now carrying the old id is not the same blocker', async () => {
  const A = [{ text: '`a` exits 0', humanGate: false }, { text: '`b` exits 0 (wording wrong)', humanGate: false }, { text: '`c` exits 0', humanGate: false }]
  const B = [{ text: '`b` exits 0', humanGate: false }, { text: '`c` exits 0', humanGate: false }, { text: '`d` exits 0', humanGate: false }]
  const la = t182Lines(A)
  const lb = t182Lines(B)
  const r = await run({
    mode: 'auto',
    maxPlanAmendRounds: 1,
    simulate: {
      sam: { 1: t182Sam(A), 2: { ...t182Sam(B), decision: 'GO' } },
      planCheck: T182_CONFORMING,
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [la[1]], boxes: t183Boxes(true, false, true), itemOwners: [{ item: la[1], itemOwner: 'checklist-wording-defect', proof: 'the box says (wording wrong) and the command passes' }] },
        { verdict: 'REQUIRED_CHANGES', items: [lb[1]], boxes: t183Boxes(true, false, true) },
        { verdict: 'LGTM', boxes: t183Boxes(true, true, true) },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = includes('the amendment happened', r.trace || [], 'plan-amend-round:1')
  // Control: with no amendment between them, the same id in two rounds is still the same blocker.
  const c = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(A) }, morgan: [{ verdict: 'REQUIRED_CHANGES', items: [la[1]] }, { verdict: 'REQUIRED_CHANGES', items: [la[1]] }] } })
  const e3 = eq('control: status', c.status, 'escalate')
  const e4 = eq('control: reason', c.reason, 'no-progress')
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T183p a box is proven only with a proof: proven:true with an empty, blank or absent proof is not ticked, whatever the verdict', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T183p')
  const items = fns.numberItems(T183_PLAIN)
  const m = fns.mapBoxes(items, [{ id: 1, proven: true, proof: '' }, { id: 2, proven: true }, { id: 3, proven: true, proof: '   \n' }])
  const e1 = eq('mapBoxes: none proven', m.boxes.map((b) => b.proven), [false, false, false])
  const ok = fns.mapBoxes(items, [{ id: 1, proven: true, proof: 'exit 0' }])
  const e2 = eq('mapBoxes control: a real proof is proven', ok.boxes.map((b) => [b.id, b.proven, b.proof]), [[1, true, 'exit 0']])
  const r = await t183Review({ prBody: t183Body(T183_L3), morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: '' }, { id: 2, proven: true }, { id: 3, proven: true, proof: '   ' }] }] })
  const e3 = eq('flow: status', r.status, 'needs-revision')
  const e4 = eq('flow: items', r.items, T183_L3)
  const e5 = eq('flow: no box ticked', t183Ticked(String(r.prBodyPreview || '')), [])
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

await testCase('T183q unproven boxes are judged before the tick: a refused tick no longer hides them (needs-revision, or ready-pending-human for a gate)', async () => {
  // A non-gate box not proven, the others proven, the tick refused: the box blocks, the run is no verified-untickable.
  const y = await t183Review({ prBody: t183Body(T183_L3), acceptanceSync: false, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, false, true) }] })
  const e1 = eq('semi: status', y.status, 'needs-revision')
  const e2 = eq('semi: items start with the unproven box', (y.items || [])[0], T183_L3[1])
  const e3 = includes('semi: trace', y.trace || [], 'acceptance-open-lgtm:0')
  // Auto: the Nick round happens for the unproven box; only when everything is proven does the refusal park the run.
  const lines = T183_L3
  const a = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      acceptanceSync: false,
      morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, false, true) }, { verdict: 'LGTM', boxes: t183Boxes(true, true, true) }],
    },
  })
  const e4 = eq('auto: status', a.status, 'verified-untickable')
  const e5 = eq('auto: one Nick round happened for the unproven box', a.round, 1)
  const e6 = eq('auto: untickableItems', (a.untickableItems || []).map((i) => i.item), lines)
  // A human gate not proven, the tick refused: ready-pending-human carrying the gate and the proven boxes.
  const g = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T182_ITEMS) }, acceptanceSync: false, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, false, true) }] } })
  const e7 = eq('gate: status', g.status, 'ready-pending-human')
  const e8 = eq('gate: humanGateItems', g.humanGateItems, [t182Lines(T182_ITEMS)[1]])
  const e9 = eq('gate: untickableItems ids', (g.untickableItems || []).map((i) => i.id), [1, 3])
  // Everything proven and the write refused is still verified-untickable (T183e), with the box 2 REQUIRED_CHANGES form too.
  const p = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T183_PLAIN) }, acceptanceSync: false, morgan: [{ verdict: 'REQUIRED_CHANGES', items: [lines[1]], boxes: t183Boxes(true, false, true) }, { verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] } })
  const e10 = eq('all proven last: status', p.status, 'verified-untickable')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || { ok: true }
})

await testCase('T183r a box ticked in the body but absent from Morgan\'s boxes is missing, not settled: the tick reopens it and an LGTM blocks on it', async () => {
  // Whoever ticked it (the Lead by hand, Morgan out of habit, the engine at an earlier round), only a proof returned in THIS round settles a box.
  const body = t183Body(['- [x] ' + T183_L3[0].slice(6), T183_L3[1], T183_L3[2]])
  const r = await t183Review({ prBody: body, morgan: [{ verdict: 'LGTM', boxes: [{ id: 2, proven: true, proof: 'p2' }, { id: 3, proven: true, proof: 'p3' }] }] })
  const p = String(r.prBodyPreview || '')
  const e1 = eq('status', r.status, 'needs-revision')
  const e2 = eq('items: the box returned by no one', r.items, [T183_L3[0]])
  const e3 = includes('boxes-missing:1', r.trace || [], 'boxes-missing:1')
  const e4 = includes('box 1 reopened', p, '- [ ] <!-- ac:1 --> ' + T183_PLAIN[0].text)
  const e5 = eq('boxes 2 and 3 ticked', t183Ticked(p).length, 2)
  // REQUIRED_CHANGES form: the same, for every box she returned nothing for.
  const w = await t183Review({ prBody: body, morgan: [{ verdict: 'REQUIRED_CHANGES', items: [T183_L3[1]], boxes: [{ id: 3, proven: true, proof: 'p3' }] }] })
  const wp = String(w.prBodyPreview || '')
  const e6 = includes('REQUIRED_CHANGES: box 1 reopened', wp, '- [ ] <!-- ac:1 --> ')
  const e7 = eq('REQUIRED_CHANGES: boxes-missing 1 and 2', (w.trace || []).filter((t) => String(t).startsWith('boxes-missing')), ['boxes-missing:1', 'boxes-missing:2'])
  // Control: the box open in the body and returned by no one is missing too.
  const c = await t183Review({ prBody: t183Body(T183_L3), morgan: [{ verdict: 'LGTM', boxes: [{ id: 2, proven: true, proof: 'p2' }, { id: 3, proven: true, proof: 'p3' }] }] })
  const e8 = eq('control: status', c.status, 'needs-revision')
  const e9 = includes('control: boxes-missing:1', c.trace || [], 'boxes-missing:1')
  // A box Morgan explicitly says is not proven is reopened even when the body shows it ticked.
  const u = await t183Review({ prBody: body, morgan: [{ verdict: 'REQUIRED_CHANGES', items: [T183_L3[0]], boxes: t183Boxes(false, true, true) }] })
  const e10 = includes('explicitly unproven: reopened', String(u.prBodyPreview || ''), '- [ ] <!-- ac:1 --> ')
  // Every box returned and proven settles it, whatever the body showed.
  const k = await t183Review({ prBody: body, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
  const e11 = eq('all returned and proven: ready', k.status, 'ready')
  // The block-level helper: ids of a body that are ticked.
  const fns = t183Splice()
  if (!fns) return t182Skip('T183r')
  const e12 = eq('checkedAcceptanceIds', fns.checkedAcceptanceIds(body), [1])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || e11 || e12 || { ok: true }
})

await testCase('T183s a refused tick carries the probe reason (tickReason) and a stale-read is retried once before parking', async () => {
  const sims = (acceptanceSync) => ({ sam: { 1: t182Sam(T183_PLAIN) }, acceptanceSync, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
  // A refusal that is not a stale read: no retry, the reason is in the result and the trace.
  const w = await run({ mode: 'auto', simulate: sims('write-failed') })
  const e1 = eq('write-failed: status', w.status, 'verified-untickable')
  const e2 = eq('write-failed: tickReason', w.tickReason, 'write-failed')
  const e3 = eq('write-failed: no retry', (w.trace || []).filter((t) => String(t).startsWith('acceptance-tick-retry')), [])
  const e4 = includes('write-failed: trace', w.trace || [], 'acceptance-tick-reason:write-failed')
  const n = await run({ mode: 'auto', simulate: sims('no-markers') })
  const e5 = eq('no-markers: tickReason', n.tickReason, 'no-markers')
  const f = await run({ mode: 'auto', simulate: sims(false) })
  const e6 = eq('refused (no reason given): status', f.status, 'verified-untickable')
  const e7 = eq('refused (no reason given): tickReason', f.tickReason, 'write-failed')
  // A stale read that stays stale: retried once, then parked with its reason.
  const s = await run({ mode: 'auto', simulate: sims(['stale-read', 'stale-read']) })
  const e8 = eq('stale twice: status', s.status, 'verified-untickable')
  const e9 = eq('stale twice: tickReason', s.tickReason, 'stale-read')
  const e10 = eq('stale twice: exactly one retry', (s.trace || []).filter((t) => String(t).startsWith('acceptance-tick-retry')), ['acceptance-tick-retry:0'])
  // A stale read the retry heals: the tick landed, the run is ready, no tickReason.
  const h = await run({ mode: 'auto', simulate: sims(['stale-read', true]) })
  const e11 = eq('stale then written: status', h.status, 'ready')
  const e12 = eq('stale then written: no tickReason', h.tickReason, undefined)
  const e13 = includes('stale then written: ticked', h.trace || [], 'acceptance-ticked:0')
  // A probe that gave no usable answer at all.
  const u = await run({ mode: 'auto', simulate: sims('probe-unavailable') })
  const e14 = eq('probe unavailable: tickReason', u.tickReason, 'probe-unavailable')
  // The reason also rides the semi needs-revision of a refused tick with an unproven box.
  const y = await t183Review({ prBody: t183Body(T183_L3), acceptanceSync: 'guard-failed-restored', morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, false, true) }] })
  const e15 = eq('needs-revision: tickReason', y.tickReason, 'guard-failed-restored')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || e11 || e12 || e13 || e14 || e15 || { ok: true }
})

await testCase('T212a a tick retried after a digest mismatch lands: ready, one retry, ticked', async () => {
  // The script refused the copied tick command before writing (#212): the retry reads the body afresh and ticks it.
  const r = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T183_PLAIN) }, acceptanceSync: ['cmd-mismatch', true], morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('no tickReason', r.tickReason, undefined)
  const e3 = eq('exactly one retry', (r.trace || []).filter((t) => String(t).startsWith('acceptance-tick-retry')), ['acceptance-tick-retry:0'])
  const e4 = includes('ticked', r.trace || [], 'acceptance-ticked:0')
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T212b a tick retried after a digest mismatch that repeats parks: verified-untickable, tickReason cmd-mismatch, one retry', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: { 1: t182Sam(T183_PLAIN) }, acceptanceSync: ['cmd-mismatch', 'cmd-mismatch'], morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] } })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('tickReason', r.tickReason, 'cmd-mismatch')
  const e3 = eq('exactly one retry', (r.trace || []).filter((t) => String(t).startsWith('acceptance-tick-retry')), ['acceptance-tick-retry:0'])
  const e4 = includes('refused trace', r.trace || [], 'acceptance-tick-reason:cmd-mismatch')
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T183t a rejected artifact proof that names no box ticks nothing this round; one that names a box un-proves only that box', async () => {
  const proof = (item) => [{ item, path: 'report.md', exists: false, mtime: '2026-01-02T00:00:00Z', bytes: 1 }]
  const none = await t183Review({ prBody: t183Body(T183_L3), artifactFloor: '2026-01-01T00:00:00Z', morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true), artifactProofs: proof('report.md was produced') }] })
  const e1 = eq('no box named: status', none.status, 'needs-revision')
  const e2 = eq('no box named: items', none.items, ['report.md was produced'])
  const e3 = eq('no box named: nothing ticked', t183Ticked(String(none.prBodyPreview || '')), [])
  const unknown = await t183Review({ prBody: t183Body(T183_L3), artifactFloor: '2026-01-01T00:00:00Z', morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true), artifactProofs: proof('- [ ] <!-- ac:9 --> no such box') }] })
  const e4 = eq('an id no box carries: nothing ticked', t183Ticked(String(unknown.prBodyPreview || '')), [])
  const named = await t183Review({ prBody: t183Body(T183_L3), artifactFloor: '2026-01-01T00:00:00Z', morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true), artifactProofs: proof(T183_L3[1]) }] })
  const e5 = eq('box 2 named: status', named.status, 'needs-revision')
  const e6 = eq('box 2 named: items', named.items, [T183_L3[1]])
  const e7 = eq('box 2 named: boxes 1 and 3 ticked', t183Ticked(String(named.prBodyPreview || '')).length, 2)
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || { ok: true }
})

await testCase('T183u a CRLF body keeps its line breaks through the tick and the splice, and a tick that changes nothing writes the same bytes', async () => {
  const fns = t183Splice()
  if (!fns) return t182Skip('T183u')
  const crlf = (s) => s.split('\n').join('\r\n')
  const rendered = T183_L3.join('\n')
  const body = crlf('x\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> ' + T183_PLAIN[0].text + '\n' + T183_L3[1] + '\n' + T183_L3[2] + '\n<!-- acceptance:end -->\ny\n')
  const e1 = eq('tick that changes nothing is byte-identical', fns.tickAcceptanceBlock(body, rendered, [1], []), body)
  const ticked = fns.tickAcceptanceBlock(body, rendered, [1, 2], [])
  const e2 = eq('a real tick: every line break of the output is CRLF', ticked.split('\r\n').join('').includes('\n'), false)
  const e3 = includes('a real tick ticked box 2', ticked, '- [x] <!-- ac:2 --> ')
  const spliced = fns.spliceAcceptanceBlock(body, '- [ ] <!-- ac:1 --> new\n- [ ] <!-- ac:2 --> new2')
  const e4 = eq('splice: every line break of the output is CRLF', spliced.split('\r\n').join('').includes('\n'), false)
  // An LF body stays LF.
  const lf = 'x\n<!-- acceptance:start -->\n' + rendered + '\n<!-- acceptance:end -->\n'
  const e5 = eq('LF body stays LF', fns.tickAcceptanceBlock(lf, rendered, [], []).includes('\r'), false)
  // An id-less line of a CRLF block survives with the body's line break.
  const withExtra = crlf('x\n<!-- acceptance:start -->\n' + rendered + '\n' + T183_R2_LINE + '\n<!-- acceptance:end -->\n')
  const e6 = eq('CRLF body with an extra line is stable', fns.tickAcceptanceBlock(withExtra, rendered, [], []), withExtra)
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T183v two entries for one id that contradict each other: the box is not proven', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T183v')
  const items = fns.numberItems(T183_PLAIN)
  const a = fns.mapBoxes(items, [{ id: 1, proven: true, proof: 'ok' }, { id: 1, proven: false, proof: '' }])
  const b = fns.mapBoxes(items, [{ id: 1, proven: false, proof: '' }, { id: 1, proven: true, proof: 'ok' }])
  const e1 = eq('proven then unproven', a.boxes.map((x) => [x.id, x.proven]), [[1, false]])
  const e2 = eq('unproven then proven', b.boxes.map((x) => [x.id, x.proven]), [[1, false]])
  const c = fns.mapBoxes(items, [{ id: 1, proven: true, proof: 'ok' }, { id: 1, proven: true, proof: 'again' }])
  const e3 = eq('control: two agreeing entries', c.boxes.map((x) => [x.id, x.proven]), [[1, true]])
  const r = await t183Review({ prBody: t183Body(T183_L3), morgan: [{ verdict: 'LGTM', boxes: [{ id: 1, proven: true, proof: 'ok' }, { id: 1, proven: false }, { id: 2, proven: true, proof: 'p' }, { id: 3, proven: true, proof: 'p' }] }] })
  const e4 = eq('flow: status', r.status, 'needs-revision')
  const e5 = eq('flow: boxes 2 and 3 ticked, 1 open', t183Ticked(String(r.prBodyPreview || '')).length, 2)
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

await testCase('T183w in an id run Morgan is told she ticks nothing and LGTM needs every box proven; the run without ids keeps its text', async () => {
  const src = SUITE_ARGS.fpSource
  const fns = t182Block()
  if (!src || !fns) return t182Skip('T183w')
  const idRule = fns.morganItemsRule(t182Lines(T182_ITEMS).join('\n'))
  const e1 = includes('id run: Morgan ticks nothing', idRule, 'you tick none')
  const e2 = includes('id run: an entry for EACH box, an already ticked one included', idRule, 'one entry for EACH box, including a box that already reads [x] in the PR body')
  const e2b = idRule.includes('every box reads [ ]') ? { ok: false, msg: 'the id-run rule still says every box reads [ ] when Morgan reads the body (false from round 1)' } : null
  const note = fns.morganBoxesNote(t182Lines(T182_ITEMS).join('\n'))
  const e2c = includes('boxes note: an entry for EVERY box, an already ticked one included', note, 'Return an entry for EVERY box above, including a box that already reads [x] in the PR body')
  const e3 = includes('id run: LGTM needs every box proven', idRule, 'LGTM only when EVERY box is proven')
  const legacy = fns.morganItemsRule('')
  const e4 = includes('no ids: the historical sentence', legacy, 'Emit `REQUIRED_CHANGES` whenever any box is unticked (human-gate or not). ')
  const e5 = eq('no ids: starts like it always did', legacy.startsWith('For each remaining unticked acceptance box, put in `items` the **verbatim checklist line** it blocks on'), true)
  const e6 = eq('both Morgan prompts interpolate the rule', src.split('${morganItemsRule(acceptanceBlock)}').length - 1, 2)
  const e7 = eq('the historical sentence is written once (in the rule)', src.split('Emit `REQUIRED_CHANGES` whenever any box is unticked').length - 1, 1)
  return e1 || e2 || e2b || e2c || e3 || e4 || e5 || e6 || e7 || { ok: true }
})

// The lines a block can hold besides the rendered id boxes (second review round, G1): the tick replaces ONLY the lines of an
// id box; each of these must come out as it went in, once, after the rendered lines, in the order it had.
const T183_FOREIGN = [
  'exception: skip lint -- migration pending -- #9',
  '- exception: skip lint -- migration pending -- #9',
  'Note: the migration plan is in the issue',
  '* [ ] x',
  '1. [ ] x',
  '-[ ] x',
  '- [ ] a box without an id',
  '- [X] a box without an id, ticked',
  '',
]

await testCase('T183x every line of the acceptance block that is not an id box survives the tick, in order, after the rendered lines', async () => {
  const fns = t183Splice()
  const crlf = (s) => s.split('\n').join('\r\n')
  for (const foreign of T183_FOREIGN) {
    const name = JSON.stringify(foreign)
    // Between the id boxes, so that "after the rendered lines" and "in the order it had" are both observable.
    const r = await t183Review({ prBody: t183Body([T183_L3[0], foreign, T183_L3[1], 'last: ' + foreign, T183_L3[2]]), morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
    const p = String(r.prBodyPreview || '')
    const e1 = eq(name + ': status', r.status, 'ready')
    const e2 = eq(name + ': the 3 id boxes ticked', t183Ticked(p).length, 3)
    const tail = '\n' + foreign + '\nlast: ' + foreign + '\n<!-- acceptance:end -->'
    const e3 = includes(name + ': the foreign lines, in order, right after the rendered lines', p, '- [x] <!-- ac:3 --> ' + T183_PLAIN[2].text + tail)
    const e4 = foreign === '' ? null : eq(name + ': the foreign line is not duplicated', p.split('\n' + foreign + '\n').length - 1, 1)
    if (e1 || e2 || e3 || e4) return e1 || e2 || e3 || e4
    if (!fns) continue
    // Block level: stable on a second pass, and the same over CRLF.
    const body = t183Body([T183_L3[0], foreign, T183_L3[1], 'last: ' + foreign, T183_L3[2]])
    const once = fns.tickAcceptanceBlock(body, T183_L3.join('\n'), [1, 2, 3], [])
    const e5 = eq(name + ': block level, the foreign lines kept after the rendered ones', once, 'Closes #183\n\n<!-- acceptance:start -->\n' + T183_L3.join('\n').split('- [ ] ').join('- [x] ') + tail + '\n')
    const e6 = eq(name + ': a second tick changes nothing', fns.tickAcceptanceBlock(once, T183_L3.join('\n'), [1, 2, 3], []), once)
    const c = crlf(body)
    const cOnce = fns.tickAcceptanceBlock(c, T183_L3.join('\n'), [1, 2, 3], [])
    const e7 = eq(name + ': CRLF: the output is the LF output with CRLF line breaks', cOnce, crlf(once))
    const e8 = eq(name + ': CRLF: a second tick changes nothing', fns.tickAcceptanceBlock(cOnce, T183_L3.join('\n'), [1, 2, 3], []), cOnce)
    if (e5 || e6 || e7 || e8) return e5 || e6 || e7 || e8
  }
  // Blank lines at the end of the block are lines too: kept, and a second pass changes nothing.
  if (fns) {
    const padded = t183Body([...T183_L3, '', ''])
    const once = fns.tickAcceptanceBlock(padded, T183_L3.join('\n'), [1, 2, 3], [])
    const e0 = eq('trailing blank lines kept', once, 'Closes #183\n\n<!-- acceptance:start -->\n' + T183_L3.join('\n').split('- [ ] ').join('- [x] ') + '\n\n\n<!-- acceptance:end -->\n')
    const e0b = eq('trailing blank lines: a second tick changes nothing', fns.tickAcceptanceBlock(once, T183_L3.join('\n'), [1, 2, 3], []), once)
    if (e0 || e0b) return e0 || e0b
  }
  // The same lines read by checkedAcceptanceIds: only an id box counts.
  if (!fns) return t182Skip('T183x')
  const ids = fns.checkedAcceptanceIds(t183Body(['- [x] <!-- ac:1 --> a', '- [x] a box without an id', 'exception: x', '- [x] <!-- ac:3 --> c']))
  return eq('checkedAcceptanceIds: only id boxes', ids, [1, 3]) || { ok: true }
})

await testCase('T183y a box settled at an earlier round is not settled again without a proof of this round (a tick of the engine, of Morgan or of the Lead)', async () => {
  // R1: round 0 proves boxes 1 and 2 (the engine ticks them), Nick pushes, round 1 returns only box 3: boxes 1 and 2 are missing.
  const r = await t183Review({
    prBody: t183Body(T183_L3),
    morgan: [
      { verdict: 'REQUIRED_CHANGES', items: [T183_L3[2]], boxes: t183Boxes(true, true, false) },
      { verdict: 'LGTM', boxes: [{ id: 3, proven: true, proof: 'p3' }] },
      { verdict: 'LGTM', boxes: t183Boxes(true, true, true) },
    ],
  }, { mode: 'auto' })
  const e1 = includes('R1: only the third round ticked the last boxes', r.trace || [], 'acceptance-ticked:2')
  const e2 = eq('R1: status', r.status, 'ready')
  const e3 = includes('R1: boxes 1 missing at round 1', r.trace || [], 'boxes-missing:1')
  const e4 = includes('R1: boxes 2 missing at round 1', r.trace || [], 'boxes-missing:2')
  const e5 = includes('R1: the LGTM of round 1 was refused', r.trace || [], 'acceptance-open-lgtm:1')
  // R1b: Morgan ticked everything herself (old habit) and answers LGTM with no boxes over a body already all [x].
  const allTicked = t183Body(T183_L3.map((l) => '- [x] ' + l.slice(6)))
  const b = await t183Review({ prBody: allTicked, morgan: [{ verdict: 'LGTM' }] })
  const e6 = eq('R1b: status', b.status, 'needs-revision')
  const e7 = eq('R1b: every box blocks', b.items, T183_L3)
  const e8 = eq('R1b: boxes-missing 1 2 3', (b.trace || []).filter((t) => String(t).startsWith('boxes-missing')), ['boxes-missing:1', 'boxes-missing:2', 'boxes-missing:3'])
  const e9 = eq('R1b: nothing stays ticked', t183Ticked(String(b.prBodyPreview || '')), [])
  // The mapping itself: a ticked box nobody returned is missing, whatever the body shows.
  const fns = t182Block()
  if (!fns) return t182Skip('T183y')
  const m = fns.mapBoxes(fns.numberItems(T183_PLAIN), [{ id: 3, proven: true, proof: 'p3' }], [1, 2, 3])
  const e10 = eq('mapBoxes: missing', m.missing, [1, 2])
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || { ok: true }
})

await testCase('T183z a human-gate box is settled by the body alone: ticked by a person, never by Morgan\'s proven', async () => {
  const gateLines = t182Lines(T182_ITEMS)
  const gate = (body, boxes, extra = {}) => run({ mode: 'semi', entryStage: 'review', prNumber: 190, planText: t182Sam(T182_ITEMS).plan, simulate: { prBody: t183Body(body), morgan: [{ verdict: 'LGTM', boxes }], ...extra } })
  const proof = (id) => ({ id, proven: true, proof: 'proof ' + id })
  // (a) The gate is open in the body and Morgan says proven: the gate is still open, ready-pending-human, never ready, never ticked.
  const a = await gate(gateLines, [proof(1), proof(2), proof(3)])
  const e1 = eq('(a) status', a.status, 'ready-pending-human')
  const e2 = eq('(a) humanGateItems', a.humanGateItems, [gateLines[1]])
  const e3 = includes('(a) the gate stays open', String(a.prBodyPreview || ''), gateLines[1])
  const e4 = eq('(a) boxes 1 and 3 ticked, the gate not', t183Ticked(String(a.prBodyPreview || '')).length, 2)
  const e4b = eq('(a) the gate box is not proven in the payload, whatever Morgan returned', (a.boxes || []).map((b) => [b.id, b.proven]), [[1, true], [2, false], [3, true]])
  // (b) The gate was ticked by a person: it is settled with an empty proof, with proven false, and with no entry at all.
  const ticked = [gateLines[0], '- [x] ' + gateLines[1].slice(6), gateLines[2]]
  const b1 = await gate(ticked, [proof(1), { id: 2, proven: true, proof: '' }, proof(3)])
  const e5 = eq('(b) empty proof: status', b1.status, 'ready')
  const e5b = eq('(b) empty proof: the gate box is proven in the payload', (b1.boxes || []).map((b) => [b.id, b.proven]), [[1, true], [2, true], [3, true]])
  const b2 = await gate(ticked, [proof(1), { id: 2, proven: false, proof: '' }, proof(3)])
  const e6 = eq('(b) proven false: status', b2.status, 'ready')
  const b3 = await gate(ticked, [proof(1), proof(3)])
  const e7 = eq('(b) no entry: status', b3.status, 'ready')
  const e8 = eq('(b) no entry: no boxes-missing for the gate', (b3.trace || []).filter((t) => String(t).startsWith('boxes-missing')), [])
  // (c) The gate was ticked by a person and Morgan returns a proof: ready, and the tick stays.
  const c = await gate(ticked, [proof(1), proof(2), proof(3)])
  const e9 = eq('(c) status', c.status, 'ready')
  const e10 = includes('(c) the gate stays ticked', String(c.prBodyPreview || ''), '- [x] <!-- ac:2 --> [human-gate] ')
  // (d) A non-gate box is still missing when the gate is settled: the gate does not stand for it.
  const d = await gate(ticked, [proof(1)])
  const e11 = eq('(d) status', d.status, 'needs-revision')
  const e12 = eq('(d) trace', (d.trace || []).filter((t) => String(t).startsWith('boxes-missing')), ['boxes-missing:3'])
  return e1 || e2 || e3 || e4 || e4b || e5 || e5b || e6 || e7 || e8 || e9 || e10 || e11 || e12 || { ok: true }
})

await testCase('T183za the fence scanner: tilde and longer fences, a fence inside the block, a fence never closed (the tick fails closed with no-markers)', async () => {
  const E = '<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n'
  const real = '<!-- acceptance:start -->\n' + T183_L3.join('\n') + '\n<!-- acceptance:end -->\n'
  const ticked3 = T183_L3.map((l) => '- [x] ' + l.slice(6)).join('\n')
  // The example comes AFTER the real block, so an unfenced reading of it would make it "the last pair" and the tick would hit it.
  const after = (fence) => 'Closes #183\n\n' + real + '\n' + fence + '\n'
  const shapes = {
    tilde: after('~~~\n' + E + '~~~'),
    'tilde, longer than 3': after('~~~~~\n' + E + '~~~~~'),
    '4 backticks holding a 3-backtick fence': after('````\n```\n' + E + '```\n````'),
    'backticks holding a tilde line': after('```\n~~~\n' + E + '```'),
    'tildes holding a backtick line': after('~~~\n```\n' + E + '~~~'),
    'indented by 3 spaces': after('   ```\n' + E + '   ```'),
    'never closed, after the block': after('```\n' + E.trimEnd()),
  }
  const fns = t183Splice()
  for (const [name, body] of Object.entries(shapes)) {
    const r = await t183Review({ prBody: body, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
    const p = String(r.prBodyPreview || '')
    const e1 = eq(name + ': status', r.status, 'ready')
    const e2 = eq(name + ': the 3 real boxes ticked', t183Ticked(p).length, 3)
    const e3 = includes(name + ': the example is intact', p, '<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->')
    const e4 = includes(name + ': the real block is the ticked one', p, '<!-- acceptance:start -->\n' + ticked3 + '\n<!-- acceptance:end -->')
    if (e1 || e2 || e3 || e4) return e1 || e2 || e3 || e4
    if (!fns) continue
    const e5 = eq(name + ': checked ids are the real block\'s', fns.checkedAcceptanceIds(p), [1, 2, 3])
    const e6 = includes(name + ': splice replaces the real block only', fns.spliceAcceptanceBlock(body, '- [ ] <!-- ac:1 --> new'), real.replace(T183_L3.join('\n'), '- [ ] <!-- ac:1 --> new'))
    if (e5 || e6) return e5 || e6
  }
  // A fence inside the block itself: the marker pair it holds (the start would cut the block) is no marker, and the id-looking line it holds is no box.
  const inner = '```\n<!-- acceptance:start -->\n- [ ] <!-- ac:2 --> fenced id example\n<!-- acceptance:end -->\n```'
  const body = 'Closes #183\n\n<!-- acceptance:start -->\n' + [T183_L3[0], inner, T183_L3[1], T183_L3[2]].join('\n') + '\n<!-- acceptance:end -->\n'
  const r = await t183Review({ prBody: body, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
  const p = String(r.prBodyPreview || '')
  const e7 = eq('fence in the block: status', r.status, 'ready')
  const e8 = includes('fence in the block: rendered boxes ticked, the fence kept after them', p, '<!-- acceptance:start -->\n' + ticked3 + '\n' + inner + '\n<!-- acceptance:end -->')
  if (e7 || e8) return e7 || e8
  if (fns) {
    const e9 = eq('fence in the block: checked ids', fns.checkedAcceptanceIds(body.replace('- [ ] <!-- ac:2 --> fenced id example', '- [x] <!-- ac:2 --> fenced id example')), [])
    if (e9) return e9
  }
  // A fence never closed BEFORE the block swallows it: no block, the tick fails closed, the run is parked with its reason.
  const open = 'Closes #183\n\n```\nan example, never closed\n\n' + real
  const o = await t183Review({ prBody: open, morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }] })
  const e10 = eq('never closed before the block: status', o.status, 'verified-untickable')
  const e11 = eq('never closed before the block: tickReason', o.tickReason, 'no-markers')
  const e12 = includes('never closed before the block: trace', o.trace || [], 'acceptance-tick-reason:no-markers')
  const e13 = eq('never closed before the block: the body is untouched', o.prBodyPreview === undefined || o.prBodyPreview === null || String(o.prBodyPreview).includes('- [x]') === false, true)
  if (!fns) return e10 || e11 || e12 || e13 || t182Skip('T183za')
  const e14 = eq('never closed before the block: block level', fns.tickAcceptanceBlock(open, T183_L3.join('\n'), [1, 2, 3], []), null)
  return e10 || e11 || e12 || e13 || e14 || { ok: true }
})

// T141 (#141) — the progress view shows one box per plan pass and per review round: the phase() titles the run calls, in
// order, are recorded by scripts/run-flow-suite.cjs in SUITE_ARGS.phaseTitles (reset at every run, read right after it).
const t141Titles = () => (SUITE_ARGS && Array.isArray(SUITE_ARGS.phaseTitles) ? SUITE_ARGS.phaseTitles.slice() : null)
const t141Skip = (id) => { log(`SKIP — ${id}: SUITE_ARGS.phaseTitles absent (suite not run via scripts/run-flow-suite.cjs)`); return { ok: true } }

await testCase('T141a a run without any loop records exactly Setup, Diagnose, Plan, Dev, Review', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'ready')
  const titles = t141Titles()
  if (!titles) return e1 || t141Skip('T141a')
  const e2 = eq('phase titles', titles, ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review'])
  return e1 || e2 || { ok: true }
})

await testCase('T141b two fix rounds record Review 2 then Review 3, each title at most 16 characters', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: ['a'] }, { verdict: 'REQUIRED_CHANGES', items: ['b'] }, { verdict: 'LGTM' }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 2)
  const titles = t141Titles()
  if (!titles) return e1 || e2 || t141Skip('T141b')
  const e3 = eq('phase titles', titles, ['Setup', 'Diagnose', 'Plan', 'Dev', 'Review', 'Review 2', 'Review 3'])
  const e4 = eq('titles over 16 characters', titles.filter((t) => t.length > 16), [])
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T141c a refused plan planned again records Plan 2', async () => {
  const withCommand = T182_ITEMS.map((it) => (it.humanGate ? { ...it, command: 'node scripts/guards.cjs' } : it))
  const r = await run({ mode: 'semi', simulate: { sam: { 1: t182Sam(withCommand), 2: t182Sam(T182_ITEMS) }, planCheck: T182_CONFORMING } })
  const e1 = eq('status', r.status, 'plan-ready')
  const titles = t141Titles()
  if (!titles) return e1 || t141Skip('T141c')
  const e2 = eq('phase titles', titles, ['Setup', 'Diagnose', 'Plan', 'Plan 2'])
  return e1 || e2 || { ok: true }
})

// The per-call `phase:` options never reach the harness in simulate mode (callAgent returns the fixture before agent()), so
// they are pinned on the engine source text: the plan-loop scout passes `phase: planPhase`; inside the review loop (from the
// roundPhase declaration to the round's Morgan call) the plan-amend scout, the Nick fix and Morgan pass `phase: roundPhase`
// and no literal `phase: 'Review'` or `phase: 'Plan'` remains.
await testCase('T141d the plan scout passes planPhase and the review loop calls pass roundPhase, never a fixed title', async () => {
  const src = SUITE_ARGS.fpSource
  if (!src) {
    log('SKIP — T141d: SUITE_ARGS.fpSource absent (suite not run via scripts/run-flow-suite.cjs)')
    return { ok: true }
  }
  const optsLine = (from, label) => {
    const at = src.indexOf(label, from)
    if (at < 0) return null
    const start = src.lastIndexOf('\n', at) + 1
    const end = src.indexOf('\n', at)
    return { line: src.slice(start, end), end }
  }
  const scout = optsLine(0, 'label: `scout-issue-${issue}-${planPass}`')
  const e1 = scout && scout.line.includes('phase: planPhase') ? null : { ok: false, msg: 'the plan-loop scout must pass `phase: planPhase`' }
  const loopStart = src.indexOf('const roundPhase = ')
  if (loopStart < 0) return { ok: false, msg: 'const roundPhase declaration not found' }
  const amend = optsLine(loopStart, 'label: `scout-amend-${issue}-r${round}`')
  const nick = optsLine(loopStart, 'label: `nick-pr-${issue}-${pr}`')
  const morgan = optsLine(loopStart, 'label: `morgan-pr-${issue}-${pr}-r${round}`')
  const e2 = amend && amend.line.includes('phase: roundPhase') ? null : { ok: false, msg: 'the plan-amend scout must pass `phase: roundPhase`' }
  const e3 = nick && nick.line.includes('phase: roundPhase') ? null : { ok: false, msg: 'the Nick fix call must pass `phase: roundPhase`' }
  const e4 = morgan && morgan.line.includes('phase: roundPhase') ? null : { ok: false, msg: 'the review-loop Morgan call must pass `phase: roundPhase`' }
  const region = morgan ? src.slice(loopStart, morgan.end) : ''
  const e5 = /phase:\s*['"`](Review|Plan)['"`]/.test(region)
    ? { ok: false, msg: "a literal `phase: 'Review'` or `phase: 'Plan'` remains in the review loop" } : null
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

// ---------------------------------------------------------------------------
// #184 — review-loop progress check, live-state ready gate, malformed-verdict escalation
// ---------------------------------------------------------------------------
// The caps stay constants; two reasons ride on the existing `escalate` status (`no-progress`, `verdict-malformed`).

// A schema of the same shape as the engine's MORGAN (the pure function reads the declared types and the verdict enum;
// the end-to-end cases T184d/e go through the real MORGAN).
const T184_SCHEMA = {
  type: 'object',
  required: ['verdict'],
  properties: {
    verdict: { enum: ['LGTM', 'REQUIRED_CHANGES', 'REGRESSION_DETECTED'] },
    items: { type: 'array', items: { type: 'string' } },
    boxes: { type: 'array', items: { type: 'object' } },
    ciGreen: { type: 'boolean' },
  },
}

await testCase('T184a two rounds with identical blockers → escalate no-progress after round 2, progress flat', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['a'] },
        { verdict: 'REQUIRED_CHANGES', items: ['a'] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'no-progress')
  const e3 = eq('round', r.round, 1)
  const e4 = eq('progress', r.progress, 'flat')
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T184b LGTM + every non-gate box proven + CI green → ready at round 0', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, true, true) }],
    },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 0)
  const e3 = (r.trace || []).includes('ci-not-green:0') ? { ok: false, msg: 'ci-not-green traced on a green run' } : null
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T184c LGTM with one open non-gate box is never ready: it loops, then stops on no-progress', async () => {
  const lines = t182Lines(T183_PLAIN)
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [
        { verdict: 'LGTM', boxes: t183Boxes(true, false, true) },
        { verdict: 'LGTM', boxes: t183Boxes(true, false, true) },
      ],
    },
  })
  const e1 = r.status === 'ready' ? { ok: false, msg: 'ready with a box not proven' } : null
  const e2 = eq('status', r.status, 'escalate')
  const e3 = eq('reason', r.reason, 'no-progress')
  const e4 = includes('trace', r.trace || [], 'acceptance-open-lgtm:0')
  // Control: with a single verdict the run stops at the review gate carrying the box-2 line.
  const s = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 190,
    planText: t182Sam(T183_PLAIN).plan,
    simulate: { morgan: [{ verdict: 'LGTM', boxes: t183Boxes(true, false, true) }] },
  })
  const e5 = eq('control: status', s.status, 'needs-revision')
  const e6 = eq('control: items', s.items, [lines[1]])
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T184d a verdict outside the schema escalates at round 0: verdict-malformed, no Nick round', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'MAYBE' }] } })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'verdict-malformed')
  const e3 = eq('round', r.round, 0)
  const e4 = eq('problem', r.problem, 'verdict')
  const e5 = includes('trace', r.trace || [], 'verdict-malformed:0')
  return e1 || e2 || e3 || e4 || e5 || nickTrace(r) || { ok: true }
})

await testCase('T184e a verdict malformed by shape in a later round escalates at once; a valid REGRESSION_DETECTED then LGTM is ready', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['a'] },
        { verdict: 'LGTM', items: 'oops' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'verdict-malformed')
  const e3 = eq('round', r.round, 1)
  const e4 = eq('problem', r.problem, 'items')
  const c = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'REGRESSION_DETECTED', items: ['a'] }, { verdict: 'LGTM' }] },
  })
  const e5 = eq('control: status', c.status, 'ready')
  const e6 = eq('control: rounds', c.rounds, 1)
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T184f reviewProgress and verdictProblem tables (the engine\'s own functions)', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T184f')
  const mk = (n, text) => `- [ ] <!-- ac:${n} --> ${text}`
  const rp = fns.reviewProgress
  const e1 = eq('identical -> flat', rp(['a', 'b'], ['a', 'b']), 'flat')
  const e2 = eq('same box id reworded -> flat', rp([mk(1, 'old wording')], [mk(1, 'new wording')]), 'flat')
  const e3 = eq('one resolved -> progress', rp(['a', 'b'], ['a']), 'progress')
  const e4 = eq('resolved + added -> progress', rp(['a'], ['b']), 'progress')
  const e5 = eq('prev null -> progress', rp(null, ['a']), 'progress')
  const e6 = eq('prev empty -> progress', rp([], ['a']), 'progress')
  const e7 = eq('prev subset of cur -> regressed', rp(['a'], ['a', 'b']), 'regressed')
  const e8 = eq('box ids: 1 -> 1,2 -> regressed', rp([mk(1, 'x')], [mk(1, 'x'), mk(2, 'y')]), 'regressed')
  const vp = fns.verdictProblem
  const e9 = eq('valid verdict -> null', vp({ verdict: 'LGTM', items: ['a'], boxes: [], ciGreen: true }, T184_SCHEMA), null)
  const e10 = eq('unknown verdict -> verdict', vp({ verdict: 'MAYBE' }, T184_SCHEMA), 'verdict')
  const e11 = eq('missing verdict -> verdict', vp({ items: [] }, T184_SCHEMA), 'verdict')
  const e12 = eq('items not an array -> items', vp({ verdict: 'LGTM', items: 'oops' }, T184_SCHEMA), 'items')
  const e13 = eq('items holding a non-string -> items', vp({ verdict: 'LGTM', items: ['a', 3] }, T184_SCHEMA), 'items')
  const e14 = eq('ciGreen not a boolean -> ciGreen', vp({ verdict: 'LGTM', ciGreen: 'yes' }, T184_SCHEMA), 'ciGreen')
  const e15 = eq('boxes not an array -> boxes', vp({ verdict: 'LGTM', boxes: {} }, T184_SCHEMA), 'boxes')
  const e16 = eq('not an object -> not-an-object', vp('LGTM', T184_SCHEMA), 'not-an-object')
  const e17 = eq('array -> not-an-object', vp([], T184_SCHEMA), 'not-an-object')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || e11 || e12 || e13 || e14 || e15 || e16 || e17 || { ok: true }
})

await testCase('T184g the CI half of the ready gate: a red CI at LGTM is REQUIRED_CHANGES, a persistent one stops on no-progress; ciBlocker table', async () => {
  const r = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM', ciGreen: false }, { verdict: 'LGTM' }] } })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('rounds', r.rounds, 1)
  const e3 = includes('trace', r.trace || [], 'ci-not-green:0')
  const p = await run({ mode: 'auto', simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM', ciGreen: false }, { verdict: 'LGTM', ciGreen: false }] } })
  const e4 = eq('persistent: status', p.status, 'escalate')
  const e5 = eq('persistent: reason', p.reason, 'no-progress')
  const fns = t182Block()
  if (!fns) return e1 || e2 || e3 || e4 || e5 || t182Skip('T184g')
  const cb = fns.ciBlocker
  const e6 = eq('green wins over a Morgan false', cb('green', false), null)
  const e7 = typeof cb('failing', true) === 'string' ? null : { ok: false, msg: 'failing + true must give a blocker line' }
  const e8 = typeof cb('pending', true) === 'string' ? null : { ok: false, msg: 'pending + true must give a blocker line' }
  // The probe ANSWERED 'none' (no check on the head): Morgan's word decides. No evidence at all (null, absent: the probe
  // failed or is an older script): a blocker unless Morgan reported ciGreen true.
  const isLine = (label, x) => (typeof x === 'string' && x !== '' ? null : { ok: false, msg: `${label} must give a blocker line, got ${JSON.stringify(x)}` })
  const e9 = isLine('null + false', cb(null, false))
  const e10 = isLine('none + false', cb('none', false))
  const e11 = eq('null + true -> null', cb(null, true), null)
  const e12 = isLine('undefined + undefined', cb(undefined, undefined)) || isLine('null + undefined', cb(null, undefined))
  const e12b = eq('undefined + true -> null', cb(undefined, true), null)
  const e12c = eq('none + undefined -> null', cb('none', undefined), null) || eq('none + true -> null', cb('none', true), null)
  const e12d = eq('the no-evidence line is the same sentence as the one of the Morgan report', cb(null, undefined), cb('none', false))
  const e13 = eq('the line is stable across calls', cb('failing', true), cb('failing', true))
  // 'absent' (a configured check GitHub never reports) is its own STABLE line naming the names, never the 'pending' sentence
  const abs = cb('absent', true, ['build', 'deploy'])
  const e14 = eq('absent line', abs, 'config.ciChecks names check(s) not reported on the PR head: build, deploy')
  const e15 = eq('absent wins over a Morgan true and is stable', cb('absent', true, ['build', 'deploy']), cb('absent', false, ['build', 'deploy']))
  const e16 = eq('absent is not the pending sentence', abs === cb('pending', true, ['build']) ? 'same' : 'distinct', 'distinct')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || e11 || e12 || e12b || e12c || e12d || e13 || e14 || e15 || e16 || { ok: true }
})

await testCase('T184h ciScope: the CI state is judged over config.ciChecks only, else the overall state', async () => {
  const fns = t182Block()
  if (!fns) return t182Skip('T184h')
  const cs = fns.ciScope
  const map = { guards: 'green', 'smoke-install': 'green', CodeQL: 'pending', 'Analyze (python)': 'failing' }
  const req = ['guards', 'smoke-install']
  const e1 = eq('filtered-out failing + pending optional checks -> green', cs('failing', map, req), 'green')
  const e2 = eq('a configured check failing -> failing', cs('green', { ...map, guards: 'failing' }, req), 'failing')
  const e3 = eq('a configured check pending -> pending', cs('green', { ...map, 'smoke-install': 'pending' }, req), 'pending')
  const e4 = eq('a configured name absent from the map -> absent (not pending: nothing is pending)', cs('green', { guards: 'green' }, req), 'absent')
  const e5 = eq('failing wins over an absent name', cs('green', { guards: 'failing' }, req), 'failing')
  const e6 = eq('failing wins over a pending one', cs('green', { guards: 'pending', 'smoke-install': 'failing' }, req), 'failing')
  const e7 = eq('no config.ciChecks (undefined) -> overall', cs('failing', map, undefined), 'failing')
  const e8 = eq('empty config.ciChecks -> overall', cs('pending', map, []), 'pending')
  const e9 = eq('no map (null) -> overall', cs('green', null, req), 'green')
  const e10 = eq('no map (undefined) -> overall, null stays null', cs(null, undefined, req), null)
  const e11 = eq('an empty map with configured names -> absent', cs('none', {}, req), 'absent')
  const e12 = eq('an inherited property name is not a check', cs('green', {}, ['constructor']), 'absent')
  const e13 = eq('__proto__ is not a check either', cs('green', {}, ['__proto__']), 'absent')
  const e14 = eq('a non-array config.ciChecks -> overall', cs('failing', map, 'guards'), 'failing')
  const e15 = eq('a map of the wrong type -> overall', cs('failing', ['guards'], req), 'failing')
  // precedence failing > pending > absent > green; the matrix names GitHub reports ('build (ubuntu-latest)') never match a bare 'build'
  const e16 = eq('pending wins over an absent name', cs('green', { guards: 'pending' }, req), 'pending')
  const e17 = eq('failing wins over absent', cs('green', { guards: 'green', 'smoke-install': 'failing' }, ['guards', 'smoke-install', 'build']), 'failing')
  const matrix = { 'build (ubuntu-latest)': 'green', 'build (macos-latest)': 'green', guards: 'green' }
  const e18 = eq('matrix job names do not satisfy the bare configured name -> absent', cs('green', matrix, ['guards', 'build']), 'absent')
  const e19 = eq('ciAbsent lists the unreported configured names in the config order', fns.ciAbsent(matrix, ['deploy', 'guards', 'build']), ['deploy', 'build'])
  const e20 = eq('ciAbsent: nothing absent -> []', fns.ciAbsent({ guards: 'green' }, ['guards']), [])
  const e21 = eq('ciAbsent: no usable map or names -> []', JSON.stringify([fns.ciAbsent(null, ['a']), fns.ciAbsent({}, []), fns.ciAbsent({}, undefined), fns.ciAbsent(['a'], ['a'])]), '[[],[],[],[]]')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || e10 || e11 || e12 || e13 || e14 || e15 || e16 || e17 || e18 || e19 || e20 || e21 || { ok: true }
})

await testCase('T184i a malformed verdict escalates with no stale boxes from the previous round', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['a'], boxes: t183Boxes(true, false, true) },
        { verdict: 'MAYBE' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'verdict-malformed')
  const e3 = eq('round', r.round, 1)
  const e4 = eq('no boxes carried over from round 0', r.boxes, undefined)
  // Control: the same run with a valid second verdict does carry that round's boxes.
  const c = await run({
    mode: 'auto',
    simulate: {
      sam: { 1: t182Sam(T183_PLAIN) },
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['a'], boxes: t183Boxes(true, false, true) },
        { verdict: 'LGTM', boxes: t183Boxes(true, true, true) },
      ],
    },
  })
  const e5 = eq('control: status', c.status, 'ready')
  const e6 = Array.isArray(c.boxes) ? null : { ok: false, msg: 'control: an id run that settles must carry its boxes' }
  return e1 || e2 || e3 || e4 || e5 || e6 || { ok: true }
})

await testCase('T184j a regressed round (previous blockers plus a new one) escalates no-progress at once', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: ['a'] },
        { verdict: 'REQUIRED_CHANGES', items: ['a', 'b'] },
        { verdict: 'LGTM' },
      ],
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'no-progress')
  const e3 = eq('progress', r.progress, 'regressed')
  const e4 = eq('round', r.round, 1)
  const e5 = includes('trace', r.trace || [], 'review-regressed:1')
  return e1 || e2 || e3 || e4 || e5 || { ok: true }
})

await testCase('T184k the hard cap: distinct blockers every round end at rounds 3 with the generic escalate', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: ['a', 'b', 'c', 'd', 'e'].map((x) => ({ verdict: 'REQUIRED_CHANGES', items: [x] })),
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('rounds', r.rounds, 3)
  const e3 = eq('no named reason: the generic escalate', r.reason, undefined)
  const e4 = eq('finalVerdict', r.finalVerdict, 'REQUIRED_CHANGES')
  return e1 || e2 || e3 || e4 || { ok: true }
})

// T123 (#42) — every test ID is unique across the suite. Must stay the LAST case so `results`
// holds every other case name. Includes a negative control proving the detector really detects.
await testCase('T123 test IDs are unique across the suite (no duplicated T<n>)', async () => {
  const control = eq('negative control', duplicateTestIds(['T1 a', 'T1 b', 'T1a c', 'F2 x']), ['T1'])
  if (control) return control
  const dups = duplicateTestIds(results.map(r => r.name))
  if (dups.length !== 0) {
    return { ok: false, msg: `duplicated test IDs: ${dups.join(', ')}` }
  }
  return { ok: true }
})

// ---------------------------------------------------------------------------
// Tally
// ---------------------------------------------------------------------------

const passed = results.filter(r => r.ok).length
const failed = results.filter(r => !r.ok).length
const total = results.length

log(`\nResults: ${passed}/${total} passed${failed > 0 ? `, ${failed} failed` : ''}`)
if (failed > 0) {
  for (const r of results.filter(x => !x.ok)) log(`  FAIL: ${r.name} — ${r.msg}`)
}

return {
  status: failed === 0 ? 'test-ok' : 'test-failed',
  passed,
  failed,
  total,
  results,
}
