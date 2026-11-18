# Canary kit

Reproduces the step "Canary re-initialised from scratch" of MAINTAINING.md.

Two scenarios, run in order, A then B, without asking which one a consumer is in:

- Scenario A (update): a repository with an existing committed configuration and a newly installed plugin version (the case of real consumers). Update the plugin in the root checkout (`claude plugin update lgtmgate@zigzag-plugins-beta --scope local`), check the loaded version with `bash scripts/plugin-versions.sh`, and start a new session before any run. A `LOADED-CACHE` line means the old local install of the root checkout, inherited by its worktrees, is still loaded (observed: 1.5.5 loaded instead of 1.6.0-beta.3); run the update command above in the root checkout again, then recheck. Then run the step 4 proofs against it.
- Scenario B (fresh install): a repository without configuration. The committed configuration is deleted before `/lgtmgate:init`; steps 1-5 below are this scenario.

Trust: a clone in a folder Claude Code has never opened stops with `Workspace not trusted`. A human accepts the trust prompt once for that folder before any background session; worktrees inherit the trust of their root repository.

1. Fresh clone, no copy of the previous config: `git clone <canary repository url> "$TMPDIR/canary"`; work only in that clone.
2. Re-initialise it from scratch: delete the committed configuration, then run `/lgtmgate:init` in the clone, choose complete; commit and push on the base branch.
3. Add one path-scoped rule file: `.claude/lgtmgate/sam.<lane>.md` whose frontmatter holds `lane: <lane>` and `paths: ["<glob>"]`; add one context file (`.md`) and list it under `agentContext["*"]` in `.claude/pipeline.config.json`; commit and push.
4. First proof of the candidate, from the plugin checkout, against the clone:
   - `node scripts/template-drift.cjs --root "$TMPDIR/canary"`
   - `node scripts/config-check.cjs "$TMPDIR/canary/.claude/pipeline.config.json"`
   - `node scripts/runtime/agent-context.cjs --root "$TMPDIR/canary"`
5. Post the three outputs on the release issue, then start the canary run.
