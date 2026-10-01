export const meta = {
  name: 'deliver-pipeline',
  description: 'Sam (plan) -> Nick (dev+PR) -> Morgan (review) -> loop until LGTM',
  whenToUse: 'Deliver a change end-to-end through the specialized agent pipeline (bug fix, chore, or feature). The Lead creates the shared worktree before launching and passes its path.',
  phases: [
    { title: 'Setup', detail: 'Run identity + early probes (config recheck, provision, freshness) before any agent work' },
    { title: 'Diagnose', detail: 'Theo qualifies EVERY issue before Sam plans — mandatory, no opt-out' },
    { title: 'Plan', detail: 'Mia (optional) + Sam scout/plan, posted on the issue' },
    { title: 'Dev', detail: 'Nick implements in the shared worktree + opens PR' },
    { title: 'Review', detail: 'Morgan reviews in the same worktree; loop back to Nick on changes' },
  ],
}

// Guards (scripts/guards.cjs, R1 ratchet vs origin/main): the counters of `await agent(` outside
// callAgent, distinct simulate seam keys and regex applications on agent output may never go
// up. A parser wrapped between the comment lines `// guards:parser-begin` and
// `// guards:parser-end` is not counted by agent-output-regex, so moving one inside markers lowers it.
//
// Args:
//   issue       — GitHub issue number (required)
//   brief       — one-line description of the change (required)
//   wtPath      — shared worktree absolute path (required)
//   config      — project-specific configuration (stack-agnostic; see pipeline.config.template.json)
//                 worktreeRoot resolution order: LGTMGATE_WORKTREE_ROOT env var -> configLocal.worktreeRoot
//                 -> config.worktreeRoot -> wtPath's parent dir (see resolveWorktreeRoot below).
//                 { ghProject, baseBranch, branchPrefix, worktreeRoot, conventionsRule,
//                   commands:{build,test,format}, ciChecks:[], regressionGuard:{testGlob,testFnPattern,baselineCmd},
//                   provision:{extraLinks:[{src,dst}]}, preflight:{canonicalStringBan:[]},
//                   commitHygiene:{squashBeforeHandoff,maxCommits}, commentHygiene:bool,
//                   oneWayDoorPaths:[] (optional; R3 path globs/prefixes, default none; see oneWayDoorSignals),
//                   oneWayDoorKinds:[] (optional; R3 kinds among status|agent|hook|seam, default none),
//                   repo:'owner/repo' }  // repo: code repo for cross-repo runs; absent -> cwd-resolved
//   config      — REQUIRED object: the parsed `.claude/pipeline.config.json`, supplied by the Lead. Absent or
//                 not an object (e.g. a JSON string) -> throws before any agent call (#13, #12).
//   configLocal — parsed `.claude/pipeline.config.local.json`, supplied by the Lead (the workflow
//                 sandbox has no filesystem — see resolveWorktreeRoot below); only `worktreeRoot` is
//                 read today (#61). Gitignored, machine-local, never versioned. Absent/garbage -> {}.
//   pmReview    — run Mia before Sam (default false)
//   issueType   — the issue's type, from its `type:*` label (e.g. 'bug', 'feature', 'chore'); optional,
//                 absent = not a bug. With 'bug' AND a Sam target under `workflows/`, the R2 fixture
//                 acceptance item is injected into Nick's prompt (#76). A launch arg, not a simulate key.
//   scoutAgent  — agent type for the scout/plan stage (default 'Sam'). Lets the consuming
//                 project route to a different scout than Sam — e.g. a domain-specific
//                 planner it registers itself — while keeping the same plan contract
//                 (artifact + SAM schema) whoever fills the slot. Any agent name outside
//                 the built-in set (Mia/Sam/Nick/Morgan) passes through normalizeAgentType
//                 unchanged, so the consuming project can supply an already-namespaced
//                 agentType or a custom agent it registered itself.
//   branchOverride — exact branch name used verbatim instead of <branchPrefix>issue-<N> (#232; rebase-without-force-push,
//                 numbered slices). Arg, else config.branchOverride. Empty = unset; chars limited to [A-Za-z0-9._/-].
//                 Skips the config-prefix reconcile so a config-prefix branch is never accepted.
//   branchPrefix — top-level arg is IGNORED (config.branchPrefix wins); a differing value logs a warning +
//                 trace 'branch-prefix-arg-ignored' (#232). Use branchOverride to force a branch.
//                 config.branchPrefix absent/blank -> falls back to 'features/' and traces
//                 'branch-prefix-fallback-default' (#267), so a caller that fails to thread the
//                 project's own branchPrefix through config is diagnosable, not silent.
//   prNumber    — existing PR number; required when entryStage='review'
//   mode        — 'auto' | 'semi' (default) | 'manual'
//   entryStage  — 'plan' (default) | 'dev' | 'review'  (skip completed phases on crash-resume)
//   proceedThrough — last stage the Lead authorized to RUN on resume ('plan'|'dev'|'review'|null).
//                    The pipeline PAUSES before any stage beyond it. proceedThrough='plan' stops at plan-ready.
//   planText    — Sam's plan text, supplied on resume (entryStage='dev'|'review') so the
//                 hand-off survives a crash without re-reading GitHub. If absent on resume,
//                 the plan is re-materialized from the artifact file (see planPath below).
//   resumeReason — optional, null by default. Set by the Lead on an entryStage:'dev' relaunch
//                  that follows a status:'escalate', reason:'mergeable-conflicting' result
//                  (#170), to thread WHY the resume happens into Nick's prompt (#183) —
//                  otherwise Nick reasons only from branch/plan content. Allow-list deliberately
//                  narrow (one value today): a branch-mismatch or plan-stale escalate doesn't
//                  resolve by relaunching Nick with this same message.
//   dryRun      — if true, validate args and return immediately (no agents spawned)
//   probeOnly   — optional { name, cmd, label, round }: run ONE probe() (probe-run gate, #80) and return
//                 status 'dry-run-ok' reason 'probe-only'. Lets a run-offline fixture reach probe()
//                 while no engine call site is migrated yet. Not a simulate key.
//   pluginRoot  — optional absolute path of the plugin root (#82). The Lead passes
//                 ${CLAUDE_PLUGIN_ROOT} for the plugin component and omits it for a local copy; the
//                 probe layer resolves templates/probe-run.cjs from it (the workflow has no
//                 filesystem or env). config.probeRunPath wins; fallback <wtPath>/templates/probe-run.cjs.
//   models      — optional per-role model override: { scout?, planAudit?, morgan? }. Resolution
//                 order per role is `models.<role> ?? config.models?.<role> ?? 'sonnet'` (same `??`
//                 idiom as planAudit above — arg wins per-run over the project default). Default is
//                 'sonnet' for all three roles (lgtmgate#161: the plan-phase loop could spawn
//                 up to 4 opus scout attempts per issue with planAudit on, the dominant cost driver);
//                 pass e.g. `models: { scout: 'opus' }` per-run when an issue is dense/dangerous
//                 enough to warrant it — opus stays fully reachable, just no longer the default. Not
//                 a general cost-control knob: Theo and Nick are NOT overridable by this key, always
//                 'sonnet' (out of scope per the issue — their calls are unconditional literals).
//   maxPlanAttempts — bound on the plan-verification gate loop between Sam and Nick
//                 (default 2; mirrors advisory.js's `maxAttempts = 2`). On the
//                 maxPlanAttempts-th NOT_CONFORMING verdict, escalate instead of looping again.
//   planAudit   — optional, DEFAULT OFF: once Sam's plan clears the planCheck gate,
//                 run an independent, adversarial plan-soundness audit (persona-in-prompt,
//                 no agentType — independence holds by construction) before Dev ever starts.
//                 Resolved `planAudit ?? config.planAudit ?? false` — arg wins per-run over the
//                 project default, an explicit `false` beats a `true` config. Placement: Plan
//                 phase only — never re-runs on entryStage='dev'|'review' (resume). Spawn-cost
//                 bound (~70k session tokens/spawn): OFF unchanged; ON typical +1 opus audit
//                 (SOUND) or +1 audit +1 scout +1 planCheck (one amendment); ON worst case per
//                 Plan phase = maxAuditRounds × maxPlanAttempts = 4 opus scout spawns + 4 haiku
//                 planChecks + 2 opus audits (defaults).
//   planFreshness — optional, default 'advisory' (#103): before Dev, diff Sam's declared
//                 `targetFiles` against origin/<baseBranch> so a plan whose premise moved
//                 upstream since the worktree's frozen base is caught before Nick opens a PR.
//                 Resolution order: this arg, then config.planFreshness, then the 'advisory'
//                 fallback (arg wins per-run over the project default); a value outside
//                 'advisory'|'gate'|'off' throws.
//                 'advisory' warns Nick + traces `plan-stale:<n>`, no routing change. 'gate'
//                 escalates (reason:'plan-stale') before Nick is spawned. 'off' skips the probe.
//   maxAuditRounds — bound on the auditor <-> scout amendment loop (default 2, mirrors
//                 maxPlanAttempts). Must be a positive integer; a non-integer or < 1 throws.
//                 HARD CEILING: values above AUDIT_ROUNDS_CEILING (2) throw
//                 unless maxAuditRoundsOverrideReason is a non-empty string naming the risk class
//                 that justifies the extra round(s) — never config-reachable, arg-only, on every
//                 launch. The reason is echoed in the dryRun/escalate/plan-ready returns and
//                 pushed onto `trace` as `audit-budget-override:<n>`.
//   maxAuditRoundsOverrideReason — required non-empty string whenever maxAuditRounds > 2; ignored
//                 (trimmed to '') otherwise. See "HARD CEILING" above.
//   architectureDecisionApproved — asserts the design-step-trigger's architecture-only pass (see
//                 Theo's design-step signals below) already happened and was approved, so the
//                 design-step gate does not require proceedThrough:'plan' on this launch.
//   maxPlanAmendRounds — optional, DEFAULT 0 (issue #97): dark-launch kill-switch for routing a
//                 Morgan-classified PLAN defect (as opposed to a code defect) back to Sam for a
//                 plan amendment instead of forever re-dispatching Nick against a frozen,
//                 unfixable plan. 0 (the shipped default) is SHADOW MODE — Morgan's itemOwners
//                 classification is still computed and traced (`plan-route-shadow:<round>`), but
//                 every item is still routed to Nick as a code defect, so the off-path behaviour
//                 is byte-for-bit identical to before #97. Must be a non-negative integer; a
//                 non-integer or negative value throws. Flipped by the human only after
//                 observing shadow-mode `trace` evidence that the classification is trustworthy.
//   simulate    — test fixture object; the only key the engine reads is `simulate.probes`, a map keyed
//                 by seam name (agent mocks sam/mia/nick/morgan/theo/audit/planCheck/preflight/
//                 alreadyDoneCheck, parsed-value probes such as headSha/prBody/mergeState/behindCount,
//                 agentTypeUnresolved, branchCheckRaw, ...). When set, no real agent is spawned and the
//                 trace is still recorded. The translation from the suite's flat keys to `probes` and
//                 every default live in run() of the flow suite (scripts/run-flow-suite.cjs runs it);
//                 the engine carries no `??` default on a seam. `simulate.probes[<role>] = 'DIE'` (the
//                 literal string) is the plain-death lever for a role, since `null` is nullish.
//
// config.commitHygiene — OFF by default: { squashBeforeHandoff: bool, maxCommits: int }.
// squashBeforeHandoff=true makes the pipeline soft-reset a >maxCommits branch to 2-3 logical
// commits before LGTM handoff (see squashBeforeHandoff() in the Review phase). Only pays off on
// a project whose base branch merges with merge commits (branch commits land verbatim otherwise).
//
// config.commentHygiene — OFF by default: bool. Opt-in pass that minimizes superseded
// PR review comments (prior-round Morgan verdicts / Nick push-notes) so only the latest verdict
// stays visible. The minimizeComment GraphQL mutation is denied by the supervised-session safety
// classifier on every attempt, so by default the pass is skipped entirely — see the guard's
// comment near minimizeSupersededReviewComments() in the Review phase for the full rationale.
// HARD PRE-CONDITION (was): config.commentHygiene: true was gated on the decision-log composer
// landing in this copy — commentHygiene COLLAPSES prior-round verdicts while the
// decision-log block is what PRESERVES the history through that collapse. The composer landed in
// 0.8.2 (see upsertDecisionLog above and recordDecision in the Review phase), so
// config.commentHygiene: true is no longer pre-conditioned on it.
//
// Resume contract (confirmed): `resumeFromRunId` replays the ORIGINAL run's cached
// inputs from the run journal — it does NOT re-thread new `mode`/`proceedThrough`/`entryStage`
// supplied on the resume call (evidence: anthropics/claude-code#65796 "Workflow resume
// silently re-runs completed agents / replays from cache" + the official Claude Code
// Workflow docs on resume-from-cache semantics; the live Workflow runtime is external to
// this repo and not exercisable by an offline test, so this citation IS the confirmation).
// Therefore:
//   (a) use `resumeFromRunId` ONLY for transparent crash-retry of the SAME run with
//       IDENTICAL args (e.g. a died-Morgan retry — see the two `resumable: true` sites below).
//   (b) to CHANGE control-flow — a real case (`mode='semi'` + `proceedThrough='plan'`),
//       or advancing `entryStage` — launch a FRESH Workflow run with explicit args (`issue`,
//       `brief`, `wtPath`, `entryStage`, `prNumber`, `planText`, `mode`, `proceedThrough`)
//       rebuilt from persisted state. NEVER bare `resumeFromRunId` for that case: it silently
//       replays the original args and bypasses the subsequent gate() (a real incident path).
//
// COPIES-ALIGNED (this repo IS upstream) — ported verbatim from an internal reference
// implementation, covering the plan-audit, artifact-proof gate, and schema-death survival
// mechanisms below. Agent-death guard: every callAgent site that can throw
// or return null/undefined is wrapped in `callAgentSafe`, which routes the death through the
// pure `agentDeathRouting()` — retry once for side-effect-free roles (provision, theo, mia,
// sam, planCheck, audit, alreadyDoneCheck, preflight), else return a terminal, resumable
// `{ status: '<stage>-died', resumable: true }` outcome (`provision-died`, `diagnose-died`,
// `plan-died`, `plan-check-died`, `plan-audit-died`, `dev-died`, `preflight-died`). `nick` is
// NEVER retried — it commits, pushes and opens the pull request, so a respawn after a
// schema-only failure risks a duplicate PR; `morgan` keeps its own pre-existing `null`-result contract via
// `callMorganGuarded` (a thrown Morgan death is caught there and folded into the same `null` →
// `review-died` path) rather than being routed through
// `callAgentSafe`. `mia` and `alreadyDoneCheck` DEGRADE on death instead of dying terminally —
// both sites already documented themselves as optional/safety-net, so killing a run over either
// would invert their purpose. Every death — retried or terminal — leaves a `trace` entry
// (`agent-died:<role>:<attempt>`) and a `log()` line, never silent.
//
// Prophylaxis (works regardless of catchability): `callAgent` appends a
// `STRUCTURED_OUTPUT_MANDATE` to the prompt of every call carrying `opts.schema`, stating as
// fact that prose is not an answer and that a nudge claiming the tool call was already made is
// FACT — pre-empting a real observed hallucination ("I have already called
// StructuredOutput").
//
// HONESTY / KNOWN LIMIT: upstream anthropics/claude-code#65500 reports that a script-level
// `.catch(() => null)` around a fan-out `agent({schema})` call did NOT contain the harness abort
// it was reporting — i.e. the failure class can occur OUT OF BAND, outside any try/catch this
// script can write. This guard rescues every CATCHABLE death (a thrown error or a null/undefined
// result); it does NOT claim to rescue an out-of-band harness abort, which stays an upstream fix
// tracked as a known upstream limitation.
//
// Diagnose stage (Theo) — MANDATORY, no opt-out (human decision, 2026-07-24: "every
// nightly run is diagnosed by Theo"). Runs before Plan on every fresh dispatch
// (entryStage='plan'): Theo qualifies the issue before Sam ever plans a fix on top of an
// unverified premise. For a bug/pain-derived issue that names a cause, Theo reproduces it
// for real and confirms/refutes the cause. For a feature/chore ask with no claimed bug,
// Theo sanity-checks it's justified (not already shipped, not solving a non-problem,
// coherent as scoped). Refuted -> status 'diagnosis-refuted' (no Sam/Nick/Morgan spent).
// Confirmed -> falls through into Plan as usual, with Theo's evidence handed to Sam.
// Never runs on resume (entryStage='dev'|'review') — Theo already ran on that issue's
// fresh dispatch.

// Build stamp (#54) — answers "which artifact served this run" (silent-stale-cache class:
// CC #61954 / #17361 / #37670). `cutFrom` is the short SHA this artifact's content was CUT FROM —
// the base commit it was derived from (a commit cannot carry its own SHA) — NOT the SHA it is
// PUBLISHED AT: that is a different value, the catalog pin (`.claude-plugin/marketplace.json`
// `source.sha`), moved by the human's publish commit (e.g. 0.8.0's cutFrom is `c040169`, its
// catalog pin moved to `f59e4e0`). `cutFrom` is CONTEXT, never the identity key, and it is
// deliberately UNGUARDED (release-checklist-only — see MAINTAINING.md §4). The identity key is
// `version`, checked against plugin.json by templates/test-canonical-guards.sh, which reports
// on every PR (.github/workflows/guards.yml) — enforcement is the standing acceptance-checklist
// line + block-merge-unchecked.sh (rulesets/branch protection unavailable on this repo).
const BUILD = { plugin: 'lgtmgate', version: '1.0.0-beta.2', cutFrom: 'f9bde6b' }
const BUILD_STAMP = `[pipeline] lgtmgate@${BUILD.version} cutFrom=${BUILD.cutFrom} workflow=deliver-pipeline`
log(BUILD_STAMP)

// Every terminal return carries the stamp as a dedicated top-level field. NOT via trace:
// `trace` is a phase/event log asserted by full deep-equality at 11 sites in
// templates/test-deliver-pipeline.js (and in every consumer's copied suite), so prepending to
// it would be a breaking return-shape contract change. `buildStamp` is a new field no
// assertion reads (every eq() in the suite is field-level; none deep-equals the return).
// nickPromptPreview (#61) — simulate-only, same idiom as preflightPromptPreview/prBodyPreview
// below: lets the flow tests assert the composed Nick brief (notably the resolved worktree root)
// without exposing prompt text outside simulate runs.
let nickPromptPreview = null
let preflightFixPromptPreview = null   // #132 — simulate-only, same idiom as nickPromptPreview
// provisionCmdPreview (#72) — same simulate-only idiom as nickPromptPreview above: lets the
// flow tests assert the composed provisioning command (notably PROVISION_ENV_SYMLINK) without
// exposing it outside simulate runs.
let provisionCmdPreview = null
// #110: set by callAgent when an agent call stayed cut off by a classifier outage past its retry
// bound; finish() then names the cause on the resulting `*-died` status.
let classifierOutageDeath = false
const finish = (o) => ({ buildStamp: BUILD_STAMP, ...(simulate ? { nickPromptPreview, provisionCmdPreview, preflightFixPromptPreview } : {}),
  ...(classifierOutageDeath && String(o.status).endsWith('-died')
    ? { reason: 'classifier-outage: resume with resumeFromRunId' } : {}), ...o })

const {
  issue, brief, pmReview = false, issueType = null, wtPath,
  scoutAgent = 'Sam',
  config,
  configLocal = {},
  prNumber = null,
  resumeReason = null,
  mode = 'semi',
  entryStage = 'plan',
  proceedThrough = null,
  planText = null,
  dryRun = false,
  probeOnly = null,
  pluginRoot = null,
  maxPlanAttempts = 2,
  planAudit = undefined,
  planFreshness = undefined,
  branchOverride = undefined,
  branchPrefix: branchPrefixArg = undefined,
  maxAuditRounds = 2,
  maxAuditRoundsOverrideReason = null,
  architectureDecisionApproved = false,
  maxPlanAmendRounds = 0,
  models = {},
  simulate = null,
  stamp = null,
} = (typeof args === 'string' ? JSON.parse(args) : args) || {}

if (!issue || !brief || !wtPath) throw new Error('Missing required args: issue, brief, wtPath')
// #13/#12 — `config` is REQUIRED and must be an object: the workflow sandbox has no filesystem, so
// an absent config silently ran every default (branchPrefix 'features/', envSymlink 'required',
// placeholder commands) and surfaced runs later as preflight-stuck / branch-mismatch. Same throw
// idiom as the arg checks above (zero agent spawns, nothing provisioned). The Lead passes the parsed
// `.claude/pipeline.config.json` (commands/deliver.md §1). An explicit `{}` is still accepted.
if (config === null || typeof config !== 'object' || Array.isArray(config)) {
  throw new Error(
    `Missing or invalid arg: config (got ${config === undefined ? 'undefined' : config === null ? 'null' : Array.isArray(config) ? 'array' : typeof config}). ` +
    `Pass the parsed .claude/pipeline.config.json OBJECT (not a string) as args.config — running on defaults is refused (#13).`)
}
if (!['auto', 'semi', 'manual'].includes(mode)) throw new Error(`Invalid mode: ${mode}`)
if (!['plan', 'dev', 'review'].includes(entryStage)) throw new Error(`Invalid entryStage: ${entryStage}`)
if (entryStage === 'review' && !prNumber) throw new Error('entryStage=review requires prNumber argument')
// Run identity (#130): first log line + Setup phase, before any agent call, so runs can be told apart.
log(`deliver #${issue} — ${String(brief).slice(0, 80)}${entryStage === 'review' ? ` (PR #${prNumber})` : ''}`)
phase('Setup')
// planAudit: arg wins per-run over the project default; an explicit `false` beats a
// `true` config (`??` only falls through on null/undefined, never on a real `false`).
const planAuditEnabled = planAudit ?? config.planAudit ?? false
// planFreshness (#103): same arg-wins-over-config precedent as planAudit above. Default
// 'advisory' — a hard gate by default would fire on this repo's own hot file (see the plan's
// design-decision rationale); the human can flip to 'gate' or 'off' via config with zero code.
const planFreshnessMode = planFreshness ?? config.planFreshness ?? 'advisory'
if (!['advisory', 'gate', 'off'].includes(planFreshnessMode)) {
  throw new Error(`Invalid planFreshness: ${JSON.stringify(planFreshnessMode)} (must be 'advisory' | 'gate' | 'off')`)
}
// resumeReason (#183): same local, simple validation idiom as planFreshnessMode above.
if (resumeReason !== null && resumeReason !== 'mergeable-conflicting') {
  throw new Error(`Invalid resumeReason: ${JSON.stringify(resumeReason)} (must be null or 'mergeable-conflicting')`)
}
if (!Number.isInteger(maxAuditRounds) || maxAuditRounds < 1) {
  throw new Error(`Invalid maxAuditRounds: ${maxAuditRounds} (must be an integer >= 1)`)
}
// #97 — dark-launch kill-switch validation (mirrors maxAuditRounds above). 0 is valid and IS
// the shipped default (shadow mode); only a non-integer or a negative value throws.
if (!Number.isInteger(maxPlanAmendRounds) || maxPlanAmendRounds < 0) {
  throw new Error(`Invalid maxPlanAmendRounds: ${maxPlanAmendRounds} (must be an integer >= 0)`)
}
// Audit-budget ceiling. Doctrine budget is 2 rounds; an escalation is a ROUTING
// event, not a signal to keep looping — observed in production: a non-convergent blocker series
// burned a large token budget across repeated relaunches with an ever-rising ceiling before this
// hard ceiling existed. Prose forbade it; nothing enforced it. Past the ceiling the
// caller must NAME the risk class that justifies the extra round(s); the reason is echoed into
// every terminal payload + trace so the justification is auditable.
// Hardcoded, never config-reachable: a config/arg-reachable ceiling would recreate the exact
// bypass-surface class already closed won't-build for the audit-model knob.
const AUDIT_ROUNDS_CEILING = 2
const auditBudgetOverrideReason =
  typeof maxAuditRoundsOverrideReason === 'string' ? maxAuditRoundsOverrideReason.trim() : ''
const auditBudgetOverridden = maxAuditRounds > AUDIT_ROUNDS_CEILING
if (auditBudgetOverridden && !auditBudgetOverrideReason) {
  throw new Error(
    `maxAuditRounds: ${maxAuditRounds} exceeds the doctrine ceiling of ${AUDIT_ROUNDS_CEILING}. ` +
    `Pass a non-empty maxAuditRoundsOverrideReason naming the RISK CLASS that justifies the extra ` +
    `round(s) (plan-audit.md: "Audit budget is 2 rounds, never extended" / "Escalation is decided ` +
    `by RISK CLASS, not by count"). An escalation is a routing event, not a signal to keep looping.`)
}
// #70 — gates HARD preflight check 1 (see preflightPrompt below). ENUM, never interpolated:
// the value only SELECTS a fixed literal check line, so it is NOT part of the
// TRUSTED-OPERATOR raw-interpolation surface that preflight.envNote belongs to.
const envSymlink = config.preflight?.envSymlink ?? 'required'
if (!['required', 'forbidden', 'ignore'].includes(envSymlink)) {
  throw new Error(`Invalid preflight.envSymlink: ${JSON.stringify(envSymlink)} (must be 'required' | 'forbidden' | 'ignore')`)
}
// models (lgtmgate#161): arg wins per-run over the project default, same `??` idiom as
// planAudit/planFreshness above. Default 'sonnet' for all three roles; opus (or any model) stays
// reachable per-run via models.<role>. Theo/Nick are NOT part of this resolution (out of scope).
const modelsCfg = config.models || {}
const scoutModel = models.scout ?? modelsCfg.scout ?? 'sonnet'
const planAuditModel = models.planAudit ?? modelsCfg.planAudit ?? 'sonnet'
const morganModel = models.morgan ?? modelsCfg.morgan ?? 'sonnet'
// Probe-run gate (#80): version of the PROBES registry (the call-site names declared at `const PROBES`).
const PROBES_VERSION = 2
if (dryRun) return finish({ status: 'dry-run-ok', probesVersion: PROBES_VERSION, issue, mode, entryStage, planAudit: planAuditEnabled, planFreshness: planFreshnessMode, maxAuditRounds, maxAuditRoundsOverrideReason: auditBudgetOverrideReason || null, maxPlanAmendRounds, models: { scout: scoutModel, planAudit: planAuditModel, morgan: morganModel } })

const trace = []
if (auditBudgetOverridden) {
  trace.push(`audit-budget-override:${maxAuditRounds}`)
  log(`Audit budget overridden to ${maxAuditRounds} rounds — reason: ${auditBudgetOverrideReason}`)
}

// ---------------------------------------------------------------------------
// Project config — every project-specific value enters here (no hardcoded stack)
// ---------------------------------------------------------------------------

let baseBranch = config.baseBranch || 'develop'
const branchPrefixConfigured = typeof config.branchPrefix === 'string' && config.branchPrefix.trim() !== ''
const branchPrefix = branchPrefixConfigured ? config.branchPrefix : 'features/'
// #232 — branchOverride: arg wins over config.branchOverride, used VERBATIM as the expected branch
// (rebase-without-force-push, numbered slices). Empty/whitespace = unset. Interpolated into shell
// commands in Nick's prompt, so restricted to [A-Za-z0-9._/-].
const branchOverrideRaw = branchOverride ?? config.branchOverride
const branchOverrideName = (typeof branchOverrideRaw === 'string' && branchOverrideRaw.trim()) ? branchOverrideRaw.trim() : null
if (branchOverrideName !== null && !/^[A-Za-z0-9._\/-]+$/.test(branchOverrideName)) {
  throw new Error(`Invalid branchOverride: ${JSON.stringify(branchOverrideName)} (allowed characters: A-Z a-z 0-9 . _ / -)`)
}
const expectedBranchName = branchOverrideName ?? `${branchPrefix}issue-${issue}`
if (!branchPrefixConfigured && branchOverrideName === null) {
  trace.push('branch-prefix-fallback-default')
  log(`config.branchPrefix is not set — expectedBranchName defaulted to ${JSON.stringify(expectedBranchName)}. If this project declares a branchPrefix in .claude/pipeline.config.json, verify the caller threads config through unchanged (a top-level branchPrefix arg is always ignored — #232, see branch-prefix-arg-ignored below).`)
}
const branchPrefixArgIgnored = typeof branchPrefixArg === 'string' && branchPrefixArg !== '' && branchPrefixArg !== branchPrefix
if (branchPrefixArgIgnored) {
  trace.push('branch-prefix-arg-ignored')
  log(`Top-level branchPrefix arg ${JSON.stringify(branchPrefixArg)} is IGNORED (config.branchPrefix ${JSON.stringify(branchPrefix)} wins) — use branchOverride to force a branch name`)
}
// #61 — env read is guarded: the Workflow sandbox injects only args/agent/log/phase, so
// `process` may not exist at all. Under `simulate` the ambient node `process` of
// scripts/run-flow-suite.cjs (new Function wrap) is NEVER read — a real
// LGTMGATE_WORKTREE_ROOT in a dev shell must not leak into a flow case.
// resolveWorktreeRoot() itself is defined below (see its :start/:end sentinel block) — hoisted,
// so this call resolves fine despite the definition appearing later in the file.
const runtimeEnv = simulate
  ? (simulate.probes?.env || {})
  : ((typeof process !== 'undefined' && process && process.env) ? process.env : {})
const worktreeRoot = resolveWorktreeRoot({ env: runtimeEnv, configLocal, config, wtPath })
log(`worktreeRoot: ${worktreeRoot ?? '(unresolved)'} (env=${runtimeEnv.LGTMGATE_WORKTREE_ROOT ? 'set' : 'unset'}, local=${configLocal.worktreeRoot ? 'set' : 'unset'}, config=${config.worktreeRoot ? 'set' : 'unset'})`)
// Code repo "owner/repo" for cross-repo runs: scopes the gh calls (guard, PR-create,
// checks, no-op gate) to the code repo instead of relying on the invoking cwd. Absent ->
// gh resolves from the worktree cwd (backward-compatible; the already-done guard then
// derives the repo from the worktree).
const repo = config.repo || null
const prFlag = repo ? ` -R ${repo}` : ''
// Sandbox-safe push (#108): SSH (port 22 / agent socket) is blocked in the agent sandbox, HTTPS to
// github.com:443 through the gh credential helper is not. Exact command, also quoted to the Lead
// by the delivered-no-pr escalation. `repo` absent -> Nick derives the slug from the origin URL.
const httpsPushCmdFor = (branch) =>
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/${repo || '<owner>/<repo from git remote get-url origin>'}.git refs/heads/${branch}:refs/heads/${branch}`
let conventionsRule = config.conventionsRule || '.claude/rules/conventions.md'
// lgtmgate#139: on a crash-resume ('dev'/'review' entry) re-verify baseBranch/conventionsRule
// against the worktree's OWN pipeline.config.json instead of trusting the possibly-stale
// caller-supplied config.* — same principle as reconcileStaleBranchPrefix, extended to these two
// fields (see reconcileStaleProjectConfig above). Never runs on a fresh 'plan' dispatch (mirrors
// the inverse fresh-vs-resume gate at the base-staleness preflight below) — no reason to pay for a
// recheck on a run that just read this same file at provisioning time.
if (entryStage !== 'plan') {
  let configProjectRecheckRaw = null
  if (simulate) {
    if (simulate.probes?.configProjectRecheckRaw !== undefined) configProjectRecheckRaw = simulate.probes?.configProjectRecheckRaw
  } else {
    try {
      configProjectRecheckRaw = await agent(
        `Run EXACTLY this command: jq -c '{baseBranch, conventionsRule}' "${wtPath}/.claude/pipeline.config.json" 2>/dev/null. ` +
        `Your answer MUST be that command's stdout VERBATIM — nothing else: ` +
        `no sentence, no quotes, no backticks, no markdown, no explanation. ` +
        `If the command itself fails, answer exactly ERROR.`,
        { label: `config-project-recheck-${issue}`, model: 'haiku' },
      )
    } catch (e) {
      log(`Project config guard: pipeline.config.json re-check failed (${e.message}) — keeping caller-supplied values`)
    }
  }
  const reconciled = reconcileStaleProjectConfig(configProjectRecheckRaw)
  if (reconciled.baseBranch && reconciled.baseBranch !== baseBranch) {
    log(`Project config guard: baseBranch "${baseBranch}" stale vs worktree's own pipeline.config.json — reconciling to "${reconciled.baseBranch}"`)
    baseBranch = reconciled.baseBranch
    trace.push('config-baseBranch-reconciled')
  }
  if (reconciled.conventionsRule && reconciled.conventionsRule !== conventionsRule) {
    log(`Project config guard: conventionsRule "${conventionsRule}" stale vs worktree's own pipeline.config.json — reconciling to "${reconciled.conventionsRule}"`)
    conventionsRule = reconciled.conventionsRule
    trace.push('config-conventionsRule-reconciled')
  }
}
const commands = config.commands || {}
const buildCmd = commands.build || 'build the project'
const testCmd = commands.test || 'run the unit tests'
const formatCmd = commands.format || 'format each modified file'
const ciChecks = Array.isArray(config.ciChecks) && config.ciChecks.length
  ? config.ciChecks : ['build-and-test']
const regressionGuard = config.regressionGuard || {}
const testGlob = regressionGuard.testGlob || ''
const testFnPattern = regressionGuard.testFnPattern || 'func test'
const baselineCmd = regressionGuard.baselineCmd || ''
const provisionLinks = config.provision?.extraLinks || []
const canonicalStringBan = config.preflight?.canonicalStringBan || []
// preflight.envNote: free-form, run-specific environment constraints from the Lead (e.g. "the browser
// binary is not installed on this machine — the browser-driven suite is expected to skip").
// Injected VERBATIM at the head of the preflight prompt so it applies to every check, notably the
// HARD test-command check 3. Absent -> the prompt is byte-identical to the pre-existing baseline (the
// HARD/ADVISORY split is informed, never weakened).
// TRUSTED-OPERATOR input, injected unescaped ahead of the hard checks — same exposure class as
// `commands.test` / `regressionGuard.baselineCmd`: a config value that reaches an agent as
// authoritative instruction text, never sanitized or escaped by this file. See README.md
// "How it stays generic" and MAINTAINING.md for the full consumer-facing trust warning.
const envNote = (config.preflight?.envNote || '').trim()
// Detection, never a control: this changes nothing about whether envNote reaches the agent — it
// is a forensics trail only, truncated so it cannot duplicate a secret into the run journal or
// flood it (no hashing primitive is reachable here without a module import, which this slice forbids).
if (envNote) log(`Preflight: operator ENVIRONMENT NOTE injected (${envNote.length} chars): ${envNote.slice(0, 120)}${envNote.length > 120 ? '…[truncated]' : ''}`)
// Stack is a property of the repo, not of a run — no per-run arg. Absent -> the audit
// prompt tells the auditor to infer it from the worktree.
const auditStack = config.stack || ''

// Commit hygiene — pre-handoff squash. OFF unless the project opts in: it only pays off
// where branch commits land verbatim on the base (merge-commit merges). A squash-merge repo
// gets the same result for free.
const commitHygiene = config.commitHygiene || {}
const squashEnabled = commitHygiene.squashBeforeHandoff === true
const squashMaxCommits = Number.isInteger(commitHygiene.maxCommits) ? commitHygiene.maxCommits : 3

// Sandbox blocks TLS on dependency installs (pip/npm/uv/poetry/bundle, or a
// project setup.sh wrapping them) even when the host is in allowedHosts — the
// sandbox network proxy intercepts the TLS handshake; excludedCommands does
// NOT lift this (anthropics/claude-code#36363, closed as duplicate). This is
// a known tooling limitation, not a broken environment — but it is also not
// something the agent may work around unattended (issue #69): stop the
// install and report it as blocked. Never sudo, never a global install, and
// never disable or bypass the sandbox — stay inside the project .venv/node_modules.
const SANDBOX_INSTALL_HINT =
  `Dependency installs (pip/npm/uv/poetry/bundle, or a setup.sh wrapping them) can fail under sandbox ` +
  `with a TLS signature — e.g. "SSLCertVerificationError('OSStatus -26276')", "problem confirming the ` +
  `ssl certificate", "tls: failed to verify certificate", "x509" — even when the host is in allowedHosts ` +
  `(the sandbox network proxy intercepts TLS; excludedCommands does NOT lift this, cf. anthropics/claude-code#36363). ` +
  `This is a known tooling limitation, not a broken environment. Do NOT try to disable, bypass or re-run ` +
  `the tool sandbox to work around it. Stop that install and REPORT IT AS BLOCKED in your return: name ` +
  `the exact command and the exact error signature you saw. The Lead/human decides what to do about ` +
  `the environment — the workflow already escalates this path. Never sudo, never a global install — ` +
  `stay inside the project .venv/node_modules.\n\n` +
  `Separately: never create a Python virtualenv with a bare \`python3 -m venv .venv\` — on a ` +
  `machine where the OS ships its own python3 (e.g. macOS system Python), that bare command can ` +
  `silently create a venv on the WRONG interpreter instead of this project's pinned one (uv, ` +
  `pyenv, .python-version, etc.), and the install that follows then fails with a large, ` +
  `generic-looking "could not find a version that satisfies the requirement / No matching ` +
  `distribution found" dump that reads like a real dependency problem but is actually the wrong ` +
  `interpreter (claude-agent-pipeline#124). Before creating a Python venv, resolve the project's ` +
  `actual pinned interpreter first (check for \`uv\`/\`uv.lock\`/\`pyproject.toml\` ` +
  `requires-python/\`.python-version\`) and create the venv with THAT exact interpreter — e.g. ` +
  `\`uv venv\` if the repo uses uv, or \`/full/path/to/pinned/python3 -m venv .venv\` otherwise ` +
  `— then verify with \`.venv/bin/python3 --version\` before installing. If you still hit that ` +
  `exact error pattern after confirming the interpreter is correct, THEN treat it as a real ` +
  `blocker and report it in your return rather than guessing further.`

// ---------------------------------------------------------------------------
// Plan hand-off (script-variable, mirroring advisory.js)
// The plan travels through the run as a SCRIPT VARIABLE, never re-read from
// GitHub. Sam writes an artifact file AND returns the plan text; downstream
// stages inline `samPlan` into their prompts. On crash-resume (entryStage
// 'dev'/'review') Sam did not run in this process, so the plan is re-materialized
// from `planText` arg, else the agent re-reads the artifact file at `planPath`.
// ---------------------------------------------------------------------------

const planPath = `.pipeline/plans/issue-${issue}-sam.md`
// Hidden HTML marker on the pipeline's OWN plan comment (same idiom as reviewMarker):
// lets an amended plan comment be found and EDITED in place instead of stacked.
const planMarker = `<!-- pipeline-plan:issue-${issue} -->`
// Same idempotent-comment idiom, for Theo's independent design-step-trigger classification
// ("living spec" correction): a quickly-drafted issue's self-declared risk
// tag is never trusted alone; Theo's comment corrects it in place, never stacks a second one.
const designStepMarker = `<!-- pipeline-design-step:issue-${issue} -->`
// The plan comment is an INDEX, never the full plan: GitHub rejects an issue-comment body
// over 65536 chars, so this cap holds by construction.
const planCommentMaxChars = 20000
let samPlan = null  // populated by Sam, or re-materialized on resume
let samTargetFiles = null  // populated by Sam (#103) — worktree-relative paths her plan touches,
                            // consumed by the pre-Dev plan-freshness probe. null on resume (no Plan
                            // phase ran in this process) — the probe degrades to skipped, not thrown.
let samAbsorbedIssues = []  // populated by Sam (#174) — sanitized issue numbers this PR fully closes
                             // alongside #<issue>. Defaults to [] (never null) so the Dev-phase
                             // closesLine composer never needs an extra Array.isArray guard.

// ---------------------------------------------------------------------------
// Stage helpers
// ---------------------------------------------------------------------------

const STAGES = ['plan', 'dev', 'review']
const stageIdx = (s) => STAGES.indexOf(s)
const reached = (s) => s ? stageIdx(s) : -1
const after = (stage, entry) => stageIdx(stage) >= stageIdx(entry)

// gate() — PURE: depends only on mode / proceedThrough / stage / verdict.
// Returns true when the workflow should pause (early return) at this checkpoint.
// Never reads simulate.
const gate = (stage, verdict = null) => {
  if (mode === 'auto') return false
  // proceedThrough = last stage the Lead AUTHORIZED to run. Suppress this checkpoint
  // only when authorized work remains past it. plan/dev checkpoints guard ENTRY into the
  // *next* stage → need authorization strictly beyond the completed stage (`>`). The review
  // checkpoint guards the review revision loop (same stage) → authorized *through* review
  // (`>=`) lets it loop freely. (proceedThrough='plan' must STOP at the plan checkpoint.)
  const authorizedPast =
    stage === 'review'
      ? reached(proceedThrough) >= stageIdx(stage)
      : reached(proceedThrough) > stageIdx(stage)
  if (authorizedPast) return false
  if (mode === 'manual') return true
  if (stage === 'plan') return true
  if (stage === 'review' && verdict === 'REQUIRED_CHANGES') return true
  return false
}

// Normalize an acceptance/blocker item for stable comparison across rounds:
// lowercase, strip punctuation, collapse whitespace. Absorbs cosmetic rewording.
const normItem = (s) =>
  String(s).toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim()

// Human-only acceptance items carry the literal [human-gate] tag (see
// pr-acceptance.md). Detected on the RAW item (normItem would strip the brackets).
const HUMAN_GATE_RE = /\[human-gate\]/i
const isHumanGate = (item) => HUMAN_GATE_RE.test(String(item))
// True when there is ≥1 blocker AND every remaining blocker is human-only.
const allHumanGate = (items) =>
  Array.isArray(items) && items.length > 0 && items.every(isHumanGate)

// Set-subset by NORMALIZED item (was exact-match). round-N ⊆ round-N+1 ⇒ no progress.
function isSubset(smaller, larger) {
  if (!Array.isArray(smaller) || smaller.length === 0 || !Array.isArray(larger)) return false
  const L = larger.map(normItem)
  return smaller.every(i => L.includes(normItem(i)))
}

// Reviewer-window issue selection — pure predicate. An issue is
// a candidate iff its `createdAt` falls INSIDE the reviewer window — a reopened issue keeps its
// ORIGINAL createdAt, so reopening one during the window never makes it a candidate (the class of
// defect that wrongly re-closed a human-reopened issue under the old number-diff mechanism).
// NOT exported (claude-agent-pipeline#132): a second top-level `export` alongside `export const
// meta` above breaks the real Workflow tool's script loader (`SyntaxError: Unexpected keyword
// 'export'` — confirmed live, 0.8.14 is unlaunchable via Workflow). The offline flow-suite's own
// `stripExports` (scripts/run-flow-suite.cjs) strips every top-level `export`, which is why CI
// stayed green on this — a stricter, non-permissive stripper is what the real tool runs. Exactly
// one top-level `export` (the `meta` header) is the invariant now enforced by
// templates/test-canonical-guards.sh's single-export check.
const reviewerWindowCandidates = (issues, windowStart, windowEnd) =>
  (issues || []).filter(i => i && i.createdAt && i.createdAt >= windowStart && i.createdAt <= windowEnd)

// Decision log — durable counterpart to the comment-collapse pass above. Pure body composer.
// --- prBodySplice:start --- (pure & self-contained: templates/pr-body-splice.cjs carries a byte-identical copy, parity-tested)
const DECISION_LOG_START = '<!-- decision-log:start -->'
const DECISION_LOG_END = '<!-- decision-log:end -->'
// Line-anchored (column 0 only) so an INDENTED/fenced illustrative copy of the markers — e.g.
// the example inside "## What this ships" — never matches; only the real, unindented,
// workflow-owned block does. Selects the LAST such pair as a second guard, since the real
// block is always appended/kept at the end of the body (observed in review: an
// un-anchored indexOf() matching the fenced example corrupted it, leaving the real
// trailing block empty forever).
const DECISION_LOG_START_RE = /^<!-- decision-log:start -->[ \t]*$/gm
const DECISION_LOG_END_RE = /^<!-- decision-log:end -->[ \t]*$/gm
// Composes the workflow-owned decision-log block from its entries. Pure.
function composeDecisionLogBlock(entries) {
  return `${DECISION_LOG_START}\n## Decision log\n${entries.join('\n')}\n${DECISION_LOG_END}`
}

// Idempotent splice of a pre-composed decision-log block into a body. Replaces an existing
// block in place; appends at the end when the markers are absent (legacy/resumed PRs). Pure —
// extracted from upsertDecisionLog (issue #87) so the SAME splice algorithm can be embedded
// (via .toString()) into the single deterministic shell chain recordDecision runs, instead of
// being hand-duplicated there.
function spliceDecisionLogBlock(body, block) {
  const src = String(body ?? '')
  let s = -1
  let m
  DECISION_LOG_START_RE.lastIndex = 0
  while ((m = DECISION_LOG_START_RE.exec(src))) s = m.index
  let e = -1
  let eLen = DECISION_LOG_END.length
  DECISION_LOG_END_RE.lastIndex = 0
  while ((m = DECISION_LOG_END_RE.exec(src))) { e = m.index; eLen = m[0].length }
  if (s !== -1 && e !== -1 && e > s) {
    return src.slice(0, s) + block + src.slice(e + eLen)
  }
  return (src.endsWith('\n') ? src : src + '\n') + '\n' + block + '\n'
}

// Idempotent upsert of the workflow-owned decision-log block. Thin wrapper — external behavior
// unchanged (issue #87 step 1: composition/splice split into pure pieces below).
function upsertDecisionLog(body, entries) {
  return spliceDecisionLogBlock(body, composeDecisionLogBlock(entries))
}

// Acceptance-block splice (issue #97) — same line-anchored-marker idiom as the decision log
// above, but FAIL-CLOSED rather than append-on-absent: the decision log is workflow-owned
// (creating it on a legacy/resumed PR is legitimate), the acceptance block is NICK-owned and
// MUST already exist (he copies it verbatim from Sam's checklist at PR-open time per
// pr-acceptance.md) — a missing pair means something upstream is already broken, and silently
// appending a second acceptance block would corrupt the gate block-merge-unchecked.sh reads.
// Selects the LAST marker pair for the SAME reason the decision-log regexes do: a plan artifact
// (this very file's own doc comments included) can contain an earlier, illustrative/fenced copy
// of the marker pair.
const ACCEPTANCE_START = '<!-- acceptance:start -->'
const ACCEPTANCE_END = '<!-- acceptance:end -->'
const ACCEPTANCE_START_RE = /^<!-- acceptance:start -->[ \t]*$/gm
const ACCEPTANCE_END_RE = /^<!-- acceptance:end -->[ \t]*$/gm
// Pure. Replaces the acceptance-block CONTENTS (between the LAST marker pair) with `checklist`
// (the verbatim `- [ ] ...` lines Sam returns for an amendment round). Returns null — NEVER
// appends — when `checklist` is empty/blank or either marker is missing from `body`.
function spliceAcceptanceBlock(body, checklist) {
  const list = String(checklist ?? '').trim()
  if (!list) return null
  const src = String(body ?? '')
  let s = -1
  let sLen = ACCEPTANCE_START.length
  ACCEPTANCE_START_RE.lastIndex = 0
  let m
  while ((m = ACCEPTANCE_START_RE.exec(src))) { s = m.index; sLen = m[0].length }
  let e = -1
  ACCEPTANCE_END_RE.lastIndex = 0
  while ((m = ACCEPTANCE_END_RE.exec(src))) e = m.index
  if (s === -1 || e === -1 || e <= s) return null
  return src.slice(0, s + sLen) + '\n' + list + '\n' + src.slice(e)
}

// Post-write byte/marker guard (issue #87) — protects a PR body read-modify-write against a
// lossy read (e.g. a model summarizing a large command's stdout in its own chat reply instead
// of relaying it verbatim). Pure, synchronous: newBody must be at least 90% of the pre-write
// byte length AND still carry both acceptance-block markers. Scoped to the acceptance block
// (the actual content lost in the #87 incident), not the decision-log markers the workflow
// itself owns and always regenerates correctly.
function bodyWriteGuardOk(preLen, newBody) {
  const b = String(newBody ?? '')
  if (!(b.length >= preLen * 0.9)) return false
  if (!b.includes('<!-- acceptance:start -->')) return false
  if (!b.includes('<!-- acceptance:end -->')) return false
  return true
}
// --- prBodySplice:end ---

// ---------------------------------------------------------------------------
// GH Project config (IDs supplied by the project — see config.ghProject)
// ---------------------------------------------------------------------------

const ghProject = config.ghProject || {}
const STATUS_OPTIONS = ghProject.statusOptions || {}

// ---------------------------------------------------------------------------
// Schemas (verbatim from origin/develop)
// ---------------------------------------------------------------------------

const SAM = {
  type: 'object',
  required: ['decision', 'plan'],
  properties: {
    decision: { enum: ['GO', 'NO-GO'] },
    plan: { type: 'string', description: 'Full plan text — the hand-off payload Nick & Morgan consume verbatim' },
    planPath: { type: 'string', description: 'Worktree-relative path of the plan artifact Sam wrote (e.g. .pipeline/plans/issue-<n>-sam.md)' },
    rationale: { type: 'string' },
    debtIssue: { type: 'string', description: 'Tracking issue # if debt was flagged, else empty' },
    targetFiles: {
      type: 'array',
      items: { type: 'string' },
      description: 'Worktree-relative paths this plan modifies/deletes/creates — used by the pre-Dev plan-freshness probe',
    },
    absorbedIssues: {
      type: 'array',
      items: { type: 'string' },
      description: 'Issue numbers (no "#", e.g. "91") this PR FULLY resolves in addition to #<issue> ' +
        '— never a partial/residual issue (that one stays open, with a forward-reference comment ' +
        'instead of a Closes #). Empty/omitted when this plan is not a bundled/epic dispatch.',
    },
    acceptanceChecklist: {
      type: 'string',
      description: 'Issue #97, plan-amendment rounds only: the FULL amended acceptance checklist ' +
        'as verbatim `- [ ] ...` lines (no markers, no prose) — replaces the PR body\'s acceptance ' +
        'block in place.',
    },
  },
}

const NICK = {
  type: 'object',
  required: ['prNumber', 'branch', 'testsPass'],
  properties: {
    prNumber: { type: 'number' },
    branch: { type: 'string' },
    testsPass: { type: 'boolean' },
    summary: { type: 'string' },
  },
}

// #9: the Lead ticks `proven-untickable` boxes from Morgan's verdict comment (scripts/lead-merge.sh --tick-from-review),
// which only matches one line per box in this exact shape.
const UNTICKABLE_LINE_RULE = 'In the posted verdict comment, for every box you could not tick, write ONE line per box, exactly `- [ ] **<box text verbatim>** — verified, tick pending (permissions): <command> -> <verbatim output>` — never grouped ("Boxes 1-4"), never cited by index ("Box 2"): the Lead ticks from these lines mechanically and skips any other shape. '
const ACCEPTANCE_PRESENCE_RULE = 'If the PR body has no acceptance:start / acceptance:end marker pair, or the block between them holds no `- [ ]` or `- [x]` line, the verdict is REQUIRED_CHANGES (never LGTM) and `items` carries the literal line `Acceptance block absent or empty`. '
const MORGAN = {
  type: 'object',
  required: ['verdict'],
  properties: {
    verdict: { enum: ['LGTM', 'REQUIRED_CHANGES', 'REGRESSION_DETECTED'] },
    items: { type: 'array', items: { type: 'string' } },
    ciGreen: { type: 'boolean' },
    artifactProofs: {
      type: 'array',
      description: 'One entry per ticked acceptance box whose text claims a live/replayed run ' +
        'produced an artifact (report, export, render, log, file at a named path). item is the ' +
        'VERBATIM checklist line; mtime MUST include an explicit UTC \'Z\' or numeric timezone ' +
        'offset (e.g. `date -u +%Y-%m-%dT%H:%M:%SZ`) — a bare timestamp without Z/offset is rejected.',
      items: {
        type: 'object',
        properties: {
          item: { type: 'string' },
          path: { type: 'string' },
          exists: { type: 'boolean' },
          mtime: { type: 'string' },
          bytes: { type: 'number' },
        },
      },
    },
    itemOwners: {
      type: 'array',
      description: 'Optional, one entry per BLOCKED item in `items` (issue #97). `item` MUST be ' +
        'copied VERBATIM from `items`. `itemOwner` classifies WHY the box stays unticked: ' +
        '\'code-defect\' is the DEFAULT whenever you are uncertain — never use a plan owner to ' +
        'excuse unfinished code. A plan owner (\'plan-defect\' | \'checklist-wording-defect\') ' +
        'REQUIRES a concrete `proof` quoting the exact contradiction between the plan/checklist ' +
        'and reality (e.g. a command + its output). An item with no entry here, or an entry with ' +
        'an empty proof, is treated as a code defect.' +
        ' \'proven-untickable\' = the box\'s own verification was actually run and PASSED, and the ONLY reason it is still `- [ ]` is that ticking it (`gh pr edit`) was denied by permissions; it REQUIRES a non-empty `proof` (command + verbatim output) and is never valid for a `[human-gate]` item nor for a box whose verification failed or was not run.',
      items: {
        type: 'object',
        properties: {
          item: { type: 'string' },
          itemOwner: { enum: ['code-defect', 'plan-defect', 'checklist-wording-defect', 'proven-untickable'] },
          proof: { type: 'string' },
        },
      },
    },
  },
}

const PLAN_CHECK = {
  type: 'object',
  required: ['verdict'],
  properties: {
    verdict: { enum: ['CONFORMING', 'NOT_CONFORMING'] },
    issues: { type: 'array', items: { type: 'string' } },
  },
}

const PLAN_AUDIT = {
  type: 'object',
  required: ['verdict', 'findings'],
  properties: {
    verdict: { enum: ['SOUND', 'SOUND-WITH-NOTES', 'NOT_SOUND'] },
    findings: {
      type: 'array',
      description: 'Ranked most-damaging first.',
      items: {
        type: 'object',
        properties: {
          severity: { enum: ['blocking', 'note'] },
          area: { enum: ['security', 'idiomacy', 'debt', 'correctness'] },
          title: { type: 'string' },
          finding: { type: 'string' },
          fix: { type: 'string' },
          debtClass: { enum: ['fenced-debt', 'accidental-debt', 'structural-mistake'] },
          sources: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    stackVerified: { type: 'string', description: 'What was checked against current docs and with which tool/doc id.' },
  },
}

const ALREADY_DONE_CHECK = {
  type: 'object',
  required: ['isAlreadyDone'],
  properties: {
    isAlreadyDone: { type: 'boolean' },
    isIssueClosed: { type: 'boolean' },
    isMerged: { type: 'boolean' },
    mergedAt: { type: 'string' },
    issueState: { type: 'string' },
    issueCreatedAt: { type: 'string' },
    mergedPr: { type: 'number' },
    mergedHeadRef: { type: 'string' },
    mergedPrClosesIssue: { type: 'boolean' },
    checkFailed: { type: 'boolean' },
    error: { type: 'string' },
  },
}

const PREFLIGHT = {
  type: 'object',
  required: ['pass'],
  properties: {
    pass: { type: 'boolean' },
    issues: { type: 'array', items: { type: 'string' } },
    testCommandRun: { type: 'string', description: 'Check-3 test command as actually executed, verbatim (drift forensics)' },
    failedChecks: {
      type: 'array',
      description: 'Check 5: one entry per required check in FAILURE state (#132); the engine folds it into issues',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          step: { type: 'string', description: 'Failing step name as printed by gh run view --log-failed' },
          logTail: { type: 'string', description: 'last failing lines of the check log, verbatim' },
        },
      },
    },
  },
}

const DIAGNOSIS = {
  type: 'object',
  required: ['confirmed', 'evidence'],
  properties: {
    confirmed: { type: 'boolean' },
    evidence: { type: 'string', description: 'Concrete repro (command run + observed output) proving or refuting the claimed cause' },
    actualCause: { type: 'string', description: 'If refuted, the real cause if found; else empty' },
    laneOk: { type: 'boolean', description: 'False if the issue is on the WRONG scout lane (user-visible surface routed to the mechanical/backend scout) — see requiredScout' },
    requiredScout: { type: 'string', description: 'When laneOk is false, the product scout the project should re-dispatch with (project-specific — e.g. a mobile or backend specialist)' },
    // Design-step-trigger signals — independently classified by Theo against the
    // REAL code/cited docs, never trusted from the issue's own self-declared risk tag (same
    // "never trust a self-report" principle as debtClass staying informative-only in the audit).
    // Each is a raw boolean the SCRIPT counts mechanically (see designStepTriggered below) — Theo
    // never self-reports the aggregate trigger itself, only the individual signals + evidence.
    persistentStateSignal: { type: 'boolean', description: 'True if the issue creates/modifies data with a multi-request lifecycle (not transient/in-memory)' },
    authSecurityBoundarySignal: { type: 'boolean', description: 'True if the issue decides who may do what, or opens new attack surface' },
    deployConfigSignal: { type: 'boolean', description: 'True if the issue touches infra/production config whose blast radius is the whole service (env vars, IAM, DNS, ALLOWED_HOSTS-class settings)' },
    immatureVendorApiSignal: { type: 'boolean', description: 'True if the issue depends on a vendor/API primitive a CITED source calls preview/beta/not-production-ready, or one nothing in this codebase has used in production before' },
    designStepSignalEvidence: { type: 'string', description: 'One line per true signal above, citing the code/doc that grounds it — same evidentiary bar as confirmed/evidence' },
    issueClassificationMismatch: { type: 'boolean', description: "True if the issue's own stated risk/lane classification (or its absence) disagrees with Theo's independent read above" },
  },
}

// ---------------------------------------------------------------------------
// Agent-id normalization
// ---------------------------------------------------------------------------

// Pipeline agents ship via the lgtmgate plugin and are registered under
// namespaced ids (lgtmgate:Sam, …). Bare role names (Sam, Nick, …) are
// invalid and cause agent() to throw. normalizeAgentType makes the mapping
// idempotent: already-namespaced ids pass through unchanged.
//
const PIPELINE_ROLES = new Set(['Mia', 'Sam', 'Nick', 'Morgan', 'Theo'])

function normalizeAgentType(agentType) {
  if (!agentType) return agentType
  if (agentType.includes(':')) return agentType  // already namespaced
  if (PIPELINE_ROLES.has(agentType)) return `lgtmgate:${agentType}`
  return agentType
}

// --- acceptAlreadyDone:start --- (pure & self-contained — keep extractable by the consuming project's tests)
function acceptAlreadyDone(guard, expectedHead, asOfIso) {
  const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/
  if (!guard || typeof guard !== 'object') return { accepted: false, reason: 'no-guard-response' }
  if (guard.checkFailed === true) return { accepted: false, reason: 'gh-tool-failure' }
  if (guard.isIssueClosed === true && guard.issueState === 'CLOSED') return { accepted: true, reason: 'issue-closed' }
  if (guard.isMerged !== true) return { accepted: false, reason: 'unsubstantiated' }
  if (!expectedHead || guard.mergedHeadRef !== expectedHead) return { accepted: false, reason: 'merged-head-mismatch' }
  if (guard.mergedPrClosesIssue === false) return { accepted: false, reason: 'merged-pr-does-not-close-issue' }
  const at = typeof guard.mergedAt === 'string' ? guard.mergedAt.trim() : ''
  if (!ISO.test(at)) return { accepted: false, reason: 'merged-without-valid-timestamp' }
  if (!Number.isInteger(guard.mergedPr) || guard.mergedPr <= 0) return { accepted: false, reason: 'merged-without-pr-number' }
  const t = Date.parse(at)
  const now = Date.parse(asOfIso)
  if (Number.isFinite(now) && t > now) return { accepted: false, reason: 'merged-in-the-future' }
  const created = typeof guard.issueCreatedAt === 'string' ? Date.parse(guard.issueCreatedAt) : NaN
  if (Number.isFinite(created) && t < created) return { accepted: false, reason: 'merged-before-issue-created' }
  return { accepted: true, reason: 'merged' }
}
// --- acceptAlreadyDone:end ---

// --- parseHeadRef:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Reads the branch-check agent's raw answer and extracts a validated bare ref out of it, instead
// of trusting the agent's prose verbatim as a ref (lgtmgate#71: the incident's real answer
// was "PR #776 is on branch `feat/issue-760`." — a sentence, not a ref). Returns the bare ref on a
// single unambiguous read, otherwise null (ambiguous/unreadable → caller falls back to nick.branch).
function parseHeadRef(raw, expectedBranch) {
  const s = String(raw ?? '').trim()
  if (!s) return null
  const isCandidate = c => /^[A-Za-z0-9._/-]+$/.test(c) && (c === expectedBranch || /[/-]/.test(c))

  // Tier 1 — the whole trimmed answer IS a bare ref (the mechanical happy path: `gh pr view`'s
  // own stdout, `feat/issue-70\n`, once trimmed).
  if (isCandidate(s)) return s

  // Tier 2 — backtick-quoted tokens (the shape the real incident produced).
  const backticked = new Set()
  for (const m of s.matchAll(/`([^`\n]+)`/g)) {
    if (isCandidate(m[1])) backticked.add(m[1])
  }
  if (backticked.size > 0) return backticked.size === 1 ? [...backticked][0] : null

  // Tier 3 — only when no backtick-quoted candidate exists: whitespace-split tokens, stripped of
  // surrounding quote/paren punctuation and trailing sentence punctuation.
  const loose = new Set()
  for (const tok of s.split(/\s+/)) {
    const stripped = tok.replace(/^["'(]+/, '').replace(/["')]+$/, '').replace(/[.,;:]+$/, '')
    if (isCandidate(stripped)) loose.add(stripped)
  }
  return loose.size === 1 ? [...loose][0] : null
}
// --- parseHeadRef:end ---

// --- reconcileStaleBranchPrefix:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// lgtmgate#131: on a cross-repo re-route, the CALLER-supplied config.branchPrefix (baked into
// expectedBranch upstream) can be stale for the repo the worktree actually operates on — a headRef
// that looks like a mismatch against expectedBranch can still be the target repo's real convention.
// Continues the same "don't trust an unverified value, verify against what's really there"
// principle already applied to the right-hand side of the comparison (parseHeadRef above,
// lgtmgate#71/#76) — here applied to the left-hand side (branchPrefix, never re-verified
// until now). Re-grounds against the worktree's OWN pipeline.config.json (already checked out
// against the correct repo/branch) rather than the caller's possibly-stale value. Returns the
// reconciled ref on an EXACT match, otherwise null — deliberately no partial/prefix leniency: an
// empty string or the 'ERROR' sentinel must never be accepted as a valid prefix (either would let
// `${''}issue-${issue}` or `${'ERROR'}issue-${issue}` accidentally match a real headRef).
function reconcileStaleBranchPrefix(headRef, issue, realBranchPrefixRaw) {
  const raw = String(realBranchPrefixRaw ?? '').trim()
  if (!raw || raw === 'ERROR' || !/^[A-Za-z0-9._/-]+$/.test(raw)) return null
  const reconciled = `${raw}issue-${issue}`
  return headRef === reconciled ? reconciled : null
}
// --- reconcileStaleBranchPrefix:end ---

// --- reconcileStaleProjectConfig:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// lgtmgate#139: extends reconcileStaleBranchPrefix's "don't trust an unverified value,
// verify against what's really there" principle (above) from branchPrefix to baseBranch/
// conventionsRule — both are caller-supplied config.* read once at dispatch and never re-read
// from the worktree's own pipeline.config.json on a crash-resume. rawJson is the verbatim stdout
// of `jq -c '{baseBranch, conventionsRule}' pipeline.config.json` (or the 'ERROR' sentinel, or
// garbage). Returns { baseBranch, conventionsRule }, each the worktree's own value when it passes
// the same non-empty/not-'ERROR'/^[A-Za-z0-9._/-]+$ validation as reconcileStaleBranchPrefix, else
// null (never accept a blank or malformed value as a "reconciled" one).
function reconcileStaleProjectConfig(rawJson) {
  const validate = (v) => {
    const raw = String(v ?? '').trim()
    return (!raw || raw === 'ERROR' || !/^[A-Za-z0-9._/-]+$/.test(raw)) ? null : raw
  }
  let parsed
  try {
    parsed = JSON.parse(String(rawJson ?? ''))
  } catch (e) {
    parsed = null
  }
  return {
    baseBranch: validate(parsed?.baseBranch),
    conventionsRule: validate(parsed?.conventionsRule),
  }
}
// --- reconcileStaleProjectConfig:end ---

// --- staleArtifactBlockers:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Re-derives whether Morgan's claimed run-artifact proofs actually hold, instead of trusting
// her verdict alone (same doctrine as acceptAlreadyDone above, one lane earlier).
// Returns [] when nothing is wrong; otherwise one { item, reason } per rejected proof, in the
// FIRST-matching-reason order below. Pure: no I/O, no closure over simulate/config/trace.
function staleArtifactBlockers(proofs, floorIso) {
  if (!Array.isArray(proofs) || proofs.length === 0) return []
  // Accepts an explicit UTC 'Z' or a numeric offset: Morgan stats artifacts on the local
  // machine, so a valid ISO-8601 like 2026-08-11T18:02:02+02:00 must not be rejected
  // (the staleness compare below already goes through Date.parse, offset-aware).
  const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/
  const floorMs = typeof floorIso === 'string' ? Date.parse(floorIso) : NaN
  const floorValid = Number.isFinite(floorMs)
  const blockers = []
  for (const p of proofs) {
    if (!p || typeof p !== 'object') {
      blockers.push({ item: '', reason: 'malformed-proof' })
      continue
    }
    const item = typeof p.item === 'string' ? p.item : ''
    if (typeof p.path !== 'string' || p.path.trim() === '') {
      blockers.push({ item, reason: 'no-path' }); continue
    }
    if (p.exists !== true) {
      blockers.push({ item, reason: 'artifact-absent' }); continue
    }
    if (Number.isFinite(p.bytes) && p.bytes <= 0) {
      blockers.push({ item, reason: 'artifact-empty' }); continue
    }
    const mtime = typeof p.mtime === 'string' ? p.mtime : ''
    if (!ISO.test(mtime)) {
      blockers.push({ item, reason: 'no-valid-mtime' }); continue
    }
    if (floorValid && Date.parse(mtime) < floorMs) {
      blockers.push({ item, reason: 'artifact-stale' }); continue
    }
  }
  return blockers
}
// --- staleArtifactBlockers:end ---

// --- resolveWorktreeRoot:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// resolveWorktreeRoot (#61) — layered, machine-free worktree-root resolution.
// Precedence: $LGTMGATE_WORKTREE_ROOT > configLocal.worktreeRoot > config.worktreeRoot
// (the versioned LOGICAL default). A winner is accepted only when ABSOLUTE; a relative
// or blank value falls back to this run's own worktree parent — wtPath is
// `<worktreeRoot>/<slug>` by construction (commands/deliver.md:35) — so the brief
// never carries a relative root. No candidate and no absolute wtPath -> null, which is
// exactly the pre-#61 `config.worktreeRoot || null` behaviour (clause omitted).
function resolveWorktreeRoot({ env = {}, configLocal = {}, config = {}, wtPath = '' }) {
  const pick = (v) => (typeof v === 'string' && v.trim() ? v.trim() : null)
  const strip = (p) => (p.length > 1 ? p.replace(/\/+$/, '') : p)
  const abs = (v) => (v && v.startsWith('/') ? strip(v) : null)
  const parentOfWt = (() => {
    const p = abs(pick(wtPath))
    if (!p) return null
    const i = p.lastIndexOf('/')
    return i >= 0 ? (p.slice(0, i) || '/') : null
  })()
  const candidate = pick(env.LGTMGATE_WORKTREE_ROOT) || pick(configLocal.worktreeRoot) || pick(config.worktreeRoot)
  return abs(candidate) || parentOfWt
}
// --- resolveWorktreeRoot:end ---

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

// --- safePlanTargets:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Sanitizes Sam's declared `targetFiles` (#103) BEFORE any value is interpolated into the shell
// command the plan-freshness probe below hands a haiku agent. Charset allowlist + no absolute
// path + no `..` segment, deduped, capped at 25 entries. Anything else is dropped SILENTLY —
// never throws (an LLM-authored plan is untrusted input, not a contract violation to surface).
function safePlanTargets(files) {
  if (!Array.isArray(files)) return []
  const SAFE = /^[A-Za-z0-9._/-]+$/
  const seen = new Set()
  const out = []
  for (const f of files) {
    if (out.length >= 25) break
    if (typeof f !== 'string') continue
    const p = f.trim()
    if (!p || !SAFE.test(p)) continue
    if (p.startsWith('/')) continue
    if (p.split('/').includes('..')) continue
    if (seen.has(p)) continue
    seen.add(p)
    out.push(p)
  }
  return out
}
// --- safePlanTargets:end ---

// --- oneWayDoor:start --- (pure & self-contained — R3: the 5th design-step signal, computed by the script)
// R3 one-way-door signal. Both inputs are per-project config, so a repo that declares neither is never
// stopped and its Sam is never asked about kinds. A plan stops at the design step on exactly two things:
// (a) an announcement line in Sam's plan, `one-way-door: <kind> — <what>`, for a kind the repo declares in
// `config.oneWayDoorKinds` (ctx.kinds; a subset of status|agent|hook|seam, default none). Sam is asked to
// announce only those kinds (samOneWayDoorText; an empty list asks nothing); `one-way-door: none`, an
// undeclared kind or any other word announces nothing; (b) Sam's `targetFiles` matched against
// `config.oneWayDoorPaths` (ctx.paths; default none). Deterministic inputs, never an LLM-filled boolean.
// A path entry is, in order: `!<entry>` = exclusion (wins over any match); `<dir>/` = prefix;
// a pattern with `*` (within a segment), `**` (across segments) or `?` = glob; else the exact path.
// oneWayDoorSignals returns { kinds: string[], summary: string[<=10] }.
const ONE_WAY_DOOR_KINDS = ['status', 'agent', 'hook', 'seam']
// The declared kinds, in canonical order: unknown words, non-strings and duplicates are dropped.
function oneWayDoorKindsOf(raw) {
  const given = (Array.isArray(raw) ? raw : []).filter(e => typeof e === 'string').map(e => e.trim().toLowerCase())
  return ONE_WAY_DOOR_KINDS.filter(k => given.includes(k))
}
// Sam's announcement instruction for the declared kinds only; '' when the repo declares none.
function samOneWayDoorText(rawKinds) {
  const kinds = oneWayDoorKindsOf(rawKinds)
  if (kinds.length === 0) return ''
  return 'ONE-WAY-DOOR ANNOUNCEMENT: in the plan text, state on its own line for each of these kinds the diff adds — ' +
    kinds.map(k => `\`one-way-door: ${k} — <what>\``).join(', ') +
    ' — or the single line `one-way-door: none`. The script parses these lines; a kind you announce stops the run at the design step. '
}
function oneWayDoorSignals(plan, targetFiles, ctx = {}) {
  const globMatch = (pat, s) => {
    const go = (pi, si) => {
      while (pi < pat.length) {
        if (pat[pi] === '*') {
          const deep = pat[pi + 1] === '*'
          let np = pi + 1
          while (pat[np] === '*') np++
          if (np === pat.length) return deep || !s.slice(si).includes('/')
          for (let k = si; k <= s.length; k++) {
            if (go(np, k)) return true
            if (k < s.length && s[k] === '/' && !deep) break
          }
          return false
        }
        if (si >= s.length) return false
        if (pat[pi] === '?' ? s[si] === '/' : pat[pi] !== s[si]) return false
        pi++; si++
      }
      return si === s.length
    }
    return go(0, 0)
  }
  const entryHit = (entry, f) => entry.endsWith('/') ? f.startsWith(entry)
    : (entry.includes('*') || entry.includes('?')) ? globMatch(entry, f) : f === entry
  const entries = (Array.isArray(ctx.paths) ? ctx.paths : [])
    .filter(e => typeof e === 'string' && e.trim() !== '').map(e => e.trim())
  const excluded = entries.filter(e => e.startsWith('!')).map(e => e.slice(1))
  const included = entries.filter(e => !e.startsWith('!'))
  const found = new Map() // kind -> evidence line
  for (const f of safePlanTargets(targetFiles)) {
    if (excluded.some(e => entryHit(e, f))) continue
    const hit = included.find(e => entryHit(e, f))
    if (hit !== undefined && !found.has('path')) found.set('path', `targetFiles: ${f} (oneWayDoorPaths: ${hit})`)
  }
  const declared = oneWayDoorKindsOf(ctx.kinds)
  // guards:parser-begin
  const announced = declared.length === 0 ? []
    : String(plan ?? '').match(/^[ \t>*-]*`?one-way-door:[ \t]*(?:status|agent|hook|seam)\b[^\n]*/gim) || []
  for (const line of announced) {
    const m = /one-way-door:[ \t]*(status|agent|hook|seam)\b/i.exec(line)
    const kind = m[1].toLowerCase()
    if (declared.includes(kind) && !found.has(kind)) found.set(kind, `plan: ${line.replace(/^[ \t>*-]*`?/, '').slice(0, 160)}`)
  }
  // guards:parser-end
  const kinds = [...found.keys()]
  const summary = kinds.length === 0 ? [] : [
    `R3 one-way-door: the plan for issue #${ctx.issue ?? '?'} hits a one-way door (${kinds.join(' + ')}).`,
    ...kinds.map(k => `- ${k}: ${found.get(k)}`),
    `Plan artifact: ${ctx.planPath || '(none)'}`,
    'Stopped at the design step (design-step-required): the maintainer decides before dev.',
    `Relaunch with architectureDecisionApproved:true once the decision is recorded.`,
  ].slice(0, 10)
  return { kinds, summary }
}
// --- oneWayDoor:end ---

// --- safeAbsorbedIssues:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Sanitizes Sam's declared `absorbedIssues` (#174) BEFORE it is spread into the Closes# line handed
// to Nick. Digit-only charset, deduped, capped at 20 entries, and the epic's own issue number is
// dropped if Sam accidentally repeats it (it is already closed via #<issue> itself). Anything else
// is dropped SILENTLY — never throws (an LLM-authored plan is untrusted input, mirrors safePlanTargets).
function safeAbsorbedIssues(list, selfIssue) {
  if (!Array.isArray(list)) return []
  const SAFE = /^\d+$/
  const self = String(selfIssue).trim()
  const seen = new Set()
  const out = []
  for (const n of list) {
    if (out.length >= 20) break
    if (typeof n !== 'string' && typeof n !== 'number') continue
    const s = String(n).trim()
    if (!s || !SAFE.test(s)) continue
    if (s === self) continue
    if (seen.has(s)) continue
    seen.add(s)
    out.push(s)
  }
  return out
}
// --- safeAbsorbedIssues:end ---

// --- subIssuesGate:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Decides whether the dispatched issue's own `Closes #<issue>` may be composed (lgtmgate#193).
// Root cause: all 5 real incidents (#156-160) were pipeline-authored PRs whose body unconditionally
// claimed `Closes #<epic>` while the epic still had an open GitHub-native sub-issue untouched by
// that run. `openSubIssues` is the raw list of open sub-issue numbers reported by the GitHub API
// (strings or numbers); `absorbedIssues` is this run's own safeAbsorbedIssues() output (already-
// resolved children). Anything in openSubIssues NOT covered by absorbedIssues blocks the epic's
// own Closes#. Never throws (an external API response is untrusted input, mirrors safeAbsorbedIssues).
function subIssuesGate(openSubIssues, absorbedIssues) {
  const absorbed = new Set((Array.isArray(absorbedIssues) ? absorbedIssues : []).map(String))
  const SAFE = /^\d+$/
  const uncovered = (Array.isArray(openSubIssues) ? openSubIssues : [])
    .map(String)
    .filter(s => SAFE.test(s) && !absorbed.has(s))
  return { blocked: uncovered.length > 0, uncovered }
}
// --- subIssuesGate:end ---

// --- planFreshnessNote:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Composes the Nick-facing plan-freshness warning (#103) — same shape/contract as
// worktreeFreshnessNote above: pure, no I/O, no closure over simulate/config/trace. Returns ''
// when staleFiles is not a non-empty array, so an unaffected run's Dev prompt stays byte-identical.
function planFreshnessNote(staleFiles, baseBranch) {
  if (!Array.isArray(staleFiles) || staleFiles.length === 0) return ''
  const list = staleFiles.map(f => `- ${f}`).join('\n')
  return (
    `PLAN FRESHNESS WARNING (#103): the following file(s) this plan targets changed on ` +
    `origin/${baseBranch} since this worktree's frozen base:\n${list}\n` +
    `Read the upstream version of each with \`git show origin/${baseBranch}:<file>\` — read-only, ` +
    `no worktree mutation. If the plan's premise for that file no longer holds (it plans to ` +
    `delete/rewrite content that moved upstream), STOP and report it in your return summary ` +
    `instead of opening the PR. If the premise still holds, implement as planned. Do not rebase, ` +
    `reset, pull or otherwise move the worktree to reconcile this — the frozen base is deliberate.\n\n`
  )
}
// --- planFreshnessNote:end ---

// --- resumeReasonNote:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Composes the Nick-facing resume-reason note (#183, absorbing #119/#169's second half) — same
// shape/contract as planFreshnessNote above. Returns '' when resumeReason is not the recognized
// value, so an ordinary plan->dev handoff (resumeReason omitted) stays byte-identical. Threads WHY a
// dev-phase resume was launched so Nick reasons from the LIVE PR state instead of concluding
// "already done" from branch/plan content alone (the gap Theo confirmed empirically on #183: a
// synthetic CONFLICTING-mergeState run produced a nickPrompt with zero conflict/mergeable/resum
// signal).
function resumeReasonNote(resumeReason, prNumberArg, baseBranch) {
  if (resumeReason !== 'mergeable-conflicting') return ''
  const prRef = prNumberArg ? `PR #${prNumberArg}` : 'the existing PR for this branch'
  return (
    `RESUME REASON (#183): this dev-phase resume was triggered by a mergeable-conflicting escalate ` +
    `(lgtmgate#170), NOT a fresh plan->dev handoff. Do NOT conclude "already done" from the ` +
    `branch/plan content alone. Before doing anything else, re-check ${prRef}'s LIVE state: ` +
    `\`gh pr view ${prNumberArg || '<PR>'} --json mergeable,mergeStateStatus,headRefName\`. If ` +
    `mergeable is still CONFLICTING, reconcile the branch against origin/${baseBranch} per this ` +
    `project's own git-workflow rule before re-pushing — a conflict is real work to do, not a stale ` +
    `read.\n\n`
  )
}
// --- resumeReasonNote:end ---

// --- subIssuesGateNote:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Composes the Nick-facing sub-issues-gate note (lgtmgate#193) — same shape/contract as
// planFreshnessNote/resumeReasonNote above. Returns '' when uncovered is not a non-empty array,
// so the overwhelmingly common zero-sub-issue dispatch keeps a byte-identical Dev prompt.
function subIssuesGateNote(uncovered, issueArg) {
  if (!Array.isArray(uncovered) || uncovered.length === 0) return ''
  const list = uncovered.map(n => `#${n}`).join(', ')
  return (
    `SUB-ISSUES GATE (lgtmgate#193): #${issueArg} has ${uncovered.length} open GitHub ` +
    `sub-issue(s) not covered by this run's bundle (${list}) — the first line above intentionally ` +
    `uses "(see #${issueArg})" instead of "Closes #${issueArg}" for THAT issue only (absorbed ` +
    `children, if any, still close normally). Do NOT describe #${issueArg} or the epic as fully ` +
    `resolved anywhere else in the PR body. `
  )
}
// --- subIssuesGateNote:end ---

// --- auditRouting:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Routes the independent plan-audit verdict to proceed / amend / escalate. Pure: no I/O,
// no closure over simulate/config/trace. Findings SEVERITY drives routing, not verdict alone —
// a SOUND-WITH-NOTES verdict can still carry a blocking finding (observed in production: a
// SOUND-WITH-NOTES review that still needed a blocking fix). Missing/unknown severity is treated as blocking
// (fail-closed): an LLM omitting the field must never silently downgrade a finding. An
// unrecognized/absent verdict is malformed output and never passes the gate.
function auditRouting(audit, round, maxRounds) {
  const VERDICTS = ['SOUND', 'SOUND-WITH-NOTES', 'NOT_SOUND']
  if (!audit || typeof audit !== 'object' || !VERDICTS.includes(audit.verdict)) {
    return { action: 'escalate', reason: 'plan-audit-malformed', blocking: [] }
  }
  const findings = Array.isArray(audit.findings) ? audit.findings : []
  const blocking = findings.filter(f => !f || f.severity !== 'note')
  const hasBlockingSignal = audit.verdict === 'NOT_SOUND' || blocking.length > 0
  if (!hasBlockingSignal) return { action: 'proceed', blocking }
  if (round >= maxRounds) return { action: 'escalate', reason: 'plan-not-sound', blocking }
  return { action: 'amend', blocking }
}
// --- auditRouting:end ---

// --- composeAuditFixBlock:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Composes the ONE consolidated amendment block appended to the scout's next prompt.
// Pure: no I/O, no closure. '' when there is nothing to fold in, so an off-path prompt (audit
// disabled, or a SOUND first pass) stays byte-identical to the state before this mechanism existed.
function composeAuditFixBlock(findings) {
  const list = Array.isArray(findings) ? findings : []
  if (list.length === 0) return ''
  const header =
    'ONE consolidated amendment round; the auditor did NOT write this plan; fold every BLOCKING ' +
    'finding in by rewriting the affected step, not by bolting on a caveat; for each NOTE either ' +
    'fold it in or state in the plan why it is declined; verify technical claims against current ' +
    'docs yourself, never from memory.'
  const entries = list.map((f, i) => {
    const sev = f && f.severity === 'note' ? 'NOTE' : 'BLOCKING'
    const debtClass = f && f.debtClass ? `[${f.debtClass}]` : ''
    const title = f && f.title ? f.title : '(untitled finding)'
    const finding = f && f.finding ? f.finding : ''
    const fix = f && f.fix ? f.fix : ''
    const sources = Array.isArray(f && f.sources) && f.sources.length ? `\nsources: ${f.sources.join(', ')}` : ''
    return `${i + 1}. [${sev}]${debtClass} ${title} — ${finding}\nFIX: ${fix}${sources}`
  })
  return `${header}\n\n${entries.join('\n\n')}`
}
// --- composeAuditFixBlock:end ---

// --- classifyBlockers:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Issue #97 — splits Morgan's REQUIRED_CHANGES `items` into plan-owned routes (Sam amends the
// plan) vs code-owned items (Nick still fixes them), from her OPTIONAL parallel `itemOwners`
// array. Fail-safe by construction: absent/empty `itemOwners`, an unknown owner, an empty/
// missing `proof`, an item that doesn't match anything in `items`, or a `[human-gate]` item
// all fall through to `codeItems` — a plan owner NEVER excuses unfinished code by default. When
// `itemOwners` is absent/empty this returns `{ planRoutes: [], codeItems: items }`, byte-
// identical to the pre-#97 historical path.
function classifyBlockers(items, itemOwners) {
  const allItems = Array.isArray(items) ? items : []
  const owners = Array.isArray(itemOwners) ? itemOwners : []
  if (owners.length === 0) return { planRoutes: [], codeItems: allItems }
  const normItems = allItems.map(normItem)
  const planRoutes = []
  const routedNorm = new Set()
  for (const o of owners) {
    if (!o || typeof o !== 'object') continue
    const owner = o.itemOwner
    if (owner !== 'plan-defect' && owner !== 'checklist-wording-defect') continue
    const proof = typeof o.proof === 'string' ? o.proof.trim() : ''
    if (!proof) continue
    const item = typeof o.item === 'string' ? o.item : ''
    if (!item || isHumanGate(item)) continue
    const n = normItem(item)
    if (!normItems.includes(n)) continue
    planRoutes.push({ item, itemOwner: owner, proof })
    routedNorm.add(n)
  }
  const codeItems = allItems.filter(i => !routedNorm.has(normItem(i)))
  return { planRoutes, codeItems }
}
// --- classifyBlockers:end ---

// --- classifyUntickable:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Issue #228 — splits Morgan's REQUIRED_CHANGES `items` into boxes she PROVED but could not tick
// (ticking `gh pr edit` denied by session permissions) vs everything else, from her OPTIONAL
// `itemOwners` array. Fail-safe by construction: absent/empty `itemOwners`, an owner other than
// 'proven-untickable', an empty/missing `proof`, an item matching nothing in `items`, or a
// `[human-gate]` item all fall through to `rest` (legacy path). Pure: never ticks anything.
// Issue #107 — `opts.checklistKind` (the engine passes it only while plan amendment is off,
// maxPlanAmendRounds === 0) also parks a 'checklist-wording-defect' item that carries a proof: a
// checklist/tick blocker is never a Nick fix. Morgan's structured `itemOwner` is the only signal.
function classifyUntickable(items, itemOwners, opts) {
  const parkOwners = opts && opts.checklistKind ? ['proven-untickable', 'checklist-wording-defect'] : ['proven-untickable']
  const allItems = Array.isArray(items) ? items : []
  const owners = Array.isArray(itemOwners) ? itemOwners : []
  if (owners.length === 0) return { untickable: [], rest: allItems }
  const normItems = allItems.map(normItem)
  const untickable = []
  const parkedNorm = new Set()
  for (const o of owners) {
    if (!o || typeof o !== 'object') continue
    if (!parkOwners.includes(o.itemOwner)) continue
    const proof = typeof o.proof === 'string' ? o.proof.trim() : ''
    if (!proof) continue
    const item = typeof o.item === 'string' ? o.item : ''
    if (!item || isHumanGate(item)) continue
    const n = normItem(item)
    if (!normItems.includes(n) || parkedNorm.has(n)) continue
    const verbatim = allItems[normItems.indexOf(n)]
    untickable.push({ item: verbatim, proof })
    parkedNorm.add(n)
  }
  const rest = allItems.filter(i => !parkedNorm.has(normItem(i)))
  return { untickable, rest }
}
// --- classifyUntickable:end ---

// --- composeReviewFixBlock:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Composes the ONE consolidated plan-amendment block appended to the scout prompt for the
// review-loop amendment round (issue #97) — modelled 1:1 on composeAuditFixBlock above. Pure:
// no I/O, no closure. '' when there is nothing to fold in, so the off-path scout prompt stays
// byte-identical (shadow mode / no plan routes never reaches this call site anyway — see the
// router in the Review phase).
function composeReviewFixBlock(routes) {
  const list = Array.isArray(routes) ? routes : []
  if (list.length === 0) return ''
  const header =
    'ONE consolidated amendment round from a Morgan review — she classified these acceptance ' +
    'items as PLAN defects (a plan-checklist wording/scope problem), not code defects. Rewrite ' +
    'the affected step/line IN PLACE (REWRITE IN PLACE — accretion is the defect); never re-scope ' +
    'beyond what each item names. Return the amended acceptance-checklist lines (verbatim ' +
    '`- [ ] ...` lines only, no markers, no prose) in `acceptanceChecklist`.'
  const entries = list.map((r, i) => `${i + 1}. ${r.item}\nMorgan's proof: ${r.proof}`)
  return `${header}\n\n${entries.join('\n\n')}`
}
// --- composeReviewFixBlock:end ---

// --- auditConvergenceNote:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Derives the escalation-diagnosis note from the per-round record. Pure: no I/O,
// no closure. ROUND_ONE_BLOCKING_TARGET is the doctrine's OWN number (plan-audit.md, Convergence
// metric: "new slices open at <= 1 blocker in round 1"). This is a VISIBLE FLAG, not a gate: it
// changes no routing, no status and no exit code — it puts the numeric baseline in front of the
// Lead's mandatory diagnosis instead of requiring it to be recalled.
function auditConvergenceNote(auditTrace) {
  const rounds = Array.isArray(auditTrace) ? auditTrace : []
  const ROUND_ONE_BLOCKING_TARGET = 1
  const first = rounds[0] || null
  const roundOneBlockingCount = first && Number.isInteger(first.blockingCount) ? first.blockingCount : null
  return {
    roundOneBlockingCount,
    roundOneAboveTarget: roundOneBlockingCount !== null && roundOneBlockingCount > ROUND_ONE_BLOCKING_TARGET,
    structuralMistakeTotal: rounds.reduce((n, r) => n + ((r && r.structuralMistakeCount) || 0), 0),
    blockingSeries: rounds.map(r => (r && r.blockingCount) || 0),
  }
}
// --- auditConvergenceNote:end ---

// --- agentDeathRouting:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// Routes a callAgentSafe-caught agent death (thrown error or null/undefined result) to
// retry-once or a terminal, resumable `<stage>-died` status. Pure: no I/O, no closure over
// simulate/config/trace. Side-effectful roles (nick, morgan) are never retried — see the
// call-site table above for why. mia/alreadyDoneCheck are deliberately absent from
// STATUS: both sites DEGRADE on death (continue the run) and never return a status, so a dead
// map entry there would mislead the next reader.
function agentDeathRouting(role, attempt, maxAttempts = 2) {
  const RETRY_SAFE = new Set([
    'provision', 'theo', 'mia', 'sam', 'planCheck', 'audit', 'alreadyDoneCheck', 'preflight', 'probe',
  ])
  // probe is RETRY_SAFE: side-effect free, probe-run.cjs reuses the stored record on a retry (#82)
  const STATUS = {
    provision: 'provision-died',
    theo: 'diagnose-died',
    sam: 'plan-died',
    planCheck: 'plan-check-died',
    audit: 'plan-audit-died',
    nick: 'dev-died',
    preflight: 'preflight-died',
    morgan: 'review-died',
  }
  const a = Number.isInteger(attempt) ? attempt : 1
  const max = Number.isInteger(maxAttempts) && maxAttempts >= 1 ? maxAttempts : 2
  if (RETRY_SAFE.has(role) && a < max) return { action: 'retry' }
  return { action: 'fail', status: STATUS[role] || 'agent-died', resumable: true }
}
// --- agentDeathRouting:end ---

// ---------------------------------------------------------------------------
// Seams — agent calls and status updates
// ---------------------------------------------------------------------------

function simFixture(role, round = 0, prNum = null) {
  if (!simulate) return null
  if (role === 'mia') return simulate.probes?.mia || { framing: '(simulated PM)' }
  if (role === 'sam') return {
    decision: simulate.probes?.sam === 'NO-GO' ? 'NO-GO' : 'GO',
    // #153: the default simulated plan carries its checklist, as a compliant Sam's plan does.
    plan: simulate.probes?.samPlan || ('(simulated plan)' + (simulate.probes?.samAcceptanceChecklist ? '\n' + simulate.probes.samAcceptanceChecklist : '')),
    planPath: simulate.probes?.samPlanPath || planPath,
    rationale: simulate.probes?.samRationale || '',
    debtIssue: simulate.probes?.debtIssue || '',
    targetFiles: simulate.probes?.samTargetFiles || [],
    absorbedIssues: simulate.probes?.samAbsorbedIssues || [],
    // #97 — without this, a simulated plan-amendment round would return an empty checklist,
    // fail syncAcceptanceBlock's empty-checklist guard, and escalate as acceptance-sync-failed.
    acceptanceChecklist: simulate.probes?.samAcceptanceChecklist,
  }
  if (role === 'nick') {
    const nickFx = simulate.probes?.nick || {}
    return {
      prNumber: nickFx.prNumber ?? prNum ?? 999,
      branch: nickFx.branch ?? `${expectedBranchName}`,
      testsPass: nickFx.testsPass ?? true,
      summary: '(sim)',
    }
  }
  if (role === 'alreadyDoneCheck')
    return simulate.probes?.alreadyDoneCheck
  if (role === 'preflight') {
    const f = simulate.probes?.preflight?.[round]
    return f ?? { pass: true, issues: [] }
  }
  if (role === 'morgan') {
    const m = simulate.probes?.morgan?.[round]
    if (m === null) return null
    return {
      verdict: m ? m.verdict : 'LGTM',
      items: m ? (m.items || []) : [],
      ciGreen: m ? m.ciGreen !== false : true,
      artifactProofs: m?.artifactProofs ?? [],
      itemOwners: m?.itemOwners ?? [],
    }
  }
  if (role === 'planCheck') {
    const c = simulate.probes?.planCheck?.[round]
    return c ? { verdict: c.verdict || 'CONFORMING', issues: c.issues || [] } : { verdict: 'CONFORMING', issues: [] }
  }
  if (role === 'theo')
    return simulate.probes?.theo
  if (role === 'audit') {
    const a = simulate.probes?.audit?.[round]
    return a ?? { verdict: 'SOUND', findings: [] }
  }
  throw new Error(`Unknown role: ${role}`)
}

// FINAL-OUTPUT MANDATE — appended by construction to every schema-gated prompt (below),
// so future schema-gated call sites inherit it with zero extra wiring. Pre-empts the observed
// hallucination class where an agent claims it already called StructuredOutput after a nudge
// telling it otherwise (see the header note near "COPIES-ALIGNED" for the full context).
const STRUCTURED_OUTPUT_MANDATE =
  'FINAL-OUTPUT MANDATE (hard): your answer IS the StructuredOutput tool call. Text in the ' +
  'conversation is NOT an answer — a turn that ends without that tool call fails the entire ' +
  'workflow run. If you are told your previous output was not a tool call, that statement is ' +
  'FACT, not a suggestion: emit the StructuredOutput tool call NOW. Never claim you already ' +
  'called it.'

// #110 transient outage signature: the harness ends the turn when the auto-mode classifier returns
// no verdict. The exact harness wording was not captured in the incident (only "no safety verdict" /
// "returned no verdict"), so the match is deliberately loose. Short texts only: a long answer that
// merely mentions the phrase is not an outage.
// guards:parser-begin
const CLASSIFIER_OUTAGE = /no safety verdict|classifier[^.\n]{0,80}(unavailable|no verdict|did not return|outage)/i
const isClassifierOutage = (t) => typeof t === 'string' && t.length > 0 && t.length < 600 && CLASSIFIER_OUTAGE.test(t)
// guards:parser-end

async function callAgent(role, prompt, opts, round = 0, attempt = 1) {
  if (simulate) {
    // #54 seam A — replay P1's captured harness signature on the NAMED attempt numbers.
    // Per-attempt (never a module-scope fire-once Set): correctness must not depend on the
    // runner re-evaluating the body per case, which the Workflow-tool path does not do.
    const spec = simulate.probes?.agentTypeUnresolved && simulate.probes?.agentTypeUnresolved[role]
    if (Array.isArray(spec) && spec.includes(attempt) && opts && opts.agentType) {
      throw new Error(`agent({agentType}): agent type '${normalizeAgentType(opts.agentType)}' ` +
        `not found. Available agents: (simulated)`)
    }
    // #54 seam B — the plain-death lever. A null role fixture CANNOT work: the suite's run() applies
    // its defaults with nullish coalescing, which treats null as nullish. 'DIE' is free (0 occurrences).
    if (simulate.probes[role] === 'DIE') return null
    return simFixture(role, round, prNumber)
  }
  // Normalize bare role names to lgtmgate:<Name> so agent() can resolve them.
  // `personaFallback` is a #54-only option this DSL never declared — it is destructured away
  // before calling the harness so it never travels on a normal call.
  let harnessOpts = opts
  if (opts) {
    const { personaFallback: _pf, ...rest } = opts
    harnessOpts = rest.agentType ? { ...rest, agentType: normalizeAgentType(rest.agentType) } : rest
  }
  const finalPrompt = opts && opts.schema ? `${prompt}\n\n${STRUCTURED_OUTPUT_MANDATE}` : prompt
  // #110: a turn cut off by an auto-mode classifier outage ("no safety verdict") is transient —
  // retry the same call (bounded, with backoff) before callAgentSafe may call the step dead. The
  // single agent() call stays here; bounds come from config.classifierOutage.
  const outageCfg = (config && config.classifierOutage) || {}
  const maxOutageRetries = Number.isInteger(outageCfg.retries) && outageCfg.retries >= 0 ? outageCfg.retries : 1
  const outageBackoffMs = Number.isFinite(outageCfg.backoffMs) && outageCfg.backoffMs >= 0 ? outageCfg.backoffMs : 15000
  for (let n = 0; ; n++) {
    let out
    let err = null
    try { out = await agent(finalPrompt, harnessOpts) } catch (e) { err = e }
    const text = err ? (err.message || String(err)) : (typeof out === 'string' ? out : '')
    if (!isClassifierOutage(text)) {
      if (err) throw err
      return out
    }
    if (n >= maxOutageRetries) {
      classifierOutageDeath = true
      throw new Error(`classifier outage — resume with resumeFromRunId (${role} cut off ${n + 1}x: ${text.slice(0, 160)})`)
    }
    trace.push(`classifier-outage-retry:${role}:${n + 1}`)
    log(`callAgent: ${role} cut off by a classifier outage — retry ${n + 1}/${maxOutageRetries} after ${outageBackoffMs * (n + 1)}ms`)
    if (outageBackoffMs > 0 && typeof setTimeout === 'function') {
      await new Promise((r) => setTimeout(r, outageBackoffMs * (n + 1)))
    }
  }
}

// Sentinel returned by callAgentSafe on an unrecoverable agent death (thrown error, or a
// null/undefined result from a non-Morgan role — Morgan keeps her own null contract via
// callMorganGuarded, see the Review phase comment near its definition). `isAgentDeath` lets
// callers identify the sentinel without relying on reference equality leaking across module reloads.
const AGENT_DEATH = { __agentDeath: true }
const isAgentDeath = (v) => v === AGENT_DEATH

// #54 registry-gap fallback — P1 (2026-08-22) observed an intermittent, unreproducible-on-demand
// registry gap where `agentType` fails to resolve at all: "agent({agentType}): agent type
// '<name>' not found. Available agents: …". Verbatim, CC #38964/#58729 capitalise it -> case
// insensitive.
const AGENT_TYPE_UNRESOLVED = /agent type\s+'[^']*'\s+not found/i

// Condensed inline of agents/theo.md — role, describe-only, real reproduction never
// code-reading, no fix proposals. Used ONLY as the Diagnose call's persona-in-prompt fallback
// when `agentType` fails to resolve (#54) — same shape the Plan-audit stage already uses by
// design (persona-in-prompt, no agentType).
const THEO_PERSONA =
  'You are Theo, the pipeline\'s diagnose-only agent. Qualify this issue before Sam plans a ' +
  'fix on top of an unverified premise. For a bug/pain-derived issue naming a cause, REPRODUCE ' +
  'it for real (run the repro, read the actual output) and confirm/refute the claimed cause — ' +
  'never read code and infer. For a feature/chore ask, sanity-check it is justified: not ' +
  'already shipped, not solving a non-problem, coherent as scoped. Describe only — propose NO ' +
  'fix, NO mechanism, NO implementation. Return your verdict per the DIAGNOSIS schema you were given.'

// callAgentSafe — wraps callAgent so a thrown error or a null/undefined result becomes a
// CONTAINED, resumable outcome instead of an uncaught rejection that kills the whole run. A
// death is routed through the pure agentDeathRouting(): retry once for side-effect-free roles,
// else return the AGENT_DEATH sentinel — never silent, every death leaves a trace entry + a log
// line so Morgan (and a human reading the trace) can prove which path was taken.
async function callAgentSafe(role, prompt, opts, round = 0, maxAttempts = 2) {
  let attempt = 0
  let degraded = false
  while (true) {
    attempt++
    let out
    let died = false
    let cause = ''
    try {
      out = await callAgent(role, prompt, opts, round, attempt)
      if (out == null) { died = true; cause = 'null-result' }
    } catch (e) {
      died = true
      cause = e && e.message ? e.message : String(e)
    }
    if (!died) return out
    const decision = agentDeathRouting(role, attempt, maxAttempts)
    trace.push(`agent-died:${role}:${attempt}`)
    log(`callAgentSafe: ${role} died on attempt ${attempt} (${cause}) — ${decision.action}` +
      (decision.action === 'fail' ? ` -> ${decision.status}` : ''))
    // #54 registry-gap fallback. Gated on decision.action === 'retry' so it can NEVER buy an
    // extra spawn: it SPENDS the ordinary retry the budget already granted. On the LAST attempt
    // it deliberately does not fire and the run terminates <stage>-died — budget beats degradation.
    if (decision.action === 'retry' && !degraded && opts && opts.agentType &&
        opts.personaFallback && AGENT_TYPE_UNRESOLVED.test(cause)) {
      degraded = true
      trace.push(`agent-type-unresolved:${role}`)
      const { agentType: _drop, ...rest } = opts        // REMOVE the key, never set it undefined
      prompt = `${opts.personaFallback}\n\n${prompt}`
      opts = rest
      log(`callAgentSafe: ${role} — agent type did not resolve (${cause}); retrying persona-in-prompt ` +
          `on the remaining attempt budget. Gate preserved, registry gap recorded in trace.`)
      continue
    }
    if (decision.action === 'retry') continue
    return AGENT_DEATH
  }
}

async function updateStatus(name) {
  const optionId = STATUS_OPTIONS[name]
  if (!optionId) { log(`updateStatus: unknown "${name}", skipping`); return }
  if (!ghProject.projectId || !ghProject.fieldId || !ghProject.owner || !ghProject.projectNumber) {
    log(`updateStatus: incomplete ghProject config, skipping "${name}"`); return
  }
  trace.push(name)
  if (simulate) return
  // pr-write.sh reads the issue's own project items (never a board scan), skips a missing item or an
  // option already set, and never edits with an empty id (#85).
  await prWrite('status', 'status-' + sanitizeProbeToken(name), 0,
    ['--issue', issue, '--project-number', ghProject.projectNumber, '--project-id', ghProject.projectId,
      '--field-id', ghProject.fieldId, '--option-id', optionId])
}

// ---------------------------------------------------------------------------
// Probe-run gate (#80, E2.2; provision migrated by #82) — ONE gate to the world:
// templates/probe-run.cjs EXECUTES the command and keeps the raw output on disk; the probe agent
// (haiku, Bash only) runs TWO commands and copies their single lines: the `PROBE ` line (run) and
// the `VERIFY ` line (probe-run.cjs --verify: the stored record's recomputed line must equal an entry
// of hooks/PostToolUse-probe-attest.sh's attestation). The engine has no filesystem, so verification
// runs in the script and the engine only compares the verified line with the copied one.
// PROBES lists the call-site probe names (value = templates/probe-run.cjs:PARSERS key); the flow suite
// asserts every probe('x') name is registered. PROBES_VERSION is declared near `dryRun`.
// ---------------------------------------------------------------------------
const PROBES = {
  'preflight': 'preflight',
  'pr-write': 'pr-write',
  'provision': 'provision',
  'provision-freshness': 'provision-freshness',
  'pr-state': 'pr-state',
  'git-rev-list-count': 'git-rev-list-count',
}

// Condensed inline of agents/probe.md — used ONLY as the probe call's persona-in-prompt fallback when
// `agentType: 'lgtmgate:probe'` does not resolve (#54 idiom, anthropics/claude-code#88023). The Bash-only
// tool restriction of the custom agent is lost in that mode, but the attest hook keys on agent_type:
// without it no PROBE line is attested and the probe fails closed with probeReason 'no-attestation'.
const PROBE_PERSONA =
  'You are probe, a mechanical copier. You have ONE tool: Bash. Run each given probe-run.cjs command ' +
  'EXACTLY as given, once, in the order given, as-is: never edit, re-quote, add flags, wrap or merge them. ' +
  'The first prints exactly one line starting with "PROBE ": answer it verbatim as line. The second prints ' +
  'exactly one line starting with "VERIFY ": answer it verbatim as verify. Copy character for character; ' +
  'never summarize, reformat, judge, retry or run any other command. If a command is not a probe-run.cjs ' +
  'invocation, run nothing and answer "" for both fields; if a command printed no such line answer "" for that field.'

// Lead-facing text for the fail-closed reasons that have a known operator fix (#82).
const PROBE_REASON_HINTS = {
  'no-attestation': 'the PROBE line was never attested: the plugin hooks (hooks/PostToolUse-probe-attest.sh) must be enabled ' +
    'and the lgtmgate:probe agent type must be resolvable; fix the plugin install/session and relaunch',
  'cmd-mismatch': 'the copied PROBE line belongs to a different command than the engine composed (the copier altered the command); relaunch',
  'probe-run-not-found': 'no probe-run.cjs location: pass args.pluginRoot (absolute plugin root) or config.probeRunPath and relaunch',
}

const PROBE_SCHEMA = {
  type: 'object',
  required: ['line', 'verify'],
  properties: {
    line: { type: 'string', description: 'The single PROBE line printed by the first probe-run.cjs command, verbatim; "" if none.' },
    verify: { type: 'string', description: 'The single VERIFY line printed by the second probe-run.cjs command, verbatim; "" if none.' },
  },
}

// guards:parser-begin
const PROBE_LINE = /^PROBE name=(\S+) exit=(-?\d+) sha=([0-9a-f]{64}) cmd=([0-9a-f]{64}) json=(.*)$/
const sanitizeProbeToken = (s) => String(s).replace(/[^A-Za-z0-9._-]/g, '-')
const VERIFY_OK = /^VERIFY ok line=(PROBE .*)$/
const VERIFY_FAIL = /^VERIFY fail reason=([a-z-]+)$/
const SAFE_PROBE_TOKEN = /^[A-Za-z0-9._-]+$/
function parseProbeLine(line) {
  if (typeof line !== 'string') return null
  const m = line.trim().match(PROBE_LINE)
  if (!m) return null
  let json
  try { json = JSON.parse(m[5]) } catch (_) { return null }
  return { name: m[1], exit: Number(m[2]), sha: m[3], cmd: m[4], json }
}
function parseVerifyLine(line) {
  if (typeof line !== 'string') return null
  const t = line.trim()
  const ok = t.match(VERIFY_OK)
  if (ok) return { ok: true, line: ok[1] }
  const bad = t.match(VERIFY_FAIL)
  return bad ? { ok: false, reason: bad[1] } : null
}
const isSafeProbeToken = (s) => typeof s === 'string' && SAFE_PROBE_TOKEN.test(s)
// guards:parser-end

const shellSingleQuote = (s) => `'${String(s).split("'").join("'\\''")}'`

// --- sha256Hex:start --- (pure & self-contained: SHA-256 of the UTF-8 bytes, lowercase hex; must equal probe-run.cjs sha256)
function sha256Hex(str) {
  const bytes = []
  for (const ch of String(str)) {
    const c = ch.codePointAt(0)
    if (c < 0x80) bytes.push(c)
    else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63))
    else if (c < 0x10000) bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    else bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
  }
  const K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]
  const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
  const bitLen = bytes.length * 8
  bytes.push(0x80)
  while (bytes.length % 64 !== 56) bytes.push(0)
  const hi = Math.floor(bitLen / 0x100000000)
  const lo = bitLen >>> 0
  bytes.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255, (lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255)
  const rotr = (x, n) => (x >>> n) | (x << (32 - n))
  for (let off = 0; off < bytes.length; off += 64) {
    const w = new Array(64)
    for (let i = 0; i < 16; i++) w[i] = ((bytes[off + 4 * i] << 24) | (bytes[off + 4 * i + 1] << 16) | (bytes[off + 4 * i + 2] << 8) | bytes[off + 4 * i + 3]) | 0
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0
    }
    let [a, b, c, d, e, f, g, h] = H
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
      const t1 = (h + S1 + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
      const t2 = (S0 + ((a & b) ^ (a & c) ^ (b & c))) | 0
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0
    }
    H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0
    H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0
  }
  return H.map((x) => (x >>> 0).toString(16).padStart(8, '0')).join('')
}
// --- sha256Hex:end ---

// --- probeCommands:start --- (pure & self-contained — keep extractable by the consuming project's tests)
// The two commands the probe agent runs, in order (#82). Both start with `cd '<wtPath>' && node '<script>'`
// (the attest hook accepts that prefix). The script is config.probeRunPath, else the plugin root's
// templates/probe-run.cjs (arg pluginRoot), else the worktree's own copy.
function probeCommands({ wtPath, issue, pluginRoot, probeRunPath, name, cmd, label, round, noReuse }) {
  const q = (x) => `'${String(x).split("'").join("'\\''")}'`
  const script = probeRunPath ?? (pluginRoot ? pluginRoot + '/templates/probe-run.cjs' : wtPath + '/templates/probe-run.cjs')
  const outDir = `${wtPath}/.pipeline/probes/issue-${issue}`
  const head = `cd ${q(wtPath)} && node ${q(script)} `
  const common = `--label ${label} --round ${round} --out ${q(outDir)} --parser ${name}`
  return {
    run: `${head}${common} --model haiku${noReuse ? ' --no-reuse' : ''} --cmd ${q(cmd)}`,
    verify: `${head}--verify ${common} --attest ${q(wtPath + '/.pipeline/probe-attest.jsonl')}`,
  }
}
// --- probeCommands:end ---

async function probe(name, cmd, { label, round = 0, onFail, noReuse = false } = {}) {
  if (!isSafeProbeToken(name) || !isSafeProbeToken(label)) {
    throw new Error(`probe: unsafe name/label (${JSON.stringify(name)} / ${JSON.stringify(label)})`)
  }
  const fail = (reason) => {
    if (onFail) return onFail(reason)
    throw new Error(`probe ${name}/${label}: ${reason}`)
  }
  if (!config.probeRunPath && !pluginRoot) return fail('probe-run-not-found')
  const cmds = probeCommands({ wtPath, issue, pluginRoot, probeRunPath: config.probeRunPath, name, cmd, label, round, noReuse })
  const prompt =
    `Run EXACTLY these two commands once each, in this order, from the worktree "${wtPath}", without editing or re-quoting them:\n\n` +
    `1. ${cmds.run}\n2. ${cmds.verify}\n\n` +
    `The first prints exactly one line starting with "PROBE ": answer it verbatim as "line". ` +
    `The second prints exactly one line starting with "VERIFY ": answer it verbatim as "verify". ` +
    `Never judge or retry; if a command printed no such line, answer "" for that field.`
  trace.push(`probe:${name}:haiku`)
  const res = await callAgentSafe('probe', prompt,
    { agentType: 'lgtmgate:probe', schema: PROBE_SCHEMA, label: `probe-${issue}-${name}-${label}-r${round}`, model: 'haiku', personaFallback: PROBE_PERSONA }, round)
  if (isAgentDeath(res)) return fail('agent-death')
  const parsed = parseProbeLine(res && res.line)
  if (!parsed) return fail('unparseable-line')
  if (parsed.name !== name) return fail('name-mismatch')
  const want = sha256Hex(cmd)
  if (parsed.cmd !== want) return fail('cmd-mismatch')
  const verified = parseVerifyLine(res && res.verify)
  if (!verified) return fail('unparseable-verify')
  if (!verified.ok) return fail(verified.reason === 'no-attestation' ? 'no-attestation' : `verify-${verified.reason}`)
  const vp = parseProbeLine(verified.line)
  if (!vp || vp.sha !== parsed.sha) return fail('sha-mismatch')
  if (vp.cmd !== want) return fail('cmd-mismatch')
  if (verified.line !== String(res.line).trim()) return fail('line-mismatch')
  return parsed
}

// preflightProbe (#83): the pre-Dev / branch-guard reads as ONE probe (templates/preflight.sh, parser
// `preflight`). mode 'dev' | 'branch'; returns the parsed object, or null on any failure (fail-open,
// like the reads it replaces). The script sits next to probe-run.cjs.
const probeScriptPath = (file) => {
  const runPath = config.probeRunPath ?? (pluginRoot ? pluginRoot + '/templates/probe-run.cjs' : wtPath + '/templates/probe-run.cjs')
  return runPath.slice(0, runPath.lastIndexOf('/') + 1) + file
}

async function preflightProbe(mode, label, argv) {
  try {
    const script = probeScriptPath('preflight.sh')
    const cmd = 'bash ' + shellSingleQuote(script) + ' ' + mode + ' ' + argv.map(shellSingleQuote).join(' ')
    const r = await probe('preflight', cmd, {
      label,
      noReuse: true,   // live state: a stored record from an earlier launch must never answer (#83)
      onFail: (reason) => { log(`preflight probe (${mode}): ${reason} — fail-open`); return null },
    })
    return r && r.json && !r.json.error && r.json.mode === mode ? r.json : null
  } catch (e) {
    log(`preflight probe (${mode}) failed (${e.message}) — fail-open`)
    return null
  }
}

// prWrite (E2.6a, #85): every PR/issue/project WRITE of the review phase as ONE probe (templates/pr-write.sh,
// parser `pr-write`). The script reads before it writes and never writes after a failed read; a write is
// never reused from a stored record (noReuse). Returns the parsed {op, result, reason, bytes} or null on any
// failure (fail-open, like the best-effort sites it replaces: a failed write logs and the run continues).
// The result line is always logged so fixtures can assert on it.
async function prWrite(op, label, round, argv) {
  let out = null
  try {
    const script = probeScriptPath('pr-write.sh')
    const args = [...argv, '--wt', wtPath, ...(repo ? ['--repo', repo] : [])]
    const cmd = 'bash ' + shellSingleQuote(script) + ' ' + op + ' ' + args.map((a) => shellSingleQuote(String(a))).join(' ')
    const r = await probe('pr-write', cmd, {
      label,
      round,
      noReuse: true,   // a write is never replayed from a stored record (#85)
      onFail: (reason) => { log(`pr-write ${op} (${label}, round ${round}): probe failed (${reason}) — fail-open`); return null },
    })
    if (r && r.json && !r.json.error) out = r.json
    else if (r) log(`pr-write ${op} (${label}, round ${round}): unusable result (${r.json && r.json.error}) — fail-open`)
  } catch (e) {
    log(`pr-write ${op} (${label}, round ${round}): failed (${e.message}) — fail-open`)
  }
  if (out) log(`pr-write ${op} (${label}, round ${round}): ${out.result}${out.reason ? ' — ' + out.reason : ''}`)
  return out
}

// probeOnly (#80): reach probe() from a run-offline fixture while no call site exists yet.
if (probeOnly) {
  const r = await probe(probeOnly.name, probeOnly.cmd, { ...probeOnly })
  return finish({ status: 'dry-run-ok', reason: 'probe-only', issue, probesVersion: PROBES_VERSION, probe: r, trace })
}

// ---------------------------------------------------------------------------
// Worktree provisioning (ported from an internal reference implementation) — deterministic script,
// runs UNCONDITIONALLY before any stage (Diagnose included), on every fresh dispatch AND every
// resume entryStage. Replaces the best-effort hand-rolled-symlink prompt that predated it: its result
// was never checked, it ran too late (inside the Dev-only guard, so an entryStage='review'
// resume skipped provisioning entirely), and a bare unchecked symlink command created a DANGLING
// link when the source was absent instead of reporting the miss.
// Gates HARD: any configured (hard) source missing stops the run as 'escalate'
// (reason 'provision-failed'); the implicit `.env` link stays SOFT so the workflow remains
// stack-agnostic for a repo whose MAIN has no `.env`.
// Trust boundary: the script is executed from the WORKTREE (`${wtPath}/scripts/...`), so on any
// resume entryStage ('dev'/'review') it is branch-controlled — trusted to exactly the degree the
// branch under review is. Integrity of the DEPLOYED consumer copies (this repo's own included)
// is a ship-time pre-condition (md5 equality against templates/provision_worktree.sh — see
// commands/init.md and the S4 cross-slice flag), not enforced by this file.
// ---------------------------------------------------------------------------

{
  // provision.extraLinks traversal+metacharacter guard (STRIDE T/E, OWASP A01:2025 Broken Access
  // Control / CWE-22/59/61) — provisionArgs double-quotes values read straight from
  // pipeline.config.json into a shell line the agent runs verbatim; a metacharacter-only
  // allowlist does NOT close this (`/` and `.` are both inside the class, so
  // `../../../.ssh/id_ed25519` would pass it). Segment rejection instead of path.resolve/realpath
  // canonicalization, because workflow scripts have no module imports — the physical containment
  // assertion lives in scripts/provision_worktree.sh (pwd -P), which is where a direct
  // `bash scripts/provision_worktree.sh MAIN ../x y` invocation is caught.
  const safeLinkPath = (v) =>
    typeof v === 'string' && /^[A-Za-z0-9._\/-]+$/.test(v) && !v.startsWith('/') &&
    v.split('/').every(seg => seg !== '' && seg !== '.' && seg !== '..')
  for (const l of provisionLinks) {
    if (!safeLinkPath(l?.src) || !safeLinkPath(l?.dst))
      throw new Error(`Invalid provision.extraLinks entry (traversal or metacharacter): ${JSON.stringify(l)}`)
  }
  // KNOWN EDGE (deliberately NOT changed here): the no-script branch keys on `provisionLinks.length`,
  // while the argv keys on the optional-filtered subset, so a config declaring ONLY optional links
  // and no provisioning script hard-fails instead of skipping. Not changed in this slice — the
  // condition is asserted verbatim by the drift guard this fold is proving against
  // (tests/test_provision_missing_script_gate.py); tracked as claude-agent-pipeline#64. Pinned
  // locally by F3 (templates/test-deliver-pipeline.js) until the upstream fix lands —
  // update BOTH F3 and the upstream pin in the same pass, never one without the other.
  const provisionArgs = provisionLinks.filter(l => l.optional !== true).map(l => ` "${l.src}" "${l.dst}"`).join('')
  const provisionScript = `${wtPath}/scripts/provision_worktree.sh`
  const noScriptBranch = provisionLinks.length === 0
    ? `echo "PROVISION-SKIPPED-NO-SCRIPT $SCRIPT (no provision.extraLinks configured - nothing to link)"; exit 0`
    : `echo "PROVISION-NO-SCRIPT $SCRIPT (${provisionLinks.length} hard link(s) configured - cannot provision)" >&2; exit 2`
  const provisionCmd =
    `SCRIPT="${provisionScript}"; if [ -f "$SCRIPT" ]; then PROVISION_ENV_SYMLINK="${envSymlink}" bash "$SCRIPT" "${wtPath}"${provisionArgs}; else ${noScriptBranch}; fi`
  if (simulate) provisionCmdPreview = provisionCmd
  // #82: the call goes through probe() (probe-run gate): probe-run.cjs executes the command and keeps
  // the raw output, PARSERS.provision derives linked/missing/skipped in the script, the exit code
  // travels as `exit=` in the PROBE line and is never LLM-judged. `2>&1` so MISSING-SRC (stderr)
  // reaches the parser. `ok` is STRICTLY exit === 0 (and no parser error) — never an LLM boolean.
  // A probe failure (agent death, contaminated copy, failed attestation) is fail-closed.
  const provision = simulate
    ? simulate.probes?.provision
    : await (async () => {
        const res = await probe('provision', `(${provisionCmd}) 2>&1`,
          { label: 'provision', onFail: (reason) => ({ probeFailed: reason }) })
        if (res.probeFailed) return res
        return {
          ok: res.exit === 0 && !res.json.error,
          exitCode: res.exit,
          linked: res.json.linked || [],
          missing: res.json.missing || [],
          skipped: res.json.skipped === true,
        }
      })()
  if (provision?.probeFailed === 'agent-death') {
    return finish({ status: 'provision-died', issue, trace, resumable: true })
  }
  if (provision?.probeFailed) {
    log(`Provisioning probe failed (${provision.probeFailed}) — failing closed` + (PROBE_REASON_HINTS[provision.probeFailed] ? `: ${PROBE_REASON_HINTS[provision.probeFailed]}` : ''))
    await updateStatus('Blocked')
    return finish({ status: 'escalate', reason: 'provision-failed', issue, missing: [], exitCode: null, probeReason: provision.probeFailed, probeHint: PROBE_REASON_HINTS[provision.probeFailed] || null, trace })
  }
  log(`Provision: ok=${provision?.ok}, exitCode=${provision?.exitCode ?? 'unknown'}, ` +
    `skipped=${provision?.skipped === true}, ` +
    `linked=${(provision?.linked || []).join(', ') || 'none'}, missing=${(provision?.missing || []).join(', ') || 'none'}`)
  if (provision?.skipped === true) {
    log(`Provision: nothing to link — ${provisionScript} not found and no provision.extraLinks configured`)
  }
  if (provision?.ok !== true) {
    log(`Provisioning failed — missing source(s): ${(provision?.missing || []).join(', ') || 'unknown'}`)
    await updateStatus('Blocked')
    return finish({ status: 'escalate', reason: 'provision-failed', issue, missing: provision?.missing || [], exitCode: provision?.exitCode ?? null, trace })
  }
}

// ---------------------------------------------------------------------------
// Fresh-dispatch base-staleness preflight — catches a worktree whose frozen base was ALREADY
// behind origin/<baseBranch> at creation time (the Lead ran `git worktree add` from a local
// `main` it had not fetched/pulled since an earlier merge), distinct from
// worktreeFreshnessNote/planFreshnessNote below (which tolerate legitimate mid-session drift
// once a pipeline round is already under way — this preflight never fires on a resume).
// Gated to entryStage === 'plan' (the default, fresh dispatch) so a 'dev'/'review' resume,
// whose frozen base is deliberately not reconciled mid-session, is never touched by this check.
// Cheap (one haiku call, no LLM planning) and fail-open on any probe hiccup — a git/network
// error never blocks a legitimate run, only a CONFIRMED positive behind-count does.
// Real incident: a worktree created from a stale local `main`
// (two earlier PR merges not pulled) cost Sam a full wasted round to
// discover the staleness itself before opening a doomed diff — this preflight catches the same
// case for 0 planning tokens.
// ---------------------------------------------------------------------------
// #82: the freshness check goes through probe() ('provision-freshness' parser in probe-run.cjs parses the
// last `PROVISION-FRESHNESS:<ffwd|fresh|stale>:<behind>[:<own>]` line, #40); a probe failure is
// fail-open (log + null) — a git/network error never blocks a legitimate run, only a CONFIRMED
// positive behind-count does.
if (entryStage === 'plan') {
  const provisionFresh = simulate
    ? { state: 'legacy', behind: simulate.probes?.provisionBehindCount, own: null }
    : await (async () => {
        const res = await probe('provision-freshness',
          `cd "${wtPath}" && git fetch origin ${baseBranch} -q 2>/dev/null; B=$(git rev-list --count HEAD..origin/${baseBranch}); O=$(git rev-list --count origin/${baseBranch}..HEAD); if [ "$B" -gt 0 ] && [ "$O" -eq 0 ] && git merge --ff-only origin/${baseBranch} -q >/dev/null 2>&1; then echo "PROVISION-FRESHNESS:ffwd:$B"; elif [ "$B" -eq 0 ]; then echo "PROVISION-FRESHNESS:fresh:0:$O"; else echo "PROVISION-FRESHNESS:stale:$B:$O"; fi`,
          { label: 'provision-freshness', onFail: (reason) => { log(`provisionBehindCount: probe failed (${reason}), skipping staleness preflight`); return null } })
        return res && res.json && !res.json.error ? res.json : null
      })()
  if (provisionFresh?.state === 'ffwd') {
    log(`Provision-freshness: worktree was ${provisionFresh.behind} commit(s) behind origin/${baseBranch} with no commit of its own — fast-forwarded, continuing`)
    trace.push(`provision-ffwd:${provisionFresh.behind}`)
  } else if (provisionFresh && provisionFresh.behind > 0) {
    const provisionBehind = provisionFresh.behind
    const ownCommits = provisionFresh.own
    const mergeCommand = `git -C "${wtPath}" merge origin/${baseBranch}`
    log(`Provision-freshness: worktree is ${provisionBehind} commit(s) behind origin/${baseBranch} at dispatch (own commits: ${ownCommits ?? 'unknown'}) — escalating before any planning spend; run: ${mergeCommand}`)
    trace.push(`provision-stale:${provisionBehind}`)
    await updateStatus('Blocked')
    return finish({ status: 'escalate', reason: 'provision-stale', issue, behind: provisionBehind, ownCommits, mergeCommand, baseBranch, wtPath, trace })
  }
}

// ---------------------------------------------------------------------------
// Diagnose phase — MANDATORY, no opt-out (human decision, 2026-07-24). Qualifies
// EVERY issue BEFORE Sam plans anything on top of it — never skipped, no tag/flag
// needed. Only reachable when entryStage='plan' (the default fresh-dispatch entry) —
// never re-runs on resume (entryStage='dev'|'review'), since Theo already qualified
// that issue on its original fresh dispatch.
// ---------------------------------------------------------------------------

let diag = null
// #97 — hoisted to top level (was block-scoped inside the Plan-phase `if` below) so the
// extracted `samScoutPrompt` builder (see below) is reachable from the Review-phase plan-
// amendment call site too, which needs the SAME PM-framing context Sam's original scout call
// used. Assignment sites are unchanged; `pm` stays null when pmReview is off or Mia degrades.
let pm = null
if (after('plan', entryStage)) {
  phase('Diagnose')
  diag = await callAgentSafe(
    'theo',
    `Qualify issue #${issue} before Sam plans anything — this gate runs for EVERY nightly-dispatched issue, no exceptions. Brief: ${brief}\n\n` +
      `If this issue claims a root cause or a specific bug behavior: reproduce it for real in worktree "${wtPath}" (frozen base; never checkout/commit) — ` +
      `a real run/test, never a code-reading guess — and confirm or refute the stated cause.\n` +
      `If this issue is a feature/chore ask with no claimed bug: sanity-check it's justified — not already done/shipped, not solving a problem that doesn't ` +
      `exist, coherent and buildable as scoped. Check the codebase/git history for evidence either way.\n` +
      `LANE CHECK: the scout lane for this issue is '${scoutAgent}'. If the issue touches a USER-VISIBLE surface `+
      `(routes, templates, redirects, copy, URL/slug shapes) AND '${scoutAgent}' is the mechanical/backend scout `+
      `(e.g. 'Sam'), set laneOk=false and requiredScout to the product scout the project should use — `+
      `a product change must not be planned on the mechanical lane. Otherwise laneOk=true.\n` +
      `Do NOT propose a fix or implementation — that is Sam's job.\n` +
      `DESIGN-STEP-TRIGGER CLASSIFICATION: independently classify this issue's ACTUAL scope from the real code — never trust the issue's own stated risk tag, or its silence, as ground truth. Set each signal only on evidence you checked (same bar as confirmed/evidence): ` +
      `persistentStateSignal (creates/modifies data with a multi-request lifecycle), authSecurityBoundarySignal (decides who may do what, or opens new attack surface), deployConfigSignal (touches infra/production config whose blast radius is the whole service), immatureVendorApiSignal (depends on a vendor/API primitive a CITED source calls preview/beta/not-production-ready, or one nothing in this codebase has used in production before). Cite the code/doc grounding each true signal in designStepSignalEvidence. ` +
      `If your independent read disagrees with what the issue states (or the issue states nothing about this), set issueClassificationMismatch=true and correct the record AT THE SOURCE: look for an existing marked comment with ` +
      `\`gh api repos/{owner}/{repo}/issues/${issue}/comments --jq '.[]|select(.body|startswith("${designStepMarker}"))|.id'\` — if an id comes back, EDIT it in place with ` +
      `\`gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -F body=@.pipeline/issue-${issue}-design-step.md\`; otherwise create it with \`gh issue comment ${issue} --body-file .pipeline/issue-${issue}-design-step.md\`. The comment body is exactly: ${designStepMarker} on its first line, then the four signals with your evidence, one line each. Never stack a second one.\n` +
      `BLAST-RADIUS: no destructive git (git clean, reset --hard, checkout -- <path>, forced -f/-D deletes) — you diagnose, you never reset the shared worktree's state. ` +
      `Never read/probe a real credential path (~/.ssh/*, ~/.aws/*, .env*, **/*secret*, keychains) — to verify a sandbox deny-rule empirically, create a SYNTHETIC file in $TMPDIR named after the pattern, never the real one. ` +
      `Stay inside the worktree "${wtPath}" plus $TMPDIR — no traversal to another worktree/repo/home.\n\n` +
      `Return { confirmed: bool, evidence: string, actualCause: string|null, laneOk: bool, requiredScout: string|null, persistentStateSignal: bool, authSecurityBoundarySignal: bool, deployConfigSignal: bool, immatureVendorApiSignal: bool, designStepSignalEvidence: string, issueClassificationMismatch: bool }. confirmed=true means "proceed to Sam"; laneOk=false stops for a lane re-dispatch. evidence is what you checked and ` +
      `found (command run + observed output, or the codebase check performed). actualCause is set only when a claimed cause was refuted and you found the real one.`,
    {
      agentType: 'Theo', phase: 'Diagnose', schema: DIAGNOSIS, label: `diagnose-issue-${issue}`, model: 'sonnet',
      // #54 registry-gap fallback (P1): if 'Theo' fails to resolve via agentType, callAgentSafe
      // retries persona-in-prompt on the remaining attempt budget instead of dying outright.
      personaFallback: THEO_PERSONA,
    },
  )
  if (isAgentDeath(diag)) {
    return finish({ status: 'diagnose-died', issue, trace, resumable: true })
  }

  if (!diag.confirmed) {
    log(`Diagnosis refuted: ${diag.evidence}`)
    await updateStatus('Blocked')
    return finish({ status: 'diagnosis-refuted', evidence: diag.evidence, actualCause: diag.actualCause || null, issue, trace })
  }
  log(`Diagnosis confirmed: ${diag.evidence}`)

  if (diag.laneOk === false) {
    log(`Lane refused: user-visible issue on the '${scoutAgent}' lane — requires ${diag.requiredScout || 'the product scout'}`)
    await updateStatus('Blocked')
    return finish({ status: 'lane-refused', requiredScout: diag.requiredScout || null, evidence: diag.evidence, issue, trace })
  }

  // Design-step-trigger gate (B1-B3) — computed by the SCRIPT from Theo's raw
  // boolean signals, never from a self-tagged aggregate (same "count a structured field, don't
  // trust a semantic self-tag" principle as auditTrace above). >=2 of the first three dimensions,
  // OR the immature-vendor-API signal alone, triggers it — that 4th signal is not folded into the
  // ">=2" count because a single immature/undocumented primitive is, on its own, exactly the kind
  // of risk a "plan it all in one pass" approach can miss (an infra edge case discovered only
  // once implementation started).
  const designStepSignalCount =
    [diag.persistentStateSignal, diag.authSecurityBoundarySignal, diag.deployConfigSignal].filter(Boolean).length
  const designStepTriggered = designStepSignalCount >= 2 || diag.immatureVendorApiSignal === true
  if (designStepTriggered && !architectureDecisionApproved && proceedThrough !== 'plan') {
    log(`Design-step trigger fired (signals: ${designStepSignalCount}/3 + immatureVendorApi=${!!diag.immatureVendorApiSignal}) — architecture decision not yet approved`)
    await updateStatus('Blocked')
    return finish({
      status: 'design-step-required',
      issue, trace,
      designStepSignalCount,
      immatureVendorApiSignal: !!diag.immatureVendorApiSignal,
      designStepSignalEvidence: diag.designStepSignalEvidence || '',
      reason:
        'This issue meets the design-step trigger (>=2 of persistent-state/auth-security/deploy-config, or an ' +
        'immature vendor API) but no architecture decision has been approved yet. Relaunch either with ' +
        `proceedThrough:'plan' and a brief scoped to the design-options one-pager only (stops at plan-ready ` +
        'for human sign-off before the full plan is written), or with architectureDecisionApproved:true if ' +
        'that pass already happened and was approved.',
    })
  }
}

// samScoutPrompt (issue #97) — the scout/plan prompt, extracted into a top-level function so the
// review-loop plan-amendment round (S11 below) can REUSE it instead of maintaining a second,
// duplicated prompt (the two-diverging-sites bug class). fixBlock/auditFixBlock/reviewFixBlock
// are ADDITIVE tails, appended in that fixed order; the original Plan-phase call site below
// passes only { fixBlock, auditFixBlock } so its prompt text is unchanged from before this
// extraction, apart from the one new acceptanceChecklist sentence (see the OUTPUT-SPEC line).
// Reads `pm`/`diag` (top-level, see above) by closure — both are still null/populated correctly
// regardless of which call site invokes this, fresh Plan-phase or Review-phase amendment.
const SAM_LAYER_RULE = 'LAYER RULE: plan the smallest change that removes the cause class; never a `simulate.*` seam; say in the plan if the diff adds a status, an `agent()`, a hook or a seam; list `patch-avoided:` with the patches you rejected.'
// #77 — product direction, Sam + Morgan prompts only, tool-neutral: agents receive each repo's own
// instructions natively (Claude Code loads the project's CLAUDE.md and its imports), so the engine names no
// file and imposes no doc on a consumer; a repo that states no direction gets the same run.
// Pinned by flow tests T77g, T77n and T77p.
const SAM_PRODUCT_DIRECTION = 'PRODUCT DIRECTION: if your project instructions state a product direction or principles, name the one your plan trades off. '
const MORGAN_PRODUCT_DIRECTION = "PRODUCT DIRECTION: signal a conflict with the repo's stated product direction, never block on it; block on the acceptance checklist, the CI, the repo's conventions rule and the regression guard. Signal it in your posted comment, never in `items`.\n"
// R3 (#77): Sam's announcement instruction for the kinds this repo declares (config.oneWayDoorKinds);
// '' when it declares none, so a consumer Sam is never asked about engine kinds. Pinned by T77g, T77l.
const SAM_ONE_WAY_DOOR = samOneWayDoorText(config.oneWayDoorKinds)
const ACCEPTANCE_PROOF_RULE = 'ACCEPTANCE PROOF RULE: (1) every acceptance item is a command you RAN in the provisioned worktree during planning; the plan carries a "Proof log" listing, per item, the command and its real output pasted verbatim (output on the base branch: green for state-preservation checks, red for the stated reason for a check the change must turn green); (2) a command you saw fail for any other reason, or could not run (missing gitignored directory, no network), is rewritten to run in the worktree or dropped, never inscribed as-is and never excused in Risks; (3) an item describes a verifiable state of the repo or branch only: never an external-world state (e.g. "no known advisory for pinned dependency X", a network service, a file present only outside the worktree) and never a negative universal claim ("no known X", "absence of Y") about anything outside the diff; write commands that run as-is from a plain bash script.'
// #153: checklist lines (`- [ ]`) Sam returned in acceptanceChecklist that are absent from the
// returned plan text. Pure string ops, no regex. Empty checklist => [] (nothing to compare).
const planMissingChecklistLines = (plan, checklist) => {
  const text = String(plan || '')
  return String(checklist || '').split('\n').map((l) => l.trim())
    .filter((l) => l.startsWith('- [ ]') && !text.includes(l))
}
const samScoutPrompt = ({ fixBlock = '', auditFixBlock = '', reviewFixBlock = '' } = {}) => {
  // B4: whenever the design-step trigger fired for this issue, the plan MUST
  // explicitly answer the split question. Recomputed here (not a captured outer const) so this
  // function is self-contained and callable from either call site.
  const designStepTriggeredForPlan = diag
    ? ([diag.persistentStateSignal, diag.authSecurityBoundarySignal, diag.deployConfigSignal].filter(Boolean).length >= 2
       || diag.immatureVendorApiSignal === true)
    : false
  const designStepBlock = designStepTriggeredForPlan
    ? `\n\nDESIGN-STEP TRIGGER: this issue meets the design-step trigger (evidence: ${diag.designStepSignalEvidence || 'see diagnosis'}). ` +
      `Your plan MUST explicitly answer: does this ship as ONE PR, or as N independently-shippable slices — if N, name them, their acceptance criteria, and their order; if one, justify why despite the risk classification. ` +
      `This is a mandatory section, not optional prose — the human decides the split-or-not call from your answer.`
    : ''
  return `cd into the shared worktree "${wtPath}" (frozen base; never checkout/commit). Scout and plan issue #${issue}. Brief: ${brief}.${pm ? `\n\nPM framing:\n${JSON.stringify(pm)}` : ''}${diag ? `\n\nConfirmed diagnosis (Theo):\n${diag.evidence}` : ''}\n\n` +
    `Write the full plan (including the acceptance checklist) as a Markdown ARTIFACT at "${planPath}" inside the worktree (create the .pipeline/plans/ directory if needed). ` +
    `This artifact is the canonical hand-off Nick and Morgan will consume — make it self-contained. ` +
    `REWRITE IN PLACE — accretion is the defect. On an amendment / re-plan round, OVERWRITE "${planPath}" with the CURRENT plan only: NO before/after or delta tables, NO "AMENDMENT N" headers, NO superseded sections kept "for traceability", NO revision archaeology. ` +
    `The durable history lives in the issue/PR thread and in git commits, never inside the plan (the artifact itself is gitignored build output). ` +
    `An amended plan is about the size of a fresh plan for the current scope — usually SMALLER than the previous revision, never monotonically larger. ` +
    `${SAM_LAYER_RULE} ` +
    `${SAM_ONE_WAY_DOOR}${SAM_PRODUCT_DIRECTION}` +
    `Author the acceptance checklist against ${conventionsRule} — in particular its Format-status and Test-status acceptance-item sections: never assert a whole-repo clean state the base branch cannot satisfy. ` +
    `${ACCEPTANCE_PROOF_RULE} ` +
    `Then post an INDEX comment on issue #${issue} — never the full plan, whatever its size. The index comment is exactly: ${planMarker} alone on its first line, a condensed summary (~15 lines max), the acceptance checklist VERBATIM, and a pointer to the canonical artifact "${planPath}" in the shared worktree. ` +
    `HARD CAP: keep that comment under ${planCommentMaxChars} characters (GitHub rejects an issue-comment body over 65536 chars); it is an index, so the bound holds by construction — if you approach it, cut summary prose, never the checklist. ` +
    `POST IDEMPOTENTLY: write the index body to ".pipeline/issue-${issue}-comment.md", then look for an existing marked comment with ` +
    `\`gh api repos/{owner}/{repo}/issues/${issue}/comments --jq '.[]|select(.body|startswith("${planMarker}"))|.id'\` — if an id comes back, EDIT that comment in place with ` +
    `\`gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -F body=@.pipeline/issue-${issue}-comment.md\`; otherwise create it with \`gh issue comment ${issue} --body-file .pipeline/issue-${issue}-comment.md\`. Reuse the id returned by the listing; never reconstruct it. Never stack a second plan comment on the issue. ` +
    `Then return GO/NO-GO, the COMPLETE text of the artifact in the \`plan\` field (NEVER a summary or pointer to the artifact; the plan gate judges only this field and refuses a plan lacking the checklist lines you return in acceptanceChecklist), and the artifact path in \`planPath\` (use "${planPath}"), and \`targetFiles\`: the worktree-RELATIVE paths your steps modify, delete or create (repo-relative, no absolute path, no \`..\`; omit it if your plan touches no file). Return the acceptance checklist lines VERBATIM (\`- [ ] ...\` lines only, no markers, no prose) in \`acceptanceChecklist\`.\n\n` +
    `OUTPUT-SPEC GATE: if this is a human-facing deliverable (asset/render/copy/UI-visible), the plan MUST start from a concrete OUTPUT EXAMPLE with named content contracts, and MUST cite any existing corpus/asset spec (precedent: a similar prior deliverable, if one exists). If no spec exists, propose the contract for human validation — do not skip it.\n` +
    `OBSERVED-INTERFACES RULE: any step consuming an external interface MUST cite a REAL observed payload. REUSE a provided field (e.g. \`qr_url\`) over reconstructing it — reconstruction is a plan defect.\n` +
    `VERSION RULE: do NOT bump .claude-plugin/plugin.json or the BUILD line; the Lead's scripts/lead-merge.sh bumps at merge time.${designStepBlock}${fixBlock}${auditFixBlock}${reviewFixBlock}`
}

// ---------------------------------------------------------------------------
// Plan phase
// ---------------------------------------------------------------------------

if (after('plan', entryStage)) {
  phase('Plan')
  await updateStatus('Plan')   // FIRST — so NO-GO → trace ['Plan','Blocked']

  if (pmReview) {
    pm = await callAgentSafe(
      'mia',
      `PM framing for issue #${issue}. Brief: ${brief}`,
      { agentType: 'Mia', phase: 'Plan', model: 'haiku' },
    )
    if (isAgentDeath(pm)) {
      log('Mia died — degrading to no PM framing (framing-degraded), continuing')
      trace.push('framing-degraded')
      pm = null
    }
  }

  // Plan-verification gate (Ruling 4) — bounded Sam <-> planCheck loop. Mia stays
  // OUTSIDE the loop (already ran once above). Each iteration re-prompts Sam (with the prior
  // planCheck.issues appended on retry), captures samPlan as the script variable (never
  // re-read from GitHub), then runs a cheap haiku conformance check on it. CONFORMING breaks
  // the inner loop; NOT_CONFORMING loops back to Sam until maxPlanAttempts, then escalates.
  //
  // An OUTER loop wraps the inner scout <-> planCheck loop: once the inner loop clears
  // CONFORMING, an optional independent plan-soundness audit runs (planAuditEnabled). A
  // blocking finding (or NOT_SOUND) sends ONE consolidated amendment back through the inner
  // loop; `planAudit` OFF (the default) never enters this branch, so the OFF path stays
  // byte-identical to the state before this mechanism existed — `planPass` is monotonic across outer iterations and equals
  // `planAttempt` whenever the stage never amends, so labels/fixture indices (1, 2, …) are
  // unchanged off-path.
  let sam = null
  let planPass = 0
  let auditRound = 0
  let auditResult = null
  const auditTrace = []
  let auditFixBlock = ''
  while (true) {
    let planAttempt = 0
    let checkIssues = []
    while (true) {
      planAttempt++
      planPass++
      const fixBlock = checkIssues.length
        ? `\n\nPLAN-VERIFICATION GATE FLAGGED THIS PLAN (attempt ${planAttempt}) — fix ALL of these before resubmitting:\n${checkIssues.map(i => `- ${i}`).join('\n')}`
        : ''

      sam = await callAgentSafe(
        'sam',
        samScoutPrompt({ fixBlock, auditFixBlock }),
        { agentType: scoutAgent, phase: 'Plan', schema: SAM, label: `scout-issue-${issue}-${planPass}`, model: scoutModel },
      )
      if (isAgentDeath(sam)) {
        return finish({ status: 'plan-died', issue, planPath, trace, resumable: true })
      }

      if (sam.decision === 'NO-GO') {
        log(`Sam: NO-GO — ${sam.rationale || 'see report'}`)
        await updateStatus('Blocked')
        return finish({ status: 'no-go', reason: sam.rationale, plan: sam.plan, trace })
      }

      // Capture the plan into the script variable — the hand-off payload for Dev + Review.
      samPlan = sam.plan
      samTargetFiles = sam.targetFiles
      samAbsorbedIssues = safeAbsorbedIssues(sam.absorbedIssues, issue)

      // #153: the gate judges only the returned text. A summary/pointer plan that lacks the checklist
      // lines Sam also returned is refused here (no plan-check call) and looped back to Sam.
      const missingChecklist = planMissingChecklistLines(sam.plan, sam.acceptanceChecklist)
      if (missingChecklist.length > 0) {
        log(`Plan-verification gate: returned plan lacks ${missingChecklist.length} acceptance checklist line(s) Sam also returned (summary/pointer plan) — refusing without a plan-check call`)
      }
      const planCheck = missingChecklist.length > 0
        ? {
            verdict: 'NOT_CONFORMING',
            issues: [`The returned plan field is a summary/pointer, not the full plan: ${missingChecklist.length} acceptance checklist line(s) you returned are absent from it. Return the FULL artifact text from "${planPath}" in the plan field, including the acceptance checklist and the Proof log.`],
          }
        : await callAgentSafe(
        'planCheck',
        `You are a cheap, binary conformance gate on Sam's plan for issue #${issue} — verify it against the plan text below (authoritative; do NOT re-read the issue from GitHub).\n\n` +
          `PLAN:\n${samPlan}\n\n` +
          `Verify: (1) a corpus/asset spec is cited when one exists, for human-facing/asset lanes; (2) any external interface is cited from a REAL observed payload, never reconstructed; (3) human-facing/asset lanes have a written output example + named content contracts. Lanes with no human-facing/asset deliverable (pure backend/mechanical) auto-pass item (3) as N/A.\n` +
          `(4) CONFORMANCE COMPLETENESS: the plan MUST contain an acceptance-checklist section. A criterion is an ORPHAN only when it names a concrete deliverable or behavior that no plan step addresses => NOT_CONFORMING (list each orphan in issues). Standard boilerplate verification criteria — full regression/test suite green, lint clean, format-check clean, scope-guard/diff-stat checks — are gate-level (satisfied by the project's own build/test/format commands, never authored as a dedicated plan step) and are EXEMPT from this check; never flag them as orphans. No acceptance-checklist section at all => NOT_CONFORMING.\n` +
          `(5) ACCEPTANCE PROOF CHECK: NOT_CONFORMING (list each offending item in issues) when an acceptance item has no executed command with its verbatim quoted output in the plan (Proof log), or is phrased as an external-world state or a "no known X" / "absence of Y" claim about anything outside the diff.\n` +
          `Return { verdict: 'CONFORMING'|'NOT_CONFORMING', issues: string[] } — issues empty when CONFORMING.`,
        { schema: PLAN_CHECK, label: `plan-check-${issue}-${planPass}`, model: 'haiku' },
        planPass,
      )
      if (isAgentDeath(planCheck)) {
        return finish({ status: 'plan-check-died', issue, planPath, trace, resumable: true })
      }

      if (planCheck.verdict === 'CONFORMING') break

      if (planAttempt >= maxPlanAttempts) {
        log(`Plan-verification gate: NOT_CONFORMING after ${planAttempt} attempt(s) — escalating`)
        await updateStatus('Blocked')
        return finish({ status: 'escalate', reason: 'plan-not-conforming', issue, planCheckIssues: planCheck.issues || [], trace })
      }

      checkIssues = planCheck.issues || []
      log(`Plan-verification gate: NOT_CONFORMING (attempt ${planAttempt}) — looping back to Sam`)
    }

    if (!planAuditEnabled) break

    auditRound++
    const auditPrompt =
      `You are an INDEPENDENT plan auditor for issue #${issue}. You did NOT write this plan and have no stake in it. ` +
      `Find what is WRONG with it before a single line of code exists — a friendly review is a failed review.\n\n` +
      `Target stack: ${auditStack || 'not declared — infer it from the worktree'}. Worktree "${wtPath}" is READ-ONLY for you — never checkout, commit, or modify anything in it.\n` +
      `Issue #${issue}. Brief: ${brief}. The plan text below is authoritative — do NOT re-read the issue or the plan from GitHub.\n\n` +
      `PLAN:\n${samPlan}\n\n` +
      `AXIS 1 — SECURITY, a lightweight structured pass (design-stage practice: OWASP Threat Modeling / Secure-by-Design):\n` +
      `1. Enumerate the surfaces this plan creates or touches: inputs, outputs/rendering, authn/authz boundaries, third-party or user-imported content, headers / caching / storage. Skip untouched surfaces explicitly.\n` +
      `2. STRIDE-lite sweep per surface — Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege.\n` +
      `3. OWASP Top 10 (current edition) as a checklist over the same surfaces; fetch the current list from https://owasp.org/Top10/ this session, never recite it from memory.\n` +
      `These categories are a checklist so you do not have to invent threats from a blank page — not a taxonomy to fill in, and not a list of vulnerabilities to expect. ` +
      `This is a ~15-minute design-stage pass, not a full threat model: no data-flow diagrams, no trust-boundary formalism, no risk scoring. Report nothing on a category rather than manufacture a finding — an empty security section is a valid outcome.\n` +
      `A category alone is never a finding. Each security item names the concrete attack on a named surface of THIS plan, carries a rewrite mandate as fix, and tags title with its STRIDE letter(s) + OWASP category (e.g. "[STRIDE:T · OWASP A05 Injection] …").\n\n` +
      `AXIS 2 — IDIOMACY vs the CURRENT version of the stack.\n\n` +
      `AXIS 3 — DEBT: classify every non-idiomatic choice as fenced-debt (acceptable, plan must name the exit) / accidental-debt (free to avoid) / structural-mistake (redesign now).\n\n` +
      `NEVER-FROM-MEMORY RULE (hard): any claim about a library, framework, API, version or best practice — including the OWASP Top 10 category list itself — MUST be verified this session against current documentation (context7, else WebSearch) and cited in sources; an unverifiable claim is stated as unverified, never as fact.\n\n` +
      `ACCEPTANCE PROOF CHECK: an acceptance item lacking an executed command with quoted output, or phrased as an external-world / "no known X" state, is a blocking finding (severity 'blocking', fix = rewrite the item to a command run in the worktree with its output logged).\n` +
      `FINDINGS: ranked most-damaging first; each carries a concrete rewrite mandate as fix, never a hint. severity:'blocking' = the plan must change before dev; 'note' = worth doing, not a blocker; when in doubt, blocking.\n` +
      `VERDICT GRID: SOUND (nothing to change) / SOUND-WITH-NOTES (approach holds, findings still fold in) / NOT_SOUND (approach itself is wrong).\n\n` +
      `Return { verdict: 'SOUND'|'SOUND-WITH-NOTES'|'NOT_SOUND', findings: [{severity, area, title, finding, fix, debtClass?, sources}], stackVerified: string }.`

    auditResult = await callAgentSafe(
      'audit',
      auditPrompt,
      { schema: PLAN_AUDIT, label: `plan-audit-${issue}-${auditRound}`, model: planAuditModel },
      auditRound,
    )
    if (isAgentDeath(auditResult)) {
      return finish({ status: 'plan-audit-died', issue, auditRounds: auditRound, trace, resumable: true })
    }
    trace.push(`plan-audit:${auditResult?.verdict ?? 'malformed'}`)

    const routing = auditRouting(auditResult, auditRound, maxAuditRounds)
    // Per-round convergence record: auditResult is overwritten each iteration, so
    // round 1's blocking count was LOST the moment a run reached round 2 — the exact number the
    // escalation diagnosis needs. blockingCount reuses routing.blocking (the SAME fail-closed
    // severity predicate that routes), never a second predicate that could drift from it.
    // structuralMistakeCount is INFORMATIVE ONLY — a self-tagged enum from the auditor's own
    // output, surfaced for the Lead's mandatory diagnosis and NEVER read by any gate (same
    // principle as pr-acceptance.md: the agent's own classification alone is never authoritative).
    {
      const roundFindings = Array.isArray(auditResult?.findings) ? auditResult.findings : []
      auditTrace.push({
        round: auditRound,
        verdict: auditResult?.verdict ?? null,
        blockingCount: routing.blocking.length,
        structuralMistakeCount: roundFindings.filter(f => f && f.debtClass === 'structural-mistake').length,
      })
    }
    if (routing.action === 'proceed') break
    if (routing.action === 'escalate') {
      log(`Plan audit: ${routing.reason} after ${auditRound} round(s) — escalating`)
      await updateStatus('Blocked')
      return finish({
        status: 'escalate', reason: routing.reason, issue,
        auditVerdict: auditResult?.verdict ?? null,
        auditFindings: auditResult?.findings ?? [],
        auditRounds: auditRound, trace,
        auditTrace, ...auditConvergenceNote(auditTrace),
        maxAuditRounds, maxAuditRoundsOverrideReason: auditBudgetOverrideReason || null,
      })
    }
    // amend
    trace.push(`plan-audit-amend:${auditRound}`)
    auditFixBlock = composeAuditFixBlock(auditResult.findings)
    log(`Plan audit: blocking finding(s) — looping back to the scout for one amendment round (round ${auditRound})`)
  }

  // R3 (#77) — 5th design-step signal, computed here from Sam's plan + targetFiles against the repo's
  // declared oneWayDoorKinds / oneWayDoorPaths (never an LLM-filled field). Same status and bypass as
  // the trigger above: no new status, agent or seam. `oneWayDoorHits` = what fired (a kind or `path`).
  const oneWayDoor = oneWayDoorSignals(sam.plan, sam.targetFiles, { issue, planPath, paths: config.oneWayDoorPaths, kinds: config.oneWayDoorKinds })
  if (oneWayDoor.kinds.length > 0 && !architectureDecisionApproved) {
    log(`R3 one-way-door: plan adds ${oneWayDoor.kinds.join(' + ')} — design step required`)
    trace.push(`one-way-door:${oneWayDoor.kinds.join('+')}`)
    await updateStatus('Blocked')
    return finish({
      status: 'design-step-required',
      issue, trace, planPath,
      oneWayDoorHits: oneWayDoor.kinds,
      reason: oneWayDoor.summary.join('\n'),
    })
  }

  if (gate('plan')) return finish({
    status: 'plan-ready', plan: sam.plan, planPath, issue, trace,
    auditVerdict: auditResult?.verdict ?? null,
    auditFindings: auditResult?.findings ?? [],
    auditRounds: auditRound,
    auditTrace, ...auditConvergenceNote(auditTrace),
    maxAuditRounds, maxAuditRoundsOverrideReason: auditBudgetOverrideReason || null,
  })
}

// ---------------------------------------------------------------------------
// Resume safety — entering at 'dev'/'review' means Sam did not run in this
// process, so `samPlan` is still null. Re-materialize it: prefer the `planText`
// arg; otherwise the downstream agent re-reads the artifact at `planPath`. In a
// real run we require ONE of the two so the plan is never silently lost; under
// `simulate`, fixtures drive the flow and no plan text is needed.
// ---------------------------------------------------------------------------

let planFromArtifact = false
if (samPlan === null && (after('dev', entryStage) || after('review', entryStage)) && !simulate) {
  if (planText && String(planText).trim()) {
    samPlan = planText
  } else {
    // No plan text in hand: fall back to the on-disk artifact, re-read by the agent.
    planFromArtifact = true
    log(`Resume at entryStage='${entryStage}' without planText — Nick/Morgan will re-read the plan artifact at ${planPath}.`)
  }
}

// Plan reference block inlined into every downstream prompt (advisory.js style):
// either the captured/supplied plan text, or an instruction to read the artifact.
// #97 — `let` (was `const`) + refreshPlanBlock(): a Review-phase plan-amendment round
// (S11) rewrites `samPlan` in place and calls refreshPlanBlock() so the NEXT Nick-fix and
// Morgan re-review prompts (the two loop-body consumers below) pick up the amended plan —
// this is the actual #96 fix (a frozen `const` plan block is why Morgan re-flagged the same
// stale plan on PR #96). The hand-off invariant itself is unchanged: the plan is NEVER
// re-read from GitHub, only recomputed from the in-process `samPlan` script variable.
let planBlock = samPlan && String(samPlan).trim()
  ? `Sam's plan (authoritative — do NOT re-read it from GitHub):\n${samPlan}`
  : `Sam's plan artifact lives at "${planPath}" inside the worktree — read it from there (do NOT re-read it from GitHub issue comments).`
const refreshPlanBlock = () => {
  planBlock = samPlan && String(samPlan).trim()
    ? `Sam's plan (authoritative — do NOT re-read it from GitHub):\n${samPlan}`
    : `Sam's plan artifact lives at "${planPath}" inside the worktree — read it from there (do NOT re-read it from GitHub issue comments).`
}

// ---------------------------------------------------------------------------
// Already-done guard (item 7) — only for resume entries, not a fresh plan→dev flow
// ---------------------------------------------------------------------------

if (entryStage === 'dev' || entryStage === 'review') {
  const guard = await callAgentSafe(
    'alreadyDoneCheck',
    `Check whether issue #${issue} is already done. Target the correct repo — gh resolves the wrong ` +
    `repo from an unrelated cwd, causing a false already-done:\n` +
    (repo
      ? `0. REPO="${repo}" (from config.repo).\n`
      : `0. cd into "${wtPath}"; REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) — if this fails, run steps 1-2 from within "${wtPath}" (cwd-scoped, still correct).\n`) +
    `1. gh issue view ${issue} -R "$REPO" --json state,createdAt — report issueState and issueCreatedAt ` +
    `VERBATIM from that output's .state and .createdAt (CLOSED → issue is done).\n` +
    `2. gh pr list -R "$REPO" --search "is:merged head:${expectedBranchName}" --json number,mergedAt,headRefName,body -q '.[0]' — ` +
    `if it prints a row, report mergedPr, mergedAt and mergedHeadRef VERBATIM from that SAME row (number, mergedAt, headRefName); ` +
    `if it prints nothing / null / [], set isMerged:false, mergedAt:"" and mergedPrClosesIssue:false — NEVER look at another PR, branch, repo or memory, ` +
    `and NEVER reuse a row from a different search.\n` +
    `3. MULTI-SLICE EPIC CHECK (a merged PR on this branch may belong to an EARLIER slice of the same epic issue, not this one — lgtmgate#197): from that SAME row's .body, set mergedPrClosesIssue:true ONLY if it contains one of GitHub's closing keywords (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved — case-insensitive) immediately followed by "#${issue}" (the exact issue number, word boundary); otherwise mergedPrClosesIssue:false. This is NOT the issue's open/closed state (that is isIssueClosed from step 1) — it is whether THIS merged PR's own body claims to close #${issue}.\n` +
    `TOOL FAILURE (fail loud, never guess): if either gh command itself fails — "tls: failed to verify certificate", ` +
    `"x509", "OSStatus", an HTTP 401/403, a network error, an auth error, or any non-zero exit that is NOT a result — ` +
    `that is a TOOL failure, not an answer. One plain retry of the SAME command is allowed; if it still fails, ` +
    `STOP and return { isAlreadyDone:false, isMerged:false, mergedAt:"", checkFailed:true, error:"<exact stderr line>" }. ` +
    `NEVER guess, NEVER fill mergedAt with the current date or a remembered value, NEVER report isMerged:true from a failed command.\n` +
    `Return { isAlreadyDone, isIssueClosed, issueState, issueCreatedAt, isMerged, mergedAt, mergedPr, mergedHeadRef, mergedPrClosesIssue, checkFailed, error }`,
    { schema: ALREADY_DONE_CHECK, label: `already-done-check-${issue}`, model: 'haiku' },
  )
  if (isAgentDeath(guard)) {
    // The guard is "a safety net, never a merge gate" (see the log line below on an
    // unverified claim) — killing a resume over a DEAD safety net inverts its purpose.
    // Degrade: skip the acceptAlreadyDone verdict block entirely and proceed with the run.
    log('Already-done guard died — skipping (safety net, never a merge gate), proceeding with the run')
    trace.push('already-done-degraded')
  } else {
    const expectedHead = `${expectedBranchName}`
    // Harness bans argless new Date() (breaks resume) — the run timestamp travels via
    // args.stamp (epoch ms); with no stamp the future-merged check degrades gracefully
    // (acceptAlreadyDone skips it on a non-finite as-of parse).
    const verdict = acceptAlreadyDone(guard, expectedHead, stamp ? new Date(Number(stamp)).toISOString() : '')
    if (verdict.accepted) {
      log(`Already-done guard: issue #${issue} is ${verdict.reason} — aborting relaunch`)
      return finish({ status: 'already-done', issue, mergedAt: verdict.reason === 'merged' ? (guard.mergedAt || null) : null, trace })
    }
    if (guard?.isAlreadyDone === true || guard?.checkFailed === true) {
      log(`Already-done guard ERROR: unverified already-done claim rejected (${verdict.reason})${guard?.error ? ` — gh: ${guard.error}` : ''}. Proceeding with the run; the guard is a safety net, never a merge gate.`)
    }
  }
}

// ---------------------------------------------------------------------------
// Dev phase
// ---------------------------------------------------------------------------

let nick = null
let planStaleFiles = null   // #103 — non-empty array when a plan target moved upstream; null = probe
                             // skipped (off mode, no targets, or probe failure) or not yet run
let planTargetsChecked = 0  // #103 — count of sanitized targetFiles the probe actually diffed
let openSubIssues = null       // lgtmgate#193 — probe result (array of open sub-issue
                                // numbers as strings), null = probe skipped/failed (fail-open)
let subIssuesUncovered = []    // lgtmgate#193 — post-gate list, exposed on dev-done finish() for tests

// Branch-conformance guard (lgtmgate#29) — the dispatch worktree can arrive on a foreign branch
// (e.g. another orchestrator's scheduled dispatch naming its own `git worktree add -B <prefix>-issue-<N>`), so the pipeline ASSERTS the
// PR head instead of assuming the caller named it right. Fails loud HERE, before Review, rather
// than letting pr-finalize's blast-radius guard reject it after Morgan's rounds are spent.
// Extracted (lgtmgate#45) so the SAME check runs both on a fresh Dev-phase dispatch AND on an
// `entryStage:'review'` resume, which otherwise skips the entire Dev block (and therefore this
// guard) since `after('dev', entryStage)` is false for that entryStage.
const assertBranchConformance = async (prNum, nickBranchFallback) => {
  const expectedBranch = `${expectedBranchName}`
  let headRef = nickBranchFallback ?? null
  let rawHeadRef = null
  let branchPf = null   // one preflight 'branch' probe per guard call, shared by the head-ref and prefix reads
  let branchPfDone = false
  const branchProbe = async () => {
    if (!branchPfDone) {
      branchPfDone = true
      branchPf = await preflightProbe('branch', 'branch', ['--wt', wtPath, '--pr', prNum ? String(prNum) : '', '--repo', repo || '', '--stamp', String(stamp ?? '')])
    }
    return branchPf
  }
  if (simulate) {
    if (simulate.probes?.branchCheckRaw !== undefined) rawHeadRef = simulate.probes?.branchCheckRaw
  } else if (prNum) {
    const pf = await branchProbe()
    if (pf) rawHeadRef = pf.headRef ?? ''
    else log(`Branch guard: preflight branch probe unavailable — falling back to nick.branch`)
  }
  if (rawHeadRef !== null) {
    const parsed = parseHeadRef(rawHeadRef, expectedBranch)
    if (parsed) {
      headRef = parsed
      if (parsed !== String(rawHeadRef).trim()) {
        trace.push('branch-check-normalized')
        log(`Branch guard: normalized raw answer "${String(rawHeadRef).slice(0, 120)}" -> "${parsed}"`)
      }
    } else {
      trace.push('branch-check-unparsed')
      log(`Branch guard: unparsed raw answer "${String(rawHeadRef).slice(0, 120)}" — falling back to nick.branch`)
    }
  }
  if (headRef !== expectedBranch) {
    let realBranchPrefixRaw = null
    if (branchOverrideName !== null) {
      // #232: an explicit override is authoritative — never accept a config-prefix branch.
    } else if (simulate) {
      if (simulate.probes?.configBranchPrefixRaw !== undefined) realBranchPrefixRaw = simulate.probes?.configBranchPrefixRaw
    } else {
      const pf = await branchProbe()
      if (pf) realBranchPrefixRaw = pf.branchPrefix
      else log(`Branch guard: preflight branch probe unavailable — escalating as before`)
    }
    const reconciled = branchOverrideName !== null ? null : reconcileStaleBranchPrefix(headRef, issue, realBranchPrefixRaw)
    if (reconciled) {
      trace.push('branch-check-reconciled')
      log(`Branch guard: PR #${prNum} head "${headRef}" mismatches the caller-supplied expectedBranch "${expectedBranch}" but matches the worktree's own pipeline.config.json branchPrefix — accepting (lgtmgate#131, cross-repo config drift)`)
    } else {
      log(`Branch mismatch: PR #${prNum} head is "${headRef}", expected "${expectedBranch}"`)
      trace.push(`branch-mismatch:${headRef}`)
      // Named (not returned as a bare object literal) so this intermediate escalate value — which
      // the caller always wraps in finish() before it ever leaves the pipeline — doesn't trip the
      // stamp-placement guard's textual scan for unstamped status-object returns
      // (test-canonical-guards.sh); same shape/keys, no behavior change.
      const branchMismatch = {
        status: 'escalate', reason: 'branch-mismatch',
        expectedBranch, actualBranch: headRef,
        pr: prNum ?? null, issue, trace,
      }
      return branchMismatch
    }
  }
  return null
}

if (after('dev', entryStage)) {
  phase('Dev')
  await updateStatus('Dev')

  // Plan-freshness probe (#103) — best-effort, read-only (fetch + diff only, never checkout/
  // reset/rebase/pull/merge). Diffs Sam's declared target files against origin/<baseBranch> so a
  // plan whose premise moved upstream since the worktree's frozen base is caught here, before
  // Nick ever opens a doomed PR. Mirrors worktreeBehindCount's shape/fail-open contract exactly.
  const planTargets = safePlanTargets(samTargetFiles)
  planTargetsChecked = planTargets.length
  // #83: the three pre-Dev reads (plan freshness, open sub-issues, git-dir writable) are ONE probe.
  // null = probe unavailable -> each read below takes its existing fail-open skip.
  const preflightDev = simulate ? null : await preflightProbe('dev', 'dev', [
    '--wt', wtPath, '--issue', String(issue), '--base', baseBranch, '--repo', repo || '',
    '--targets', planTargets.join(' '), '--stamp', String(stamp ?? ''),
  ])
  if (planFreshnessMode !== 'off' && planTargets.length > 0) {
    const planStaleFilesProbe = async () => {
      if (simulate) return simulate.probes?.planStaleFiles
      if (!preflightDev || !Array.isArray(preflightDev.planStale)) {
        log(`planStaleFilesProbe: no preflight result, skipping plan-freshness check`)
        return null
      }
      return preflightDev.planStale
    }
    planStaleFiles = await planStaleFilesProbe()
    if (Array.isArray(planStaleFiles) && planStaleFiles.length > 0) {
      trace.push(`plan-stale:${planStaleFiles.length}`)
      log(`Plan freshness: ${planStaleFiles.length} target file(s) changed upstream on origin/${baseBranch} since the frozen base — ${planStaleFiles.join(', ')}`)
      if (planFreshnessMode === 'gate') {
        await updateStatus('Blocked')
        return finish({ status: 'escalate', reason: 'plan-stale', staleFiles: planStaleFiles, planTargetsChecked, issue, trace })
      }
    }
  }

  const openSubIssuesProbe = async () => {
    if (simulate) return simulate.probes?.openSubIssues
    if (!preflightDev || !Array.isArray(preflightDev.openSubIssues)) {
      log(`openSubIssuesProbe: no preflight result, skipping sub-issues gate (fail-open, mirrors planStaleFilesProbe)`)
      return null
    }
    return preflightDev.openSubIssues
  }
  openSubIssues = await openSubIssuesProbe()
  const subGate = Array.isArray(openSubIssues)
    ? subIssuesGate(openSubIssues, samAbsorbedIssues)
    : { blocked: false, uncovered: [] }
  subIssuesUncovered = subGate.uncovered
  if (subGate.blocked) {
    trace.push(`sub-issues-open:${subGate.uncovered.length}`)
    log(`Epic #${issue} has ${subGate.uncovered.length} open sub-issue(s) not covered by this run (${subGate.uncovered.join(', ')}) — composing a non-closing reference instead of Closes #${issue}.`)
  }

  // Worktree write-access preflight (#263, companion real incident #262: 5 agents, ~546k
  // tokens, ~3 min burned when Nick discovered a sandbox permission gap mid-stage). Cheap,
  // fail-open probe against the REAL git-dir (`.git/worktrees/<branch>`, distinct from the
  // worktree checkout path itself) — touches/unlinks a marker file there (unlink, never rm: a repo denying Bash(rm *) refuses the whole probe, #99), never wtPath or any
  // tracked file. Ungated by entryStage (unlike the fresh-dispatch provision-stale preflight
  // above): a resumed run can hit the same external sandbox-grant gap as a fresh one.
  const gitDirWritableProbe = async () => {
    if (simulate) return simulate.probes?.gitDirWritable
    if (!preflightDev || typeof preflightDev.writable !== 'boolean') {
      log(`gitDirWritableProbe: no preflight result, skipping worktree write-access preflight (fail-open)`)
      return null
    }
    return { writable: preflightDev.writable, gitDir: preflightDev.gitDir }
  }
  const gitDirProbe = await gitDirWritableProbe()
  if (gitDirProbe && gitDirProbe.writable === false) {
    trace.push(`worktree-git-dir-not-writable:${gitDirProbe.gitDir || 'unknown'}`)
    log(`Worktree write-access preflight: git-dir "${gitDirProbe.gitDir}" is not writable — escalating before Nick spawn`)
    await updateStatus('Blocked')
    return finish({ status: 'escalate', reason: 'worktree-git-dir-not-writable', gitDir: gitDirProbe.gitDir, issue, wtPath, trace })
  }

  const epicRef = subGate.blocked ? `(see #${issue})` : 'Closes #' + issue
  const closesLine = [epicRef, ...samAbsorbedIssues.map(n => 'Closes #' + n)].join(', ')
  // R2 (#76): deterministic — the fixture acceptance item is decided here, never by Nick's judgment.
  const r2Applies = issueType === 'bug' && safePlanTargets(samTargetFiles).some(p => p.startsWith('workflows/'))
  const r2Note = r2Applies
    ? `R2 fixture rule (issue #${issue}): add this acceptance item to the checklist verbatim — "fixture \`fixtures/incidents/${issue}-*.json\` present, replayed red on base and green on the branch by \`scripts/run-offline.cjs\`". If no such fixture exists in the branch, run \`gh issue edit ${issue} -R ${repo || '<repo>'} --add-label no-fixture\` and use \`Refs #${issue}\` instead of \`Closes #${issue}\` on the first line of the PR body (the issue then stays open). `
    : ''
  const nickPrompt = (
    `Work in the shared worktree "${wtPath}" (cd into it; it already exists${worktreeRoot ? `; worktree root: ${worktreeRoot}` : ''}). ` +
      `Issue #${issue}. Brief: ${brief}. The plan text below is authoritative — do NOT re-read the issue or the plan from GitHub.\n\n` +
      `${planBlock}\n\n${planFreshnessNote(planStaleFiles, baseBranch)}${resumeReasonNote(resumeReason, prNumber, baseBranch)}` +
      `FIRST, before ANY commit: the worktree may have been dispatched on a foreign branch. ` +
        `Run \`git -C "${wtPath}" rev-parse --abbrev-ref HEAD\`; if it is not exactly \`${expectedBranchName}\`, ` +
        `if the branch already exists locally (\`git -C "${wtPath}" rev-parse --verify --quiet refs/heads/${expectedBranchName}\` succeeds) run \`git -C "${wtPath}" switch ${expectedBranchName}\`, otherwise run \`git -C "${wtPath}" switch -c ${expectedBranchName}\`; never reset or force the branch (no \`-B\`/\`-C\`, no \`reset --hard\`), and if the switch is refused because of a dirty tree, stop and report instead of forcing. Then re-run \`git -C "${wtPath}" rev-parse --abbrev-ref HEAD\` to confirm. ` +
        `Every commit, the push and the PR head MUST be \`${expectedBranchName}\`. ` +
        `Implement the plan on that branch. Write meaningful tests and get the green bar: build via \`${buildCmd}\`, run unit tests via \`${testCmd}\`, and format each modified file via \`${formatCmd}\`. ` +
      `When deleting repo-tracked files, use \`git rm <file>\` instead of bare \`rm\` — bare rm is sandbox-denied and burns permission rounds. ` +
      `${SANDBOX_INSTALL_HINT} ` +
      `Push the branch explicitly before opening the PR: \`git push origin ${expectedBranchName}\` (no upstream flag — the sandbox cannot write the worktree's .git/config, CC bug #51818; see .claude/rules/git-workflow.md). ` +
      `If that push fails because the SSH remote is unreachable in the sandbox (\`ssh_dispatch_run_fatal\`, \`Broken pipe\`, \`Connection refused\`, \`Could not resolve hostname\`; CC issues #30619, #33300), retry ONCE over HTTPS through the gh credential helper (github.com:443 is reachable, SSH is not): \`${httpsPushCmdFor(expectedBranchName)}\` (explicit refspec, no upstream flag, no sandbox bypass). If the HTTPS push fails too, do not bypass the sandbox and do not open a PR: stop, return prNumber 0 with a summary that quotes the failing command and its error. ` +
      `Open a PR (draft) with EXPLICIT refs — gh resolves HEAD from the invoking cwd, not the worktree branch: \`gh pr create --draft${prFlag} --base ${baseBranch} --head ${expectedBranchName} ...\`. ` +
      `${r2Note}` +
      `Compose the PR body in this order (artifact-first structure): first line \`${closesLine}\` — one \`Closes #N\` per fully-resolved issue (the epic plus every issue Sam's plan explicitly named as fully resolved by this bundle; never for an issue flagged partial/residual in the plan — that one stays open, with a forward-reference comment on the child issue instead, as already practiced); ${subIssuesGateNote(subIssuesUncovered, issue)}then a \`## What this ships\` H2 with a bullet summary of the diff; then, ONLY IF the acceptance checklist below contains a \`[human-gate]\` item, an optional \`## <Human> — N gestures\` H2 listing those manual human actions (omit this H2 entirely when no \`[human-gate]\` item exists — never ship an empty stub section); then a \`## Acceptance checklist\` H2. Copy the acceptance checklist into the PR body between \`<!-- acceptance:start -->\`/\`<!-- acceptance:end -->\`. Leave an EMPTY \`<!-- decision-log:start -->\`/\`<!-- decision-log:end -->\` marker pair right after the acceptance block — workflow-owned, never hand-fill it. Close with a \`<details><summary>Technical detail</summary>\` fold holding the test plan / feature flag / risk notes. Post a comment on issue #${issue} linking the PR, then idle.`
  )
  if (simulate) nickPromptPreview = nickPrompt
  nick = await callAgentSafe(
    'nick',
    nickPrompt,
    { agentType: 'Nick', phase: 'Dev', schema: NICK, label: `nick-issue-${issue}`, model: 'sonnet' },
  )
  if (isAgentDeath(nick)) {
    return finish({ status: 'dev-died', issue, trace, resumable: true })
  }

  const branchGuardResult = await assertBranchConformance(nick?.prNumber, nick?.branch)
  if (branchGuardResult) { await updateStatus('Blocked'); return finish(branchGuardResult) }

  if (gate('dev')) return finish({ status: 'dev-done', pr: nick.prNumber, issue, planStaleFiles, planTargetsChecked, subIssuesUncovered, trace })
}

// ---------------------------------------------------------------------------
// Review phase
// ---------------------------------------------------------------------------

if (after('review', entryStage)) {
  phase('Review')
  await updateStatus('Review')

  const pr = nick?.prNumber ?? prNumber
  if (!pr) {
    // No-PR terminal delivery — Nick can legitimately deliver without opening a PR
    // (e.g. the deliverables were pre-existing PRs). Only treat as terminal when the evidence is
    // there (tests green + a real summary); otherwise this stays the loud dev failure it always was.
    const noPrDelivery = nick?.testsPass === true &&
      typeof nick?.summary === 'string' && nick.summary.trim().length > 0
    if (noPrDelivery) {
      log('No-PR terminal delivery: nick reported testsPass=true with a summary and no PR — skipping Review')
      trace.push('delivered-no-pr')
      const leadAction = `Lead: if the branch was not pushed (SSH blocked in the sandbox, #108), push it with \`${httpsPushCmdFor(expectedBranchName)}\`, then open the PR with \`gh pr create --draft${prFlag} --base ${baseBranch} --head ${expectedBranchName}\` and relaunch with entryStage:"review" + prNumber.`
      log(`delivered-no-pr: ${leadAction}`)
      return finish({ status: 'delivered-no-pr', issue, summary: nick.summary, leadAction, trace })
    }
    // Dev-stage failure with no evidence and no PR (lgtmgate#262) — whatever the cause
    // (permission gap, agent crash, anything), stay inside the pipeline's normal status
    // vocabulary (mirrors provision-failed/plan-stale) instead of an uncaught throw that
    // kills the run with no actionable state.
    log('Review phase: no PR number and no delivery evidence (nick + prNumber both null) — escalating')
    trace.push('dev-stage-no-pr')
    await updateStatus('Blocked')
    return finish({ status: 'escalate', reason: 'dev-stage-no-pr', issue, trace })
  }

  // Branch-conformance guard, resume path (lgtmgate#45) — `entryStage:'review'` is the only
  // entryStage for which the Dev block above never ran in THIS process, so it is the only one that
  // never called the shared guard function above. `entryStage:'plan'`/`'dev'` both satisfy
  // `after('dev', entryStage)` and already ran the guard there.
  // Fallback seed is the expectedBranch itself, not null: unlike the Dev-phase call (seeded from
  // Nick's own self-reported branch, a real signal worth distrust-and-verify), a resume has no
  // session-local report to seed from — `pr` is always truthy here (the no-PR case above already
  // returned/threw), so real execution always runs the live `gh pr view` check regardless of this
  // seed; it only matters as the harness default when a test does not simulate branchCheckRaw.
  if (entryStage === 'review') {
    const branchGuardResult = await assertBranchConformance(pr, `${expectedBranchName}`)
    if (branchGuardResult) { await updateStatus('Blocked'); return finish(branchGuardResult) }
  }

  // PR comment hygiene — hidden HTML marker the pipeline injects into its OWN posted
  // comments (Morgan's verdicts, Nick's push-notes). All agents share ONE GitHub token, so
  // author filtering is useless/dangerous — targeting is marker-only. Unmarked (human)
  // comments are never touched.
  const reviewMarker = `<!-- pipeline-review-round pr=${pr} -->`
  // Review-freshness marker (#157): Morgan's verdict, and the commit-hygiene squash note (which re-attests the squashed
  // head), carry the head SHA the review was made on. scripts/lead-merge.sh and hooks/block-merge-unchecked.sh refuse a
  // merge unless the latest such marker names the PR head (scripts/lib/review-check.sh). Nick's push-notes keep the bare
  // `reviewMarker`: a push-note is not a review. Prompt text only: the SHA is read by the agent, verified by the merge gate.
  const reviewVerdictMarker = `<!-- pipeline-review-round pr=${pr} sha=<HEAD_SHA> -->`
  const reviewShaRule = `, replacing \`<HEAD_SHA>\` with the full 40-hex head of PR #${pr} that you reviewed: run \`gh pr view ${pr}${prFlag} --json headRefOid -q .headRefOid\` FIRST, before reading the diff, and paste that value verbatim (never shortened, never re-read when posting)`

  // Reviewer-window issue flag (reopened) — settings.json/plugin PreToolUse hooks
  // do NOT fire for spawned Task/Workflow-DSL subagents (CC anthropics/claude-code#27661 /
  // anthropics/claude-code#18392, both CLOSED as DUPLICATE, not FIXED), so a deny hook cannot gate
  // Morgan's `gh issue create` from inside her own subagent session. Compensating control instead,
  // run from the orchestrator (this process, which DOES have live gh access) — but NEVER
  // destructive: all agents (and the human) typically share ONE GitHub login, so there is NO
  // attribution signal to tell Morgan's own issue apart from a concurrent pipeline's or a human's
  // (verified in production: every agent-authored comment carries the same author login).
  // An earlier mechanism (snapshot issue NUMBERS before/after, close whatever is new) was observed
  // in production to silently mis-close issues — including a HUMAN-REOPENED issue
  // (createdAt predates the window; a number-diff cannot see that) and came within a couple of
  // issues of a silent mass-wrong-close once a repo passed the hardcoded before-snapshot page cap. Replacement: candidates
  // are selected by CREATION TIME inside the review window (a reopen keeps its original
  // `createdAt`, so it is never a candidate), and the action on a candidate is a single
  // non-destructive comment — no close, no copied title/body — because unattributed issues must
  // never be closed automatically.
  // PR state reads (E2.5, #84): ONE probe (templates/pr-state.sh, parser `pr-state`, run with noReuse:
  // live state) answers every review-phase read of the PR: the wall clock, the head sha and body
  // digest, mergeability, the commit count and last commit date, the un-minimized review comments and
  // (with `since`) the open issues created in the window. The harness bans argless
  // `new Date()`/`Date.now()` in a workflow script (breaks resume; claude-agent-pipeline#144/#135), so
  // the clock is `date -u` inside pr-state.sh, run by the probe gate: no LLM interprets it (incident #14).
  // Returns the parsed object, or null on any failure (fail-open: every caller keeps its own fallback).
  const prState = async (label, round, { since } = {}) => {
    try {
      const argv = ['--pr', String(pr), '--wt', wtPath]
      if (repo) argv.push('--repo', repo)
      if (since) argv.push('--since', since)
      const cmd = 'bash ' + shellSingleQuote(probeScriptPath('pr-state.sh')) + ' ' + argv.map(shellSingleQuote).join(' ')
      const r = await probe('pr-state', cmd, {
        label,
        round,
        noReuse: true,   // live state: a stored record from an earlier launch must never answer (#83)
        onFail: (reason) => { log(`pr-state probe (${label}, round ${round}): ${reason} — fail-open`); return null },
      })
      return r && r.json && !r.json.error ? r.json : null
    } catch (e) {
      log(`pr-state probe (${label}, round ${round}) failed (${e.message}) — fail-open`)
      return null
    }
  }

  const reviewerWindowStart = async (round) => {
    if (simulate) return simulate.probes?.windowStart
    return (await prState('window-start', round))?.now ?? null
  }

  const flagReviewerWindowIssues = async (windowStart, round, endState) => {
    let candidates
    let windowEnd
    if (simulate) {
      const raw = simulate.probes?.issueWindow?.[round]
      const morganIssuesFx = simulate.probes?.morganIssues
      candidates = raw
        ? reviewerWindowCandidates(raw.issues, windowStart, raw.windowEnd ?? '9999-12-31T23:59:59Z')
        : (morganIssuesFx?.[round] ?? [])
    } else {
      // lgtmgate#18: the scan is bounded server-side by the `created:>=` qualifier and by the
      // script's safety limit (templates/pr-state.sh); a result of exactly that limit comes back as
      // openIssues:null + openIssuesTruncated:true, and a partial list is never treated as exhaustive.
      // A failed probe, a missing window start or a truncated scan skip the pass (fail-open).
      if (!windowStart || !endState || !Array.isArray(endState.openIssues)) {
        log(`flagReviewerWindowIssues round ${round}: issue scan unavailable or truncated, skipping`)
        return
      }
      windowEnd = endState.now
      candidates = reviewerWindowCandidates(endState.openIssues, windowStart, windowEnd)
    }
    const flagged = []
    for (const it of candidates) {
      const num = typeof it === 'number' ? it : it.number
      trace.push(`reviewer-window-issue-flagged:${num}`)
      flagged.push({ number: num, url: it && it.url ? it.url : null })
      if (simulate) continue
      // Non-destructive by design (see the header note above): a single comment on the
      // candidate itself, no copied title/body, and never a close-the-issue call — closing an
      // unattributed issue is exactly the defect this replaces. pr-write.sh skips it when a comment
      // carrying the marker is already there (idempotent across a re-run of the same round).
      await prWrite('issue-comment', 'rw-flag-' + num, round, [
        '--number', num,
        '--marker', `<!-- pipeline-reviewer-window pr=${pr} -->`,
        '--body',
        `<!-- pipeline-reviewer-window pr=${pr} -->\n` +
        `Opened during the reviewer (Morgan) window of PR #${pr} (${windowStart} .. ${windowEnd}).\n` +
        `If this is a review finding, it belongs on that PR, not on a new issue\n` +
        `(see .claude/rules/pr-acceptance.md). If it is unrelated, ignore this comment.\n` +
        `This issue was NOT closed.`,
      ])
    }
    if (!simulate && flagged.length > 0) {
      const lines = flagged.map(f => `- #${f.number}${f.url ? ` (${f.url})` : ''}`).join('\n')
      const rollupMarker = `<!-- pipeline-reviewer-window-rollup pr=${pr} round=${round} -->`
      await prWrite('pr-comment', 'rw-rollup', round, [
        '--pr', pr,
        '--marker', rollupMarker,
        '--body',
        `${rollupMarker}\n` +
        `Reviewer-window issues flagged — opened during this review round, ` +
        `NOT closed (see .claude/rules/pr-acceptance.md):\n\n${lines}`,
      ])
    }
  }

  // PR comment hygiene — best-effort, marker-scoped minimize pass. Collapses (never
  // deletes) prior-round Morgan verdicts + Nick push-notes so only the LATEST verdict stays
  // visible; never filters by author (single shared token, see reviewMarker above) and never
  // throws (mirrors reconcileMorganIssues above). Under-minimize (agent forgets the marker)
  // fails safe = comment stays visible.
  const minimizeSupersededReviewComments = async (round) => {
    // Opt-in only (config.commentHygiene: true). The minimizeComment GraphQL
    // mutation is denied by the supervised-session safety classifier on every
    // attempt, so by default the pass is skipped entirely: two agent spawns and
    // red error entries per round bought zero effect. Superseded comments simply
    // stay visible. Simulate mode still exercises the flow logic.
    // HARD PRE-CONDITION (was): config.commentHygiene: true was gated on the
    // decision-log composer landing — this pass COLLAPSES prior-round verdicts while the
    // decision-log block is what PRESERVES the history through that collapse. The composer landed
    // in 0.8.2 (upsertDecisionLog + recordDecision), so this copy carries it.
    if (!simulate && config.commentHygiene !== true) return
    let ids
    if (simulate) {
      const mcFx = simulate.probes?.minimizedComments
      ids = mcFx?.[round] ?? []
    } else {
      const st = await prState('comments', round)
      ids = st && st.reviewCommentIds
      if (!Array.isArray(ids)) {
        log(`minimizeSupersededReviewComments round ${round}: scan failed, skipping`)
        return
      }
    }
    let index = 0
    for (const id of ids) {
      trace.push(`review-comment-minimized:${id}`)
      if (simulate) continue
      // The probe name carries the index, not the id (GraphQL node ids are not guaranteed label-safe);
      // pr-write.sh reads isMinimized first.
      await prWrite('minimize', 'minimize-' + index, round, ['--id', id])
      index += 1
    }
  }

  // Artifact-proof freshness floor — lazy: only resolved when Morgan actually declares
  // artifactProofs, so a run with no declared proof spends zero extra agent calls. Never throws
  // on a `gh` hiccup (mirrors reconcileMorganIssues): logs and falls through to the run stamp.
  const artifactFloorIso = async (round, endState) => {
    if (simulate) return simulate.probes?.artifactFloor
    const t = endState && endState.lastCommitDate
    if (t) return t
    log(`artifactFloorIso round ${round}: no last commit date from the pr-state probe, falling back to run stamp`)
    return stamp ? new Date(Number(stamp)).toISOString() : null
  }

  // Artifact-proof gate — the workflow re-derives the verdict from Morgan's OWN declared
  // proofs, never trusting her LGTM alone. No-op when artifactProofs is absent/empty — every
  // pre-existing flow is unchanged.
  const callMorganGuarded = async (prompt, opts, round) => {
    const windowStart = await reviewerWindowStart(round)
    let v
    try {
      v = await callAgent('morgan', prompt, opts, round)
    } catch (e) {
      // A thrown Morgan death is contained here and folded into the SAME null contract
      // the two review-died branches below already handle — Morgan is deliberately NOT routed
      // through callAgentSafe (see the header note near "COPIES-ALIGNED"): the flow suite's
      // null-Morgan case and simFixture's `if (m === null) return null` depend on `null` staying
      // the one death signal for this role.
      log(`callMorganGuarded round ${round}: Morgan threw (${e && e.message ? e.message : e}) — treating as death (null)`)
      v = null
    }
    // ONE pr-state probe per Morgan round serves the window end, the issue scan and the artifact floor.
    // Without a window start (its probe failed) it carries no `since`, so lastCommitDate still feeds
    // artifactFloorIso; flagReviewerWindowIssues skips on its own when windowStart is falsy (#85).
    const endState = simulate ? null : await prState('window-end', round, windowStart ? { since: windowStart } : {})
    await flagReviewerWindowIssues(windowStart, round, endState)
    if (v === null) return v
    const proofs = Array.isArray(v.artifactProofs) ? v.artifactProofs : []
    if (proofs.length === 0) return v
    const floorIso = await artifactFloorIso(round, endState)
    const blockers = staleArtifactBlockers(proofs, floorIso)
    if (blockers.length === 0) return v
    const merged = [...(v.items || [])]
    for (const b of blockers) {
      trace.push(`artifact-proof-rejected:${b.reason}`)
      const line = b.item || `Unverified run artifact (${b.reason}): stat the named artifact and cite path + mtime + size`
      if (!merged.some(i => normItem(i) === normItem(line))) merged.push(line)
    }
    log(`callMorganGuarded round ${round}: overturned verdict ${v.verdict} -> REQUIRED_CHANGES ` +
      `(${blockers.length} stale/absent artifact proof(s): ${blockers.map(b => b.reason).join(', ')})`)
    return { ...v, verdict: 'REQUIRED_CHANGES', items: merged }
  }

  // Regression guard — baseline SET-DIFF, not a grep/function-count check.
  const regressionGuardStep = baselineCmd
    ? `run the REGRESSION GUARD as a baseline SET-DIFF (no checkout/stash beyond what the command does):\n` +
      `  1) capture the ${baseBranch} baseline by running this exact command (it writes the baseline test log) — export WORKTREE="${wtPath}" and BASE_BRANCH="${baseBranch}" first:\n     ${baselineCmd}\n` +
      `  2) list the files the PR adds, which survive the baseline overlay: \`git -C "${wtPath}" diff --name-only --diff-filter=ACR origin/${baseBranch}...HEAD\`\n` +
      `  3) run the suite on HEAD via \`${testCmd}\` and collect its {failures, errors} by fully-qualified test NAME;\n` +
      `  4) DIFF the {failures, errors} SETS (HEAD minus baseline) by test name. ANY test name that fails or errors on HEAD but is NOT in the baseline log is a NEW regression => verdict REQUIRED_CHANGES (REGRESSION_DETECTED if a previously-passing test now fails).\n` +
      `  BRANCH-ONLY-FILES RULE (mandatory): \`git checkout origin/${baseBranch} -- .\` overlays baseline content but does NOT delete files the PR adds, so a brand-new test file ALSO executes during baseline capture and its failures land in the baseline log. A failing/erroring test whose SOURCE FILE appears in the step-2 added-files list is NEW, regardless of whether its name appears in the baseline log.\n` +
      `  A failure/error may be dismissed as 'pre-existing' ONLY if BOTH hold: its EXACT fully-qualified test name appears in the baseline log AND its source file is NOT in the step-2 added-files list — and you MUST cite both the baseline line and the added-files check. You MUST actually run both suites; do NOT grep test-function counts as a substitute. `
    : `run the unit suite via \`${testCmd}\` and treat ANY failing or erroring test as REQUIRED_CHANGES (no regression baseline configured; do NOT grep test-function counts as a substitute). `

  // Artifact-proof gate — lane-agnostic, shared by both Morgan prompts below (initial +
  // loop). Post-mortem (real incident): only a PREVIOUS-day report was on disk while the box claimed a
  // fresh re-run; a content-only check (the clause above) cannot catch a stale-but-matching
  // artifact. This clause makes freshness/existence itself the proof, machine-re-derived by
  // staleArtifactBlockers() — the workflow overturns an LGTM whose proofs do not hold.
  const artifactProofStep =
    `ARTIFACT-PROOF GATE (lane-agnostic): before ticking ANY acceptance box whose text claims a live ` +
    `or replayed run produced an artifact (report, export, render, log, file at a named path), verify ` +
    `the artifact YOURSELF — \`ls -l\` / \`stat\` the exact path — and confirm it EXISTS, is NON-EMPTY, ` +
    `and that its mtime is AFTER the PR's latest commit; an artifact from an earlier run is STALE ` +
    `evidence, not proof. Cite path + mtime + size in the posted proof; a grep whose output cannot be ` +
    `traced to a named, freshly stat-ed path is NOT proof. Return one \`artifactProofs\` entry per such ` +
    `ticked box ({item: the verbatim checklist line, path, exists, mtime ISO-8601 — MUST include an ` +
    `explicit UTC 'Z' or numeric timezone offset (e.g. \`date -u +%Y-%m-%dT%H:%M:%SZ\`); a bare ` +
    `timestamp without Z/offset is rejected, bytes}). Absent, ` +
    `empty or predating the latest commit ⇒ the box stays UNTICKED and its verbatim line goes into ` +
    `\`items\` ⇒ REQUIRED_CHANGES, never a tick. The workflow re-derives this from \`artifactProofs\` and ` +
    `will overturn an LGTM whose proofs do not hold. `

  // Worktree freshness probe — best-effort, read-only (fetch only, never checkout/reset/
  // rebase/pull). Surfaces to Morgan how far the frozen base has drifted from origin/<baseBranch>
  // so a local-vs-CI test-count mismatch reads as expected, not a regression. Degrades to null on
  // any failure (mirrors artifactFloorIso) — a `git`/agent hiccup can never crash the review.
  const worktreeBehindCount = async () => {
    if (simulate) return simulate.probes?.behindCount
    try {
      const res = await probe('git-rev-list-count',
        `cd "${wtPath}" && git fetch origin ${baseBranch} -q 2>/dev/null; git rev-list --count HEAD..origin/${baseBranch}`,
        { label: `worktree-behind-${pr}`, onFail: () => null })
      return res && res.json && Number.isFinite(res.json.count) ? res.json.count : null
    } catch (e) {
      log(`worktreeBehindCount: probe failed (${e.message}), skipping freshness note`)
      return null
    }
  }
  const behind = await worktreeBehindCount()
  const freshnessStep = worktreeFreshnessNote(behind, baseBranch)
  if (freshnessStep) {
    trace.push(`worktree-behind:${behind}`)
    log(`Worktree freshness: ${behind} commit(s) behind origin/${baseBranch} — warning injected into both Morgan prompts`)
  }

  // Pre-Morgan preflight gate (item 4) — runs before each Morgan call.
  // Returns true when checks pass; returns { status: 'preflight-stuck', ... } after 2 failures.
  let preflightCallCount = 0
  let preflightPromptPreview = null   // simulate-only: lets the flow tests assert the composed preflight prompt
  // Report-only forensics: logs what check-3 actually ran, never feeds pass/issues.
  const logTestCmdRun = (p) => {
    const ran = String(p?.testCommandRun ?? '').trim()
    if (!ran) {
      log('Preflight: no testCommandRun reported — check-3 drift undetectable')
      return
    }
    log(`Preflight check-3 command as run: ${ran}`)
    const head = String(testCmd).split(';')[0].trim()
    if (head && !ran.includes(head)) log(`WARNING: preflight check-3 drift — reported command does not contain the configured head "${head}"`)
  }
  const preflightPrompt = () => {
    const banPattern = canonicalStringBan.length > 0
      ? canonicalStringBan.map(s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')
      : null
    const hardRange = envSymlink === 'ignore' ? '2-3' : '1-3'
    const p = (
      // envNote is TRUSTED-OPERATOR input, injected unescaped ahead of the hard checks — this is
      // detection/documentation, never a control (see the const's own comment above). The note
      // outranks HARD check 3's own "opaque command" hardening below by wording and by position;
      // that widening of an existing trust assumption is accepted, not silently shipped.
      (envNote
        ? `ENVIRONMENT NOTE (from the Lead, authoritative — apply to every command below): ${envNote}\n`
        : '') +
      `Run pre-Morgan preflight checks on worktree "${wtPath}" and PR #${pr} ` +
      `(best-effort; aggregate results into pass/issues):\n` +
      `HARD checks (local, always enforced):\n` +
      (envSymlink === 'ignore'
        ? ''
        : envSymlink === 'forbidden'
          ? `1. test ! -e "${wtPath}/.env" — env file/symlink MUST be ABSENT (this project runs envless by contract)\n`
          : `1. test -L "${wtPath}/.env" — env symlink present\n`) +
      `2. git -C "${wtPath}" diff --cached --name-only | head -5 — no stray staged files\n` +
      `3. Unit suite still green. Run EXACTLY the configured test command below, ONCE, in ONE shell ` +
      `whose cwd is "${wtPath}". The command is OPAQUE to you: do NOT substitute, simplify, split, ` +
      `re-quote or improvise another runner — a bare \`pytest\` is NOT this command. Judge check 3 on ` +
      `its exit status only. Report in \`testCommandRun\` the command you actually ran, verbatim; ` +
      `if it is not the block below, check 3 FAILS.\n` +
      `--- BEGIN TEST COMMAND (run verbatim) ---\n` +
      `cd "${wtPath}"\n` +
      `${testCmd}\n` +
      `--- END TEST COMMAND ---\n` +
      `ADVISORY checks (require live GitHub/gh access):\n` +
      (banPattern
        ? `4. gh pr view ${pr}${prFlag} --json body -q .body | grep -iE "${banPattern}" — no banned strings in PR body (fail if match found)\n`
        : '') +
      `5. gh pr checks ${pr}${prFlag} --json name,state,link — no required-check FAILURES (PENDING is OK). ` +
      `For each check in FAILURE state: list \`check '<name>' is in FAILURE state\` in issues, take the run id ` +
      `from its link (the number after /actions/runs/), run \`gh run view <id> --log-failed\`, and report in ` +
      `failedChecks one entry { name, step, logTail } (step = the failing step name as printed by gh; logTail = ` +
      `the last ~40 lines of that output, verbatim). If the log command ITSELF fails (tls/x509/auth/no run id), ` +
      `keep the name in issues, leave logTail empty, and do NOT set pass:false for that tool failure.\n` +
      `Checks 4-5 use gh and require live GitHub/TLS access. If the gh command ITSELF fails ` +
      `(e.g. "tls: failed to verify certificate", "x509", "OSStatus", a network error, an auth error, ` +
      `or any non-zero exit that is NOT a check result), that is a TOOL failure, not a check failure: ` +
      `log it in issues as advisory and SKIP the check — do NOT set pass:false for it. ` +
      `Only set pass:false for checks 4-5 if the gh command SUCCEEDS and returns a real banned string (4) ` +
      `or a check name in FAILURE state (5).\n` +
      `Check 3 stays a HARD check: if the suite fails on import/module-not-found errors AND the install or ` +
      `setup.sh failed earlier with a sandbox TLS signature (see hint below), name the cause explicitly in ` +
      `issues[] (e.g. "sandbox TLS blocked the dependency install — deps missing") — pass:false is still ` +
      `correct, skipping the install would not install anything.\n` +
      `${SANDBOX_INSTALL_HINT}\n` +
      `Return { pass: bool, issues: string[], failedChecks } where pass=true if HARD checks ${hardRange} all pass AND no ADVISORY ` +
      `check (4-5) that actually ran found a positive result; an advisory check skipped due to a tool ` +
      `failure does NOT set pass:false. ` +
      `Also include testCommandRun as forensics only (see check 3) — it does not affect the check-3 verdict.`
    )
    if (simulate) preflightPromptPreview = p
    return p
  }
  // #132 — fold the probe's failedChecks data into issues (deterministic, string ops only).
  // guards:parser-begin
  const FAILED_LOG_TAIL_LINES = 40
  const foldFailedChecks = (pf) => {
    const base = Array.isArray(pf?.issues) ? pf.issues : []
    const fc = Array.isArray(pf?.failedChecks) ? pf.failedChecks : []
    const extra = []
    for (const c of fc) {
      if (!c || typeof c !== 'object') continue
      const tail = String(c.logTail || '').split('\n').slice(-FAILED_LOG_TAIL_LINES).join('\n')
      extra.push(`check '${c.name || '?'}' failing step '${c.step || '?'}'` + (tail ? ` — last failing log lines:\n${tail}` : ''))
    }
    return [...base, ...extra]
  }
  // guards:parser-end
  const runPreflight = async (currentRound) => {
    const pf = await callAgentSafe(
      'preflight',
      preflightPrompt(),
      { schema: PREFLIGHT, label: `preflight-${issue}-${pr}-${preflightCallCount}`, model: 'haiku' },
      preflightCallCount,
    )
    preflightCallCount++
    logTestCmdRun(pf)
    if (isAgentDeath(pf)) {
      return finish({ status: 'preflight-died', pr, issue, round: currentRound, trace, resumable: true })
    }
    if (pf?.pass !== false) return true

    // Preflight failed — ask Nick to fix mechanical issues, then retry once
    const foldedIssues = foldFailedChecks(pf)
    log(`Preflight failed (attempt ${preflightCallCount - 1}): ${foldedIssues.join(', ')}`)
    const nickFixPrompt = (
      `Pre-Morgan preflight failed on worktree "${wtPath}" (PR #${pr}). Fix these mechanical issues and push:\n` +
      `${foldedIssues.map(i => `- ${i}`).join('\n')}\n` +
      `${SANDBOX_INSTALL_HINT} ` +
      `Do NOT change any product code — fix only the listed mechanical issues; reinstalling deps is NOT ` +
      `product code and is allowed. If the install cannot succeed under the sandbox, stop and report it ` +
      `as blocked in your return rather than working around the sandbox — the second preflight will then ` +
      `fail and the workflow escalates for the Lead/human. If a listed issue's stated requirement is ` +
      `literally what this PR's diff changes (self-reference-preflight — the running pipeline is the ` +
      `DISPATCH-time snapshot, so it enforces pre-PR gate logic), do not mutate the worktree to satisfy ` +
      `it and do not revert the PR's own change; stop and report it as blocked in your return, so the ` +
      `second preflight fails and the workflow escalates for the Lead/human.`
    )
    if (simulate) preflightFixPromptPreview = nickFixPrompt
    const nickFix = await callAgentSafe(
      'nick',
      nickFixPrompt,
      { agentType: 'Nick', label: `nick-preflight-fix-${issue}-${pr}`, model: 'sonnet' },
      currentRound,
    )
    if (isAgentDeath(nickFix)) {
      return finish({ status: 'dev-died', pr, issue, round: currentRound, trace, resumable: true })
    }

    const pf2 = await callAgentSafe(
      'preflight',
      preflightPrompt(),
      { schema: PREFLIGHT, label: `preflight-${issue}-${pr}-${preflightCallCount}`, model: 'haiku' },
      preflightCallCount,
    )
    preflightCallCount++
    logTestCmdRun(pf2)
    if (isAgentDeath(pf2)) {
      return finish({ status: 'preflight-died', pr, issue, round: currentRound, trace, resumable: true })
    }
    if (pf2?.pass !== false) return true

    log(`Preflight still failing after retry — escalating as preflight-stuck`)
    return finish({ status: 'preflight-stuck', pr, issue, round: currentRound, issues: foldFailedChecks(pf2), trace })
  }

  let prevRoundItems = null
  let round = 0

  const decisionLog = []
  let prBodyPreview = null   // simulate-only: lets the flow tests assert the composed body
  let guardProbeResult = null   // simulate-only: T87b probes the REAL bodyWriteGuardOk (issue #87)
  let acceptanceSpliceProbe = null   // simulate.probes?.acceptanceSpliceProbe-only: T113 probes the REAL spliceAcceptanceBlock (issue #97)
  let planAmendRounds = 0   // #97 — budget counter for the plan-defect-persists escalation (S13)

  // Decision log — durable counterpart to the comment-collapse pass above. Best-effort, never
  // throws (mirrors minimizeSupersededReviewComments). Runs only AFTER callMorganGuarded has
  // returned, so no agent is live and the read-modify-write on the body cannot race Morgan's
  // box-ticking `gh pr edit --body`.
  const recordDecision = async (r, verdict, items) => {
    const n = Array.isArray(items) ? items.length : 0
    decisionLog.push(verdict === 'LGTM'
      ? `- round ${r} — LGTM`
      : `- round ${r} — ${verdict} (${n} blocker${n === 1 ? '' : 's'})`)
    if (simulate) {
      // T87b (issue #87) — additive lever, zero behavior change when absent (mirrors
      // simulate.probes?.artifactFloor/simulate.probes?.behindCount). Exercises the REAL production
      // bodyWriteGuardOk, never a hand-duplicated copy in the test file.
      if (simulate.probes?.recordDecisionGuardProbe) {
        const { preLen, newBody } = simulate.probes?.recordDecisionGuardProbe
        guardProbeResult = bodyWriteGuardOk(preLen, newBody)
      }
      if (simulate.probes?.prBody === undefined) return
      prBodyPreview = upsertDecisionLog(simulate.probes?.prBody, decisionLog)
      return
    }
    // issue #87 — the PR body content (routinely 5-30 KB) must NEVER transit through the model's own
    // chat reply. #85: read, splice, write, re-read, guard and restore run in templates/pr-write.sh
    // (op body-splice); the agent only copies a PROBE line, and the block text is the only content that
    // passes through the probe command.
    const res = await prWrite('body-splice', 'decision-log', r, ['--pr', pr, '--mode', 'decision-log', '--text', composeDecisionLogBlock(decisionLog)])
    if (!res) { log(`recordDecision round ${r}: sync failed (probe unavailable), skipping`); return }
    if (res.result === 'failed') log(`recordDecision round ${r}: ${res.reason || 'failed'}`)
  }

  // reviewParkedTerminal(v, round) (issue #228) — Morgan PROVED every remaining box but could not tick it
  // (`gh pr edit` denied by session permissions). Nothing here is a code defect, so dispatching
  // Nick only ends in `nick-no-op`. Park the run for the Lead instead: `verified-untickable`
  // (or `ready-pending-human` carrying `untickableItems` when human-gate boxes remain too).
  // Returns null (legacy path, byte-identical) unless EVERY non-human-gate item is proven
  // untickable. Never ticks anything itself (D4): the Lead re-verifies each proof and ticks.
  const reviewParkedTerminal = async (v, round) => {
    if (!v || v.verdict !== 'REQUIRED_CHANGES' || v.ciGreen === false) return null
    const { untickable, rest } = classifyUntickable(v.items, v.itemOwners, { checklistKind: maxPlanAmendRounds === 0 })
    if (untickable.length === 0) return null
    if (rest.some(i => !isHumanGate(i))) return null   // a real blocker remains → Nick loop
    trace.push(`verified-untickable:${round}`)
    log(`Verified-untickable: ${untickable.length} box(es) proven but not tickable (permissions)${rest.length > 0 ? ` + ${rest.length} human-gate` : ''} — parking for the Lead, no Nick round`)
    await updateStatus('Pending Tick')   // best-effort; logs + skips if the option is unconfigured
    if (rest.length === 0) {
      return finish({ status: 'verified-untickable', pr, issue, round, untickableItems: untickable, trace, decisionLog, resumable: true })
    }
    return finish({ status: 'ready-pending-human', pr, issue, round, humanGateItems: rest, untickableItems: untickable, trace, decisionLog, resumable: true })
  }

  // syncAcceptanceBlock (issue #97) — deterministic, FAIL-CLOSED sync of Sam's amended acceptance
  // checklist into the PR body after a plan-amendment round (S11). Same #87 doctrine as
  // recordDecision above (the PR body content never transits the model's own reply) and the SAME
  // single-shell-chain construction, embedding the REAL spliceAcceptanceBlock/bodyWriteGuardOk
  // source via .toString() — but splicing the ACCEPTANCE block instead of the decision log, and
  // NEVER appending: an absent marker pair (exit code 3) is reported as NO_MARKERS and returns
  // false, exactly like an empty checklist — this function never invents an acceptance block.
  const syncAcceptanceBlock = async (checklist, r) => {
    const list = String(checklist ?? '').trim()
    if (!list) { log(`syncAcceptanceBlock round ${r}: empty checklist — refusing to sync`); return false }
    if (simulate) {
      if (simulate.probes?.prBody === undefined) return simulate.probes?.acceptanceSync !== false
      const out = spliceAcceptanceBlock(simulate.probes?.prBody, list)
      if (out !== null) prBodyPreview = out
      return out !== null
    }
    // #85: the chain (read, splice, write, re-read, guard, restore) lives in templates/pr-write.sh; the
    // checklist never transits a model reply, the agent only copies a PROBE line. Never appends: absent
    // markers come back as failed/no-markers.
    const res = await prWrite('body-splice', 'acceptance-sync', r, ['--pr', pr, '--mode', 'acceptance', '--text', list])
    if (res && (res.result === 'written' || res.result === 'skipped')) { trace.push(`acceptance-synced:${r}`); return true }
    log(`syncAcceptanceBlock round ${r}: ${res ? (res.reason || res.result) : 'probe unavailable'}`)
    return false
  }

  // Offline probe lever (issue #97, T87b precedent) — when simulate.probes?.acceptanceSpliceProbe is set,
  // evaluate the REAL spliceAcceptanceBlock once against that fixture and expose the result on
  // the terminal payload, so the offline suite can prove the pure splice function's marker
  // selection/fail-closed behavior without hand-duplicating it in the test file.
  if (simulate?.probes?.acceptanceSpliceProbe) {
    const { body: probeBody, checklist: probeChecklist } = simulate.probes?.acceptanceSpliceProbe
    acceptanceSpliceProbe = spliceAcceptanceBlock(probeBody, probeChecklist)
  }

  // prSignature (issue #97) — captures a { sha, body } pair for the no-op gate below. `when` is
  // 'before'|'after'; `r` is the current review round. Widens the pre-#97 SHA-only comparison
  // (which falsely escalated `nick-no-op` on a fix that landed as a PR-body-only edit, no new
  // commit) to SHA-OR-body: escalate only when BOTH are unchanged. ONE real gh call per side,
  // embedded in ONE agent() Bash call, replying with a single "<sha> <12-char digest>" line —
  // the PR body itself never transits the model's reply (#87 doctrine): only a content-hash of
  // it does. On a throw / unparseable reply, fails OPEN with a sentinel unique per (when, round)
  // so before !== after — the run costs one extra re-review instead of a false auto:blocked.
  const prSignature = async (when, r) => {
    if (simulate) {
      // sha: unchanged expressions (same idiom the pre-#97 no-op gate used) — before is a plain
      // index, after looks ahead to r+1 with a round-scoped fallback so two absent defaults
      // still differ (a normal round must never fabricate a no-op).
      const shaFx = simulate.probes?.headSha
      const bodyFx = simulate.probes?.prBodySig
      const sha = when === 'before'
        ? (shaFx?.[r] ?? `sha-round-${r}`)
        : (shaFx?.[r + 1] ?? (shaFx?.[r] !== undefined ? shaFx[r] : `sha-round-${r}-post`))
      // body: SAME polarity, keyed off simulate.probes?.prBodySig — identical by default (no lever set)
      // so a plain SHA-only fixture (T23) still escalates exactly as before #97; a fixture that
      // sets prBodySig[r] and prBodySig[r+1] to different strings models a body-only fix.
      const body = when === 'before'
        ? (bodyFx?.[r] ?? `body-round-${r}`)
        : (bodyFx?.[r + 1] ?? bodyFx?.[r] ?? `body-round-${r}`)
      return { sha, body }
    }
    const st = await prState(`sig-${when}`, r)
    if (!st || !st.headRefOid || !st.bodyDigest) {
      log(`prSignature ${when} round ${r}: pr-state probe unavailable — failing open`)
      return { sha: `probe-fail-${when}-${r}`, body: `probe-fail-${when}-${r}` }
    }
    return { sha: st.headRefOid, body: st.bodyDigest }
  }

  // Preflight before initial Morgan call
  const pf0 = await runPreflight(round)
  if (pf0 !== true) return pf0

  // PR comment hygiene — minimize any prior-round verdicts/push-notes left over from a
  // resumed run (entryStage='review' resume) before Morgan posts a fresh one. No-op on a fresh
  // run (nothing marked yet).
  await minimizeSupersededReviewComments(0)

  let v = await callMorganGuarded(
    `Work in the shared worktree "${wtPath}". Review PR #${pr}.\n\n` +
      `${planBlock}\n\n` +
      `${MORGAN_PRODUCT_DIRECTION}` +
      `Gate on the acceptance checklist FROM THAT PLAN, review against ${conventionsRule}, ` +
      `${regressionGuardStep}` +
      `For asset/render/human-facing lanes, BEFORE any verdict, execute the real-case live run yourself (the exact command the plan names, deps included) and machine-verify the output contract from the plan (e.g. the exact pixel/asset dimensions and named visual elements the plan calls for, screenshot non-empty, named fields written). Units mock the other side, so seam errors pass with the mock; only a taste judgment then remains for the human-gate. ` +
      `${artifactProofStep}` +
      `${freshnessStep}` +
      `${subIssuesUncovered.length > 0
        ? `Note (lgtmgate#193): this run's dev phase found ${subIssuesUncovered.length} open sub-issue(s) of #${issue} not covered by this bundle — the PR's first line intentionally does NOT close #${issue}; do not treat #${issue}/the epic as fully resolved in your verdict. `
        : ''}` +
      `Confirm CI is green via the GitHub checks ${ciChecks.join(' + ')} (gh pr checks ${pr}${prFlag}), ` +
      `then POST your verdict (LGTM | REQUIRED_CHANGES | REGRESSION_DETECTED) as a comment on PR #${pr}. Prefix that posted comment EXACTLY with the pipeline-review-round marker \`${reviewVerdictMarker}\` as its own first line${reviewShaRule} (hidden HTML marker; do NOT let it leak into \`items\`). ` +
      `For each remaining unticked acceptance box, put in \`items\` the **verbatim checklist line** it blocks on (copy the box text exactly — do NOT paraphrase — so a persistent blocker reads identically across rounds). Any box whose line contains the tag \`[human-gate]\` is a **human-only** item: you cannot verify it and MUST NOT tick it or ask Nick to fix it — copy its line verbatim into \`items\` (tag preserved) and treat it as a human gate, not a code defect. Emit \`REQUIRED_CHANGES\` whenever any box is unticked (human-gate or not). ` +
      `For each item in \`items\`, ALSO classify it in \`itemOwners\` ({item, itemOwner, proof}): 'code-defect' is the DEFAULT whenever you are uncertain — a plan owner ('plan-defect'|'checklist-wording-defect') REQUIRES a concrete \`proof\` quoting the exact contradiction between the plan/checklist and reality, and NEVER excuses unfinished code. If a box's verification PASSED but ticking it (\`gh pr edit\`) is denied by permissions, do NOT retry, do NOT work around the denial and do NOT post "Ready to merge": leave the box \`- [ ]\`, copy its verbatim line into \`items\`, and classify it in \`itemOwners\` as 'proven-untickable' with \`proof\` = the command you ran and its verbatim output. ${UNTICKABLE_LINE_RULE}${ACCEPTANCE_PRESENCE_RULE}A box whose verification failed or was not run stays 'code-defect'. A [human-gate] box is NEVER 'proven-untickable'.`,
    { agentType: 'Morgan', phase: 'Review', schema: MORGAN, label: `morgan-pr-${issue}-${pr}-r${round}`, model: morganModel },
    round,
  )

  // Null guard (item 1) — Morgan agent death on initial call
  if (v === null) {
    log('Morgan died (null result) — run is resumable via resumeFromRunId (same-args crash-retry only)')
    return finish({ status: 'review-died', pr, issue, round: 0, trace, resumable: true })
  }

  await recordDecision(round, v.verdict, v.items)

  // Proven-but-untickable terminal outcome (issue #228) — BEFORE the human-gate branch and gate().
  const parked0 = await reviewParkedTerminal(v, round)
  if (parked0) return parked0

  // Human-only terminal outcome: the only remaining blockers are human-gate
  // boxes Morgan cannot verify → stop cleanly, surface them to the Lead. Resumable:
  // human runs the live test, posts approval, ticks the box, Lead re-launches review.
  if (v.verdict === 'REQUIRED_CHANGES' && allHumanGate(v.items)) {
    log(`Ready pending human: only human-gate items remain (${v.items.length})`)
    await updateStatus('Pending Human')   // best-effort; no-ops if the option is unconfigured
    return finish({ status: 'ready-pending-human', pr, issue, round, humanGateItems: v.items, trace, decisionLog, resumable: true })
  }

  while (v.verdict !== 'LGTM' && round < 3) {
    if (gate('review', v.verdict)) {
      return finish({ status: 'needs-revision', round, items: v.items, pr, issue, trace })
    }
    prevRoundItems = v.items || []
    round++
    log(`Round ${round}: ${v.verdict} (${(v.items || []).length} items)`)

    // #97 — plan/code blocker routing, computed from the CURRENT verdict BEFORE Nick is ever
    // dispatched this round. Off-path (no itemOwners at all) leaves planRoutes empty and this
    // whole block a no-op: nickItems stays v.items and planRouted stays false, so the prompt and
    // no-op gate below are byte-identical to before #97.
    const { planRoutes, codeItems } = classifyBlockers(v.items, v.itemOwners)
    let nickItems = v.items || []
    let planRouted = false
    if (planRoutes.length > 0 && maxPlanAmendRounds === 0) {
      // Shadow mode (the shipped default) — classify + trace, route NOTHING. The historical
      // all-code-defect path stays bit-for-bit unchanged; this is observability only.
      trace.push(`plan-route-shadow:${round}`)
      log(`Round ${round}: ${planRoutes.length} item(s) classified as plan defect(s) — shadow mode (maxPlanAmendRounds=0), routing all ${nickItems.length} item(s) to Nick as before`)
    } else if (planRoutes.length > 0) {
      planAmendRounds++
      trace.push(`plan-amend-round:${round}`)
      log(`Round ${round}: routing ${planRoutes.length} plan-defect item(s) to Sam for a plan amendment (amend round ${planAmendRounds}/${maxPlanAmendRounds})`)
      const samAmend = await callAgentSafe(
        'sam',
        samScoutPrompt({ reviewFixBlock: composeReviewFixBlock(planRoutes) }),
        { agentType: scoutAgent, phase: 'Plan', schema: SAM, label: `scout-amend-${issue}-r${round}`, model: scoutModel },
        round,
      )
      if (isAgentDeath(samAmend)) {
        return finish({ status: 'plan-died', issue, planPath, trace, resumable: true })
      }
      if (samAmend.decision === 'NO-GO') {
        log(`Sam (plan amendment): NO-GO — ${samAmend.rationale || 'see report'}`)
        await updateStatus('Blocked')
        return finish({ status: 'no-go', reason: samAmend.rationale, plan: samAmend.plan, trace })
      }
      samPlan = samAmend.plan
      refreshPlanBlock()
      const acceptanceSynced = await syncAcceptanceBlock(samAmend.acceptanceChecklist, round)
      if (!acceptanceSynced) {
        await updateStatus('Blocked')
        return finish({ status: 'escalate', reason: 'acceptance-sync-failed', pr, issue, round, trace })
      }
      nickItems = codeItems
      planRouted = true
    }

    // #97 review fix — dispatchNick must stay true on the off-path (planRouted === false), even
    // when nickItems is empty (MORGAN.items is optional; REQUIRED_CHANGES with no items has never
    // meant "skip Nick" — Nick's fix prompt reads the review comment, not `items`). The skip is
    // only valid when something was actually routed to the plan amendment above.
    const dispatchNick = !planRouted || nickItems.length > 0
    if (!dispatchNick) {
      // Every remaining blocker was routed to the plan amendment above — the no-op gate's own
      // premise ("we asked Nick for a fix") no longer holds, so skip both Nick and the gate.
      trace.push(`nick-skipped-plan-only:${round}`)
      log(`Round ${round}: every remaining blocker routed to the plan amendment — skipping Nick and the no-op gate this round`)
    } else {
      // --- no-op gate (backport plugin 44c3a02/2648079; widened to SHA+body, issue #97) ---
      const before = await prSignature('before', round)
      const nickFixRound = await callAgentSafe(
        'nick',
        `Work in the shared worktree "${wtPath}". Read Morgan's review on PR #${pr} (gh pr view ${pr}${prFlag} --comments), address every REQUIRED_CHANGES item${planRouted ? ' listed below (the other blockers on this PR are handled by a plan amendment — do NOT touch them)' : ''} while staying faithful to the plan below, re-run the green bar (\`${buildCmd}\` + \`${testCmd}\`, format modified files via \`${formatCmd}\`), and push. When deleting repo-tracked files, use \`git rm <file>\` instead of bare \`rm\` — bare rm is sandbox-denied and burns permission rounds. ${SANDBOX_INSTALL_HINT} After pushing, post a ONE-LINE push-note comment on PR #${pr} (only there, not on the issue) prefixed EXACTLY with the pipeline-review-round marker \`${reviewMarker}\` as its own first line, summarizing the change you just made.${planRouted ? `\n\nItems to address:\n${nickItems.map(i => `- ${i}`).join('\n')}` : ''}\n\n${planBlock}`,
        { agentType: 'Nick', phase: 'Review', label: `nick-pr-${issue}-${pr}`, model: 'sonnet' },
        round,
      )
      if (isAgentDeath(nickFixRound)) {
        return finish({ status: 'dev-died', pr, issue, round, trace, resumable: true })
      }
      const after = await prSignature('after', round)
      if (after.sha === before.sha && after.body === before.body) {
        log(`Round ${round}: Nick no-op — SHA+body unchanged (${after.sha}). Escalating without re-review.`)
        await updateStatus('Blocked')
        return finish({ status: 'escalate', reason: 'nick-no-op', round, pr, issue, trace, sha: after.sha })
      }
      if (after.sha === before.sha) {
        trace.push(`nick-body-only-fix:${round}`)
        log(`Round ${round}: Nick fixed via PR body only (SHA unchanged: ${after.sha}) — continuing to re-review`)
      }
      // --- fin no-op gate ---
    }

    // Preflight before loop Morgan call
    const pfN = await runPreflight(round)
    if (pfN !== true) return pfN

    // PR comment hygiene — runs AFTER Nick's round-N push-note (posted above) so it too
    // is minimized, and BEFORE Morgan posts her new verdict so only the fresh one stays visible.
    await minimizeSupersededReviewComments(round)

    v = await callMorganGuarded(
      `Work in the shared worktree "${wtPath}". Re-review PR #${pr} after Nick's fixes, against the SAME plan and acceptance checklist below. ` +
        `${MORGAN_PRODUCT_DIRECTION}` +
        `Re-run the regression guard the same way: ${regressionGuardStep}` +
        `For asset/render/human-facing lanes, BEFORE any verdict, execute the real-case live run yourself (the exact command the plan names, deps included) and machine-verify the output contract from the plan (e.g. the exact pixel/asset dimensions and named visual elements the plan calls for, screenshot non-empty, named fields written). Units mock the other side, so seam errors pass with the mock; only a taste judgment then remains for the human-gate. ` +
        `${artifactProofStep}` +
        `${freshnessStep}` +
        `Then post the new verdict (LGTM | REQUIRED_CHANGES | REGRESSION_DETECTED) as a comment on the PR. Prefix that posted comment EXACTLY with the pipeline-review-round marker \`${reviewVerdictMarker}\` as its own first line${reviewShaRule} (hidden HTML marker; do NOT let it leak into \`items\`). ` +
        `For each remaining unticked acceptance box, put in \`items\` the **verbatim checklist line** it blocks on (copy the box text exactly — do NOT paraphrase — so a persistent blocker reads identically across rounds). Any box whose line contains the tag \`[human-gate]\` is a **human-only** item: you cannot verify it and MUST NOT tick it or ask Nick to fix it — copy its line verbatim into \`items\` (tag preserved) and treat it as a human gate, not a code defect. Emit \`REQUIRED_CHANGES\` whenever any box is unticked (human-gate or not). ` +
        `For each item in \`items\`, ALSO classify it in \`itemOwners\` ({item, itemOwner, proof}): 'code-defect' is the DEFAULT whenever you are uncertain — a plan owner ('plan-defect'|'checklist-wording-defect') REQUIRES a concrete \`proof\` quoting the exact contradiction between the plan/checklist and reality, and NEVER excuses unfinished code. If a box's verification PASSED but ticking it (\`gh pr edit\`) is denied by permissions, do NOT retry, do NOT work around the denial and do NOT post "Ready to merge": leave the box \`- [ ]\`, copy its verbatim line into \`items\`, and classify it in \`itemOwners\` as 'proven-untickable' with \`proof\` = the command you ran and its verbatim output. ${UNTICKABLE_LINE_RULE}${ACCEPTANCE_PRESENCE_RULE}A box whose verification failed or was not run stays 'code-defect'. A [human-gate] box is NEVER 'proven-untickable'.\n\n${planBlock}`,
      { agentType: 'Morgan', phase: 'Review', schema: MORGAN, label: `morgan-pr-${issue}-${pr}-r${round}`, model: morganModel },
      round,
    )

    // Null guard (item 1) — Morgan agent death in loop
    if (v === null) {
      log(`Morgan died (null result) on round ${round} — run is resumable via resumeFromRunId (same-args crash-retry only)`)
      return finish({ status: 'review-died', pr, issue, round, trace, resumable: true })
    }

    await recordDecision(round, v.verdict, v.items)

    // Proven-but-untickable terminal outcome (issue #228) — BEFORE the human-gate branch.
    const parkedN = await reviewParkedTerminal(v, round)
    if (parkedN) return parkedN

    // Human-only terminal outcome: the only remaining blockers are human-gate
    // boxes Morgan cannot verify → stop cleanly, surface them to the Lead. Resumable:
    // human runs the live test, posts approval, ticks the box, Lead re-launches review.
    if (v.verdict === 'REQUIRED_CHANGES' && allHumanGate(v.items)) {
      log(`Ready pending human: only human-gate items remain (${v.items.length})`)
      await updateStatus('Pending Human')   // best-effort; no-ops if the option is unconfigured
      return finish({ status: 'ready-pending-human', pr, issue, round, humanGateItems: v.items, trace, decisionLog, resumable: true })
    }

    // Plan-defect-persists escalation (issue #97, S13) — evaluated BEFORE same-blocker-twice, and
    // ONLY when maxPlanAmendRounds > 0 (the shipped default 0 leaves same-blocker-twice bit-for-
    // bit unchanged). Budget exhausted (planAmendRounds >= maxPlanAmendRounds) AND the FRESH
    // verdict still classifies at least one item as a plan defect => the amendment did not fix
    // the plan; escalate NAMED as a plan defect, never mislabelled as Nick failing twice.
    if (maxPlanAmendRounds > 0 && planAmendRounds >= maxPlanAmendRounds && v.verdict === 'REQUIRED_CHANGES') {
      const { planRoutes: freshPlanRoutes } = classifyBlockers(v.items, v.itemOwners)
      if (freshPlanRoutes.length > 0) {
        log(`Plan-defect-persists: round ${round} still classifies ${freshPlanRoutes.length} item(s) as plan defect(s) after ${planAmendRounds} amendment round(s) — escalating`)
        await updateStatus('Blocked')
        return finish({
          status: 'escalate', reason: 'plan-defect-persists', pr, issue, round,
          items: freshPlanRoutes.map(r => r.item), trace,
        })
      }
    }

    // Same-blocker-twice escalation (item 5)
    if (round > 0 && v.verdict === 'REQUIRED_CHANGES' && isSubset(prevRoundItems, v.items)) {
      log(`Same-blocker-twice: round ${round} items ⊇ round ${round - 1} items — escalating`)
      await updateStatus('Blocked')
      return finish({ status: 'escalate', reason: 'same-blocker-twice', pr, issue, round, items: v.items, trace })
    }
  }

  // Commit hygiene — squash the branch to a few LOGICAL commits BEFORE handoff, because
  // some projects merge with merge commits and every agent round-fix otherwise lands verbatim on
  // the base branch. Best-effort: every guard is a silent skip; nothing here may throw or block
  // the PR-Ready handoff.
  // Placement (mtime-floor coupling): a squash rewrites the branch head, moving the freshness
  // floor staleArtifactBlockers compares against (artifactFloorIso). Safe here because both
  // ready-pending-human returns are upstream of this call site, so the squash fires ONLY on the
  // terminal status:'ready' path; and a post-'ready' entryStage='review' resume is safe because
  // callMorganGuarded consumes v.artifactProofs from the CURRENT round's verdict — proofs are
  // minted after the new head, and one predating it is the defect the gate exists to catch.
  const squashBeforeHandoff = async () => {
    if (!squashEnabled) return
    let headRefName, commitCount
    if (simulate) {
      if (simulate.probes?.squashCommits === undefined) return
      commitCount = simulate.probes?.squashCommits
      const hrFx = simulate.probes?.headRefName
      headRefName = hrFx ?? `${expectedBranchName}`
    } else {
      const st = await prState('squash', round)
      if (!st || typeof st.commitCount !== 'number') { log('squashBeforeHandoff: scan failed, skipping'); return }
      headRefName = st.headRefName            // REUSE the provided field — never rebuild it
      commitCount = st.commitCount
    }
    if (!headRefName || commitCount <= squashMaxCommits) return
    trace.push(`commit-squashed:${pr}`)
    if (simulate) return
    await callAgentSafe(
      'nick',
      `Pre-handoff commit-hygiene squash for PR #${pr} (issue #${issue}) — this repo merges with merge commits, so a branch with more than ${squashMaxCommits} commits lands ALL of them verbatim on ${baseBranch}. Squash it to 2-3 LOGICAL commits before handoff:\n` +
      `1. cd "${wtPath}"; git fetch origin ${baseBranch}.\n` +
      `2. ABORT (do nothing, report skipped) if ANY of: \`git rev-parse --abbrev-ref HEAD\` != \`${headRefName}\`; \`git status --porcelain\` is non-empty; \`git rev-list --merges --count $(git merge-base HEAD origin/${baseBranch})..HEAD\` != 0.\n` +
      `3. OLD=$(git rev-parse HEAD); MB=$(git merge-base HEAD origin/${baseBranch}).\n` +
      `4. git reset --soft "$MB", then create 2-3 Conventional-Commits commits (${conventionsRule}) splitting the work LOGICALLY — never one commit per review round.\n` +
      `5. Tree-identity proof (mandatory): \`git diff "$OLD" HEAD --stat\` must print NOTHING. If it prints anything: \`git reset --hard "$OLD"\`, push nothing, report squashed:false with the diff.\n` +
      `6. git push --force-with-lease origin "${headRefName}".\n` +
      `7. Post ONE comment on PR #${pr}, prefixed with \`${reviewVerdictMarker}\` as its own first line, replacing \`<HEAD_SHA>\` with the NEW head (\`git rev-parse HEAD\` after the push, full 40-hex): it re-attests the review onto the squashed head. State the old and new head SHAs and that \`git diff <old> <new>\` is empty (the LGTM still holds).\n` +
      `Never use bare --force. Never push to ${baseBranch}/main. Never merge this PR yourself — merging is an external gesture handled outside the pipeline. Never throw — the handoff must complete either way.`,
      { agentType: 'Nick', label: `nick-squash-${issue}-${pr}`, model: 'sonnet' },
      round,
    )
  }
  // Mergeability recheck (#162, absorbs #91/#119) — GitHub's live mergeable state can drift to
  // CONFLICTING between Morgan's plan/diff-based LGTM and this terminal handoff (e.g. a sibling PR
  // merged mid-flight), which would otherwise report a false-positive `ready`. Fail-open on any
  // ambiguity: only an exact `mergeable === 'CONFLICTING'` escalates — `MERGEABLE`, `UNKNOWN` (GitHub
  // still computing, not a conflict), and a `null` (tool-failure) result all fall through unchanged.
  const checkMergeState = async () => {
    if (simulate) return simulate.probes?.mergeState
    const st = await prState('merge', round)
    return (st && typeof st.mergeable === 'string') ? { mergeable: st.mergeable, mergeStateStatus: st.mergeStateStatus } : null
  }
  if (v.verdict === 'LGTM') {
    const mergeState = await checkMergeState()
    if (mergeState?.mergeable === 'CONFLICTING') {
      trace.push(`mergeable-conflicting:${mergeState.mergeStateStatus || 'DIRTY'}`)
      log(`Mergeability recheck: PR #${pr} reports mergeable=CONFLICTING (mergeStateStatus=${mergeState.mergeStateStatus}) despite LGTM — escalating instead of a false-positive ready (#91/#119)`)
      await updateStatus('Blocked')
      return finish({ status: 'escalate', reason: 'mergeable-conflicting', pr, issue, round, mergeStateStatus: mergeState.mergeStateStatus || null, trace, decisionLog })
    }
    await squashBeforeHandoff()
  }

  await updateStatus(v.verdict === 'LGTM' ? 'PR Ready' : 'Blocked')
  return finish({
    status: v.verdict === 'LGTM' ? 'ready' : 'escalate',
    pr,
    branch: nick?.branch ?? '<unavailable>',
    rounds: round,
    finalVerdict: v.verdict,
    issue,
    worktreeBehind: behind ?? null,
    planStaleFiles,
    planTargetsChecked,
    subIssuesUncovered,
    trace,
    decisionLog,
    prBodyPreview,
    guardProbeResult,
    acceptanceSpliceProbe,
    preflightPromptPreview,
    preflightFixPromptPreview,
  })
}
