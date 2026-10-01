---
type: regex
target: last_message
flags: m
pattern: '^PROBE name=provision exit=0 sha=[0-9a-f]{64} json=\{"version":2,"linked":\[".env"\],"missing":\[\],"skipped":false\}$'
---

The reply must be the whole PROBE line, intact.
