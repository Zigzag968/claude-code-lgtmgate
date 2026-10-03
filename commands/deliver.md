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
- Keep the JSON object in memory: pass it as-is to the workflow (`config`) — ALWAYS, as the parsed object (never the JSON text, never omitted): the workflow has no filesystem and refuses to start without a `config` object (#13). Same for `configLocal` (`{}` if the file is absent).
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
- `git fetch origin <baseBranch>` first: the worktree is created from the freshly fetched `origin/<baseBranch>`, never from a local branch taken for granted.
- Slug: **`issue-<N>`** (fixed). Nick commits on the worktree's branch (he no longer recomputes it) — keep a predictable name aligned with GH tracking. (friction F2)
- `WT="<worktreeRoot>/<slug>"`; branch `<config.branchPrefix><slug>`.
- Create it (1 command):
  ```bash
  git worktree add "<WT>" -b <branchPrefix><slug> origin/<baseBranch>
  ```
- **Behind the base** (the dispatch preflight reports it): a worktree with no commit of its own is fast-forwarded with `git merge --ff-only origin/<baseBranch>`; with own commits it is refused and the exact command is `git -C "<WT>" merge origin/<baseBranch>`. Never a rebase.
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
  architectureDecisionApproved: <optional — attests that the architecture-only pass (design-step trigger) already happened and was approved, exempts this launch from proceedThrough:"plan">,
  pluginRoot: <absolute ${CLAUDE_PLUGIN_ROOT} for the plugin component; for a local copy of the workflow, the absolute root of the checkout that holds templates/probe-run.cjs (or set config.probeRunPath); its .claude-plugin/plugin.json version must equal the engine's, so a local copy of the workflow is refreshed together with the plugin (a mismatch escalates before provisioning, #195) — the workflow has no filesystem or env, so this is how the probe layer finds templates/probe-run.cjs (config.probeRunPath wins; with neither, the run fails closed with probeReason 'probe-run-not-found')>
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
| `plan-ready` | Sam posted his plan (GO), semi checkpoint | Update the user (plan + issue). On green light: relaunch the workflow with `entryStage:"dev"` + `proceedThrough:"dev"` (or `"review"`) + `planText` (Sam's plan: the artifact `.pipeline/plans/issue-<N>-sam.md` or the `<!-- pipeline-plan:issue-<N> -->` comment on the issue). |
| `dev-done` | Nick opened the PR, checkpoint | Update (PR URL). On green light: relaunch with `entryStage:"review"` + `prNumber:<PR>` + `planText` (Sam's plan, as for `plan-ready`). |
| `needs-revision` | Morgan requested changes (`items`) | Report the blockers. On green light: relaunch with `entryStage:"review"` + `prNumber` + `proceedThrough:"review"` + `planText` (Sam's plan, as for `plan-ready`) (Nick fixes, Morgan re-reviews). |
| `verified-untickable` | Morgan proved the boxes but the workflow's tick (the pr-write probe) was refused, or only checklist wording is left (not a code defect); `untickableItems[]` = `{id, item, proof}` per box, read from the probe result, and `tickReason` = the reason the probe gave (`write-failed`: the edit was refused, often permissions; `stale-read`: the body kept changing under the tick, already retried once; `no-markers`, `read-failed`, `splice-failed`, `guard-failed-restored`, or `probe-unavailable`: no usable probe answer, so no reason is known) | Never dispatch Nick. Read `tickReason` first: only `write-failed` is a refusal, any other reason is a defect of the PR body or of the probe to look at before ticking. Re-run each `proof` carried by the payload (quick), tick only the boxes whose proof passes by hand (`gh pr edit <pr> --body ...`; `scripts/lead-merge.sh <pr> --tick-from-review` serves a run without ids only, tracked in #196), then relaunch with `entryStage:"review"` + `prNumber:<pr>` + `planText` (Sam's plan, as for `needs-revision`, so that the acceptance items survive; Morgan proves every box again, the ticked ones included, LGTM, `ready`). |
| `ready-pending-human` | Morgan requested changes but every remaining box is a `[human-gate]` item (`humanGateItems[]`), optionally plus proven boxes whose tick was refused (`untickableItems[]`, `tickReason`); nothing left for Nick; `resumable:true` | Never dispatch Nick. Hand the human gestures to the user (live test, approval), who ticks the `[human-gate]` boxes; handle `untickableItems[]` as for `verified-untickable`; then relaunch with `entryStage:"review"` + `prNumber:<pr>`. |
| `delivered-no-pr` | Nick finished (tests green, `summary`) without a PR, typically because `git push` over SSH is blocked in the agent sandbox (#108); `leadAction` carries the exact commands | The Lead pushes (the agent never bypasses its sandbox) with the HTTPS command quoted in `leadAction` (`git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/<repo>.git refs/heads/<branch>:refs/heads/<branch>`), opens the draft PR (`gh pr create --draft --base <base> --head <branch>`), then relaunches with `entryStage:"review"` + `prNumber:<PR>`. If the deliverables were legitimately pre-existing PRs, no push is needed. |
| `no-go` | Sam blocked (`reason`) | Relay the blocker to the user. Do not force it. |
| `diagnosis-refuted` | Theo refuted the issue's premise (`evidence`; `actualCause` when he found the real one); no Sam/Nick/Morgan spent | Relay the evidence to the user; the issue is amended (or closed) before any relaunch — never relaunch on the refuted premise. |
| `lane-refused` | Theo found a user-visible change dispatched on the mechanical scout lane (`evidence`); `requiredScout` names the product scout the project should use | Relaunch with `scoutAgent:"<requiredScout>"` (a scout the project registers itself), or confirm the lane with the user. |
| `escalate` | 3 rounds without LGTM (`finalVerdict`), or `reason:"plan-not-sound"`/`"plan-audit-malformed"` (plan audit, if `planAudit` is active) | Escalate to the user: merge as-is + follow-up, or continue. A `plan-not-sound` escalate carries `auditTrace`/`roundOneAboveTarget`/`blockingSeries` — read them BEFORE deciding (never raise `maxAuditRounds` further without an explicit risk-class reason; it's a routing event, not a signal to loop again). A `reason:"plugin-version-skew"` / `"plugin-version-unreadable"` escalate (#195): `pluginRoot` holds another plugin version than the engine, or its manifest is unreadable; raised before provisioning, no Project label written; relaunch with the current `${CLAUDE_PLUGIN_ROOT}`. A `reason:"mergeable-conflicting"` escalate (legacy#170): check the live state (`gh pr view <pr> --json mergeable,mergeStateStatus`); if you decide to let Nick reconcile rather than handle it as-is, relaunch with `entryStage:"dev"` + `prNumber:<pr>` + `resumeReason:"mergeable-conflicting"` (lgtmgate#183) — its prompt will then explicitly carry the resume reason instead of letting it wrongly conclude "already done". |
| `design-step-required` | The design-step trigger fired (Theo: >=2 of {persistent state, auth/security, deployment config}, or an immature vendor API), or the plan hit a one-way door the repo declares (a `targetFiles` entry matching `config.oneWayDoorPaths`, or a `one-way-door: <kind>` line Sam announced for a kind listed in `config.oneWayDoorKinds`; both default none; the result's `oneWayDoorHits` names what fired and `reason` summarizes it), and no architecture decision has been approved yet | Relaunch either with `proceedThrough:"plan"` + a brief scoped to the architecture one-pager alone (stops at `plan-ready` for your validation), or with `architectureDecisionApproved:true` if that pass already happened. |
| `ready` | LGTM, PR ready to merge | Update (PR + branch). See §6. |
| `provision-died` / `diagnose-died` / `plan-died` / `plan-check-died` / `plan-audit-died` / `dev-died` / `preflight-died` / `review-died` | An agent died (error or empty response) on this step after retry (Nick and Morgan are never retried); `resumable:true` | Diagnose the cause if possible, then relaunch the workflow with the **same `config`/`wtPath`** via `resumeFromRunId` (see §Supervision) — never relaunch identically in a loop without understanding why. |
| `preflight-stuck` | 2 preflight failures, run escalated | First check whether the failing requirement is literally what the PR's diff changes (`self-reference-preflight`, issue legacy#83); if so it's a known false-positive — check the branch state by hand and do NOT ask Nick to satisfy the stale check. To relaunch against the branch's current gate logic, launch a **NEW** run via `Workflow({ scriptPath: "<worktree>/workflows/deliver-pipeline.js", ... })` (fresh read from disk), **never** a plain `resumeFromRunId` (it replays the original run's cached inputs). |
| `already-done` | On an `entryStage:"dev"`/`"review"` relaunch, the already-done guard found the issue closed or its PR merged on the expected branch (`mergedAt`); the relaunch is aborted | Nothing to relaunch. Check the PR/issue state (`gh pr view`, `gh issue view`), then §6 for the worktree (on the user's order). |
| `dry-run-ok` | `dryRun:true` validated the args and echoes the resolved options (`mode`, `entryStage`, `planAudit`, `planFreshness`, `maxAuditRounds`, `models`...) with no agent spawned; `reason:"probe-only"` when `probeOnly` ran one probe (`probe`) | None — read the echoed resolution, then launch for real (the flow suite and the run-offline fixtures use it). |

Always relaunch the workflow with the **same `config` and `wtPath`**. Never re-spawn a step that already finished without `entryStage`.
Every relaunch or resume (green light, `resumeFromRunId`) follows the §4 clean-turn rule: `Workflow` is the
first tool call of its turn. If you need to check anything first (`gh pr view`, `git log`), do it, end the
turn with a trivial background command, and relaunch from the notification turn.

A payload returned after a Morgan round may carry `boxes[]` (`{id, text, humanGate, proven, proof}` per acceptance box, ids from the `<!-- ac:N -->` comments) when the run holds Sam's `acceptanceItems`; a run resumed at `entryStage` dev or review rebuilds them from the `<!-- ac:N -->` lines of `planText`: pass Sam's plan (the artifact or the `<!-- pipeline-plan:issue-<N> -->` comment), as the `plan-ready`, `dev-done` and `needs-revision` rows of §5 say. A `planText` without ids, one whose checklist has a line without its id (all or nothing), one holding two different id'd checklists, or none, leaves no items and returns no `boxes`.

### Probe prerequisites (fail-closed, #82)
Provision, freshness and the behind-count go through `probe()`; a probe that cannot be proven fails closed, never open. When the templates come from `args.pluginRoot` (no `config.probeRunPath`), the first probe of a run is the plugin version read (#195): the signatures below appear on it, before provisioning.
- **Plugin hooks enabled**: `hooks/PostToolUse-probe-attest.sh` must run (it attests the PROBE line). Signature: `escalate` / `reason: provision-failed` with `probeReason: 'no-attestation'` and a `probeHint`. Fix: enable the plugin hooks in the session, relaunch.
- **`lgtmgate:probe` agent type resolvable**: if the registry lacks it (anthropics/claude-code#88023), the engine retries once persona-in-prompt (trace `agent-type-unresolved:probe`). The hook keys on `agent_type`, so in that mode attestation is usually missing and the run ends as above; start a fresh session.
- **`args.pluginRoot` or `config.probeRunPath`**: without either, `probeReason: 'probe-run-not-found'`.
- **Plugin root of the engine's version** (#195): when the templates come from `args.pluginRoot` (no `config.probeRunPath`), a script reads `<pluginRoot>/.claude-plugin/plugin.json` before provisioning and compares its version with the engine's own build. A different version (older or newer) ends as `escalate` / `reason: plugin-version-skew`; a manifest the probe read but that is absent, not JSON, or without a string version, as `reason: plugin-version-unreadable`. Both name the engine version and the remedy, and never the local path (it would be refused by the GitHub scrub hook if pasted): the path of the root is the result's own `pluginRoot` field. `plugin-version-unreadable` means the probe ran and the manifest is what failed: a failure of the probe itself (the bullets above: no attestation, agent type not resolved, no line copied) keeps the `provision-failed` signature with its `probeReason` and `probeHint`. No Project label is written by this check (the stale root's scripts may be absent), so read the returned `reason`.
- **Relaunch after a failed probe**: `probe-run.cjs` reuses `.pipeline/probes/issue-<N>/<label>-r<round>.json` only for the identical command with a successful exit; a changed command or a stored failure is re-executed.
- **What is verified**: the VERIFY line is produced by the probe agent (it runs `probe-run.cjs --verify`); the engine compares it with the copied PROBE line but does not itself attest VERIFY. Attesting VERIFY is a follow-up (#83).

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
- **Before any decision on an `escalate` or `*-died` status** (engine repo): `bash scripts/capture-incident.sh <runId> <issue> <label>` writes a private raw capture under `.pipeline/captures/` (git-ignored), replays it and prints the next step. Capture first, then decide.

### R2 fixture rule (`no-fixture`)
- The Lead passes `issueType` in the Workflow args, taken from the issue's `type:*` label (e.g. `bug`, `feature`, `chore`); omit it when unknown (= not a bug).
- Workflow JS computes `r2Applies` = `issueType === 'bug'` AND a Sam target file under `workflows/` AND `config.engineRepo` is true (this plugin's own repo); a consumer run never carries the item. Nick is never asked to judge it.
- When it applies, Nick's Dev-phase prompt carries the acceptance item: `fixtures/incidents/<issue>-*.json` present, replayed red on base and green on branch by `scripts/run-offline.cjs`.
- No such fixture in the branch: Nick sets label `no-fixture` on the issue and uses `Refs #<N>` (not `Closes`) on the PR body's first line, so the issue stays open.
- The Lead treats a `no-fixture` issue as not done.

## 6. On `ready` — merge (on user order) and worktree cleanup
- The PR is ready (LGTM, acceptance checklist checked). **Do not merge on your own initiative.**
- **Merge only through `scripts/lead-merge.sh <pr>`**, on an explicit user order, run from the PR worktree:
  - checks the acceptance checklist (`scripts/lib/acceptance-check.sh`, same lib as the merge hook); any `- [ ]` refuses
  - refuses `FAIL: review-stale` (right after the acceptance gate, before the exceptions, the tick and every fetch/merge/push) unless the latest comment whose first line is `<!-- pipeline-review-round pr=<N> sha=<40hex> -->` (Morgan's verdict; the squash note re-attests the squashed head) names the PR head as the API reports it now. No such marker, or another sha (a commit after the review): re-run the review (resume at `review`), never merge around it. A re-run after a partial run (only this script's own bump and base-merge commits on top of the reviewed sha) is accepted; any other commit is not. Nick's push-notes keep the bare marker and are never a review. `hooks/block-merge-unchecked.sh` applies the same check to a bare `gh pr merge`
  - `--tick-from-review` (after the exception check, before the base merge): reads Morgan's latest multi-line `pipeline-review-round` verdict, ticks through REST (`PATCH pulls/<N>`) each open box it quotes verbatim with `— verified, tick pending (permissions): <proof with a command>` (never `[human-gate]`), re-reads the body, then the gate above decides; a box without such a line stays open and refuses; no verdict comment refuses. Re-verify the proofs yourself first; a push after the verdict is refused (`review-stale`, step above)
  - refuses a declared exception (`exception: <what> — <why> — #N` in the acceptance block) unless `#N` is open with the `tech-debt` label and the PR diff adds a `DEBT(#N)` marker (`FAIL: declared-exception: <reason>`, before any bump or push)
  - refuses unless on the PR head branch, clean, and in sync with the remote head (fast-forwards if behind, refuses if diverged)
  - brings the base in locally first: `git fetch origin main` + `git merge --no-edit origin/main` (merge only; a conflict aborts the merge and stops before any push; a conflict limited to the version files takes main's copy). No `gh pr update-branch`: the local merge already makes the branch current
  - then bumps the version from the merged tree (next version over max(branch, main), semver precedence: patch+1, or the prerelease counter+1 for `X.Y.Z-beta.N`: `.claude-plugin/plugin.json` + `BUILD`), commits, pushes once — PRs themselves never bump
  - waits until the PR reports the pushed sha with at least one check (bounded poll, cli/cli#7401), then asks the API whether `main` requires status checks (classic branch protection, then rulesets; HTTP 403/404 = none, any other answer refuses): required (`mode: required-checks`) waits for them to register, then `gh pr checks --watch --fail-fast --required`; none (`mode: no-required-checks`, e.g. a private repo on GitHub Free) polls `gh pr checks --json` until the head's checks are green, restricted to `config.ciChecks` when set. A timeout names the mode
  - `gh pr merge --merge --delete-branch` (never the auto-merge flag)
  - reads the PR back over REST (`merged` true and `merged_at` set); only then closes each still-open `Closes/Fixes/Resolves #N` issue found in the PR body's header block only (lines before the first `## ` line, code fences and inline code stripped) with `Fixed by #<PR> (merged).` (`Refs #N` never closed; a failed or unverified merge exits non-zero and closes nothing)
  - then sync the main checkout: `git fetch origin && git merge --ff-only origin/main`
- **No resume across a pin move**: never `resumeFromRunId` a run after the plugin version or pin changed (`BUILD` differs from the one the run started on) — relaunch fresh.
- **Only remove the worktree after an explicit order from the user** (uncommitted work could still live there). The SubagentStop hook only warns, never deletes.
- On order:
  ```bash
  git worktree remove "<WT>"
  ```

## Reporting
Short status to the user at each milestone (plan-ready / dev-done / needs-revision / verified-untickable / ready / no-go / escalate): what happened + the next decision. Bullets, no prose.
