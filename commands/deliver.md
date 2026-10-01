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
  pluginRoot: <absolute ${CLAUDE_PLUGIN_ROOT} for the plugin component; for a local copy of the workflow, the absolute root of the checkout that holds templates/probe-run.cjs (or set config.probeRunPath) — the workflow has no filesystem or env, so this is how the probe layer finds templates/probe-run.cjs (config.probeRunPath wins; with neither, the run fails closed with probeReason 'probe-run-not-found')>
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
| `verified-untickable` | Morgan proved every box but couldn't check them (permissions); `untickableItems[]` = `{item, proof}` per box (not a code defect) | Never dispatch Nick. Re-run each `proof` carried by the payload (quick), tick only the boxes whose proof passes, either by hand (`gh pr edit <pr> --body ...`) or at merge time with `scripts/lead-merge.sh <pr> --tick-from-review` (ticks the boxes Morgan's verdict lists as `verified, tick pending (permissions)` with a quoted command, never a `[human-gate]` box), then relaunch with `entryStage:"review"` + `prNumber:<pr>` (Morgan no longer sees an open box, LGTM, `ready`). A `ready-pending-human` payload can also carry `untickableItems[]`: same handling for those; `[human-gate]` boxes stay human-only, never checked by you. |
| `delivered-no-pr` | Nick finished (tests green, `summary`) without a PR, typically because `git push` over SSH is blocked in the agent sandbox (#108); `leadAction` carries the exact commands | The Lead pushes (the agent never bypasses its sandbox) with the HTTPS command quoted in `leadAction` (`git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/<repo>.git refs/heads/<branch>:refs/heads/<branch>`), opens the draft PR (`gh pr create --draft --base <base> --head <branch>`), then relaunches with `entryStage:"review"` + `prNumber:<PR>`. If the deliverables were legitimately pre-existing PRs, no push is needed. |
| `no-go` | Sam blocked (`reason`) | Relay the blocker to the user. Do not force it. |
| `escalate` | 3 rounds without LGTM (`finalVerdict`), or `reason:"plan-not-sound"`/`"plan-audit-malformed"` (plan audit, if `planAudit` is active) | Escalate to the user: merge as-is + follow-up, or continue. A `plan-not-sound` escalate carries `auditTrace`/`roundOneAboveTarget`/`blockingSeries` — read them BEFORE deciding (never raise `maxAuditRounds` further without an explicit risk-class reason; it's a routing event, not a signal to loop again). A `reason:"mergeable-conflicting"` escalate (legacy#170): check the live state (`gh pr view <pr> --json mergeable,mergeStateStatus`); if you decide to let Nick reconcile rather than handle it as-is, relaunch with `entryStage:"dev"` + `prNumber:<pr>` + `resumeReason:"mergeable-conflicting"` (lgtmgate#183) — its prompt will then explicitly carry the resume reason instead of letting it wrongly conclude "already done". |
| `design-step-required` | The design-step trigger fired (Theo: >=2 of {persistent state, auth/security, deployment config}, or an immature vendor API), or the plan hit a one-way door (a `targetFiles` entry matching `config.oneWayDoorPaths`, default none, or a `one-way-door: <kind>` line Sam announced because the repo's `ARCHITECTURE.md` lists one-way doors; `oneWayDoorKinds` names it), and no architecture decision has been approved yet | Relaunch either with `proceedThrough:"plan"` + a brief scoped to the architecture one-pager alone (stops at `plan-ready` for your validation), or with `architectureDecisionApproved:true` if that pass already happened. |
| `ready` | LGTM, PR ready to merge | Update (PR + branch). See §6. |
| `diagnose-died` / `plan-died` / `plan-check-died` / `plan-audit-died` / `dev-died` / `preflight-died` | An agent died (error or empty response) on this step after retry; `resumable:true` | Diagnose the cause if possible, then relaunch the workflow with the **same `config`/`wtPath`** via `resumeFromRunId` (see §Supervision) — never relaunch identically in a loop without understanding why. |
| `preflight-stuck` | 2 preflight failures, run escalated | First check whether the failing requirement is literally what the PR's diff changes (`self-reference-preflight`, issue legacy#83); if so it's a known false-positive — check the branch state by hand and do NOT ask Nick to satisfy the stale check. To relaunch against the branch's current gate logic, launch a **NEW** run via `Workflow({ scriptPath: "<worktree>/workflows/deliver-pipeline.js", ... })` (fresh read from disk), **never** a plain `resumeFromRunId` (it replays the original run's cached inputs). |

Always relaunch the workflow with the **same `config` and `wtPath`**. Never re-spawn a step that already finished without `entryStage`.
Every relaunch or resume (green light, `resumeFromRunId`) follows the §4 clean-turn rule: `Workflow` is the
first tool call of its turn. If you need to check anything first (`gh pr view`, `git log`), do it, end the
turn with a trivial background command, and relaunch from the notification turn.

### Probe prerequisites (fail-closed, #82)
Provision, freshness and the behind-count go through `probe()`; a probe that cannot be proven fails closed, never open.
- **Plugin hooks enabled**: `hooks/PostToolUse-probe-attest.sh` must run (it attests the PROBE line). Signature: `escalate` / `reason: provision-failed` with `probeReason: 'no-attestation'` and a `probeHint`. Fix: enable the plugin hooks in the session, relaunch.
- **`lgtmgate:probe` agent type resolvable**: if the registry lacks it (anthropics/claude-code#88023), the engine retries once persona-in-prompt (trace `agent-type-unresolved:probe`). The hook keys on `agent_type`, so in that mode attestation is usually missing and the run ends as above; start a fresh session.
- **`args.pluginRoot` or `config.probeRunPath`**: without either, `probeReason: 'probe-run-not-found'`.
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

### R2 fixture rule (`no-fixture`)
- The Lead passes `issueType` in the Workflow args, taken from the issue's `type:*` label (e.g. `bug`, `feature`, `chore`); omit it when unknown (= not a bug).
- Workflow JS computes `r2Applies` = `issueType === 'bug'` AND a Sam target file under `workflows/`; Nick is never asked to judge it.
- When it applies, Nick's Dev-phase prompt carries the acceptance item: `fixtures/incidents/<issue>-*.json` present, replayed red on base and green on branch by `scripts/run-offline.cjs`.
- No such fixture in the branch: Nick sets label `no-fixture` on the issue and uses `Refs #<N>` (not `Closes`) on the PR body's first line, so the issue stays open.
- The Lead treats a `no-fixture` issue as not done.

## 6. On `ready` — merge (on user order) and worktree cleanup
- The PR is ready (LGTM, acceptance checklist checked). **Do not merge on your own initiative.**
- **Merge only through `scripts/lead-merge.sh <pr>`**, on an explicit user order, run from the PR worktree:
  - checks the acceptance checklist (`scripts/lib/acceptance-check.sh`, same lib as the merge hook); any `- [ ]` refuses
  - `--tick-from-review` (after the exception check, before the base merge): reads Morgan's latest multi-line `pipeline-review-round` verdict, ticks through REST (`PATCH pulls/<N>`) each open box it quotes verbatim with `— verified, tick pending (permissions): <proof with a command>` (never `[human-gate]`), re-reads the body, then the gate above decides; a box without such a line stays open and refuses; no verdict comment refuses. Re-verify the proofs yourself first: a Nick push-note after the verdict is not detected
  - refuses a declared exception (`exception: <what> — <why> — #N` in the acceptance block) unless `#N` is open with the `tech-debt` label and the PR diff adds a `DEBT(#N)` marker (`FAIL: declared-exception: <reason>`, before any bump or push)
  - refuses unless on the PR head branch, clean, and in sync with the remote head (fast-forwards if behind, refuses if diverged)
  - brings the base in locally first: `git fetch origin main` + `git merge --no-edit origin/main` (merge only; a conflict aborts the merge and stops before any push; a conflict limited to the version files takes main's copy). No `gh pr update-branch`: the local merge already makes the branch current
  - then bumps the patch version from the merged tree (patch+1 over max(branch, main): `.claude-plugin/plugin.json` + `BUILD`), commits, pushes once — PRs themselves never bump
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
