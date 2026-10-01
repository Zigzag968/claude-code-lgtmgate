---
type: regex
target: trace
pattern: '"type":"tool_result","content":"(?:[^"\\]|\\.)*VERIFY ok line=PROBE name=provision exit=0 sha=13545932077c0ffa362d1323d1ba86b360ba278619bef52d8d10c7ee7ec290e3'
---

The trace must hold the VERIFY ok line that probe-run.cjs --verify printed, inside a Bash tool_result.
The pattern is anchored on a tool_result content string (JSON-escaped in the trace), so the same text
written by the agent in prose or in its report does not count. The sha is the one of the real output:
the commands really ran and exited 0, the PROBE line was not invented.
