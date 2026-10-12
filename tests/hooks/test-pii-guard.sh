#!/usr/bin/env bash
# Regression test for hooks/pii-guard.sh (#167): a GitHub write or commit whose text (the command plus the files it names)
# matches a pattern of the repository's .pii-patterns is refused naming the pattern, never the matched text; the same text
# without the match passes; read-only commands pass; an invalid regex is fail-closed; no .pii-patterns file means no effect.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/hooks/pii-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pii-hook-test.XXXXXX")"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# fixture repo with patterns: labelled, unlabelled, comment, blank
mkdir -p "$T/repo" "$T/clean" "$T/badre"
cat > "$T/repo/.pii-patterns" <<'PAT'
# personal data of the fixture

ssn :: [0-9]{3}-[0-9]{2}-[0-9]{4}
TOPSECRETWORD
PAT
printf 'ok :: fine\n[unclosed\n' > "$T/badre/.pii-patterns"
printf 'my number 123-45-6789 here\n' > "$T/repo/leak.md"
printf 'a harmless text\n' > "$T/repo/fine.md"

# run <dir> <command> -> sets RC, ERR
run() {
  local dir="$1" cmd="$2" input
  input="$(jq -nc --arg c "$cmd" --arg d "$dir" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  ERR="$(cd "$dir" && printf '%s' "$input" | bash "$HOOK" 2>&1 >/dev/null)"; RC=$?
}
refused() { # <label> <dir> <cmd> <pattern name>
  run "$2" "$3"
  if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "pattern $4 " && ! printf '%s' "$ERR" | grep -q '123-45-6789'; then ok "$1"; else bad "$1 (rc=$RC err=$ERR)"; fi
}
passes() { # <label> <dir> <cmd>
  run "$2" "$3"
  if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1 (rc=$RC err=$ERR)"; fi
}

R="$T/repo"
refused "gh pr create --body match" "$R" 'gh pr create --draft --title t --body "ssn 123-45-6789"' ssn
passes  "gh pr create --body clean" "$R" 'gh pr create --draft --title t --body "nothing here"'
refused "gh pr create --body-file match" "$R" 'gh pr create --title t --body-file leak.md' ssn
passes  "gh pr create --body-file clean" "$R" 'gh pr create --title t --body-file fine.md'
refused "gh issue comment --body-file match (absolute path)" "$R" "gh issue comment 5 --body-file $R/leak.md" ssn
passes  "gh issue comment --body-file clean" "$R" 'gh issue comment 5 --body-file fine.md'
refused "gh issue comment inline match" "$R" 'gh issue comment 5 --body "see 123-45-6789"' ssn
refused "gh api -X PATCH -F body=@file match" "$R" 'gh api -X PATCH repos/o/r/pulls/3 -F body=@leak.md' ssn
passes  "gh api -X PATCH -F body=@file clean" "$R" 'gh api -X PATCH repos/o/r/pulls/3 -F body=@fine.md'
refused "git commit -m match" "$R" 'git commit -m "fix for 123-45-6789"' ssn
passes  "git commit -m clean" "$R" 'git commit -m "fix: a thing"'
refused "unlabelled pattern is named line-N" "$R" 'git commit -m "has TOPSECRETWORD inside"' line-4
refused "compound command" "$R" 'cd x && git commit -am "123-45-6789"' ssn
passes  "read-only gh pr view" "$R" 'gh pr view 3 --json body'
passes  "read-only gh api GET" "$R" 'gh api repos/o/r/pulls/3'
passes  "match in a non-write command (grep)" "$R" 'grep 123-45-6789 file.txt'
passes  "pr-write.sh is left to its own check" "$R" 'bash scripts/runtime/pr-write.sh pr-comment --pr 1 --marker m --body "123-45-6789"'

run "$T/badre" 'git commit -m "plain text"'
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'pattern line-2-invalid-pattern '; then ok "invalid regex is fail-closed"; else bad "invalid regex (rc=$RC err=$ERR)"; fi

passes "no .pii-patterns: matching text passes" "$T/clean" 'git commit -m "123-45-6789"'
# a PATH without jq: only the tools the hook needs before reading the input
mkdir -p "$T/nojq"
for tool in bash dirname git sed cat grep; do
  p="$(command -v "$tool" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$T/nojq/$tool"
done
input='{"tool_input":{"command":"git commit -m x"}}'
if (cd "$T/clean" && printf '%s' "$input" | PATH="$T/nojq" /bin/bash "$HOOK" >/dev/null 2>&1); then ok "no .pii-patterns: exit 0 even without jq"; else bad "no .pii-patterns without jq"; fi
if (cd "$R" && printf '%s' "$input" | PATH="$T/nojq" /bin/bash "$HOOK" >/dev/null 2>&1); then bad "patterns present without jq must fail closed"; else ok "patterns present without jq: fail-closed"; fi

echo "[test-pii-guard] status=$([ "$fail" -eq 0 ] && echo ok || echo fail) passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
