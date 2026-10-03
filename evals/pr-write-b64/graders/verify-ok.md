---
type: regex
target: trace
pattern: '"type":"tool_result","content":"(?:[^"\\]|\\.)*VERIFY ok line=PROBE name=pr-write exit=0 sha=ddf9ebb84945d5b33e38a553d87b65badd98870cbbec4afad14ec38c7e3527ea'
---

The trace must hold the VERIFY ok line that probe-run.cjs --verify printed, inside a Bash tool_result.
The pattern is anchored on a tool_result content string (JSON-escaped in the trace), so the same text
written by the agent in prose or in its report does not count. The sha is the one of the real output:
the commands really ran and exited 0, the PROBE line was not invented.
