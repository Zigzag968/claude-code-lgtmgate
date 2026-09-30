# Vision

The doctrine of this repo, for the agents and the humans who develop lgtmgate. Judge every plan and
every diff against it. Principles, invariants and their checks: `ARCHITECTURE.md`. Map: `docs/codemap.md`.

## Thesis
Humans read proofs, not diffs. LGTM Gate is the trust layer between coding agents and `main`:
nothing reaches `main` unless every acceptance item is proven by a command and its output.

## Who the product serves
The Product Engineer who has more ideas than they can code themselves, lets agents build, and must be
able to trust that those agents stay aligned with the product vision and the technical vision of the
repo. Installed in a repo, the gate plugs into that repo's own `VISION.md`, `ARCHITECTURE.md` and code
map when they exist, and holds its agents to the maintainer's intent.

## Target
- A labelled issue becomes a merge-ready PR whose every acceptance item is proven, on any GitHub repo.
- Every real incident becomes a replayed fixture; every closed cause class becomes a CI check; the
  same failure class never recurs.
- The merge ladder: today a human merges every PR. Next, the human merges on proofs alone, never on
  a diff. Target: a change class with a measured clean record merges on its own; humans act at
  one-way doors. Each step is earned by a measurement, never claimed.
- Cost per issue stays bounded because a script does every mechanical job and the model only
  judges; the Lead's progress table carries the tokens per PR that show it.

## Design decisions (do not re-propose the rejected options)
1. One gate to the world. Code executes, keeps the raw output, parses it and prints one line; the
   agent only copies that line; a hook attests the execution. Rejected: one model call per read or
   write, re-typing stdout.
2. One state registry. Every run outcome is a typed status; the Lead's table and the hooks are
   checked against it. Rejected: status strings scattered through the engine.
3. The checklist is data. Acceptance items carry ids, are rendered by the workflow and proven per
   id. Rejected: a Markdown checklist read by three parsers.

## How we work
- The patch is the default route. It becomes structural when it would cross an invariant.
- A shortcut is allowed at the margin, never in silence: a `DEBT` marker in the code, an open
  follow-up issue, an `exception:` line in the PR, and a human who accepts it at merge
  (format in `ARCHITECTURE.md`). Never for the three ratchet counters, an unproven item, a bug
  without its fixture, or a critical path.
- The planner names the proof, the developer makes it pass, the reviewer runs it.
- The critical paths of the product are declared in `docs/critical-paths.md`; each one has a passing
  test; an agent never edits that list without a human.
- Humans act at one-way doors and at merge. A script over a model for any mechanical job.

## Never
- An agent re-types what a command printed.
- Anything merges unproven.
- A rule without its check.
- A model adopts its own rules: a human adopts every invariant.
- A new agent role for a mechanical job.

## Out of scope
Forges other than GitHub. Multi-human roles and permissions.

## Evolution
Add a rule at its second occurrence, only with a check. Remove a rule that changed no result.
