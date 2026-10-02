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
- A scout `plan` must contain its `acceptanceChecklist` lines: the engine refuses a pointer/summary plan before plan-check (see `153-plan-pointer-return`).
- A label missing from `calls` throws with the label and the prompt head, **and fails the fixture even
  when the engine swallows the error** (fail-open probes, agent-death routing). Nothing is defaulted:
  the harness only proves what the fixture actually feeds.

## Capture a fixture from a real run

```
bash scripts/capture-incident.sh <runId> <issue> <label> [--out DIR]
```

- It reads the run's journal and run record and writes a **private raw capture**
  `.pipeline/captures/<issue>-<label>.json`: git-ignored (the script refuses any output path git
  does not ignore), never committed, and it may hold private data.
- One `calls[<label>]` entry per `agent()` call of the run's final pass, exactly as the agent
  returned it (the final pass of a relaunched run is identified by the record's `agentId` values,
  never by journal order). It fails closed, naming the key, on any layout it does not recognise
  and on a call that died; it then replays the capture and prints the next step.
- `expect.status` is the OBSERVED status. For a bug fix, set the correct outcome before the
  fixture is published: it must fail on `origin/main` and pass on the fix branch.
- Until the publication step exists, publish by hand: `node scripts/redact-fixture.cjs <file>`, move
  the file to `fixtures/incidents/`, then `node scripts/run-offline.cjs <file>`.
- `node scripts/run-offline.cjs <file> --report-unused` also lists the fixture entries a replay
  never consumed (report only, never a failure).

## Honesty note on `smoke/`

`smoke/auto-lgtm.json` is **synthetic-raw**: the strings are the exact shapes the engine's
prompts request (`PROBE` / `VERIFY ok` line pairs built with `probeLine()` from `templates/probe-run.cjs`, `preflight` probe pairs (`probe-<issue>-preflight-dev-r0` / `-branch-r0`), `<sha> <digest>`, JSON arrays), not a
captured transcript. It exercises the real parsers on the nominal path; it does not prove the
model returns those shapes. The first canary run replaces it with a captured one.
