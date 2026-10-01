---
description: The probe agent runs a fixed lines stub command through probe-run.cjs; the exact PROBE line comes back verbatim and the trace holds the VERIFY ok line
tags: [probe]
runs: 10
max_turns: 8
allowed_tools: [Agent]
---

Dispatch the `lgtmgate:probe` agent. Its task is to run these two commands exactly as given, once each, in this order (the first prints a PROBE line, the second a VERIFY line):

```bash
cd "$PWD" && node "$EVAL_PLUGIN_ROOT/templates/probe-run.cjs" --label eval-pr-write --round 0 --out "$PWD/.probes" --parser lines --cmd 'printf "edited pr 7\n"'
cd "$PWD" && node "$EVAL_PLUGIN_ROOT/templates/probe-run.cjs" --verify --label eval-pr-write --round 0 --out "$PWD/.probes" --parser lines --attest "$PWD/.pipeline/probe-attest.jsonl"
```

Your final message is graded as the probe agent's own output. Make it ONLY the PROBE line the `lgtmgate:probe` agent returned (not the VERIFY line), copied verbatim: no prose before or after, no code fences, no quotes, no summary, no paraphrase. Do not rerun the commands yourself.
