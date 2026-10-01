---
type: regex
target: last_message
pattern: '^\s*PROBE name=gh-pr-view-json exit=0 sha=df193c40b67f4ed5fa2b5d754e4252c473682a6434f6f5486aa765d9e1738766 cmd=9a7448db0bb2943991c3d0e6378459944e371db7ed0e4a33b8908d77e58a8aef json=\{"state":"OPEN","number":7\}\s*$'
---

The final message must be exactly the PROBE line the script printed, and nothing else.
The whole line is pinned (sha of the output, sha of the command, parsed json): a flipped character, a
paraphrase, an invented line or any prose around it fails.
