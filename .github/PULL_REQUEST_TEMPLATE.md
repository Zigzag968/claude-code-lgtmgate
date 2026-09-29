## What this changes

<!-- What does this PR do, and why? Link the issue it addresses. -->

Closes #

## How this was tested

<!-- Which of the offline test suites did you run? Any manual verification? -->

- [ ] `bash templates/test-canonical-guards.sh`
- [ ] `node scripts/run-flow-suite.cjs`
- [ ] `bash templates/test-provision-worktree.sh` (if relevant to your change)
- [ ] `python3 -m unittest discover plugins/backlog/tests` (if touching `plugins/backlog/`)

## Checklist

- [ ] Docs updated if behavior or config changed (`README.md`, `MAINTAINING.md`, or the relevant `agents/*.md`)
- [ ] No new third-party dependency introduced (this repo is stdlib-only, by design)
