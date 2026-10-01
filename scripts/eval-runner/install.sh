#!/usr/bin/env bash
# Installs the eval runner LaunchAgent files (#81). Run once by the human. bash 3.2 safe.
# Usage: install.sh [--dry-run] <spool-dir>   |   install.sh --uninstall
# - Writes the plist and a copy of the runner; does NOT load the job and does NOT touch the Keychain.
# - The spool must be on the boot disk: macOS TCC blocks a launchd job from reading /Volumes/*. Suggested: /tmp/claude/lgtmgate-eval-spool
# - Env LGTMGATE_REPO_URL overrides the clone URL written to the plist.
# - --dry-run prints the plist to stdout and writes nothing.
set -u

LABEL="dev.lgtmgate.eval-runner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNNER_DST="$HOME/Library/Application Support/lgtmgate/eval-runner.sh"
REPO_URL="${LGTMGATE_REPO_URL:-https://github.com/Zigzag968/claude-code-lgtmgate.git}"
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

if [ $# -ne 1 ]; then echo "usage: install.sh [--dry-run] <spool-dir> | --uninstall" >&2; exit 2; fi
case "$1" in /*) ;; *) echo "install: spool-dir must be absolute" >&2; exit 2 ;; esac
case "$1" in
  /Volumes/*)
    echo "install: refused: a launchd job cannot read an external volume (macOS TCC: 'Operation not permitted')." >&2
    echo "install: pick a spool on the boot disk, e.g. /tmp/claude/lgtmgate-eval-spool" >&2
    exit 2 ;;
esac
spool="${1%/}"

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
    <key>REPO_URL</key>
    <string>$(xml "$REPO_URL")</string>
    <key>PATH</key>
    <string>$(xml "/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
  </dict>
  <!-- launchd exits 78 (EX_CONFIG) without starting a job whose log path is on an external volume: keep it on the boot disk. -->
  <key>StandardOutPath</key>
  <string>$(xml "$HOME/Library/Logs/lgtmgate-eval-runner.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$HOME/Library/Logs/lgtmgate-eval-runner.log")</string>
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
Spool: $spool   Repo: $REPO_URL

Next, run these yourself:
  1. claude setup-token
  2. security add-generic-password -a "\$USER" -s lgtmgate-eval-token -T /usr/bin/security -w
     (prompts for the token, so it never lands in shell history)
  3. launchctl bootstrap gui/\$(id -u) $PLIST

The eval runs on the PUSHED state of <branch> (fresh clone per trigger).
The session then runs: LGTMGATE_EVAL_SPOOL=$spool bash scripts/eval-runner/trigger.sh --wait 1800 <branch>
MSG
