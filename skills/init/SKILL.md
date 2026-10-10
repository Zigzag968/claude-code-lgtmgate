---
name: init
description: Bootstrap the lgtmgate in this project — copy templates, generate pipeline.config.json, wire GH + settings.
disable-model-invocation: true
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
  - Note (legacy#73): `complete` NEVER refreshes a file that's already present (e.g. `.claude/rules/pr-acceptance.md`) even if `templates/pr-acceptance.md` has been hardened since the initial provisioning. After every `claude plugin update lgtmgate`, run `node ${CLAUDE_PLUGIN_ROOT}/scripts/template-drift.cjs --root "${CLAUDE_PROJECT_DIR}"`: it lists each copy that differs from the current template with the `diff` command to run. Propagate by hand what you want to keep in sync; a deliberate customisation stays.

## 1. Copy the templates
Create the target folders if missing (`.claude/workflows`, `.claude/rules`, `.claude/scripts`, **`scripts`** — at the repo root, not under `.claude/`), then copy:

- `${CLAUDE_PLUGIN_ROOT}/templates/test-deliver-pipeline.js` → `.claude/workflows/test-deliver-pipeline.js`
- `${CLAUDE_PLUGIN_ROOT}/templates/pr-acceptance.md`         → `.claude/rules/pr-acceptance.md`
- `${CLAUDE_PLUGIN_ROOT}/templates/gh-pipeline-status.sh`    → `.claude/scripts/gh-pipeline-status.sh`
- `${CLAUDE_PLUGIN_ROOT}/templates/blocked-by-check.sh`      → `.claude/scripts/blocked-by-check.sh`
- `${CLAUDE_PLUGIN_ROOT}/templates/provision-worktree.sh`    → `scripts/provision-worktree.sh`

Then: `chmod +x .claude/scripts/gh-pipeline-status.sh`, `chmod +x .claude/scripts/blocked-by-check.sh` and `chmod +x scripts/provision-worktree.sh`.

`blocked-by-check.sh` is not fail-closed like `provision-worktree.sh` — a project with no cross-repo dependency works fine without it, this copy is just an optional install slot.

Setup (provisioning) is **fail-closed** on `scripts/provision-worktree.sh` — this copy is not optional: without it, the first run `exit 127`s.

**Upgrading from the previous name.** A consumer initialised earlier has `scripts/provision_worktree.sh`. The engine keeps provisioning with that copy while `scripts/provision-worktree.sh` is absent. To switch, re-run init (`complete` mode installs the missing new name), then `git rm scripts/provision_worktree.sh`, commit and push (provisioning runs from the committed worktree). The fallback is removed under #364.

(1 `cp` command per file — no compounding.)

**Commit + push BEFORE the first run (mandatory — MANDATORY, claude-agent-pipeline#51).** The provisioning gate runs `bash "<worktree>/scripts/provision-worktree.sh"` **from the WORKTREE**, i.e. the content **COMMITTED** on `baseBranch` — not the working tree of the main checkout that `init` just wrote to. `git worktree add` always clones from a committed ref: until these files are committed + pushed to `baseBranch`, a freshly created worktree does NOT have `scripts/provision-worktree.sh`, the gate `exit 127`s, and the pipeline escalates `provision-failed` on the very first task — exactly the failure this gate is meant to prevent. Before the first `/lgtmgate:deliver`:
```bash
git add .claude/lgtmgate scripts/provision-worktree.sh .claude/workflows .claude/rules .claude/scripts .claude/pipeline.config.json
```
```bash
git commit -m "chore(pipeline): bootstrap lgtmgate machinery"
```
```bash
git push origin <baseBranch>
```
(1 command per call, no compounding — same rule as the rest of this runbook.)

The `.claude/lgtmgate/` folder is created by section 2bis below: run it before staging. Project specifics are read from `origin/<baseBranch>`, so commit and push the folder and the config to the base branch before the first `/lgtmgate:deliver`.

## 2. Generate `.claude/pipeline.config.json`
Read the template `${CLAUDE_PLUGIN_ROOT}/templates/pipeline.config.template.json`. Detect what you can, ask for the rest via **AskUserQuestion** (lettered options + tradeoff), then write the final JSON with the Write tool.

### Repo introspection (do this BEFORE filling in — friction F13)
The plugin must integrate with the repo's REAL git-flow, not hardcode defaults. Detect:
- **Default branch**: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. If a `develop` branch exists (`git show-ref --verify --quiet refs/remotes/origin/develop`), git-flow is likely → propose `develop` as `baseBranch`, otherwise the default branch.
- **Dominant branch prefix**: `git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin` (one command, no pipe), then count the prefix before the first `/` yourself, ignoring `HEAD` → take the most frequent prefix (e.g. `feature` → `branchPrefix: "feature/"`). **Do NOT hardcode `features/`.** If a `.claude/rules/git-workflow.md` rule exists, its conventions take precedence.
- **CI base filters**: for each `.github/workflows/*.yml`, read `on.pull_request.branches`. **If `baseBranch` isn't in there, WARN**: "PRs to `<baseBranch>` will not trigger CI `<workflow>` → either target a covered base, or leave `ciChecks: []` (Morgan will validate on the local green bar)". Fill `ciChecks` with the check-run names of the workflows that DO trigger on the chosen base, exactly as `gh pr checks` prints them (matrix suffix included, e.g. `build (ubuntu-latest)`; a reusable workflow reads `caller / callee`).

Fields to fill in:
- **commands**: `build`, `test`, `format` — the exact command for the stack (e.g. Node: `npm run build` / `npm test` / `npx prettier -w`). Detect via the manifests present (`package.json`, `Cargo.toml`, `*.xcworkspace`, `pyproject.toml`, `Makefile`). If ambiguous → ask.
- **Retired key**: a leftover `conventionsRule` in a config is ignored and traced `conventionsRule-ignored:<path>`, the path returned in the run payload as `retiredKeyPath`; when it names a readable rule file, propose adding it to `agentContext["*"]` (flow: #267).
- **baseBranch** / **branchPrefix**: from the introspection above (default branch + dominant prefix). Confirm via AskUserQuestion if ambiguous. **Never hardcode `features/`.**
- **worktreeRoot**: root where shared worktrees will be created (e.g. `/Users/you/Worktrees/<repo>` or `../worktrees/<repo>`). Ask if not obvious. **Versioned value = LOGICAL default only** (legacy#61): a machine-specific root goes into `$LGTMGATE_WORKTREE_ROOT` (env) or into `.claude/pipeline.config.local.json` (gitignored, precedence `env > local > versioned`) — add this path to the consuming project's `.gitignore`.
- **ciChecks**: check-run names required green before LGTM, written exactly as `gh pr checks` prints them on a PR of this repo (matrix suffix included, e.g. `["build-and-test", "build (ubuntu-latest)"]`); a configured name GitHub does not report keeps the run from `ready` (the blocker names it). Take them from the workflows that trigger on `baseBranch` (cf introspection). If the chosen base is covered by no workflow → **`ciChecks: []`** (Morgan validates on the local green bar, without blocking on an absent CI).
- **regressionGuard**: `testGlob` (e.g. `*Tests.swift`, `*.test.ts`, `test_*.py`) + `testFnPattern` (e.g. `func test`, `it(`, `def test_`).
- **ghProject**: `number`, `id`, the "Pipeline Status" field (`fieldId`) + `statusOptions` (name→optionId map). See §5 if the field doesn't exist. If the project doesn't use a GH Project, leave `ghProject` empty — the workflow degrades gracefully (skips updateStatus).
- **planAudit**: adversarial plan-soundness audit before Dev, default `false`. Enable it explicitly if the project wants this gate.
- **stack**: free-text string describing the target stack, passed to the plan auditor (e.g. `Django 5 / Python 3.12`). Empty → the auditor infers it from the worktree.
- **oneWayDoorPaths**: optional key, deliberately absent from `pipeline.config.template.json` and default `[]` (no path-based stop). Add it only for a repo that declares one-way doors (globs, `dir/` prefixes or exact paths, `!` to exclude): a plan touching one stops at the design step before dev.
- **oneWayDoorKinds**: optional key, deliberately absent from `pipeline.config.template.json` and default `[]` (Sam gets no kind question, no kind stops a run). Add it only for a repo whose own change kinds are one-way doors, among `status`, `agent`, `hook` and `seam`: Sam is asked to announce only the listed kinds, and an announced one stops the run at the design step before dev.
- **engineRepo**: optional key, deliberately absent from `pipeline.config.template.json` and default absent = consumer. Never set it in a consumer repo: `true` marks the repo that IS this plugin and turns on the engine-only rules (Sam's engine layer rule, Nick's R2 fixture item); a consumer gets the neutral plan rule and no R2 item.
- **commitHygiene** / **commentHygiene**: optional keys, deliberately absent from `pipeline.config.template.json` (no automatic generation — enable knowingly). `commitHygiene: { squashBeforeHandoff, maxCommits }` only pays off on a repo whose base merges with merge-commits (otherwise a squash merge already does the job for free). `commentHygiene: true` collapses the review-round history in PR comments — the decision-log compositor landed in this copy (0.8.2) and preserves that history in the PR body, so enabling it stays a conscious decision but is no longer blocked by a lack of replacement mechanism.

Validate the written JSON: `python3 -c "import json; json.load(open('.claude/pipeline.config.json'))"`.

## 2bis. Project specifics (stubs the owner completes)
The agents read the owner's rules from `.claude/lgtmgate/` (config key `projectSpecifics`). Init proposes and creates only the stubs; the owner completes them in their own words.

1. **Detect.** `node ${CLAUDE_PLUGIN_ROOT}/scripts/init-specifics.cjs --root "${CLAUDE_PROJECT_DIR}" --detect` prints JSON: the stacks (manifests), the signals and CI workflows, `.claude/rules/*` with or without `paths:`, `AGENTS.md`, `.mcp.json`, the project agents, and an existing `.claude/lgtmgate/` (`existing`, each stub `pristine` or not).
2. **Ask (AskUserQuestion, a recommendation each, only what cannot be detected).** Name each question with these exact phrases:
   - `docs/issues language`
   - `test policy`
   - `forbidden actions`
   - `tools/CLI allowed`, per role
   - `rules to target`, per role: the answer goes to `agentContext` (`"*"` or a role)
   - `branch protection`: see (7)
   There is no `oneWayDoorPaths` question (documented option only). Lanes are a separate, optional step (8).
3. **Proposal before any write.** `node ${CLAUDE_PLUGIN_ROOT}/scripts/init-specifics.cjs --root "${CLAUDE_PROJECT_DIR}" --propose --plugin-version <version of ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json>` prints what would be created or kept and which config keys would be set. Show it and wait for the owner's confirmation.
4. **Write.** `node ${CLAUDE_PLUGIN_ROOT}/scripts/init-specifics.cjs --root "${CLAUDE_PROJECT_DIR}"` creates only the missing stubs and never touches an existing path. Add the owner's answers, in the owner's words, with Edit ONLY into a stub that `--detect` reports `pristine: true`. For any other existing file, print the proposed diff and write nothing: the file is project-owned, never overwrite (P-04).
5. **Config keys (Edit, only when absent or empty).** `projectSpecifics: ".claude/lgtmgate"`; `minPluginVersion` = the plugin version (never lower an existing one, written together with `projectSpecifics` because an older engine ignores the key); `agentContext` entries are added, never removed. Validate the JSON afterwards.
6. **Never copy** a file of `${CLAUDE_PLUGIN_ROOT}/templates/` under `.claude/lgtmgate/` (a copy drifts from the plugin).
7. **Security.** The pipeline needs branch protection on `<baseBranch>` plus required CI (threats: a reviewer ticking everything, an agent pushing to the base or disabling a hook, one shared `gh` identity so a forged review marker is indistinguishable). Ask the branch protection question, then verify with `gh api repos/{o}/{r}/branches/<base>/protection` (REST): 200 with required status checks = ok; 404 = warn and document the need; 403 plan limit = report "cannot verify", never block.
8. **Lanes (optional).** A lane gives a role extra rules and a persona for one part of the repo: files named `<role>.<lane>.md` (`sam.ios.md`, `nick.web.md`), a lane being declared by `lane: <lane>` in the file's frontmatter.
   - Offer it only when `--detect` reports `laneCandidates` with at least 2 entries (distinct stacks), never from the count of project agents. If the owner names an agent they already have (for example an iOS persona), say what it means: without lanes, every file is injected at every run; with lanes, an iOS-only issue receives only the iOS files.
   - AskUserQuestion with a recommendation each: the lane names (`[a-z0-9-]`, 24 characters at most, one per stack), the `paths` globs of each lane, a `hint` (120 characters at most), an optional `persona` (a single name, unique in the folder, never a role name).
   - Show `--propose --lanes a,b` and wait for the owner's confirmation, then run `node ${CLAUDE_PLUGIN_ROOT}/scripts/init-specifics.cjs --root "${CLAUDE_PROJECT_DIR}" --lanes a,b`: only the missing lane files are created, an existing path is kept.
   - Write the answers (persona, paths and hint in the frontmatter, the owner's rules in the body, for example the iOS persona's rules moved into `sam.ios.md`) with Edit ONLY into a lane file that `--detect` lists in `laneFiles` with `pristine: true`; any other lane file is project-owned: print the proposed diff and write nothing.
   - A lane file with no text once its comments are stripped adds nothing: the SessionStart hook says so until the owner completes it. Commit and push the lane files to the base branch (specifics are read from `origin/<base>`).

## 3. GitHub snippets (optional, propose)
Propose (AskUserQuestion) inserting the snippets to enable pm_review + the acceptance gate:
- `${CLAUDE_PLUGIN_ROOT}/templates/github/feature-pm-review.snippet` → `pm_review` checkboxes block to add to `.github/ISSUE_TEMPLATE/feature.yml`.
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
