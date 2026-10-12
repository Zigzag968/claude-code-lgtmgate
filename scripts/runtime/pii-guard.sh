#!/usr/bin/env bash
# pii-guard.sh — deterministic personal-data guard for texts written to GitHub (#167).
#
# Usage:
#   bash pii-guard.sh exists [--dir DIR]   exit 0 when a .pii-patterns file applies to DIR, else exit 1 (prints nothing)
#   bash pii-guard.sh check  [--dir DIR]   text on stdin; exit 0 = clean (or no patterns file), exit 1 = refused
#                                          stdout on refusal: pii-refused:<name>   (the NAME only, never the matched text)
#
# The patterns file `.pii-patterns` lives in the target repository root (the main checkout: it is git-ignored,
# so a worktree never holds it). Looked up in DIR (default $PWD), then in the parent of the git common dir.
# One extended regular expression (grep -E) per line; blank lines and lines starting with `#` are ignored.
# Optional label: `<label> :: <regex>` with <label> in [A-Za-z0-9_-]+; an unlabelled line is named line-<N>.
# Case-sensitive, matched line by line of the text.
# Fail-closed: an unreadable file or an invalid regex refuses with pii-refused:line-<N>-invalid-pattern.
# No file = exit 0 at once, nothing printed. The plugin ships no default pattern. bash 3.2 compatible, never rm.

set -uo pipefail

CMD="${1:-}"
[ $# -ge 1 ] && shift
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift ;;
  esac
  shift
done
[ -n "$DIR" ] || DIR="$PWD"

find_patterns() {
  local gc root
  if [ -e "$DIR/.pii-patterns" ]; then printf '%s\n' "$DIR/.pii-patterns"; return 0; fi
  gc="$(cd "$DIR" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || gc=""
  case "$gc" in
    */.git) root="${gc%/.git}"; if [ -e "$root/.pii-patterns" ]; then printf '%s\n' "$root/.pii-patterns"; return 0; fi ;;
  esac
  return 1
}

case "$CMD" in
  exists)
    find_patterns >/dev/null
    exit $?
    ;;
  check)
    pf="$(find_patterns)" || exit 0
    if [ ! -r "$pf" ] || [ -d "$pf" ]; then printf 'pii-refused:line-0-invalid-pattern\n'; exit 1; fi
    text="$(cat)"
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      if [ -z "${line//[[:space:]]/}" ]; then continue; fi
      name="line-$n"; re="$line"
      if [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]+::[[:space:]]+(.*)$ ]]; then
        name="${BASH_REMATCH[1]}"; re="${BASH_REMATCH[2]}"
      fi
      printf '' | grep -Eq -e "$re" 2>/dev/null
      if [ $? -eq 2 ]; then printf 'pii-refused:line-%s-invalid-pattern\n' "$n"; exit 1; fi
      if printf '%s\n' "$text" | grep -Eq -e "$re" 2>/dev/null; then printf 'pii-refused:%s\n' "$name"; exit 1; fi
    done < "$pf"
    exit 0
    ;;
  *)
    echo "usage: pii-guard.sh exists|check [--dir DIR]" >&2
    exit 64
    ;;
esac
