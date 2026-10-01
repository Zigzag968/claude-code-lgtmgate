---
type: regex
target: trace
pattern: '"type":"tool_result","content":"(?:[^"\\]|\\.)*VERIFY ok line=PROBE name=lines exit=0 sha=f71bd46175b9529cbecc0871592d7a5b339b90d2498a8ae40b585024f25ccf0d'
---

The trace must hold the VERIFY ok line that probe-run.cjs --verify printed, inside a Bash tool_result.
The pattern is anchored on a tool_result content string (JSON-escaped in the trace), so the same text
written by the agent in prose or in its report does not count. The sha is the one of the real output:
the commands really ran and exited 0, the PROBE line was not invented.
