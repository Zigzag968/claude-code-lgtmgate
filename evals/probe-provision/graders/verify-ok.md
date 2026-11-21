---
type: regex
target: trace
pattern: '"type":"tool_result","content":"(?:[^"\\]|\\.)*VERIFY ok linesha=2e7638175328ecc539f8a4ed21751eaef65d20d5cbf1caec8660e5a91ac928ea'
---

The trace must hold the VERIFY ok line that probe-run.cjs --verify printed, inside a Bash tool_result.
The pattern is anchored on a tool_result content string (JSON-escaped in the trace), so the same text
written by the agent in prose or in its report does not count. The digest is the sha256 of the pinned PROBE line (the one of the real output):
the commands really ran and exited 0, the PROBE line was not invented.
