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


_CONFIG_CHECK_TIMEOUT = 2
_GIT_CHECK_IGNORE_TIMEOUT = 2


def _config_check(config_path: Path) -> Optional[list]:
    """
    Best-effort: run scripts/config-check.cjs (the single source of truth for
    retired / recommended config keys) and return its `warn:` lines when its
    last line says status=warn. None on ok or on any failure (no node, script
    missing, timeout, odd output). MUST NEVER raise.
    """
    try:
        root = os.environ.get("CLAUDE_PLUGIN_ROOT") or str(Path(__file__).resolve().parents[2])
        res = subprocess.run(
            ["node", str(Path(root) / "scripts" / "config-check.cjs"), str(config_path)],
            capture_output=True, text=True, timeout=_CONFIG_CHECK_TIMEOUT,
        )
        out = [ln for ln in res.stdout.splitlines() if ln.strip()]
        if res.returncode != 0 or not out or "status=warn" not in out[-1]:
            return None
        warns = [ln[len("warn: "):] for ln in out[:-1] if ln.startswith("warn: ")]
        return warns or None
    except Exception:
        return None


def _read_json_object(path: Path) -> dict:
    """A JSON object read from path; {} on any failure or when it is not an object."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _main_checkout_dir(project_dir: str) -> Optional[Path]:
    """
    The main checkout's directory when project_dir is a linked git worktree
    (its .git is a FILE "gitdir: <path>", whose commondir names the main .git
    directory), else None. Reads files only, no subprocess. MUST NEVER raise.
    """
    try:
        base = Path(project_dir)
        dot_git = base / ".git"
        if not dot_git.is_file():
            return None
        content = dot_git.read_text(encoding="utf-8").strip()
        if not content.startswith("gitdir:"):
            return None
        gitdir = Path(content[len("gitdir:"):].strip())
        if not gitdir.is_absolute():
            gitdir = base / gitdir
        common = Path((gitdir / "commondir").read_text(encoding="utf-8").strip())
        if not common.is_absolute():
            common = gitdir / common
        common = common.resolve()
        if common.name != ".git":
            return None
        main = common.parent
        if main == base.resolve():
            return None
        return main
    except Exception:
        return None


def _loaded_plugin_lines(project_dir: str) -> list:
    """
    Up to two lines naming the loaded plugin version and marketplace, plus a
    warning when the project's effective settings enable lgtmgate from another
    marketplace than the loaded one (local scope overrides shared scope).
    Reads only CLAUDE_PLUGIN_ROOT (manifest and path layout
    .../cache/<marketplace>/lgtmgate/<version>) and the project's
    .claude/settings.json and .claude/settings.local.json (and, in a linked
    worktree, the main checkout's .claude/settings.local.json); no subprocess,
    no network, no user-scope settings. MUST NEVER raise: any failure means
    "no lines".
    """
    try:
        root = Path(os.environ.get("CLAUDE_PLUGIN_ROOT") or str(Path(__file__).resolve().parents[2]))
        manifest = _read_json_object(root / ".claude-plugin" / "plugin.json")
        version = manifest.get("version")
        if not isinstance(version, str) or not version.strip():
            version = None
        marketplace = None
        if root.parent.name == "lgtmgate" and "cache" in root.parts:
            marketplace = root.parent.parent.name or None
        shown_version = version or "version unknown"
        lines = ["- Loaded plugin: lgtmgate {} from marketplace {}.".format(
            shown_version,
            marketplace or "unknown (the plugin root is not under a plugin cache)")]
        if marketplace:
            sources = [Path(project_dir) / ".claude" / "settings.json"]
            main = _main_checkout_dir(project_dir)
            if main is not None:
                sources.append(main / ".claude" / "settings.local.json")
            sources.append(Path(project_dir) / ".claude" / "settings.local.json")
            effective = {}
            for src in sources:
                enabled = _read_json_object(src).get("enabledPlugins")
                if not isinstance(enabled, dict):
                    continue
                for key, val in enabled.items():
                    if isinstance(key, str) and isinstance(val, bool):
                        effective[key] = val
            others = set()
            for key, val in effective.items():
                plugin, _, mkt = key.rpartition("@")
                if val is True and plugin == "lgtmgate" and mkt and mkt != marketplace:
                    others.add(mkt)
            if others:
                other = sorted(others)[0]
                lines.append(
                    "- WARNING: this project's settings enable lgtmgate@{other} but this session loaded "
                    "lgtmgate {version} from {marketplace} (plugin root {root}). Expected when you chose "
                    "that channel on purpose (for example by disabling lgtmgate@{other} at local scope); "
                    "otherwise open /plugin, enable the install you want, and restart the session.".format(
                        other=other, version=shown_version, marketplace=marketplace, root=root))
        return lines
    except Exception:
        return []


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


def _pipeline_ignore_hint(project_dir: str) -> str:
    """
    One line when git reports `.pipeline/` as not ignored (check-ignore exit 1):
    launching by reference then silently falls back. Silent outside a git
    repository (exit 128), without git, on timeout. Writes nothing. MUST NEVER
    raise: any failure means "no hint".
    """
    try:
        res = subprocess.run(
            ["git", "-C", project_dir, "check-ignore", "-q", ".pipeline/x"],
            capture_output=True, timeout=_GIT_CHECK_IGNORE_TIMEOUT,
        )
        if res.returncode != 1:
            return ""
        return (
            "- Fast launches by reference are not used: .pipeline/ is not git-ignored in this "
            "repository (a missed gain, not an error). Add the line .pipeline/ to .gitignore."
        )
    except Exception:
        return ""


_LANE_ROLES = ("mia", "sam", "nick", "morgan", "theo")
_LANE_READ_BYTES = 65536


def _names_line(prefix: str, names: list, tail: str) -> str:
    shown = ", ".join(names[:3]) + (" (+{} more)".format(len(names) - 3) if len(names) > 3 else "")
    return "- {} {}{}".format(prefix, shown, tail)


def _lanes_hints(project_dir: str, config_path: Path) -> list:
    """
    Up to two lines about the lane files of the `projectSpecifics` folder
    (`<role>.<lane>[.<subject>].md`, a lane being declared by `lane:` in the
    frontmatter): one when a `lane:` contradicts the file name (or sits on a
    `<role>.md`), one when a declared lane has no text left once the HTML
    comments are stripped (what /lgtmgate:init --lanes leaves until the owner
    completes it). Silent without frontmatter, and when every lane is
    consistent and filled. Same path-escape refusal as _specifics_hint. MUST
    NEVER raise: any failure means "no hint".
    """
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        if not isinstance(cfg, dict):
            return []
        rel = cfg.get("projectSpecifics")
        if not isinstance(rel, str) or not rel.strip():
            return []
        rel = rel.strip().rstrip("/")
        if os.path.isabs(rel) or ".." in Path(rel).parts:
            return []
        folder = Path(project_dir) / rel
        if not folder.is_dir():
            return []
        contradicting = []
        empty = []
        for f in sorted(folder.glob("*.md")):
            parts = f.name[:-3].split(".")
            if parts[0] not in _LANE_ROLES or f.is_symlink() or not f.is_file():
                continue
            with open(f, "rb") as fh:
                text = fh.read(_LANE_READ_BYTES).decode("utf-8", errors="replace")
            if not text.startswith("---\n"):
                continue
            end = text.find("\n---", 4)
            if end < 0:
                continue
            fm = text[4:end]
            m = re.search(r"^lane:[ \t]*(.*)$", fm, re.MULTILINE)
            if not m:
                continue
            lane = m.group(1).strip().strip("\"'")
            seg = parts[1] if len(parts) > 1 else None
            if lane != seg:
                contradicting.append(f.name)
                continue
            body = text[end + 4:]
            prev = None
            while prev != body:
                prev = body
                body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
            if body.strip() == "":
                empty.append(f.name)
        lines = []
        if contradicting:
            lines.append(_names_line(
                "lane: contradicts the file name in", contradicting,
                " (a file <role>.<lane>.md declares that same lane; fix one of the two, then commit to the base branch)."))
        if empty:
            lines.append(_names_line(
                "lane declared but empty:", empty,
                " (write the lane's rules in the file, or remove it; an empty lane adds nothing)."))
        return lines
    except Exception:
        return []


def build_stub() -> str:
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    config_path = Path(project_dir) / ".claude" / "pipeline.config.json"
    configured = config_path.exists()

    lines = [
        "# lgtmgate (plugin active)",
        "",
        "The **lgtmgate** plugin is loaded. "
        "Delivery work runs through its five-agent pipeline, launched with `/lgtmgate:deliver`.",
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
    lines.extend(_loaded_plugin_lines(project_dir))

    if configured:
        warns = _config_check(config_path)
        if warns:
            lines.append("- Status: config detected but out of date for this engine (the pipeline still runs):")
            lines.extend("  - " + w for w in warns)
        else:
            lines.append("- Status: config detected, pipeline ready to use.")
        hint = _specifics_hint(project_dir, config_path)
        if hint:
            lines.append(hint)
        lines.extend(_lanes_hints(project_dir, config_path))
        hint = _pipeline_ignore_hint(project_dir)
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
