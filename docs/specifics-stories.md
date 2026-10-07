# Specifics stories

The user stories of epic #261 (project specifics for agents), one row each. `stories-covered`
(`templates/test-canonical-guards.sh`) checks every row.

Proof column rules:
- `doc`: delivered as documentation only, nothing to execute.
- `pending: #N`: not proven yet, owned by issue #N. Tolerated until #266 removes the tolerance; the epic closes only when no row is pending.
- otherwise the proof must exist: a fixture `fixtures/specifics/us-<x><n>-*.json`, or a case of a `scripts/test-*.sh` / `templates/test-*` file or a guard name that spells the id. The guard computes this itself and never reads the free text of the column.

| Id | Story | Issue | Proof |
|---|---|---|---|
| US-C1 | project owner runs init; plugin detects the stack, warns about what agents will not guess, proposes stub files | #267 | scripts/test-init-specifics.sh |
| US-C2 | 3 lines written in `nick.md` are applied at every run | #265 | pending: #265 |
| US-C3 | existing rule files are targeted per role via `agentContext` without moving them | #265 | pending: #265 |
| US-C4 | dropping `nick.testing.md` is picked up on the next run with no config change | #264 | pending: #264 |
| US-C5 | the owner sees what each agent will receive before launching (`/lgtmgate:context`) | #268 | pending: #268 |
| US-C6 | multi-stack repos: an issue only receives the specifics of its lane | #271 | pending: #271 |
| US-C7 | exceeding the recommended size is announced once and the owner decides | #265 | pending: #265 |
| US-C8 | the owner's rules survive plugin updates; init never overwrites | #267 | scripts/test-init-specifics.sh |
| US-C9 | the Lead gets a clear failure before any agent starts | #265 | pending: #265 |
| US-C10 | a plugin agent no longer cites one repo's rules or stack | #263 | agent-neutrality |
| US-R1 | no more substitute agents to get a planner for a stack | #266 | pending: #266 |
| US-R2 | no more `lane-refused` status and relaunch with `scoutAgent` | #266 | pending: #266 |
| US-R3 | no more convention-rule key to set and hope | #270 | pending: #270 |
| US-R4 | plugin agents free of one maintainer's references | #263 | project-specifics-slot |
| US-R5 | no more prose instructions inside `commands.build` (project decision) | #267 | doc |
| US-R6 | no more copying agent md files into the project (Claude Code behaviour, one README sentence) | #265 | doc |
