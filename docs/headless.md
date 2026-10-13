# Headless delivery profile

An unattended `claude -p` session runs with no one to answer a permission prompt. The profile makes every
tool outside an exact allow list a denial instead of a prompt, caps the run, and never bypasses permissions.

## Run it

```
printf '%s' '<prompt>' | bash scripts/run-workflow-headless.sh --max-turns 40 --max-budget-usd 5 --out <path>
```

- The wrapper assembles `--permission-mode dontAsk --permission-prompts none --max-turns N --max-budget-usd X --settings scripts/headless-settings.json`.
- The allow list lives in `scripts/headless-settings.json` only (`--settings <file>` swaps it).
- It refuses (exit 2, cause on stderr, trailer `status=error`): `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, any `--permission-mode`, a settings file naming a bypass mode, a missing settings file, a missing or non-numeric cap.
- It prints `[wf-headless] stream-log=<path>` first and the trailer `[wf-headless] status=<ok|no-result|error> out=<path>` last.
- Success is judged from the workflow `output_file`, never from the exit code (a denial exits 0, see E2).
- To measure a profile apart from the maintainer's user settings, run `claude` with `--setting-sources project`.

## Experiments (Claude Code 2.1.296)

Run by the Lead from empty scratch directories, each with `--max-turns 3` and a budget cap. Not rerun by the PR author.

| Exp | Command run | Output observed |
|---|---|---|
| E1 gh in the sandbox | `claude -p "run exactly: gh api rate_limit --jq .resources.core.remaining; report the output" --permission-mode dontAsk --allowedTools "Bash(gh *)" --settings VARIANT --max-turns 3 --max-budget-usd 0.30 --output-format json` with VARIANT = (c) `{"sandbox":{"enabled":true}}` / (a) `{"sandbox":{"enabled":true,"enableWeakerNetworkIsolation":true}}` / (b) `{"sandbox":{"enabled":true,"excludedCommands":["gh *"]}}` | All three: exit 0, is_error false, num_turns 2, permission_denials [], result `5000`. The three postures behave the same: E1 does not tell them apart. |
| E2 dontAsk denial | `claude -p "Write probe.txt with content x" --setting-sources project --permission-mode dontAsk --permission-prompts none --output-format json --max-turns 3 --max-budget-usd 0.20` (also with a `curl` prompt) | exit 0, is_error false, subtype success, permission_denials [{tool_name Write, file_path probe.txt, content x}], `ls probe.txt` gives No such file. The curl run: permission_denials [{tool_name Bash, ...curl...}]. `--max-turns` is honoured: runs stopped at num_turns 2 under a cap of 3. Without `--setting-sources project`, the user-level allow rules masked the profile (Write, uname and curl all allowed): not a valid measure. |
| E3 doctor on settings | `claude doctor` run in a scratch directory holding `.claude/settings.json` with `{"sandbox":{"enabled":true,"allowUnsandboxedCommands":false}}` then with `"allowUnsandboxedCommands":"false"` | Boolean: no settings error reported. String: `Invalid settings - .claude/settings.json > sandbox.allowUnsandboxedCommands: Expected boolean, but received string`. The key must be a boolean. |

Deviation on E3: `claude doctor --settings '<json>'` fails (`error: unknown option '--settings'`), so each candidate was written as `.claude/settings.json` in a scratch directory and `claude doctor` ran there.

## Decision for the maintainer (ac:4): sandbox posture for gh

| Posture | Setting | E1 result | Note |
|---|---|---|---|
| Control | `{"sandbox":{"enabled":true}}` | gh reached GitHub (`5000`) | the call was REST (`rate_limit`), not GraphQL, and ran from an empty scratch directory |
| Weaker isolation | `enableWeakerNetworkIsolation: true` | gh reached GitHub (`5000`) | not shown to be needed by E1 |
| Excluded commands | `excludedCommands: ["gh *"]` | gh reached GitHub (`5000`) | matches the call text only; the engine runs gh through `templates/probe-run.cjs` |
| Linux runner | none | not measured | no macOS sandbox TLS limit |

E1 does not discriminate, so `scripts/headless-settings.json` ships no weaker-isolation or excluded-commands key. The maintainer picks the posture; the shipped file is amended in the same PR if the pick differs.

## Known traps

- A workflow launched mid-turn can relay a stale human message to each `agent()` (anthropics/claude-code#96640): launch it as the first tool call of a turn.
- A denial can exit 0 with subtype success (anthropics/claude-code#76867): read `permission_denials` and assert the side effect.
- A settings file with a wrongly typed key can be dropped whole: run `claude doctor` on it (E3).
- A hook answering `ask` counts as a denial in `dontAsk` mode.
- In `-p`, a background task wait is bounded by `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`.
- Not tested yet: plugin agents under `dontAsk`, and whether an untrusted workspace silently drops `permissions.allow` (single source). Nothing here claims either.
