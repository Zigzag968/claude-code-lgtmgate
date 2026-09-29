"""Propose-only backlog triage: list what needs triage, validate a proposals file, print the review table.

Ported from the validator half of an internal catch-up script. There is deliberately NO apply path in
this module: it imports nothing that writes, and its CLI has no write flag. A human applies (or a later,
separately reviewed contract does).
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass, field
from typing import Dict, FrozenSet, List, Optional, Set

from backlog_common import is_open, label_names, load_json_list
from backlog_lint import lint

CONFIDENCES = ("high", "medium", "low")
OPEN_LIMIT = 500
_PROPOSAL_KEYS = ("issue", "labels_before", "labels_after", "reason", "confidence")


@dataclass(frozen=True)
class Proposal:
    issue: Optional[int]
    before: FrozenSet[str]
    after: FrozenSet[str]
    reason: str
    confidence: str
    schema_error: str = ""
    index: int = 0


def _str_list(value) -> bool:
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


def parse_proposals(raw: list) -> List[Proposal]:
    """A malformed entry becomes a `bad-schema` proposal instead of crashing the whole check."""
    out: List[Proposal] = []
    for index, entry in enumerate(raw):
        ok = (
            isinstance(entry, dict)
            and all(key in entry for key in _PROPOSAL_KEYS)
            and isinstance(entry["issue"], int)
            and not isinstance(entry["issue"], bool)
            and _str_list(entry["labels_before"])
            and _str_list(entry["labels_after"])
            and isinstance(entry["reason"], str)
            and entry["reason"].strip() != ""
            and entry["confidence"] in CONFIDENCES
        )
        if not ok:
            issue = entry.get("issue") if isinstance(entry, dict) else None
            number = issue if isinstance(issue, int) and not isinstance(issue, bool) else None
            out.append(Proposal(number, frozenset(), frozenset(), "", "low", schema_error="bad-schema", index=index))
            continue
        out.append(
            Proposal(
                entry["issue"],
                frozenset(entry["labels_before"]),
                frozenset(entry["labels_after"]),
                entry["reason"],
                entry["confidence"],
                index=index,
            )
        )
    return out


def _order(proposals: List[Proposal]) -> List[Proposal]:
    return sorted(proposals, key=lambda p: (p.issue is None, p.issue or 0, p.index))


@dataclass
class Result:
    proposal: Proposal
    codes: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.codes


def validate(proposals: List[Proposal], issues: List[dict], live_label_names: Set[str], cfg,
             removable_extra: FrozenSet[str] = frozenset()) -> List[Result]:
    """Deterministic rejection codes. Proposals are processed in ascending issue order so a cap slot goes to
    the lowest issue number. Adding or removing is limited to the labels of the configured axes; bare flags
    (money-path, cross-repo...) are human decisions and can never be part of a proposal. `removable_extra`
    lists additional labels a proposal may REMOVE (never add): the mapped legacy labels of the catch-up."""
    allowed = cfg.axis_label_names()
    by_number = {int(i["number"]): i for i in issues}
    state: Dict[int, Set[str]] = {n: label_names(i) for n, i in by_number.items() if is_open(i)}
    counts: Dict[int, int] = {}
    for proposal in proposals:
        if proposal.issue is not None:
            counts[proposal.issue] = counts.get(proposal.issue, 0) + 1

    results: List[Result] = []
    for proposal in _order(proposals):
        result = Result(proposal)
        results.append(result)
        codes = result.codes
        if proposal.schema_error:
            codes.append(proposal.schema_error)
            continue
        number = int(proposal.issue)
        if counts[number] > 1:
            codes.append("duplicate-issue")
            continue
        issue = by_number.get(number)
        if issue is None:
            codes.append("issue-not-found")
            continue
        if not is_open(issue):
            codes.append("issue-not-open")
            continue
        live = state[number]
        before, after = proposal.before, proposal.after
        if before == after:
            codes.append("noop")
        if not ((before & after) <= live <= (before | after)):
            codes.append("stale-before")
        if any(cfg.is_protected(name) for name in before ^ after):
            codes.append("protected-label-changed")
        added, removed = after - before, before - after
        free = cfg.free_namespaces()
        if any(not (name in allowed or name.startswith(free)) for name in added):
            codes.append("add-not-allowed")
        if any(name not in (allowed | removable_extra) for name in removed):
            codes.append("remove-not-allowed")
        if any(name not in live_label_names for name in added):
            codes.append("unknown-label")
        for violation in lint([{"number": number, "state": "OPEN", "labels": sorted(after)}], cfg, caps={}):
            codes.append("lint:%s" % violation.code)
        for label, cap in cfg.caps.items():
            if label in after - live:
                total = sum(1 for names in state.values() if label in names) + 1
                if total > cap:
                    codes.append("cap-exceeded:%s" % label)
        if not codes:
            state[number] = set(after)
    return results


def list_inbox(issues: List[dict], cfg) -> List[dict]:
    """Open issues whose status is the intake or the waiting one: what a triage pass reasons over."""
    wanted = {cfg.role_label("intake"), cfg.role_label("waiting")}
    out = []
    for issue in sorted((i for i in issues if is_open(i)), key=lambda i: int(i["number"])):
        names = label_names(issue)
        if names & wanted:
            out.append(
                {"number": int(issue["number"]), "title": issue.get("title", ""), "labels": sorted(names), "createdAt": issue.get("createdAt")}
            )
    return out


def _cell(names) -> str:
    return ", ".join(sorted(names))


def render_table(results: List[Result]) -> str:
    lines = [
        "| #issue | before | after | reason | confidence | verdict |",
        "|--------|--------|-------|--------|------------|---------|",
    ]
    for result in results:
        p = result.proposal
        verdict = "ok" if result.ok else "REJECT(%s)" % ",".join(result.codes)
        ref = "#?" if p.issue is None else "#%d" % p.issue
        reason = p.reason.replace("|", "\\|").replace("\n", " ")
        lines.append("| %s | %s | %s | %s | %s | %s |" % (ref, _cell(p.before), _cell(p.after), reason, p.confidence, verdict))
    return "\n".join(lines)


def table_digest(proposals: List[Proposal]) -> str:
    rows = sorted(
        (
            json.dumps(
                {"issue": p.issue, "labels_before": sorted(p.before), "labels_after": sorted(p.after)},
                sort_keys=True,
                separators=(",", ":"),
            )
            for p in proposals
        ),
        key=lambda s: (json.loads(s)["issue"] is None, json.loads(s)["issue"] or 0, s),
    )
    return hashlib.sha256(("[" + ",".join(rows) + "]").encode()).hexdigest()[:16]


def _issues(args, cfg, gh) -> List[dict]:
    if args.issues_file:
        return load_json_list(args.issues_file)
    return gh.fetch_issues("open", OPEN_LIMIT)


def _ensure_gh(cfg, gh):
    if gh is None:
        from backlog_gh import Gh

        gh = Gh(cfg)
    return gh


def build_inbox_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="backlog_cli.py inbox", description="List the issues awaiting triage (read-only).")
    parser.add_argument("--issues-file", help="open issues, `gh issue list --json` shape (offline)")
    return parser


def build_check_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py triage-check",
        description="Validate a triage proposals file and print the review table. Propose-only: nothing is written.",
    )
    parser.add_argument("--proposals", required=True, help="JSON list of {issue, labels_before, labels_after, reason, confidence}")
    parser.add_argument("--issues-file", help="open issues, `gh issue list --json` shape (offline)")
    parser.add_argument("--labels-file", help="repo labels, `gh label list --json name` shape (offline)")
    parser.add_argument("--strict", action="store_true", help="exit 1 when any proposal is rejected")
    return parser


def main_inbox(argv: List[str], cfg, gh=None) -> int:
    args = build_inbox_parser().parse_args(argv)
    try:
        issues = _issues(args, cfg, gh if args.issues_file else _ensure_gh(cfg, gh))
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as exc:
        print("[backlog-triage] error: %s" % exc)
        return 1
    print(json.dumps(list_inbox(issues, cfg), indent=2))
    return 0


def main_check(argv: List[str], cfg, gh=None) -> int:
    args = build_check_parser().parse_args(argv)
    try:
        proposals = parse_proposals(load_json_list(args.proposals))
        if args.issues_file and args.labels_file:
            issues = load_json_list(args.issues_file)
            labels = {str(entry["name"]) for entry in load_json_list(args.labels_file)}
        else:
            gh = _ensure_gh(cfg, gh)
            issues = load_json_list(args.issues_file) if args.issues_file else gh.fetch_issues("open", OPEN_LIMIT)
            if args.labels_file:
                labels = {str(entry["name"]) for entry in load_json_list(args.labels_file)}
            else:
                labels = gh.fetch_label_names()
    except (RuntimeError, ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print("[backlog-triage] error: %s" % exc)
        return 1

    results = validate(proposals, issues, labels, cfg)
    rejected = sum(1 for r in results if not r.ok)
    print(
        "[backlog-triage] open=%d proposals=%d accepted=%d rejected=%d"
        % (sum(1 for i in issues if is_open(i)), len(results), len(results) - rejected, rejected)
    )
    print(render_table(results))
    print("[backlog-triage] table-digest: %s" % table_digest(proposals))
    print("[backlog-triage] propose-only: nothing was written; a human applies the accepted rows")
    return 1 if args.strict and rejected else 0
