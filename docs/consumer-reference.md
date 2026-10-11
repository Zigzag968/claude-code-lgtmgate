# Consumer reference

Every name a consumer can meet, with the remedy. A guard (`node scripts/guards.cjs`, rule `consumer-reference`) fails on a name the code emits that has neither a row here nor an entry in `scripts/consumer-reference-baseline.json`.

- A name is found by a pattern, per family: run reasons are the `reason:` strings of `workflows/deliver-pipeline.js`; assembler refusals are the `<name> at line` messages and `hit('<name>'` calls of `scripts/agent-context.cjs` and its two libraries; configuration keys are the `config.<key>` reads of the engine and of `readConfig` in the assembler; hook messages are the `echo`/`deny` lines of `hooks/*.sh`, named `<script>: <prefix>`.
- Limits: a name built at run time (`secret-${id}`) or carried by a helper object is not found; the pattern for assembler refusals also yields the junk name `at-line`, kept in the baseline as found.
- A name leaves the baseline when its row is written here; the baseline never grows.
- Columns: raised at (a file and a symbol, never a line number), what the user sees, remedy. Prerequisites have no pattern: their rows are only checked for a remedy.

## Configuration keys

| name | raised at | what the user sees | remedy |
|---|---|---|---|
| `agentContext` | `readConfig` of `scripts/agent-context.cjs` | `agentContext must be an object`, `agentContext: unknown role "<name>"` or `agentContext.<role>: must be an array of path strings`, and the assembler stops | Set `agentContext` in `.claude/pipeline.config.json` to an object whose keys are `*` or a role (Mia, Sam, Nick, Morgan, Theo) and whose values are arrays of repo paths. |
| `projectSpecifics` | `readConfig` of `scripts/agent-context.cjs` | `projectSpecifics must be a string`, or `projectSpecifics: <problem>` when the path is invalid | Set `projectSpecifics` to a repo-relative folder path (empty or absent turns the folder off). |
| `minPluginVersion` | `minPluginVersionVerdict` of `workflows/deliver-pipeline.js` | Optional. An unusable value throws `Invalid minPluginVersion: <value> (must be a version x.y.z, optionally with a -prerelease)`; an engine below it ends the run with `plugin-version-too-old` | Write a version such as `1.3.0` or `1.3.0-beta.20`, or remove the key; when the run stops, update the plugin and relaunch. |
| `planFreshness` | top of `workflows/deliver-pipeline.js` (`planFreshnessMode`) | Default `advisory`. A value outside `advisory`, `gate` and `off` throws `Invalid planFreshness: <value> (must be 'advisory' \| 'gate' \| 'off')` | Set `planFreshness` to `advisory`, `gate` or `off`, or remove the key. |
| `branchPrefix` | `branchPrefixConfigured` of `workflows/deliver-pipeline.js` | When unset or blank, the branch name falls back to the prefix `features/` and the log says `config.branchPrefix is not set` | Set `branchPrefix` in `.claude/pipeline.config.json` (for example `feat/`); a `branchPrefix` argument at launch is ignored. |
| `ciChecks` | `ciChecks` and `ciBlocker` of `workflows/deliver-pipeline.js` | Default `["build-and-test"]`. A name the PR head does not report stops the review with `config.ciChecks names check(s) not reported on the PR head: <names>` | Set `ciChecks` to the exact names of your CI checks, as the PR shows them. |
| `probeRunPath` | `probeCommands` of `workflows/deliver-pipeline.js` | With no `probeRunPath` and no plugin root, the probe fails with `no probe-run.cjs location: pass args.pluginRoot (absolute plugin root) or config.probeRunPath and relaunch` | Pass the plugin root when launching, or set `probeRunPath` to the path of `templates/probe-run.cjs`, then relaunch. |

## Assembler refusals

| name | raised at | what the user sees | remedy |
|---|---|---|---|
| `folder-absent` | `resolveFiles` of `scripts/agent-context.cjs` | `<folder>: folder-absent at line 0`: the `projectSpecifics` folder is not in the commit tree | Create the folder and commit it, or fix the `projectSpecifics` path. |
| `missing` | `byPath` of `scripts/agent-context.cjs` | `<path>: missing at line 0`: a file named in `agentContext` is not in the commit tree | Commit the file or fix its path in `agentContext`. |

## Run reasons

| name | raised at | what the user sees | remedy |
|---|---|---|---|
| `plugin-version-too-old` | `minPluginVersionVerdict` of `workflows/deliver-pipeline.js` | The run escalates before anything runs: the engine is below the `minPluginVersion` the repository asks for | Update the plugin (`claude plugin update <plugin>@<marketplace> --scope <scope>`), restart the session, relaunch. |
| `plugin-version-skew` | `pluginVersionVerdict` of `workflows/deliver-pipeline.js` | The run escalates before provisioning: the plugin root and the engine hold different versions | Pass the current plugin root and relaunch; when the engine is the older one, reload the session or refresh the local copy of the engine. |
| `plugin-version-unreadable` | `pluginVersionVerdict` of `workflows/deliver-pipeline.js` | The run escalates before provisioning: the version in the plugin root's `.claude-plugin/plugin.json` cannot be read | Pass the current plugin root and relaunch. |
| `session-root-mismatch` | `sessionRootVerdict` of `workflows/deliver-pipeline.js` | The run escalates before provisioning: the session root is not the repository of the run's worktree | Drive the repository from a session opened in it (restart the session after any instruction file changes), then relaunch. |
| `session-root-unreadable` | `sessionRootVerdict` of `workflows/deliver-pipeline.js` | The run escalates before provisioning: the check of the session root gave no usable answer | Pass `sessionRoot` as the absolute root of a session opened in the target repository, then relaunch. |
| `invalid-proceedThrough` | argument validation of `workflows/deliver-pipeline.js`, before Setup | The run escalates and nothing runs: `proceedThrough` is not `plan`, `dev`, `review` or absent | Relaunch with `proceedThrough` set to one of `plan`, `dev`, `review`, or leave it out. |

## Hook messages

| name | raised at | what the user sees | remedy |
|---|---|---|---|
| `block-merge-unchecked.sh: BLOCKED by pr-acceptance gate` | `hooks/block-merge-unchecked.sh` | A `gh pr merge` is refused: the PR acceptance checklist still has unchecked items | Prove and tick every box of the acceptance block, then merge again. |
| `block-merge-unchecked.sh: BLOCKED by review-stale gate` | `hooks/block-merge-unchecked.sh` | A `gh pr merge` is refused: the PR has no review marker carrying a head sha, or the head moved since the last review | Re-run the review on the current head, then merge again. |

## Prerequisites

| name | raised at | what the user sees | remedy |
|---|---|---|---|
| `jq` | `hooks/block-merge-unchecked.sh` and `hooks/deny-destructive-git.sh` | `jq is required` and the hook fails closed: a merge or a git command that could not be checked is refused | Install `jq` and make sure it is on `PATH`. |
| `gh` | the engine's GitHub reads and writes | Runs and merges fail on any GitHub call when `gh` is missing or not signed in | Install the GitHub CLI and run `gh auth login` (see the prerequisites in the README). |
