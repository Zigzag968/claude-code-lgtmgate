#!/usr/bin/env bash
# forwarder to scripts/runtime/preflight.sh, removed after one release (#312)
exec bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/runtime/preflight.sh" "$@"
