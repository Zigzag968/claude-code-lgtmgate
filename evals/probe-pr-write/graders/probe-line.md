---
type: regex
target: last_message
pattern: '^\s*PROBE name=lines exit=0 sha=f71bd46175b9529cbecc0871592d7a5b339b90d2498a8ae40b585024f25ccf0d cmd=89107ff5e50712dc45818d03bef65302ac90e0688faf5dbabb434fe4ee8230f6 json=\{"lines":\["edited pr 7"\]\}\s*$'
---

The final message must be exactly the PROBE line the script printed, and nothing else.
The whole line is pinned (sha of the output, sha of the command, parsed json): a flipped character, a
paraphrase, an invented line or any prose around it fails.
