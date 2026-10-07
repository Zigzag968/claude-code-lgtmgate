#!/usr/bin/env python3
"""
SessionStart hook — lgtmgate stub injection.

Prints a short markdown stub into additionalContext so the Lead always knows
the lgtmgate plugin is active, how to launch a delivery run, and where the
project config lives. Robust: never throws, always exit 0 (a failing
SessionStart hook must not wedge the session).
"""

import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

# Best-effort network call budgets (seconds). Kept well under the hook's own
# manifest timeout (15s) so a slow/offline network never risks the hook being
# killed mid-way — it just skips the reminder instead.
_GIT_REMOTE_TIMEOUT = 2
_GH_TIMEOUT = 3

# Force UTF-8 on Windows (defensive; emoji-free stub but stay safe).
if sys.platform == "win32":
    try:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        pass


def _owner_repo_from_remote(remote_url: str) -> Optional[str]:
    """git@github.com:owner/repo.git or https://github.com/owner/repo(.git) -> owner/repo."""
    m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$", remote_url.strip())
    return f"{m.group(1)}/{m.group(2)}" if m else None


def _pr_ready_reminder(project_dir: str) -> str:
    """
    Best-effort: a one-line "N PR awaiting human review/merge" reminder for
    an orchestrator convention this plugin recognizes (issues/PRs labeled
    auto:pr-ready — e.g. the nightly runner's no-auto-merge contract: CI
    green + undrafted is a terminal state, a human merges by hand).

    MUST NEVER block or slow down session start beyond its own short
    timeouts, and MUST NEVER raise — any failure (no git, no gh, no network,
    not a GitHub remote, rate-limited, whatever) means "no reminder", full
    stop, silently.
    """
    try:
        remote = subprocess.run(
            ["git", "-C", project_dir, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=_GIT_REMOTE_TIMEOUT,
        )
        if remote.returncode != 0:
            return ""
        owner_repo = _owner_repo_from_remote(remote.stdout)
        if not owner_repo:
            return ""  # not a github.com remote

        gh = subprocess.run(
            ["gh", "issue", "list", "-R", owner_repo, "--label", "auto:pr-ready",
             "--state", "open", "--json", "number", "--jq", ".[].number", "--limit", "50"],
            capture_output=True, text=True, timeout=_GH_TIMEOUT,
        )
        if gh.returncode != 0:
            return ""
        numbers = [n for n in gh.stdout.split() if n.isdigit()]
        if not numbers:
            return ""
        return "- ⏳ {} PR nightly awaiting human review: {}".format(
            len(numbers), ", ".join(f"#{n}" for n in numbers)
        )
    except Exception:
        return ""


def _specifics_hint(project_dir: str, config_path: Path) -> str:
    """
    One line when the config sets `projectSpecifics` but its folder holds no
    .md file (the stubs `/lgtmgate:init` creates are missing). A path that
    escapes the project directory is never read. MUST NEVER raise: any
    failure means "no hint".
    """
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        if not isinstance(cfg, dict):
            return ""
        rel = cfg.get("projectSpecifics")
        if not isinstance(rel, str) or not rel.strip():
            return ""
        rel = rel.strip().rstrip("/")
        if os.path.isabs(rel) or ".." in Path(rel).parts:
            return ""
        folder = Path(project_dir) / rel
        if folder.is_dir() and any(folder.glob("*.md")):
            return ""
        return (
            "- projectSpecifics is set but {} holds no .md file: run /lgtmgate:init "
            "to create the stubs, then commit and push them to the base branch "
            "(specifics are read from origin/<base>).".format(rel)
        )
    except Exception:
        return ""


def build_stub() -> str:
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    config_path = Path(project_dir) / ".claude" / "pipeline.config.json"
    configured = config_path.exists()

    lines = [
        "# lgtmgate (plugin active)",
        "",
        "The **lgtmgate** plugin is loaded. Delivery work runs through the "
        "**Mia -> Sam -> Nick -> Morgan** orchestration.",
        "",
        "- Launch a delivery: `/lgtmgate:deliver <issue> \"<brief>\"` "
        "(the Lead creates the shared worktree, then drives the workflow — the plugin's "
        "`lgtmgate:deliver-pipeline` component by default, or the project's "
        "`.claude/workflows/deliver-pipeline.js` as a fallback for a not-yet-migrated project ; "
        "exact resolution: `/lgtmgate:deliver` step 1).",
        "- Project config: `.claude/pipeline.config.json` "
        "(build/test/format commands, baseBranch, branchPrefix, worktreeRoot, "
        "ciChecks, GH Project).",
        "",
        "**In-flight run supervision.** On wake-up or between tasks: if pipeline runs are "
        "in flight (`.pipeline/**/*.json`, non-terminal status), do a guard round BEFORE "
        "anything new — alive -> leave it alone ; `review-died`/`resumable` -> resume "
        "via `resumeFromRunId` + persisted args, bounded (2-3 attempts max, never loop) ; "
        "silent past the threshold (`supervision.staleMinutes`) -> mark blocked/escalate. "
        "Never leave a dead run without a decision (the `Stop` guard hook reminds of this).",
    ]

    if configured:
        lines.append("- Status: config detected, pipeline ready to use.")
        hint = _specifics_hint(project_dir, config_path)
        if hint:
            lines.append(hint)
    else:
        lines.append(
            "- **No `.claude/pipeline.config.json` detected** in this project. "
            "Run `/lgtmgate:init` to generate the config and install "
            "the templates (workflow, pr-acceptance rule, scripts, GH snippets)."
        )

    reminder = _pr_ready_reminder(project_dir)
    if reminder:
        lines.append(reminder)

    return "\n".join(lines)


def main() -> int:
    try:
        stub = build_stub()
    except (OSError, ValueError, TypeError):
        # Never wedge the session — emit nothing meaningful but valid.
        stub = "# lgtmgate (plugin active)\n\nRun `/lgtmgate:init` if not configured."

    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": stub,
        }
    }
    try:
        sys.stdout.write(json.dumps(output))
    except (OSError, ValueError, TypeError):
        pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError):
        sys.exit(0)
