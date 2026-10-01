# Vision

Target: a labelled issue becomes a merge-ready PR whose every acceptance item is proven by a command and its output, on any GitHub repo.

## Never (R1 ratchet: `scripts/guards.cjs` counts each one against `origin/main`)
- A new `await agent(` outside `callAgent`.
- A new `simulate.*` seam key.
- A new regex on agent output outside the `// guards:parser-begin` / `// guards:parser-end` markers.

## Where new code goes
- A probe or a shell side effect: `templates/probe-run.cjs` (executes, keeps the raw output, prints one line).
- A new run outcome: `finish({ status })` plus its row in the status table of `commands/deliver.md` (one-way door).
- A new check on a PR: an acceptance item in the plan's checklist (`acceptanceChecklist`; target: `acceptanceItems` with ids).

## Design decisions (do not re-propose the rejected options)
1. One gate to the world. Code executes, keeps the raw output, parses it and prints one line; the agent only copies that line; a hook attests the execution. Rejected: one model call per read or write, re-typing stdout.
2. One state registry. Every run outcome is a typed status; the Lead's table and the hooks are checked against it. Rejected: status strings scattered through the engine.
3. The checklist is data. Acceptance items carry ids, are rendered by the workflow and proven per id. Rejected: a Markdown checklist read by three parsers.

Sam's mandate: smallest change that removes the cause class; never a `simulate.*` seam; say in the plan if the diff adds a status, an `agent()`, a hook or a seam.
