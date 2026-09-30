"""`backlog_cli.py set`: change the axis labels of ONE issue, dry run first. Stdlib only.

A light, single-issue counterpart of the catch-up tooling. Each axis flag REPLACES the labels of its axis on the
issue (`--status needs-info` removes the live `status:*` label and adds `status:needs-info`). The change is
validated with the triage rules (`backlog_triage.validate`: protected labels, owned axes, unknown labels, the lint
of the resulting state, a stale read), then printed. Without `--apply` nothing is written.

`--blocked-by M` / `--unblock M` (repeatable, alone or with axis flags) add or remove GitHub native dependencies of
the issue, REST only (`backlog_gh.DepGh`, reached through `backlog_apply.execute_deps`). A link already in the live
`blockedBy` (or an unblock of one that is not there) is a noop. Same apply conditions and same journal.

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

from backlog_apply import Refused, execute_deps, execute_set, stage_one
from backlog_common import LabelEdit, is_open, label_names, positive_int, printable, repo_assertion_error
from backlog_gh import MAX_DEP_LINKS
from backlog_promote import check_promotion, effective_promotion, reserved_adds, wants_promotion
from backlog_triage import OPEN_LIMIT, Proposal, validate

TAG = "set"
AXIS_FLAGS = ("status", "type", "size", "exec", "priority", "area")
MAX_REASON = 200


_positive_int = positive_int


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
    parser.add_argument("--blocked-by", type=_positive_int, action="append", default=[], metavar="N",
                        help="add a native 'blocked by' dependency on this issue number (repeatable)")
    parser.add_argument("--unblock", type=_positive_int, action="append", default=[], metavar="N",
                        help="remove a native 'blocked by' dependency on this issue number (repeatable)")
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


def _live_blockers(issue: dict) -> set:
    nodes = (issue.get("blockedBy") or {}).get("nodes") or []
    return {int(node["number"]) for node in nodes if isinstance(node, dict) and str(node.get("number", "")).isdigit()}


def _refuse(text: str) -> int:
    print("[%s] refused: %s" % (TAG, text))
    return 1


def main(argv: List[str], cfg, gh=None, apply_runner=None) -> int:
    parser = build_parser(cfg)
    args = parser.parse_args(argv)
    requested = _requested(args)
    dep_add = sorted(set(args.blocked_by))
    dep_remove = sorted(set(args.unblock))
    if not requested and not dep_add and not dep_remove:
        parser.error("give at least one of --status, --type, --size, --exec, --priority, --area, --blocked-by, --unblock")
    if args.issue in dep_add or args.issue in dep_remove:
        return _refuse("an issue cannot block itself (#%d)" % args.issue)
    if set(dep_add) & set(dep_remove):
        return _refuse("--blocked-by and --unblock name the same issue: %s" % ", ".join(
            "#%d" % n for n in sorted(set(dep_add) & set(dep_remove))))
    if len(dep_add) + len(dep_remove) > MAX_DEP_LINKS:
        return _refuse("too many dependency changes (max %d per call)" % MAX_DEP_LINKS)
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

    live_blockers = _live_blockers(issue)
    add_links = [n for n in dep_add if n not in live_blockers]
    remove_links = [n for n in dep_remove if n in live_blockers]
    for number in dep_add:
        if number in live_blockers:
            print("[%s] #%d blocked-by #%d noop (already blocked)" % (TAG, args.issue, number))
    for number in dep_remove:
        if number not in live_blockers:
            print("[%s] #%d unblock #%d noop (not blocked by it)" % (TAG, args.issue, number))
    deps_change = bool(add_links or remove_links)

    before = frozenset(label_names(issue))
    after = set(before)
    for axis, label in requested:
        prefix = axis + ":"
        after = {name for name in after if not name.startswith(prefix)}
        after.add(label)
    after = frozenset(after)
    labels_change = after != before
    if not labels_change and not deps_change:
        print("[%s] #%d noop (already in the target state)" % (TAG, args.issue))
        return 0

    reason = printable(args.reason).strip()[:MAX_REASON] or "set"
    verdict = None
    if labels_change:
        added_capped = sorted((after - before) & set(cfg.caps))
        open_issues: List[dict] = []
        if added_capped:
            try:
                open_issues = gh.fetch_issues("open", OPEN_LIMIT)
            except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
                print("[%s] error: %s" % (TAG, printable(exc)))
                return 1

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
        if promoting:
            verdict = check_promotion(issue, after, cfg)
            facts = verdict.facts
            print("[%s] promotion: checkboxes=%d size=%s type=%s blockers=%d verdict=%s" % (
                TAG, facts["checkboxes"], printable(facts["size"]) or "-", printable(facts["type"]) or "-",
                facts["blockers"], "ok" if verdict.ok else "refused"))
            if not verdict.ok:
                return _refuse("promotion: %s" % ",".join(printable(code) for code in verdict.codes))
    for number in add_links:
        print("[%s] #%d planned blocked-by: +#%d" % (TAG, args.issue, number))
    for number in remove_links:
        print("[%s] #%d planned blocked-by: -#%d" % (TAG, args.issue, number))
    if not args.apply:
        print("[%s] dry-run only: nothing was written (add --apply)" % TAG)
        return 0

    if labels_change:
        edit = LabelEdit(
            issue=args.issue,
            before=tuple(sorted(before)),
            after=tuple(sorted(after)),
            add=tuple(sorted(after - before)),
            remove=tuple(sorted(before - after)),
            reason=reason,
        )
        rc = execute_set(cfg, edit, reason, verdict, apply_runner=apply_runner)
        if rc != 0 or not deps_change:
            return rc
    return execute_deps(cfg, args.issue, add_links, remove_links, reason, dep_runner=apply_runner)
