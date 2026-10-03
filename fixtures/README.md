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

`expect` keys: `status` (required), `reason` (exact), `trace` (PREFIX match on `result.trace`), `logsInclude`
(substrings of the log), `throws` (the run must throw an error containing it, instead of `status`) and two opt-in
exactness keys that change no fixture that does not set them: `traceExact: true` (the trace must have exactly as many
entries as `trace`) and `callLabels` (the ordered labels of the `agent()` calls, exact equality).

- `calls` is keyed by the `label` of each `agent()` call. A migrated probe (#82: provision, provision
  freshness, review-phase behind-count) is keyed `probe-<issue>-<parser>-<label>-r<round>` and answered
  `{ line, verify }`: `line` built with `require('./templates/probe-run.cjs').probeLine(parser, { stdout, exit })`,
  `verify` = `VERIFY ok line=<line>`. A string answers a schema-less call
  (the engine's own parser runs on it), an object answers a schema call. An array is consumed
  in call order (one entry per round).
- Probe fixtures need `args.pluginRoot` (any absolute string, e.g. `/plugin`) or `config.probeRunPath`; without it
  the run fails closed before any agent call (`probeReason: probe-run-not-found`, see `82-provision-no-probe-run-path`).
  A fixture with `args.pluginRoot` and no `config.probeRunPath` also answers `probe-<issue>-lines-plugin-version-r0`
  (#195: the plugin-version check runs before provisioning; stdout `PLUGIN-VERSION:<version>`, command built by
  `pluginVersionCmd(pluginRoot)`, see `195-stale-plugin-root`). The token `@@ENGINE_VERSION@@`, anywhere in a fixture,
  resolves to the engine's `BUILD` version (refused against an engine with none): use it in that answer's `json=` and in
  any `expect` naming the engine, so the fixture survives the version bump at merge.
  A `verify` answer of `VERIFY fail reason=no-attestation` reproduces a session whose attest hook is not enabled
  (`probeReason: no-attestation`, see `82-provision-no-attestation`). The VERIFY line is attested by the same hook as
  the PROBE line (bound to the call's label and round), and the probe agent may not stop without the pair (#83). The persona fallback (agent type not found) has no fixture (the harness
  cannot throw); the flow suite pins its wiring (T273).
- A scout `plan` must contain its `acceptanceChecklist` lines, or the lines of its `acceptanceItems` (`- [ ] <!-- ac:N --> text`, the id comment optional): the engine refuses a pointer/summary plan before plan-check (see `153-plan-pointer-return`).
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
  and on a call that died; it then replays the capture and prints the next step. A call the engine
  retried (record label `<label> (retry N)`, journal label `<label>`) is captured once under `<label>`
  with the answer of the last attempt that did not die, and the status line reports `retries=<n>`; a call
  whose every attempt died, and any other label difference, still refuse.
- `expect.status` is the OBSERVED status, and publishing requires the replay to reproduce it: leave it
  as captured. For a bug fix the correct outcome is set on the published fixture (see below).
- `node scripts/run-offline.cjs <file> --report-unused` also lists the fixture entries a replay
  never consumed (report only, never a failure).

## Publish a capture as a public fixture

```
bash scripts/publish-fixture.sh <raw capture> [<out name>] [--out-dir DIR]
```

It turns the private capture into `fixtures/incidents/<issue>-<label>.json`, written to a temporary file in the
same directory and linked at its name (an existing file, a symbolic link included, is never overwritten; a kill
never leaves a partial file at the final name). SIGINT and SIGTERM remove the temporary file and the private copy of the
candidate and end with `status=error`; SIGKILL cannot be handled and may leave a hidden `.<name>.json.tmp-*` file in the
output directory (delete it by hand; it is never at the final name). Any step that cannot reach an identical outcome
refuses with its cause and writes nothing.

- Every string value of `args` and `calls` is replaced by a typed neutral token (zeros for a hash, `1` for
  a number, `_` otherwise), and a replacement is kept only if the replay outcome is identical. The outcome is: status,
  reason, exact trace, the ordered `agent()` call labels, the engine's ordered log and phase call sites, the FORM of the
  rest of the result (keys, array lengths, numbers, booleans and nulls exactly; a string only as empty or not) and the
  number of log lines. Free text of the result is outside the oracle. Every `agent()` call resolves to one engine site (`callAgent`), so the ordered labels carry the order of the
  agents and the log and phase sites carry the path through the engine. The baseline is replayed three times and must agree.
- A single-word value is neutralized like any other string: a first name, a short password or a one-word branch name can equal
  a literal of `workflows/deliver-pipeline.js`, so the engine's own words get no exemption (a value the engine switches on
  stays, because replacing it changes the outcome).
- Protected args (`mode`, `entryStage`, `proceedThrough`, `issueType`, `resumeReason`, `planFreshness`,
  `config.planFreshness`, `config.preflight.envSymlink`, `config.oneWayDoorKinds`, `config.oneWayDoorPaths`,
  `probeOnly.name`; a path protects its whole subtree) are never neutralized.
- The `cmd=` hash of a PROBE answer coupled to the args is recomputed after every change.
- `scripts/redact-fixture.cjs` runs next (it refuses on residue), then its `--check`, then a strict replay.
- Entries of `calls` the final replay never consumed (a label never asked, the tail of an array) are dropped.
- The published `expect` is rebuilt from the replay: `status`, `reason`, `trace` with `traceExact`, `callLabels`.
- It prints what remains as field names and character counts, never values: every kept string by JSON path, the kept
  fields that hold free text (`free-text`: a plan line, a reason, a file path, a protected field with a path, and a PROBE /
  VERIFY line whose part after `json=` holds a space or a path separator) and the published `expect.reason`, with their
  length (the line `free text: N field(s), T characters`), then the number of key names and of non-string scalars kept
  as they are, and the number of entries pruned.

For a bug fix, the Lead sets `expect` to the CORRECT outcome (and drops or corrects `reason`, `callLabels` and
`traceExact`) before the PR: the fixture must fail on `origin/main` and pass on the fix branch.

Declared limits:
- Key names and non-string values (numbers, booleans, null) are never neutralized: only the count is printed.
- What stays in the published file although it may be private: the PROBE / VERIFY answer lines the engine parses (kept
  whole, with their `json=` payload: a repository path of `planStale`, a `gitDir`, a PR `title`), the folder name of the
  project that follows `/Users/<name>` (the redactor rewrites the user name only), the protected args (for example
  `config.oneWayDoorPaths` such as `src/<product>/**`), the local paths, repo slug and branch names the engine parses, and
  the project folder name after a `.git/worktrees` path. The `free text:` line counts and lists the probe lines and the
  protected fields that hold a space or a path separator; it does not judge them. The first publication of a capture from
  a consumer repository is read by a person before it is committed.
- Free text the engine copies into `result.reason` (Sam's rationale, a target file path) is pinned as `expect.reason`, and
  the plan lines, `targetFiles` and path patterns it keeps stay in `calls` and `args`: the output lists them by path and
  length, it does not judge them. A token outside the patterns of `scripts/redact-fixture.cjs` is not caught by it.
- A minimized fixture reproduces the OBSERVED outcome, not the correct one.
- A weak oracle (status and trace only) silently drops behaviour, hence the strict one.
- A new enum or switch arg in the engine must be added to `PROTECTED_ARGS` in `scripts/publish-fixture.cjs`.

## Honesty note on `smoke/`

`smoke/auto-lgtm.json` is **synthetic-raw**: the strings are the exact shapes the engine's
prompts request (`PROBE` / `VERIFY ok` line pairs built with `probeLine()` from `templates/probe-run.cjs`, `preflight` probe pairs (`probe-<issue>-preflight-dev-r0` / `-branch-r0`), `<sha> <digest>`, JSON arrays), not a
captured transcript. It exercises the real parsers on the nominal path; it does not prove the
model returns those shapes. The first canary run replaces it with a captured one.
