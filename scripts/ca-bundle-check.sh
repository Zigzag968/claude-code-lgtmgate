#!/usr/bin/env bash
# Sandbox certificate bundle check (#251): scripts/ca-bundle-check.sh
# The sandbox writes one certificate bundle at session start and exports it as SSL_CERT_FILE and GIT_SSL_CAINFO (and three
# more variables that name the same file). macOS cleans files older than three days from the user temp directory and nothing
# recreates the bundle, so a session older than that has every git and gh call over HTTPS fail on certificates. The Lead runs
# this at the start of a run (skills/deliver/SKILL.md step 0) so the run fails by name instead of three agents later.
# For each of SSL_CERT_FILE and GIT_SSL_CAINFO, in that order: unset or empty -> skipped; names a missing file -> stale
# (cause "missing"); names an empty file -> stale (cause "empty"). The first stale variable prints one line starting with
# `sandbox-ca-stale` and exits 1. Otherwise it prints `ca-bundle-check: ok (<n> variable(s) checked)` or
# `ca-bundle-check: nothing to check (...)` and exits 0. Read-only, no network, never prints the file path.
set -u

checked=0
for var in SSL_CERT_FILE GIT_SSL_CAINFO; do
  val="${!var:-}"
  [ -n "$val" ] || continue
  checked=$((checked + 1))
  cause=""
  if [ ! -e "$val" ]; then
    cause="missing"
  elif [ ! -s "$val" ]; then
    cause="empty"
  fi
  if [ -n "$cause" ]; then
    echo "sandbox-ca-stale: $var names a $cause file: the sandbox certificate bundle of this session is gone (macOS clears it after three days); restart the session, then relaunch (see docs/long-lived-sessions.md)"
    exit 1
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "ca-bundle-check: nothing to check (SSL_CERT_FILE and GIT_SSL_CAINFO unset)"
else
  echo "ca-bundle-check: ok ($checked variable(s) checked)"
fi
exit 0
