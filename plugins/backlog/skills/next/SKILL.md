---
name: next
description: Print the next backlog issue an agent may pick up (read-only)
disable-model-invocation: true
argument-hint: "[--json] [--executor <label>]"
---

# /backlog:next

Report which backlog issue an agent may work on next. Read-only: this never labels, edits or claims anything, and never pulls from the intake or waiting statuses.

Arguments from the user: `$ARGUMENTS`.

## Steps

1. Run:
   ```bash
   python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" next $ARGUMENTS
   ```
2. Report the output verbatim. `[backlog] mode=off ...` means the repo has no active `.claude/backlog.yml`: say so and stop. `[next-item] error: ...` is a fetch failure, never an empty queue: report it as an error.
3. Do not start the work: picking it up is the user's call.
