---
type: regex
target: trace
pattern: '"type":"tool_result","content":"(?:[^"\\]|\\.)*VERIFY ok linesha=bec3ac97db9a29dce9fe52ad357cc0ccfa551f2c961b0476eeaffa2ae31a94ca'
---

The trace must hold the VERIFY ok line that probe-run.cjs --verify printed, inside a Bash tool_result.
The pattern is anchored on a tool_result content string (JSON-escaped in the trace), so the same text
written by the agent in prose or in its report does not count. The digest is the sha256 of the pinned PROBE line (the one of the real output):
the commands really ran and exited 0, the PROBE line was not invented.
