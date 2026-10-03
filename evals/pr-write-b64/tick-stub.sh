#!/usr/bin/env bash
# Stand-in for templates/pr-write.sh in the pr-write-b64 eval (no gh, no network): reads the same flags as the
# real body-splice tick (--text-b64 <base64 of the block>), decodes the token and prints the one JSON line the
# pr-write parser reads, with the exact byte count of the decoded block. A copy of the token that lost or
# changed a character decodes to another size, and the command digest gate refuses it before this runs.
set -u
b64=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-b64) b64="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$b64" ] || { echo '{"op":"body-splice","result":"failed","reason":"bad-args","bytes":null}'; exit 0; }
n="$(node -e 'process.stdout.write(String(Buffer.from(process.argv[1], "base64").length))' "$b64")"
printf '{"op":"body-splice","result":"written","reason":null,"bytes":%s}\n' "$n"
