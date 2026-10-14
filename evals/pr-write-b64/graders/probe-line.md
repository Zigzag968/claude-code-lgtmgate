---
type: regex
target: last_message
pattern: '^\s*PROBE name=pr-write exit=0 sha=ddf9ebb84945d5b33e38a553d87b65badd98870cbbec4afad14ec38c7e3527ea cmd=230821c1163f5e3e8cccd445e952499e842d791a8da1925faace926310763b07 json=\{"op":"body-splice","result":"written","reason":null,"bytes":2440\}\s*$'
---

The final message must be exactly the PROBE line the script printed, and nothing else.
The whole line is pinned (sha of the output, sha of the command, parsed json): a flipped character, a
paraphrase, an invented line or any prose around it fails.
