---
name: run-probe-evals
description: Run or debug the probe evals of issue #81 (`claude plugin eval` on evals/probe-*, in Docker; the gate is at least 29 of 30 runs fully passed, a 0.95 mean is not enough). Use when the probe layer changed, at the E2 gate, or when a probe eval case scores below 1.00.
---

# Run the probe evals (#81)

## Prerequisites
- Docker running (the evals cannot run on the macOS host: anthropics/claude-code#94308).
- Keychain item `lgtmgate-eval-token`, holding a token from `claude setup-token`.
  - Create it: `claude setup-token`, then `security add-generic-password -a "$USER" -s lgtmgate-eval-token -T /usr/bin/security -w` (prompts for the token).
  - Over SSH: `security unlock-keychain` first.
- Never print, echo, log or write the token, and never export it in the Lead's shell: the wrapper reads the Keychain item itself and hands it to the container environment only.
- Check the prerequisites in under 10 s: `bash scripts/eval-preflight.sh docker` (names the failing one: docker, daemon, Keychain item).
- One-time gesture, maintainer-owned (this repo never edits the maintainer's settings): add a permission allow rule for `bash scripts/run-probe-evals-docker.sh` and exclude that command from the Bash sandbox, so the Lead can launch it without ever holding the credential.

## Run everything (3 cases, 10 runs each, capped at $3 per case)
- `bash scripts/run-probe-evals-docker.sh`
- Optional case names after the script restrict the run, e.g. `... run-probe-evals-docker.sh probe-provision`.
  - A restricted run is gated on its own runs (95 % of 10 per case); only the full 3-case run is the E2 gate.
- Docker and Keychain need the Bash sandbox disabled when launched from a Claude session. In a supervised session that needs the maintainer's explicit approval for that command. An unsupervised session must stop and report the blocker, never disable the sandbox (`.claude/rules/pr-acceptance.md`, section "Autonomy in unsupervised sessions").
- The runner takes the OAuth token only (no API key); the repo is mounted read-only, only `evals/results` is writable.
- The cost shown is an estimate: it draws on the subscription quota, nothing is billed.

## The gate
- Gate: at least 29 of the 30 runs (3 cases x 10) FULLY passed, i.e. score 1.00 on all 4 graders; every case must have its 10 runs.
- `scripts/run-probe-evals.sh` ends with `scripts/probe-eval-gate.sh`, which prints `<case>: <k>/<n> runs fully passed` per case, then `gate: <K>/<N> fully passed runs (need >= 29/30) -> PASS|FAIL`, and exits non-zero on FAIL or on a missing or unreadable `evals/results/<case>/aggregate-result.json`.
- A case mean of 0.95 is NOT enough: two runs at 0.75 (a corrupted PROBE line each) average 0.95 and pass `claude plugin eval --threshold 0.95`, yet only 28/30 runs fully passed. The `claude exit=` line the runner prints comes from that mean threshold and is informational.
- The run also writes `evals/results/eval-summary.json`: the content digest of `evals/ templates/ hooks/ agents/ scripts/` plus the gate verdict. Nothing is written when the tree changed during the run.
- To share the result across checkouts, the Lead copies it to `docs/gate/e2-eval.json` and commits it; `scripts/gate-check.sh e2` reads it when there is no local results dir. `node scripts/eval-digest.cjs --check <file>` prints `fresh` or `stale` (a merge of the base branch that touches none of those paths keeps it fresh).
- Re-check a past run without paying: `bash scripts/probe-eval-gate.sh evals/results` (results are local, git-ignored).
- The runner deletes each case's previous `aggregate-result.json` first, so an aborted run cannot be gated on an older pass.

## Pinned CLI version
- `.devcontainer/package.json` pins the CLI to `2.1.294`, its lockfile carries the integrity hash, and the Dockerfile and the `smoke-install` job install it with `npm ci`: the `verify-ok` grader depends on that version's trace format, and the gate on its `aggregate-result.json` shape.
- Bumping it: change the manifest, regenerate the lockfile (`npm install --package-lock-only --prefix .devcontainer`) and this note, rerun the whole suite (30 runs) and re-check the pinned graders against the new trace. `tests/scripts/test-probe-evals.sh` fails if the manifest, the lockfile and this note disagree.

## Debug one case
- Same `docker run` as the script, plus `--runs 1 --keep-temp`, and a mount on `/tmp` to keep the trace:
  - `mkdir -p /tmp/claude/evaltmp-x /tmp/claude/evalres-x`
  - The token is passed only by a Keychain-reading one-liner run by the maintainer (`security find-generic-password -s lgtmgate-eval-token -w` as a prefix assignment of `CLAUDE_CODE_OAUTH_TOKEN`), never by the Lead: `docker run --rm --init --security-opt seccomp=unconfined --security-opt systempaths=unconfined -e CLAUDE_CODE_OAUTH_TOKEN -e EVAL_PLUGIN_ROOT=/workspace -v "$PWD:/workspace" -v /tmp/claude/evaltmp-x:/tmp -v /tmp/claude/evalres-x:/evalres -w /workspace lgtmgate-probe-evals claude plugin eval . --case probe-provision --runs 1 --keep-temp --max-cost-usd 3 --no-publish --allow-tools Bash --ablation none --threshold 0.95 --trust-plugin --output-dir /evalres`
- Trace: `/tmp/claude/evaltmp-x/claude-eval-*/out/trace.jsonl` (one JSON event per line).
  - First `chmod 700` the `claude-eval-*` dir and its `sealed/` subdir.
  - Read the Bash `tool_result` of the probe agent (the trace carries the subagent's tool calls and results, tagged `parent_tool_use_id`) and the last assistant message.
- HTML report: `/tmp/claude/evalres-x/report.html`.

## How a case finds the plugin
- A run gets an allowlisted environment only: `CLAUDE_PLUGIN_ROOT` is NOT exported to subagent Bash, but `EVAL_*` variables pass (doc: https://code.claude.com/docs/en/plugin-evals, `env` field).
- `scripts/run-probe-evals.sh` exports `EVAL_PLUGIN_ROOT`; the case prompts call `$EVAL_PLUGIN_ROOT/scripts/runtime/probe-run.cjs`.
- Each prompt gives the probe agent TWO commands (run, then `--verify`): the `SubagentStop-probe.sh` hook refuses to stop the agent without an attested PROBE and VERIFY pair.

## Known pitfalls
- `bwrap: Can't mount proc on /newroot/proc: Operation not permitted`: Docker masks /proc. Fix: `--security-opt systempaths=unconfined` (next to `seccomp=unconfined`); bubblewrap#284.
- `401 Invalid bearer token`: the token was pasted broken across lines. Re-add it to the Keychain on one line.
- `401 OAuth access token is invalid`: the token was revoked. Run `claude setup-token` and replace the Keychain item.
- Eval refused on the macOS host (#94308): use the Docker wrapper, never the bare script.
- `eval-not-runnable` (exit 3) / `eval-preflight: ...`: a host refusal or a missing prerequisite, not a probe result. Follow its `Fix:` line; it never counts toward the gate.
- `Cannot find module '/scripts/runtime/probe-run.cjs'`: a prompt still uses `$CLAUDE_PLUGIN_ROOT`; use `$EVAL_PLUGIN_ROOT`.
- The probe agent answers "I need two commands": the prompt gives only the run command; add the `--verify` command.
- Score meaning: 4 graders weighted 1 each, so 0.25 per grader (agent-dispatched, bash-called, probe-line, verify-ok).
  - `probe-line` pins the WHOLE expected PROBE line (sha, cmd, json) and must match the whole final message: one flipped hex char, a paraphrase, an invented line, prose or a code fence around it fails.
  - `verify-ok` looks in the trace for `VERIFY ok line=PROBE name=<name> exit=0 sha=<pinned sha>` inside a Bash `tool_result`: it proves the commands really ran and exited 0.
  - 0.75 = one regex grader failed:
    - `probe-line` only: the final message is not exactly the PROBE line (the relay added prose or altered a char).
    - `verify-ok` only: the VERIFY line is absent from the Bash results (verify failed, or the trace shape changed).
  - 0.50 = both regex graders failed: the command did not run or failed (e.g. `Cannot find module`) and the model answered anyway.
  - 0.00 = the agent was never dispatched, so nothing ran.
  - The gate is not a score threshold: it counts fully passed runs (1.00 each), at least 29 of 30 (see The gate).
- The pinned lines are constants: the case commands are fixed, so `sha`, `cmd` and `json` never vary (checked twice offline).
  - If a case command or `scripts/runtime/probe-run.cjs` output changes, regenerate its two graders; `tests/scripts/test-probe-evals.sh` fails until the pinned line equals the real one.
