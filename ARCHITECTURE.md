# Architecture
Readers: Sam and Morgan (their prompts tell them to read this file when it exists), the Lead, contributors. Product: `VISION.md`.
## Bird's eye view
A Claude Code plugin. The Lead runs `/lgtmgate:deliver <issue>`; `workflows/deliver-pipeline.js` drives Theo (diagnose),
Sam (plan), Nick (code and PR) and Morgan (review) in the issue's worktree and returns one status. A human merges.
## Boundaries
- Reaches a consumer run: the engine and its prompts, `agents/*.md`, `commands/*.md`, `hooks/` and the `scripts/lib/` they source.
- Also reaches a consumer: the templates `/lgtmgate:init` copies into its repo (`commands/init.md`).
- Stays here: `VISION.md`, this file, `CLAUDE.md`, `.claude/`, `docs/`, `fixtures/`, `evals/`, the rest of `scripts/`.
- Neutrality: a config without the optional keys runs as before them; T77g (doc reads conditional), T77h (paths), T77l (kinds).
## Invariants and what each check verifies
1. R1, the ratchet (`scripts/guards.cjs`): three engine counters never rise against `origin/main` (never a fixed threshold):
   `await agent(` outside `callAgent`; distinct `simulate.<key>` keys (a seam); regex applications outside parser markers.
2. `hooks/block-merge-unchecked.sh` refuses a `- [ ]` between the acceptance markers, and a bare `gh pr merge` on a stale review.
3. `scripts/lead-merge.sh` re-checks both and adds: markers present, declared exceptions valid, CI checks green.
4. A proof is a command with its expected output, or an artifact Morgan inspects (`.claude/rules/pr-acceptance.md`): Morgan's review.
5. `staleArtifactBlockers` overturns an LGTM whose declared artifact is absent, empty or older than the last commit; artifacts only.
6. R2, a bug is a fixture: for a `bug` touching `workflows/`, Nick's prompt gets the fixture item; CI replays `run-offline.cjs --all`.
7. The CI gates enforce the rest (suites wired, Sam's prompt parity, version floor, critical paths, doc budgets, canonical guards):
   run `node scripts/guards.cjs` and `bash templates/test-canonical-guards.sh`; a failure names its rule.
## Design decisions (state; rejected alternative)
1. One gate to the world. In transition, epic #66: `templates/probe-run.cjs` runs provision, preflight, PR state and PR writes;
   other reads still ask an agent. Rejected: one model call per read or write, an agent re-typing stdout.
2. One state registry. Target, epic #67: no `STATUS` registry in the code yet. Rejected: status strings scattered in the engine.
3. The checklist is data. Target, epic #67: no `acceptanceItems` in the code yet. Rejected: a Markdown checklist read by three parsers.
4. One-way doors are per-repo config. Done, #77: the engine knows no path and no kind. Rejected: stops hard-coded for every repo.
## One-way doors (R3)
- R3 stops a run at `design-step-required` before dev; `architectureDecisionApproved:true` is the maintainer's way through.
- Kind: Sam's plan announces `one-way-door: <kind> — <what>` and `oneWayDoorKinds` lists it (`status`, `agent`, `hook`, `seam`).
- Sam is asked about the listed kinds only; an empty list asks nothing and stops nothing.
- Path: one of Sam's `targetFiles` matches `oneWayDoorPaths` (`dir/`, `*`, `**`, `?`, exact path; `!` excludes).
- Here: the four kinds, every file under `hooks/` except top-level `hooks/test-*`, and `docs/critical-paths.md`.
- A hook edit and a new hook look alike from `targetFiles`: both stop. Proof: flow tests T77a-o.
## Where new code goes
- A probe or a shell side effect: `templates/probe-run.cjs` (executes, keeps the raw output, prints one line).
- A new run outcome: `finish({ status })` and its row in `commands/deliver.md` (a `status` one-way door).
- A new check on a PR: an acceptance item in the plan's checklist (`acceptanceChecklist`).
- An engine bug fix: `fixtures/incidents/<issue>-*.json` first, red on the base, then the fix.
- A pure helper: a `// --- name:start ---` / `// --- name:end ---` block (no I/O, no closure state), extracted by the flow suite.
## Declared exception
- A shortcut at the margin, never in silence: `// DEBT(#N): <what is skipped and why>` (`# DEBT(#N)` in shell).
- Its follow-up `#N` is open and labelled `tech-debt`; the acceptance block carries `exception: <what> — <why> — #N`.
- `scripts/lead-merge.sh` refuses an exception without that open issue or without the `DEBT(#N)` marker in the diff.
- Never for an R1 counter, an unproven item, an engine bug without its fixture, or a critical path.
## Conventions without a check
- Stage functions return `finish({ status, ... })`, never a bare `return { status }`: the `STATUS` registry, #67.
- No engine vocabulary in a consumer prompt; the layer rule and the R2 trigger still reach consumer prompts: #163.
- An R2 waiver is declared as an `exception:` line: #174.
- A `[human-gate]` item only where no command can prove it: #169.
## Not used on purpose / cross-cutting
- Not used: ADR files, dependency-injection frameworks, a plugin system in the engine, unbounded retries (`callAgent`'s are bounded).
- Not used: a hand-written file-by-file map; a generated one is tracked by #128.
- `.claude/pipeline.config.json` keys change additively only; a new key's default keeps the old behaviour.
- Channels: `stable` (pinned) and `beta` (`main`), see `MAINTAINING.md`.
