---
type: regex
target: trace
pattern: '"type":"tool_result","content":"(?:[^"\\]|\\.)*VERIFY ok line=PROBE name=gh-pr-view-json exit=0 sha=df193c40b67f4ed5fa2b5d754e4252c473682a6434f6f5486aa765d9e1738766'
---

The trace must hold the VERIFY ok line that probe-run.cjs --verify printed, inside a Bash tool_result.
The pattern is anchored on a tool_result content string (JSON-escaped in the trace), so the same text
written by the agent in prose or in its report does not count. The sha is the one of the real output:
the commands really ran and exited 0, the PROBE line was not invented.
