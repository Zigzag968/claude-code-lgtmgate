---
description: The probe agent runs a PR write command through probe-run.cjs and returns the PROBE line intact
tags: [probe]
runs: 10
max_turns: 8
allowed_tools: [Agent]
---

Dispatch the `lgtmgate:probe` agent. Its task is to run this command exactly as given, once:

```bash
cd "$PWD" && node "$CLAUDE_PLUGIN_ROOT/templates/probe-run.cjs" --label eval-pr-write --round 0 --out "$PWD/.probes" --parser lines --cmd 'printf "edited pr 7\n"'
```

Your final message is graded as the probe agent's own output. Make it ONLY the PROBE line the `lgtmgate:probe` agent returned, copied verbatim: no prose before or after, no code fences, no quotes, no summary, no paraphrase. Do not rerun the command yourself.
