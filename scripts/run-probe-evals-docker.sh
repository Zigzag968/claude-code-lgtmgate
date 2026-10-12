#!/usr/bin/env bash
# Runs scripts/run-probe-evals.sh inside a local Linux container (.devcontainer/), for macOS hosts
# where `claude plugin eval` cannot run natively (anthropics/claude-code#94308). Local only, spends tokens.
# Why seccomp=unconfined: Docker's default profile blocks the user namespaces bubblewrap needs.
# Why systempaths=unconfined: Docker masks parts of /proc, and bubblewrap needs a full /proc to mount a
# fresh one in its sandbox ("Can't mount proc on /newroot/proc", containers/bubblewrap#284).
# Why --init: a tini PID 1 forwards SIGINT/SIGTERM, so Ctrl-C stops a run instead of leaving the container up.
# Needs: Docker running, and the Keychain item `lgtmgate-eval-token` (`claude setup-token`), which this script
# reads itself: the token goes only into the docker child's environment, never into argv, a file or the caller's
# shell. A caller who already exported CLAUDE_CODE_OAUTH_TOKEN skips the Keychain read.
# The container mounts the repo read-only, with only evals/results writable. `bash scripts/eval-preflight.sh docker` checks the prerequisites.
# Extra args are optional case names, forwarded to run-probe-evals.sh. bash 3.2 safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${PROBE_EVALS_IMAGE:-lgtmgate-probe-evals}"

# The command may be pre-authorised with any args: only plain case names that exist are accepted.
for c in "$@"; do
  case "$c" in
    *[!a-z0-9-]*|-*|"") echo "usage: run-probe-evals-docker.sh [case...]  (bad case name: $c)" >&2; exit 2 ;;
  esac
  if [ ! -f "$ROOT/evals/$c/prompt.md" ]; then
    echo "usage: run-probe-evals-docker.sh [case...]  (no evals/$c/prompt.md)" >&2
    exit 2
  fi
done

bash "$SCRIPT_DIR/eval-preflight.sh" docker || exit $?

tok=""
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  tok="$(security find-generic-password -s lgtmgate-eval-token -w 2>/dev/null)"
  if [ -z "$tok" ]; then
    echo "run-probe-evals-docker: Keychain item lgtmgate-eval-token is empty or locked (over SSH: security unlock-keychain)." >&2
    exit 1
  fi
fi

mkdir -p "$ROOT/evals/results" || exit 1
docker build -t "$IMAGE" "$ROOT/.devcontainer" || exit 1

# Keep in sync with runArgs in .devcontainer/devcontainer.json. -e takes names only: values stay in the child env.
if [ -n "$tok" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$tok" docker run --rm --init \
    --security-opt seccomp=unconfined \
    --security-opt systempaths=unconfined \
    -e CLAUDE_CODE_OAUTH_TOKEN \
    -v "$ROOT:/workspace:ro" -v "$ROOT/evals/results:/workspace/evals/results" -w /workspace \
    "$IMAGE" bash scripts/run-probe-evals.sh "$@"
  rc=$?
else
  docker run --rm --init \
    --security-opt seccomp=unconfined \
    --security-opt systempaths=unconfined \
    -e CLAUDE_CODE_OAUTH_TOKEN \
    -v "$ROOT:/workspace:ro" -v "$ROOT/evals/results:/workspace/evals/results" -w /workspace \
    "$IMAGE" bash scripts/run-probe-evals.sh "$@"
  rc=$?
fi
unset tok
exit "$rc"
