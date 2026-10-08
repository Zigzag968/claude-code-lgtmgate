# CLAUDE.md — working on lgtmgate itself

@VISION.md
@ARCHITECTURE.md

Runbook for the Lead (the session that changes this repo or dispatches its pipeline).
- Launching and supervising a run: `commands/deliver.md`.
- Where files go: docs/layout.md.
- Default to the smallest change that removes the cause class; a shortcut is a declared exception, never a silent one.
- A rule enters at its second occurrence, with its check; one that changed no result over 20 PRs is reviewed for removal.

## Merge

- Only through `scripts/lead-merge.sh`: every acceptance box checked with its proof (command +
  output, or the artifact) in the PR body. Never `--auto`, never a squash on a shared branch, never a rebase.
- After a merge on `main`, bring the other open PRs up to date (merge, not rebase) before merging.

## Escalation

- Capture first: copy the raw run data (`.pipeline/`) into a fixture before any decision on an
  `escalate` or `*-died` status, then decide.
- Every real escalation ends as a replayed fixture in CI.
- An escalation that trades off a `VISION.md` principle names it.
