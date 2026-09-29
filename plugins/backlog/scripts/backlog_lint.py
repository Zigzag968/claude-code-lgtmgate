"""Backlog exclusivity linter (ported from an internal reference implementation). Read-only.

Pure `lint()` over the open issues of a `gh issue list --json ...` payload. Every label it reasons about
comes from the config: nothing is hardcoded here.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from typing import Dict, List, Optional, Set

from backlog_common import axis_labels, is_open, label_names, load_json_list


@dataclass(frozen=True)
class Violation:
    number: Optional[int]
    code: str
    message: str

    def render(self) -> str:
        ref = "#-" if self.number is None else "#%d" % self.number
        return "[backlog-lint] %s %s: %s" % (ref, self.code, self.message)


def _exactly_one(number: int, names: Set[str], axis: str, out: List[Violation]) -> None:
    found = axis_labels(names, axis)
    if not found:
        out.append(Violation(number, "%s-missing" % axis, "no %s: label" % axis))
    elif len(found) > 1:
        out.append(Violation(number, "%s-multiple" % axis, "several %s: labels: %s" % (axis, ", ".join(found))))


def lint(issues: List[dict], cfg, caps: Optional[Dict[str, int]] = None) -> List[Violation]:
    caps = cfg.caps if caps is None else caps
    out: List[Violation] = []
    open_issues = [issue for issue in issues if is_open(issue)]
    known = cfg.axis_label_names()
    owned = cfg.owned_namespaces()
    ready = cfg.role_label("ready")
    split = set(cfg.role_labels("split"))
    for issue in open_issues:
        number = int(issue["number"])
        names = label_names(issue)
        _exactly_one(number, names, "type", out)
        _exactly_one(number, names, "status", out)

        for axis in ("priority", "size"):
            found = axis_labels(names, axis)
            if len(found) > 1:
                out.append(Violation(number, "%s-multiple" % axis, "several %s: labels: %s" % (axis, ", ".join(found))))
        sizes = axis_labels(names, "size")

        executors = axis_labels(names, "exec") + [flag for flag in cfg.executor_flags if flag in names]
        if len(executors) > 1:
            out.append(Violation(number, "executor-multiple", "several Executors: %s" % ", ".join(executors)))

        if ready in names:
            if not executors:
                out.append(Violation(number, "ready-no-executor", "%s needs an Executor" % ready))
            if not sizes:
                out.append(Violation(number, "ready-no-size", "%s needs a size: label" % ready))
            for label in sorted(split & names):
                out.append(Violation(number, "ready-size-l", "%s must be split before it is ready" % label))

        if owned:
            for name in sorted(names):
                if name.startswith(owned) and name not in known:
                    out.append(Violation(number, "unknown-value", "%s is not a known value" % name))

    for label, cap in caps.items():
        count = sum(1 for issue in open_issues if label in label_names(issue))
        if count > cap:
            out.append(Violation(None, "cap-exceeded", "%s has %d open issues (cap %d)" % (label, count, cap)))

    return sorted(out, key=lambda v: (v.number or 0, v.code))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="backlog_cli.py lint", description="Lint backlog label exclusivity (read-only).")
    parser.add_argument("--issues-file", help="JSON file in `gh issue list --json` shape (offline)")
    parser.add_argument("--strict", action="store_true", help="exit 1 when any violation is found")
    return parser


def main(argv: List[str], cfg, gh=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.issues_file:
            issues = load_json_list(args.issues_file)
        else:
            if gh is None:
                from backlog_gh import Gh

                gh = Gh(cfg)
            issues = gh.fetch_issues("open", 500)
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as exc:
        print("[backlog-lint] error: %s" % exc)
        return 1
    violations = lint(issues, cfg)
    for violation in violations:
        print(violation.render())
    print("[backlog-lint] violations=%d open=%d" % (len(violations), sum(1 for i in issues if is_open(i))))
    if args.strict and violations:
        return 1
    return 0
