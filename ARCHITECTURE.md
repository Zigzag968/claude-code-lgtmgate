# Architecture
## Where the engine is going (6-12 months)
- One gate to the world: every read or write outside the engine runs through `templates/probe-run.cjs`; scripts execute, agents copy.
- One state registry: every run outcome is a typed status, and the Lead's table and the hooks are checked against it.
- The checklist is data: acceptance items carry ids, are rendered and ticked by the engine, proven per id.
- Repo-neutral: the engine knows no stack, path or rule of its own; each repo's config and docs say what matters there.
## Today
- The Lead runs `/lgtmgate:deliver`; the workflow drives Theo, Sam, Nick and Morgan in the issue's worktree and returns one status.
- The workflow runtime has no filesystem or shell: it only launches agents; every git, gh or file access runs as a script through a probe.
- Consumers receive the engine, `agents/`, `commands/`, `hooks/` and the init templates.
## Technical doctrine, ranked (the higher one wins a conflict)
1. Determinism over judgment: a script does the mechanical work; a model only judges.
2. Proof over trust: every claim is a command output or an artifact; an engine bug ships with a replayed fixture.
3. Ratchet over thresholds: model calls outside `callAgent`, `simulate.*` seams and regex parsers never increase.
4. Root cause over patch: the smallest change that removes the cause class; a shortcut is a declared `DEBT(#N)` exception.
## One-way doors (the run stops for the maintainer)
- A new status, agent call, hook or seam (`oneWayDoorKinds`), or a change to a path listed in `oneWayDoorPaths`.
## How agents use this
- Sam plans toward the destination and names the doctrine line he trades off; Morgan blocks only on what the CI checks.
- Checks: `node scripts/guards.cjs` and `bash templates/test-canonical-guards.sh`; a failure names its rule.
