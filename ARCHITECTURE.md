# Architecture
## Where the engine is going (6-12 months)
- One gate to the world: every read or write outside the engine runs through `templates/probe-run.cjs`, bar the Lead copy of specifics, checked by digest.
- One state registry: every run outcome is a typed status, and the Lead's table and the hooks are checked against it.
- The checklist is data: acceptance items carry ids, are rendered and ticked by the engine, proven per id.
- Repo-neutral: the engine knows no stack, path or rule of its own; each repo's config and docs say what matters there.
## Today
- The Lead runs `/lgtmgate:deliver` (four agents, issue's worktree, one status); consumers get the engine, `agents/`, `commands/`, `hooks/` and init templates.
- The workflow has no filesystem or shell: it launches agents; git, gh and file reads run as scripts, via a probe or a Lead copy checked by digest.
## Technical doctrine, ranked (the higher one wins a conflict)
1. Determinism over judgment: a script does the mechanical work; a model only judges.
2. Proof over trust: every claim is a command output or an artifact; an engine bug ships with a replayed fixture.
3. Ratchet over thresholds: model calls outside `callAgent`, `simulate.*` seams and regex parsers never increase.
4. Root cause over patch: the smallest change that removes the cause class; a shortcut is a declared `DEBT(#N)` exception.
5. Fit over foresight: build what the issue needs, for every valid input, clean and tested; nothing speculative, never a shortcut that only passes the example.
## One-way doors (the run stops for the maintainer)
- A new status, agent call, hook or seam (`oneWayDoorKinds`), or a change to a path listed in `oneWayDoorPaths`.
## How agents use this
- Sam plans toward the destination and names the doctrine line he trades off; Morgan blocks on the checklist, CI, repo conventions and regression guard.
- Checks: `node scripts/guards.cjs` and `bash templates/test-canonical-guards.sh`; a failure names its rule.
