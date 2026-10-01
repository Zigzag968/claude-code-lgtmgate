---
description: Bootstrap the lgtmgate in this project — copy templates, generate pipeline.config.json, wire GH + settings.
argument-hint: ""
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# /lgtmgate:init — Runbook (Lead)

You are the **Lead**. You install the `lgtmgate` pipeline in the current project. Goal: a ready-to-use `.claude/` and a valid `.claude/pipeline.config.json`, without hardcoding anything stack-specific into the plugin.

Work from the project root (`${CLAUDE_PROJECT_DIR}`). The plugin lives under `${CLAUDE_PLUGIN_ROOT}`. **Bash: absolute path, 1 command/call, no `cd`/`&&`/`|`.**

## 0. Pre-check
- `command -v gh` — confirm the `gh` CLI is installed. Missing -> stop, ask to install it from https://cli.github.com/.
- `gh auth status` — confirm authentication and scopes. Not authenticated / insufficient scopes -> stop, ask for `gh auth login --scopes "repo,project"`.
- `command -v jq` — confirm the `jq` CLI is installed (required by hooks/block-merge-unchecked.sh and hooks/deny-destructive-git.sh, which fail closed without it). Missing -> stop, ask to install it from https://jqlang.github.io/jq/.
- `git rev-parse --show-toplevel` — confirm we're in a git repo. If not, stop and ask.
- If `.claude/pipeline.config.json` already exists → **AskUserQuestion 3-way**: (a) **complete** — only reinstall the missing machinery artifacts (workflows/rules/scripts), validate the existing config against the template schema, **without overwriting it** (recommended default if the existing config is valid); (b) **re-init** — regenerate everything, overwrites the config; (c) **abort**. (friction F1)
  - Note (legacy#73): `complete` NEVER refreshes a file that's already present (e.g. `.claude/rules/pr-acceptance.md`) even if `templates/pr-acceptance.md` has been hardened since the initial provisioning. After every `claude plugin update lgtmgate`, manually diff the consumer file against `${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md` (`diff .claude/rules/pr-acceptance.md ${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md`) and propagate the hardened sections — never assume the consumer file automatically tracks the canonical one.

## 1. Copy the templates
Create the target folders if missing (`.claude/workflows`, `.claude/rules`, `.claude/scripts`, **`scripts`** — at the repo root, not under `.claude/`), then copy:

- `${CLAUDE_PLUGIN_ROOT}/templates/test-deliver-pipeline.js` → `.claude/workflows/test-deliver-pipeline.js`
- `${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md`         → `.claude/rules/pr-acceptance.md`
- `${CLAUDE_PLUGIN_ROOT}/templates/gh-pipeline-status.sh`    → `.claude/scripts/gh-pipeline-status.sh`
- `${CLAUDE_PLUGIN_ROOT}/templates/blocked-by-check.sh`      → `.claude/scripts/blocked-by-check.sh`
- `${CLAUDE_PLUGIN_ROOT}/templates/provision_worktree.sh`    → `scripts/provision_worktree.sh`

Then: `chmod +x .claude/scripts/gh-pipeline-status.sh`, `chmod +x .claude/scripts/blocked-by-check.sh` and `chmod +x scripts/provision_worktree.sh`.

`blocked-by-check.sh` is not fail-closed like `provision_worktree.sh` — a project with no cross-repo dependency works fine without it, this copy is just an optional install slot.

Pipeline stage 1 (provisioning) is **fail-closed** on `scripts/provision_worktree.sh` — this copy is not optional: without it, the first run `exit 127`s.

(1 `cp` command per file — no compounding.)

**Commit + push BEFORE the first run (mandatory — MANDATORY, claude-agent-pipeline#51).** The provisioning gate runs `bash "<worktree>/scripts/provision_worktree.sh"` **from the WORKTREE**, i.e. the content **COMMITTED** on `baseBranch` — not the working tree of the main checkout that `init` just wrote to. `git worktree add` always clones from a committed ref: until these files are committed + pushed to `baseBranch`, a freshly created worktree does NOT have `scripts/provision_worktree.sh`, the gate `exit 127`s, and the pipeline escalates `provision-failed` on the very first task — exactly the failure this gate is meant to prevent. Before the first `/lgtmgate:deliver`:
```bash
git add scripts/provision_worktree.sh .claude/workflows .claude/rules .claude/scripts .claude/pipeline.config.json
```
```bash
git commit -m "chore(pipeline): bootstrap lgtmgate machinery"
```
```bash
git push origin <baseBranch>
```
(1 command per call, no compounding — same rule as the rest of this runbook.)

## 2. Generate `.claude/pipeline.config.json`
Read the template `${CLAUDE_PLUGIN_ROOT}/templates/pipeline.config.template.json`. Detect what you can, ask for the rest via **AskUserQuestion** (lettered options + tradeoff), then write the final JSON with the Write tool.

### Repo introspection (do this BEFORE filling in — friction F13)
The plugin must integrate with the repo's REAL git-flow, not hardcode defaults. Detect:
- **Default branch**: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. If a `develop` branch exists (`git show-ref --verify --quiet refs/remotes/origin/develop`), git-flow is likely → propose `develop` as `baseBranch`, otherwise the default branch.
- **Dominant branch prefix**: `git branch -r | sed -E 's#^ *origin/##' | grep / | cut -d/ -f1 | sort | uniq -c | sort -rn` → take the most frequent prefix (e.g. `feature` → `branchPrefix: "feature/"`). **Do NOT hardcode `features/`.** If a `.claude/rules/git-workflow.md` rule exists, its conventions take precedence.
- **CI base filters**: for each `.github/workflows/*.yml`, read `on.pull_request.branches`. **If `baseBranch` isn't in there, WARN**: "PRs to `<baseBranch>` will not trigger CI `<workflow>` → either target a covered base, or leave `ciChecks: []` (Morgan will validate on the local green bar)". Fill `ciChecks` with the job names of the workflows that DO trigger on the chosen base.

Fields to fill in:
- **commands**: `build`, `test`, `format` — the exact command for the stack (e.g. Node: `npm run build` / `npm test` / `npx prettier -w`). Detect via the manifests present (`package.json`, `Cargo.toml`, `*.xcworkspace`, `pyproject.toml`, `Makefile`). If ambiguous → ask.
- **conventionsRule**: path to the project's conventions rule (default `.claude/rules/conventions.md`). If absent, offer to create a skeleton.
- **baseBranch** / **branchPrefix**: from the introspection above (default branch + dominant prefix). Confirm via AskUserQuestion if ambiguous. **Never hardcode `features/`.**
- **worktreeRoot**: root where shared worktrees will be created (e.g. `/Users/you/Worktrees/<repo>` or `../worktrees/<repo>`). Ask if not obvious. **Versioned value = LOGICAL default only** (legacy#61): a machine-specific root goes into `$LGTMGATE_WORKTREE_ROOT` (env) or into `.claude/pipeline.config.local.json` (gitignored, precedence `env > local > versioned`) — add this path to the consuming project's `.gitignore`.
- **ciChecks**: job names required green before LGTM (e.g. `["build-and-test"]`), from the workflows that trigger on `baseBranch` (cf introspection). If the chosen base is covered by no workflow → **`ciChecks: []`** (Morgan validates on the local green bar, without blocking on an absent CI).
- **regressionGuard**: `testGlob` (e.g. `*Tests.swift`, `*.test.ts`, `test_*.py`) + `testFnPattern` (e.g. `func test`, `it(`, `def test_`).
- **ghProject**: `number`, `id`, the "Pipeline Status" field (`fieldId`) + `statusOptions` (name→optionId map). See §5 if the field doesn't exist. If the project doesn't use a GH Project, leave `ghProject` empty — the workflow degrades gracefully (skips updateStatus).
- **planAudit**: adversarial plan-soundness audit before Dev, default `false`. Enable it explicitly if the project wants this gate (cost: `maxAuditRounds × maxPlanAttempts` extra opus spawns in the worst case).
- **stack**: free-text string describing the target stack, passed to the plan auditor (e.g. `Django 5 / Python 3.12`). Empty → the auditor infers it from the worktree.
- **oneWayDoorPaths**: optional key, deliberately absent from `pipeline.config.template.json` and default `[]` (no path-based stop). Add it only for a repo that declares one-way doors (globs, `dir/` prefixes or exact paths, `!` to exclude): a plan touching one stops at the design step before dev.
- **commitHygiene** / **commentHygiene**: optional keys, deliberately absent from `pipeline.config.template.json` (no automatic generation — enable knowingly). `commitHygiene: { squashBeforeHandoff, maxCommits }` only pays off on a repo whose base merges with merge-commits (otherwise a squash merge already does the job for free). `commentHygiene: true` collapses the review-round history in PR comments — the decision-log compositor landed in this copy (0.8.2) and preserves that history in the PR body, so enabling it stays a conscious decision but is no longer blocked by a lack of replacement mechanism.

Validate the written JSON: `python3 -c "import json; json.load(open('.claude/pipeline.config.json'))"`.

## 3. GitHub snippets (optional, propose)
Propose (AskUserQuestion) inserting the snippets to enable pm_review + the acceptance gate:
- `${CLAUDE_PLUGIN_ROOT}/templates/github/feature-pm_review.snippet` → `pm_review` checkboxes block to add to `.github/ISSUE_TEMPLATE/feature.yml`.
- `${CLAUDE_PLUGIN_ROOT}/templates/github/pr-acceptance.snippet` → `## Acceptance checklist` section (with `<!-- acceptance:start/end -->` markers) to add to `.github/pull_request_template.md`.

If the target files exist: insert the block at the right spot (Edit). Otherwise: offer to create the file from the snippet. **Never overwrite** an existing template without confirmation.

## 4. Settings (reminder)
Remind the user to enable the plugin in `.claude/settings.json` (or global settings):
- `extraKnownMarketplaces` → add the `zigzag-plugins` marketplace (`github` / `Zigzag968/claude-code-lgtmgate`).
- `enabledPlugins` → add `"lgtmgate@zigzag-plugins"`.

Offer to do it for them (Edit the settings) after confirmation; otherwise show the diff to paste.

## 5. (Optional) Create the GH "Pipeline Status" field
If the project uses a GH Project but doesn't have the field, offer to create it:
```bash
gh project field-create <number> --owner <owner> --name "Pipeline Status" --data-type SINGLE_SELECT --single-select-options "Planning,Dev,Review,Ready,Blocked"
```
Then fetch the `optionId`s (via `gh project field-list ... --format json`) and fill in `ghProject.statusOptions` in the config.

## 6. Final summary
Show: files copied, config path, CI checks retained, and the next action (`/lgtmgate:deliver <issue> "<brief>"`). If a source template is missing under `${CLAUDE_PLUGIN_ROOT}/templates/`, report it clearly (don't pretend to have copied it).
