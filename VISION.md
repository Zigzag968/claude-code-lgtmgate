# Vision — read before planning or reviewing

You are planning or reviewing a change to lgtmgate. Judge every plan and every diff against this file.
When in doubt, stop and escalate to the maintainer; never work around a rule.

## Target (the engine in 6 months)
Code orchestrates, the LLM only judges. Every contact with the world (shell, git, GitHub, files) goes
through one port; every run state is a typed status; every acceptance item is data with a proof.
Product goal: a labelled issue becomes a merge-ready PR whose every item is proven by a command and
its output. Reliability first (nothing merges unproven), then autonomy (`size:S` issues reach `ready`
with no human step), on any GitHub repo.

## Directives
1. Prove, never assert: a box is checked only with its command and output.
2. Fix the layer that produced the bug, not the symptom. A new agent, probe `agent()` or `simulate.*`
   seam is never the answer to a failure.
3. Humans act only at one-way doors (a new status, `agent()`, hook or seam: announce
   `one-way-door:` and stop) and at merge. Never merge automatically.
4. Keep cost bounded: a script over an agent for any mechanical check.

## Never — each rule has its check
| # | Never | Checked by | State |
|---|---|---|---|
| N1 | an `await agent(` outside `callAgent` | `scripts/guards.cjs` R1 ratchet | in place (target: 1 call, E2) |
| N2 | a new `simulate.*` seam | `scripts/guards.cjs` R1 ratchet | in place (target: `simulate.probes` only, E2) |
| N3 | a regex on agent output outside parser markers | `scripts/guards.cjs` R1 ratchet | in place |
| N4 | a merge with an unproven acceptance box | `hooks/block-merge-unchecked.sh`, `scripts/lead-merge.sh` | in place |
| N5 | an engine bug fixed without a replayed fixture | R2 acceptance item, `run-offline.cjs --all` in CI | in place |

Also enforced: every test suite runs in CI (`all-tests-wired`); persona and engine prompts share
byte-identical rules (`sam-parity`); the version never goes below `main` and is bumped at merge.

## Decisions (do not re-propose the rejected options)
1. One gate to the world: `probe-run` executes, keeps the raw output, parses it with pure parsers and
   prints one line; the agent only copies that line; a hook attests the execution (E2).
   Rejected: one haiku probe per read or write, re-typing stdout (22 probes).
2. One state registry: `STATUS` holds every run outcome; the Lead's table and the Stop hook are
   checked against it (E3). Rejected: status strings scattered through the engine.
3. The checklist is data: `acceptanceItems` with ids, rendered by the workflow, proven per id (E3).
   Rejected: a Markdown checklist read by three parsers.

## Where new code goes
Side effect or probe → `probe-run` (today `callAgent`) · new outcome → `STATUS` (one-way door) ·
new check → an acceptance item · engine bug → `fixtures/incidents/<issue>-*.json` first, then the fix.
Map of the current code: `ARCHITECTURE.md`.

## Out of scope — refuse and say why
New agent roles · new probe `agent()` calls · automatic merge · forges other than GitHub.

## Evolution
Add a rule only at its second occurrence, and only with a check. Remove a rule that changed no result.
Version: 2026-09-30.
