# Contributing to lgtmgate

Thanks for considering a contribution. This project is young and maintained by a single person, so
please be patient with review times — see [GOVERNANCE](#maintainers--decisions) below.

By participating, you're expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Before proposing a change, read [VISION.md](VISION.md) and [ARCHITECTURE.md](ARCHITECTURE.md); AI coding tools get the same
pointer from [AGENTS.md](AGENTS.md).

## Ways to contribute

- **Bug reports** — open an issue using the bug report template. Include your Claude Code version,
  the plugin version (`.claude-plugin/plugin.json`'s `version`, or the `buildStamp` from a run),
  your OS, and reproduction steps.
- **Feature requests** — open an issue using the feature request template. Explain the problem
  you're hitting before proposing a solution; this plugin is deliberately stack-agnostic, so
  proposals need to work for more than one project's conventions.
- **Pull requests** — for anything beyond a trivial fix, please open an issue first to discuss the
  approach. This plugin's core (`workflows/deliver-pipeline.js`, the agent prompts in `agents/`) is
  dense and interconnected; an early conversation saves everyone rework.

## Labels

File your issue with whatever label feels natural: `bug`, `enhancement`, `documentation`, or
GitHub's own suggestions. This project also runs a `type:`/`status:`/`priority:`/`exec:`/`size:`
taxonomy (`.claude/backlog.yml`) for its own triage automation, and a plain `bug` gets reconciled
to `type:bug` automatically, so you never need to learn that taxonomy just to file something.
`good first issue` and `help wanted` flag issues open to a first contribution.

## Requirements

- `git`
- [`gh` (GitHub CLI)](https://cli.github.com/), authenticated (`gh auth login`) — most of the
  plugin's hooks and scripts shell out to it.
- [`jq`](https://jqlang.github.io/jq/) — required by `hooks/block-merge-unchecked.sh` and
  `hooks/deny-destructive-git.sh` (PreToolUse gates on every Bash call); both fail closed
  (exit 2) if `jq` is missing.
- Node.js (no external npm packages — the JS side is stdlib-only).
- Python 3.9+ (no external pip packages — the `backlog` plugin is stdlib-only).
- Bash.

There is no package manager install step: no JS/Python package has a third-party dependency
(the JS side is stdlib-only, the `backlog` plugin's Python side is stdlib-only). System tools
(`git`, `gh`, `jq`) are still required — see above.

## Development loop

Never edit on `main` directly — work in a branch or a git worktree.

To run your edited copy of the pipeline **without publishing anything**, use `--plugin-dir`:

```bash
printf '%s' '<prompt>' | claude --print --model claude-sonnet-5 --plugin-dir <your-worktree> --allowed-tools Workflow
```

The prompt must arrive on stdin. See `MAINTAINING.md` for the full dev-loop details, including a
known collision hazard when a `--plugin-dir` tree and the installed plugin cache share a component
name — set a `-dev` suffixed version locally if you hit ambiguous results.

## Running the tests

All test suites are offline (no network, no API calls) and dependency-free:

```bash
bash templates/test-canonical-guards.sh      # this repo's own release/structure guard net
FLOW_SUITE_STRICT=1 node scripts/run-flow-suite.cjs   # offline simulation of the pipeline workflow (strict = CI mode)
bash templates/test-provision-worktree.sh    # worktree provisioning guard
bash hooks/test-Stop-supervise-runs.sh       # stale-run watchdog regression test
bash scripts/test-verify-workflow-launch.sh  # workflow-launch verification regression test
python3 -m unittest discover plugins/backlog/tests   # backlog plugin's own suite
```

These are exactly the checks CI (`.github/workflows/guards.yml`) runs on every pull request — run
them locally before opening a PR.

## Commit conventions

This repo uses [Conventional Commits](https://www.conventionalcommits.org/) (`fix:`, `feat:`,
`docs:`, `test:`, `chore:`, ...) referencing the issue/PR a change relates to, e.g.:

```
fix: correct staleness threshold default in supervision doctrine (legacy#123)
```

There is no `CHANGELOG.md` — `git log --oneline -- .claude-plugin/plugin.json` is the canonical,
always-current release history (see `MAINTAINING.md` §4).

## Opening a pull request

1. Fork the repo, branch from `main`.
2. Make your change, with tests where it makes sense, and run the suites above.
3. Open a PR against `main` using the pull request template. Fill in what changed and why, and how
   you tested it.
4. CI (`guards.yml`) runs automatically. Address any red check before requesting review.

Contributions are accepted under this project's license (see [LICENSE](LICENSE), MIT) — by
submitting a PR you agree your contribution is licensed under the same terms.

## Maintainers & decisions

This project currently has a single maintainer ([@Zigzag968](https://github.com/Zigzag968), see
[CODEOWNERS](CODEOWNERS)), who has final say on design direction and merges. As the contributor
base grows, this section will be expanded into a fuller governance model.
