# Critical paths

The use cases that must work at every release. Declared by the maintainer, one line each, each proven
by a test that runs in CI. Any change to this file by an agent is a one-way door (R3): the run stops
at the design step until a human approves.

Format: `- CP-<n> — <use case> — proof: <test id | fixture | script> — expects: <result>`.

- CP-1 — a labelled issue with a confirmed diagnosis and a GO plan reaches the plan gate — proof: `fixtures/smoke/semi-plan-ready.json` — expects: `plan-ready`
- CP-2 — a PR whose every acceptance box Morgan proved reaches the merge queue — proof: `fixtures/smoke/auto-lgtm.json` — expects: `ready`
- CP-3 — a plan announcing a new status stops before any code is written — proof: `T77a` — expects: `design-step-required`
- CP-4 — a plan touching a hook file stops before any code is written — proof: `T77b` — expects: `design-step-required`
- CP-5 — an ordinary plan is not stopped by the one-way-door signal — proof: `T77c` — expects: `plan-ready`
- CP-6 — a stale branch prefix on a cross-repo re-route is reconciled instead of escalating — proof: `T61a` — expects: no escalation
- CP-7 — a PR with an unchecked acceptance box is refused at merge — proof: `scripts/test-lead-merge.sh` — expects: merge refused
- CP-8 — a probe answering in prose instead of the raw line is caught, not parsed as data — proof: `fixtures/incidents/99-gitdir-probe-prose.json` — expects: the replayed status of the fixture
- CP-9 — a review that only asks for checklist wording or ticks does not cost a dev round — proof: `fixtures/incidents/107-checklist-only-blockers.json` — expects: `verified-untickable`
- CP-10 — an agent cut off by a classifier outage is retried, and reported dead only once retries are exhausted — proof: `fixtures/incidents/110-classifier-outage-retry.json`, `fixtures/incidents/110-classifier-outage-exhausted.json` — expects: `ready`, then `dev-died`

## Not yet proven — owned elsewhere, do not list above
- raw incident capture at every escalation: epic #67
