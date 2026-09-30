---
description: Deliver a change end-to-end through the Mia -> Sam -> Nick -> Morgan pipeline (creates the shared worktree, drives deliver-pipeline.js).
argument-hint: "[issue] [brief]"
allowed-tools: Bash, Read, Workflow, TaskCreate, TaskUpdate, TaskGet, TaskList, AskUserQuestion, SendMessage, TeamCreate, Agent
---

# /lgtmgate:deliver — Runbook (Lead)

You are the **Lead**. You deliver a change end-to-end through the **Mia -> Sam -> Nick -> Morgan** pipeline. The workflow (plugin component `lgtmgate:deliver-pipeline`, or the local copy `.claude/workflows/deliver-pipeline.js` as fallback — exact resolution in the "## 1. Read the config" section below) orchestrates the agents; you prepare the shared worktree, launch the workflow, and handle the statuses it returns to you.

**Args**: `$ARGUMENTS` = `<issue> "<brief>"` (GitHub issue number + short description). If either is missing, ask for it.

**Bash: absolute path, 1 command/call, no `cd`/`&&`/`|`.**

## 1. Read the config
- Read `.claude/pipeline.config.json` (project root). Missing → stop: `Pipeline not configured. Run /lgtmgate:init first.`
- Keep the JSON object in memory: pass it as-is to the workflow (`config`).
- Resolve which pipeline to launch (two branches, never a bare name):
  - The `lgtmgate` plugin (>=0.8.0) provides the **namespaced** workflow component
    `lgtmgate:deliver-pipeline` (plugin's `workflows/` directory, default
    resolution). If this plugin is installed and up to date, that's the target.
  - Otherwise (not-yet-migrated project, or a plugin older than 0.8.0 without the component) and
    `.claude/workflows/deliver-pipeline.js` still exists in THIS project, use this explicit
    local copy — the project then also keeps its own copied suite
    (`.claude/workflows/test-deliver-pipeline.js`), so it really is ITS copy that must
    run, never the plugin's component.
  - Neither one -> stop: `Pipeline not found. Run /lgtmgate:init first.`

## 2. Check the worktreeRoot
- Resolve the worktreeRoot BEFORE checking it (legacy#61 — precedence, the workflow sandbox has no filesystem access so YOU are the one reading it): `$LGTMGATE_WORKTREE_ROOT` (env) > `.claude/pipeline.config.local.json:worktreeRoot` (if this file exists — absent = normal case, don't treat it as an error) > `config.worktreeRoot` (versioned default).
- The RESOLVED worktreeRoot must be mounted/accessible. Check it (e.g. `test -d "<resolved worktreeRoot>"` or that the parent volume is mounted). Inaccessible → stop and report to the user (e.g. external SSD not mounted).

## 3. Create the shared worktree (frozen from the base branch)
- `git fetch origin` then make sure the base branch (`config.baseBranch`) is up to date.
- Slug: **`issue-<N>`** (fixed). Nick commits on the worktree's branch (he no longer recomputes it) — keep a predictable name aligned with GH tracking. (friction F2)
- `WT="<worktreeRoot>/<slug>"`; branch `<config.branchPrefix><slug>`.
- Create it (1 command):
  ```bash
  git worktree add "<WT>" -b <branchPrefix><slug> <baseBranch>
  ```
- Check `git worktree list` < 60s afterward (mitigation for anthropics/claude-code#39886). Failure → fix before launching the workflow.
- **Alternate base** (feature stacked on a not-yet-merged branch, or dogfood): override `config.baseBranch` to that branch FOR THIS RUN (in the config object passed to the workflow) AND create the worktree from it. Worktree + PR target + regression guard then all point to the right base. Check that it triggers CI (`on.pull_request.branches`); otherwise `ciChecks: []` (Morgan validates on the local green bar). (friction F3)

## 4. Launch the workflow
**Launch in a clean turn (anthropics/claude-code#96640).** When `Workflow` is not the first tool call of a
turn started by a typed message, the harness relays that message to every `agent()` as an overriding user
request, and small-model agents run it instead of their task. So never call `Workflow` after steps 1-3 in
the same turn:
1. End the turn that ran steps 1-3 with one trivial background command (`run_in_background: true`,
   e.g. `true`) and nothing after it.
2. In the turn opened by its completion notification, `Workflow` is the first and only tool call.

Same `args` in both cases — only the TARGET changes, per the step 1 resolution:
```
args = {
  issue:  <N>,
  brief:  "<brief>",
  wtPath: "<WT>",
  mode:   "semi",
  pmReview: <true if the issue's pm_review checkbox is checked, false otherwise>,
  config: <the full .claude/pipeline.config.json object>,
  configLocal: <parsed content of .claude/pipeline.config.local.json, or {} if absent — the workflow sandbox does not read files (legacy#61), so it's the Lead who reads and passes it through>,
  planAudit: <optional — true to force adversarial plan audit on THIS run; absent -> config.planAudit>,
  maxAuditRounds: <optional — bound on the auditor <-> scout loop, default 2, HARD CEILING at 2: beyond that, throw unless maxAuditRoundsOverrideReason is provided>,
  maxAuditRoundsOverrideReason: <mandatory if maxAuditRounds > 2 — names the RISK CLASS that justifies the extra round(s), never a silent overrun>,
  architectureDecisionApproved: <optional — attests that the architecture-only pass (design-step trigger) already happened and was approved, exempts this launch from proceedThrough:"plan">
}
```
- **Resolved plugin component** -> launch by the **namespaced** name `lgtmgate:deliver-pipeline` (never the bare name `deliver-pipeline`, which a `--plugin-dir` or another project can shadow — claude-agent-pipeline#54).
- **Resolved not-yet-migrated local copy** -> launch explicitly with `Workflow({ scriptPath: "<repo>/.claude/workflows/deliver-pipeline.js", args })` — never by name, bare or namespaced: this project's copied test suite still validates THIS copy, not the plugin's component.
> `mode: "semi"` = checkpoints at milestones (plan ready, review requesting changes). `auto` runs everything through, `manual` stops at every step. Agents do NOT have the Workflow tool — only the Lead drives it.
> **Iteration machinery**: if you patch `.claude/workflows/deliver-pipeline.js` mid-session, relaunch the workflow via `scriptPath: "<abs path>"` (fresh read from disk) and NOT `name:` (resolution cached on first use → would replay the old version). (friction F9)
> **Test suite**: the same staleness applies INSIDE the flow suite — `test-deliver-pipeline.js` also resolves the pipeline under test via the registry. To validate a branch, pass `args: { fpScriptPath: "<worktree>/.claude/workflows/deliver-pipeline.js" }`; by `name:` the suite silently tests the base branch's copy instead (real incident observed: two cases reported as failing against a pipeline that simply didn't have the gate).

## 5. Handle the returned status
The workflow returns an object `{ status, ... }`. Depending on `status`:

| status | Meaning | Lead action |
|--------|------|-------------|
| `plan-ready` | Sam posted his plan (GO), semi checkpoint | Update the user (plan + issue). On green light: relaunch the workflow with `entryStage:"dev"` + `proceedThrough:"dev"` (or `"review"`). |
| `dev-done` | Nick opened the PR, checkpoint | Update (PR URL). On green light: relaunch with `entryStage:"review"` + `prNumber:<PR>`. |
| `needs-revision` | Morgan requested changes (`items`) | Report the blockers. On green light: relaunch with `entryStage:"review"` + `prNumber` + `proceedThrough:"review"` (Nick fixes, Morgan re-reviews). |
| `verified-untickable` | Morgan proved every box but couldn't check them (permissions); `untickableItems[]` = `{item, proof}` per box (not a code defect) | Never dispatch Nick. Re-run each `proof` carried by the payload (quick), tick by hand (`gh pr edit <pr> --body ...`) only the boxes whose proof passes, then relaunch with `entryStage:"review"` + `prNumber:<pr>` (Morgan no longer sees an open box, LGTM, `ready`). A `ready-pending-human` payload can also carry `untickableItems[]`: same handling for those; `[human-gate]` boxes stay human-only, never checked by you. |
| `no-go` | Sam blocked (`reason`) | Relay the blocker to the user. Do not force it. |
| `escalate` | 3 rounds without LGTM (`finalVerdict`), or `reason:"plan-not-sound"`/`"plan-audit-malformed"` (plan audit, if `planAudit` is active) | Escalate to the user: merge as-is + follow-up, or continue. A `plan-not-sound` escalate carries `auditTrace`/`roundOneAboveTarget`/`blockingSeries` — read them BEFORE deciding (never raise `maxAuditRounds` further without an explicit risk-class reason; it's a routing event, not a signal to loop again). A `reason:"mergeable-conflicting"` escalate (legacy#170): check the live state (`gh pr view <pr> --json mergeable,mergeStateStatus`); if you decide to let Nick reconcile rather than handle it as-is, relaunch with `entryStage:"dev"` + `prNumber:<pr>` + `resumeReason:"mergeable-conflicting"` (lgtmgate#183) — its prompt will then explicitly carry the resume reason instead of letting it wrongly conclude "already done". |
| `design-step-required` | The design-step trigger fired (Theo: >=2 of {persistent state, auth/security, deployment config}, or an immature vendor API) and no architecture decision has been approved yet | Relaunch either with `proceedThrough:"plan"` + a brief scoped to the architecture one-pager alone (stops at `plan-ready` for your validation), or with `architectureDecisionApproved:true` if that pass already happened. |
| `ready` | LGTM, PR ready to merge | Update (PR + branch). See §6. |
| `diagnose-died` / `plan-died` / `plan-check-died` / `plan-audit-died` / `dev-died` / `preflight-died` | An agent died (error or empty response) on this step after retry; `resumable:true` | Diagnose the cause if possible, then relaunch the workflow with the **same `config`/`wtPath`** via `resumeFromRunId` (see §Supervision) — never relaunch identically in a loop without understanding why. |
| `preflight-stuck` | 2 preflight failures, run escalated | First check whether the failing requirement is literally what the PR's diff changes (`self-reference-preflight`, issue legacy#83); if so it's a known false-positive — check the branch state by hand and do NOT ask Nick to satisfy the stale check. To relaunch against the branch's current gate logic, launch a **NEW** run via `Workflow({ scriptPath: "<worktree>/workflows/deliver-pipeline.js", ... })` (fresh read from disk), **never** a plain `resumeFromRunId` (it replays the original run's cached inputs). |

Always relaunch the workflow with the **same `config` and `wtPath`**. Never re-spawn a step that already finished without `entryStage`.
Every relaunch or resume (green light, `resumeFromRunId`) follows the §4 clean-turn rule: `Workflow` is the
first tool call of its turn. If you need to check anything first (`gh pr view`, `git log`), do it, end the
turn with a trivial background command, and relaunch from the notification turn.

### Supervising in-flight runs
Before considering the turn done (semi checkpoint, resuming after a pause, or before launching a
new one): if a run persists as unfinished (`.pipeline/<issue>.json`, status neither
resolved `ready`/`no-go`/`escalate`), do a check-in pass rather than silently abandoning it —
- **Alive** (task in progress, making progress) -> leave it alone.
- **Dead or `review-died`/`resumable`** -> resume via `resumeFromRunId` + persisted args, **bounded**
  (2-3 different attempts max, never the same relaunch identically, never a loop).
- **Silent past the configured threshold** (`pipeline.config.json` -> `supervision.staleMinutes`,
  default 30 min; the guard `Stop` hook detects this automatically and re-prompts) -> mark it blocked
  and escalate to the user, never leave it as-is.

### R2 fixture rule (`no-fixture`)
- The Lead passes `issueType` in the Workflow args, taken from the issue's `type:*` label (e.g. `bug`, `feature`, `chore`); omit it when unknown (= not a bug).
- Workflow JS computes `r2Applies` = `issueType === 'bug'` AND a Sam target file under `workflows/`; Nick is never asked to judge it.
- When it applies, Nick's Dev-phase prompt carries the acceptance item: `fixtures/incidents/<issue>-*.json` present, replayed red on base and green on branch by `scripts/run-offline.cjs`.
- No such fixture in the branch: Nick sets label `no-fixture` on the issue and uses `Refs #<N>` (not `Closes`) on the PR body's first line, so the issue stays open.
- The Lead treats a `no-fixture` issue as not done.

## 6. On `ready` — worktree cleanup (after user order)
- The PR is ready (LGTM, acceptance checklist checked). **Do not merge on your own initiative.**
- **Only remove the worktree after an explicit order from the user** (uncommitted work could still live there). The SubagentStop hook only warns, never deletes.
- On order:
  ```bash
  git worktree remove "<WT>"
  ```

## Reporting
Short status to the user at each milestone (plan-ready / dev-done / needs-revision / verified-untickable / ready / no-go / escalate): what happened + the next decision. Bullets, no prose.
