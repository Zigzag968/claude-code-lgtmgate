"""Backlog snapshot + rollback (dry run). Stdlib only.

`snapshot` freezes the labels of every issue (all states) into a directory OUTSIDE any repo, with a sha256 and a
generated `rollback.sh`. `rollback` recomputes, from the snapshot alone, the label changes that would restore it and
prints them: by default a DRY RUN, nothing is written to GitHub by this module. `rollback --apply` delegates to
`backlog_apply.py`, which holds every apply condition and the only write path.

The only files this module writes are the three snapshot files, in a new directory named after the target repo
(`~/.backlog-snapshots/<OWNER>__<NAME>/<UTC stamp>/` by default). It never overwrites and never deletes a file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Set, Tuple

from backlog_common import (
    LabelEdit,
    is_open,
    label_names,
    load_json_list,
    printable,
    repo_assertion_error,
    repo_slug,
)

SNAPSHOT_FIELDS = "number,title,state,updatedAt,labels"
SNAPSHOT_LIMIT = 1000
OPEN_LIMIT = 500
SNAPSHOT_FILE = "snapshot.json"
SHA_FILE = "snapshot.sha256"
SCRIPT_FILE = "rollback.sh"
SNAPSHOT_VERSION = 1
PLUGIN_ROOT = Path(__file__).resolve().parent.parent


def project_dir_of(cfg) -> Path:
    """The directory holding `.claude/backlog.yml` (the repo the config lives in)."""
    if cfg.source:
        return Path(cfg.source).resolve().parent.parent
    return Path.cwd().resolve()


def assert_outside_repo(path, project_dir) -> Path:
    """Refuse any target under the project, under the plugin, or under a directory holding a `.git`
    (a `.git` directly in $HOME, i.e. a dotfiles repo, does not count)."""
    resolved = Path(path).expanduser().resolve()
    for root in (Path(project_dir).resolve(), PLUGIN_ROOT.resolve()):
        if resolved == root or root in resolved.parents:
            raise ValueError("%s: must live OUTSIDE the repo and the plugin (%s)" % (resolved, root))
    home = Path.home().resolve()
    for ancestor in (resolved,) + tuple(resolved.parents):
        if ancestor != home and (ancestor / ".git").exists():
            raise ValueError("%s: is inside a git repository (%s)" % (resolved, ancestor))
    return resolved


def utc_stamp(now: datetime) -> str:
    return now.strftime("%Y%m%dT%H%M%SZ")


def build_snapshot(issues: List[dict], labels, taken_at: str, repo: str) -> dict:
    return {
        "version": SNAPSHOT_VERSION,
        "repo": repo,
        "taken_at": taken_at,
        "issues": [
            {
                "number": int(issue["number"]),
                "title": str(issue.get("title", "")),
                "state": str(issue.get("state", "")),
                "updatedAt": str(issue.get("updatedAt", "")),
                "labels": sorted(label_names(issue)),
            }
            for issue in sorted(issues, key=lambda i: int(i["number"]))
        ],
        "labels": sorted(str(name) for name in labels),
    }


def write_exclusive(path: Path, text: str, mode: int) -> None:
    """Create a NEW file (fails if it exists) with the given permission bits."""
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)


def _rollback_script(snapshot_dir: Path, sha: str, project_dir: Path) -> str:
    cli = PLUGIN_ROOT / "scripts" / "backlog_cli.py"
    return (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'exec "${PYTHON:-python3}" -B %s --project-dir %s rollback --snapshot-dir %s --expect-sha %s "$@"\n'
        % (shlex.quote(str(cli)), shlex.quote(str(project_dir)), shlex.quote(str(snapshot_dir)), sha)
    )


def _ensure_gh(cfg, gh):
    if gh is None:
        from backlog_gh import Gh

        gh = Gh(cfg)
    return gh


def build_snapshot_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py snapshot",
        allow_abbrev=False,
        description="Freeze the labels of every issue into a NEW directory outside any repo (local files only).",
    )
    parser.add_argument("--repo", help="assertion only: must equal `repo:` of .claude/backlog.yml")
    parser.add_argument("--snapshot-dir", help="target directory (default ~/.backlog-snapshots/<OWNER>__<NAME>/<UTC stamp>)")
    parser.add_argument("--issues-file", help="all issues, `gh issue list --json` shape (offline)")
    parser.add_argument("--labels-file", help="repo labels, `gh label list --json name` shape (offline)")
    return parser


def build_rollback_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py rollback",
        allow_abbrev=False,
        description="Print the label changes that would restore a snapshot. Dry run unless --apply.",
    )
    parser.add_argument("--repo", help="assertion only: must equal `repo:` of .claude/backlog.yml")
    parser.add_argument("--snapshot-dir", required=True)
    parser.add_argument("--expect-sha", required=True, help="sha256 of snapshot.json")
    parser.add_argument("--issues-file", help="live open issues, `gh issue list --json` shape (offline)")
    parser.add_argument("--labels-file", help="live labels, `gh label list --json name` shape (offline)")
    parser.add_argument("--apply", action="store_true", help="restore the open issues (needs --confirm <table-digest>)")
    parser.add_argument("--confirm", help="the table-digest printed by the dry run")
    return parser


def main_snapshot(argv: List[str], cfg, gh=None, now: Optional[datetime] = None) -> int:
    args = build_snapshot_parser().parse_args(argv)
    if not cfg.repo:
        print("[snapshot] error: `repo:` is required in .claude/backlog.yml (the snapshot is named after the target repo)")
        return 1
    problem = repo_assertion_error(cfg, args.repo)
    if problem:
        print("[snapshot] error: %s" % problem)
        return 1
    taken = now or datetime.now(timezone.utc)
    try:
        default_dir = Path.home() / ".backlog-snapshots" / repo_slug(cfg.repo) / utc_stamp(taken)
        project_dir = project_dir_of(cfg)
        out_dir = assert_outside_repo(args.snapshot_dir or default_dir, project_dir)
        if (out_dir / SNAPSHOT_FILE).exists():
            raise ValueError("%s already exists: refusing to overwrite a snapshot" % (out_dir / SNAPSHOT_FILE))
        if args.issues_file and args.labels_file:
            issues = load_json_list(args.issues_file)
            labels = {str(entry["name"]) for entry in load_json_list(args.labels_file)}
        else:
            gh = _ensure_gh(cfg, gh)
            issues = load_json_list(args.issues_file) if args.issues_file else gh.fetch_issues("all", SNAPSHOT_LIMIT, SNAPSHOT_FIELDS)
            labels = {str(e["name"]) for e in load_json_list(args.labels_file)} if args.labels_file else gh.fetch_label_names()
        snapshot = build_snapshot(issues, labels, taken.strftime("%Y-%m-%dT%H:%M:%SZ"), cfg.repo)
        payload = json.dumps(snapshot, indent=2, sort_keys=True) + "\n"
        sha = hashlib.sha256(payload.encode()).hexdigest()
        created = not out_dir.exists()
        out_dir.mkdir(parents=True, exist_ok=True)
        if created:  # never change the permissions of a directory the user already had
            os.chmod(str(out_dir), 0o700)
        write_exclusive(out_dir / SNAPSHOT_FILE, payload, 0o600)
        write_exclusive(out_dir / SHA_FILE, "%s  %s\n" % (sha, SNAPSHOT_FILE), 0o600)
        write_exclusive(out_dir / SCRIPT_FILE, _rollback_script(out_dir, sha, project_dir), 0o700)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[snapshot] error: %s" % printable(exc))
        return 1
    print("[snapshot] repo=%s issues=%d labels=%d sha256=%s" % (cfg.repo, len(snapshot["issues"]), len(snapshot["labels"]), sha))
    print("[snapshot] wrote %s (%s, %s, %s)" % (printable(out_dir), SNAPSHOT_FILE, SHA_FILE, SCRIPT_FILE))
    return 0


def rollback_plan(snapshot_issues: List[dict], live_issues: List[dict], live_label_names: Set[str], cfg) -> Tuple[List[LabelEdit], List[str]]:
    """Changes restoring the snapshot labels of every issue that was OPEN then and is still OPEN. Only the labels
    of the configured axes are ever removed; protected labels are never touched. Problems are strings prefixed
    `missing-label:` (a label to restore no longer exists in the repo) or `skip:` (issue closed or absent live)."""
    live_by_number = {int(i["number"]): i for i in live_issues}
    axis_names = cfg.axis_label_names()
    edits: List[LabelEdit] = []
    problems: List[str] = []
    for snap in sorted(snapshot_issues, key=lambda s: int(s["number"])):
        if not is_open(snap):
            continue
        number = int(snap["number"])
        live_issue = live_by_number.get(number)
        if live_issue is None or not is_open(live_issue):
            problems.append("skip: #%d is closed or absent live" % number)
            continue
        target = set(snap["labels"])
        live = label_names(live_issue)
        add = sorted(name for name in target - live if not cfg.is_protected(name))
        drop = sorted(name for name in (live - target) & axis_names if not cfg.is_protected(name))
        missing = [name for name in add if name not in live_label_names]
        if missing:
            problems.append("missing-label: #%d needs %s which does not exist in the repo" % (number, ", ".join(missing)))
            continue
        if not add and not drop:
            continue
        edits.append(
            LabelEdit(
                issue=number,
                before=tuple(sorted(live)),
                after=tuple(sorted((live - set(drop)) | set(add))),
                add=tuple(add),
                remove=tuple(drop),
                reason="restore snapshot labels",
            )
        )
    return edits, problems


def rollback_digest(snapshot_issues: List[dict], repo: str) -> str:
    """Digest of the restore target of every issue OPEN in the snapshot, bound to the repo (independent of the
    live state, so it stays stable across batches)."""
    rows = [
        {"issue": int(s["number"]), "target": sorted(s["labels"])}
        for s in sorted(snapshot_issues, key=lambda s: int(s["number"]))
        if is_open(s)
    ]
    payload = json.dumps({"repo": repo, "rows": rows}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def render_rollback(edits: List[LabelEdit]) -> str:
    lines = ["| #issue | live | restored | add | remove |", "|--------|------|----------|-----|--------|"]
    for edit in edits:
        cells = [", ".join(edit.before), ", ".join(edit.after), ", ".join(edit.add), ", ".join(edit.remove)]
        lines.append(printable("| #%d | %s |" % (edit.issue, " | ".join(cells))))
    return "\n".join(lines)


def main_rollback(argv: List[str], cfg, gh=None, apply_runner=None) -> int:
    args = build_rollback_parser().parse_args(argv)
    if not cfg.repo:
        print("[rollback] error: `repo:` is required in .claude/backlog.yml (a snapshot is bound to its repo)")
        return 1
    problem = repo_assertion_error(cfg, args.repo)
    if problem:
        print("[rollback] error: %s" % problem)
        return 1
    if args.apply or args.confirm:
        from backlog_apply import apply_rollback  # lazy: backlog_apply imports this module

        return apply_rollback(args, cfg, gh, apply_runner)
    try:
        raw = (Path(args.snapshot_dir).expanduser() / SNAPSHOT_FILE).read_bytes()
        sha = hashlib.sha256(raw).hexdigest()
        if sha != args.expect_sha:
            print("[rollback] error: snapshot sha256 mismatch (expected %s, got %s)" % (printable(args.expect_sha), sha))
            return 1
        snapshot = json.loads(raw)
        if not isinstance(snapshot, dict) or snapshot.get("version") != SNAPSHOT_VERSION:
            print("[rollback] error: unsupported snapshot version")
            return 1
        if snapshot.get("repo") != cfg.repo:
            print("[rollback] error: the snapshot belongs to %s, the config targets %s" % (printable(snapshot.get("repo")), cfg.repo))
            return 1
        snapshot_issues = snapshot["issues"]
        if args.issues_file and args.labels_file:
            live_issues = load_json_list(args.issues_file)
            live_labels = {str(entry["name"]) for entry in load_json_list(args.labels_file)}
        else:
            gh = _ensure_gh(cfg, gh)
            live_issues = load_json_list(args.issues_file) if args.issues_file else gh.fetch_issues("open", OPEN_LIMIT)
            live_labels = {str(e["name"]) for e in load_json_list(args.labels_file)} if args.labels_file else gh.fetch_label_names()
        edits, problems = rollback_plan(snapshot_issues, live_issues, live_labels, cfg)
        digest = rollback_digest(snapshot_issues, cfg.repo)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[rollback] error: %s" % printable(exc))
        return 1

    print(render_rollback(edits))
    for entry in problems:
        print("[rollback] %s" % printable(entry))
    print("[rollback] edits=%d table-digest: %s" % (len(edits), digest))
    print("[rollback] dry-run: nothing written (--apply needs --confirm <table-digest>)")
    return 0
