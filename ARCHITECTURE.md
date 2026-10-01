# Architecture

Read by Sam and Morgan. Direction and design decisions: `VISION.md` (imported for every agent through `CLAUDE.md`). For humans, never imported into a prompt: `docs/codemap.md`, `docs/critical-paths.md`, `docs/architecture-notes.md`.

## Constraints (one line each, with the check that enforces it)
Vocabulary: **R1** is the ratchet (counters compared to `origin/main`, never to a threshold); **R2** is "an engine bug ships its raw fixture"; **R3** is the one-way-door stop; a **seam** is a point where a `simulate.*` double replaces real code.
1. Every model call goes through `callAgent`: no new `await agent(` outside it — `scripts/guards.cjs` R1 `agent-calls`.
2. No new `simulate.*` seam; a double never replaces a parser — `scripts/guards.cjs` R1 `simulate-seams`.
3. No new regex on agent output outside balanced parser markers — `scripts/guards.cjs` R1 `agent-output-regex` and `R1 parser markers`.
4. No merge with an unchecked or unproven acceptance box — `hooks/block-merge-unchecked.sh`, `scripts/lead-merge.sh` (`scripts/test-lead-merge.sh`).
5. Every acceptance item is a command plus its expected output: the planner names the proof, the developer makes it pass, the reviewer runs it and pastes the output — Morgan's review (`.claude/rules/pr-acceptance.md`).
6. The workflow overturns an LGTM whose proofs do not hold — `staleArtifactBlockers` (flow suite).
7. An engine bug ships its raw fixture under `fixtures/incidents/`, red on the base, green on the branch (R2) — acceptance item + `OFFLINE_STRICT=1 node scripts/run-offline.cjs --all fixtures` in CI.
8. Every test suite runs in CI — `scripts/guards.cjs` `all-tests-wired`.
9. `agents/sam.md` and `samScoutPrompt` carry the same LAYER RULE sentence and `patch-avoided:`, never a `root-cause:` field — `scripts/guards.cjs` `sam-parity`.
10. The plugin version never drops below `main` — `scripts/guards.cjs` `version-floor`.
11. A plan adding a status, an `agent()`, a hook or a seam, or touching a path of `oneWayDoorPaths`, ends in `design-step-required` (R3) — `oneWayDoor` block, flow suite T77a-k.
12. No new agent role for a mechanical job (use a script or a probe): a new role is a new model call, announced `one-way-door: agent` and stopped by R3 (constraint 11) — flow suite T77d.
13. Every line of `docs/critical-paths.md` names a proof that exists — `templates/test-canonical-guards.sh` `critical-paths-proven`.
14. `VISION.md` stays within 20 lines and this file within 60 — `scripts/guards.cjs` `doc-budgets`.

The other invariants of the canonical guard net (stamp parity, PR body structure, no private refs, ...) are listed in the header of `templates/test-canonical-guards.sh`.

## One-way doors
A plan that adds a status, an `agent()` call, a hook or a seam stops at the design step (`design-step-required`): Sam announces it on a line `one-way-door: <kind> — <what>` (kind: `status`, `agent`, `hook` or `seam`), or `one-way-door: none`. So does a plan whose target files match `oneWayDoorPaths` in `.claude/pipeline.config.json` (here: the hook scripts, `hooks/plugin-hooks.json`, `docs/critical-paths.md`); the engine knows no path, a repo that declares none is never stopped. The maintainer approves explicitly (`architectureDecisionApproved`) or edits the file themself; otherwise the run stays stopped. Adding a rule or a guard is a one-way door too: announce it, then stop.

## Where new code goes
- A probe or a shell side effect: `templates/probe-run.cjs` (executes, keeps the raw output, prints one line).
- A new run outcome: `finish({ status })` plus its row in the status table of `commands/deliver.md` (one-way door).
- A new check on a PR: an acceptance item in the plan's checklist (`acceptanceChecklist`; target: `acceptanceItems` with ids).

## Declared exception
A shortcut is allowed at the margin and never in silence.
- In the code: `// DEBT(#N): <what is skipped and why>` (`# DEBT(#N)` in shell).
- A follow-up issue `#N`, labelled `tech-debt`, open before the merge.
- In the PR body, inside the acceptance block: `exception: <what is skipped> — <why> — #N`.
- Morgan flags it; the maintainer accepts it by merging.
- Never for the three R1 counters, an unproven acceptance item, an engine bug without its fixture, or a line of `docs/critical-paths.md`.

## Conventions without a check yet
- A new file gets its line in `docs/codemap.md` (check to come: a generator from one header per file, verified in CI).
- An `exception:` line in a PR has an open follow-up issue and a `DEBT` marker in the diff (check to come in `scripts/lead-merge.sh`, #122; Morgan flags it meanwhile).
- No new probe kind (a parser in `templates/probe-run.cjs`) without a design decision: it is a one-way door (no check yet; announce it, then stop).
- Stage functions return `finish({ status, ... })`; never a bare `return { status }`.
- `callAgent` / `callAgentSafe` validate a schema with bounded retries; agent output is structured (`verdict` is an enum), never free text parsed by a regex.
- Blocks between `// --- name:start ---` and `// --- name:end ---` are pure and self-contained (extracted by `extractBetween` for tests): no I/O, no closure state.
- A test the plan names is written first, seen red once, then green; never weakened to pass.
- `.claude/pipeline.config.json` keys change additively only.
- Not used, on purpose: ADR files, dependency-injection frameworks, a plugin system inside the engine, retries hidden in helpers.
