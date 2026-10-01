# fixtures/ — record/replay material for `scripts/run-offline.cjs`

This repo is public: every file under `fixtures/` goes through `node scripts/redact-fixture.cjs`
before it is committed, and the `no-private-refs` invariant scans the whole tracked tree.

| Directory | What | Consumed by |
|---|---|---|
| `smoke/` | one nominal run per mode, every `agent()` call answered with a raw value | `run-offline.cjs --all fixtures` (CI) |
| `incidents/` | one file per real incident, named `<issue>-<label>.json`; the replay asserts the status the fix must produce | same, plus the acceptance item of every engine bug fix (doctrine R2) |
| `probes/` | raw stdout of a real `gh`/`git` command (`*.raw`), consumed by `templates/test-probe-run.sh` once the probe layer exists (E2.2) | `test-probe-run.sh` |

## Fixture format

```json
{
  "name": "auto-lgtm",
  "args": { "issue": 1, "mode": "auto", "...": "never `simulate`" },
  "calls": {
    "probe-1-provision-provision-r0": { "line": "PROBE name=provision exit=0 sha=... cmd=... json={...}", "verify": "VERIFY ok line=PROBE name=provision ..." },
    "scout-issue-1-1": { "decision": "GO", "plan": "..." },
    "morgan-pr-123-42-r0": [ { "verdict": "LGTM", "items": [] } ]
  },
  "expect": { "status": "ready", "trace": ["Provision"], "logsInclude": [] }
}
```

- `calls` is keyed by the `label` of each `agent()` call. A migrated probe (#82: provision, provision
  freshness, review-phase behind-count) is keyed `probe-<issue>-<parser>-<label>-r<round>` and answered
  `{ line, verify }`: `line` built with `require('./templates/probe-run.cjs').probeLine(parser, { stdout, exit })`,
  `verify` = `VERIFY ok line=<line>`. A string answers a schema-less call
  (the engine's own parser runs on it), an object answers a schema call. An array is consumed
  in call order (one entry per round).
- Probe fixtures need `args.pluginRoot` (any absolute string, e.g. `/plugin`) or `config.probeRunPath`; without it
  the run fails closed before any agent call (`probeReason: probe-run-not-found`, see `82-provision-no-probe-run-path`).
  A `verify` answer of `VERIFY fail reason=no-attestation` reproduces a session whose attest hook is not enabled
  (`probeReason: no-attestation`, see `82-provision-no-attestation`). The VERIFY line is attested by the same hook as
  the PROBE line (bound to the call's label and round), and the probe agent may not stop without the pair (#83). The persona fallback (agent type not found) has no fixture (the harness
  cannot throw); the flow suite pins its wiring (T273).
- A label missing from `calls` throws with the label and the prompt head, **and fails the fixture even
  when the engine swallows the error** (fail-open probes, agent-death routing). Nothing is defaulted:
  the harness only proves what the fixture actually feeds.

## Capture a fixture from a real run (before the probe layer exists)

Until E2.2 lands there is no `.pipeline/probes/` directory and no capture script. A smoke or
incident fixture is built by hand from the run's own record:

1. Take the run's journal (the Workflow tool records each `agent()` return value) or, failing
   that, the transcript pasted in the issue.
2. For every `agent()` call, add one `calls[<label>]` entry with **exactly** what the model
   returned: the raw string for a schema-less call, the JSON object for a schema call. Do not
   normalise, do not fix typos — the incident is often in the typo.
3. Set `args` to the run's arguments (drop `simulate`, drop secrets) and `expect.status` to the
   status the fix must produce (for an incident: the *correct* outcome, not the observed one).
4. `node scripts/redact-fixture.cjs fixtures/incidents/<issue>-<label>.json`
5. `node scripts/run-offline.cjs fixtures/incidents/<issue>-<label>.json` — it must fail on
   `origin/main` and pass on the fix branch.

Once E2.2 lands, `probe-run` writes every raw probe output under `.pipeline/probes/` and
`scripts/capture-incident.sh` (E3.10) turns them into a fixture in one command.

## Honesty note on `smoke/`

`smoke/auto-lgtm.json` is **synthetic-raw**: the strings are the exact shapes the engine's
prompts request (`PROBE` / `VERIFY ok` line pairs built with `probeLine()` from `templates/probe-run.cjs`, `preflight` probe pairs (`probe-<issue>-preflight-dev-r0` / `-branch-r0`), `<sha> <digest>`, JSON arrays), not a
captured transcript. It exercises the real parsers on the nominal path; it does not prove the
model returns those shapes. The first canary run replaces it with a captured one.
