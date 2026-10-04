#!/usr/bin/env bash
# gh-read-class.sh — names the CAUSE of a failed `gh` read as one word from a closed set (#239). SOURCED by
# pr-write.sh and preflight.sh, never run on its own.
#
#   gh_read_class <stderr text>   prints nothing for an empty text (no cause known), else exactly one of
#                                 tls | rate-limit | auth | not-found | other
#
# Why a class and not the text: the line a probe prints is attested and hashed, and `gh` stderr can hold URLs and
# tokens, so only the class leaves the script, never the text. Checked in this order (the first match wins); an
# unknown message is `other`, never a wrong specific class. Plain `case` globs: no regex, no `gh` call, bash 3.2.
#
#   tls         the TLS certificate could not be verified (a Go binary under a macOS sandbox cannot reach the system
#               trust daemon: anthropics/claude-code#34876, #82793)
#   rate-limit  the GraphQL counter is spent (cli/cli#8321)
#   auth        a 401, bad credentials, or gh asking for a login
#   not-found   the PR / issue does not exist (or is not visible)
gh_read_class() {
  local t="${1:-}"
  [ -n "$t" ] || return 0
  case "$t" in
    *x509*|*"tls:"*|*certificate*) printf 'tls\n' ;;
    *"rate limit"*) printf 'rate-limit\n' ;;
    *"HTTP 401"*|*"Bad credentials"*|*"gh auth login"*) printf 'auth\n' ;;
    *"Could not resolve to a"*|*"HTTP 404"*) printf 'not-found\n' ;;
    *) printf 'other\n' ;;
  esac
}
