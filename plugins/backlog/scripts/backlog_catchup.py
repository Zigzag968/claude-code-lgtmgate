"""Backlog catch-up: move legacy labels onto the configured taxonomy. Stdlib only.

`propose` builds the deterministic baseline of proposals from the config's `legacy_map` (read-only; `--out` writes
ONE new local file outside any repo). `check` validates a proposals file against the live issues and prints the
review table with a digest bound to the repo (and, when a snapshot is named, to that snapshot). Without `--apply`
nothing is written; `check --apply` delegates to `backlog_apply.py`, which holds every apply condition and the only
write path. This module reuses the triage validator (`backlog_triage`) and adds the catch-up rules on top of it.

Adding the `ready` status or an agent executor label is refused (`role-add-refused`): promotion to the agent
queue stays a human triage decision.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from typing import FrozenSet, List, Optional, Set

from backlog_common import (
    axis_labels,
    is_open,
    label_names,
    load_json_list,
    printable,
    repo_assertion_error,
)
from backlog_config import AXES
from backlog_snapshot import assert_outside_repo, project_dir_of, write_exclusive
from backlog_triage import (
    Result,
    parse_proposals,
    render_table,
    table_digest,
    validate,
)

OPEN_LIMIT = 500


@dataclass(frozen=True)
class MapResult:
    after: Optional[FrozenSet[str]]
    reason: str
    confidence: str
    unresolved: Optional[str] = None


def _unresolved(code: str) -> MapResult:
    return MapResult(None, code, "low", code)


def map_legacy(names: Set[str], cfg) -> MapResult:
    """Deterministic baseline of the config's `legacy_map`. Anything ambiguous is `unresolved` for a human.

    Per axis (except the free-form `area`): the existing labels of the axis plus the mapped targets must resolve
    to ONE label, else `<axis>-conflict`. Exception, `type` with no existing `type:` label and several mapped
    targets: the FIRST one in the order of `labels.type` wins (confidence medium). No type at all is
    `type-unmapped`. A missing status becomes the intake one. Mapped legacy labels are dropped unless listed in
    `legacy_keep`."""
    after = set(names)
    parts: List[str] = []
    confidence = "high"
    mapped = {name: cfg.legacy_map[name] for name in sorted(names) if name in cfg.legacy_map}
    targets_by_axis = {}
    for target in mapped.values():
        targets_by_axis.setdefault(target.split(":", 1)[0], set()).add(target)

    for axis in AXES:
        targets = targets_by_axis.get(axis, set())
        if axis == "area":
            after |= targets
            continue
        existing = set(axis_labels(names, axis))
        candidates = existing | targets
        if axis == "type" and not existing and len(targets) > 1:
            order = ["type:%s" % value for value in cfg.labels.get("type", ())]
            ranked = [label for label in order if label in targets]
            chosen = ranked[0]
            after.add(chosen)
            confidence = "medium"
            parts.append("type precedence %s" % ">".join(label.split(":", 1)[1] for label in ranked))
            continue
        if len(candidates) > 1:
            return _unresolved("%s-conflict" % axis)
        after |= targets
        if not candidates:
            if axis == "type":
                return _unresolved("type-unmapped")
            if axis == "status":
                intake = cfg.role_label("intake")
                after.add(intake)
                parts.append("no status->%s" % intake)

    mapped_parts: List[str] = []
    for legacy, target in mapped.items():
        keep = legacy in cfg.legacy_keep
        mapped_parts.append("%s->%s%s" % (legacy, target, " (kept)" if keep else ""))
        if not keep:
            after.discard(legacy)
    parts = mapped_parts + parts

    if after == names:
        return MapResult(frozenset(after), "already canonical", "high")
    return MapResult(frozenset(after), "; ".join(parts), confidence)


def catchup_digest(proposals, repo: Optional[str], snapshot_sha: Optional[str] = None) -> str:
    """The triage table digest, bound to the target repo: the same table for another repo has another digest.
    With `snapshot_sha` it is also bound to that snapshot (what `--confirm` must equal to apply)."""
    base = hashlib.sha256(((repo or "") + "\n" + table_digest(proposals)).encode()).hexdigest()[:16]
    if snapshot_sha is None:
        return base
    return hashlib.sha256((base + "\n" + snapshot_sha).encode()).hexdigest()[:16]


def validate_catchup(proposals, issues: List[dict], live_label_names: Set[str], cfg) -> List[Result]:
    """The triage validator, plus: the mapped legacy labels may be REMOVED, and `ready` / agent executor labels
    can never be ADDED (`role-add-refused`)."""
    removable = frozenset(cfg.legacy_map) - frozenset(cfg.legacy_keep)
    results = validate(proposals, issues, live_label_names, cfg, removable_extra=removable)
    refused = {cfg.role_label("ready")} | set(cfg.role_labels("agent"))
    for result in results:
        proposal = result.proposal
        if proposal.schema_error:
            continue
        if (proposal.after - proposal.before) & refused:
            result.codes.append("role-add-refused")
    return results


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py catchup",
        allow_abbrev=False,
        description="Legacy-label catch-up. `propose` and a plain `check` write nothing to GitHub; `check --apply` is gated.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    propose = sub.add_parser("propose", allow_abbrev=False, help="baseline proposals from the config's legacy_map (read-only)")
    propose.add_argument("--repo", help="assertion only: must equal `repo:` of .claude/backlog.yml")
    propose.add_argument("--issues-file", help="open issues, `gh issue list --json` shape (offline)")
    propose.add_argument("--out", help="write the proposals JSON to this NEW file, outside any repo")

    check = sub.add_parser("check", allow_abbrev=False, help="validate a proposals file and print the review table")
    check.add_argument("--repo", help="assertion only: must equal `repo:` of .claude/backlog.yml")
    check.add_argument("--proposals", required=True, help="JSON list of {issue, labels_before, labels_after, reason, confidence}")
    check.add_argument("--issues-file", help="open issues, `gh issue list --json` shape (offline)")
    check.add_argument("--labels-file", help="repo labels, `gh label list --json name` shape (offline)")
    check.add_argument("--strict", action="store_true", help="exit 1 when any proposal is rejected")
    check.add_argument("--apply", action="store_true", help="apply the accepted proposals (needs --snapshot-dir, --expect-sha, --confirm)")
    check.add_argument("--confirm", help="the table-digest printed by the check")
    check.add_argument("--snapshot-dir", help="a verified snapshot directory (outside any repo)")
    check.add_argument("--expect-sha", help="sha256 of the snapshot.json")
    return parser


def _ensure_gh(cfg, gh):
    if gh is None:
        from backlog_gh import Gh

        gh = Gh(cfg)
    return gh


def _cmd_propose(args, cfg, gh) -> int:
    try:
        issues = load_json_list(args.issues_file) if args.issues_file else _ensure_gh(cfg, gh).fetch_issues("open", OPEN_LIMIT)
        out_path = assert_outside_repo(args.out, project_dir_of(cfg)) if args.out else None
        proposals: List[dict] = []
        for issue in sorted((i for i in issues if is_open(i)), key=lambda i: int(i["number"])):
            names = label_names(issue)
            mapped = map_legacy(names, cfg)
            number = int(issue["number"])
            if mapped.unresolved:
                print("[catch-up] unresolved #%d: %s" % (number, mapped.unresolved))
                continue
            if mapped.after == names:
                continue
            proposals.append(
                {
                    "issue": number,
                    "labels_before": sorted(names),
                    "labels_after": sorted(mapped.after or ()),
                    "reason": mapped.reason,
                    "confidence": mapped.confidence,
                }
            )
        print("[catch-up] proposed=%d" % len(proposals))
        if out_path is not None:
            out_path.parent.mkdir(parents=True, exist_ok=True)
            write_exclusive(out_path, json.dumps(proposals, indent=2) + "\n", 0o600)
            print("[catch-up] wrote %s" % printable(out_path))
        else:
            for entry in proposals:
                print("[catch-up] #%d (%s): %s" % (entry["issue"], entry["confidence"], printable(entry["reason"])))
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[catch-up] error: %s" % printable(exc))
        return 1
    return 0


def _cmd_check(args, cfg, gh, apply_runner=None) -> int:
    if args.apply or args.confirm:
        from backlog_apply import apply_catchup  # lazy: backlog_apply imports this module

        return apply_catchup(args, cfg, gh, apply_runner)
    try:
        proposals = parse_proposals(load_json_list(args.proposals))
        if args.issues_file and args.labels_file:
            issues = load_json_list(args.issues_file)
            labels = {str(entry["name"]) for entry in load_json_list(args.labels_file)}
        else:
            gh = _ensure_gh(cfg, gh)
            issues = load_json_list(args.issues_file) if args.issues_file else gh.fetch_issues("open", OPEN_LIMIT)
            labels = {str(e["name"]) for e in load_json_list(args.labels_file)} if args.labels_file else gh.fetch_label_names()
        results = validate_catchup(proposals, issues, labels, cfg)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[catch-up] error: %s" % printable(exc))
        return 1

    rejected = sum(1 for r in results if not r.ok)
    print(
        "[catch-up] open=%d proposals=%d accepted=%d rejected=%d"
        % (sum(1 for i in issues if is_open(i)), len(results), len(results) - rejected, rejected)
    )
    for line in render_table(results).split("\n"):
        print(printable(line))
    bound = args.expect_sha if args.snapshot_dir and args.expect_sha else None
    print("[catch-up] table-digest: %s" % catchup_digest(proposals, cfg.repo, bound))
    print("[catch-up] dry-run only: nothing was written (--apply needs --snapshot-dir, --expect-sha and --confirm <table-digest>)")
    return 1 if args.strict and rejected else 0


def main(argv: List[str], cfg, gh=None, apply_runner=None) -> int:
    args = build_parser().parse_args(argv)
    problem = repo_assertion_error(cfg, args.repo)
    if problem:
        print("[catch-up] error: %s" % problem)
        return 1
    if args.command == "propose":
        return _cmd_propose(args, cfg, gh)
    return _cmd_check(args, cfg, gh, apply_runner)
