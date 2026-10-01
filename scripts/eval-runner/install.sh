#!/usr/bin/env bash
# Installs the eval runner LaunchAgent files (#81). Run once by the human. bash 3.2 safe.
# Usage: install.sh [--dry-run] <spool-dir> <allowed-root>   |   install.sh --uninstall
# - Writes the plist and a copy of the runner; does NOT load the job and does NOT touch the Keychain.
# - --dry-run prints the plist to stdout and writes nothing.
set -u

LABEL="dev.lgtmgate.eval-runner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNNER_DST="$HOME/Library/Application Support/lgtmgate/eval-runner.sh"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lgtmgate-eval-runner.sh"

mode="install"
case "${1:-}" in
  --dry-run) mode="dry"; shift ;;
  --uninstall) mode="uninstall"; shift ;;
esac

if [ "$mode" = "uninstall" ]; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LABEL" || true
  fi
  rm -f "$PLIST" "$RUNNER_DST"
  echo "uninstalled $LABEL (spool directory and Keychain item left untouched)"
  echo "optional: security delete-generic-password -a \"\$USER\" -s lgtmgate-eval-token"
  exit 0
fi

if [ $# -ne 2 ]; then echo "usage: install.sh [--dry-run] <spool-dir> <allowed-root> | --uninstall" >&2; exit 2; fi
case "$1" in /*) ;; *) echo "install: spool-dir must be absolute" >&2; exit 2 ;; esac
case "$2" in /*) ;; *) echo "install: allowed-root must be absolute" >&2; exit 2 ;; esac
spool="${1%/}"; allowed="${2%/}"

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$RUNNER_DST")</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>$(xml "$spool/inbox")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SPOOL</key>
    <string>$(xml "$spool")</string>
    <key>ALLOWED_ROOT</key>
    <string>$(xml "$allowed")</string>
    <key>PATH</key>
    <string>$(xml "/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml "$spool/launchd.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$spool/launchd.log")</string>
</dict>
</plist>
PLIST
}

if [ "$mode" = "dry" ]; then plist; exit 0; fi

mkdir -p "$spool/inbox" "$spool/running" "$spool/done" "$HOME/Library/LaunchAgents" "$(dirname "$RUNNER_DST")" || exit 1
cp "$SRC" "$RUNNER_DST" || exit 1
plist > "$PLIST" || exit 1

cat <<MSG
Installed (not loaded): $PLIST
Runner copy: $RUNNER_DST
Spool: $spool   Allowed root: $allowed

Next, run these yourself:
  1. claude setup-token
  2. security add-generic-password -a "\$USER" -s lgtmgate-eval-token -T /usr/bin/security -w
     (prompts for the token, so it never lands in shell history)
  3. launchctl bootstrap gui/\$(id -u) $PLIST

The session then runs: LGTMGATE_EVAL_SPOOL=$spool bash scripts/eval-runner/trigger.sh --wait 1800 <worktree>
MSG
