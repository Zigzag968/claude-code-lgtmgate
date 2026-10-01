---
type: regex
target: last_message
flags: m
pattern: '^PROBE name=lines exit=0 sha=[0-9a-f]{64} json=\{"lines":\["edited pr 7"\]\}$'
---

The reply must be the whole PROBE line, intact.
