#!/usr/bin/env bash
# Preflight for the probe evals (#234): names the failing prerequisite in under 10 s instead of letting a
# run die late. No model call, no network, never reads the secret.
#   eval-preflight.sh [docker|host]   (default docker)
#   docker: `docker` on PATH, the daemon answers within 5 s, and (when no credential env var is set) the
#           Keychain item `lgtmgate-eval-token` exists (existence only, no -w).
#   host:   `claude` on PATH, and no symbolic link in the Docker credential store, which makes
#           `claude plugin eval` refuse on the host (anthropics/claude-code#94308).
# Exit: 0 ok, 1 missing prerequisite, 3 eval-not-runnable (host refusal, not a probe result). bash 3.2 safe.
set -u

MODE="${1:-docker}"
PROBE_TIMEOUT=5
KEYCHAIN_ITEM="lgtmgate-eval-token"

# with_timeout <secs> cmd...: macOS has no `timeout`; background, poll, kill on expiry (124).
with_timeout() {
  local secs="$1" pid i=0 max
  shift
  max=$((secs * 2))
  "$@" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$max" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.5
    i=$((i + 1))
  done
  wait "$pid"
}

case "$MODE" in
  docker)
    if ! command -v docker >/dev/null 2>&1; then
      echo "eval-preflight: docker not found on PATH. Fix: install Docker Desktop and start it." >&2
      exit 1
    fi
    if ! with_timeout "$PROBE_TIMEOUT" docker version --format '{{.Server.Version}}'; then
      echo "eval-preflight: Docker daemon not answering within ${PROBE_TIMEOUT}s. Fix: start Docker Desktop and wait for the whale icon to settle, then rerun." >&2
      exit 1
    fi
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      if ! command -v security >/dev/null 2>&1 || ! with_timeout "$PROBE_TIMEOUT" security find-generic-password -s "$KEYCHAIN_ITEM"; then
        echo "eval-preflight: Keychain item $KEYCHAIN_ITEM not readable." >&2
        echo "  Fix: claude setup-token, then: security add-generic-password -a \"\$USER\" -s $KEYCHAIN_ITEM -T /usr/bin/security -w" >&2
        echo "  Over SSH: security unlock-keychain first." >&2
        exit 1
      fi
    fi
    echo "eval-preflight: ok (docker)"
    ;;
  host)
    if ! command -v claude >/dev/null 2>&1; then
      echo "eval-preflight: claude CLI not found on PATH" >&2
      exit 1
    fi
    store="${DOCKER_CONFIG:-$HOME/.docker}"
    link=""
    if [ -d "$store" ]; then
      link="$(find "$store" -type l 2>/dev/null | head -n 1)"
    fi
    if [ -n "$link" ]; then
      echo "eval-not-runnable: symbolic link in the Docker credential store ($link); claude plugin eval refuses on this host." >&2
      echo "  Fix: run bash scripts/run-probe-evals-docker.sh (anthropics/claude-code#94308)." >&2
      exit 3
    fi
    echo "eval-preflight: ok (host)"
    ;;
  *)
    echo "usage: eval-preflight.sh [docker|host]" >&2
    exit 2
    ;;
esac
exit 0
