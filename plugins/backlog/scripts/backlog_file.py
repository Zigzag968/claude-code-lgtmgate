"""Backlog intake: validate one new issue against the config, then (mode permitting) create it.

The label set of a new issue is fixed by the config: exactly one `type:` label, the status is FORCED to the
intake one, free `area:*` labels are accepted, and nothing protected or human-owned (exclusion flags, executor
flags) can be set at intake. Creation goes through `Gh.create_issue`, the plugin's only write, and only when the
mode allows it:

* `propose`          -> always a dry run, nothing is created;
* `write-supervised` -> `--apply --confirm <payload-digest>` (the digest printed by the dry run) is required;
* `free`             -> `--apply` creates.

`--blocked-by N` (repeatable) declares GitHub native dependencies. The dry run prints one planned line per link,
the links are part of the payload digest, and after a successful create each one is written through `DepGh`
(REST). A link that fails after the create is reported with the created issue and the missing links.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from typing import List, Optional, Sequence, Set

from backlog_gh import MAX_DEP_LINKS, DepGh
from backlog_common import is_open, label_names, load_json_list, positive_int
from backlog_lint import lint

MAX_TITLE = 256
OPEN_LIMIT = 500


def normalize_title(title: str) -> str:
    return re.sub(r"[^0-9a-z]+", " ", title.casefold()).strip()


def final_labels(labels: Sequence[str], cfg) -> List[str]:
    """The labels the issue would be created with: the requested ones plus the forced intake status."""
    out = list(dict.fromkeys(labels))
    intake = cfg.role_label("intake")
    if intake not in out:
        out.append(intake)
    return out


def payload_digest(title: str, body: str, labels: Sequence[str], repo: Optional[str], blocked_by: Sequence[int] = ()) -> str:
    fields = {"title": title, "body": body, "labels": sorted(labels), "repo": repo or ""}
    if blocked_by:  # absent when empty: a payload without dependencies keeps its historical digest
        fields["blocked_by"] = sorted(set(blocked_by))
    payload = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def validate_intake(
    title: str,
    body: str,
    labels: Sequence[str],
    cfg,
    open_issues: List[dict],
    repo_labels: Optional[Set[str]] = None,
) -> List[str]:
    """Deterministic refusal codes for a new issue; an empty list means it may be filed."""
    codes: List[str] = []
    if not title.strip():
        codes.append("title-empty")
    if "\n" in title or "\r" in title:
        codes.append("title-multiline")
    if len(title) > MAX_TITLE:
        codes.append("title-too-long")

    intake = cfg.role_label("intake")
    known = cfg.axis_label_names()
    free = cfg.free_namespaces()
    for label in dict.fromkeys(labels):
        if label.startswith("status:") and label != intake:
            codes.append("status-not-intake")
        elif cfg.is_protected(label):
            codes.append("protected-label")
        elif label in cfg.exclusions or label in cfg.executor_flags:
            codes.append("flag-not-allowed")
        elif label not in known and not (free and label.startswith(free)):
            codes.append("unknown-label")

    final = final_labels(labels, cfg)
    for axis in cfg.intake_required:
        # type and status are already refused unconditionally by lint()'s exactly-one check below (and status
        # can never actually be missing: final_labels() always forces the intake one in), so only an axis
        # outside that pair needs its own code here — the default `intake_required: [type]` adds nothing new.
        if axis in ("type", "status"):
            continue
        if not any(name.startswith(axis + ":") for name in final):
            codes.append("%s-missing" % axis)
    for violation in lint([{"number": 0, "state": "OPEN", "labels": final}], cfg, caps={}):
        codes.append("lint:%s" % violation.code)

    open_only = [i for i in open_issues if is_open(i)]
    for label, cap in cfg.caps.items():
        if label in final and sum(1 for i in open_only if label in label_names(i)) + 1 > cap:
            codes.append("cap-exceeded:%s" % label)

    wanted = normalize_title(title)
    if wanted:
        for issue in sorted(open_only, key=lambda i: int(i["number"])):
            if normalize_title(str(issue.get("title", ""))) == wanted:
                codes.append("duplicate-of:#%d" % int(issue["number"]))
                break

    if repo_labels is not None:
        for label in final:
            if label not in repo_labels:
                codes.append("label-missing-in-repo:%s" % label)

    return list(dict.fromkeys(codes))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py file",
        description="Validate (and, mode permitting, create) one backlog issue. Dry run unless --apply.",
    )
    parser.add_argument("--title", required=True)
    body = parser.add_mutually_exclusive_group()
    body.add_argument("--body", help="issue body (prefer --body-file)")
    body.add_argument("--body-file", help="file holding the issue body")
    parser.add_argument("--label", action="append", default=[], help="label to set (repeatable); the status is forced to the intake one")
    parser.add_argument("--blocked-by", type=positive_int, action="append", default=[], metavar="N",
                        help="issue number this one is blocked by (repeatable); written as a native dependency after the create")
    parser.add_argument("--issues-file", help="open issues, `gh issue list --json` shape (offline, dry run only)")
    parser.add_argument("--labels-file", help="repo labels, `gh label list --json name` shape (offline, dry run only)")
    parser.add_argument("--apply", action="store_true", help="create the issue when the mode allows it")
    parser.add_argument("--confirm", help="payload-digest printed by the dry run (required in write-supervised)")
    return parser


_URL_NUMBER = re.compile(r"/issues/([1-9][0-9]*)\s*$")


def _read_body(args) -> str:
    if args.body_file:
        with open(args.body_file, encoding="utf-8") as handle:
            return handle.read()
    return args.body or ""


def _load_inputs(args, cfg, gh):
    if gh is None and not (args.issues_file and args.labels_file):
        from backlog_gh import Gh

        gh = Gh(cfg)
    issues = load_json_list(args.issues_file) if args.issues_file else gh.fetch_issues("open", OPEN_LIMIT)
    if args.labels_file:
        repo_labels = {str(entry["name"]) for entry in load_json_list(args.labels_file)}
    else:
        repo_labels = gh.fetch_label_names()
    return gh, issues, repo_labels


def _create_and_link(args, cfg, gh, dep_runner, body: str, labels: List[str], blockers: List[int]) -> int:
    dep_gh = None
    if blockers:
        try:  # built BEFORE the create: a mode/repo refusal must never leave a created issue without its links
            dep_gh = DepGh(cfg, runner=dep_runner)
        except RuntimeError as exc:
            print("[backlog-file] refusing to create: %s" % exc)
            return 1
    try:
        url = gh.create_issue(args.title, body, labels, confirmed=cfg.mode == "write-supervised")
    except RuntimeError as exc:
        print("[backlog-file] error: %s" % exc)
        return 1
    print("[backlog-file] created %s" % url)
    if not blockers:
        return 0
    match = _URL_NUMBER.search(url)
    if not match:
        print("[backlog-file] error: created %s but its number could not be read: missing blocked-by links: %s"
              % (url, ", ".join("#%d" % n for n in blockers)))
        return 1
    created = int(match.group(1))
    missing: List[int] = []
    first_error = ""
    for number in blockers:
        try:
            dep_gh.add_blocked_by(created, number)
        except RuntimeError as exc:
            missing.append(number)
            first_error = first_error or str(exc)
            continue
        print("[backlog-file] linked #%d blocked-by #%d" % (created, number))
    if missing:
        print("[backlog-file] error: created #%d (%s) but these blocked-by links are missing: %s (%s)"
              % (created, url, ", ".join("#%d" % n for n in missing), first_error))
        return 1
    return 0


def main(argv: List[str], cfg, gh=None, dep_runner=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        body = _read_body(args)
    except OSError as exc:
        print("[backlog-file] error: %s" % exc)
        return 1

    offline = bool(args.issues_file or args.labels_file)
    if args.apply and offline:
        print("[backlog-file] error: --apply cannot be combined with --issues-file/--labels-file (offline inputs are dry-run only)")
        return 1

    try:
        gh, issues, repo_labels = _load_inputs(args, cfg, gh)
    except (RuntimeError, ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print("[backlog-file] error: %s" % exc)
        return 1

    blockers = sorted(set(args.blocked_by))
    codes = validate_intake(args.title, body, args.label, cfg, issues, repo_labels)
    if len(blockers) > MAX_DEP_LINKS:
        codes.append("too-many-blocked-by:%d" % MAX_DEP_LINKS)
    labels = final_labels(args.label, cfg)
    digest = payload_digest(args.title, body, labels, cfg.repo, blockers)
    verdict = "ok" if not codes else "refused"
    print("[backlog-file] verdict=%s codes=%s payload-digest=%s" % (verdict, ",".join(codes) or "-", digest))
    print("[backlog-file] labels=%s" % ",".join(sorted(labels)))
    for number in blockers:
        print("[backlog-file] planned blocked-by: #%d" % number)

    if not args.apply:
        print("[backlog-file] dry-run: nothing created")
        return 0
    if codes:
        print("[backlog-file] refusing to create: the payload is refused")
        return 1
    if cfg.mode == "propose":
        print("[backlog-file] mode=propose: proposal only, nothing created")
        return 0
    if cfg.mode == "write-supervised":
        if args.confirm != digest:
            print("[backlog-file] refusing to create: --confirm must equal the printed payload-digest %s" % digest)
            return 1
    return _create_and_link(args, cfg, gh, dep_runner, body, labels, blockers)
