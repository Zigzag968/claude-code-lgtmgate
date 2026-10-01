---
type: regex
target: last_message
flags: m
pattern: '^PROBE name=gh-pr-view-json exit=0 sha=[0-9a-f]{64} cmd=[0-9a-f]{64} json=\{.*\}$'
---

The reply must be the whole PROBE line, intact.
