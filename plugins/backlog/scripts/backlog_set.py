"""`backlog_cli.py set`: change the axis labels of ONE issue, dry run first. Stdlib only.

A light, single-issue counterpart of the catch-up tooling. Each axis flag REPLACES the labels of its axis on the
issue (`--status needs-info` removes the live `status:*` label and adds `status:needs-info`). The change is
validated with the triage rules (`backlog_triage.validate`: protected labels, owned axes, unknown labels, the lint
of the resulting state, a stale read), then printed. Without `--apply` nothing is written.

`--apply` writes only when: the mode is `write-supervised` or `free`, `repo:` is set, the fresh live read
validates, and the journal line of the intent could be written BEFORE the write (`backlog_apply.execute_set`).
There is no snapshot and no digest for a single issue.

Promotion: adding `status:ready` or an agent executor is refused unless the repo opted in with
`promotion: checked` AND the deterministic check of `backlog_promote.py` passes on the fresh read. The executor
flag `nightly` is never set by this command.

This module never builds the write chokepoint itself and spawns nothing: the write goes through
`backlog_apply.execute_set`. A capped axis (`priority` by default) needs a real open-issue count, fetched only
when the change adds a capped label. There is no way to name a raw label.
"""

from __future__ import annotations

import argparse
import json
from typing import List, Optional, Tuple

from backlog_apply import Refused, execute_set, stage_one
from backlog_common import LabelEdit, is_open, label_names, printable, repo_assertion_error
from backlog_promote import check_promotion, effective_promotion, reserved_adds, wants_promotion
from backlog_triage import OPEN_LIMIT, Proposal, validate

TAG = "set"
AXIS_FLAGS = ("status", "type", "size", "exec", "priority", "area")
MAX_REASON = 200


def _positive_int(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not an issue number" % text)
    if value <= 0:
        raise argparse.ArgumentTypeError("the issue number must be > 0")
    return value


def build_parser(cfg=None) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py set",
        allow_abbrev=False,
        description="Change the axis labels of ONE issue (dry run unless --apply). Each axis flag replaces the labels "
        "of its axis. Needs mode write-supervised or free and `repo:` to write.",
    )
    parser.add_argument("--issue", type=_positive_int, required=True, help="issue number")
    for axis in AXIS_FLAGS:
        if cfg is None:
            choices = None
        elif axis == "area" and not cfg.labels.get("area"):
            choices = None  # a free area axis (the default: no fixed values) accepts any value
        else:
            choices = list(cfg.labels.get(axis, ()))
        parser.add_argument("--" + axis, choices=choices, metavar="VALUE", help="set the %s axis to this value" % axis)
    parser.add_argument("--reason", default="", help="why (journal only, cut to %d characters)" % MAX_REASON)
    parser.add_argument("--repo", help="OWNER/NAME: an assertion that must match `repo:` of the config, never a selector")
    parser.add_argument("--apply", action="store_true", help="write to GitHub (otherwise a dry run)")
    return parser


def _requested(args) -> List[Tuple[str, str]]:
    return [(axis, "%s:%s" % (axis, getattr(args, axis))) for axis in AXIS_FLAGS if getattr(args, axis) is not None]


def _plan_line(issue: int, requested, before, after, promoting: bool) -> str:
    added = ["+" + n for n in sorted(after - before)]
    removed = ["-" + n for n in sorted(before - after)]
    changes = " ".join(added + removed)
    if promoting:
        return "[%s] #%d promotion requested (%s)" % (TAG, issue, changes)
    parts = []
    for axis, _ in requested:
        prefix = axis + ":"
        old = ",".join(sorted(n for n in before if n.startswith(prefix))) or "(none)"
        new = ",".join(sorted(n for n in after if n.startswith(prefix))) or "(none)"
        parts.append("%s -> %s" % (old, new))
    return "[%s] #%d %s (%s)" % (TAG, issue, "; ".join(parts), changes)


def _refuse(text: str) -> int:
    print("[%s] refused: %s" % (TAG, text))
    return 1


def main(argv: List[str], cfg, gh=None, apply_runner=None) -> int:
    parser = build_parser(cfg)
    args = parser.parse_args(argv)
    requested = _requested(args)
    if not requested:
        parser.error("give at least one of --status, --type, --size, --exec, --priority, --area")
    error = repo_assertion_error(cfg, args.repo)
    if error:
        return _refuse(error)

    # A promotion (ready / an agent executor) is decided from the arguments, BEFORE any read: a repo that did not
    # opt in with `promotion: checked` never reaches gh for it.
    wants = wants_promotion((label for _, label in requested), cfg)
    if wants and cfg.promotion != "checked":
        return _refuse(
            "promotion-off: adding %s stays a human triage decision (set `promotion: checked` in .claude/backlog.yml)"
            % ", ".join(sorted(label for _, label in requested if label in reserved_adds(cfg)))
        )
    if args.apply:
        try:
            stage_one(cfg, True)  # mode, repo, --apply: checked before any live read
        except Refused as exc:
            return _refuse(printable(exc))

    if gh is None:
        from backlog_gh import Gh

        gh = Gh(cfg)
    try:
        issue = gh.fetch_issue(args.issue, with_body=wants)
        live_labels = gh.fetch_label_names()
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[%s] error: %s" % (TAG, printable(exc)))
        return 1
    if not is_open(issue):
        return _refuse("rejected: issue-not-open")

    before = frozenset(label_names(issue))
    after = set(before)
    for axis, label in requested:
        prefix = axis + ":"
        after = {name for name in after if not name.startswith(prefix)}
        after.add(label)
    after = frozenset(after)
    if after == before:
        print("[%s] #%d noop (already in the target state)" % (TAG, args.issue))
        return 0

    added_capped = sorted((after - before) & set(cfg.caps))
    open_issues: List[dict] = []
    if added_capped:
        try:
            open_issues = gh.fetch_issues("open", OPEN_LIMIT)
        except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
            print("[%s] error: %s" % (TAG, printable(exc)))
            return 1

    reason = printable(args.reason).strip()[:MAX_REASON] or "set"
    results = validate([Proposal(args.issue, before, after, reason, "high")], [issue], live_labels, cfg)
    codes = list(results[0].codes)
    for label in added_capped:
        total = sum(1 for i in open_issues if is_open(i) and label in label_names(i)) + 1
        if total > cfg.caps[label]:
            codes.append("cap-exceeded:%s" % label)
    promoting = effective_promotion(before, after, cfg)
    print(_plan_line(args.issue, requested, before, after, promoting))
    if codes:
        return _refuse("rejected: %s" % ",".join(codes))
    verdict = None
    if promoting:
        verdict = check_promotion(issue, after, cfg)
        facts = verdict.facts
        print("[%s] promotion: checkboxes=%d size=%s type=%s blockers=%d verdict=%s" % (
            TAG, facts["checkboxes"], printable(facts["size"]) or "-", printable(facts["type"]) or "-",
            facts["blockers"], "ok" if verdict.ok else "refused"))
        if not verdict.ok:
            return _refuse("promotion: %s" % ",".join(printable(code) for code in verdict.codes))
    if not args.apply:
        print("[%s] dry-run only: nothing was written (add --apply)" % TAG)
        return 0

    edit = LabelEdit(
        issue=args.issue,
        before=tuple(sorted(before)),
        after=tuple(sorted(after)),
        add=tuple(sorted(after - before)),
        remove=tuple(sorted(before - after)),
        reason=reason,
    )
    return execute_set(cfg, edit, reason, verdict, apply_runner=apply_runner)
