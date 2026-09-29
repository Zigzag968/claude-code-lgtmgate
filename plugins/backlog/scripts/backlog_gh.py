"""The `gh` chokepoint of the backlog plugin. Stdlib only.

Two classes, and this is the only module of the plugin that spawns a process:

* `Gh` (reads + ONE write, `issue create`). Its guarantees, all enforced before any process is spawned:
  - mode `off` (which is also what a missing or invalid `.claude/backlog.yml` resolves to) reaches nothing;
  - only allow-listed verb pairs run: four reads and ONE write. Every other verb raises `ModeError`;
  - the argv is built here: only the flags of each verb's allow-list pass, so a caller can never smuggle a
    repo override, a browser/editor flag or an assignment flag; the configured `repo` is injected as `-R`;
  - a write needs the mode to permit it (`propose` never writes, `write-supervised` needs `confirmed=True`,
    `free` writes) and is counted against a per-instance write cap; total calls are capped too.
* `ApplyGh`, the label-write half used by the catch-up tooling. It is a SIBLING of `Gh`, never a subclass, and
  `Gh.WRITE_ALLOW` stays exactly `{("issue", "create")}`. It runs two verbs only (`issue edit` with
  `--add-label` / `--remove-label`, `label create` with `--color` / `--description`), needs an `ApplyGrant`
  that only `backlog_apply.py` mints after every apply condition has passed, injects `-R <repo>` itself,
  validates every issue number and label name, and is capped per instance. It has no delete, rename or
  label-edit verb and no read method.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from typing import Any, Callable, Dict, FrozenSet, List, Optional, Sequence, Tuple

READ_ALLOW: FrozenSet[Tuple[str, str]] = frozenset(
    {("issue", "list"), ("issue", "view"), ("pr", "list"), ("label", "list")}
)
WRITE_ALLOW: FrozenSet[Tuple[str, str]] = frozenset({("issue", "create")})

ALLOWED_FLAGS: Dict[Tuple[str, str], FrozenSet[str]] = {
    ("issue", "list"): frozenset({"--state", "--limit", "--json"}),
    ("issue", "view"): frozenset({"--json"}),
    ("pr", "list"): frozenset({"--state", "--limit", "--json"}),
    ("label", "list"): frozenset({"--limit", "--json"}),
    ("issue", "create"): frozenset({"--title", "--body", "--label"}),
}

APPLY_ALLOW: FrozenSet[Tuple[str, str]] = frozenset({("issue", "edit"), ("label", "create")})
APPLY_FLAGS: Dict[Tuple[str, str], FrozenSet[str]] = {
    ("issue", "edit"): frozenset({"--add-label", "--remove-label"}),
    ("label", "create"): frozenset({"--color", "--description"}),
}
MAX_APPLY_ISSUES = 50
MAX_APPLY_LABELS = 50
_NAME_RE = re.compile(r"[A-Za-z0-9][\w.:-]*")
_COLOR_RE = re.compile(r"[0-9a-fA-F]{6}")
_CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f]")
MAX_DESCRIPTION = 100

ISSUE_FIELDS = "number,title,state,createdAt,labels,blockedBy"
PR_FIELDS = "number,title,body,isDraft,closingIssuesReferences"
LABEL_LIST_LIMIT = 200
LABEL_FIELDS = "name,color,description"
_STATES = ("open", "closed", "all")


class ModeError(RuntimeError):
    """The requested `gh` call is not permitted by the mode, the allow-list or the caps (never ran)."""


class Gh:
    def __init__(self, cfg, runner: Optional[Callable[..., Any]] = None, max_calls: int = 25, max_writes: int = 1):
        self.cfg = cfg
        self._runner = runner or subprocess.run
        self.max_calls = max_calls
        self.max_writes = max_writes
        self.calls = 0
        self.writes = 0

    def _check_flags(self, verb: Tuple[str, ...], args: Sequence[str]) -> None:
        allowed = ALLOWED_FLAGS.get(verb, frozenset())
        for arg in args:
            if arg.startswith("-") and arg.split("=", 1)[0] not in allowed:
                raise ModeError("flag %r is not allow-listed for gh %s" % (arg.split("=", 1)[0], " ".join(verb)))

    def run(self, verb: Sequence[str], args: Sequence[str], write: bool = False, confirmed: bool = False) -> str:
        """Run one allow-listed `gh` call and return its stdout. Raises ModeError (refused) or RuntimeError
        (the call ran and failed)."""
        verb_t = tuple(verb)
        mode = self.cfg.mode
        if mode == "off":
            raise ModeError("mode off: no gh access (missing/invalid .claude/backlog.yml, or mode: off)")
        allowed = WRITE_ALLOW if write else READ_ALLOW
        if verb_t not in allowed:
            raise ModeError("gh %s is not an allow-listed %s verb" % (" ".join(verb_t), "write" if write else "read"))
        self._check_flags(verb_t, args)
        if write:
            if mode == "propose":
                raise ModeError("mode propose never writes")
            if mode == "write-supervised" and not confirmed:
                raise ModeError("mode write-supervised needs an explicit confirmation for each write")
            if self.writes >= self.max_writes:
                raise ModeError("write cap reached (%d)" % self.max_writes)
        if self.calls >= self.max_calls:
            raise ModeError("call cap reached (%d)" % self.max_calls)
        argv: List[str] = ["gh"] + list(verb_t) + list(args)
        if self.cfg.repo:
            argv += ["-R", self.cfg.repo]
        self.calls += 1
        if write:
            self.writes += 1
        try:
            result = self._runner(argv, capture_output=True, text=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError, OSError) as exc:
            raise RuntimeError("gh %s failed: %s" % (" ".join(verb_t), exc)) from exc
        return result.stdout

    def _json_list(self, verb: Tuple[str, str], args: List[str], what: str) -> list:
        out = self.run(verb, args)
        try:
            data = json.loads(out)
        except ValueError as exc:
            raise RuntimeError("failed to fetch %s via gh: %s" % (what, exc)) from exc
        if not isinstance(data, list):
            raise RuntimeError("failed to fetch %s via gh: payload is not a list" % what)
        return data

    def fetch_issues(self, state: str = "open", limit: int = 500, fields: str = ISSUE_FIELDS) -> list:
        """`gh issue list` (read-only). Fails closed on any error and when the result may be truncated."""
        if state not in _STATES:
            raise ModeError("invalid state %r" % state)
        data = self._json_list(
            ("issue", "list"), ["--state", state, "--limit", str(limit), "--json", fields], "issues"
        )
        if len(data) >= limit:
            raise RuntimeError("issue list hit the limit (%d): possible silent truncation, raise the limit" % limit)
        return data

    def fetch_issue(self, number: int, with_body: bool = False) -> dict:
        """`gh issue view` of ONE issue (read-only), same fields as the list read. The free text of the issue is
        added only under `with_body=True`; the field string is fixed here, a caller cannot ask for another field.
        Fails closed: a failing call or a payload that is not the requested issue is an error."""
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise ModeError("invalid issue number %r" % (number,))
        fields = ISSUE_FIELDS + (",body" if with_body else "")
        out = self.run(("issue", "view"), [str(number), "--json", fields])
        try:
            data = json.loads(out)
        except ValueError as exc:
            raise RuntimeError("failed to fetch issue #%d via gh: %s" % (number, exc)) from exc
        if not isinstance(data, dict) or data.get("number") != number:
            raise RuntimeError("failed to fetch issue #%d via gh: unexpected payload" % number)
        return data

    def fetch_prs(self, limit: int = 200, fields: str = PR_FIELDS) -> list:
        data = self._json_list(("pr", "list"), ["--state", "open", "--limit", str(limit), "--json", fields], "pull requests")
        if len(data) >= limit:
            raise RuntimeError("pr list hit the limit (%d): possible silent truncation" % limit)
        return data

    def fetch_label_names(self) -> set:
        data = self._json_list(
            ("label", "list"), ["--limit", str(LABEL_LIST_LIMIT), "--json", "name"], "labels"
        )
        if len(data) >= LABEL_LIST_LIMIT:
            raise RuntimeError("label list hit the limit (%d): possible silent truncation" % LABEL_LIST_LIMIT)
        return {str(entry["name"]) for entry in data if isinstance(entry, dict) and entry.get("name")}

    def fetch_labels(self) -> list:
        """`gh label list` with color and description (read-only). Fails closed on a possibly truncated list."""
        data = self._json_list(("label", "list"), ["--limit", str(LABEL_LIST_LIMIT), "--json", LABEL_FIELDS], "labels")
        if len(data) >= LABEL_LIST_LIMIT:
            raise RuntimeError("label list hit the limit (%d): possible silent truncation" % LABEL_LIST_LIMIT)
        return [entry for entry in data if isinstance(entry, dict) and entry.get("name")]

    def create_issue(self, title: str, body: str, labels: Sequence[str], confirmed: bool = False) -> str:
        """The plugin's only write. Returns the URL `gh` prints."""
        args = ["--title=" + title, "--body=" + body] + ["--label=" + label for label in labels]
        return self.run(("issue", "create"), args, write=True, confirmed=confirmed).strip()


class PartialApplyError(RuntimeError):
    """`edit_labels` added the labels, then the removal failed: the issue is half-edited (add done)."""


@dataclass(frozen=True)
class ApplyGrant:
    """What an `ApplyGh` may touch. Data only: minted by `backlog_apply.py` once every apply condition passed."""

    repo: str
    digest: str
    snapshot_sha: str
    issues: FrozenSet[int]
    labels: FrozenSet[str]
    refused_adds: FrozenSet[str]


class ApplyGh:
    """The label-write chokepoint: `issue edit` (add/remove labels) and `label create`, nothing else."""

    def __init__(self, cfg, grant: ApplyGrant, runner: Optional[Callable[..., Any]] = None):
        if not isinstance(grant, ApplyGrant):
            raise ModeError("an ApplyGrant is required")
        if cfg.mode not in ("write-supervised", "free"):
            raise ModeError("mode %s never writes" % cfg.mode)
        if not cfg.repo or grant.repo != cfg.repo:
            raise ModeError("the grant does not belong to the repo of the config")
        self.cfg = cfg
        self.grant = grant
        self._runner = runner or subprocess.run
        self.max_calls = 2 * MAX_APPLY_ISSUES + MAX_APPLY_LABELS
        self.calls = 0
        self._issues_touched: set = set()
        self._labels_created: set = set()

    @staticmethod
    def _check_name(name: Any) -> str:
        if not isinstance(name, str) or not _NAME_RE.fullmatch(name):
            raise ModeError("invalid label name %r" % (name,))
        return name

    def _check_issue(self, issue: Any) -> int:
        if isinstance(issue, bool) or not isinstance(issue, int) or issue <= 0:
            raise ModeError("invalid issue number %r" % (issue,))
        if issue not in self.grant.issues:
            raise ModeError("issue #%d is not covered by the grant" % issue)
        return issue

    def _run(self, verb: Sequence[str], args: Sequence[str]) -> str:
        verb_t = tuple(verb)
        if verb_t not in APPLY_ALLOW:
            raise ModeError("gh %s is not an allow-listed apply verb" % " ".join(verb_t))
        allowed = APPLY_FLAGS[verb_t]
        for arg in args:
            if arg.startswith("-") and arg.split("=", 1)[0] not in allowed:
                raise ModeError("flag %r is not allow-listed for gh %s" % (arg.split("=", 1)[0], " ".join(verb_t)))
        if self.calls >= self.max_calls:
            raise ModeError("call cap reached (%d)" % self.max_calls)
        argv: List[str] = ["gh"] + list(verb_t) + list(args) + ["-R", self.cfg.repo]
        self.calls += 1
        try:
            result = self._runner(argv, capture_output=True, text=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError, OSError) as exc:
            raise RuntimeError("gh %s failed: %s" % (" ".join(verb_t), exc)) from exc
        return result.stdout

    def edit_labels(self, issue: int, add: Sequence[str], remove: Sequence[str]) -> None:
        """Add, THEN remove, labels of one granted issue: two sequential calls, each only when non-empty."""
        add_l, remove_l = list(add), list(remove)
        self._check_issue(issue)
        if not add_l and not remove_l:
            raise ModeError("nothing to change on #%d" % issue)
        for name in add_l + remove_l:
            self._check_name(name)
        if len(set(add_l)) != len(add_l) or len(set(remove_l)) != len(remove_l) or set(add_l) & set(remove_l):
            raise ModeError("add and remove lists must be duplicate-free and disjoint")
        refused = sorted(set(add_l) & self.grant.refused_adds)
        if refused:
            raise ModeError("adding %s stays a human triage decision" % ", ".join(refused))
        if issue not in self._issues_touched and len(self._issues_touched) >= MAX_APPLY_ISSUES:
            raise ModeError("batch cap reached (%d issues)" % MAX_APPLY_ISSUES)
        self._issues_touched.add(issue)
        if add_l:
            self._run(("issue", "edit"), [str(issue), "--add-label=" + ",".join(add_l)])
        if remove_l:
            try:
                self._run(("issue", "edit"), [str(issue), "--remove-label=" + ",".join(remove_l)])
            except RuntimeError as exc:
                if add_l:
                    raise PartialApplyError(str(exc)) from exc
                raise

    def create_label(self, name: str, color: str, description: str = "") -> None:
        self._check_name(name)
        if name not in self.grant.labels:
            raise ModeError("label %r is not covered by the grant" % name)
        if not isinstance(color, str) or not _COLOR_RE.fullmatch(color):
            raise ModeError("invalid label color %r" % (color,))
        if not isinstance(description, str) or len(description) > MAX_DESCRIPTION or _CONTROL_RE.search(description):
            raise ModeError("invalid label description")
        if name not in self._labels_created and len(self._labels_created) >= MAX_APPLY_LABELS:
            raise ModeError("batch cap reached (%d labels)" % MAX_APPLY_LABELS)
        self._labels_created.add(name)
        args = [name, "--color=" + color]
        if description:
            args.append("--description=" + description)
        self._run(("label", "create"), args)
