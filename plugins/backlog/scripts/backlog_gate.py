"""The apply gate of the catch-up tooling: the six conditions an apply must meet before any write. Stdlib only.

An apply refuses (`RefusedError`, one code per missing condition, zero write) unless the mode is `write-supervised` or
`free`, `repo:` is set, `--apply` was passed, `--confirm` equals the printed table digest, the snapshot is verified
(sha256, version and repo match, outside the repo, covering every proposed issue) and nothing is rejected on the live
data. `Gate` is the proof `check_gate` passed; the grant itself is minted by `backlog_apply.py` only.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Optional, Tuple

from backlog_common import printable
from backlog_snapshot import SNAPSHOT_FILE, SNAPSHOT_VERSION, assert_outside_repo


class RefusedError(Exception):
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


def stage_one(cfg, apply: bool) -> None:
    """The cheap conditions (mode, repo, apply): checked BEFORE any live read."""
    if cfg.mode not in ("write-supervised", "free"):
        raise RefusedError("mode", "mode %s never writes (write-supervised or free is required)" % cfg.mode)
    if not cfg.repo:
        raise RefusedError("repo", "`repo:` is absent from .claude/backlog.yml (an apply needs an explicit target)")
    if not apply:
        raise RefusedError("apply", "--confirm without --apply: nothing to do (add --apply to write)")


def load_snapshot(snapshot_dir, project_dir) -> Tuple[Path, bytes]:
    try:
        directory = assert_outside_repo(snapshot_dir, project_dir)
        return directory, (directory / SNAPSHOT_FILE).read_bytes()
    except (ValueError, OSError) as exc:
        raise RefusedError("snapshot", printable(exc))


def verify_snapshot(cfg, snapshot_dir, expect_sha, project_dir, covers: Iterable[Tuple[int, Iterable[str]]] = ()) -> str:
    """Return the verified sha256 of the snapshot, or raise `RefusedError("snapshot", ...)`."""
    if not snapshot_dir or not expect_sha:
        raise RefusedError("snapshot", "--snapshot-dir and --expect-sha are required (take a snapshot first)")
    _, raw = load_snapshot(snapshot_dir, project_dir)
    sha = hashlib.sha256(raw).hexdigest()
    if sha != expect_sha:
        raise RefusedError("snapshot", "sha256 mismatch (expected %s, got %s)" % (printable(expect_sha), sha))
    try:
        snapshot = json.loads(raw)
        if not isinstance(snapshot, dict) or snapshot.get("version") != SNAPSHOT_VERSION:
            raise RefusedError("snapshot", "unsupported snapshot version")
        if snapshot.get("repo") != cfg.repo:
            raise RefusedError("snapshot", "the snapshot belongs to %s, the config targets %s" % (printable(snapshot.get("repo")), cfg.repo))
        by_number = {int(i["number"]): set(i.get("labels") or []) for i in snapshot["issues"]}
    except (ValueError, KeyError, TypeError) as exc:
        raise RefusedError("snapshot", "unreadable snapshot (%s)" % printable(exc))
    for number, before in covers:
        if number not in by_number:
            raise RefusedError("snapshot", "#%d is not in the snapshot: take a fresh snapshot" % number)
        if by_number[number] != set(before):
            raise RefusedError("snapshot", "#%d changed since the snapshot (labels differ): take a fresh snapshot" % number)
    return sha


def check_gate(cfg, *, apply: bool, confirm: Optional[str], digest: Optional[str],
               verify: Callable[[], str], rejected: int) -> Gate:
    """The six conditions, in a fixed order, one code each. Any miss raises `RefusedError` (zero write)."""
    stage_one(cfg, apply)
    if digest is None:
        verify()  # surfaces the missing/invalid snapshot first
        raise RefusedError("confirm", "no table digest can be computed")
    if not confirm or confirm != digest:
        raise RefusedError("confirm", "--confirm does not match the table digest printed by the dry run")
    sha = verify()
    if rejected:
        raise RefusedError("rejected", "%d proposal(s) rejected on the live data: fix them and re-run the check" % rejected)
    return Gate(digest=digest, confirm=confirm, sha=sha, rejected=rejected)
