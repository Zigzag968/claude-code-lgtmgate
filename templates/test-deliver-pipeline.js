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
async function run(overrides) {
  return await workflow(FP_REF, { ...BASE, ...overrides })
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
await testCase('same-blocker-twice (round 1 items ⊇ round 0) → escalate', async () => {
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
  const e2 = eq('reason', r.reason, 'same-blocker-twice')
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

// 18. T18 — human-gate short-circuit at round 0
// Morgan returns only the HUMAN TEST GATE item → pipeline terminates ready-pending-human
// at round 0 (not a REQUIRED_CHANGES loop). Directly replays the real incident.
await testCase('T18 human-gate short-circuit round 0 → ready-pending-human', async () => {
  const humanItem = "[human-gate] HUMAN TEST GATE: human runs `python -m app.render --render-id abc123-... --publish`, verifies the output renders correctly, posts approval on the PR"
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [humanItem] }],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('round', r.round, 0)
  const e3 = r.humanGateItems && r.humanGateItems.length === 1
    ? null
    : { ok: false, msg: `humanGateItems.length: expected 1, got ${r.humanGateItems?.length}` }
  const e4 = r.resumable === true
    ? null
    : { ok: false, msg: `resumable: expected true, got ${r.resumable}` }
  return (e1 || e2 || e3 || e4) ? (e1 || e2 || e3 || e4) : { ok: true }
})

// 19. T19 — mixed round loops on real blocker, then terminates
// round0: [human-gate item + real blocker] → loops; round1: [human-gate only] → ready-pending-human
await testCase('T19 mixed round loops on real blocker then human-gate terminates', async () => {
  const humanItem = '[human-gate] human live-render check, post approval on PR'
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [humanItem, 'fix URL regex'] },
        { verdict: 'REQUIRED_CHANGES', items: [humanItem] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = r.humanGateItems && r.humanGateItems.length === 1
    ? null
    : { ok: false, msg: `humanGateItems.length: expected 1, got ${r.humanGateItems?.length}` }
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// 20. T20 — normalization catches cosmetic rewording (Part 2)
// Two cosmetically-reworded copies of one blocker trigger same-blocker-twice escalate.
// Would fail under the old exact-match isSubset, passes under normalized comparison.
await testCase('T20 normalization catches cosmetic rewording → same-blocker-twice escalate', async () => {
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
  const e2 = eq('reason', r.reason, 'same-blocker-twice')
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

// ── #228 — verified-untickable terminal status ──────────────────────────────────────────────
// Morgan PROVED every box but the tick (`gh pr edit`) is denied by permissions. The workflow must
// park the run for the Lead (`verified-untickable`) instead of dispatching a Nick round that ends
// `escalate nick-no-op`. Fail-safe: human-gate items, empty proofs and ciGreen:false never park.
const UNT_A = '- [ ] `node scripts/run-flow-suite.cjs` ends `failed=0`'
const UNT_B = '- [ ] `diff templates/pr-acceptance.md .claude/rules/pr-acceptance.md` prints nothing'
const untOwner = (item, proof = '$ cmd\n(verbatim output)') => ({ item, itemOwner: 'proven-untickable', proof })

await testCase('T228a all boxes proven-untickable (auto) → verified-untickable, no Nick round, no reason', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [UNT_A, UNT_B], itemOwners: [untOwner(UNT_A), untOwner(UNT_B)] }],
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('round', r.round, 0)
  const e3 = eq('untickableItems.length', r.untickableItems?.length, 2)
  const e4 = eq('resumable', r.resumable, true)
  const e5 = eq('reason', r.reason, undefined)
  const e6 = eq('item verbatim', r.untickableItems?.[0]?.item, UNT_A)
  const e7 = eq('proof carried', r.untickableItems?.[0]?.proof, '$ cmd\n(verbatim output)')
  const e8 = (r.trace || []).some(t => /^nick/i.test(String(t))) ? { ok: false, msg: `Nick dispatched: trace=${JSON.stringify(r.trace)}` } : null
  const e9 = includes('trace', r.trace, 'verified-untickable:0')
  return e1 || e2 || e3 || e4 || e5 || e6 || e7 || e8 || e9 || { ok: true }
})

await testCase('T228b semi mode, entryStage:review → verified-untickable (returns before gate(review))', async () => {
  const r = await run({
    mode: 'semi',
    entryStage: 'review',
    prNumber: 231,
    simulate: {
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [UNT_A, UNT_B], itemOwners: [untOwner(UNT_A), untOwner(UNT_B)] }],
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('untickableItems.length', r.untickableItems?.length, 2)
  return e1 || e2 || { ok: true }
})

await testCase('T228c [human-gate] line labelled proven-untickable → refused → ready-pending-human, no untickableItems', async () => {
  const humanItem = '- [ ] [human-gate] human confirms the wording'
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [humanItem], itemOwners: [untOwner(humanItem)] }],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('humanGateItems.length', r.humanGateItems?.length, 1)
  const e3 = eq('untickableItems', r.untickableItems, undefined)
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T228d proven-untickable + [human-gate] → ready-pending-human carrying both lists', async () => {
  const humanItem = '- [ ] [human-gate] human confirms the D5 status name'
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [UNT_A, humanItem], itemOwners: [untOwner(UNT_A)] }],
    },
  })
  const e1 = eq('status', r.status, 'ready-pending-human')
  const e2 = eq('humanGateItems.length', r.humanGateItems?.length, 1)
  const e3 = eq('untickableItems.length', r.untickableItems?.length, 1)
  const e4 = eq('untickable item', r.untickableItems?.[0]?.item, UNT_A)
  return e1 || e2 || e3 || e4 || { ok: true }
})

await testCase('T228e empty/whitespace proof → fail-safe legacy path → escalate nick-no-op', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', items: [UNT_A], itemOwners: [untOwner(UNT_A, '   ')] }, { verdict: 'LGTM' }],
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'nick-no-op')
  const e3 = eq('untickableItems', r.untickableItems, undefined)
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T228f ciGreen:false with all items proven-untickable → not parked (legacy path)', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [{ verdict: 'REQUIRED_CHANGES', ciGreen: false, items: [UNT_A], itemOwners: [untOwner(UNT_A)] }, { verdict: 'LGTM' }],
      headSha: { 1: 'sha-abc123' },
    },
  })
  const e1 = r.status === 'verified-untickable' ? { ok: false, msg: 'parked despite ciGreen:false' } : null
  const e2 = eq('status', r.status, 'escalate')
  const e3 = eq('reason', r.reason, 'nick-no-op')
  return e1 || e2 || e3 || { ok: true }
})

await testCase('T228g round 0 proven-untickable + real code blocker loops, round 1 only proven-untickable → verified-untickable at round 1', async () => {
  const r = await run({
    mode: 'auto',
    simulate: {
      sam: 'GO',
      morgan: [
        { verdict: 'REQUIRED_CHANGES', items: [UNT_A, 'fix the null guard'], itemOwners: [untOwner(UNT_A)] },
        { verdict: 'REQUIRED_CHANGES', items: [UNT_A], itemOwners: [untOwner(UNT_A)] },
      ],
    },
  })
  const e1 = eq('status', r.status, 'verified-untickable')
  const e2 = eq('round', r.round, 1)
  const e3 = eq('untickableItems.length', r.untickableItems?.length, 1)
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
// non-destructive flag, never a close. (This suite's numbering is per-feature, not globally
// sequential — see T33/T34 below for the same note.)
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
// wrongly re-closed a human-reopened issue in production. NOTE: this label coincides with the
// pre-existing, UNRELATED "T33 planCheck orphan criterion" case above (#14) — this suite's
// numbering is per-feature, not a globally unique sequence; both are legitimate, distinct cases.
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
// NOTE: coincides with the pre-existing, UNRELATED "T34 Theo laneOk:false" case (same rationale
// as T33 above). Not gated by its own acceptance-checklist box (§5 only cites T32/T33); kept as
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

// 33. T33 (#14) — planCheck item 4: an orphan acceptance criterion (in the checklist, no
//     plan step) yields NOT_CONFORMING; bounded to escalate, and the orphan list surfaces in
//     planCheckIssues so the Lead sees exactly what is unaddressed.
await testCase('T33 planCheck orphan criterion → escalate, orphans in planCheckIssues', async () => {
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

// 34. T34 (#14) — Theo lane-check: a user-visible issue on the mechanical ('Sam') lane →
//     laneOk:false → status 'lane-refused', requiredScout surfaced, no Sam/Nick/Morgan spent.
await testCase('T34 Theo laneOk:false → lane-refused, requiredScout surfaced', async () => {
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
// #175 (epic slice 2: #114/#120) — parseProvisionOutput regression coverage. Unlike
// T37/T38/F2/T99/T100/T104a-d above (which all stub the ALREADY-SHAPED `simulate.provision`
// result object, bypassing the parser entirely), these three route raw provision_worktree.sh-style
// text through `simulate.provisionRaw` so they exercise the REAL deterministic parser under test —
// the only regression coverage this repo has for the false-`provision-failed` (#114) and
// flip-flopping missing/linked (#120) defects the LLM-judgment schema used to cause.
// ---------------------------------------------------------------------------

// T175a (#114 negative control) — a WARN-only (soft-miss) raw transcript with exit 0 parses to
// ok=true (derived strictly from PROVISION-EXIT:0) → ready, same as T38's happy path, but this
// time via the REAL parser: proves a soft WARN line is never mistaken for a hard MISSING-SRC one.
await testCase('T175a provisionRaw WARN-only + exit 0 → parsed ok=true, ready, trace unchanged', async () => {
  const raw =
    'LINKED .env -> /main/.env\n' +
    'WARN optional src missing: /main/.cache\n' +
    'PROVISION-EXIT:0\n'
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], provisionRaw: raw },
  })
  const e1 = eq('status', r.status, 'ready')
  const e2 = eq('trace', r.trace, ['Plan', 'Dev', 'Review', 'PR Ready'])
  return (e1 || e2) ? (e1 || e2) : { ok: true }
})

// T175b (#114 positive case) — a MISSING-SRC (hard-miss) raw transcript with exit 2 parses to
// ok=false, missing=['/main/.venv'] parsed verbatim from the literal MISSING-SRC line (never
// from the WARN line above it) → escalate/provision-failed, mirroring T37's assertions but
// through the real parser instead of a pre-shaped stub.
await testCase('T175b provisionRaw MISSING-SRC + exit 2 → parsed missing verbatim, escalate/provision-failed', async () => {
  const raw =
    'WARN optional src missing: /main/.cache\n' +
    'MISSING-SRC /main/.venv\n' +
    'PROVISION-FAILED: 1 link(s)\n' +
    'PROVISION-EXIT:2\n'
  const r = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], provisionRaw: raw },
  })
  const e1 = eq('status', r.status, 'escalate')
  const e2 = eq('reason', r.reason, 'provision-failed')
  const e3 = eq('missing', r.missing, ['/main/.venv'])
  const e4 = eq('exitCode', r.exitCode, 2)
  const err = e1 || e2 || e3 || e4
  return err ? err : { ok: true }
})

// T175c (#120 determinism criterion) — the SAME raw transcript run twice must yield an IDENTICAL
// status + trace both times. #120's own observed defect was the LLM judgment flip-flopping
// missing/linked across identical re-runs of the same underlying script output; this proves the
// deterministic parser has no such non-determinism at the JS-parsing layer.
await testCase('T175c provisionRaw identical input twice → identical status + trace (determinism)', async () => {
  const raw =
    'MISSING-SRC /main/.venv\n' +
    'PROVISION-FAILED: 1 link(s)\n' +
    'PROVISION-EXIT:2\n'
  const r1 = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], provisionRaw: raw },
  })
  const r2 = await run({
    mode: 'auto',
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], provisionRaw: raw },
  })
  const e1 = eq('status (run1 vs run2)', r1.status, r2.status)
  const e2 = eq('trace (run1 vs run2)', r1.trace, r2.trace)
  const e3 = eq('missing (run1 vs run2)', r1.missing, r2.missing)
  const err = e1 || e2 || e3
  return err ? err : { ok: true }
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

await testCase('T71b resolveWorktreeRoot: $AGENT_PIPELINE_WORKTREE_ROOT beats local and versioned', async () => {
  const r = await run({
    mode: 'auto',
    config: { ...CONFIG, worktreeRoot: '/tmp/lgtmgate-worktrees' },
    configLocal: { worktreeRoot: '/local/root' },
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }], env: { AGENT_PIPELINE_WORKTREE_ROOT: '/env/root' } },
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
await testCase('T104 nickPrompt includes the raw issue brief alongside the plan (#111)', async () => {
  const marker = 'UNIQUE-BRIEF-MARKER-T104-xyz987'
  const r = await run({
    mode: 'auto',
    brief: marker,
    simulate: { sam: 'GO', morgan: [{ verdict: 'LGTM' }] },
  })
  const err = includes('nickPromptPreview', r.nickPromptPreview, marker)
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
// named as a plan defect rather than mislabelled same-blocker-twice.
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

// T99 — Morgan review fix (PR #121): off-path regression where an empty/absent `items` (MORGAN.items
// is optional; REQUIRED_CHANGES has never required items) silently skipped Nick because
// `dispatchNick` was gated on `nickItems.length > 0` even when nothing was plan-routed
// (`planRouted === false`). Exact repro fixture from the review comment: no `itemOwners` at all
// (fully off-path), Morgan round 1 returns REQUIRED_CHANGES with no `items`, headSha frozen across
// rounds → Nick MUST still be dispatched, run the no-op gate, and escalate nick-no-op — never reach
// `ready` via a silent `nick-skipped-plan-only` skip.
await testCase('T99 off-path empty items (no itemOwners) → Nick still dispatched, no-op gate fires, escalate nick-no-op', async () => {
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
