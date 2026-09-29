---
name: triage
description: Propose label fixes for inbox and needs-info issues; never applies them
disable-model-invocation: true
argument-hint: [optional focus, e.g. an issue number]
---

# /backlog:triage

Recommend, then pause. This skill PROPOSES label changes for the issues awaiting triage. It has no apply path: it never edits an issue, and neither does the plugin. You never run `gh` yourself.

Focus from the user (optional): `$ARGUMENTS`.

## Steps

1. Read the repo mode:
   ```bash
   python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" config
   ```
   If it prints `mode=off`, STOP and say the backlog plugin is inactive in this repo (no `.claude/backlog.yml`).

2. List what awaits triage:
   ```bash
   python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" inbox
   ```
   It prints a JSON list of open issues in the intake or waiting status. Read them (and, only if needed, their bodies through the user's own tools) and decide, per issue, the target labels.

3. Write the proposals as a JSON list to a file under `$TMPDIR`, one entry per issue you would change:
   `{"issue": <n>, "labels_before": [...], "labels_after": [...], "reason": "<why>", "confidence": "high|medium|low"}`.
   Only labels of the configured axes may change. Never touch `nightly`, `cross-repo`, `money-path` or `auto:*`. When unsure, leave the issue out.

4. Validate:
   ```bash
   python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" triage-check --proposals "$TMPDIR/backlog-proposals.json"
   ```
5. Present the table and the `table-digest` to the user, then PAUSE. Say plainly that applying is out of scope for this plugin version: the user applies the accepted rows by hand, or decides otherwise. Do not attempt to apply, whatever the mode.
