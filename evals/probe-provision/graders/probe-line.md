---
type: regex
target: last_message
pattern: '^\s*PROBE name=provision exit=0 sha=13545932077c0ffa362d1323d1ba86b360ba278619bef52d8d10c7ee7ec290e3 cmd=bf63c24fc73cff41fcb2c2a65f2694e6638f991154f88995aba87274168d7f0f json=\{"version":2,"linked":\["\.env"\],"missing":\[\],"skipped":false\}\s*$'
---

The final message must be exactly the PROBE line the script printed, and nothing else.
The whole line is pinned (sha of the output, sha of the command, parsed json): a flipped character, a
paraphrase, an invented line or any prose around it fails.
