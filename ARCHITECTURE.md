# Architecture

## Bird's eye view
A Claude Code plugin. The Lead runs `/lgtmgate:deliver <issue>`; the workflow drives the agents
(Theo diagnose → Sam plan → Nick implement + PR → Morgan review) in the issue's worktree and returns
one status. A human merges through `scripts/lead-merge.sh`. Direction: `VISION.md`. Map of the code:
`docs/codemap.md`. Use cases that must keep working: `docs/critical-paths.md`.

## Engineering principles, their invariants, their checks
One line per principle. Every check in this table runs in CI today; a principle without a running
check does not belong here. Vocabulary: **R1** is the ratchet (three counters compared to `origin/main`
in `scripts/guards.cjs`: `await agent(` calls outside `callAgent`, `simulate.*` seam keys, regexes on
agent output outside parser markers); **R2** is "an engine bug ships its raw fixture"; **R3** is the
one-way-door stop. A **seam** is a point where a test double (`simulate.*`) replaces real code.

| Principle | Here it means | Invariant | Check |
|---|---|---|---|
| Code orchestrates, the model only judges | every model call goes through one boundary | no `await agent(` outside `callAgent` | `scripts/guards.cjs` ratchet R1 |
| Ports and adapters: one port to the world | parsers are pure, doubles never replace them | no new `simulate.*` seam, no regex on agent output outside parser markers | `scripts/guards.cjs` ratchet R1 |
| Verification by external state, never by narrative | a box is checked with its command and output | no merge with an unproven acceptance box | `hooks/block-merge-unchecked.sh`, `scripts/lead-merge.sh` |
| Characterization tests on raw runs | an engine bug ships its raw fixture, red on the base, green on the branch (R2) | no engine bug fixed without a replayed fixture | acceptance item + `scripts/run-offline.cjs --all` (`.github/workflows/guards.yml`) |
| Fitness functions as ratchets | counters are compared to `origin/main`, never to a threshold | the three R1 counters never rise | `scripts/guards.cjs` |
| Nothing runs outside CI | every suite is wired, persona and prompt say the same, version never below `main` | `all-tests-wired`, `sam-parity`, version floor | `scripts/guards.cjs` |
| One-way doors stop the run | a plan adding a status, an `agent()`, a hook, a seam, or touching `docs/critical-paths.md` ends in `design-step-required` (R3) | no one-way door passes without the maintainer | `oneWayDoor` block, flow suite T77a-f |
| Critical paths declared and proven | each line of `docs/critical-paths.md` names a proof that exists | no declared path without its passing proof | `templates/test-canonical-guards.sh` (critical-paths-proven), flow suite, `run-offline.cjs --all`, `scripts/test-lead-merge.sh` |
| Tests are the contract between roles | the planner names the proof, the developer makes it pass, the reviewer runs it and pastes the output | every acceptance item is a command plus its expected output | `pr-acceptance.md`, Morgan's review |
| Reviewer debiasing | Morgan reads plan, diff and checklist without the author; `FAIL:` means required changes | an LGTM whose proofs do not hold is overturned | `staleArtifactBlockers`, `agents/morgan.md` |

## Patterns in use
- Stage functions return `finish({ status, ... })`: every run outcome goes through one constructor.
  Forbidden: a bare `return { status }`.
- Single agent boundary: `callAgent` / `callAgentSafe` wrap every model call with schema validation
  and bounded retries; agent output is structured (`verdict` is an enum), never free text parsed by a
  regex.
- Pure blocks between markers: `// --- name:start ---` … `// --- name:end ---` are pure and
  self-contained, extracted by `extractBetween` for tests, because a Workflow script cannot `import`.
  Forbidden: I/O or closure state inside a block.
- Test doubles by seam: `simulate.*` returns pre-parsed values. This is the pattern being retired: it
  lets a test go green without running a parser. Target: replay raw fixtures through the real
  parsers (`scripts/run-offline.cjs`).
- Proof over verdict: the workflow re-checks Morgan's proofs and overturns an LGTM whose proofs do
  not hold.
- Acceptance item = command + expected output (`pr-acceptance.md`): authored by Sam, executed by
  Nick, proven by Morgan. This is the only binding contract on what to test.
- Guards as ratchets: counters against `origin/main`, never absolute thresholds.
- Not used, on purpose: ADR files, dependency-injection frameworks, a plugin system inside the
  engine, retries hidden in helpers.

## One-way doors
A plan that adds a status, an `agent()` call, a hook or a seam, or that touches
`docs/critical-paths.md`, stops at the design step (`design-step-required`). The maintainer approves
explicitly (`architectureDecisionApproved`) or edits the file themself; otherwise the run stays
stopped. Adding a rule or a guard is a one-way door too: announce it, then stop.

## Where new code goes
| You need | Put it in |
|---|---|
| a shell side effect or a probe | behind `callAgent` (single boundary; target: the single `probe-run` port) |
| a new outcome of a run | the status table of the engine (one-way door: stop and ask) |
| a new check on a PR | an acceptance item, with its command and expected output |
| a fix for an engine bug | `fixtures/incidents/<issue>-*.json` first, then the fix |
| a test the plan names | written first, seen red once, then green; never weakened to pass |
| a new file | one line in `docs/codemap.md` |

## Conventions awaiting their check
- A new file gets its line in `docs/codemap.md` (check to come: a generator from one header per
  file, verified in CI).
- An `exception:` line in a PR has an open follow-up issue and a `DEBT` marker in the diff (check to
  come in `scripts/lead-merge.sh`, #122; Morgan flags it meanwhile).

## Declared exception
A shortcut is allowed at the margin and never in silence.
- In the code: `// DEBT(#N): <what is skipped and why>` (`# DEBT(#N)` in shell).
- A follow-up issue `#N`, labelled `tech-debt`, open before the merge.
- In the PR body, inside the acceptance block: `exception: <what is skipped> — <why> — #N`.
- Morgan flags it; the maintainer accepts it by merging.
- Never for the three R1 counters, an unproven acceptance item, an engine bug without its fixture,
  or a line of `docs/critical-paths.md`.

## In transition
- Side effects: `callAgent` today → a single `probe-run` port that executes, keeps the raw output and
  prints one line.
- Run state: status strings today → a `STATUS` registry every table and hook is checked against.
- Checklist: Markdown read by parsers today → `acceptanceItems` with ids, rendered by the workflow.

## Cross-cutting
- Config contract: `.claude/pipeline.config.json` keys change additively only.
- Channels: `stable` (pinned) and `beta` (`main`), see `MAINTAINING.md`.
