#!/usr/bin/env bash
# Runs scripts/run-probe-evals.sh inside a local Linux container (.devcontainer/), for macOS hosts
# where `claude plugin eval` cannot run natively (anthropics/claude-code#94308). Local only, spends tokens.
# Why seccomp=unconfined: Docker's default profile blocks the user namespaces bubblewrap needs.
# Needs: Docker, and CLAUDE_CODE_OAUTH_TOKEN exported on the host (`claude setup-token`).
# Extra args are forwarded to run-probe-evals.sh (it currently takes none). bash 3.2 safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${PROBE_EVALS_IMAGE:-lgtmgate-probe-evals}"

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "run-probe-evals-docker: CLAUDE_CODE_OAUTH_TOKEN is not set." >&2
  echo "  Run 'claude setup-token', then: export CLAUDE_CODE_OAUTH_TOKEN=<token>" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "run-probe-evals-docker: docker not found on PATH" >&2
  exit 1
fi

docker build -t "$IMAGE" "$ROOT/.devcontainer" || exit 1

# Keep in sync with runArgs in .devcontainer/devcontainer.json.
docker run --rm \
  --security-opt seccomp=unconfined \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -v "$ROOT:/workspace" -w /workspace \
  "$IMAGE" bash scripts/run-probe-evals.sh "$@"
exit $?
