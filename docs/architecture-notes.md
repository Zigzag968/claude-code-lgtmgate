# Architecture notes

For humans; never imported into an agent prompt. These sections were moved verbatim out of `VISION.md`
and `ARCHITECTURE.md` when both were brought back to their budgets (20 and 60 lines, `doc-budgets` in
`scripts/guards.cjs`). The binding text for agents lives in those two files; where a line here and
there disagree, those two files win.

## Moved from VISION.md

### Thesis
Humans read proofs, not diffs. LGTM Gate is the trust layer between coding agents and `main`:
nothing reaches `main` unless every acceptance item is proven by a command and its output.

### Who the product serves
The Product Engineer who has more ideas than they can code themselves, lets agents build, and must be
able to trust that those agents stay aligned with the product vision and the technical vision of the
repo. Installed in a repo, the gate plugs into that repo's own `VISION.md`, `ARCHITECTURE.md` and code
map when they exist, and holds its agents to the maintainer's intent.

### Target
- A labelled issue becomes a merge-ready PR whose every acceptance item is proven, on any GitHub repo.
- Every real incident becomes a replayed fixture; every closed cause class becomes a CI check; the
  same failure class never recurs.
- The merge ladder: today a human merges every PR. Next, the human merges on proofs alone, never on
  a diff. Target: a change class with a measured clean record merges on its own; humans act at
  one-way doors. Each step is earned by a measurement, never claimed.
- Cost per issue stays bounded because a script does every mechanical job and the model only
  judges; the Lead's progress table carries the tokens per PR that show it.

### How we work
- The patch is the default route. It becomes structural when it would cross an invariant.
- A shortcut is allowed at the margin, never in silence: a `DEBT` marker in the code, an open
  follow-up issue, an `exception:` line in the PR, and a human who accepts it at merge
  (format in `ARCHITECTURE.md`). Never for the three ratchet counters, an unproven item, a bug
  without its fixture, or a critical path.
- The planner names the proof, the developer makes it pass, the reviewer runs it.
- The critical paths of the product are declared in `docs/critical-paths.md`; each one has a passing
  test; an agent never edits that list without a human.
- Humans act at one-way doors and at merge. A script over a model for any mechanical job.

### Never (the list before the three R1 counters became the Never list of VISION.md)
- An agent re-types what a command printed.
- Anything merges unproven.
- A rule without its check.
- A model adopts its own rules: a human adopts every invariant.
- A new agent role for a mechanical job.

### Out of scope
Forges other than GitHub. Multi-human roles and permissions.

### Evolution
Add a rule at its second occurrence, only with a check. Remove a rule that changed no result.

## Moved from ARCHITECTURE.md

### Bird's eye view
A Claude Code plugin. The Lead runs `/lgtmgate:deliver <issue>`; the workflow drives the agents
(Theo diagnose → Sam plan → Nick implement + PR → Morgan review) in the issue's worktree and returns
one status. A human merges through `scripts/lead-merge.sh`. Direction: `VISION.md`. Map of the code:
`docs/codemap.md`. Use cases that must keep working: `docs/critical-paths.md`.

### Engineering principles, their invariants, their checks
One line per principle. Every check in this table runs in CI today; a principle without a running
check does not belong here.

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

### Patterns in use
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

### Where new code goes (the full table; the three agent-read rows are in VISION.md)
| You need | Put it in |
|---|---|
| a shell side effect or a probe | behind `callAgent` (single boundary; target: the single `probe-run` port) |
| a new outcome of a run | the status table of the engine (one-way door: stop and ask) |
| a new check on a PR | an acceptance item, with its command and expected output |
| a fix for an engine bug | `fixtures/incidents/<issue>-*.json` first, then the fix |
| a test the plan names | written first, seen red once, then green; never weakened to pass |
| a new file | one line in `docs/codemap.md` |

### In transition
- Side effects: `callAgent` today → a single `probe-run` port that executes, keeps the raw output and
  prints one line.
- Run state: status strings today → a `STATUS` registry every table and hook is checked against.
- Checklist: Markdown read by parsers today → `acceptanceItems` with ids, rendered by the workflow.

### Cross-cutting
- Config contract: `.claude/pipeline.config.json` keys change additively only.
- Channels: `stable` (pinned) and `beta` (`main`), see `MAINTAINING.md`.
