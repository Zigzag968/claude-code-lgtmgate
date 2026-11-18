# Probe first-request tokens (omitClaudeMd measurement)

- Issue: #616. Read-only measurement of existing subagent transcripts; no new run launched.
- Metric: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the first `assistant` line `usage` of each `lgtmgate:probe` agent, grouped by UTC day.
- Field under test: `agents/probe.md` line 5 `omitClaudeMd: true` (merged 2026-10-17, PR #586).

## Command

- `node docs/bench/probe-first-request.cjs` (default corpus `~/.claude/projects`; optional `argv[2]` = other directory).
- Read-only: no file written, no network, no dependency; exits 0 on a directory with no transcripts.

## Result

| day | calls | median | min | max |
|---|---|---|---|---|
| 2026-09-30 | 8 | 31181 | 31128 | 31244 |
| 2026-10-01 | 324 | 31675 | 31128 | 42792 |
| 2026-10-02 | 326 | 32070 | 31925 | 43112 |
| 2026-10-03 | 273 | 32210 | 30617 | 44799 |
| 2026-10-04 | 308 | 41313 | 31088 | 48016 |
| 2026-10-05 | 215 | 46354 | 31748 | 54544 |
| 2026-10-06 | 61 | 46336 | 46171 | 48301 |
| 2026-10-08 | 231 | 59249 | 58999 | 59745 |
| 2026-10-09 | 12 | 59153 | 59077 | 59262 |
| 2026-10-10 | 6 | 59221 | 59107 | 59412 |
| 2026-10-12 | 224 | 50915 | 46972 | 51371 |
| 2026-10-13 | 570 | 47425 | 46648 | 51503 |
| 2026-10-14 | 437 | 47334 | 41789 | 51703 |
| 2026-10-15 | 575 | 41397 | 28561 | 47945 |
| 2026-10-16 | 19 | 41950 | 41847 | 42113 |
| 2026-10-17 | 833 | 29211 | 23691 | 51814 |
| 2026-10-18 | 67 | 29197 | 28950 | 30268 |
| 2026-10-19 | 226 | 29624 | 8831 | 30145 |
| 2026-10-26 | 56 | 36144 | 36025 | 36351 |
| 2026-10-28 | 22 | 36317 | 36176 | 36513 |
| 2026-10-31 | 249 | 30076 | 29450 | 31205 |
| 2026-11-01 | 40 | 30011 | 8192 | 30338 |
| 2026-11-02 | 82 | 9371 | 8143 | 29812 |
| 2026-11-05 | 20 | 9741 | 9595 | 9850 |
| 2026-11-06 | 18 | 9755 | 9705 | 9849 |
| 2026-11-07 | 31 | 9739 | 9595 | 11127 |
| 2026-11-08 | 176 | 9677 | 9174 | 10219 |
| 2026-11-09 | 88 | 9265 | 8144 | 10185 |
| 2026-11-10 | 38 | 9957 | 9337 | 10141 |
| 2026-11-12 | 1 | 8677 | 8677 | 8677 |
| 2026-11-13 | 43 | 8446 | 8330 | 8680 |
| 2026-11-16 | 34 | 8906 | 8726 | 9051 |

probe meta files: 5615, days with a first request: 32

## Before/after summary

- Last stable stretch before the field (2026-10-17 to 2026-11-01): median about 29k to 32k (36k on 2026-10-26 and 2026-10-28).
- After the field (2026-11-05 onward): median about 9.3k to 9.8k (8.4k to 8.9k from 2026-11-12).
- 2026-11-02: mixed day, 82 calls, median 9371, min 8143, max 29812.
- Arrival day inferred from the data, not from a release record: `git log -S omitClaudeMd -- agents/probe.md` gives a3ddf8d (2026-10-17, PR #586 merged the same day); the drop shows at 2026-11-02, about two weeks later.
- Separate earlier step: 2026-10-17 also drops (about 47k to 29k), before the field reached the corpus. Other cause (launch facts skipping probes, same PR #586), not `omitClaudeMd`.

## Evidence

- Probe `agent-ad3cae5fa619a6e48`, workflow wf_29292c19-c92, phase Setup, timestamp 2026-11-16T23:52:30.085Z.
- `meta.json`:

```json
{"agentType":"lgtmgate:probe","isBuiltIn":false,"description":"probe-616-provision-provision-r0","workflowPhase":"Setup","spawnDepth":1,"requestShape":"foreground","requestNonInteractive":false,"model":"haiku","pickedEffortModel":"claude-sonnet-5-5","inWorkflowRun":true}
```

- First-request `usage`: `{"input_tokens":2,"cache_creation_input_tokens":5735,"cache_read_input_tokens":3171,...}`
- Sum: 2 + 5735 + 3171 = 8908, inside the 2026-11-16 row range (8726 to 9051).

## Known limit

- Plugin version is not recorded per call: neither `meta.json` nor `prefix.json` carries it.
- Attribution of the drop to `omitClaudeMd` is observed, not proven (not proven by any per-call version field).
- `systemCharCount` is stable per issue body, so it does not separate causes.
- The 2026-10-17 step has another cause (see above).
- Figures depend on the local `~/.claude/projects` corpus (`<project>` transcripts); not reproducible elsewhere. Corpus kept growing since the issue count (5538 transcripts).
