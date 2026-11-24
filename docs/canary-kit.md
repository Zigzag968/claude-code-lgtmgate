# Canary kit

Reproduces the step "Canary re-initialised from scratch" of MAINTAINING.md.

Two scenarios, run in order, A then B, without asking which one a consumer is in:

- Scenario A (update): a repository with an existing committed configuration and a newly installed plugin version (the case of real consumers). It runs in the canary checkout that the maintainer opened once (never a fresh clone). Update the plugin in that checkout (`claude plugin update lgtmgate@zigzag-plugins-beta --scope local`), check the loaded version with `bash scripts/plugin-versions.sh`, and start a new session before any run. A `LOADED-CACHE` line means the old local install of the root checkout, inherited by its worktrees, is still loaded (observed: 1.5.5 loaded instead of 1.6.0-beta.3); run the update command above in the root checkout again, then recheck. Then run the step 4 proofs against it.
- Scenario B (fresh install): a repository without configuration. The committed configuration is deleted before `/lgtmgate:init`; steps 1-5 below are this scenario. It runs in place in a dedicated folder that is already trusted (`<scenario B folder>`), the existing clone: nothing is emptied or deleted. Owner decision, 2026-11-18: "Oui, B en place, et runbook corrigé".

Trust: a clone in a folder Claude Code has never opened stops with `Workspace not trusted`. A human accepts the trust prompt once for that folder before any background session; worktrees inherit the trust of their root repository. A fresh clone anywhere else than the two fixed locations needs that trust gesture of a human (Claude Code ties trust to the path). The two locations: scenario A = the canary checkout the maintainer opened once (never a fresh clone); scenario B = the dedicated trusted folder, used in place for each release.

1. Work in place in `<scenario B folder>`; bring it to the release candidate with `git fetch origin` then `git merge --ff-only origin/<base branch>` (no rebase, no reset); work only in that checkout.
2. Re-initialise it from scratch: delete the committed configuration, then run `/lgtmgate:init` in the clone, choose complete; commit and push on the base branch.
3. Add one path-scoped rule file: `.claude/lgtmgate/sam.<lane>.md` whose frontmatter holds `lane: <lane>` and `paths: ["<glob>"]`; add one context file (`.md`) and list it under `agentContext["*"]` in `.claude/pipeline.config.json`; commit and push.
4. First proof of the candidate, from the plugin checkout, against the clone:
   - `node scripts/template-drift.cjs --root "<scenario B folder>"`
   - `node scripts/config-check.cjs "<scenario B folder>/.claude/pipeline.config.json"`
   - `node scripts/runtime/agent-context.cjs --root "<scenario B folder>"`
5. Post the three outputs on the release issue, then start the canary run.

## Findings of the 1.6.0-beta.9 canary runs

- Scenario B ran on a branch of the canary repository with the base overridden: the worktree is created from `origin/<branch>` before `claude -w issue-<N>`.
- Stable channel: disable the stable plugin at the local scope before `/lgtmgate:init`, then check the loaded version.
- Init answers: language English; test policy "every tested behaviour" (from `docs/canary-context.md`); forbidden actions: no value without a founded reason; branch protection: not protected; configuration taken over unchanged.
- Friction seen during init: `1 userConfig option not yet set`.
- Cause of both stopped runs of 2026-11-18: `Workspace not trusted` in a never-opened folder, which the fixed locations above remove.
