# CLAUDE.md — working on lgtmgate itself

Runbook for the Lead (the session that changes this repo or dispatches its pipeline).
- Launching and supervising a run: `commands/deliver.md`.
- Direction: `VISION.md` (target, directives, out of scope); code map and invariants: `ARCHITECTURE.md`.

## Three rules (they bind the Lead, Sam, Nick and Morgan alike)

- **R1, ratchet**: three counters never go up against `origin/main`: `await agent(` outside
  `callAgent`, `simulate.*` seam keys, regex parsing of agent output outside markers.
- **R2, a bug is a fixture**: an engine bug is fixed with a raw fixture replayed red on the base and
  green on the branch; without it the issue stays open.
- **R3, one raw stop signal**: a diff that adds a status, an `agent()` call, a hook or a seam stops
  at the design step and goes to the maintainer.

Default to the smallest change that removes the cause class; go structural only when the code
requires it.

## Merge

- Only through `scripts/lead-merge.sh` once it exists (#74). Until then: every acceptance box
  checked with its proof (command + output) in the PR body, then `gh pr merge <N> --merge` in a
  separate call. Never `--auto`, never a squash on a shared branch, never a rebase.
- After a merge on `main`, bring the other open PRs up to date (merge, not rebase) before merging.

## Escalation

- Capture first: copy the raw run data (`.pipeline/`) into a fixture before any decision on an
  `escalate` or `*-died` status, then decide.
- Every real escalation ends as a replayed fixture in CI.
