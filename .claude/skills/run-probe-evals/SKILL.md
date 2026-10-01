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
  - `CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s lgtmgate-eval-token -w)" docker run --rm --security-opt seccomp=unconfined --security-opt systempaths=unconfined -e CLAUDE_CODE_OAUTH_TOKEN -e EVAL_PLUGIN_ROOT=/workspace -v "$PWD:/workspace" -v /tmp/claude/evaltmp-x:/tmp -v /tmp/claude/evalres-x:/evalres -w /workspace lgtmgate-probe-evals claude plugin eval . --case probe-provision --runs 1 --keep-temp --max-cost-usd 3 --no-publish --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir /evalres`
- Trace: `/tmp/claude/evaltmp-x/claude-eval-*/out/trace.jsonl` (one JSON event per line).
  - First `chmod 700` the `claude-eval-*` dir and its `sealed/` subdir.
  - Read the Bash `tool_result` of the probe agent and the last assistant message.
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
- Score meaning: 3 graders weighted 1 each (agent-dispatched, bash-called, probe-line).
  - 0.67 = the PROBE line is missing or mangled in the final message (the regex grader failed).
  - 0.33 = the agent was never dispatched or never ran Bash, plus the regex miss.
  - Threshold is 0.95 per case over 10 runs.
