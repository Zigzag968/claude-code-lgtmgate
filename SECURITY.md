# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities using **GitHub's private vulnerability reporting**, not a
public issue:

1. Go to the [Security tab](../../security/advisories) of this repository.
2. Click **"Report a vulnerability"**.
3. Describe the issue, its impact, and steps to reproduce.

This opens a private advisory visible only to the maintainer and you, so the issue isn't disclosed
before a fix ships. If private reporting isn't enabled yet on this repository, open a regular issue
with as few exploit details as possible and ask for a private channel.

We don't currently have a bug bounty program. We'll credit reporters in the fix's release notes
unless you ask not to be named.

## Threat model: this is an agent orchestrator, not a passive library

`lgtmgate` gives Claude Code agents the ability to run shell commands, write files, open pull
requests, and (per your `pipeline.config.json`) merge or push in some workflows. That's a materially
different risk profile than installing a typical dependency, and it's worth understanding before you
install it on a repository with anything sensitive in it:

- **`.claude/pipeline.config.json` is trusted-operator input, not inert data.** Several config keys
  — `commands.{build,test,format}`, `regressionGuard.baselineCmd`, `baseBranch`, `branchPrefix`,
  `preflight.envNote`, `stack` — are interpolated **unescaped** into text an agent is instructed to
  run or treat as authoritative. The only key that's validated in code is `provision.extraLinks`
  (path/metacharacter guard). **Practically: a pull request that only touches
  `pipeline.config.json` is a code-review surface, not a docs change** — review it with the same
  scrutiny you'd give a change to the workflow script itself. Never merge a config change from an
  untrusted source without reading exactly what it sets.
- **Agents run with the permissions of the session that invokes them.** The plugin's own hooks deny
  a few specific destructive patterns (see `hooks/plugin-hooks.json` and
  `hooks/block-merge-unchecked.sh`), but that is a safety net for the *intended* use of this plugin,
  not a sandbox against a malicious config or a malicious prompt injected through issue/PR content
  the agents read.
- **This plugin never merges its own publish PR, and neither should any automation you build on
  it for your own repos** — Nick and Morgan never merge, in this codebase or in yours. Merging is
  the Lead orchestrating the run, not one of the pipeline's worker agents. If you build unattended
  automation on top of `lgtmgate` (a scheduled runner, etc.), keep that boundary: let agents
  prepare and open PRs, and if the Lead itself merges unattended, that's a deliberate choice you
  made and are accountable for, not something this plugin's own agents will ever do on their own.
- **CI implications**: this repository's own CI (`.github/workflows/guards.yml`) executes
  branch-authored code by design (see the workflow's header comment) and therefore triggers only on
  `pull_request`, never `pull_request_target` — if you fork this plugin or adapt its CI pattern,
  preserve that distinction; using `pull_request_target` with untrusted branch code would leak your
  base branch's secrets to it.

If you find a way to make an agent take an action outside what its prompt and your config
authorized — a prompt-injection bypass of the acceptance-checklist gate, a way to make Nick or Sam
write outside the worktree, a way to make the `pull_request` CI job exfiltrate secrets it shouldn't
have — that's exactly what we want reported privately.

## Supported versions

This project ships as a single rolling Claude Code plugin version (see
`.claude-plugin/plugin.json`); there are no maintained older release branches. Fixes land on the
latest version — update via `claude plugin update lgtmgate` (or `backlog`) to get them.
