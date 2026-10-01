#!/usr/bin/env bash
# Runs scripts/run-probe-evals.sh inside a local Linux container (.devcontainer/), for macOS hosts
# where `claude plugin eval` cannot run natively (anthropics/claude-code#94308). Local only, spends tokens.
# Why seccomp=unconfined: Docker's default profile blocks the user namespaces bubblewrap needs.
# Why systempaths=unconfined: Docker masks parts of /proc, and bubblewrap needs a full /proc to mount a
# fresh one in its sandbox ("Can't mount proc on /newroot/proc", containers/bubblewrap#284).
# Needs: Docker, and CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`) or ANTHROPIC_API_KEY exported on the host.
# Extra args are forwarded to run-probe-evals.sh (optional case names). bash 3.2 safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${PROBE_EVALS_IMAGE:-lgtmgate-probe-evals}"

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "run-probe-evals-docker: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set." >&2
  echo "  Run 'claude setup-token', then: export CLAUDE_CODE_OAUTH_TOKEN=<token> (or export ANTHROPIC_API_KEY)" >&2
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
  --security-opt systempaths=unconfined \
  -e CLAUDE_CODE_OAUTH_TOKEN -e ANTHROPIC_API_KEY \
  -v "$ROOT:/workspace" -w /workspace \
  "$IMAGE" bash scripts/run-probe-evals.sh "$@"
exit $?
