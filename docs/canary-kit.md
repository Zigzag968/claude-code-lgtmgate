# Canary kit

Reproduces the step "Canary re-initialised from scratch" of MAINTAINING.md.

1. Fresh clone, no copy of the previous config: `git clone <canary repository url> "$TMPDIR/canary"`; work only in that clone.
2. Re-initialise it from scratch: run `/lgtmgate:init` in the clone, choose complete; commit and push on the base branch.
3. Add one path-scoped rule file: `.claude/lgtmgate/sam.<lane>.md` whose frontmatter holds `lane: <lane>` and `paths: ["<glob>"]`; add one context file (`.md`) and list it under `agentContext["*"]` in `.claude/pipeline.config.json`; commit and push.
4. First proof of the candidate, from the plugin checkout, against the clone:
   - `node scripts/template-drift.cjs --root "$TMPDIR/canary"`
   - `node scripts/config-check.cjs "$TMPDIR/canary/.claude/pipeline.config.json"`
   - `node scripts/agent-context.cjs --root "$TMPDIR/canary"`
5. Post the three outputs on the release issue, then start the canary run.
