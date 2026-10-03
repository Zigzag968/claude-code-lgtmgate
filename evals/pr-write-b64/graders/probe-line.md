---
type: regex
target: last_message
pattern: '^\s*PROBE name=pr-write exit=0 sha=ddf9ebb84945d5b33e38a553d87b65badd98870cbbec4afad14ec38c7e3527ea cmd=234325b46b44270eea6726c16b0e3ac76a171a133f6a2ce479d722b22214f804 json=\{"op":"body-splice","result":"written","reason":null,"bytes":2440\}\s*$'
---

The final message must be exactly the PROBE line the script printed, and nothing else.
The whole line is pinned (sha of the output, sha of the command, parsed json): a flipped character, a
paraphrase, an invented line or any prose around it fails.
