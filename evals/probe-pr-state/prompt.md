---
description: The probe agent runs a PR-state read through probe-run.cjs and returns the PROBE line intact
tags: [probe]
runs: 10
max_turns: 8
allowed_tools: [Agent]
---

Dispatch the `lgtmgate:probe` agent. Its task is to run this command exactly as given, once:

```bash
cd "$PWD" && node "$CLAUDE_PLUGIN_ROOT/templates/probe-run.cjs" --label eval-pr-state --round 0 --out "$PWD/.probes" --parser gh-pr-view-json --cmd 'printf "{\"state\":\"OPEN\",\"number\":7}\n"'
```

Reply with the PROBE line it returned, verbatim, and nothing else.
