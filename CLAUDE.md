# CLAUDE.md — working on lgtmgate itself

Runbook for the Lead (the session that changes this repo or dispatches its pipeline).
- Launching and supervising a run: `commands/deliver.md`.
- Direction, read by every agent: @VISION.md
- Constraints and their checks, one-way doors, declared exceptions: `ARCHITECTURE.md` (Sam and
  Morgan import it). Map and use cases that must keep working: `docs/codemap.md`, `docs/critical-paths.md`.

## Rules (they bind the Lead, Sam, Nick and Morgan alike)

- **R1, ratchet**: three counters never rise against `origin/main`. **R2, a bug is a fixture**: red on
  the base, green on the branch, or the issue stays open. **R3, one-way door**: a status, an `agent()`,
  a hook, a seam or `docs/critical-paths.md` in a plan stops the run for the maintainer.
  Each constraint and its check: `ARCHITECTURE.md`.
- A shortcut is a declared exception (`ARCHITECTURE.md`), never a silent one.
- Default to the smallest change that removes the cause class; go structural only when the code
  requires it.

## Merge

- Only through `scripts/lead-merge.sh`: every acceptance box checked with its proof (command +
  output) in the PR body. Never `--auto`, never a squash on a shared branch, never a rebase.
- After a merge on `main`, bring the other open PRs up to date (merge, not rebase) before merging.

## Escalation

- Capture first: copy the raw run data (`.pipeline/`) into a fixture before any decision on an
  `escalate` or `*-died` status, then decide.
- Every real escalation ends as a replayed fixture in CI.
