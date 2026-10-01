---
name: run-probe-evals
description: Run or debug the probe evals of issue #81 (`claude plugin eval` on evals/probe-*, in Docker, score must be >= 0.95). Use when the probe layer changed, at the E2 gate, or when a probe eval case scores below 1.00.
---

# Run the probe evals (#81)

## Prerequisites
- Docker running (the evals cannot run on the macOS host: anthropics/claude-code#94308).
- Keychain item `lgtmgate-eval-token`, holding a token from `claude setup-token`.
  - Create it: `claude setup-token`, then `security add-generic-password -a "$USER" -s lgtmgate-eval-token -T /usr/bin/security -w` (prompts for the token).
  - Over SSH: `security unlock-keychain` first.
- Never print, echo, log or write the token.

## Run everything (3 cases, 10 runs each, capped at $3 per case)
- `CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s lgtmgate-eval-token -w)" bash scripts/run-probe-evals-docker.sh`
- Optional case names after the script restrict the run, e.g. `... run-probe-evals-docker.sh probe-provision`.
- Needs the Bash sandbox disabled when launched from a Claude session (Docker and Keychain).
- The cost shown is an estimate: it draws on the subscription quota, nothing is billed.

## Debug one case
- Same `docker run` as the script, plus `--runs 1 --keep-temp`, and a mount on `/tmp` to keep the trace:
  - `mkdir -p /tmp/claude/evaltmp-x /tmp/claude/evalres-x`
  - `CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s lgtmgate-eval-token -w)" docker run --rm --init --security-opt seccomp=unconfined --security-opt systempaths=unconfined -e CLAUDE_CODE_OAUTH_TOKEN -e EVAL_PLUGIN_ROOT=/workspace -v "$PWD:/workspace" -v /tmp/claude/evaltmp-x:/tmp -v /tmp/claude/evalres-x:/evalres -w /workspace lgtmgate-probe-evals claude plugin eval . --case probe-provision --runs 1 --keep-temp --max-cost-usd 3 --no-publish --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir /evalres`
- Trace: `/tmp/claude/evaltmp-x/claude-eval-*/out/trace.jsonl` (one JSON event per line).
  - First `chmod 700` the `claude-eval-*` dir and its `sealed/` subdir.
  - Read the Bash `tool_result` of the probe agent (the trace carries the subagent's tool calls and results, tagged `parent_tool_use_id`) and the last assistant message.
- HTML report: `/tmp/claude/evalres-x/report.html`.

## How a case finds the plugin
- A run gets an allowlisted environment only: `CLAUDE_PLUGIN_ROOT` is NOT exported to subagent Bash, but `EVAL_*` variables pass (doc: https://code.claude.com/docs/en/plugin-evals, `env` field).
- `scripts/run-probe-evals.sh` exports `EVAL_PLUGIN_ROOT`; the case prompts call `$EVAL_PLUGIN_ROOT/templates/probe-run.cjs`.
- Each prompt gives the probe agent TWO commands (run, then `--verify`): the `SubagentStop-probe.sh` hook refuses to stop the agent without an attested PROBE and VERIFY pair.

## Known pitfalls
- `bwrap: Can't mount proc on /newroot/proc: Operation not permitted`: Docker masks /proc. Fix: `--security-opt systempaths=unconfined` (next to `seccomp=unconfined`); bubblewrap#284.
- `401 Invalid bearer token`: the token was pasted broken across lines. Re-add it to the Keychain on one line.
- `401 OAuth access token is invalid`: the token was revoked. Run `claude setup-token` and replace the Keychain item.
- Eval refused on the macOS host (#94308): use the Docker wrapper, never the bare script.
- `Cannot find module '/templates/probe-run.cjs'`: a prompt still uses `$CLAUDE_PLUGIN_ROOT`; use `$EVAL_PLUGIN_ROOT`.
- The probe agent answers "I need two commands": the prompt gives only the run command; add the `--verify` command.
- Score meaning: 4 graders weighted 1 each, so 0.25 per grader (agent-dispatched, bash-called, probe-line, verify-ok).
  - `probe-line` pins the WHOLE expected PROBE line (sha, cmd, json) and must match the whole final message: one flipped hex char, a paraphrase, an invented line, prose or a code fence around it fails.
  - `verify-ok` looks in the trace for `VERIFY ok line=PROBE name=<name> exit=0 sha=<pinned sha>` inside a Bash `tool_result`: it proves the commands really ran and exited 0.
  - 0.75 = one regex grader failed:
    - `probe-line` only: the final message is not exactly the PROBE line (the relay added prose or altered a char).
    - `verify-ok` only: the VERIFY line is absent from the Bash results (verify failed, or the trace shape changed).
  - 0.50 = both regex graders failed: the command did not run or failed (e.g. `Cannot find module`) and the model answered anyway.
  - 0.00 = the agent was never dispatched, so nothing ran.
  - Threshold is 0.95 per case over 10 runs.
- The pinned lines are constants: the case commands are fixed, so `sha`, `cmd` and `json` never vary (checked twice offline).
  - If a case command or `templates/probe-run.cjs` output changes, regenerate its two graders; `scripts/test-probe-evals.sh` fails until the pinned line equals the real one.
