---
name: file
description: File one well-formed backlog issue (dry run first, create only as the repo mode allows)
disable-model-invocation: true
argument-hint: <title> [--label type:bug] [--label area:x]
---

# /backlog:file

File ONE new issue in the current repo through the backlog plugin. You never run `gh` yourself: everything goes through `backlog_cli.py`, which enforces the repo's `.claude/backlog.yml`.

Arguments from the user: `$ARGUMENTS` (a title, and optionally labels to set).

## Steps

1. Read the repo mode:
   ```bash
   python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" config
   ```
   If it prints `mode=off`, STOP. Tell the user the backlog plugin is inactive here and that `${CLAUDE_PLUGIN_ROOT}/templates/backlog.template.yml` is the file to copy to `.claude/backlog.yml` to opt in. Do nothing else.

2. Draft the issue: a one-line title, a body (context, expected outcome, acceptance criteria), and exactly ONE `type:` label (plus optional free `area:*` labels). Never set `status:`, `exec:`, `nightly`, `cross-repo`, `money-path` or any `auto:*` label: the status is forced to the intake one and the rest are human decisions. Write the body to a temp file under `$TMPDIR`.

3. ALWAYS dry-run first:
   ```bash
   python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" file --title "<title>" --body-file "$TMPDIR/backlog-body.md" --label "type:<x>"
   ```
   Report the verdict line verbatim. On `verdict=refused`, explain each code, fix the draft and dry-run again. Never work around a refusal.

4. Act on the mode from step 1:
   - `propose`: report the dry-run and STOP. Nothing is created in this mode; the user files it by hand or switches mode.
   - `write-supervised`: show the user the title, body, labels and the `payload-digest`, ASK for an explicit yes, and only then re-run the same command with `--apply --confirm <payload-digest>`.
   - `free`: re-run the same command with `--apply`.

5. Report the created issue URL (`[backlog-file] created ...`) or the refusal, nothing more.
