"""`next` -- pick the next backlog issue an agent may work on (ported from an internal reference implementation).

Read-only: it never writes, never labels, never pulls from the intake or waiting statuses. A fetch or
parse failure prints `[next-item] error: ...` and exits 1 -- it is never reported as an empty queue.
All label names come from the config.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, field
from typing import List, Optional, Set, Tuple

from backlog_common import axis_labels, axis_rank, is_open, label_names, load_json_list


@dataclass
class Selection:
    selected: Optional[dict]
    candidates: List[int] = field(default_factory=list)
    inbox: int = 0
    needs_info: int = 0


def default_executors(cfg) -> Tuple[str, ...]:
    return cfg.role_labels("agent")


def selectable_executors(cfg) -> Tuple[str, ...]:
    return default_executors(cfg) + tuple(cfg.executor_flags)


def open_pr_references(prs: List[dict]) -> Set[int]:
    """Issue numbers referenced by an OPEN PR: a closing reference or a `#N` token in title/body."""
    referenced: Set[int] = set()
    for pr in prs:
        for ref in pr.get("closingIssuesReferences") or []:
            if isinstance(ref, dict) and "number" in ref:
                referenced.add(int(ref["number"]))
        text = "%s\n%s" % (pr.get("title") or "", pr.get("body") or "")
        for match in re.finditer(r"(?<![\w/])#(\d+)(?!\d)", text):
            referenced.add(int(match.group(1)))
    return referenced


def open_blockers(issue: dict) -> List[int]:
    """Numbers of the OPEN issues blocking this one (`blockedBy.nodes[]`); missing key = none."""
    blocked_by = issue.get("blockedBy") or {}
    nodes = blocked_by.get("nodes") or []
    return [int(node["number"]) for node in nodes if isinstance(node, dict) and is_open(node)]


def _is_candidate(issue: dict, referenced: Set[int], allowed: Tuple[str, ...], cfg) -> bool:
    if not is_open(issue):
        return False
    names = label_names(issue)
    if cfg.role_label("ready") not in names:
        return False
    if cfg.role_label("intake") in names or cfg.role_label("waiting") in names:
        return False
    if any(label in names for label in cfg.role_labels("human")):
        return False
    if not any(executor in names for executor in allowed):
        return False
    if not any(label in names for label in ("size:%s" % s for s in cfg.roles["candidate_sizes"])):
        return False
    if cfg.role_label("epic") in names or any(flag in names for flag in cfg.exclusions):
        return False
    if open_blockers(issue):
        return False
    return int(issue["number"]) not in referenced


def _sort_key(issue: dict, cfg) -> tuple:
    names = label_names(issue)
    priority_rank = axis_rank(cfg, "priority")
    size_rank = axis_rank(cfg, "size")
    priority = next((priority_rank[p] for p in axis_labels(names, "priority") if p in priority_rank), len(priority_rank))
    size = next((size_rank[s] for s in axis_labels(names, "size") if s in size_rank), len(size_rank))
    bug = 0 if cfg.role_label("bug") in names else 1
    return (priority, bug, size, str(issue.get("createdAt") or ""), int(issue["number"]))


def select_next(issues: List[dict], prs: List[dict], cfg, allowed_executors: Optional[Tuple[str, ...]] = None) -> Selection:
    allowed = tuple(allowed_executors) if allowed_executors else default_executors(cfg)
    referenced = open_pr_references(prs)
    ranked = sorted(
        (issue for issue in issues if _is_candidate(issue, referenced, allowed, cfg)),
        key=lambda issue: _sort_key(issue, cfg),
    )
    open_issues = [issue for issue in issues if is_open(issue)]
    intake, waiting = cfg.role_label("intake"), cfg.role_label("waiting")
    return Selection(
        selected=ranked[0] if ranked else None,
        candidates=[int(issue["number"]) for issue in ranked],
        inbox=sum(1 for issue in open_issues if intake in label_names(issue)),
        needs_info=sum(1 for issue in open_issues if waiting in label_names(issue)),
    )


def _first(names: List[str], default: str) -> str:
    return names[0] if names else default


def build_parser(cfg) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="backlog_cli.py next", description="Pick the next backlog issue (read-only).")
    parser.add_argument("--issues-file", help="JSON file in `gh issue list --json` shape (offline)")
    parser.add_argument("--prs-file", help="JSON file in `gh pr list --json` shape (offline)")
    parser.add_argument(
        "--executor",
        action="append",
        choices=selectable_executors(cfg),
        help="allowed Executor (repeatable); default: the configured agent executor(s)",
    )
    parser.add_argument("--json", action="store_true", dest="as_json", help="print one JSON object")
    return parser


def main(argv: List[str], cfg, gh=None) -> int:
    args = build_parser(cfg).parse_args(argv)
    try:
        if args.issues_file and args.prs_file:
            issues, prs = load_json_list(args.issues_file), load_json_list(args.prs_file)
        else:
            if gh is None:
                from backlog_gh import Gh

                gh = Gh(cfg)
            issues = load_json_list(args.issues_file) if args.issues_file else gh.fetch_issues("open", 500)
            prs = load_json_list(args.prs_file) if args.prs_file else gh.fetch_prs(200)
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as exc:
        print("[next-item] error: %s" % exc)
        return 1

    allowed = tuple(args.executor) if args.executor else default_executors(cfg)
    selection = select_next(issues, prs, cfg, allowed)

    if args.as_json:
        chosen = selection.selected
        print(
            json.dumps(
                {
                    "selected": (
                        {"number": chosen["number"], "title": chosen.get("title"), "labels": sorted(label_names(chosen))}
                        if chosen
                        else None
                    ),
                    "queue_empty": chosen is None,
                    "inbox": selection.inbox,
                    "needs_info": selection.needs_info,
                    "candidates": selection.candidates,
                }
            )
        )
        return 0

    if selection.selected is None:
        print("[next-item] queue empty: inbox=%d needs-info=%d" % (selection.inbox, selection.needs_info))
        return 0

    chosen = selection.selected
    names = label_names(chosen)
    print(
        "[next-item] selected=#%s priority=%s size=%s title=%s"
        % (chosen["number"], _first(axis_labels(names, "priority"), "none"), _first(axis_labels(names, "size"), "none"), chosen.get("title", ""))
    )
    print("[next-item] candidates=%d" % len(selection.candidates))
    return 0
