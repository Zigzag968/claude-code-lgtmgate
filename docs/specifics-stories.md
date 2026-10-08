# Specifics stories

The user stories of epic #261 (project specifics for agents), one row each. `stories-covered`
(`tests/templates/test-canonical-guards.sh`) checks every row.

Proof column rules:
- `doc`: delivered as documentation only, nothing to execute.
- otherwise the proof must exist: a fixture `fixtures/specifics/us-<x><n>-*.json`, or a case of a `tests/scripts/test-*.sh` / `tests/templates/test-*` file or a guard name that spells the id. The guard computes this itself and never reads the free text of the column.

| Id | Story | Issue | Proof |
|---|---|---|---|
| US-C1 | project owner runs init; plugin detects the stack, warns about what agents will not guess, proposes stub files | #267 | tests/scripts/test-init-specifics.sh |
| US-C2 | 3 lines written in `nick.md` are applied at every run | #265 | fixtures/specifics/us-c2-inject.json |
| US-C3 | existing rule files are targeted per role via `agentContext` without moving them | #265 | fixtures/specifics/us-c3-agentcontext.json |
| US-C4 | dropping `nick.testing.md` is picked up on the next run with no config change | #264 | tests/scripts/test-agent-context.sh |
| US-C5 | the owner sees what each agent will receive before launching (`/lgtmgate:context`) | #268 | tests/scripts/test-context-print.sh |
| US-C6 | multi-stack repos: an issue only receives the specifics of its lane | #271 | fixtures/specifics/us-c6-lanes-single.json |
| US-C7 | exceeding the recommended size is announced once and the owner decides | #265 | fixtures/specifics/us-c7-oversize-accepted.json |
| US-C8 | the owner's rules survive plugin updates; init never overwrites | #267 | tests/scripts/test-init-specifics.sh |
| US-C9 | the Lead gets a clear failure before any agent starts | #265 | fixtures/specifics/us-c9-missing-arg.json |
| US-C10 | a plugin agent no longer cites one repo's rules or stack | #263 | agent-neutrality |
| US-R1 | no more substitute agents to get a planner for a stack | #266 | fixtures/specifics/us-r1-scout-arg-removed.json |
| US-R2 | no more substitute-scout status and relaunch with a substitute scout | #266 | templates/test-deliver-pipeline.js (T120) |
| US-R3 | no more convention-rule key to set and hope | #270 | fixtures/specifics/us-r3-conventionsrule-ignored.json |
| US-R4 | plugin agents free of one maintainer's references | #263 | project-specifics-slot |
| US-R5 | no more prose instructions inside `commands.build` (project decision) | #267 | doc |
| US-R6 | no more copying agent md files into the project (Claude Code behaviour, one README sentence) | #265 | doc |
