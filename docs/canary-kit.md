# Canary kit

Reproduces the step "Canary re-initialised from scratch" of MAINTAINING.md.

1. Fresh clone, no copy of the previous config: `git clone <canary repository url> "$TMPDIR/canary"`; work only in that clone.
2. Re-initialise it from scratch: run `/lgtmgate:init` in the clone, choose complete; commit and push on the base branch.
3. Add one path-scoped rule file: `.claude/lgtmgate/sam.<lane>.md` whose frontmatter holds `lane: <lane>` and `paths: ["<glob>"]`; add one context file (`.md`) and list it under `agentContext["*"]` in `.claude/pipeline.config.json`; commit and push.
4. First proof of the candidate, from the plugin checkout, against the clone:
   - `node scripts/template-drift.cjs --root "$TMPDIR/canary"`
   - `node scripts/config-check.cjs "$TMPDIR/canary/.claude/pipeline.config.json"`
   - `node scripts/runtime/agent-context.cjs --root "$TMPDIR/canary"`
5. Post the three outputs on the release issue.
6. Start the canary run from the Lead session, from the plugin checkout (headless profile, `docs/headless.md`):
   - `bash scripts/canary-launch.sh --consumer "$TMPDIR/canary" --issue <n> --brief "<one line>" --out-dir <run-dir> --max-turns <n> --max-budget-usd <x>` (runs `scripts/canary-preflight.sh` first; the caps have no default).
   - Append one line `<ISO> <what>` to `<run-dir>/gestures.log` for each manual Lead gesture during the run; a line starting `[human-gate]` is the gesture a human box asks for and is not counted.
   - `bash scripts/canary-measure.sh <run-dir>` prints the record again; it ends `canary: PASS` or `canary: FAIL <cause>`. Link the record in the PR.
