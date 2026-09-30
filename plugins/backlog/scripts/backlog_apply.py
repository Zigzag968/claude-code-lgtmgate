"""Applier of the catch-up tooling: the write half of `label-sync`, `catchup check` and `rollback`. Stdlib only.

This is the ONLY module that mints an `ApplyGrant` and builds an `ApplyGh` (the label-write chokepoint of
`backlog_gh.py`). No skill names or calls it: it is reached from the three `--apply` flags and from the
single-issue `set --apply` (`mint_set_grant` / `execute_set`, below), and the opt-in PreToolUse rule of the plugin
hook asks the human before an agent Bash call may run one of them.

An apply run refuses (exit 1, ZERO write call, one code per missing condition) unless ALL of these hold:

  mode       the config mode is `write-supervised` or `free` (the mode is a ceiling: `free` waives nothing)
  repo       `repo:` is present in the `.claude/backlog.yml` of the target
  apply      `--apply` was passed
  confirm    `--confirm` equals the table digest printed by the dry run (bound to the repo AND the snapshot)
  snapshot   a verified snapshot: sha256, version and repo match, it lives outside the repo, and it covers
             every proposed issue with the labels the proposal starts from
  rejected   the validation of the FRESH live data rejects nothing

After the gate, the run re-reads the live issues, diffs against their live labels, adds THEN removes, and
journals after every issue (atomic write next to the snapshot). It stops at the first failure and works in
batches of at most 50 issues: re-running the same command resumes. It never adds the `ready` status nor an
agent executor label (promotion stays a human triage decision), never deletes, renames or edits a label.

The one exception is the single-issue `set` (`mint_set_grant`): it may add them only for a repo that opted in with
`promotion: checked`, for the one issue an ok `PromotionVerdict` (backlog_promote.py) covers. The bulk paths above
never relax the refusal.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

from backlog_catchup import OPEN_LIMIT, catchup_digest, validate_catchup
from backlog_common import LabelEdit, label_names, load_json_list, printable
from backlog_gh import MAX_APPLY_ISSUES, ApplyGh, ApplyGrant, DepGh, Gh, PartialApplyError
from backlog_labelsync import labelsync_digest, plan, spec_from_config
from backlog_promote import PromotionVerdict, effective_promotion, reserved_adds
from backlog_snapshot import (
    SNAPSHOT_FILE,
    SNAPSHOT_VERSION,
    assert_outside_repo,
    project_dir_of,
    render_rollback,
    rollback_digest,
    rollback_plan,
)
from backlog_triage import parse_proposals, render_table

CODES = ("mode", "repo", "apply", "confirm", "snapshot", "rejected")
JOURNAL_VERSION = 1
CATCHUP_JOURNAL = "applied.json"
ROLLBACK_JOURNAL = "rollback-applied.json"
LABELSYNC_JOURNAL = "label-sync-applied.json"
SET_JOURNAL = "set-journal.jsonl"
_DONE = ("applied", "noop")


class Refused(Exception):
    """An apply condition is not met (nothing was written). The message is `<code>: <text>`."""

    def __init__(self, code: str, text: str):
        super().__init__("%s: %s" % (code, text))
        self.code = code


@dataclass(frozen=True)
class Gate:
    """Proof that `check_gate` passed. Only `check_gate` builds one."""

    digest: str
    confirm: str
    sha: str
    rejected: int


# --- the gate ----------------------------------------------------------------------------------------


def stage_one(cfg, apply: bool) -> None:
    """The cheap conditions (mode, repo, apply): checked BEFORE any live read."""
    if cfg.mode not in ("write-supervised", "free"):
        raise Refused("mode", "mode %s never writes (write-supervised or free is required)" % cfg.mode)
    if not cfg.repo:
        raise Refused("repo", "`repo:` is absent from .claude/backlog.yml (an apply needs an explicit target)")
    if not apply:
        raise Refused("apply", "--confirm without --apply: nothing to do (add --apply to write)")


def _load_snapshot(snapshot_dir, project_dir) -> Tuple[Path, bytes]:
    try:
        directory = assert_outside_repo(snapshot_dir, project_dir)
        return directory, (directory / SNAPSHOT_FILE).read_bytes()
    except (ValueError, OSError) as exc:
        raise Refused("snapshot", printable(exc))


def verify_snapshot(cfg, snapshot_dir, expect_sha, project_dir, covers: Iterable[Tuple[int, Iterable[str]]] = ()) -> str:
    """Return the verified sha256 of the snapshot, or raise `Refused("snapshot", ...)`."""
    if not snapshot_dir or not expect_sha:
        raise Refused("snapshot", "--snapshot-dir and --expect-sha are required (take a snapshot first)")
    _, raw = _load_snapshot(snapshot_dir, project_dir)
    sha = hashlib.sha256(raw).hexdigest()
    if sha != expect_sha:
        raise Refused("snapshot", "sha256 mismatch (expected %s, got %s)" % (printable(expect_sha), sha))
    try:
        snapshot = json.loads(raw)
        if not isinstance(snapshot, dict) or snapshot.get("version") != SNAPSHOT_VERSION:
            raise Refused("snapshot", "unsupported snapshot version")
        if snapshot.get("repo") != cfg.repo:
            raise Refused("snapshot", "the snapshot belongs to %s, the config targets %s" % (printable(snapshot.get("repo")), cfg.repo))
        by_number = {int(i["number"]): set(i.get("labels") or []) for i in snapshot["issues"]}
    except (ValueError, KeyError, TypeError) as exc:
        raise Refused("snapshot", "unreadable snapshot (%s)" % printable(exc))
    for number, before in covers:
        if number not in by_number:
            raise Refused("snapshot", "#%d is not in the snapshot: take a fresh snapshot" % number)
        if by_number[number] != set(before):
            raise Refused("snapshot", "#%d changed since the snapshot (labels differ): take a fresh snapshot" % number)
    return sha


def check_gate(cfg, *, apply: bool, confirm: Optional[str], digest: Optional[str],
               verify: Callable[[], str], rejected: int) -> Gate:
    """The six conditions, in a fixed order, one code each. Any miss raises `Refused` (zero write)."""
    stage_one(cfg, apply)
    if digest is None:
        verify()  # surfaces the missing/invalid snapshot first
        raise Refused("confirm", "no table digest can be computed")
    if not confirm or confirm != digest:
        raise Refused("confirm", "--confirm does not match the table digest printed by the dry run")
    sha = verify()
    if rejected:
        raise Refused("rejected", "%d proposal(s) rejected on the live data: fix them and re-run the check" % rejected)
    return Gate(digest=digest, confirm=confirm, sha=sha, rejected=rejected)


def mint_grant(cfg, gate: Gate, issues: Iterable[int] = (), labels: Iterable[str] = ()) -> ApplyGrant:
    """Defence in depth: re-verify the gate's facts, then mint the grant. Never builds one without a `Gate`."""
    if not isinstance(gate, Gate):
        raise Refused("apply", "no gate")
    if cfg.mode not in ("write-supervised", "free"):
        raise Refused("mode", "mode %s never writes" % cfg.mode)
    if not cfg.repo:
        raise Refused("repo", "`repo:` is absent")
    if gate.confirm != gate.digest:
        raise Refused("confirm", "--confirm does not match the table digest")
    if gate.rejected:
        raise Refused("rejected", "rejected proposals")
    refused_adds = frozenset({cfg.role_label("ready")} | set(cfg.role_labels("agent")))
    return ApplyGrant(
        repo=cfg.repo,
        digest=gate.digest,
        snapshot_sha=gate.sha,
        issues=frozenset(int(i) for i in issues),
        labels=frozenset(str(name) for name in labels),
        refused_adds=refused_adds,
    )


def mint_set_grant(cfg, edit: LabelEdit, verdict=None) -> ApplyGrant:
    """The grant of ONE single-issue `set` (backlog_set.py). Same defence in depth as `mint_grant`, but bound to the
    one issue of `edit` and to no label creation. The reserved labels (`backlog_promote.reserved_adds`: the ready
    status, plus an agent executor unless `exec_gating: triage`) stay refused UNLESS `effective_promotion` says this
    edit is not itself a promotion attempt (the bootstrap carve-out: a labelless issue's first `set --apply` that
    picks up an agent executor without requesting `status:ready`, or `exec_gating: triage` making the executor a
    plain triage label) or `verdict` is an ok `PromotionVerdict` of THIS issue on a repo that opted in with
    `promotion: checked`. `mint_grant` (the bulk paths) never relaxes it."""
    if not isinstance(edit, LabelEdit):
        raise Refused("apply", "no edit")
    if cfg.mode not in ("write-supervised", "free"):
        raise Refused("mode", "mode %s never writes" % cfg.mode)
    if not cfg.repo:
        raise Refused("repo", "`repo:` is absent")
    refused_adds = frozenset(reserved_adds(cfg)) if effective_promotion(edit.before, edit.after, cfg) else frozenset()
    if isinstance(verdict, PromotionVerdict) and verdict.ok and verdict.issue == edit.issue and cfg.promotion == "checked":
        refused_adds = frozenset()
    fingerprint = "|".join([cfg.repo, str(edit.issue), ",".join(edit.add), ",".join(edit.remove)])
    return ApplyGrant(
        repo=cfg.repo,
        digest="set:" + hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()[:16],
        snapshot_sha="",
        issues=frozenset({int(edit.issue)}),
        labels=frozenset(),
        refused_adds=refused_adds,
    )


# --- the journal ---------------------------------------------------------------------------------------


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Journal:
    """One JSON file per apply kind, next to the snapshot. Rewritten whole, atomically, after every issue."""

    def __init__(self, path: Path, kind: str, repo: str, digest: str, snapshot_sha: str, entries: Optional[List[dict]] = None):
        self.path = Path(path)
        self.kind = kind
        self.repo = repo
        self.digest = digest
        self.snapshot_sha = snapshot_sha
        self.entries: List[dict] = list(entries or [])

    @classmethod
    def load(cls, path, kind: str, repo: str, digest: str, snapshot_sha: str) -> "Journal":
        target = Path(path)
        if not target.exists():
            return cls(target, kind, repo, digest, snapshot_sha)
        try:
            data = json.loads(target.read_text(encoding="utf-8"))
            same = (
                isinstance(data, dict)
                and data.get("version") == JOURNAL_VERSION
                and data.get("kind") == kind
                and data.get("repo") == repo
                and data.get("digest") == digest
                and data.get("snapshot_sha") == snapshot_sha
                and isinstance(data.get("entries"), list)
                and all(isinstance(e, dict) and "key" in e and "status" in e for e in data["entries"])
            )
        except (ValueError, OSError):
            same = False
            data = None
        if not same:
            raise Refused("snapshot", "%s is a journal of another table or snapshot (or unreadable): take a fresh snapshot" % printable(target))
        return cls(target, kind, repo, digest, snapshot_sha, data["entries"])

    def done(self) -> Set[str]:
        return {str(e["key"]) for e in self.entries if e.get("status") in _DONE}

    def record(self, key: str, status: str, add: Sequence[str] = (), remove: Sequence[str] = ()) -> None:
        self.entries.append({"key": str(key), "status": status, "add": list(add), "remove": list(remove), "at": _now()})
        self._write()

    def _write(self) -> None:
        payload = json.dumps(
            {
                "version": JOURNAL_VERSION,
                "kind": self.kind,
                "repo": self.repo,
                "digest": self.digest,
                "snapshot_sha": self.snapshot_sha,
                "entries": self.entries,
            },
            indent=2,
            sort_keys=True,
        ) + "\n"
        fd, tmp = tempfile.mkstemp(dir=str(self.path.parent), prefix=".journal-", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(self.path))


class SetJournal:
    """Append-only JSON lines of the single-issue `set`: `<project>/.claude/.backlog-snapshots/set-journal.jsonl`
    (directory 0700, file 0600, INSIDE the project — unlike the bulk snapshot/catchup tooling below, which stays
    outside any repo). One `intent` line is written BEFORE the write, then one outcome line. Never rewritten,
    never truncated. Human decision (2026-09-28): moved in-project so a sandboxed Claude Code session (default
    write scope: CWD + session temp dir only) can write it without a harness-level config change. Trade-off
    accepted knowingly: this journal no longer survives deletion of the checkout it was written from, and is not
    shared across worktrees of the same repo (each worktree gets its own `.claude/.backlog-snapshots/`) — the
    bulk snapshot/catchup/rollback tooling keeps the outside-repo, cross-worktree-safe placement, since a mistake
    there is bulk and harder to recover from. The directory is listed in `.gitignore`; never commit it."""

    def __init__(self, path: Path):
        self.path = Path(path)

    @classmethod
    def for_repo(cls, cfg) -> "SetJournal":
        try:
            directory = project_dir_of(cfg) / ".claude" / ".backlog-snapshots"
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        except OSError as exc:
            raise Refused("journal", printable(exc))
        return cls(directory / SET_JOURNAL)

    def append(self, entry: dict) -> None:
        line = json.dumps(dict(entry, at=_now()), sort_keys=True) + "\n"
        fd = os.open(str(self.path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(str(self.path), 0o600)


# --- the apply loops -----------------------------------------------------------------------------------


@dataclass
class Outcome:
    applied: int = 0
    noop: int = 0
    remaining: int = 0
    error: Optional[str] = None


def apply_edits(apply_gh: ApplyGh, journal: Journal, edits: Sequence[LabelEdit], live_by_number: Dict[int, dict], tag: str) -> Outcome:
    """Apply the not-yet-journaled edits (at most one batch), diffing each against its FRESH live labels: add
    first, then remove. Journal after every issue; stop at the first failure."""
    done = journal.done()
    pending = [e for e in edits if str(e.issue) not in done]
    outcome = Outcome(remaining=len(pending))
    for edit in pending[:MAX_APPLY_ISSUES]:
        live_issue = live_by_number.get(edit.issue)
        if live_issue is None:
            outcome.error = "#%d is no longer open" % edit.issue
            break
        live = label_names(live_issue)
        add_now = [name for name in edit.add if name not in live]
        remove_now = [name for name in edit.remove if name in live]
        try:
            if not add_now and not remove_now:
                journal.record(str(edit.issue), "noop")
                outcome.noop += 1
                print("[%s] noop #%d (already in the target state)" % (tag, edit.issue))
            else:
                try:
                    apply_gh.edit_labels(edit.issue, add_now, remove_now)
                except PartialApplyError:
                    journal.record(str(edit.issue), "partial", add_now, ())
                    raise
                journal.record(str(edit.issue), "applied", add_now, remove_now)
                outcome.applied += 1
                print("[%s] %s #%d (+%d -%d)" % (tag, "restored" if tag == "rollback" else "applied", edit.issue, len(add_now), len(remove_now)))
        except (RuntimeError, OSError) as exc:
            outcome.error = "#%d: %s" % (edit.issue, printable(exc))
            break
        outcome.remaining -= 1
    return outcome


def _finish(tag: str, prefix: str, verb: str, outcome: Outcome, skipped: Optional[int], journal: Journal, extra: str = "") -> int:
    if outcome.error:
        print("[%s] error: %s" % (tag, outcome.error))
        print("[%s] stopped: %s=%d remaining=%d journal=%s" % (tag, verb, outcome.applied, outcome.remaining, printable(journal.path)))
        return 1
    middle = "" if skipped is None else " skipped=%d" % skipped
    print("[%s] %s%s=%d%s remaining=%d journal=%s%s" % (tag, prefix, verb, outcome.applied, middle, outcome.remaining, printable(journal.path), extra))
    if outcome.remaining:
        print("[%s] batch limit reached: %s=%d remaining=%d; re-run the same command to resume" % (tag, verb, outcome.applied, outcome.remaining))
    return 0


def _refuse(tag: str, exc: Refused) -> int:
    print("[%s] refused: %s" % (tag, printable(exc)))
    return 1


def _offline(args, tag: str, names: Sequence[Tuple[str, str]]) -> None:
    for attr, flag in names:
        if getattr(args, attr, None):
            raise Refused("apply", "--apply reads the LIVE state from GitHub: %s is for dry runs only" % flag)


def _journal(args, cfg, kind: str, file_name: str, digest: Optional[str]) -> Optional[Journal]:
    if not args.snapshot_dir or not args.expect_sha or digest is None:
        return None
    return Journal.load(Path(args.snapshot_dir).expanduser().resolve() / file_name, kind, cfg.repo, digest, args.expect_sha)


def _ensure_gh(cfg, gh):
    return gh if gh is not None else Gh(cfg)


def _fresh_journal(journal: Optional[Journal], args, cfg, kind: str, file_name: str, gate: Gate) -> Journal:
    return journal or Journal.load(Path(args.snapshot_dir).expanduser().resolve() / file_name, kind, cfg.repo, gate.digest, gate.sha)


# --- catchup check --apply -----------------------------------------------------------------------------


def apply_catchup(args, cfg, gh=None, apply_runner=None) -> int:
    tag = "catch-up"
    try:
        _offline(args, tag, (("issues_file", "--issues-file"), ("labels_file", "--labels-file")))
        stage_one(cfg, args.apply)
        gh = _ensure_gh(cfg, gh)
        proposals = parse_proposals(load_json_list(args.proposals))
        digest = catchup_digest(proposals, cfg.repo, args.expect_sha) if args.expect_sha else None
        journal = _journal(args, cfg, "catchup", CATCHUP_JOURNAL, digest)
        done = journal.done() if journal else set()
        pending = [p for p in proposals if p.issue is None or str(p.issue) not in done]
        issues = gh.fetch_issues("open", OPEN_LIMIT)
        labels = gh.fetch_label_names()
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[%s] error: %s" % (tag, printable(exc)))
        return 1

    results = validate_catchup(pending, issues, labels, cfg)
    rejected = sum(1 for r in results if not r.ok)
    print("[%s] open=%d proposals=%d accepted=%d rejected=%d" % (tag, len(issues), len(results), len(results) - rejected, rejected))
    for line in render_table(results).split("\n"):
        print(printable(line))
    print("[%s] table-digest: %s" % (tag, digest or "(needs --snapshot-dir and --expect-sha)"))
    try:
        gate = check_gate(
            cfg,
            apply=args.apply,
            confirm=args.confirm,
            digest=digest,
            verify=lambda: verify_snapshot(
                cfg, args.snapshot_dir, args.expect_sha, project_dir_of(cfg),
                covers=[(p.issue, p.before) for p in pending if not p.schema_error],
            ),
            rejected=rejected,
        )
        edits = [
            LabelEdit(
                issue=int(r.proposal.issue),
                before=tuple(sorted(r.proposal.before)),
                after=tuple(sorted(r.proposal.after)),
                add=tuple(sorted(r.proposal.after - r.proposal.before)),
                remove=tuple(sorted(r.proposal.before - r.proposal.after)),
                reason=r.proposal.reason,
            )
            for r in results
        ]
        grant = mint_grant(cfg, gate, issues=[e.issue for e in edits])
        journal = _fresh_journal(journal, args, cfg, "catchup", CATCHUP_JOURNAL, gate)
        apply_gh = ApplyGh(cfg, grant, runner=apply_runner)
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, OSError) as exc:  # ModeError of the constructor, unreadable journal directory
        print("[%s] refused: %s" % (tag, printable(exc)))
        return 1
    outcome = apply_edits(apply_gh, journal, edits, {int(i["number"]): i for i in issues}, tag)
    return _finish(tag, "apply: ", "applied", outcome, outcome.noop, journal)


# --- rollback --apply ----------------------------------------------------------------------------------


def apply_rollback(args, cfg, gh=None, apply_runner=None) -> int:
    tag = "rollback"
    try:
        _offline(args, tag, (("issues_file", "--issues-file"), ("labels_file", "--labels-file")))
        stage_one(cfg, args.apply)
        gh = _ensure_gh(cfg, gh)
        _, raw = _load_snapshot(args.snapshot_dir, project_dir_of(cfg))
        try:
            snapshot_issues = json.loads(raw)["issues"]
            digest: Optional[str] = rollback_digest(snapshot_issues, cfg.repo)
        except (ValueError, KeyError, TypeError) as exc:
            raise Refused("snapshot", "unreadable snapshot (%s)" % printable(exc))
        journal = _journal(args, cfg, "rollback", ROLLBACK_JOURNAL, digest)
        issues = gh.fetch_issues("open", OPEN_LIMIT)
        labels = gh.fetch_label_names()
        edits, problems = rollback_plan(snapshot_issues, issues, labels, cfg)
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[%s] error: %s" % (tag, printable(exc)))
        return 1

    role_labels = {cfg.role_label("ready")} | set(cfg.role_labels("agent"))
    kept: List[LabelEdit] = []
    for edit in edits:
        forbidden = sorted(set(edit.add) & role_labels)
        if forbidden:
            problems.append("skip: #%d role-add-refused (would re-add %s: promotion stays a human decision)" % (edit.issue, ", ".join(forbidden)))
        else:
            kept.append(edit)
    print(render_rollback(kept))
    for entry in problems:
        print("[%s] %s" % (tag, printable(entry)))
    print("[%s] edits=%d table-digest: %s" % (tag, len(kept), digest))
    try:
        gate = check_gate(
            cfg,
            apply=args.apply,
            confirm=args.confirm,
            digest=digest,
            verify=lambda: verify_snapshot(cfg, args.snapshot_dir, args.expect_sha, project_dir_of(cfg)),
            rejected=0,
        )
        grant = mint_grant(cfg, gate, issues=[e.issue for e in kept])
        journal = _fresh_journal(journal, args, cfg, "rollback", ROLLBACK_JOURNAL, gate)
        apply_gh = ApplyGh(cfg, grant, runner=apply_runner)
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, OSError) as exc:
        print("[%s] refused: %s" % (tag, printable(exc)))
        return 1
    outcome = apply_edits(apply_gh, journal, kept, {int(i["number"]): i for i in issues}, tag)
    return _finish(tag, "", "restored", outcome, len(problems), journal)


# --- label-sync --apply --------------------------------------------------------------------------------


def apply_labelsync(args, cfg, gh=None, apply_runner=None) -> int:
    tag = "label-sync"
    try:
        _offline(args, tag, (("live_file", "--live-file"),))
        stage_one(cfg, args.apply)
        gh = _ensure_gh(cfg, gh)
        live = gh.fetch_labels()
        spec = spec_from_config(cfg)
        colors = {entry["name"]: entry["color"] for entry in spec}
        actions = plan(spec, live)
        creates = [(a.name, colors[a.name]) for a in actions if a.kind == "create"]
        digest = labelsync_digest(creates, cfg.repo, args.expect_sha) if args.expect_sha else None
        journal = _journal(args, cfg, "label-sync", LABELSYNC_JOURNAL, digest)
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print("[%s] error: %s" % (tag, printable(exc)))
        return 1

    for action in actions:
        print("[%s] %s %s" % (tag, action.kind, printable(action.name)))
    print("[%s] table-digest: %s" % (tag, digest or "(needs --snapshot-dir and --expect-sha)"))
    try:
        gate = check_gate(
            cfg,
            apply=args.apply,
            confirm=args.confirm,
            digest=digest,
            verify=lambda: verify_snapshot(cfg, args.snapshot_dir, args.expect_sha, project_dir_of(cfg)),
            rejected=0,
        )
        grant = mint_grant(cfg, gate, labels=[name for name, _ in creates])
        journal = _fresh_journal(journal, args, cfg, "label-sync", LABELSYNC_JOURNAL, gate)
        apply_gh = ApplyGh(cfg, grant, runner=apply_runner)
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, OSError) as exc:
        print("[%s] refused: %s" % (tag, printable(exc)))
        return 1

    done = journal.done()
    pending = [(name, color) for name, color in creates if name not in done]
    outcome = Outcome(remaining=len(pending))
    for name, color in pending[:MAX_APPLY_ISSUES]:
        try:
            apply_gh.create_label(name, color)
            journal.record(name, "applied", (name,), ())
        except (RuntimeError, OSError) as exc:
            outcome.error = "%s: %s" % (printable(name), printable(exc))
            break
        outcome.applied += 1
        outcome.remaining -= 1
        print("[%s] created %s" % (tag, printable(name)))
    return _finish(tag, "apply: ", "created", outcome, None, journal, " (drift left untouched: no label edit)")


# --- set (one issue) -----------------------------------------------------------------------------------


def _verdict_record(verdict) -> Optional[dict]:
    """The facts of a promotion verdict for the journal: codes and counts only, never any issue text."""
    if not isinstance(verdict, PromotionVerdict):
        return None
    return {"ok": verdict.ok, "codes": list(verdict.codes), "facts": dict(verdict.facts)}


def execute_set(cfg, edit: LabelEdit, reason: str = "", verdict=None, apply_runner=None) -> int:
    """Apply ONE validated label change of ONE issue. The journal `intent` line comes first: no journal, no write."""
    tag = "set"
    try:
        grant = mint_set_grant(cfg, edit, verdict)
        journal = SetJournal.for_repo(cfg)
        apply_gh = ApplyGh(cfg, grant, runner=apply_runner)
        journal.append({
            "issue": edit.issue, "status": "intent", "before": list(edit.before), "add": list(edit.add),
            "remove": list(edit.remove), "reason": reason, "promotion": _verdict_record(verdict),
        })
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, OSError) as exc:  # ModeError of the constructor, unwritable journal
        print("[%s] refused: %s" % (tag, printable(exc)))
        return 1
    try:
        try:
            apply_gh.edit_labels(edit.issue, edit.add, edit.remove)
        except PartialApplyError as exc:
            journal.append({"issue": edit.issue, "status": "partial"})
            print("[%s] error: #%d: %s" % (tag, edit.issue, printable(exc)))
            return 1
        except RuntimeError as exc:
            journal.append({"issue": edit.issue, "status": "failed"})
            print("[%s] error: #%d: %s" % (tag, edit.issue, printable(exc)))
            return 1
        journal.append({"issue": edit.issue, "status": "applied"})
    except OSError as exc:
        print("[%s] error: #%d: the journal could not record the outcome (%s)" % (tag, edit.issue, printable(exc)))
        return 1
    print("[%s] applied: added=%s removed=%s journal=%s" % (
        tag, ",".join(edit.add) or "-", ",".join(edit.remove) or "-", printable(journal.path)))
    return 0


def execute_deps(cfg, issue: int, add: Sequence[int], remove: Sequence[int], reason: str = "", dep_runner=None) -> int:
    """Apply the dependency changes ("Blocked by") of ONE issue, REST only, through `DepGh`. Same gate as the label
    write (`stage_one`) and the same journal: the `intent` line comes first, no journal, no write."""
    tag = "set"
    try:
        stage_one(cfg, True)
        journal = SetJournal.for_repo(cfg)
        dep_gh = DepGh(cfg, runner=dep_runner)
        journal.append({
            "issue": issue, "status": "intent", "kind": "dependencies",
            "blocked_by_add": list(add), "blocked_by_remove": list(remove), "reason": reason,
        })
    except Refused as exc:
        return _refuse(tag, exc)
    except (RuntimeError, OSError) as exc:  # ModeError of the constructor, unwritable journal
        print("[%s] refused: %s" % (tag, printable(exc)))
        return 1
    done_add: List[int] = []
    done_remove: List[int] = []
    try:
        try:
            for number in add:
                dep_gh.add_blocked_by(issue, number)
                done_add.append(number)
            for number in remove:
                dep_gh.remove_blocked_by(issue, number)
                done_remove.append(number)
        except RuntimeError as exc:
            status = "partial" if (done_add or done_remove) else "failed"
            journal.append({"issue": issue, "status": status, "kind": "dependencies",
                            "blocked_by_add": done_add, "blocked_by_remove": done_remove})
            print("[%s] error: #%d: %s (%s: added=%s removed=%s)" % (
                tag, issue, printable(exc), status,
                ",".join("#%d" % n for n in done_add) or "-", ",".join("#%d" % n for n in done_remove) or "-"))
            return 1
        journal.append({"issue": issue, "status": "applied", "kind": "dependencies"})
    except OSError as exc:
        print("[%s] error: #%d: the journal could not record the outcome (%s)" % (tag, issue, printable(exc)))
        return 1
    print("[%s] applied: blocked-by added=%s removed=%s journal=%s" % (
        tag, ",".join("#%d" % n for n in add) or "-", ",".join("#%d" % n for n in remove) or "-", printable(journal.path)))
    return 0
